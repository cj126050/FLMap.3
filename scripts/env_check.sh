#!/bin/bash
# =============================================================
#  Mid360-LIO 实时建图环境检查脚本
#  扫描本机环境，判断是否满足实时建图运行要求，
#  不满足的项会归类列出并给出补齐建议。
#
#  用法:
#    ./env_check.sh                 # 完整检查
#    ./env_check.sh --quick         # 仅快速网络连通检查（ping）
#
#  退出码: 0 = 全部满足；非 0 = 存在缺失项
# =============================================================

CTRL_DIR="$(cd "$(dirname "$0")" && pwd)"      # scripts/
WS_DIR="$(cd "$CTRL_DIR/.." && pwd)"           # 仓库根

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
PASS="${G}[通过]${N}"
FAIL="${R}[缺失]${N}"
WARN="${Y}[警告]${N}"

QUICK=0
for a in "$@"; do [ "$a" = "--quick" ] && QUICK=1; done

# 结果统计
PASS_N=0; FAIL_N=0; WARN_N=0
# 收集缺失项（用于末尾汇总）
declare -a MISSING
# 收集警告项
declare -a WARNINGS

# 记录一项结果：check NAME 通过态
#  $1 名称  $2 结果  pass/fail/warn  $3 建议(可选)
#  fail 的建议进入「需补齐」列表；warn 的建议仅作为提示（单独列出）
note() {
    local name="$1" res="$2" tip="${3:-}"
    case "$res" in
        pass) PASS_N=$((PASS_N+1)); echo -e "  ${PASS} $name" ;;
        warn) WARN_N=$((WARN_N+1)); echo -e "  ${WARN} $name"; [ -n "$tip" ] && WARNINGS+=("$name：$tip") ;;
        fail) FAIL_N=$((FAIL_N+1)); echo -e "  ${FAIL} $name"; [ -n "$tip" ] && MISSING+=("$tip") ;;
    esac
}

echo -e "${C}========== Mid360-LIO 环境检查 ==========${N}"
echo "  仓库: $WS_DIR"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# -----------------------------------------------------------
echo -e "${C}[1/5] 系统与 ROS 2 环境${N}"

# 操作系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "  系统: $NAME $VERSION_ID (内核 $(uname -r))"
    case "$VERSION_ID" in
        22.04) note "Ubuntu 版本 ($VERSION_ID)" pass ;;
        # 20.04 是 Go2 拓展坞的**标准**环境（JetPack 5.1.1 只有 20.04），不是缺陷
        20.04) note "Ubuntu 版本 ($VERSION_ID)" pass ;;
        *)     note "Ubuntu 版本 ($VERSION_ID)" warn "本项目在 20.04(Foxy)/22.04(Humble) 验证，当前 $VERSION_ID 可能需自行排查" ;;
    esac
else
    note "Ubuntu 版本" fail "未检测到 /etc/os-release"
fi

# ROS 2（自动识别发行版：狗端 Foxy / PC 端 Humble）
ROS_FOUND=""
for d in "${ROS_DISTRO:-}" humble foxy; do
    [ -n "$d" ] || continue
    if [ -f "/opt/ros/$d/setup.bash" ]; then ROS_FOUND="$d"; break; fi
done
if [ -n "$ROS_FOUND" ]; then
    note "ROS 2 $ROS_FOUND (/opt/ros/$ROS_FOUND)" pass
    if [ "$ROS_FOUND" = "foxy" ]; then
        note "发行版适配" warn "Foxy：源码需先跑 scripts/patch_foxy.sh（deploy_edge.sh 会自动执行）"
    fi
else
    note "ROS 2" fail "未找到 /opt/ros/{humble,foxy}/setup.bash"
fi

# ros2 命令可用性
if command -v ros2 >/dev/null 2>&1; then
    note "ros2 CLI" pass
elif [ -n "$ROS_FOUND" ]; then
    note "ros2 CLI" warn "ros2 未在 PATH，需先 source /opt/ros/$ROS_FOUND/setup.bash"
else
    note "ros2 CLI" fail "缺少 ros2 命令"
fi

# DDS 环境（跨机器通信的两个关键变量）
note "ROS_DOMAIN_ID" pass "${ROS_DOMAIN_ID:-未设置（默认 0，建议与本仓库一致用 42）}"
note "RMW_IMPLEMENTATION" "$([ "${RMW_IMPLEMENTATION:-}" = "rmw_cyclonedds_cpp" ] && echo pass || echo warn)" \
    "${RMW_IMPLEMENTATION:-未设置（默认 rmw_fastrtps_cpp，与本仓库不一致会收不到数据）}"

