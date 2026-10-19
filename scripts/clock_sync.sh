#!/bin/bash
# =============================================================
#  clock_sync.sh —— 有线模式下的时间基准工具（PC 侧入口）
#
#  为什么需要它
#  ------------
#  Orin Nano 载板没有 RTC 电池，断电后时钟回到镜像构建日。
#  而 FAST-LIO2 要把 10 Hz 点云和 200 Hz IMU 融合，两端只要差到几百毫秒，
#  PC 端 RViz 就会报 "Message Filter dropping message"，TF 全部过期。
#
#  有线让这件事变得便宜：RTT 只有 0.5 ms，一次 HTTP 采样就能校准到 1 ms 内。
#
#  用法
#  ----
#    ./scripts/clock_sync.sh start      # 在 PC 上起授时服务（后台常驻）
#    ./scripts/clock_sync.sh install    # 推到狗端安装 systemd 服务（需 sudo）
#    ./scripts/clock_sync.sh check      # 测当前偏差，只读
#    ./scripts/clock_sync.sh stop       # 停掉 PC 侧授时服务
#
#  环境变量:
#    EDGE_HOST  狗端 IP      默认 192.168.123.18
#    EDGE_USER  狗端用户名    默认 unitree
#    TIME_PORT  授时端口      默认 8000
# =============================================================
set -uo pipefail

EDGE_HOST="${EDGE_HOST:-192.168.123.18}"
EDGE_USER="${EDGE_USER:-unitree}"
TIME_PORT="${TIME_PORT:-8000}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG=/tmp/go2_timeserver.log
PIDF=/tmp/go2_timeserver.pid

SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=15)
SSH="ssh ${SSH_OPTS[*]} ${EDGE_USER}@${EDGE_HOST}"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; D='\033[2m'; N='\033[0m'
say() { echo -e "${C}[clock]${N} $*"; }
ok()  { echo -e "${G}[ ok ]${N} $*"; }
warn(){ echo -e "${Y}[warn]${N} $*"; }
die() { echo -e "${R}[fail]${N} $*"; exit 1; }
dim() { echo -e "${D}       $*${N}"; }

# 本机在 192.168.123.0/24 上的地址（授时服务要用它）
local_ip() {
    ip -4 -o addr show | awk '$4 ~ /^192\.168\.123\./ {sub(/\/.*/,"",$4); print $4; exit}'
}

cmd_start() {
    local ip; ip=$(local_ip)
    [ -z "$ip" ] && die "PC 上没有 192.168.123.x 的地址 —— 先按 docs/02 §3 配有线口"
    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        ok "授时服务已在运行 (pid $(cat "$PIDF"))"; return 0
    fi
    if ss -ltn 2>/dev/null | grep -q ":${TIME_PORT} "; then
        ok "端口 ${TIME_PORT} 已有服务在监听"; return 0
    fi
    nohup python3 "$REPO_DIR/tools/clock/go2_timeserver.py" --port "$TIME_PORT" --bind 0.0.0.0 \
        > "$LOG" 2>&1 &
    echo $! > "$PIDF"
    sleep 0.6
    if kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        ok "授时服务已启动: http://${ip}:${TIME_PORT}/time"
        dim "日志 $LOG   pid $(cat "$PIDF")"
        if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            warn "ufw 已启用，狗可能连不上。放行：sudo ufw allow ${TIME_PORT}/tcp"
        fi
    else
        die "启动失败，看 $LOG"
    fi
}

cmd_stop() {
    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        kill "$(cat "$PIDF")" && rm -f "$PIDF" && ok "已停止"
    else
        pkill -f "go2_timeserver.py" 2>/dev/null && ok "已停止" || warn "没有在跑的授时服务"
    fi
}

# 用与狗端相同的算法测偏差：3 次采样取最小 RTT，按单程补偿
cmd_check() {
    local ip; ip=$(local_ip)
    [ -z "$ip" ] && die "PC 上没有 192.168.123.x 的地址"
    python3 - "$EDGE_HOST" "${EDGE_USER}" "$TIME_PORT" "$ip" <<'PY'
import subprocess, sys, time, urllib.request

host, user, port, ip = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
url = "http://%s:%d/time" % (ip, port)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

try:
    with opener.open(url, timeout=2) as r:
        float(r.read().decode().strip())
except Exception as e:
    print("  \033[31m✗\033[0m PC 授时服务不可达 %s  (%s)" % (url, e))
    print("     先在 PC 上: ./scripts/clock_sync.sh start")
    sys.exit(1)

# 狗端用自己的 go2-clock status，走的是同一套采样逻辑
cmd = "command -v go2-clock >/dev/null && go2-clock status || echo 'NO_GO2_CLOCK'"
try:
    out = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
         "-o", "StrictHostKeyChecking=accept-new", "%s@%s" % (user, host), cmd],
        capture_output=True, text=True, timeout=25).stdout
except subprocess.TimeoutExpired:
    print("  \033[31m✗\033[0m ssh 超时")
    sys.exit(1)

print(out.rstrip() if out.strip() else "  （无输出）")
PY
}

cmd_install() {
    cmd_start
    say "推送到狗端…"
    $SSH 'mkdir -p ~/flmap3_clock' >/dev/null 2>&1 || die "ssh 不通"
    scp -q "${SSH_OPTS[@]}" "$REPO_DIR"/tools/clock/go2-clock \
        "$REPO_DIR"/tools/clock/install_go2_clock.sh \
        "${EDGE_USER}@${EDGE_HOST}:~/flmap3_clock/" || die "scp 失败"
    say "安装（需要狗端 sudo 密码）…"
    $SSH "cd ~/flmap3_clock && sudo bash install_go2_clock.sh" 2>&1 | sed 's/^/    /'
    echo
    cmd_check
}

case "${1:-check}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    check)   cmd_check ;;
    install) cmd_install ;;
    -h|--help) sed -n '2,25p' "$0" ;;
    *) echo "用法: $0 {start|install|check|stop}"; exit 1 ;;
esac
