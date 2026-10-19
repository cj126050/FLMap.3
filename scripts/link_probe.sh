#!/bin/bash
# =============================================================
#  link_probe.sh —— 无线链路体检（在 PC 上跑）
#
#  这个脚本回答一个问题：**PC 到底能不能稳定收到狗端的点云？**
#  它按"物理层 → 网络层 → DDS 层 → 应用层"四层依次测，
#  哪一层先红，问题就在哪一层。对应排查步骤见 docs/network-and-dds.md。
#
#  用法:
#    ./scripts/link_probe.sh
#    EDGE_HOST=192.168.50.31 ./scripts/link_probe.sh
#    ./scripts/link_probe.sh --bw        # 附带 iperf3 带宽测试（需两端都装了 iperf3）
# =============================================================

set -o pipefail   # 注意：不开 set -u —— ROS 的 setup.bash 会引用未定义变量

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EDGE_HOST="${EDGE_HOST:-192.168.123.18}"
EDGE_USER="${EDGE_USER:-unitree}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"
export ROS_DOMAIN_ID
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"

WITH_BW=0
[ "${1:-}" = "--bw" ] && WITH_BW=1

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
VERDICT=()

say()  { echo -e "\n${B}${C}== $* ==${N}"; }
pass() { echo -e "  ${G}✔${N} $*"; }
warn() { echo -e "  ${Y}!${N} $*"; VERDICT+=("$*"); }
fail() { echo -e "  ${R}✘${N} $*"; VERDICT+=("$*"); }

# ---- ROS 环境（只为跑 ros2 CLI）----
for d in humble foxy; do
    [ -f "/opt/ros/$d/setup.bash" ] && { source "/opt/ros/$d/setup.bash"; break; }
done
[ -f "$REPO_DIR/install/setup.bash" ] && source "$REPO_DIR/install/setup.bash"

echo -e "${B}链路体检${N}  目标 ${EDGE_HOST}  DOMAIN ${ROS_DOMAIN_ID}  RMW ${RMW_IMPLEMENTATION}"

# ---------------------------------------------------------------- 1. 物理/网络
say "1. 本机网络"
ip -br addr show 2>/dev/null | awk '$1!="lo"{printf "  %-12s %-8s %s\n", $1, $2, $3}'
ROUTE_IF=$(ip route get "$EDGE_HOST" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
[ -n "$ROUTE_IF" ] && echo "  到 ${EDGE_HOST} 走: ${ROUTE_IF}"
case "$ROUTE_IF" in
    wl*) pass "走无线网卡（预期）" ;;
    "")  fail "没有到 ${EDGE_HOST} 的路由 —— 不在同一网段，或没连上狗" ;;
    *)   warn "走的是有线口 ${ROUTE_IF}，不是无线 —— 你是不是还插着网线？" ;;
esac

