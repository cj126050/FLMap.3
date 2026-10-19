# tools/diag —— 点云链路的诊断工具

这一组工具解决同一类问题：**话题有数据、频率正确、消息头自洽，但点云是坏的。**

完整背景和排查全过程见 [docs/10-pitfalls.md](../../docs/10-pitfalls.md)。

| 工具 | 回答什么问题 | 典型命令 |
|---|---|---|
| `dds_loopback.py` | 传输层（含跨发行版 DDS、大包分片）有没有动过 payload？ | `python3 dds_loopback.py -n 5000` |
| `cloud_stat.py` | 现在这个话题的数据分布正常吗？ | `python3 cloud_stat.py -t /flmap/cloud` |
| `bridge_selftest.py` | 串位发生在读、写、还是传输？ | 见下方"两步跑" |
| `run_bridge_selftest.sh` | 上面那步的一键版，自动起停一个隔离的 bridge 实例 | `./run_bridge_selftest.sh -n 5000` |

## 两步跑

**1. 真实数据的体检**（狗端建图中，PC 上执行）：

```bash
source /opt/ros/humble/setup.bash
export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
python3 cloud_stat.py -t /flmap/cloud -n 2
```

看三件事：

- `x / y / z` 三轴的 `min` 是不是同一个值 → 是的话几乎确定串位；
- `=1.0` 的占比 → 正常点云接近 0，串位时能到 15~25%；
- `intensity` 有没有负值 → Livox 反射率是无符号量，负数说明读错。

**2. 打包逻辑的回归测试**（改完 `flmap_bridge` 后必跑）：

```bash
./run_bridge_selftest.sh -n 5000
```

它会在独立域（`ROS_DOMAIN_ID=43`）起一个只用于测试的 bridge 实例，喂
"每个分量自带身份"的点云进去，核对输出是否 100% 对得上，退出码即结论。

```
输入 5000 点 -> 输出 5000 点   step=16  len=80000
分量为同一整点且顺序正确的点: 5000/5000 = 100.0%
结论: 重打包无损 ✅
```

## 依赖

只需要 ROS 2（Humble 或 Foxy 都行）+ rclpy + sensor_msgs。
**刻意不用** `sensor_msgs_py`（Foxy 上没有）和 numpy（只用到 `struct`），
所以狗端也能直接跑，方便在"怀疑上游"时把同一份代码放到另一端做对照。