# -----------------------------------------------------------
echo -e "${C}[2/5] 工作空间与编译产物${N}"

if [ -f "$WS_DIR/install/setup.bash" ]; then
    note "仓库编译产物 (install/setup.bash)" pass
else
    note "仓库编译产物 (install/setup.bash)" fail "尚未编译，请在仓库根目录运行 ./setup.sh"
fi

# 关键可执行文件
MAP_BIN="$WS_DIR/install/fast_lio2/lib/fast_lio2/fastlio2_mapping"
if [ -x "$MAP_BIN" ]; then
    note "fastlio2_mapping 可执行文件" pass
elif [ -f "$WS_DIR/install/setup.bash" ]; then
    note "fastlio2_mapping 可执行文件" warn "未找到 $MAP_BIN，可能包名不同或未编译成功"
else
    note "fastlio2_mapping 可执行文件" warn "依赖编译产物，编译后自动检查"
fi

# 三个包的 install 目录
for pkg in fast_lio2 livox_ros_driver2 go2_fastlio flmap_bridge flmap_accumulator flmap_bringup; do
    if [ -d "$WS_DIR/install/$pkg" ]; then
        note "已编译包 $pkg" pass
    else
        note "已编译包 $pkg" warn "未在 install/ 下找到 $pkg，可能未编译"
    fi
done

# -----------------------------------------------------------
echo -e "${C}[3/5] Livox SDK 与依赖库${N}"

# Livox-SDK2 动态库
if [ -f /usr/local/lib/liblivox_lidar_sdk_shared.so ]; then
    note "Livox-SDK2 (liblivox_lidar_sdk_shared.so)" pass
else
    note "Livox-SDK2 (liblivox_lidar_sdk_shared.so)" fail "缺少 Livox-SDK2，请安装: https://github.com/Livox-SDK/Livox-SDK2"
fi

# 头文件
if [ -f /usr/local/include/livox_lidar_def.h ] || [ -f /usr/local/include/livox_lidar_sdk.h ]; then
    note "Livox-SDK2 头文件" pass
elif [ -f /usr/local/lib/liblivox_lidar_sdk_shared.so ]; then
    note "Livox-SDK2 头文件" warn "未在 /usr/local/include 找到头文件，可能影响重编译"
else
    note "Livox-SDK2 头文件" warn "依赖 Livox-SDK2 安装"
fi

# PCL（版本随发行版变：20.04→1.10，22.04→1.12，所以按前缀匹配而不是写死版本号）
if compgen -G "/usr/include/pcl-*" > /dev/null 2>&1; then
    note "PCL 开发库 ($(cd /usr/include && ls -d pcl-* 2>/dev/null | head -1))" pass
else
    note "PCL 开发库" fail "缺少 libpcl-dev，请: sudo apt install libpcl-dev"
fi

# Eigen
if [ -d /usr/include/eigen3 ]; then
    note "Eigen3" pass
else
    note "Eigen3" fail "缺少 libeigen3-dev，请: sudo apt install libeigen3-dev"
fi

# -----------------------------------------------------------
echo -e "${C}[4/5] 雷达网络连通性${N}"

# 读取雷达 IP（优先 config 文件，失败用默认）
LIDAR_IP=""
CFG="$WS_DIR/src/livox_ros_driver2/config/MID360_config.json"
if [ -f "$CFG" ]; then
    LIDAR_IP=$(grep -oP '"ip"\s*:\s*"\K[0-9.]+' "$CFG" | head -1)
fi
[ -z "$LIDAR_IP" ] && LIDAR_IP="192.168.120.221"

# 本机配置的 host IP
HOST_IP=$(grep -oP '"point_data_ip"\s*:\s*"\K[0-9.]+' "$CFG" 2>/dev/null | head -1)
[ -z "$HOST_IP" ] && HOST_IP="192.168.120.10"

echo "  雷达 IP: $LIDAR_IP | 本机 IP: $HOST_IP"

# 本机是否已配该网段 IP
if ip -4 addr show 2>/dev/null | grep -q "$HOST_IP"; then
    note "本机静态 IP ($HOST_IP)" pass