say "2. 连通性与时延（20 包）"
PING=$(ping -c 20 -i 0.2 -W 1 "$EDGE_HOST" 2>/dev/null)
if echo "$PING" | grep -q "0% packet loss\|[1-9][0-9]* received"; then
    LOSS=$(echo "$PING" | sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p')
    STATS=$(echo "$PING" | awk -F'/' '/rtt|round-trip/{print $4, $5, $6}')
    AVG=$(echo "$STATS" | awk '{print $2}')
    MDEV=$(echo "$STATS" | awk '{print $3}')
    MAX=$(echo "$STATS" | awk '{print $4}')
    echo "  丢包 ${LOSS:-?}%  平均 ${AVG:-?} ms  抖动 ${MDEV:-?} ms  最大 ${MAX:-?} ms"
    awk -v l="${LOSS:-0}" 'BEGIN{exit !(l>2)}'  && fail "丢包 ${LOSS}% > 2% —— 距离/干扰/信道问题"  || pass "丢包正常"
    awk -v a="${AVG:-0}"  'BEGIN{exit !(a>30)}' && fail "平均 RTT ${AVG} ms > 30 ms —— 链路拥塞或速率协商过低" || pass "时延正常"
    awk -v m="${MDEV:-0}" 'BEGIN{exit !(m>20)}' && warn "抖动 ${MDEV} ms 偏大 —— 点云会一顿一顿" || pass "抖动正常"
else
    fail "ping 不通 —— 先解决这一层，后面的检查都没意义"
    echo -e "\n${Y}排查顺序${N}:"
    echo "  1) 狗和 PC 连的是同一个 Wi-Fi 吗？狗端 ip -br addr 看有没有 wlan0 地址"
    echo "  2) 狗端有没有开热点/换过网段？两边前三段必须一致"
    echo "  3) 路由器是否开了 AP 隔离（客户端互相不可见）—— 关掉它"
    exit 1
fi

# ---------------------------------------------------------------- 3. SSH
say "3. SSH（用于部署/诊断）"
if timeout 6 ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${EDGE_USER}@${EDGE_HOST}" true 2>/dev/null; then
    pass "免密 ssh 可用"
else
    warn "免密 ssh 不可用 —— deploy_edge.sh 会失败；执行 ssh-copy-id ${EDGE_USER}@${EDGE_HOST}"
fi

# ---------------------------------------------------------------- 4. DDS
say "4. DDS 发现（跨机器发现节点）"
NODES=$(timeout 10 ros2 node list 2>/dev/null)
if [ -n "$NODES" ]; then
    CNT=$(echo "$NODES" | grep -c .)
    echo "$NODES" | sed 's/^/    /' | head -8
    if echo "$NODES" | grep -q "flmap_bridge"; then
        pass "发现狗端节点（含 flmap_bridge）"
    else
        warn "能发现 ${CNT} 个节点，但没看到 flmap_bridge —— 狗端可能没启动，或只发现到本机节点"
    fi
else
    fail "一个节点都没发现 —— DDS 没通。检查两侧 ROS_DOMAIN_ID 与 RMW_IMPLEMENTATION 是否一致"
fi

# ---------------------------------------------------------------- 5. 应用层
say "5. 点云流（应用层，最能说明问题）"
RATE=$(timeout 8 ros2 topic hz /flmap/cloud 2>/dev/null | grep -m1 "average rate" | awk '{print $3}')
if [ -n "$RATE" ]; then
    echo "  /flmap/cloud ≈ ${RATE} Hz"
    awk -v r="$RATE" 'BEGIN{exit !(r<3.5)}' \
        && warn "帧率 ${RATE} Hz 低于目标 5 Hz —— 看狗端 stats 确认是不是限流/丢帧" \
        || pass "帧率达标"
else
    fail "/flmap/cloud 无数据 —— 狗端建图或桥接没起来"
fi

BW=$(timeout 8 ros2 topic bw /flmap/cloud 2>/dev/null | grep -m1 -oE "[0-9.]+ [kMG]B/s" | head -1)
[ -n "$BW" ] && echo "  /flmap/cloud 带宽 ≈ ${BW}"

# ---------------------------------------------------------------- 6. 带宽（可选）
if [ "$WITH_BW" = "1" ]; then
    say "6. 原始带宽（iperf3，需两端都装）"
    if command -v iperf3 >/dev/null && timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=4 \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            "${EDGE_USER}@${EDGE_HOST}" 'command -v iperf3' >/dev/null 2>&1; then
        echo "  在狗端起 iperf3 server 并测 5 秒…"
        timeout 6 ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            "${EDGE_USER}@${EDGE_HOST}" 'pkill -f "iperf3 -s" 2>/dev/null; nohup iperf3 -s -D >/dev/null 2>&1' || true
        sleep 1
        iperf3 -c "$EDGE_HOST" -t 5 -f m 2>/dev/null | awk '/receiver/{print "  下行 "$5, $6}'
    else
        warn "缺少 iperf3（两端都要装：sudo apt install iperf3）"
    fi
fi

# ---------------------------------------------------------------- 结论
echo -e "\n${B}== 结论 ==${N}"
if [ ${#VERDICT[@]} -eq 0 ]; then
    echo -e "  ${G}链路健康，直接 ./scripts/pc_view.sh${N}"
else
    for v in "${VERDICT[@]}"; do echo -e "  ${Y}•${N} $v"; done
    echo -e "\n  对应处置见 docs/network-and-dds.md 的「症状 → 处置」表"
fi
