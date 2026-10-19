# 02 · 有线组网与 DDS 配置

> **这一篇是"连不上时第一个看"的地方。** 全篇只讲有线 —— FLMap.3 的整个前提就是
> PC、狗、雷达三者用网线挂到同一台交换机上。

---

## 1. 拓扑

```
                    ┌──────────────┐
                    │   千兆交换机   │
                    └──┬────┬────┬──┘
           ┌───────────┘    │    └───────────┐
           │                │                │
    ┌──────┴──────┐  ┌──────┴──────┐  ┌──────┴──────┐
    │  PC         │  │ Go2 拓展坞   │  │ Livox Mid360│
    │ 192.168.123 │  │ 192.168.123 │  │ 192.168.123 │
    │    .10      │  │    .18      │  │    .221     │
    └─────────────┘  └─────────────┘  └─────────────┘
                            │
                    （狗身内部有线）
                            │
                     ┌──────┴──────┐
                     │  运控单元    │
                     │    .161     │
                     └─────────────┘
```

三个关键事实：

1. **所有设备在同一个二层**，同一个 `192.168.123.0/24`，不需要任何路由或 NAT。
2. **雷达直接把 UDP 点云推给狗**（`56301` 端口），PC 不参与数据搬运。
3. **PC 只订阅结果话题**，不碰原始传感器数据。

这就是有线模式相对 Wi-Fi 模式最本质的区别：**没有跨网段，就少了一整类静默失败。**

## 2. 地址表

| 设备 | IP | 网卡名 | 说明 |
|---|---|---|---|
| PC | `192.168.123.10/24` | `enp131s0`（按实际） | 静态，**不设默认网关** |
| Go2 拓展坞 | `192.168.123.18/24` | `eth0` | Orin Nano，跑 FAST-LIO2 |
| Livox Mid360 | `192.168.123.221` | — | 出厂默认是 `192.168.1.1xx`，需先在 Livox Viewer 里改 |
| 运控单元 | `192.168.123.161` | — | 只做遥控，本方案不依赖它 |

> ⚠️ **雷达地址不是 `192.168.123.20`。** 很多旧笔记写 `.20`，那是早期的另一台。
> 用 `ping 192.168.123.221` 和 `arp -n` 确认：Mid360 的 MAC 前缀属于
> `SZ DJI TECHNOLOGY`（Livox 是大疆旗下）。改雷达 IP 的方法见
> [08-hardware.md](08-hardware.md)。

## 3. PC 侧网卡配置

**不要用 DHCP，也不要填默认网关。**

### 3.1 命令行（临时，重启失效）

```bash
sudo ip link set enp131s0 up
sudo ip addr replace 192.168.123.10/24 dev enp131s0
```

### 3.2 NetworkManager（持久，推荐）

```bash
sudo nmcli connection add type ethernet ifname enp131s0 con-name go2-wired \
    ipv4.method manual ipv4.addresses 192.168.123.10/24 \
    ipv4.gateway "" ipv4.dns ""
sudo nmcli connection up go2-wired
```

或者直接编辑 nmconnection：

```ini
[ipv4]
method=manual
address1=192.168.123.10/24
never-default=true
```

`never-default=true` 是这段配置里最重要的一行。

### 3.3 为什么绝对不能设默认网关

如果给 `enp131s0` 配了 `ipv4.gateway=192.168.123.1`：

- NetworkManager 会往默认路由表里插一条 `default via 192.168.123.1`
- 它和家里 Wi-Fi / 手机共享那条默认路由打架，metric 小的赢
- 赢了的话，**整个 PC 断网** —— 网页打不开、对话直接断
- 输了的话，去 `192.168.123.x` 的包可能仍走对，但任何依赖联网的操作行为不可预期

而 `192.168.123.1` 在很多车上**根本不存在**（ARP 不通，是幽灵路由）。
它是 Go2 出厂配置里写的网关，不代表真有设备在那儿。

> 判断方法：`ip route | grep default`，正常应该只有一条，走 Wi-Fi 或手机共享，
> 不该出现 `192.168.123.1`。

## 4. 链路体检

```bash
./scripts/link_probe.sh          # 四层逐级检查
```

单条命令看质量：

```bash
# 千兆？双工对不对？
cat /sys/class/net/enp131s0/speed /sys/class/net/enp131s0/duplex

# 延迟与抖动（0.5 ms / 0.1 ms 是正常值）
ping -c 20 -i 0.2 192.168.123.18
```

FLMap.3 的参考基线（2026-10-19 实测，千兆交换机）：

| 目标 | RTT avg | 抖动 mdev | 丢包 |
|---|---|---|---|
| 拓展坞 `.18` | 0.55 ms | 0.12 ms | 0 |
| 运控 `.161` | 0.52 ms | — | 0 |
| 雷达 `.221` | 0.74 ms | — | 0 |

**如果 RTT 超过 2 ms 或抖动超过 1 ms**，先查三件事：网线是不是只有百兆
（`speed` 显示 100）、有没有双工不匹配（`duplex` 不是 `full`）、交换机是不是
把三个口分在了不同的 VLAN。

## 5. DDS 配置

### 5.1 三个必须一致的东西

| 项 | 值 | 不一致的后果 |
|---|---|---|
| `ROS_DOMAIN_ID` | 两端都是 **42** | 互相看不见，`ros2 topic list` 全空 |
| RMW 实现 | 两端都用 `rmw_cyclonedds_cpp` | 节点互相发现不了（混用 FastDDS 也能通，但别混） |
| 网卡绑定 | 只在 `192.168.123.0/24` 这块上发现 | 发现包从别的网卡出去，PC 永远看不到 |

