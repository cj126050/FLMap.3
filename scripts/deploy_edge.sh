#!/bin/bash
# =============================================================
#  deploy_edge.sh —— 把仓库同步到 Go2 拓展坞并远程编译
#
#  为什么要单独一个脚本：
#    狗端是 Ubuntu 20.04 + Foxy，PC 端是 Humble，**不能用同一份 src**。
#    本脚本的做法是「PC 保留干净源码，狗端拿一份打过 Foxy 补丁的副本」，
#    这样两边互不污染，PC 端随时可以重新编译验证。
#
#  用法:
#    ./scripts/deploy_edge.sh                 # 同步 + 打补丁 + 编译
#    ./scripts/deploy_edge.sh --no-build      # 只同步，不编译
#    ./scripts/deploy_edge.sh --no-patch      # 同步 + 编译，跳过 Foxy 补丁（已打过时）
#    ./scripts/deploy_edge.sh --allow-delete  # 允许删除远端多余文件（默认拒绝）
#    ./scripts/deploy_edge.sh --no-delete     # 只增不删，也不检查冲突
#
#  环境变量:
#    EDGE_HOST  狗端 IP        默认 192.168.123.18
#    EDGE_USER  狗端用户名      默认 unitree
#    EDGE_WS    狗端工作空间    默认 ~/flmap3_ws
#
#  ⚠️ 安全设计：默认**不做删除同步**。如果远端 src/ 里有本仓库没有的包
#     （例如你自己加的 l1_bridge、私有节点），脚本会直接拒绝并列出这些包，
#     避免一次部署把别人的工作空间清空。三种处置见报错提示。
#     干净机器上首次部署不会触发（远端 src 为空）。
#
#  前置条件：已能 ssh 免密登录狗端（ssh-copy-id unitree@192.168.123.18）
# =============================================================

set -uo pipefail

EDGE_HOST="${EDGE_HOST:-192.168.123.18}"
EDGE_USER="${EDGE_USER:-unitree}"
EDGE_WS="${EDGE_WS:-~/flmap3_ws}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# accept-new：首次连接自动记录主机密钥，之后强制校验（比 StrictHostKeyChecking=no 安全，
# 又不像默认 ask 那样在 BatchMode 下直接失败——这是新机器上最常见的"免密配好了却连不上"）。
# UserKnownHostsFile 显式指定：某些环境里 ssh 取的是 passwd 的 home（如以 root 运行但
# HOME=/home/xxx），会和实际用户的 ~/.ssh 不一致，导致写 known_hosts 失败。
KH_FILE="${HOME}/.ssh/known_hosts"
mkdir -p "${HOME}/.ssh" 2>/dev/null
SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes
          -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="${KH_FILE}"
          -o ServerAliveInterval=15)
SSH="ssh ${SSH_OPTS[*]} ${EDGE_USER}@${EDGE_HOST}"
RSYNC_SSH="ssh ${SSH_OPTS[*]}"

DO_BUILD=1
DO_PATCH=1
ALLOW_DELETE=0
NO_DELETE=0
for a in "$@"; do
    case "$a" in
        --no-build) DO_BUILD=0 ;;
        --no-patch) DO_PATCH=0 ;;
        --allow-delete) ALLOW_DELETE=1 ;;
        --no-delete) NO_DELETE=1 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    esac
done

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
say() { echo -e "${C}[deploy]${N} $*"; }
ok()  { echo -e "${G}[ ok ]${N} $*"; }
warn(){ echo -e "${Y}[warn]${N} $*"; }
die() { echo -e "${R}[fail]${N} $*"; exit 1; }

# ---------------------------------------------------------------- 1. 连通性
say "检查到 ${EDGE_USER}@${EDGE_HOST} 的连接…"
if ! $SSH true 2>/dev/null; then
    die "ssh 不通。先确认：
      - PC 有线口已配 192.168.123.10/24，与狗同在一个交换机
      - ping ${EDGE_HOST} 通
      - 已 ssh-copy-id ${EDGE_USER}@${EDGE_HOST}"
fi
ok "ssh 可用"

REMOTE_ROS=$($SSH 'if [ -f /opt/ros/foxy/setup.bash ]; then echo foxy; elif [ -f /opt/ros/humble/setup.bash ]; then echo humble; else echo none; fi')
[ "$REMOTE_ROS" = "none" ] && die "狗端没有装 ROS 2（/opt/ros/{foxy,humble} 都不存在）"
say "狗端 ROS 发行版: ${REMOTE_ROS}"

