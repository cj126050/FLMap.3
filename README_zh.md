# FLMap.3 —— Go2 有线边缘建图 + PC 实时可视化

**机器狗上建图，电脑上看图，一根网线解决所有问题。**

Mid360 与 Go2 拓展坞挂到同一台千兆交换机，FAST-LIO2 在狗载 Orin 上跑，
点云经有线实时送到 PC，RViz 里看着地图一点点长出来。

> **只想赶紧跑起来？** 直接看 [docs/11-runbook.md](docs/11-runbook.md)（一页操作手册）。

`ROS 2 Foxy（狗端）` · `ROS 2 Humble（PC 端）` · `Livox Mid360` · `FAST-LIO2` · `BSD-3-Clause`

---

## 一、为什么还有第三版

三代解决的是三个不同的问题：

| | 原版 [FLMap](https://github.com/cj126050/FLMap) | [FLMap.2](https://github.com/cj126050/FLMap.2) | **FLMap.3** |
|---|---|---|---|
| LIO 跑在哪 | PC | Orin 拓展坞 | Orin 拓展坞 |
| PC 与狗之间 | 网线 | Wi-Fi | **千兆有线 + 交换机** |
| 链路 RTT | 0.4 ms | 2–40 ms（省电模式 90 ms） | **0.55 ms** |
| 链路抖动 | 0.1 ms | 0.1–35 ms，随机 | **0.12 ms** |
| 狗能自由走动 | 不能 | 能 | 不能（半径 = 网线长度） |
| 搭建难度 | 低 | **高**（跨网段、NAT、AP/STA 切换） | **低**（同网段，零路由配置） |

FLMap.2 为了摆脱网线，付了一整套代价：狗端没有射频要插 USB 网卡、跨
`12.x ↔ 123.x` 网段要运控配合转发、多播被 AP 丢弃、省电模式把抖动推到 40 ms、
邻居路由同信道打架。**其中"运控不转发"这一条实测下来是死路**（见 FLMap.2 的
`docs/09-wireless-link.md`）。

FLMap.3 的判断很直接：**如果使用场景是室内、固定场地、要的是建图质量而不是
狗的机动性，那根网线不是负担，是最便宜的稳定性。**

### 有线换来的三件事

1. **抖动从 35 ms 降到 0.12 ms。** 实时点云最怕抖动，这一项决定了画面是"顺"还是"一顿一顿"。
2. **带宽从 1.3 Mbit/s 放宽到 11.6 Mbit/s，只占千兆的 1.2%。** 降采样体素从
   `0.20 m` 收紧到 `0.10 m`、帧率从 `5 Hz` 提到 `10 Hz` —— 画面细节直接翻倍。
3. **少掉一整类静默失败。** 同网段、没有 NAT、没有跨网段路由、没有 AP/STA 切换，
   DDS 发现失败的原因从七八种收敛到三种。

## 二、架构

```
   ┌──────────────── Go2 拓展坞（边缘）────────────────┐       ┌──────── PC ────────┐
   │                                                   │       │                    │
   │  Mid360 ──▶ livox_ros_driver2 ──▶ FAST-LIO2       │       │  flmap_accumulator │
   │  .221              │                  │           │       │        │           │
   │              /livox/lidar      /cloud_registered  │ 千兆   │        ▼           │
   │              /livox/imu               │           │ 有线   │   /flmap/map       │
   │                                       ▼           │       │        │           │
   │                                flmap_bridge ──────┼──────▶│      RViz2         │
   │                             （降采样 + 限流）      │ 13Mbps│                    │
   │                                       │           │ 10 Hz │                    │
   │                                       ▼           │       │                    │
   │                                /flmap/cloud ──────┘       │                    │
   └───────────────────────────────────────────────────┘       └────────────────────┘
            ▲
            │ 同一台千兆交换机
            │
     ┌──────┴──────┐
     │  PC .10     │
     └─────────────┘
```

**关键设计没有变：狗端只传「当前这一帧」，不传整张地图。**
地图在 PC 上累加，所以跑一小时和跑一分钟的链路负载一样。这一点是三代共用的
根本，也是这套方案能在 Wi-Fi 上成立、在有线上更从容的原因。

变的是参数：链路从"紧张"变成"富余"，于是可以把保真度调到 Wi-Fi 下不敢想的水平。

## 三、目录结构

```
FLMap.3/
├── src/
│   ├── FAST_LIO2_ROS2/      # LIO 核心（含断流修复）
│   ├── livox_ros_driver2/   # Livox 驱动（雷达 IP 见 config/MID360_config.json）
│   ├── go2_fastlio/         # LIO 的 launch / 参数集成
│   ├── flmap_bridge/        # ★ 狗端：降采样 + 重打包 + 限流 → /flmap/cloud
│   ├── flmap_accumulator/   # ★ PC 端：多帧累积成地图 → /flmap/map
│   └── flmap_bringup/       # ★ 双端 launch 文件 + RViz 配置
├── scripts/
│   ├── deploy_edge.sh       # 同步到狗 + Foxy 补丁 + 远程编译
│   ├── edge_control.sh      # 狗端交互控制台（不起 RViz）
│   ├── pc_view.sh           # PC 端一键可视化
│   ├── clock_sync.sh        # ★ 时间同步：PC 授时 + 狗端校准
│   ├── link_probe.sh        # 四层链路体检（物理→网络→DDS→应用）
│   ├── patch_foxy.sh        # Humble → Foxy 源码补丁（幂等）
│   └── env_check.sh         # 环境体检报告
├── config/
│   └── cyclonedds_unicast.xml.example   # 可选：交换机做了端口隔离时用
├── tools/
│   ├── clock/               # ★ 授时服务 + 狗端校时工具
│   ├── diag/                # ★ 排查工具（详见 docs/10）
│   │   ├── dds_loopback.py  #   本机已知答案闭环：传输层到底干不干净
│   │   ├── cloud_stat.py    #   点云数值分布体检：找"自洽但错位"的数据
│   │   ├── bridge_selftest.py      # 自解释点云 → 反查串位
│   │   └── run_bridge_selftest.sh  # 上一项的一键版（回归测试）
│   ├── fake_cloud.py        # 没有雷达也能压测的合成点云源
│   ├── render_cloud.py      # 不起 RViz，直接把点云渲染成 PNG
│   └── bench_bridge.py      # 量任意话题的真实帧率/带宽
└── docs/                    # 十一篇文档；11 是操作手册
```

## 四、快速开始

### 0. 硬件与前置条件

| 项 | 要求 |
|---|---|
| PC | Ubuntu 22.04 + ROS 2 Humble（桌面版，带 RViz2） |
| 狗端 | Go2 拓展坞（Orin Nano），已装 ROS 2 Foxy + Livox-SDK2 |
| 交换机 | 千兆，**不要用百兆**（百兆会在 11.6 Mbit/s 的点云上丢包） |
| 雷达 | Livox Mid360，IP 改成 `192.168.123.221`（见 [docs/08](docs/08-hardware.md)） |
| 线材 | 三根网线：PC↔交换机、狗↔交换机、雷达↔交换机 |

### 1. 配 PC 有线口

```bash
# 静态 IP，不设默认网关（设了会断网，见 docs/02 §3.3）
sudo nmcli connection add type ethernet ifname enp131s0 con-name go2-wired \
    ipv4.method manual ipv4.addresses 192.168.123.10/24 \
    ipv4.gateway "" ipv4.dns ""
sudo nmcli connection up go2-wired

ping -c3 192.168.123.18      # 拓展坞
ping -c3 192.168.123.221     # 雷达
```

### 2. 时间同步（**建图前必须做**）

```bash
./scripts/clock_sync.sh start        # PC 起授时服务
./scripts/clock_sync.sh install      # 狗端装校时服务（首次，需 sudo 密码）
./scripts/clock_sync.sh check        # 确认偏差 < 10 ms
```

不做这一步的后果：狗端没有 RTC 电池，断电后时间可能是 2023 年，RViz 会一直刷
`Message Filter dropping message`，画面定住不动。

### 3. PC 上编译

```bash
git clone https://github.com/cj126050/FLMap.3.git && cd FLMap.3
./setup.sh
```

### 4. 推到狗上并编译

```bash
./scripts/deploy_edge.sh
# 可用环境变量：EDGE_WS=~/flmap3_ws EDGE_HOST=192.168.123.18
```

脚本做三件事：rsync 源码 → 远端 `patch_foxy.sh` → 远端 `colcon build`。
约 4–8 分钟（Orin Nano）。

### 5. 狗端开始建图

```bash
ssh unitree@192.168.123.18
cd ~/flmap3_ws && ./scripts/edge_control.sh
```

控制台命令：

| 命令 | 作用 |
|---|---|
| `start` | 开始一次扫描（建任务目录 + 录包） |
| `pause` / `resume` | 暂停 / 继续录包 |
| `stop` | 停止并导出 PCD |
| `status` | 进程、话题频率、温度、内存 |
| `stats` | bridge 的压缩比与实际输出频率 |
| `quit` | 退出（自动 stop） |

### 6. PC 端看图

```bash
./scripts/pc_view.sh
```

RViz 四个显示项：

| 显示项 | 话题 | 含义 |
|---|---|---|
| Accumulated Map | `/flmap/map` | 累积地图（PC 本地拼的） |
| Edge Frame (live) | `/flmap/cloud` | 狗端刚发来的当前帧 |
| Odometry | `/aft_mapped_to_init` | 当前位姿 |
| Trajectory | `/path` | 走过的轨迹 |

**一片空白？** 跑 `./scripts/link_probe.sh`，它按物理层→网络层→DDS 层→应用层
逐层检查，直接告诉你断在哪一层。

## 五、实测

**测试环境**：Go2 拓展坞（Orin Nano，Ubuntu 20.04 + Foxy）+ 千兆交换机 +
PC（Ubuntu 22.04 + Humble），Mid360 固件默认参数，室内办公室，约 10 m × 10 m。

### 链路

| 指标 | 数值 |
|---|---|
| PC → 拓展坞 `192.168.123.18` RTT | **0.549 ms**（avg，`ping -c 100`） |
| PC → 运控 `192.168.123.161` RTT | 0.524 ms |
| PC → 雷达 `192.168.123.221` RTT | 0.741 ms |
| 网卡协商 | `carrier=1` / `speed=1000` / `duplex=full` |
| 时间同步残差 | **−4.9 ms**（RTT 1.5 ms，HTTP 授时每 30 s 校准） |

### 狗端 LIO（Orin Nano）

```
[ LIO ] Raw feature num: 16023, downsampled feature num: 5989
        effective feature num: 5935  average residual: 0.0107
```

单帧雷达 19968 点（`point_num: 19968`），10 Hz。LIO 残差稳定在 0.01 量级，
说明时间同步与雷达外参都没有系统偏差。

### 狗端 bridge

```
in 15921 pts -> out 8982 pts (56.4%), ~144 kB/msg, ~11.5 Mbit/s @10.0 Hz
```

- 体素 `0.10 m`（FLMap.2 是 `0.20 m`），保留点数从 ~15% 提到 **56%**
- 带宽 **11.5 Mbit/s**，只占千兆链路的 **1.2%**

### PC 端

| 指标 | 数值 |
|---|---|
| `/flmap/cloud` 频率 | **9.99 Hz**（`bench_bridge.py`，100 帧） |
| 平均点数/帧 | **9075**（max 9319） |
| 实测带宽 | **11.6 Mbit/s** |
| `/flmap/map` 累积速度 | 50 秒 **157 万点 / 25.6 MB** |
| 端到端延迟 | 网线 0.55 ms + DDS 抖动 0.12 ms，RViz 目视无滞后 |

俯视地图（`tools/render_cloud.py` 直接抓 `/flmap/map` 渲染，非截图）：

![PC 端累积地图](docs/images/cloud_pc_map.png)

墙面、地面（深紫，z≈0）、天花板（黄，z≈3.5 m）层次清晰；房间相对
`camera_init` 旋转约 45°，这是雷达安装姿态造成的，非建图误差。

> **如果这张图变成"原点附近一小团"**，几乎一定是点云打包串位 —— 见
> [docs/10-pitfalls.md](docs/10-pitfalls.md)。跑一条
> `./tools/diag/run_bridge_selftest.sh` 就能确认。

## 六、文档索引

| 文档 | 内容 | 什么时候读 |
|---|---|---|
| [01-architecture.md](docs/01-architecture.md) | 为什么这样拆分、数据流、带宽账、关键决策 | 想改设计 / 想理解取舍 |
| [02-network-and-dds.md](docs/02-network-and-dds.md) | 交换机拓扑、IP 规划、DDS 参数、症状→处置 | **连不上时第一个看** |
| [03-edge-deployment.md](docs/03-edge-deployment.md) | 狗端依赖、Foxy 补丁、开机自启、功耗、看门狗 | 首次部署 / 换机器 |
| [04-pc-visualization.md](docs/04-pc-visualization.md) | PC 端环境、RViz 面板、累加器调参、录屏 | 想让画面更好看 |
| [05-bandwidth-tuning.md](docs/05-bandwidth-tuning.md) | 有线下的带宽预算、保真度与帧率的取舍 | 画面卡顿 / 想调清晰度 |
| [06-troubleshooting.md](docs/06-troubleshooting.md) | 按症状索引的排查手册 | 出问题时 |
| [07-gap-fix.md](docs/07-gap-fix.md) | 数据断流导致的点云发散修复 | 点云突然飞走 |
| [08-hardware.md](docs/08-hardware.md) | Mid360 接线、IP 配置、安装姿态 | 装雷达时 |
| [09-time-sync.md](docs/09-time-sync.md) | 为什么必须同步、怎么同步、精度多少 | **建图飘 / RViz 定住时** |
| [10-pitfalls.md](docs/10-pitfalls.md) | 一个"元数据全对、数据全错"的点云 bug 的完整排查过程 | 怀疑点云形状不对时 |
| [11-runbook.md](docs/11-runbook.md) | **本地操作手册**：接线 → 上电 → 三终端 SOP → 收工，每步带检查点 | **每次实验前打印这一篇** |
| [10-pitfalls.md](docs/10-pitfalls.md) | 点云"有数据但几何是错的"两类故障 + 诊断工具 | **地图形状不对时必看** |

## 七、兼容性与已知限制

- **跨发行版 DDS。** 狗端 Foxy、PC 端 Humble。`PointCloud2` / `Odometry` /
  `TFMessage` 在 RTPS 层兼容，两端都用 CycloneDDS 时实践可用。失败时的回退
  方案见 [02 文档](docs/02-network-and-dds.md) §6。
- **狗不能自由走动。** 半径等于网线长度。这是主动取舍，不是缺陷 —— 要机动性
  请用 FLMap.2。
- **PC 端地图是累积结果，不是 LIO 的内部地图。** 走回头路时重复点只有触到内存
  上限才全局去重。这是可视化的取舍，不影响建图精度 —— 权威地图始终是狗端导出
  的 PCD。
- **雷达 IP 必须先在 Livox Viewer 里改。** Mid360 出厂是 `192.168.1.1xx`，
  不改就连不上 `192.168.123.0/24`。
- **交换机别用百兆。** 11.6 Mbit/s 的点云流在百兆上勉强能过，但会和其它流量抢，
  抖动不可控。
- **FLMap.2 的可视化链路一直是错的。** 它的 `flmap_bridge` 用
  `PointCloud2ConstIterator::operator[]` 当点索引，实际每次只前进 `sizeof(float)`
  而不是 `point_step`，导致分量整体串位。本仓库从第一版起就修好了，并把诊断
  变成回归测试：[docs/10](docs/10-pitfalls.md)。狗端 LIO 的精度从未受影响，
  受影响的只有 PC 端看到的形状。

## 八、致谢

- [FAST_LIO2_ROS2](https://github.com/Vulcan-YJX/FAST_LIO2_ROS2) —— LIO 核心
- [livox_ros_driver2](https://github.com/Livox-SDK/livox_ros_driver2) —— Livox 驱动
- [Unitree Go2](https://www.unitree.com/go2) —— 承载平台

上游包保留其原始 BSD 许可，本仓库新增部分均为 BSD-3-Clause。
