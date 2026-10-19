# 11 · 本地操作手册（Runbook）

> 打印这一篇就够用。每一步都有**检查点**：输出不对就别往下走，直接跳 §6。
> 全流程约 3 分钟（不算首次部署）。

**本机固定参数**

| 角色 | 地址 | 说明 |
|---|---|---|
| PC 有线口 | `192.168.123.10/24` | `enp131s0`，**不设默认网关** |
| Go2 拓展坞 | `192.168.123.18` | SSH 用户 `unitree`，建图跑在这上面 |
| 运控 | `192.168.123.161` | 只用来确认狗活着 |
| Mid360 | `192.168.123.221` | 由狗端供电，随狗上电 |
| ROS 域 | `ROS_DOMAIN_ID=42` | 避开宇树自用的 0 域，脚本已内置 |
| RMW | `rmw_cyclonedds_cpp` | 两端必须相同，脚本已内置 |

---

## 0. 最短路径（已经配好过、只想再建一次图）

```bash
# 终端 A（PC）    起授时，常驻
cd ~/FLMap.3 && ./scripts/clock_sync.sh start

# 终端 B（狗端）  进控制台，看到 10 Hz 后敲 start
ssh unitree@192.168.123.18 && cd ~/flmap3_ws && ./scripts/edge_control.sh
#   flmap> start

# 终端 C（PC）    出图
cd ~/FLMap.3 && ./scripts/pc_view.sh
```

收工：终端 B `stop` → `quit`，终端 C `Ctrl-C`。

## 0.1 三条路径，先选一条

| 我要做什么 | 走哪节 | 耗时 |
|---|---|---|
| 今天只是要建一次图 | 上面这段 / §3 | 3 分钟 |
| 换了新 PC / 重装了系统 / 第一次跑 | §2 一次性配置 → §3 | 20–30 分钟 |
| 已经有问题（连不上 / 画面空 / 形状怪） | §6 症状速查 | — |

一条命令判断"现在能不能直接开跑"：

```bash
cd ~/FLMap.3 && ./scripts/link_probe.sh
```

末尾出现「链路健康，直接 ./scripts/pc_view.sh」就跳 §3；有红项看 §6。

---

## 1. 上电前：接线与顺序

```
        ┌──────────── 千兆交换机 ────────────┐
        │              │                    │
   PC enp131s0     拓展坞 RJ45 #2        Mid360 RJ45
   192.168.123.10  192.168.123.18       192.168.123.221
                        │
                   Go2 运控 .161（内部链路）
```

三根网线，全部 `192.168.123.0/24`，**不需要任何路由配置**。

上电顺序（有讲究，别反）：

1. 交换机通电。
2. 插好三根网线（PC、拓展坞、雷达）。
3. 狗上电（电池开机），等 40–60 秒。
   - 宇树套装（M8 复合线）：雷达由这根线供电，**跟着狗一起醒**，不用单独上电。
   - 零售版（M12 + XT30 裸线）：雷达电源独立，记得**先把 12 V 接上**再指望 ping 通。
4. PC 上 `ping` 三个地址。

```bash
ping -c3 192.168.123.18     # 拓展坞，最先通
ping -c3 192.168.123.161    # 运控（可选）
ping -c3 192.168.123.221    # 雷达，通常比拓展坞慢几秒
```

**检查点**：三个都通，RTT 都在 1 ms 内。

```
3 packets transmitted, 3 received, 0% packet loss
rtt min/avg/max/mdev = 0.42/0.55/0.71/0.08 ms
```

> 雷达 ping 不通但拓展坞通？八成是雷达没上电（狗端 M8 没插好），或 IP 不是 `.221`。
> 见 [08-hardware.md](08-hardware.md)。

---

## 2. 一次性配置（只在新机器 / 重装后做）

### 2.1 PC 有线口

```bash
# 只在第一次执行；con-name 已存在会报错，忽略即可
sudo nmcli connection add type ethernet ifname enp131s0 con-name go2-wired \
    ipv4.method manual ipv4.addresses 192.168.123.10/24 \
    ipv4.gateway "" ipv4.dns ""
sudo nmcli connection up go2-wired
ip -br addr show enp131s0        # 期望 192.168.123.10/24
```

