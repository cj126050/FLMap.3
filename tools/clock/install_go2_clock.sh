#!/bin/bash
# install_go2_clock.sh —— 在 Go2 拓展坞上安装时间基准（需 root）
#
# 用法（在拓展坞上，与 go2-clock 放同一目录）:
#   sudo bash install_go2_clock.sh
#
# 安装内容:
#   /usr/local/bin/go2-clock                     校时工具
#   /etc/systemd/system/go2-clock-restore.service  开机恢复上次已知时间（one-shot）
#   /etc/systemd/system/go2-clock-pull.service/timer  每 30s 向 PC 拉一次时间
#   /etc/systemd/system/go2-clock-save.service/timer  每 60s 落盘当前 epoch
# 同时关闭 systemd-timesyncd（拓展坞无外网、RTC 无电池，它只会空转）

set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "请用 sudo 运行"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/go2-clock"
[ -f "$SRC" ] || { echo "[ERROR] 找不到 $SRC"; exit 1; }

echo "== 1. 安装 go2-clock =="
install -m 755 "$SRC" /usr/local/bin/go2-clock
mkdir -p /var/lib/go2-clock
chmod 755 /var/lib/go2-clock

echo "== 2. 关闭 systemd-timesyncd（无可用 NTP 源，避免假象）=="
systemctl disable --now systemd-timesyncd 2>/dev/null || true

echo "== 3. 写 systemd 单元 =="
cat > /etc/systemd/system/go2-clock-restore.service <<'EOF'
[Unit]
Description=Restore Go2 clock from last known epoch (no RTC battery)
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/go2-clock restore
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/go2-clock-pull.service <<'EOF'
[Unit]
Description=Pull time from PC time server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# PC 不在线时静默失败，不影响系统
ExecStart=/usr/local/bin/go2-clock pull
TimeoutStartSec=8
EOF

cat > /etc/systemd/system/go2-clock-pull.timer <<'EOF'
[Unit]
Description=Periodically pull time from PC

[Timer]
OnBootSec=15s
OnUnitActiveSec=30s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/go2-clock-save.service <<'EOF'
[Unit]
Description=Persist current epoch for next boot

[Service]
Type=oneshot
ExecStart=/usr/local/bin/go2-clock save
EOF

cat > /etc/systemd/system/go2-clock-save.timer <<'EOF'
[Unit]
Description=Save epoch every minute

[Timer]
OnBootSec=60s
OnUnitActiveSec=60s

[Install]
WantedBy=timers.target
EOF

echo "== 4. 启用 =="
systemctl daemon-reload
systemctl enable go2-clock-restore.service >/dev/null
systemctl enable --now go2-clock-pull.timer go2-clock-save.timer >/dev/null
systemctl start go2-clock-restore.service || true

echo "== 5. 立即校时 =="
/usr/local/bin/go2-clock pull || echo "  PC 授时服务未响应（稍后定时器会自动重试）"
/usr/local/bin/go2-clock save

echo
echo "== 完成，当前状态 =="
/usr/local/bin/go2-clock status
echo
systemctl --no-pager list-timers 'go2-clock-*' --all 2>/dev/null | head -5
