# 05 · 带宽与保真度调优

> 千兆有线把"带宽"这一项从瓶颈变成了常量：默认参数只占链路的 1.2%。
> 所以这份文档的重点不是"怎么省带宽"，而是**"余量这么多，该把保真度花在哪"**
> 以及"画面卡但带宽还空着"时该查什么。

---

## 1. 先算清楚账

```
单帧字节数 = 点数 × 每点字节数
链路带宽   = 单帧字节数 × 频率 × 8        （bit/s）
```

Mid360 在 `point_filter_num=1` 时约 **16 000–20 000 点/帧 @10 Hz**。实测（室内办公室）：

| 环节 | 点数 | 字节/点 | 频率 | 带宽 |
|---|---|---|---|---|
| FAST-LIO2 输出 `/cloud_registered` | ~16 000 | 48 | 10 Hz | **~61 Mbit/s** |
| 桥接输出 `/flmap/cloud`（`voxel_leaf=0.10`） | **9 075** | 16 | 10 Hz | **11.6 Mbit/s** |
| 千兆链路可用 | — | — | — | 1000 Mbit/s |

- 桥接保留率 **56.6%**（`in 15921 -> out 8982`），比 FLMap.2 的 ~15% 高一个量级，
  因为体素从 `0.20 m` 收到了 `0.10 m`；
- 11.6 Mbit/s 相对千兆是 **1.2%**，链路抖动实测 **0.082 ms**；
- 注意 `PointXYZINormal` 是 **48 B/点**（x,y,z,pad + normal[3],curvature + intensity,pad），
  重打包成 `x,y,z,intensity` 的 **16 B/点** 本身就是 3 倍压缩，比降采样更"无损"。

**关键结论**：带宽不是这套方案的约束。真正会先撞墙的是 **RViz 渲染** 和
**累加器的内存**（见第 5 节）。

---

## 2. 五个旋钮

参数在 `src/flmap_bridge/config/bridge_default.yaml`，也可以用 launch 覆盖：

```bash
ros2 launch flmap_bringup edge_mapping.launch.py \
    voxel_leaf:=0.05 max_rate_hz:=10.0 keep_intensity:=true
```

| 参数 | 默认（有线） | 调大 / 调细的代价 |
|---|---|---|
| `voxel_leaf` | **0.10 m** | 调细（0.05）→ 点数翻倍，墙面细节更好，狗端 CPU 与带宽上升；调粗（0.20）→ 省资源但墙会发糊 |
| `max_rate_hz` | **10.0 Hz** | 跟雷达同频，再高没有意义（上游就是 10 Hz）；调低只省带宽，画面会"一帧一帧蹦" |
| `keep_intensity` | `true` | 关掉省 25% 带宽，但 RViz 只能按高度着色，看不出材质差异 |
| `range_max` | `40.0 m` | 室内可降到 20 m，远处噪点直接消失，点云更干净 |
| `max_points` | **60 000** | 单帧点数硬上限，室内正常场景撞不到；撞到了日志会打 `hit max_points cap` |

**有线下的推荐动作**：先什么都不用调。0.10 m / 10 Hz 已经能跑满雷达帧率，
再细对肉眼几乎没有收益，反而让累加器内存涨得更快。

---

## 3. 三个预设

### 默认（有线，推荐）

```yaml
voxel_leaf: 0.10
max_rate_hz: 10.0
keep_intensity: true
max_points: 60000
range_max: 40.0
```

实测 9 075 点/帧、11.6 Mbit/s。

### 省资源（PC 较弱 / 长时间跑 / 只想看轮廓）

```yaml
voxel_leaf: 0.15
max_rate_hz: 10.0
keep_intensity: true     # 建议保留，着色信息比点密度更影响"能看懂"
max_points: 40000
range_max: 25.0
```

约 4 000 点/帧、5 Mbit/s，累加器内存增长减半。

### 高保真（静态展示 / 精细建模参考）

```yaml
voxel_leaf: 0.05
max_rate_hz: 10.0
keep_intensity: true
max_points: 120000
range_max: 40.0
```

约 20 000 点/帧、26 Mbit/s —— 仍然只占千兆的 2.6%，代价主要在狗端 CPU 和
PC 端累加器内存。

> 就算把 `voxel_leaf` 设成 0（关掉降采样）、10 Hz 全量 16 B/点，
> 也只有 16 000 × 16 × 10 × 8 ≈ **20 Mbit/s**。这就是"有线"带来的自由度：
> 你可以只在需要的时候才考虑带宽。

---

## 4. 怎么验证调参效果

```bash
# 狗端：桥接自己的统计（每 stats_period 帧一行）
grep "in .* pts" /tmp/flmap_edge/bridge.log | tail -3
# 实测输出：
# in 15921 pts -> out 8982 pts (56.4%), ~144 kB/msg, ~11.5 Mbit/s @10.0 Hz

# PC 端：量实际收到的
python3 tools/bench_bridge.py --topic /flmap/cloud --seconds 10
# 实测输出：
# topic=/flmap/cloud  frames=100  rate=10.0 Hz
# points/frame avg=9075  max=9319
# payload 1452 kB/s  ->  11.6 Mbit/s
```

判据：

| 指标 | 健康 | 说明 |
|---|---|---|
| `rate` 接近 `max_rate_hz` | 9.5–10.2 / 10.0 | 明显低于目标说明在丢帧或上游卡了 |
| `points/frame` 稳定 | 波动 < 10% | 忽大忽小说明场景在变或上游不稳 |
| 桥接日志 `hit max_points cap` | 不出现 | 出现说明体素太细或场景太大 |
| 两端 `rate` 一致 | 差值 < 3% | **PC 端低 = 链路丢帧；两端一样低 = 狗端没发出来** |

---

## 5. 画面卡但带宽只用了 1%？查这五条

1. **RViz 渲染跟不上**（有线场景下最常见）

   累积地图到 150 万点以后，RViz 每次刷新都要重传整份顶点，CPU 单核吃满。
   处置：显示项的点大小 2 px → 1 px；`publish_rate` 1.0 → 0.5；
   或干脆用 `tools/render_cloud.py` 离屏渲染。

2. **累加器内存涨太快**

   `voxel_leaf=0.15`、50 秒到 157 万点 / 25.6 MB 是正常的；但如果 PC 内存小于 8 GB，
   把 `voxel_leaf` 调到 0.20，或调低 `max_points` 触发更频繁的全局去重。

3. **狗端 CPU 打满**（LIO 抢不到核）

   `edge_control.sh status` 看负载；`top` 看 `fastlio2_mapping` 是否 >100%。
   确认 `taskset -c 0-3` 生效，并跑过 `nvpmodel -m 0 && jetson_clocks`。

4. **DDS 重传堆积**（物理层有问题但还没断）

   `link_probe.sh` 看丢包与抖动：有线正常是 **0% / 0.08 ms**，
   一旦出现丢包，先查网线、水晶头、交换机端口，而不是调参数。

5. **PC 网卡选错 / 走错出口**

   多网卡机器上 CycloneDDS 可能绑到 Wi-Fi。`link_probe.sh` 第 1 节会打印
   "到 192.168.123.18 走: enp131s0"，以及协商速率是否为 1000 Mbit/s。

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