狗端 `~/.bashrc` 里应该有：

```bash
export ROS_DOMAIN_ID=42
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
```

PC 端由 `setup.sh` 写入同样的两行。

### 5.2 网卡绑定

PC 上通常有多块网卡（有线、Wi-Fi、手机 USB 共享）。CycloneDDS 默认会在
**所有网卡**上做发现，一旦它选了 Wi-Fi 那块，狗就找不到你。

```bash
# PC 上：只让 CycloneDDS 认有线口
export CYCLONEDDS_URI='<CycloneDDS><Domain><General>
  <Interfaces><NetworkInterface name="enp131s0"/></Interfaces>
</General></Domain></CycloneDDS>'
```

狗上同理，网卡名是 `eth0`。

`scripts/dds_env.sh` 会按当前机器的实际网卡名生成这段配置并 `export`，不用手写。

### 5.3 多播还是单播

**有线默认用多播，不要改。** 交换机对多播的处理是确定的，Wi-Fi 时代那些
"多播被 AP 限速/丢弃"的坑在有线上不存在。

只有当交换机做了**端口隔离**（每个口一个 VLAN，互不可见）时，才需要切单播：

```bash
# 模板在 config/cyclonedds_unicast.xml.example
export CYCLONEDDS_URI=file:///绝对路径/dds_edge.xml
```

判断是否被隔离：`ping` 通但 `ros2 node list` 看不到对方 —— 典型特征。

### 5.4 QoS 对照表

跨机器传点云，发布端和订阅端的可靠性策略必须**匹配或兼容**，否则静默丢数据：

| 话题 | 发布端 | 订阅端（RViz） |
|---|---|---|
| `/flmap/cloud` | RELIABLE | **RELIABLE** |
| `/cloud_registered` | RELIABLE | RELIABLE |
| `/aft_mapped_to_init` | RELIABLE | RELIABLE |

> RViz 的 `PointCloud2` 显示项默认是 `Best effort`，而本仓库的发布端是
> `RELIABLE`。两者**可以**互通（订阅端要求更弱即可兼容），但如果发现
> "有话题没画面"，先把 RViz 里那一项改成 `Reliable` 试一次。

## 6. 跨发行版互操作（Foxy ↔ Humble）

狗端 Ubuntu 20.04 + ROS 2 Foxy，PC 端 22.04 + Humble。RTPS 线协议兼容，
`PointCloud2` / `Odometry` / `TFMessage` 这些基础消息在实际部署中可直接互通。

前提仍是那三个一致：domain id、RMW 实现、网卡。

如果 `ping` 通、`ros2 node list` 仍然看不到对方，按顺序试：

1. 两端 `unset CYCLONEDDS_URI`，用纯默认配置试一次
2. 检查 `ROS_LOCALHOST_ONLY` 是不是被设成了 1（应该是 0 或未设置）
3. PC 上跑 Foxy 容器（`osrf/ros:foxy-desktop`，host 网络）
4. 退到离线：狗端录包，拷到 PC 上 `ros2 bag play` 看

## 7. 症状 → 处置

| 症状 | 最可能的原因 | 处置 |
|---|---|---|
| `ping .18` 不通 | 网线没插 / 交换机没电 / IP 没配上 | `cat /sys/class/net/enp131s0/carrier` 必须是 1 |
| `ping` 通但 `ros2 topic list` 空 | domain id 不一致 / RMW 不一致 / 绑错网卡 | 逐个核对 §5.1 |
| 只看到自己的节点 | 多播被隔离，或 `ROS_LOCALHOST_ONLY=1` | §5.3、`env \| grep ROS_` |
| 有话题但 RViz 没画面 | QoS 不匹配 / Fixed Frame 不是 `map` / 时间戳过期 | 先改 Reliable，再查 Fixed Frame |
| RViz 报 `Message Filter dropping message` | **两端时钟差太多** | 见 [09-time-sync.md](09-time-sync.md) |
| 点云显示但位置飘 | 雷达外参 / 时间戳不同步 | [08-hardware.md](08-hardware.md)、[07-gap-fix.md](07-gap-fix.md) |
| PC 整个断网 | 给有线口设了默认网关 | §3.3，删掉网关 |

## 8. 和 Wi-Fi 模式比，省掉了什么

[FLMap.2](https://github.com/cj126050/FLMap.2) 走 Wi-Fi，要处理：狗的 AP 模式与
STA 模式切换、跨网段路由、NAT 与回程路由、多播被 AP 限速、省电模式导致的
30+ ms 抖动、信道干扰。

有线模式下这一整列问题**不存在**：

| Wi-Fi 要处理的 | 有线 |
|---|---|
| 跨网段 `12.x ↔ 123.x` | 同网段，没有 |
| 运控要不要转发 / 要不要 NAT | 不经过运控，无关 |
| 多播被 AP 丢弃 | 交换机正常转发 |
| `power_save` 让抖动飙到 40 ms | 抖动稳定在 0.1 ms |
| ch149 和邻居路由打架 | 没有共享介质 |
| 狗端没有射频，得插 USB 网卡 | 网口本来就有 |

代价只有一个：**狗被线拴住了**。室内固定场地建图、跑数据集、调参，
这个代价可以接受；要狗满屋跑，回去用 FLMap.2。