> **不要设默认网关。** 设了之后 PC 的所有出网流量都会往狗身上撞，表现为"能 ping 狗，
> 但浏览器打不开网页"。原因见 [02-network-and-dds.md](02-network-and-dds.md) §3.3。

### 2.2 PC 端编译

```bash
cd ~/FLMap.3
./setup.sh                       # 首次约 4–5 分钟
```

**检查点**：末尾出现 `[ ok ] 编译完成`，并且 `install/setup.bash` 存在。

### 2.3 时间同步（**建图前必须做，且只需装一次**）

```bash
./scripts/clock_sync.sh start     # PC 起 HTTP 授时服务（后台常驻）
./scripts/clock_sync.sh install   # 推到狗端装 systemd 定时器（要狗端 sudo 密码）
```

装完之后，**狗端**每 30 秒自动校一次，以后开机不用管。但 **PC 端的授时服务不会开机自启**，
所以每次实验还是要在终端 A 跑一次 `clock_sync.sh start`（见 §3）。

验证：

```bash
./scripts/clock_sync.sh check
```

**检查点**：最后一行形如 `偏差=-0.0051s`，即 **|偏差| < 10 ms**（实测 −5 ms 量级，RTT 1.3–1.5 ms）。

> 不做这一步的后果：Orin Nano 没有 RTC 电池，断电后时间可能是 2023 年。RViz 会不停
> 刷 `Message Filter dropping message`，TF 全部过期，画面定住。原理见
> [09-time-sync.md](09-time-sync.md)。

### 2.4 部署到狗端

```bash
./scripts/deploy_edge.sh
```

脚本做三件事：`rsync` 整仓 → 远端打 Foxy 补丁 → 远端 `colcon build`。

**检查点**：`6 packages finished`，约 4–8 分钟（Orin Nano 实测 4 分 32 秒）。

```bash
# 可选：确认狗端装好了
ssh unitree@192.168.123.18 'ls ~/flmap3_ws/install/setup.bash'
```

> 只改了狗端代码时，可以只同步+编译，不重新打补丁：
> `./scripts/deploy_edge.sh --no-patch`

---

## 3. 每次实验 SOP（三个终端，顺序不能乱）

### 终端 A —— PC：时间基准

```bash
cd ~/FLMap.3
./scripts/clock_sync.sh start      # 已在跑会提示"已在运行"，无害
```

**检查点**：`[ ok ] 授时服务已启动` 或 `已在运行`。

> 开着就别关。它只占一个 HTTP 端口，狗端定时来取。

### 终端 B —— 狗端：起建图

```bash
ssh unitree@192.168.123.18
cd ~/flmap3_ws
./scripts/edge_control.sh
```

脚本会自动依次拉起 **驱动 → FAST-LIO2 → bridge**，约 11 秒，然后进入 `flmap>` 提示符。

**检查点**（启动日志里必须看到这两条）：

```
[ ok ]  /cloud_registered: average rate: 10.0xx
```

```
flmap_bridge: /cloud_registered -> /flmap/cloud | voxel 0.10 m | <= 10.0 Hz (tol 0.85)
              | <= 60000 pts | range 0.5-40.0 m | qos reliable->reliable
```

如果 `/cloud_registered` 那行显示 **“统计还没出（LIO 刚起）”**，属正常：话题刚建、`hz`
还没攒够样本。等 10 秒在 `flmap>` 里敲 `status` 再看，出现 `average rate: 10.x` 即可。

只有显示 **“驱动未连上雷达”** 时才需要处理，看 §6.2。

> **驱动和建图一进控制台就在跑**，`start` 只是"开始录包 + 建任务目录"。

### 终端 C —— PC：看图

```bash
cd ~/FLMap.3
./scripts/pc_view.sh
```

它会先做连通性检查，再起累加器 + RViz2（自带配置，不用手动加 Display）。

