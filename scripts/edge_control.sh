#!/bin/bash
# =============================================================
#  edge_control.sh —— 狗端交互式建图控制台（不启动 RViz）
#
#  和原版 mid360_control.sh 的区别：
#    1. 不启 RViz —— 可视化在 PC 端做（见 scripts/pc_view.sh）
#    2. 多起一个 flmap_bridge，把全分辨率点云瘦身后发给 PC
#    3. 多了 link 命令，现场查无线链路质量
#
#  命令:
#    start   开始一次新扫描（建任务目录 + 录包）
#    pause   暂停录包        resume 继续录包
#    stop    停止录包并导出 PCD
#    status  进程 / 话题 / 流量状态
#    link    无线链路体检（RTT、丢包、Wi-Fi 信号）
#    stats   bridge 输出频率与点数
#    quit    退出（先 stop，再关节点）
#
#  用法:
#    ./scripts/edge_control.sh              # 完整流程
#    ./scripts/edge_control.sh --no-bag     # 只建图不录包（省磁盘，调参时用）
# =============================================================

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${LOG_DIR:-/tmp/flmap_edge}"
BAG_DIR="${FLMAP_BAG_DIR:-$HOME/bags}"
PC_IP="${FLMAP_PC_IP:-}"          # PC 的 IP，用于 link 命令测 RTT
mkdir -p "$LOG_DIR"

# ---- 环境：自动识别 Foxy（狗）/ Humble（开发机）----
for d in foxy humble; do
    if [ -f "/opt/ros/$d/setup.bash" ]; then
        # shellcheck disable=SC1090
        source "/opt/ros/$d/setup.bash"
        break
    fi
done
if [ -f "$REPO_DIR/install/setup.bash" ]; then
    # shellcheck disable=SC1091
    source "$REPO_DIR/install/setup.bash"
else
    echo "[ERROR] 没找到 $REPO_DIR/install/setup.bash —— 先在仓库根目录跑 ./setup.sh"
    exit 1
fi

export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"     # 避开宇树自用的 0 域
export ROS_LOCALHOST_ONLY=0
export LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH:-}"

WITH_BAG=1
for a in "$@"; do
    [ "$a" = "--no-bag" ] && WITH_BAG=0
done

DRV_PID=""; MAP_PID=""; BRG_PID=""; REC_PID=""
TASK_DIR=""; REC_STATE="idle"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
log() { echo -e "$*"; }

cleanup() {
    for p in "$REC_PID" "$BRG_PID" "$MAP_PID" "$DRV_PID"; do
        [ -n "$p" ] && kill -9 "$p" 2>/dev/null
    done
    pkill -9 -f flmap_bridge_node 2>/dev/null
    pkill -9 -f fastlio2_mapping 2>/dev/null
    pkill -9 -f livox_ros_driver2_node 2>/dev/null
    pkill -9 -f "ros2 bag record" 2>/dev/null
}

start_nodes() {
    log "${C}=== 启动 Livox 驱动${N}"
    ros2 launch livox_ros_driver2 msg_MID360_launch.py > "$LOG_DIR/driver.log" 2>&1 &
    DRV_PID=$!
    sleep 5

    log "${C}=== 启动 FAST-LIO2（use_sim_time=false）${N}"
    ros2 launch go2_fastlio mapping_mid360_go2.launch.py use_sim_time:=false > "$LOG_DIR/mapping.log" 2>&1 &
    MAP_PID=$!
    sleep 4

    log "${C}=== 启动瘦身桥（发给 PC）${N}"
    # 必须显式传 params-file：节点代码里的默认值是保守值，真正的调参在
    # src/flmap_bridge/config/bridge_default.yaml（install 里是指向它的符号链接）。
    BRG_CFG="$(ros2 pkg prefix flmap_bridge 2>/dev/null)/share/flmap_bridge/config/bridge_default.yaml"
    ros2 run flmap_bridge flmap_bridge_node --ros-args --params-file "$BRG_CFG" > "$LOG_DIR/bridge.log" 2>&1 &
    BRG_PID=$!
    sleep 2

    # 自检：雷达帧率是判断"到底有没有在出图"的唯一硬指标
    local hz
    hz=$(timeout 6 ros2 topic hz /cloud_registered 2>/dev/null | grep -m1 "average rate" || true)
    if [ -n "$hz" ]; then
        log "${G}  /cloud_registered: $hz${N}"
    else
        log "${Y}  /cloud_registered 暂无数据 —— 检查雷达供电/网口/IP${N}"
    fi
    log "  日志: $LOG_DIR/{driver,mapping,bridge}.log"
}

