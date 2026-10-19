#!/bin/bash
# =============================================================
#  link_probe.sh —— 有线链路体检（在 PC 上跑）
#
#  这个脚本回答一个问题：**PC 到底能不能稳定收到狗端的点云？**
#  它按"物理/网络层 → 连通性 → SSH → DDS 层 → 应用层"依次测，
#  哪一层先红，问题就在哪一层。对应排查步骤见 docs/02-network-and-dds.md。
#
#  用法:
#    ./scripts/link_probe.sh
#    EDGE_HOST=192.168.123.161 ./scripts/link_probe.sh     # 测运控
#    ./scripts/link_probe.sh --bw                          # 附带 iperf3 带宽测试
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

# FLMap.3 的前提就是有线：走 wl* 说明接错了口（多半是有线没配 IP，回落到了默认路由）
case "$ROUTE_IF" in
    en*|eth*)
        pass "走有线口 ${ROUTE_IF}（预期）"
        SPEED=$(cat "/sys/class/net/${ROUTE_IF}/speed" 2>/dev/null)
        if [ -n "$SPEED" ]; then
            if [ "$SPEED" -ge 1000 ] 2>/dev/null; then
                pass "协商速率 ${SPEED} Mbit/s"
            else
                fail "协商速率只有 ${SPEED} Mbit/s —— 换千兆交换机/网线（CAT5e 以上）"
            fi
        fi
        ;;
    wl*)
        fail "走的是无线口 ${ROUTE_IF} —— FLMap.3 要求有线。检查有线口是否配了 192.168.123.10/24"
        ;;
    "")
        fail "没有到 ${EDGE_HOST} 的路由 —— 不在同一网段，或网线没插/交换机没上电"
        ;;
    *)
        warn "走的是 ${ROUTE_IF}，不是预期的有线网卡名（en*/eth*）"
        ;;
esac

# ---------------------------------------------------------------- 2. 连通性
say "2. 连通性与时延（20 包）"
PING=$(ping -c 20 -i 0.2 -W 1 "$EDGE_HOST" 2>/dev/null)
if echo "$PING" | grep -q "0% packet loss\|[1-9][0-9]* received"; then
    LOSS=$(echo "$PING" | sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p')
    # ping -q 的统计行：rtt min/avg/max/mdev = a/b/c/d ms
    # 用 '/' 切之后 $4="mdev = a"、$5=b(avg)、$6=c(max)、$7="d ms"
    LINE=$(echo "$PING" | grep -E 'rtt|round-trip' | tail -1)
    MIN=$(echo "$LINE" | awk -F'/' '{n=split($4,a," "); print a[n]}')
    AVG=$(echo "$LINE" | awk -F'/' '{print $5}')
    MAX=$(echo "$LINE" | awk -F'/' '{print $6}')
    MDEV=$(echo "$LINE" | awk -F'/' '{print $7}' | awk '{print $1}')
    echo "  丢包 ${LOSS:-?}%  RTT min/avg/max = ${MIN:-?}/${AVG:-?}/${MAX:-?} ms  抖动 ${MDEV:-?} ms"
    awk -v l="${LOSS:-0}" 'BEGIN{exit !(l>2)}' \
        && fail "丢包 ${LOSS}% > 2% —— 网线/水晶头/交换机端口的问题" || pass "丢包正常"
    # 有线同网段正常在 1 ms 以内；超过 30 ms 基本不可能是物理层，通常是本机负载
    awk -v a="${AVG:-0}" 'BEGIN{exit !(a>30)}' \
        && fail "平均 RTT ${AVG} ms > 30 ms —— 对有线来说不正常，查本机负载 / 交换机" || pass "时延正常"
    awk -v m="${MDEV:-0}" 'BEGIN{exit !(m>20)}' \
        && warn "抖动 ${MDEV} ms 偏大 —— 点云会一顿一顿" || pass "抖动正常"
else
    fail "ping 不通 —— 先解决这一层，后面的检查都没意义"
    echo -e "\n${Y}排查顺序${N}:"
    echo "  1) PC 有线口有没有 192.168.123.10/24？ ip -br addr"
    echo "  2) 网线是否插在交换机上（不是墙上网口）？交换机指示灯亮不亮？"
    echo "  3) 狗端拓展坞上电了吗？ping 192.168.123.161（运控）能不能通？"
    echo "  4) 别给有线口设默认网关，否则路由会被抢走（见 docs/02 §3.3）"
    exit 1
fi

# ---------------------------------------------------------------- 3. SSH
say "3. SSH（用于部署/诊断）"
if timeout 6 ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${EDGE_USER}@${EDGE_HOST}" true 2>/dev/null; then
    pass "免密 ssh 可用"
    EDGE_CLOCK=$(timeout 6 ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${EDGE_USER}@${EDGE_HOST}" 'date +%s' 2>/dev/null)
    if [ -n "$EDGE_CLOCK" ]; then
        SKEW=$(( $(date +%s) - EDGE_CLOCK ))
        SKEW=${SKEW#-}
        if [ "$SKEW" -le 1 ]; then
            pass "两端时间差 ≤ ${SKEW}s"
        else
            warn "两端时间差 ${SKEW}s —— 建图前先跑 ./scripts/clock_sync.sh start && check"
        fi
    fi
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
    # FLMap.3 的默认目标就是 10 Hz（max_rate_hz: 10.0）
    awk -v r="$RATE" 'BEGIN{exit !(r<8.0)}' \
        && warn "帧率 ${RATE} Hz 低于目标 10 Hz —— 看狗端 stats 确认是不是限流/丢帧" \
        || pass "帧率达标"
else
    fail "/flmap/cloud 无数据 —— 狗端建图或桥接没起来（scripts/edge_control.sh status）"
fi

BW=$(timeout 8 ros2 topic bw /flmap/cloud 2>/dev/null | grep -m1 -oE "[0-9.]+ [kMG]B/s" | head -1)
[ -n "$BW" ] && echo "  /flmap/cloud 带宽 ≈ ${BW}（千兆链路上约 1.5 MB/s）"

# 有数据但形状可疑 —— 这是"分量串位"的典型场景，必须单独提示
if [ -n "$RATE" ]; then
    echo "  想确认点云内容是否正常： python3 tools/diag/cloud_stat.py -t /flmap/cloud -n 1"
fi

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
    echo -e "\n  对应处置见 docs/02-network-and-dds.md 的「症状 → 处置」表"
fi