**检查点**：

```
[ ok ] 收到点云，当前帧 8812 点，约 9.9 Hz
```

点数在 8500–9200 之间浮动是正常的（视野内容变了），**别当成丢数据**。

RViz 里应该出现四个显示项：

| 显示项 | 话题 | 长什么样 |
|---|---|---|
| Accumulated Map | `/flmap/map` | 越攒越大的地图，1 Hz 刷新 |
| Edge Frame (live) | `/flmap/cloud` | 当前这一帧，10 Hz 闪动 |
| Odometry | `/aft_mapped_to_init` | 位姿箭头 |
| Trajectory | `/path` | 走过的轨迹 |

### 开始 / 暂停 / 结束（在终端 B 的 `flmap>` 里）

```
flmap> start        # 建任务目录 + 开始录包
flmap> pause        # 暂停录包（节点继续跑，地图继续长）
flmap> resume       # 继续录
flmap> stop         # 停止录包 + 自动导出 PCD
flmap> status       # 进程 / 话题频率 / 温度 / 内存
flmap> stats        # bridge 压缩比与输出频率
flmap> link         # 有线链路体检（网口速率 + 到 PC/雷达 RTT）
flmap> quit         # 退出（会自动先 stop）
```

**检查点**（`stats` 输出，实测基线）：

```
in 15921 pts -> out 8982 pts (56.4%), ~144 kB/msg, ~11.5 Mbit/s @10.0 Hz
```

| 数值 | 正常范围 | 偏低说明 |
|---|---|---|
| 保留比例 | 50–60% | 体素调大了，或场景太空旷 |
| 输出频率 | 9.5–10.0 Hz | 输入帧率不足 / 限流参数被改 |
| 带宽 | 10–13 Mbit/s | 点太少，检查雷达 |

---

## 4. 收工

顺序：**先停狗端，再关 PC 端，最后断电**。

```
flmap> stop      # 导出 PCD（不 stop 直接 quit 也会自动 stop）
flmap> quit      # 关掉驱动 / LIO / bridge
```

PC 端：终端 C `Ctrl-C` 结束 `pc_view.sh`。

数据在哪：

```
狗端  ~/bags/<日期>_<时间>/scan/      # rosbag（/livox/lidar /livox/imu /cloud_registered /aft_mapped_to_init）
狗端  ~/bags/<日期>_<时间>/map.pcd    # stop 时导出的全分辨率地图
狗端  ~/bags/<日期>_<时间>/info.txt   # 开始时间、主机、话题清单
```

拷回 PC（千兆，几十 MB 一两秒）：

```bash
scp -r unitree@192.168.123.18:~/bags/2026-10-19_14-30-00 ~/bags/   # 换成实际目录名
```

---

## 5. 实时体检：什么数值算正常

任何时候怀疑"跑歪了"，按这个顺序看，一级一级往下排。

先加载环境 —— **只有手动敲下面这些命令才需要**，`scripts/` 里的脚本内部已经配好了：

```bash
source /opt/ros/humble/setup.bash
export PATH="/usr/bin:$PATH"        # 有 conda/pyenv 时，保证 python3 带 rclpy/numpy
export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=0
```

```bash
# ① 链路：脚本一次跑完 6 节（网络/时延/SSH/DDS/点云/带宽）
cd ~/FLMap.3 && ./scripts/link_probe.sh

# ② 狗端：驱动在不在、点云有没有、bridge 什么参数
ssh unitree@192.168.123.18 'pgrep -af "livox_ros|fastlio2|flmap_bridge"'

# ③ 话题：狗端本机 vs PC 端，两边频率是否一致
ros2 topic hz /flmap/cloud

# ④ 数据本身：数值分布对不对（不是"有没有数据"）
cd ~/FLMap.3 && python3 tools/diag/cloud_stat.py -t /flmap/cloud -n 1
```

④ 的正常长相（实测）：

