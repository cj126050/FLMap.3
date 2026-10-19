# 03 · 狗端部署（Go2 拓展坞）

> 目标：让 Go2 载的 Orin Nano 能跑 **驱动 + FAST-LIO2 + 瘦身桥**，并且不装显示器、不需要
> 拖网线。可视化在 PC 上做，见 [04-pc-visualization.md](04-pc-visualization.md)。

---

## 1. 狗端是什么

以 Go2 拓展坞（Orin Nano 8GB）实测环境为例：

| 项目 | 实测值 |
|---|---|
| SoC | Jetson Orin Nano 8GB（6× A78AE，默认锁 1.51 GHz） |
| 系统 | Ubuntu 20.04.5 LTS，L4T R35.3.1 / JetPack 5.1.1，内核 5.10.104-tegra |
| ROS | **Foxy**（没有 Humble） |
| 存储 | NVMe 469 GB，根分区可用 ~430 GB |
| 网络 | `eth0` = 宇树内网 `192.168.123.18`；另有雷达专用网口 |
| RTC | **没有电池** —— 断电后时间回到镜像构建日（实测差 384 天） |
| 外网 | **没有** —— 任何 `apt install` 都要提前在 PC 上准备好 |

凡是"狗上装不了 XX"的问题，根源基本都是最后两条。

---

## 2. 依赖

狗端需要已有（出厂镜像通常已带）：

```bash
ros-foxy-desktop            # 至少要有 rclcpp / sensor_msgs / tf2 / pcl_conversions
libpcl-dev pcl-tools
libeigen3-dev
# Livox-SDK2 —— 宇树镜像里通常预编译在 /usr/local/lib/liblivox_lidar_sdk_shared.so
```

验证：

```bash
ls /opt/ros/foxy/setup.bash
ls /usr/local/lib/liblivox_lidar_sdk_shared.so
```

**没有外网时怎么补依赖**：在 PC 上 `apt-get download <包名>` 拿到 `.deb`，`scp` 到狗上
`sudo dpkg -i`。注意架构必须是 **arm64**（`apt-get download` 前加
`-o APT::Architecture=arm64`，或者在有 arm64 源的环境里下载）。

---

## 3. 部署（在 PC 上一条命令）

```bash
./scripts/deploy_edge.sh
```

它做三件事：

```
rsync 源码 ──▶ 远端跑 scripts/patch_foxy.sh ──▶ 远端 colcon build
```

可配置：

```bash
EDGE_HOST=192.168.1.50 EDGE_USER=unitree EDGE_WS=~/flmap_ws ./scripts/deploy_edge.sh
./scripts/deploy_edge.sh --no-build     # 只同步
./scripts/deploy_edge.sh --no-patch     # 补丁已打过时
```

前置：`ssh-copy-id unitree@<狗IP>` 建立免密，否则脚本第一步就退出。

### 目标目录里已经有别的东西怎么办

脚本默认**不做删除同步**。如果远端 `src/` 里有本仓库没有的包（你自己加的节点、
L1 桥接之类），它会拒绝执行并把这些包列出来：

```
[warn] 远端 src/ 里有本仓库不包含的包：
         l1_bridge
```

三种处置：

| 场景 | 做法 |
|---|---|
| 想两个项目各自独立（推荐） | `EDGE_WS=~/flmap2_ws ./scripts/deploy_edge.sh` |
| 保留那些包，只覆盖本仓库的文件 | `./scripts/deploy_edge.sh --no-delete` |
| 确认可以丢弃它们 | `./scripts/deploy_edge.sh --allow-delete` |

早期版本直接用 `rsync --delete` 同步到 `~/flmap_ws`，会把你手工加进工作空间的包删掉。
这个坑是实机部署时踩出来的，所以现在做成了默认拒绝。