ask_env_check() {
    [ "${ENV_CHECKED:-0}" = "1" ] && return 0
    ENV_CHECKED=1
    echo ""
    log "${C}扫描前是否做一次环境体检？(y/N)${N}"
    printf "${G}[y/N]: ${N}"
    read -r ans
    case "$ans" in
        y|Y) bash "$REPO_DIR/scripts/env_check.sh" ;;
        *)   log "${Y}已跳过${N}" ;;
    esac
}

do_start() {
    if [ "$REC_STATE" != "idle" ]; then
        log "${Y}已有进行中的任务（$TASK_DIR），先 stop${N}"; return
    fi
    ask_env_check
    local ts; ts=$(date +%Y-%m-%d_%H-%M-%S)
    TASK_DIR="$BAG_DIR/$ts"

    if [ "$WITH_BAG" = "1" ]; then
        mkdir -p "$TASK_DIR"
        {
            echo "开始时间: $ts"
            echo "主机: $(hostname)  ROS: ${ROS_DISTRO}  DOMAIN: $ROS_DOMAIN_ID"
            echo "话题: /livox/lidar /livox/imu /cloud_registered /aft_mapped_to_init /flmap/cloud"
        } > "$TASK_DIR/info.txt"
        ros2 bag record -o "$TASK_DIR/scan" \
            /livox/lidar /livox/imu /cloud_registered /aft_mapped_to_init \
            > "$TASK_DIR/record.log" 2>&1 &
        REC_PID=$!
        sleep 2
        REC_STATE="recording"
        log "${G}录包中 → $TASK_DIR/scan/  (PID $REC_PID)${N}"
    else
        REC_STATE="recording"
        log "${G}开始扫描（未录包，--no-bag）${N}"
    fi
}

do_pause() {
    [ "$REC_STATE" != "recording" ] && { log "${Y}当前没有在录${N}"; return; }
    [ -n "$REC_PID" ] && kill -STOP "$REC_PID" 2>/dev/null
    REC_STATE="paused"; log "${Y}已暂停${N}"
}

do_resume() {
    [ "$REC_STATE" != "paused" ] && { log "${Y}当前没有暂停的任务${N}"; return; }
    [ -n "$REC_PID" ] && kill -CONT "$REC_PID" 2>/dev/null
    REC_STATE="recording"; log "${G}已继续${N}"
}

do_stop() {
    [ "$REC_STATE" = "idle" ] && { log "${Y}没有在录${N}"; return; }
    if [ -n "$REC_PID" ]; then
        [ "$REC_STATE" = "paused" ] && kill -CONT "$REC_PID" 2>/dev/null
        kill -INT "$REC_PID" 2>/dev/null
        for _ in $(seq 1 20); do kill -0 "$REC_PID" 2>/dev/null || break; sleep 0.5; done
        kill -9 "$REC_PID" 2>/dev/null
        REC_PID=""
    fi
    REC_STATE="idle"

    if [ -n "$TASK_DIR" ] && [ "$WITH_BAG" = "1" ]; then
        local bagdir
        bagdir=$(find "$TASK_DIR" -name metadata.yaml -printf "%h\n" 2>/dev/null | head -1)
        if [ -n "$bagdir" ]; then
            if /usr/bin/python3 "$REPO_DIR/scripts/bag_to_pcd.py" "$bagdir" "$TASK_DIR/map.pcd" 2>/dev/null; then
                log "${G}PCD 已导出: $TASK_DIR/map.pcd${N}"
            else
                log "${R}PCD 导出失败（/cloud_registered 可能没数据）${N}"
            fi
            ls -lh "$TASK_DIR" | sed 's/^/  /'
        fi
    fi
    TASK_DIR=""
}