```
[帧 0] 8812 点  step=16  row_step=140992  len=140992 OK
  x : min  -5.333  max  23.678 | =0  0.0%  =1.0  0.0%
  y : min -26.073  max   6.821 | =0  0.0%  =1.0  0.0%
  z : min  -0.742  max   6.883 | =0  0.0%  =1.0  0.0%
  i : min   0.000  max 190.000 | =0  9.5%  =1.0  7.5%   ← 强度有 0/1.0 属正常
  错位指纹 (y[i+1]==x[i] 且 z[i+1]==y[i]): 0.0%  (正常)
```

**三轴范围必须各不相同**。如果 `x/y/z` 三列的最小值一模一样，或出现大量 `=1.000`
的值，就是点云串位 —— 见 §6.4。

---

## 6. 症状速查

> 完整版在 [06-troubleshooting.md](06-troubleshooting.md)，这里只放现场最常撞的六种。

### 6.1 `ping` 不通拓展坞

```bash
ip -br addr show enp131s0              # 有没有 192.168.123.10？
cat /sys/class/net/enp131s0/carrier    # 必须是 1
cat /sys/class/net/enp131s0/speed      # 必须是 1000
```

- `carrier=0` → 网线 / 交换机口 / 狗没开机。换线换口。
- 有 IP 但 ping 不通 → PC 上有第二条默认路由抢走了流量：`ip route get 192.168.123.18`。

### 6.2 狗端 `/cloud_registered` 没数据

```bash
tail -30 /tmp/flmap_edge/driver.log      # 找 "successfully set lidar attitude"
tail -30 /tmp/flmap_edge/mapping.log     # 找 "Raw feature num"
```

| 日志 | 含义 | 处置 |
|---|---|---|
| `successfully set lidar attitude, ip: 192.168.123.221` | 驱动正常 | 继续看 mapping.log |
| `failed to connect` / 一直重试 | 雷达没上电或 IP 不对 | `ping 192.168.123.221`，见 [08](08-hardware.md) |
| 驱动正常但 mapping 没 `Raw feature num` | LIO 没收到点云 | `ros2 topic hz /livox/lidar`，检查 QoS 是否成对 |

### 6.3 有数据，但 RViz 一片空白

```bash
./scripts/link_probe.sh          # 先看第 4 节（DDS 发现）和第 5 节（点云流）
```

- 第 4 节（DDS 发现）就红 → 两边 `ROS_DOMAIN_ID` / `RMW_IMPLEMENTATION` 不一致。
  **别手动 export**，用脚本启动（脚本内部已固化 `42` + `cyclonedds`）。
- 第 5 节（点云流）红但第 4 节正常 → CycloneDDS 可能绑错网卡（多网卡机器常见）：

```bash
# 先按 §5 加载环境
ros2 daemon stop; ROS_LOCALHOST_ONLY=0 ros2 topic list | grep flmap
```

- 都正常 → RViz 的 Fixed Frame 是否为 `camera_init`？显示项的 Reliability 是否为
  `Reliable`（与发布端成对，BEST_EFFORT 订阅 RELIABLE 在 CycloneDDS 下**收不到**）。

### 6.4 点云"有数据但形状不对"

典型表现：点挤在原点一小片、像狗身轮廓；或 Z 轴范围到 ±20 m；或三轴最小值相同。

```bash
python3 tools/diag/cloud_stat.py -t /flmap/cloud -n 1
```

判定：

- `x/y/z` 任一项的 `=1.0` 占比 > 5% → **点云串位**，跑回归测试确认
  （强度列的 `=1.0` 是真实反射值，不算）。

```bash
./tools/diag/run_bridge_selftest.sh -n 5000     # 期望 5000/5000
```

回归不过 = `flmap_bridge` 被改回了迭代器写法。原因（`operator[]` 按
`sizeof(T)` 而不是 `point_step` 前进）见 [10-pitfalls.md](10-pitfalls.md)。

### 6.5 画面卡顿

```bash
# 狗端本机频率 vs PC 端频率，两个数一比就知道丢在哪
ssh unitree@192.168.123.18 'export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp; \
  source ~/flmap3_ws/install/setup.bash; ros2 topic hz /flmap/cloud'
ros2 topic hz /flmap/cloud
```