> **不要两端共用同一份 src。** `patch_foxy.sh` 会修改 `src/` 下的源码（注释掉 Sophus、
> 删 `pcl_ros` 依赖等），改过的树在 Humble 上仍能编，但会让 PC 端工作区"看起来脏"。
> 本仓库的模型是：**PC 保持干净源码，狗端是打过补丁的副本**。想还原：
> `git checkout -- src`。

---

## 4. Foxy 补丁改了什么

`scripts/patch_foxy.sh` 是幂等的（重复执行无副作用），六处最小改动：

| # | 位置 | 改动 | 原因 |
|---|---|---|---|
| 1 | `FAST_LIO2_ROS2/include/common_lib.h` | 注释 `sophus/se3.h` 与 `using namespace Sophus` | Foxy 没有 Sophus 包；SE3 只在从未被 include 的 `feature.h` 里用到 |
| 2 | `FAST_LIO2_ROS2/CMakeLists.txt` | 注释 `find_package(Sophus)` 与 include 路径 | 同上 |
| 3 | `FAST_LIO2_ROS2/package.xml` | 删 `<depend>pcl_ros</depend>` | Foxy 的 PCL 集成包叫 `pcl_conversions`；代码里也没用到 `pcl_ros` |
| 4 | `FAST_LIO2_ROS2/src/**.cpp/.h` | `tf2_geometry_msgs.hpp` → `.h` | `.hpp` 是 Humble 才引入的文件名 |
| 5 | `livox_ros_driver2/src/comm/pub_handler.cpp` | 去掉 `kLivoxLidarTypeMid360s` 分支 | 板上预编译 SDK2（2023-11）没有这个枚举，只影响 MID360**s** 机型 |
| 6 | `livox_ros_driver2/CMakeLists.txt` | 显式链接 PCL/Boost/OpenMP | Foxy 的 `pcl_conversions` 不像 Humble 的 `pcl_ros` 那样传递依赖，否则 `.so` 留未定义符号 |

编译耗时参考：Orin Nano 上全量约 **4 分钟**（`-DCMAKE_BUILD_TYPE=Release`）。

---

## 5. 雷达接线与 IP

狗端只有一个能用的雷达网口，接线和 IP 规划见 [08-hardware.md](08-hardware.md)。
最短路径：

```bash
# 1. 雷达上电，接狗的雷达网口（M8 或 RJ45）
ping -c2 192.168.123.20                 # 雷达出厂 IP（已按 08 文档改过）

# 2. 确认网口在同一网段
ip -br addr | grep 192.168.123

# 3. 确认配置里的 host IP 与本机一致
grep -A2 host_net_info ~/flmap_ws/src/livox_ros_driver2/config/MID360_config.json
```

`MID360_config.json` 里要改两个地方：

- `host_net_info.*_ip` → 拓展坞在该网段的地址（如 `192.168.123.18`）
- `lidar_configs[0].ip` → 雷达地址（如 `192.168.123.20`）

---

## 6. 运行

```bash
ssh unitree@<狗IP>
cd ~/flmap_ws
./scripts/edge_control.sh
```

控制台会依次起驱动、LIO、桥接，然后自检 `/cloud_registered` 频率，最后进入交互。

```
flmap> start      # 开始扫描 + 录包
flmap> status     # 看进程 / 话题 / 温度
flmap> stats      # 看桥接的压缩比与实际输出频率
flmap> stop       # 停止并导出 PCD
flmap> quit       # 退出
```

调参时用 `--no-bag` 省磁盘：

```bash
./scripts/edge_control.sh --no-bag
```

单步排查可以直接用 launch（等价于控制台里的前两步）：

```bash
ros2 launch flmap_bringup edge_mapping.launch.py
ros2 launch flmap_bringup edge_mapping.launch.py start_driver:=false   # 驱动已在跑
ros2 launch flmap_bringup edge_mapping.launch.py voxel_leaf:=0.3 max_rate_hz:=3.0 keep_intensity:=false
```

---

## 7. 时间戳（必读）

**拓展坞没有 RTC 电池。** 断电后系统时间会回到镜像构建日（实测差 384 天）。
这会导致：