# ---------------------------------------------------------------- 2. 同步
say "同步源码 → ${EDGE_WS}"
$SSH "mkdir -p ${EDGE_WS}" || die "无法创建远端目录"

# 只同步源码与脚本；不传 build/install/log，也不传 .git（体积大且无用）
EXCLUDES=(--exclude 'build/' --exclude 'install/' --exclude 'log/'
          --exclude '.git/' --exclude '__pycache__/' --exclude '*.pyc'
          --exclude '.vscode/' --exclude 'bags/' --exclude '.devlog/')

# ---- 防误删：远端 src 里有、本仓库没有的包 → 拒绝删除同步 ----
# 用临时文件而不是 <() 进程替换：某些沙箱环境不提供 /dev/fd
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
( cd "$REPO_DIR/src" 2>/dev/null && ls -d */ 2>/dev/null | tr -d '/' ) | sort > "$TMPD/local.txt"
$SSH "cd ${EDGE_WS}/src 2>/dev/null && ls -d */ 2>/dev/null | tr -d '/'" | sort > "$TMPD/remote.txt"
EXTRA=$(comm -13 "$TMPD/local.txt" "$TMPD/remote.txt" | grep -v '^[[:space:]]*$' || true)

if [ -n "$EXTRA" ] && [ "$ALLOW_DELETE" != "1" ] && [ "$NO_DELETE" != "1" ]; then
    warn "远端 src/ 里有本仓库不包含的包："
    echo "$EXTRA" | sed 's/^/         /'
    warn "默认拒绝删除。三种处理方式："
    echo "         1) 换一个干净目录部署（推荐，彼此不干扰）："
    echo "            EDGE_WS=~/flmap3_ws ./scripts/deploy_edge.sh"
    echo "         2) 保留这些包继续部署（不做删除同步）："
    echo "            ./scripts/deploy_edge.sh --no-delete"
    echo "         3) 确认可以丢弃它们："
    echo "            ./scripts/deploy_edge.sh --allow-delete"
    exit 2
fi

RSYNC_DELETE=()
[ "$ALLOW_DELETE" = "1" ] && RSYNC_DELETE=(--delete-delay)
[ -n "$EXTRA" ] && warn "已确认，将删除远端多余包：$(echo "$EXTRA" | tr '\n' ' ')"

rsync -a -e "${RSYNC_SSH}" "${RSYNC_DELETE[@]}" "${EXCLUDES[@]}" \
    "$REPO_DIR"/ "${EDGE_USER}@${EDGE_HOST}:${EDGE_WS}/" \
    || die "rsync 失败"
ok "同步完成"

# ---------------------------------------------------------------- 3. Foxy 补丁
if [ "$DO_PATCH" = "1" ] && [ "$REMOTE_ROS" = "foxy" ]; then
    say "应用 Foxy 兼容补丁…"
    $SSH "cd ${EDGE_WS} && bash scripts/patch_foxy.sh ${EDGE_WS}" 2>&1 | sed 's/^/    /'
    ok "补丁完成（幂等，可重复执行）"
fi

# ---------------------------------------------------------------- 4. 编译
if [ "$DO_BUILD" = "1" ]; then
    say "狗端编译（Orin Nano 上约 4-8 分钟）…"
    $SSH "cd ${EDGE_WS} && \
        source /opt/ros/${REMOTE_ROS}/setup.bash && \
        export PATH=/usr/bin:\$PATH && \
        colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release" 2>&1 | tail -20 | sed 's/^/    /'
    # 用 tee 拿不到远端退出码，单独验证产物
    if $SSH "test -f ${EDGE_WS}/install/setup.bash"; then
        ok "编译产物就绪: ${EDGE_WS}/install/setup.bash"
    else
        die "编译未产出 install/setup.bash，看上面的报错"
    fi
fi

echo
say "下一步（在狗端终端里）:"
echo "    ssh ${EDGE_USER}@${EDGE_HOST}"
echo "    cd ${EDGE_WS} && ./scripts/edge_control.sh"
echo
say "PC 端可视化:"
echo "    ./scripts/pc_view.sh"
