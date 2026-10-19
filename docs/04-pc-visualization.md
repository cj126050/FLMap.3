# 04 · PC 端远程可视化

> 目标：在 PC 的 RViz 里，实时看到狗端建图过程 —— 地图一点点长出来、当前帧跟着狗走、
> 轨迹画出来。全部数据来自 Wi-Fi，PC 上不跑任何建图算法。

---

## 1. 环境

| 项目 | 要求 |
|---|---|
| 系统 | Ubuntu 22.04（20.04 也行，Foxy 分支） |
| ROS | Humble desktop（含 `rviz2`） |
| Python | `numpy`（`flmap_accumulator` 用；`python3-numpy` 一般随 ROS 装好） |
| 网络 | 与狗同网段，`ping <狗IP>` 通 |

```bash
# 一次性
sudo apt install -y ros-humble-desktop python3-numpy
cd FLMap.2 && ./setup.sh
```

---

## 2. 一键启动

```bash
./scripts/pc_view.sh
```

脚本会：

1. 设好 `ROS_DOMAIN_ID=42` + `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`（必须与狗端一致）
2. ping 狗、等 8 秒看 `/flmap/cloud` 有没有数据（**先诊断再开窗口**，避免盯着空白 RViz 发呆）
3. `ros2 launch flmap_bringup pc_view.launch.py`

变体：

```bash
./scripts/pc_view.sh --headless      # 不弹窗口，只收数据（录包/远程桌面用）
./scripts/pc_view.sh --raw           # 不攒图，只看狗端发来的当前帧
EDGE_HOST=192.168.1.50 ./scripts/pc_view.sh
```

> 狗端 IP 变了就设 `EDGE_HOST`。脚本只把它用于 ping 和提示，DDS 本身靠发现机制找节点 ——
> 也就是说 **IP 写错也能连上**（只要 DDS 能发现），但诊断信息会骗你。

---

## 3. RViz 里看到的是什么

配置在 `src/flmap_bringup/rviz/flmap_pc.rviz`，四个显示项：

| 显示项 | 话题 | 着色 | 含义 |
|---|---|---|---|
| **Accumulated Map** | `/flmap/map` | 按高度（AxisColor） | PC 累积出来的地图，越走越大 |
| **Edge Frame (live)** | `/flmap/cloud` | 按 intensity | 狗端刚发来的当前帧，跟着狗跑 |
| **Odometry** | `/aft_mapped_to_init` | 橙色坐标轴 | 当前位姿 |
| **Trajectory** | `/path` | 绿色线 | 走过的轨迹 |

关键设置：

- **Fixed Frame = `camera_init`** —— FAST-LIO2 的世界系就是这个名字，别改成 `map` 或 `odom`
- **Accumulated Map 的 Decay Time = 0** —— 0 表示永久保留（地图才会累积）；
  设成 5 就变成"只看最近 5 秒"，看起来像是地图一直在消失
- **Edge Frame 的 Decay Time = 0.5** —— 保留半秒，让单帧看起来连续一点

### 为什么有两份点云

```
/flmap/cloud  5 Hz  当前这一帧 ──┐
                                 ├──▶ RViz 叠加显示
/flmap/map    1 Hz  累积地图 ────┘
```

狗端只发当前帧（省带宽），PC 自己攒（不花带宽）。两个都开的好处是：
**当前帧是"实时"的（跟着狗动），累积地图是"全局"的（判断有没有漏扫）**。

---

## 4. 累加器参数

配置在 `src/flmap_accumulator/config/pc_view.yaml`：

| 参数 | 默认 | 作用 | 调它的场景 |
|---|---|---|---|
| `voxel_leaf` | 0.15 m | 累积时的体素尺寸 | 想要更细 → 0.10（内存翻倍）；内存紧 → 0.25 |
| `publish_rate` | 1.0 Hz | 多久重发整张地图 | 想更顺滑 → 2.0（CPU/带宽翻倍） |
| `max_points` | 2 000 000 | 点数硬上限（≈32 MB） | 大场景 → 5 000 000；内存小 → 500 000 |
| `frame_id` | `camera_init` | 输出点云的坐标系 | 必须与 Fixed Frame 一致 |
| `input_reliability` | `reliable` | 与狗端 `output_reliability` 匹配 | 见 [02](02-network-and-dds.md) §4.2 |

命令行临时覆盖（不用改文件）：

```bash
ros2 run flmap_accumulator flmap_accumulator.py --ros-args -p voxel_leaf:=0.10 -p publish_rate:=2.0
```

内存观察：

```
[flmap_accumulator] 地图 812345 点 | 累计接收 1902334 点 | 内存 13.0 MB
```

"累计接收"远大于"地图点数"是正常的 —— 狗走回头路时会重复累加，触顶才全局去重。

---

## 5. 没有显示器 / 远程桌面

三种做法：

**A. 无头采集，事后看**

```bash
./scripts/pc_view.sh --headless &
ros2 bag record -o ~/data/flmap_run /flmap/cloud /flmap/map /aft_mapped_to_init /path
```

**B. 通过 SSH X11 转发**（需 PC 上允许 `X11Forwarding`，延迟高但能看）

```bash
ssh -X <PC> 'cd FLMap.2 && ./scripts/pc_view.sh'
```

**C. VNC / NoMachine / 向日葵**：体验最好，推荐现场用。

---

## 6. 录屏与截图

演示/汇报用：

```bash
# 直接录 RViz 窗口（找到窗口 id）
xwininfo -name "RViz*" | grep "Window id"
ffmpeg -f x11grab -video_size 1200x846 -framerate 15 -i :0.0+100,100 -t 60 rviz.mp4
```

或者录数据包后回放：

```bash
ros2 bag record -o ~/data/run /flmap/cloud /flmap/map /aft_mapped_to_init /path
# 之后
ros2 bag play ~/data/run &
ros2 launch flmap_bringup pc_view.launch.py accumulate:=false   # 直接看回放的 /flmap/cloud
```

> 注意：回放时 `/flmap/map` 不会自动重建，用 `accumulate:=true` 让累加器跟着回放
> 重新拼一遍即可（`--raw` 的反面）。

---

## 7. 离线回放（把 bag 变成地图）

狗端录的包里存的是 `/cloud_registered`（全分辨率），可以在 PC 上重建：

```bash
# 终端 1：桥接（PC 上跑，把全分辨率压成可视化尺寸，省 CPU）
ros2 run flmap_bridge flmap_bridge_node --ros-args \
  -p input_topic:=/cloud_registered -p output_topic:=/flmap/cloud

# 终端 2：累加器
ros2 run flmap_accumulator flmap_accumulator.py

# 终端 3：RViz
rviz2 -d $(ros2 pkg prefix flmap_bringup)/share/flmap_bringup/rviz/flmap_pc.rviz

# 终端 4：回放
ros2 bag play ~/data/xxx_bag
```

⚠️ 回放时**不要**再起 FAST-LIO2 —— bag 里已经有 `/cloud_registered` 了，重复建图只会打架。

如果只想从 bag 里导 PCD，用 `scripts/bag_to_pcd.py`：

```bash
python3 scripts/bag_to_pcd.py <bag目录> out.pcd
```