- `ros2 bag record` 的文件名和消息时间戳全错，离线回放对不上
- RViz 提示 `message is too old` / TF 查询拒绝
- 多传感器融合（如果有）时间对不齐

上电后第一件事就是校时。最简单的方式是从 PC 拉：

```bash
# 狗端
sudo date -s "$(ssh <PC用户>@<PC_IP> 'date -u "+%Y-%m-%d %H:%M:%S UTC"')"
```

> 更稳的做法是在狗上跑一个每 30 秒向 PC 校时的小服务（`systemd timer` + `curl`），
> 本仓库不内置，因为它依赖你 PC 上的授时端点。要点只有两个：
> ① 校时**必须在启动 LIO 之前**完成（跳变会在点云时间戳上留下断口）；
> ② 用 `flock` 串行化，避免两个进程同时改钟互相污染。

验证：

```bash
date                              # 狗
date                              # PC  —— 两者应在 1 秒内
```

---

## 8. 性能与散热

Orin Nano 默认是 15 W 模式且 CPU 被锁在 1.51 GHz。跑 LIO 前应放开：

```bash
sudo nvpmodel -m 0            # 0 = 15W（Orin Nano 的最高档）
sudo jetson_clocks            # 解锁频率（重启失效，每次上电都要跑）
```

这两条**不持久**。写进 `edge_control.sh` 的启动流程或 `rc.local` 里更省心。

CPU 绑核：LIO 是单线程重计算 + OpenMP，让它独占前 4 核，把 DDS 和驱动留给后 2 核：

```bash
taskset -c 0-3 ros2 launch go2_fastlio mapping_mid360_go2.launch.py use_sim_time:=false
```

温度观察：

```bash
for z in /sys/class/thermal/thermal_zone*/temp; do awk '{printf "%.0f ", $1/1000}' $z; done
```

> 实测空载 CPU 约 58 ℃。建图时若持续超过 85 ℃ 会触发降频，表现是 LIO 帧率掉到 6–7 Hz、
> 点云出现拖影。拓展坞自带风扇，确认它没被挡住。

---

## 9. 开机自启（可选）

想让它上电即用，加一个 systemd 单元：

```ini
# /etc/systemd/system/flmap.service
[Unit]
Description=FLMap edge mapping
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=unitree
WorkingDirectory=/home/unitree/flmap_ws
Environment=ROS_DOMAIN_ID=42
Environment=RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ExecStartPre=/usr/bin/bash -c 'sudo /usr/sbin/nvpmodel -m 0 && sudo /usr/bin/jetson_clocks || true'
ExecStart=/usr/bin/bash -lc 'source /opt/ros/foxy/setup.bash && source install/setup.bash && ros2 launch flmap_bringup edge_mapping.launch.py'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now flmap.service
journalctl -u flmap -f
```

> 用 `ExecStartPre` 跑 `sudo` 需要有免密 sudo 规则，否则服务起不来。
> 不想改 sudoers 的话，把这两条命令写成 root 的 oneshot 服务，让 `flmap.service`
> `After=` 它。

---

## 10. 磁盘与日志

建图 + 录包是最容易把 430 GB 吃满的操作：

| 项目 | 位置 | 增长速度（参考） |
|---|---|---|
| rosbag | `~/bags/<时间戳>/scan/` | 约 1.5–2 GB / 分钟（录 `/livox/lidar` 全量） |
| 运行日志 | `/tmp/flmap_edge/` | 几 MB / 次 |
| PCD | `~/bags/<时间戳>/map.pcd` | 10–100 MB / 次 |

清理：

```bash
du -sh ~/bags/* | sort -h | tail
rm -rf ~/bags/2026-10-17_21-49-24      # 确认已拷回 PC 再删
```

拷回 PC（走 Wi-Fi，百兆级几秒到几十秒）：

```bash
# PC 上
rsync -avP unitree@<狗IP>:~/bags/2026-10-18_10-00-00 ~/data/go2_bags/
```