do_status() {
    echo -e "${C}--- 进程 ---${N}"
    printf "  驱动 %-8s 建图 %-8s 桥 %-8s 录包 %-8s\n" \
        "${DRV_PID:-无}" "${MAP_PID:-无}" "${BRG_PID:-无}" "${REC_PID:-无}"
    echo "  录包状态: $REC_STATE   任务: ${TASK_DIR:-无}"

    echo -e "${C}--- 话题 ---${N}"
    for t in /cloud_registered /flmap/cloud; do
        printf "  %-20s " "$t"
        timeout 4 ros2 topic hz "$t" 2>/dev/null | grep -m1 "average rate" || echo "无数据"
    done

    echo -e "${C}--- 硬件 ---${N}"
    echo "  SOC: $(for z in /sys/class/thermal/thermal_zone*/temp; do awk '{printf "%.0f ", $1/1000}' "$z" 2>/dev/null; done)℃"
    echo "  负载: $(uptime | sed 's/.*load average: //')"
    echo "  内存: $(free -h | awk '/^Mem:/{print $3"/"$2}')"
}

do_stats() {
    echo -e "${C}--- bridge 统计（最近 3 行）---${N}"
    grep -E "in .* pts" "$LOG_DIR/bridge.log" 2>/dev/null | tail -3 | sed 's/^/  /' \
        || echo "  还没有统计（默认每 60 帧一行，约 12 秒）"
    echo -e "${C}--- 输出帧率 ---${N}"
    printf "  /flmap/cloud  "
    timeout 5 ros2 topic hz /flmap/cloud 2>/dev/null | grep -m1 "average rate" || echo "无数据"
}

do_link() {
    echo -e "${C}--- 无线链路 ---${N}"
    ip -br addr show 2>/dev/null | awk '$1!="lo"{printf "  %-12s %s\n", $1, $3}'
    for w in /sys/class/net/wl*; do
        [ -e "$w" ] || continue
        local n; n=$(basename "$w")
        echo "  $n 信号: $(iw dev "$n" link 2>/dev/null | awk '/signal/{print $2, $3}' || echo '未知')"
        echo "  $n 速率: $(iw dev "$n" link 2>/dev/null | awk '/bitrate/{print $2, $3}' || echo '未知')"
    done

    if [ -z "$PC_IP" ]; then
        echo -e "  ${Y}未设置 FLMAP_PC_IP，跳过 RTT 测试${N}"
        echo "    export FLMAP_PC_IP=<PC 的 IP> 后再跑 link"
        return
    fi
    echo -e "${C}--- 到 PC ($PC_IP) ---${N}"
    ping -c 20 -i 0.2 -q "$PC_IP" 2>/dev/null | tail -3 | sed 's/^/  /'
}

do_quit() {
    [ "$REC_STATE" != "idle" ] && do_stop
    log "${Y}关闭节点…${N}"
    [ -n "$BRG_PID" ] && kill -INT "$BRG_PID" 2>/dev/null
    [ -n "$MAP_PID" ] && kill -INT "$MAP_PID" 2>/dev/null
    sleep 3
    [ -n "$DRV_PID" ] && kill -INT "$DRV_PID" 2>/dev/null
    sleep 2
    cleanup
    log "${G}已退出${N}"
}

do_help() {
    cat <<EOF
  start   开始新扫描（首次会问是否体检）
  pause   暂停录包       resume 继续录包
  stop    停止录包 + 导出 PCD
  status  进程/话题/硬件
  stats   bridge 输出频率与压缩比
  link    无线链路体检
  env     手动跑一次环境体检
  quit    退出（自动 stop + 关节点）
EOF
}

# ================= 主流程 =================
trap 'do_quit; exit 0' INT TERM
cleanup
start_nodes

log ""
log "${C}========================================${N}"
log "${C} 狗端建图控制台（可视化在 PC 端）${N}"
log "${C} 命令: start / stop / status / stats / link / quit${N}"
log "${C}========================================${N}"

while true; do
    printf "${G}flmap> ${N}"
    read -r cmd || { do_quit; exit 0; }
    case "$cmd" in
        start)  do_start ;;
        pause)  do_pause ;;
        resume) do_resume ;;
        stop)   do_stop ;;
        status) do_status ;;
        stats)  do_stats ;;
        link)   do_link ;;
        env)    bash "$REPO_DIR/scripts/env_check.sh" ;;
        quit|exit) do_quit; exit 0 ;;
        help|"") do_help ;;
        *) log "${Y}未知命令: $cmd${N}" ;;
    esac
done
