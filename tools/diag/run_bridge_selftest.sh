#!/bin/bash
# =============================================================
#  run_bridge_selftest.sh —— 一条命令跑完 flmap_bridge 回归测试
#
#  起一个隔离的 bridge 实例（独立话题 + 1 mm 体素 + 不限距离），
#  喂"自解释"点云进去，核对输出是否逐个分量都对得上，然后收尾。
#
#  用法:
#    ./tools/diag/run_bridge_selftest.sh              # 5000 点
#    ./tools/diag/run_bridge_selftest.sh -n 20000     # 更大包
#
#  退出码: 0 = 通过, 非 0 = 存在串位
# =============================================================

set -o pipefail   # 不开 set -u：ROS 的 setup.bash 会引用未定义变量

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-43}"   # 用独立域，避免和真机建图互相干扰
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"

G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
say() { echo -e "${C}[selftest]${N} $*"; }

if [ -z "${ROS_DISTRO:-}" ]; then
    for d in humble foxy; do
        if [ -f "/opt/ros/$d/setup.bash" ]; then
            set +u; . "/opt/ros/$d/setup.bash"; set -u
            break
        fi
    done
fi
if [ -f "$REPO_DIR/install/setup.bash" ]; then
    set +u; . "$REPO_DIR/install/setup.bash"; set -u
fi

BIN="$REPO_DIR/install/flmap_bridge/lib/flmap_bridge/flmap_bridge_node"
[ -x "$BIN" ] || { echo -e "${R}[fail]${N} 找不到 $BIN，先 ./setup.sh 或 colcon build"; exit 1; }

say "启动隔离 bridge 实例（域 $ROS_DOMAIN_ID，话题 /_syn_in -> /_syn_out）"
"$BIN" --ros-args \
    -p input_topic:=/_syn_in -p output_topic:=/_syn_out \
    -p voxel_leaf:=0.001 -p max_points:=60000 \
    -p range_min:=0.0 -p range_max:=1000000.0 \
    -p debug_dump:=1 \
    > /tmp/flmap_bridge_selftest.log 2>&1 &
BRG_PID=$!
trap 'kill -9 $BRG_PID 2>/dev/null' EXIT

sleep 3
python3 "$REPO_DIR/tools/diag/bridge_selftest.py" "$@"
RC=$?

if [ $RC -ne 0 ]; then
    echo -e "${R}[fail]${N} 回归测试未通过，bridge 日志：/tmp/flmap_bridge_selftest.log"
    grep -A4 "DEBUG input" /tmp/flmap_bridge_selftest.log | head -8
else
    echo -e "${G}[ ok ]${N} 通过（bridge 日志：/tmp/flmap_bridge_selftest.log）"
fi
exit $RC
