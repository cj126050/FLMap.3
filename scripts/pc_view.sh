#!/bin/bash
# =============================================================
#  pc_view.sh —— PC 端一键远程可视化
#
#  做三件事：
#    1. 配好和狗端一致的 DDS 环境（CycloneDDS + DOMAIN 42）
#    2. 快速确认狗端在不在线、点云有没有过来
#    3. 起 flmap_accumulator + RViz2
#
#  用法:
#    ./scripts/pc_view.sh                 # 正常开窗口
#    ./scripts/pc_view.sh --headless      # 不起 RViz（只收数据，用其他工具看）
#    ./scripts/pc_view.sh --raw           # 不攒图，只看狗端发来的当前帧
#    EDGE_HOST=192.168.1.50 ./scripts/pc_view.sh
# =============================================================

set -o pipefail   # 注意：不开 set -u —— ROS 的 setup.bash 会引用未定义变量

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EDGE_HOST="${EDGE_HOST:-192.168.123.18}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"
RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
export ROS_DOMAIN_ID RMW_IMPLEMENTATION
export ROS_LOCALHOST_ONLY=0

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
say() { echo -e "${C}[pc_view]${N} $*"; }
ok()  { echo -e "${G}[ ok ]${N} $*"; }
warn(){ echo -e "${Y}[warn]${N} $*"; }
die() { echo -e "${R}[fail]${N} $*"; exit 1; }

LAUNCH_ARGS=()
for a in "$@"; do
    case "$a" in
        --headless) LAUNCH_ARGS+=("rviz:=false") ;;
        --raw)      LAUNCH_ARGS+=("accumulate:=false") ;;
        -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
        *)          LAUNCH_ARGS+=("$a") ;;
    esac
done

# ---- 1. ROS 环境 ----
# 系统 python 优先：装了 conda / pyenv 的机器上，PATH 里的 python3 往往没有
# numpy 和 ROS 的 python 绑定，累加器会直接 ModuleNotFoundError 退出。
export PATH="/usr/bin:$PATH"
for d in humble foxy; do
    if [ -f "/opt/ros/$d/setup.bash" ]; then
        # shellcheck disable=SC1090
        source "/opt/ros/$d/setup.bash"
        break
    fi
done
[ -z "${ROS_DISTRO:-}" ] && die "没找到 /opt/ros/{humble,foxy}/setup.bash"

if [ -f "$REPO_DIR/install/setup.bash" ]; then
    # shellcheck disable=SC1091
    source "$REPO_DIR/install/setup.bash"
else
    die "本仓库还没编译：先在仓库根目录跑 ./setup.sh"
fi
ok "ROS ${ROS_DISTRO} | DOMAIN ${ROS_DOMAIN_ID} | ${RMW_IMPLEMENTATION}"

# ---- 2. 链路快检 ----
say "检查到狗端 ${EDGE_HOST} 的连通性…"
if ping -c 3 -W 1 "$EDGE_HOST" >/dev/null 2>&1; then
    rtt=$(ping -c 5 -i 0.2 -q "$EDGE_HOST" 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5}')
    ok "ping 通，平均 RTT ${rtt:-?} ms"
else
    warn "ping ${EDGE_HOST} 不通。可视化会是一片空白。排查见 docs/network-and-dds.md："
    warn "  - 狗和 PC 是否在同一个 Wi-Fi / 同网段？ ip -br addr"
    warn "  - 狗端 edge_control.sh 是否已在跑？"
    warn "  - 想继续启动（比如换 EDGE_HOST）按 Ctrl-C 退出"
    sleep 3
fi

say "等待狗端的 /flmap/cloud（最多 8 秒）…"
if timeout 8 ros2 topic hz /flmap/cloud 2>/dev/null | grep -q "average rate"; then
    hz=$(timeout 4 ros2 topic hz /flmap/cloud 2>/dev/null | grep -m1 "average rate" | awk '{print $3}')
    ok "收到点云，约 ${hz:-?} Hz"
else
    warn "/flmap/cloud 没数据 —— RViz 会空着。常见原因："
    warn "  1) 狗端还没 start（控制台里输入 start 才开始录包，但建图/桥接是立刻在跑的）"
    warn "  2) 两边 ROS_DOMAIN_ID 不一致（本脚本用 ${ROS_DOMAIN_ID}）"
    warn "  3) 两边 RMW 不一致（本脚本用 ${RMW_IMPLEMENTATION}）"
    warn "  4) 防火墙挡了 DDS，跑 ./scripts/link_probe.sh 看详情"
fi

# ---- 3. 启动 ----
say "启动累加器 + RViz…"
exec ros2 launch flmap_bringup pc_view.launch.py "${LAUNCH_ARGS[@]}"
