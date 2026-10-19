# 05 · 带宽调优

> 画面卡、掉帧、延迟大 —— 先看完这份再改参数，能省掉一半试错。

---

## 1. 先算清楚账

```
单帧字节数 = 点数 × 每点字节数
链路带宽   = 单帧字节数 × 频率 × 8        （bit/s）
```

Mid360 在 `point_filter_num=1` 时约 **20 000 点/帧 @10 Hz**。默认参数下：

| 环节 | 点数 | 字节/点 | 频率 | 带宽 |
|---|---|---|---|---|
| FAST-LIO2 输出 `/cloud_registered` | 20 000 | 48 | 10 Hz | 76.8 Mbit/s |
| 桥接默认（0.20 m / 5 Hz / 保留 intensity） | 2 061 | 16 | 5 Hz | **1.32 Mbit/s** |
| 弱网预设（0.30 m / 3 Hz / 丢 intensity） | ~1 100 | 12 | 3 Hz | **~0.32 Mbit/s** |
| 高清预设（0.10 m / 8 Hz / 保留 intensity） | ~5 000 | 16 | 8 Hz | **~5.1 Mbit/s** |

> 点数是实测值：`tools/fake_cloud.py` 造 8×8×3 m 房间 20 000 点，
> 0.20 m 体素后剩 2 061 点（10.3%）。真实室内场景在 6%–20% 区间，
> 空旷大厅（点更分散）降得更多，走廊（墙面集中）降得更少。

**关键结论**：默认参数只占 1.3 Mbit/s，5 GHz Wi-Fi 的单流可用吞吐通常有 30–80 Mbit/s，
余量 20 倍以上。**如果你的画面在卡，八成不是带宽不够，而是别的原因**（见第 5 节）。

---

## 2. 五个旋钮，按这个顺序调

参数都在 `src/flmap_bridge/config/bridge_default.yaml`，也可以用 launch 覆盖：

```bash
ros2 launch flmap_bringup edge_mapping.launch.py \
    voxel_leaf:=0.30 max_rate_hz:=3.0 keep_intensity:=false
```

| 顺序 | 参数 | 效果 | 代价 |
|---|---|---|---|
| 1 | `voxel_leaf` 0.20 → 0.30 | 点数 −35% | 墙面开始发糊，细节丢失 |
| 2 | `max_rate_hz` 5 → 3 | 带宽 −40% | 画面一顿一顿，但还能看 |
| 3 | `keep_intensity` true → false | 带宽 −25% | 失去反射率着色，只能按高度看 |
| 4 | `range_max` 40 → 20 | 点数明显减少 | 远处结构直接消失 |
| 5 | `max_points` 20000 → 8000 | 硬上限 | 开阔场景点云变稀，室内几乎无感 |

**为什么不先降频率？** 因为观感损失最直接 —— 3 Hz 的点云在 RViz 里是"一帧一帧蹦"。
降体素只是让墙糊一点，人眼更容易接受。

---

## 3. 三个预设

### 默认（推荐起点）

```yaml
voxel_leaf: 0.20
max_rate_hz: 5.0
keep_intensity: true
max_points: 20000
```

### 弱网（2.4 GHz / 隔着墙 / 多设备干扰）

```yaml
voxel_leaf: 0.30
max_rate_hz: 3.0
keep_intensity: false        # 同时把两侧 QoS 改成 best_effort，见 02 文档
max_points: 8000
range_max: 20.0
```

### 高清（5 GHz 近距离，要演示细节）

```yaml
voxel_leaf: 0.10
max_rate_hz: 8.0
keep_intensity: true
max_points: 40000
```

> 高清预设约 5 Mbit/s，仍在安全区内。再往上（0.05 m / 10 Hz）就接近 20 Mbit/s，
> 链路一旦抖动就会连环重传 —— 除非你在做静态展示，否则不建议。

---

## 4. 怎么验证调参效果

自带的量测工具：

```bash
# 狗端：看桥接自己的统计（每 stats_period 帧打一行）
grep "in .* pts" /tmp/flmap_edge/bridge.log | tail -3
# 例：
# in 20000 pts -> out 2061 pts (10.3%), ~33 kB/msg, ~1.3 Mbit/s @5.0 Hz

# PC 端：量实际收到的
python3 tools/bench_bridge.py --topic /flmap/cloud --seconds 8
# 例：
# topic=/flmap/cloud  frames=40  rate=5.0 Hz
# points/frame avg=2061  max=2061
# payload 165 kB/s  ->  1.3 Mbit/s
```

判据：

| 指标 | 健康 | 说明 |
|---|---|---|
| `rate` 接近 `max_rate_hz` | 4.5–5.0 / 5.0 | 明显低于目标说明在丢帧 |
| `points/frame` 稳定 | 波动 < 10% | 忽大忽小说明 input 端不稳 |
| 桥接日志 `hit max_points cap` | 不出现 | 出现说明体素太细或场景太大 |

**PC 端的 rate 比狗端低 = 链路丢帧；两端一样低 = 狗端没发出来**（或输入帧率就低）。

---

## 5. 画面卡但带宽没超？看这四个

1. **Wi-Fi 省电模式**（最常见）

   ```bash
   iw dev wlan0 get power_save        # 狗端
   sudo iw dev wlan0 set power_save off
   ```

   省电模式下 RTT 会从 3 ms 跳到 100+ ms，表现为"卡 2 秒、蹦一下"。

2. **RViz 渲染跟不上**（不是网络问题）

   PC 端 CPU 占用高、RViz 帧率低 → 把地图显示项的点大小从 2 px 调到 1 px，
   或 `publish_rate` 从 1.0 降到 0.5。积到 200 万点的地图，RViz 每次刷新都要重传整份顶点。

3. **DDS 重传堆积**（链路丢包多但还没断）

   `link_probe.sh` 看抖动，mdev > 20 ms 就会这样。

4. **狗端 CPU 打满**（LIO 抢不到核）

   `edge_control.sh status` 看负载；`top` 看 `fastlio2_mapping` 是否 >100%。
   确认 `taskset -c 0-3` 生效，并把 `nvpmodel -m 0 && jetson_clocks` 跑过。

---

## 6. 极端场景

### 走公网 / 4G 远程看图

DDS 直接跨公网不现实（多播发现、UDP 穿透）。正确做法是**在公网两端各放一个桥**：

- 简单版：狗端 `ros2 bag record` → 定时 `rsync` 到有公网 IP 的服务器 → PC 拉下来离线看
- 实时版：用 `zenoh-bridge-dds` 或 `tailscale` + 单播 DDS（`config/cyclonedds_unicast.xml.example`
  里把 Peer 换成 Tailscale 的虚拟 IP）

这类场景已超出本仓库范围，只在此说明为什么默认方案不支持。

### 多台狗同时建图

给每台狗分配不同 `ROS_DOMAIN_ID`（42 / 43 / 44），PC 端起多个累加器：

```bash
ROS_DOMAIN_ID=42 ros2 run flmap_accumulator flmap_accumulator.py \
  --ros-args -p input_topic:=/flmap/cloud -p output_topic:=/robot1/map &
ROS_DOMAIN_ID=43 ros2 run flmap_accumulator flmap_accumulator.py \
  --ros-args -p input_topic:=/flmap/cloud -p output_topic:=/robot2/map &
```

⚠️ 单个 RViz 进程只能连一个 domain，要多开窗口。