else
    note "本机静态 IP ($HOST_IP)" warn "本机未检测到 $HOST_IP，需配置雷达网段静态 IP（见下方建议）"
    MISSING+=("配置本机有线网卡静态 IP：sudo nmcli connection add type ethernet ifname <网卡> con-name mid360 ipv4.method manual ipv4.addresses $HOST_IP/24 && sudo nmcli connection up mid360")
fi

# ping 雷达
if command -v ping >/dev/null 2>&1; then
    if ping -c 1 -W 2 "$LIDAR_IP" >/dev/null 2>&1; then
        note "雷达连通性 (ping $LIDAR_IP)" pass
    else
        note "雷达连通性 (ping $LIDAR_IP)" fail "无法 ping 通雷达 $LIDAR_IP，请检查网线连接、本机 IP 是否同网段、雷达是否上电"
    fi
else
    note "雷达连通性" warn "未找到 ping 命令"
fi

# -----------------------------------------------------------
echo -e "${C}[5/5] 运行环境变量与工具${N}"

# RMW 实现
if [ -n "${RMW_IMPLEMENTATION:-}" ]; then
    note "RMW_IMPLEMENTATION ($RMW_IMPLEMENTATION)" pass
else
    note "RMW_IMPLEMENTATION" warn "未设置，脚本会自动导出 rmw_cyclonedds_cpp"
fi

# bag 转换依赖
if /usr/bin/python3 -c "import rosbag2_py" >/dev/null 2>&1; then
    note "rosbag2_py (PCD 转换依赖)" pass
else
    note "rosbag2_py (PCD 转换依赖)" warn "系统 python3 缺 rosbag2_py，可能影响自动 PCD 转换（不影响建图本身）"
fi

# 磁盘空间
avail_kb=$(df -k --output=avail "$HOME" 2>/dev/null | tail -1 | tr -d ' ')
if [ -n "$avail_kb" ] && [ "$avail_kb" -gt 1048576 ]; then
    note "磁盘空间 (剩余 $((avail_kb/1024/1024)) GB)" pass
elif [ -n "$avail_kb" ]; then
    note "磁盘空间 (剩余 $((avail_kb/1024)) MB)" warn "剩余空间较少，录包可能很快占满"
else
    note "磁盘空间" warn "无法检测"
fi

# -----------------------------------------------------------
echo ""
echo -e "${C}========== 检查结果汇总 ==========${N}"
echo -e "  通过 ${G}$PASS_N${N} 项 | 警告 ${Y}$WARN_N${N} 项 | 缺失 ${R}$FAIL_N${N} 项"
echo ""

if [ "$FAIL_N" -eq 0 ] && [ "$WARN_N" -eq 0 ]; then
    echo -e "${G}环境完全满足实时建图要求，可直接 start 开始扫描。${N}"
elif [ "$FAIL_N" -eq 0 ]; then
    echo -e "${Y}环境基本可用（无致命缺失），但有以下建议项：${N}"
elif [ "$FAIL_N" -gt 0 ]; then
    echo -e "${R}环境不满足实时建图要求，需补齐以下缺失项：${N}"
fi

# 去重后列出缺失项
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo ""
    echo -e "${C}--- 需补齐的环境 ---${N}"
    printf '%s\n' "${MISSING[@]}" | awk '!seen[$0]++' | sed 's/^/  · /'
fi

# 列出警告提示（仅供参考，不阻断）
if [ "${#WARNINGS[@]}" -gt 0 ]; then
    echo ""
    echo -e "${Y}--- 提示（非阻断） ---${N}"
    printf '%s\n' "${WARNINGS[@]}" | awk '!seen[$0]++' | sed 's/^/  · /'
fi

# 输出到任务日志目录，供 mid360_control.sh 记录
if [ "$QUICK" -eq 0 ] && [ -w /tmp ]; then
    mkdir -p /tmp/mid360_ctrl
    {
        echo "=== 环境检查 $(date '+%Y-%m-%d %H:%M:%S') ==="
        echo "通过 $PASS_N / 警告 $WARN_N / 缺失 $FAIL_N"
        [ "${#MISSING[@]}" -gt 0 ] && printf '%s\n' "${MISSING[@]}" | awk '!seen[$0]++' | sed 's/^/缺失: /'
    } > /tmp/mid360_ctrl/env_check.log
fi

[ "$FAIL_N" -gt 0 ] && exit 1 || exit 0
