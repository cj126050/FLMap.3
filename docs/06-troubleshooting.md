# 06 · 故障排查

> 按症状查。每条都是「判据 → 原因 → 处置」，不用从头读。
> 链路问题先用 `./scripts/link_probe.sh` 定位到层，再回来查对应条目。

---

## 快速索引

| 症状 | 跳到 |
|---|---|
| RViz 一片空白 | [§1](#1-rviz-一片空白) |
| 有画面但卡顿 / 掉帧 | [§2](#2-有画面但卡顿--掉帧) |
| 点云突然朝一个方向飞走 | [§3](#3-点云突然朝一个方向飞走) |
| 位姿慢慢漂 / 地图重影 | [§4](#4-位姿漂--地图重影) |
| 地图不增长 / 只在原地转 | [§5](#5-地图不增长) |
| PC 端内存一直涨 | [§6](#6-pc-端内存一直涨) |
| 时间戳相关报错 | [§7](#7-时间戳报错) |
| 狗端起不来 / 编译失败 | [§8](#8-狗端编译与启动失败) |
| ssh / 部署失败 | [§9](#9-ssh-与部署失败) |
| 搜不到机器狗热点 / App 连不上 | [§10](#10-搜不到机器狗热点--app-连不上) |
| 扫描输出看不懂，怕是隐藏网络 | [§10.1](#101-扫描结果怎么读避免误判成隐藏网络) |
| 改过 SSID 后热点彻底消失 | [§10.2](#102-情况③改过-ssid-后再也搜不到) |

---

## 1. RViz 一片空白

**判据**：RViz 起来了，Displays 面板没有红色报错，但什么都没有。

按顺序排除（每步都有明确结论，别跳）：

```bash
# ① 狗端到底在发吗？（在狗端执行）
ros2 topic hz /flmap/cloud            # 有 5 Hz → 狗端正常，问题在链路/PC
                                      # 无输出 → 看 §8

# ② PC 能看到这个 topic 吗？
ros2 topic list | grep flmap
                                      # 看不到 → DDS 发现失败，看 02 文档 §4/§6
                                      # 看得到 → 继续

# ③ PC 能收到数据吗？（这里最容易踩 QoS）
python3 tools/bench_bridge.py --topic /flmap/cloud --seconds 5
                                      # 有 frames → 数据到了，问题在 RViz 配置
                                      # frames=0 → QoS 不匹配，看下面
```

**QoS 不匹配**是最常见的原因。表现：`topic list` 有、`topic info` 有 publisher、
但订阅端一帧收不到。确认两侧可靠性一致：

```bash
ros2 topic info /flmap/cloud -v | grep -A3 "QoS profile"
```

狗端 `output_reliability` 与 PC 端 `input_reliability` 必须相同；
RViz 显示项的 `Reliability Policy` 也要与发布端相同。详见
[02-network-and-dds.md §4.2](02-network-and-dds.md#42-qos-对照表重要)。

**RViz 配置问题**：确认 `Fixed Frame` 是 `camera_init`。如果 Displays 里显示
`No transform from [camera_init]`，说明 Fixed Frame 写错或点云的 frame_id 不叫这个：

```bash
ros2 topic echo /flmap/cloud --field header.frame_id --once
```

---

## 2. 有画面但卡顿 / 掉帧

**判据**：`bench_bridge.py` 测出的 rate 明显低于 `max_rate_hz`。

先分清是"狗端没发够"还是"链路丢了"：

```bash
# 狗端
grep "in .* pts" /tmp/flmap_edge/bridge.log | tail -3    # 看 @5.0 Hz 是否达到
ros2 topic hz /flmap/cloud                                # 本机订阅，不受链路影响
```

| 狗端本机 | PC 端 | 结论 |
|---|---|---|
| 5 Hz | 5 Hz | 正常，卡顿来自 RViz 渲染或 PC 性能 |
| 5 Hz | 2–3 Hz | **链路丢帧** → 见下面三条 |
| 2–3 Hz | 2–3 Hz | 狗端输出就不够 → 输入帧率低或限流失效 |

链路丢帧的处置顺序：

1. **关 Wi-Fi 省电**（最常见，占一半以上）

   ```bash
   sudo iw dev wlan0 set power_save off
   iw dev wlan0 link                       # 看 signal 与 bitrate
   ```

2. **换 5 GHz**。2.4 GHz 在办公室几乎必然拥堵。

3. **降参数**。`voxel_leaf:=0.3 max_rate_hz:=3.0`，见 [05](05-bandwidth-tuning.md)。

4. **确认没有中间设备**。Mesh 中继、VPN、代理都会让 UDP 抖动放大。

---

## 3. 点云突然朝一个方向飞走

**判据**：RViz 里整幅点云像被"甩出去"一样加速飞走，轨迹发散，之后再也回不来。

这是 **雷达/IMU 数据流断档** 导致的经典发散：跨断档的一次 IMU 积分把 1 秒多的
重力残差积成了几 m/s 的虚假速度，EKF 拉不回来。

本仓库的 FAST-LIO2 已经带了三处修复（见 [07-gap-fix.md](07-gap-fix.md)），
如果仍然复现，按顺序查：

```bash
# ① 是不是网络/供电导致的断流？
ros2 topic hz /livox/lidar        # 应稳定 10 Hz，不能出现 >0.5 s 的空档
ping -c 100 192.168.123.20        # 雷达链路丢包？应 0%

# ② 狗端 CPU 是否打满（打满会丢帧）
top -b -n1 | head -12
sudo nvpmodel -q                  # 是否 15W 模式
sudo jetson_clocks --show         # 频率是否解锁

# ③ 是不是在数据集上本来就有断档（回放时）
ros2 bag info ~/bags/xxx/scan     # 看 duration 与消息数是否对得上
```

> 断档本身不可怕，**可怕的是断档后 EKF 还在相信旧速度**。修复补丁做的就是
> "检测到 dt > 0.2 s 就跳过积分、零速、膨胀协方差"，让下一次激光匹配重新把位姿拉回来。

---

## 4. 位姿漂 / 地图重影

**判据**：静止时点云缓慢旋转或平移；走一圈回来墙面有两层（重影）。

| 原因 | 判据 | 处置 |
|---|---|---|
| 外参不准 | 重影主要在一个方向上，且随距离线性增大 | 重新标定 `extrin_calib/extrinsic_T` / `_R` |
| 时间不同步 | 快速旋转时重影明显，慢速时不明显 | 检查 IMU 与雷达时间基准（见 §7） |
| 静止漂移 | 完全静止也在动 | 正常现象，FAST-LIO2 静止漂移量级 cm 级；若 >10 cm 检查 IMU 噪声参数 |
| 场景退化 | 长走廊 / 空旷大厅 | 加约束或降速通过，属 LIO 固有限制 |

静止漂移的参考值：本仓库在 Mid360 上实测**静止 20 秒漂移约 2 cm**，属正常。
超过 10 cm 就要查 `imu/acc_cov`、`imu/gyr_cov` 是否与实际 IMU 匹配。

---

## 5. 地图不增长

**判据**：`/flmap/cloud` 有数据，但 `/flmap/map` 一直很小或不变化。

```bash
# 累加器在跑吗？
ros2 node list | grep accumulator

# 它收到数据了吗？看它的报告行（每 10 秒一行）
# [flmap_accumulator] 地图 812345 点 | 累计接收 1902334 点 | 内存 13.0 MB
#                     ^^ 这个数不涨 = 收不到
```

| 现象 | 原因 | 处置 |
|---|---|---|
| "累计接收"不涨 | 输入 QoS 不匹配 | 见 §1 |
| "累计接收"涨、"地图"不涨 | 触到 `max_points` 上限且去重后仍满 | 调大 `max_points` 或调粗 `voxel_leaf` |
| 两者都涨但 RViz 不更新 | RViz 显示项 Disabled / Decay Time 设成了小值 | 勾选 Enabled，Decay Time 设 0 |

---

## 6. PC 端内存一直涨

**判据**：`flmap_accumulator` 的 RSS 随时间线性增长，几十分钟后吃掉几个 GB。

设计上是有上限的（`max_points` 默认 200 万 ≈ 32 MB 数据 + numpy 开销）。
如果涨得远超这个量级：

```bash
# 看实际点数
ros2 topic echo /flmap/map --field width --once
```

| 现象 | 原因 | 处置 |
|---|---|---|
| width 卡在 200 万不再涨，但 RSS 仍在涨 | 去重后 `first` 索引保序但数组未释放 | 已知问题，重启累加器即可；不是泄漏扩大 |
| width 远超 `max_points` | 参数没生效（节点名不匹配） | 确认 yaml 顶层的键就是 `/flmap_accumulator` |
| RSS 稳定在几十 MB | 正常 | 200 万点 ≈ 32 MB 数据 + 索引，属预期 |

---

## 7. 时间戳报错

**判据**：RViz 里出现 `message is too old`、`Detected jump back in time`，
或者 bag 回放时点云不显示。

根因几乎总是**狗端没有 RTC**（断电后时间回到镜像构建日）。

```bash
# 两端对比
date                # 狗端
date                # PC 端
```

差超过 1 秒就校时：

```bash
# 狗端
sudo date -s "$(ssh <PC用户>@<PC_IP> 'date -u "+%Y-%m-%d %H:%M:%S UTC"')"
```

顺序很重要：**先校时，再启动 LIO**。运行中跳时会在点云时间戳上留下断口，
RViz 会直接丢帧。

另外确认 `use_sim_time`：

```bash
ros2 param get /fastlio2_mapping use_sim_time     # 实时跑必须是 false
```

---

## 8. 狗端编译与启动失败

| 报错 | 原因 | 处置 |
|---|---|---|
| `Could not find a package configuration file provided by "sophus"` | 没打 Foxy 补丁 | `bash scripts/patch_foxy.sh ~/flmap_ws` |
| `pcl_ros` 找不到 | Foxy 上包名不同 | 同上（补丁会删这个依赖） |
| `tf2_geometry_msgs.hpp: No such file` | Humble 才有的文件名 | 同上 |
| `undefined symbol: _ZN3tbb...` / PCL 链接错误 | Foxy 不传递 PCL/Boost 依赖 | 同上（补丁会插入显式链接块） |
| `kLivoxLidarTypeMid360s` 未声明 | 板上 SDK2 版本较老 | 同上（补丁会去掉该分支） |
| `colcon build` 报 `catkin_pkg` 找不到 | 用了 pyenv/conda 的 python3 | `export PATH=/usr/bin:$PATH` 后再编 |
| 编译过但 `ros2 launch` 说找不到 launch 文件 | 没 `source install/setup.bash` | 每个新终端都要 source |
| `fastlio2_mapping` 起了但不出图 | `use_sim_time` 默认 true，在等 `/clock` | 加 `use_sim_time:=false` |

启动后自检：

```bash
ros2 node list                      # 应有 livox_ros_driver2 / fastlio2_mapping / flmap_bridge
ros2 topic hz /cloud_registered     # 应约 10 Hz
ros2 topic hz /flmap/cloud          # 应约 5 Hz
```

---

## 9. ssh 与部署失败

| 现象 | 处置 |
|---|---|
| `ssh: connect to host ... No route to host` | 不在同一网段；`ip route get <狗IP>` 看走哪个网卡 |
| `Permission denied (publickey)` | `ssh-copy-id unitree@<狗IP>` |
| `Host key verification failed` | 狗的 IP 变了：`ssh-keygen -R <狗IP>` |
| `deploy_edge.sh` 卡在 rsync | 狗端磁盘满（`df -h`），或 Wi-Fi 太差换有线部署 |
| rsync 后狗端编译失败 | 用了 `--no-patch` 但之前没打过补丁；去掉该参数重跑 |
| 部署后行为没变 | 狗端旧进程还在跑：`pkill -f fastlio2_mapping` 后重启 |

---

## 10. 搜不到机器狗热点 / App 连不上

这是脱离线缆后最常见的卡点：改过 WiFi 名称，结果手机和 PC 都搜不到那个名字。
先分清 App 里填的到底是**哪种**名字——两种机制完全不同，改错地方就会变成"谁也连不上"。

| App 里的设置项 | 实际含义 | 后果 |
|---|---|---|
| 热点 / AP 名称 | 机器狗自己广播的 SSID | 改名后模块要重启才生效，期间仍广播旧名字 |
| 中继 / 自定义网络（STA） | 机器狗**作为客户端**去连的路由器 | 填了它，机器狗自己的热点会关掉，转而去连那个网络 |

**判据 → 原因 → 处置**

| 判据 | 原因 | 处置 |
|---|---|---|
| 遥控器能控制，但手机/PC 搜不到任何相关 SSID | 热点被设成隐藏，或名字没生效 | `sudo ./scripts/wifi_scan_report.sh` 看有没有 `<隐藏或空>` 条目；**先查该条目的 MAC 厂商**，是 TP-LINK/华硕/小米就与狗无关 |
| 扫到 `Go2_xxxxxx` 这类出厂名 | 改的名字没生效 | 连旧名进去重改，改完**必须重启机器人** |
| 扫不到任何强信号 AP（1 m 内应 ≥ −50 dBm） | 热点没起来，或已被切成 STA 模式 | 断电静置 10 s 再上电，等 **2 分钟**再扫（WiFi 模块启动比主控慢） |
| App 里填的名字恰好是**手机热点名** | 机器狗在连你的手机，不是在自己发热点 | 把手机热点开起来、名字设成该值，等 1 分钟让狗连上，再用 App 改回 AP 模式 |
| 能搜到但连不上 | 连接名额被占（遥控器/另一台手机） | 关掉遥控器，只留一台设备再连 |
| 只有 5 GHz 设备能搜到 | 热点跑在高信道（165 以上）或 6 GHz | PC 网卡在 `CN` 域可用 2.4G ch1–13 / 5G ch36–64 与 ch149–165；超出的扫不到 |

> ⚠️ 改完 SSID 不重启，是这类问题最常见的原因。模块不会热加载配置。

### 10.1 扫描结果怎么读（避免误判成「隐藏网络」）

`wifi_scan_report.sh` 的输出里有三个坑，看错方向就会白折腾一晚上：

| 看到的 | 真实含义 |
|---|---|
| `\x00\x00…`（十六组零） | 路由在探测响应里塞的 0x00 填充，**不是隐藏网络**。旧版脚本会把它算进情况②，已剔除 |
| `<隐藏或空>` 只有一两条，且 MAC 前缀查出是 TP-LINK / ASUSTek / 小米 / 华为 | 邻居家的隐藏路由。狗底壳或电池仓有 MAC 贴纸，前缀对不上就直接排除 |
| 隐藏条目的 MAC 第一字节是 `x2 / x6 / xA / xE`（本地管理位 = 1） | **不能据此排除。** 实测 Go2 自己的热点就是 `7a:22:88:af:9d:29`，也是本地管理地址（所以 OUI 查不到厂商是正常的）。这条只用来解释"为什么查不到牌子"，判据还得看名字和信号 |
| 隐藏条目信号 ≤ −70 dBm | 狗就在你脚边，1 m 内不可能这么弱。直接排除 |
| 扫到 40+ 个 AP，却没有任何 `GO2-` / `Unitree-` / 纯 11 位数字的 SSID | 情况③：**AP 根本没广播**。此时不要再去「添加隐藏网络」里试，试也是白试 |

判定顺序是：**先认名字 → 再看 MAC 厂商（查得出牌子且是家用路由才排除）→ 最后才轮到"隐藏"这个假设**。因为隐藏只改变广播行为，不改变"模块得先活着"这件事；而 OUI 只能证明"芯片是谁造的"，**证明不了"这台是不是你的狗"**。

### 10.2 情况③：改过 SSID 后再也搜不到

热点彻底不广播，只有两个真实原因，症状几乎一样：

| 症状 | 原因 |
|---|---|
| 改过 SSID/密码 → 重启 → 名字消失，改名之前一切正常 | hostapd 配置没写成功。Go2 热点密码是**8 位**，把 11 位手机号填进密码框时，App 可能只在名称那一步显示成功 |
| 断电重启后依然不广播 | 模块卡在 STA 模式，一直在找那个不存在的网络 |

**恢复顺序（从轻到重，前两步不用碰硬件）**

0. **先用蓝牙当试金石**（10 秒判断模块死活）：
   App 添加设备时是靠**蓝牙**发现狗的。蓝牙能列出这台狗 → Wi-Fi/BT 是同一颗模组，
   模组活着，问题**只在 hostapd 配置**，直接走第 2 步；
   蓝牙也扫不到 → 模组没上电或已损坏，才轮到第 3 步恢复出厂 / 送修。
1. **先排除遥控器**：长按遥控器电源键 2 s 关机，等 3 min 再扫一次。
   官方文档明确写了遥控器和 App 不能同时控制狗，两者会抢同一个连接名额。
2. **蓝牙重新配网**（推荐，不动其它设置）：
   App → 删除/解绑设备 → 添加设备（开手机蓝牙）→ 选 **AP 模式** → 重设热点名 + 8 位数字密码。
   首次绑定本来就是走蓝牙下发 AP 配置的，所以热点不存在时这条路依然通。
   配完先把手机 Wi-Fi 断开再扫，别被缓存的旧名字骗了。
3. **物理恢复出厂**（背面 reset 按钮）：
   关机状态**长按 reset 不放** → 电池短按 + 长按 2 s 上电 → 头部**黄灯闪**时松开 → 等绿灯（约 30 min）。
   要求电量 ≥ 3 格、狗趴好。之后热点回到 `GO2-XXXXXX`，所有自定义设置清空。
4. **有线兜底**：网线接拓展坞能通 `192.168.123.18` / `.161`，但 AP 由运控侧提供，
   没有运控密码就改不了它的 hostapd —— 所以第 2、3 步才是主路。

---

## 11. 出问题时的信息采集

提 issue 时带上这些，能省掉来回问：

```bash
# 两端各跑一次
./scripts/link_probe.sh > link.txt 2>&1
ros2 topic list > topics.txt
ros2 topic info /flmap/cloud -v > qos.txt
uname -a; echo $ROS_DISTRO $ROS_DOMAIN_ID $RMW_IMPLEMENTATION

# 狗端额外
tail -50 /tmp/flmap_edge/{driver,mapping,bridge}.log
```

> 本仓库的 `env_check.sh` 也会输出一份环境摘要。