| 狗端 | PC 端 | 结论 |
|---|---|---|
| 10 Hz | 10 Hz | 卡在 RViz 渲染 / PC 性能，不是链路 |
| 10 Hz | 6–8 Hz | 链路丢帧 → `link_probe.sh` 看丢包与协商速率 |
| 6 Hz | 6 Hz | 输入帧率就不够 → 看雷达 / CPU 温度（`status`） |

### 6.6 RViz 报 `Unable to create a suitable GLXContext`

跟仓库无关，是本机显卡驱动 / 远程桌面没有 GLX。绕开窗口：

```bash
./scripts/pc_view.sh --headless          # 只收数据
python3 tools/render_cloud.py -t /flmap/map -o /tmp/map.png --view both   # 先按 §5 加载环境
```

---

## 7. 调参速查

改 `src/flmap_bridge/config/bridge_default.yaml`。狗端是 `--symlink-install` 编译的，
**只改 yaml 不用重编译**：

```bash
scp src/flmap_bridge/config/bridge_default.yaml \
    unitree@192.168.123.18:~/flmap3_ws/src/flmap_bridge/config/
```

然后在狗端控制台 `quit` 再重进。改了 C++ 代码才需要
`./scripts/deploy_edge.sh --no-patch`。

| 我想要 | 改什么 | 代价 |
|---|---|---|
| 更细的墙面 / 家具边缘 | `voxel_leaf: 0.10 → 0.05` | 带宽 ×3（约 35 Mbit/s），Orin CPU +15% |
| 更省 CPU / 更稳 | `voxel_leaf: 0.15` | 细节变糊，带宽降到 ~6 Mbit/s |
| 画面更连续 | `max_rate_hz: 10.0`（已是默认上限） | 再高没意义，输入只有 10 Hz |
| 只保留近处 | `range_max: 40 → 15` | 远处墙没了，带宽降一半 |
| 不要强度、只要几何 | `keep_intensity: false` | RViz 不能按反射率着色，省 25% |

PC 端累加密度：`./scripts/pc_view.sh voxel_leaf:=0.10`（默认 0.15，越小越细、越吃内存）。

> 千兆链路下**基本不需要为了带宽调参**（11.6 Mbit/s 只占 1.2%）。调参是为了
> 观感或 CPU，不是为了"塞得下"。

---

## 8. 完整命令卡（可整段复制）

```bash
# ---------- 首次 ----------
cd ~/FLMap.3
./setup.sh
./scripts/clock_sync.sh start
./scripts/clock_sync.sh install
./scripts/deploy_edge.sh

# ---------- 每次实验 ----------
# 终端 A
cd ~/FLMap.3 && ./scripts/clock_sync.sh start

# 终端 B
ssh unitree@192.168.123.18
cd ~/flmap3_ws && ./scripts/edge_control.sh
#   进去后：start

# 终端 C
cd ~/FLMap.3 && ./scripts/pc_view.sh

# ---------- 收工 ----------
# 终端 B：stop  →  quit
# 终端 C：Ctrl-C

# ---------- 出问题 ----------
# 先按 §5 的前三行加载 ROS 环境
cd ~/FLMap.3 && ./scripts/link_probe.sh
python3 tools/diag/cloud_stat.py -t /flmap/cloud -n 1
./tools/diag/run_bridge_selftest.sh -n 5000
```

---

## 附：本机路径

| 内容 | 路径 |
|---|---|
| 仓库（PC） | `/home/cj/FLMap.3` |
| 仓库（狗端副本） | `unitree@192.168.123.18:~/flmap3_ws` |
| 狗端运行日志 | `/tmp/flmap_edge/{driver,mapping,bridge}.log` |
| 狗端录包 | `~/bags/<时间戳>/scan/` |
| 授时服务日志 | `/tmp/go2_timeserver.log` |
| 累积地图渲染图 | `docs/images/cloud_pc_map.png` |
