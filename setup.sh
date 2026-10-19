#!/bin/bash
# =============================================================
#  setup.sh —— 编译本仓库（PC 或 Go2 拓展坞都能用）
#
#  PC 端（Ubuntu 22.04 + ROS 2 Humble）：直接编译，源码保持干净
#  狗端（Ubuntu 20.04 + ROS 2 Foxy）  ：先打 Foxy 补丁再编译
#
#  用法:
#    ./setup.sh              # 自动识别平台并编译
#    ./setup.sh --no-foxy    # 跳过 Foxy 补丁（已打过时）
#    ./setup.sh --clean      # 先删 build/install/log 再编
# =============================================================

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

DO_FOXY=1
DO_CLEAN=0
for a in "$@"; do
    case "$a" in
        --no-foxy) DO_FOXY=0 ;;
        --clean)   DO_CLEAN=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    esac
done

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
say() { echo -e "${C}[setup]${N} $*"; }
ok()  { echo -e "${G}[ ok ]${N} $*"; }
warn(){ echo -e "${Y}[warn]${N} $*"; }
die() { echo -e "${R}[fail]${N} $*"; exit 1; }

# ---------------------------------------------------------------- ROS 发行版
ROS_SETUP=""
if [ -n "${ROS_DISTRO:-}" ] && [ -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]; then
    ROS_SETUP="/opt/ros/${ROS_DISTRO}/setup.bash"
else
    for d in humble foxy; do
        [ -f "/opt/ros/$d/setup.bash" ] && { ROS_SETUP="/opt/ros/$d/setup.bash"; break; }
    done
fi
[ -z "$ROS_SETUP" ] && die "没找到 ROS 2（/opt/ros/{humble,foxy}/setup.bash）"
# ROS 的 setup.bash 里引用了若干未定义变量，本脚本开了 set -u，直接 source 会
# 报 "AMENT_TRACE_SETUP_FILES: unbound variable" 并退出。source 期间临时关掉。
set +u
# shellcheck disable=SC1090
source "$ROS_SETUP"
set -u
say "ROS_DISTRO=${ROS_DISTRO}"

IS_EDGE=0
[ "$ROS_DISTRO" = "foxy" ] && IS_EDGE=1

# ---------------------------------------------------------------- 清理
if [ "$DO_CLEAN" = "1" ]; then
    say "清理 build/ install/ log/ …"
    rm -rf build install log
fi

# ---------------------------------------------------------------- Foxy 补丁
if [ "$IS_EDGE" = "1" ] && [ "$DO_FOXY" = "1" ]; then
    say "检测到 Foxy（狗端），应用兼容补丁…"
    bash scripts/patch_foxy.sh "$REPO_DIR" || die "补丁失败"
    ok "补丁完成（只应作用在狗端副本上）"
fi

# ---------------------------------------------------------------- 依赖
if [ "$IS_EDGE" = "0" ] && [ ! -f /usr/local/lib/liblivox_lidar_sdk_shared.so ]; then
    warn "未找到 Livox-SDK2（/usr/local/lib/liblivox_lidar_sdk_shared.so）"
    warn "  安装: https://github.com/Livox-SDK/Livox-SDK2  然后重跑本脚本"
fi

# CMake 必须用「带 catkin_pkg 的 python3」。用 pyenv/conda 的用户常见坑：
# PATH 里的 python3 缺 catkin_pkg，导致 package.xml 解析失败。
if [ -x /usr/bin/python3 ] && /usr/bin/python3 -c "import catkin_pkg" 2>/dev/null; then
    export PATH="/usr/bin:$PATH"
    export PYTHON_EXECUTABLE=/usr/bin/python3
    export Python3_EXECUTABLE=/usr/bin/python3
fi

# ---------------------------------------------------------------- 编译
say "colcon build --symlink-install （狗端 Orin Nano 约 4-8 分钟）…"
colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -8
[ -f "$REPO_DIR/install/setup.bash" ] || die "编译失败：没有产出 install/setup.bash"

ok "编译完成"
echo
if [ "$IS_EDGE" = "1" ]; then
    cat <<EOF
狗端下一步:
    source $REPO_DIR/install/setup.bash
    ./scripts/edge_control.sh          # 建成图 + 瘦身桥（可视化在 PC 端）
EOF
else
    cat <<EOF
PC 端下一步:
    source $REPO_DIR/install/setup.bash
    ./scripts/pc_view.sh               # 远程 RViz
    ./scripts/deploy_edge.sh           # 把代码推到狗上并编译
EOF
fi
