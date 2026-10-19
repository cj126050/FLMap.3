# Fast-LIO2 常见问题排查（Go2 + Mid360）

本文档针对 **go2_fastlio** 包：建图/定位中的常见现象与处理，以及 RViz 建图、保存地图的说明。

**目录**

- [effective feature num: 0、average residual: -nan](#effective-feature-num-0average-residual--nan)
- [点云倾斜（不与地面平行）](#点云倾斜不与地面平行)
- [建图漂移（同一墙面重叠/重影）](#建图漂移同一墙面重叠重影)
- [在 RViz 中看建图过程](#在-rviz-中看建图过程)
- [如何保存地图](#如何保存地图)

---

## effective feature num: 0、average residual: -nan

**含义**：当前帧与体素地图没有匹配到有效点，位姿主要靠 IMU 递推，容易漂移。

按下面顺序逐项检查和处理。

---

### 1. 静止启动（必做）

- **启动前**：把狗放在地上，**不要移动、不要抬起来**，先启动 livox_ros_driver2，再启动 Fast-LIO2。
- **启动后**：保持静止约 **10–20 秒**，让系统完成：
  - IMU 初始化、重力方向估计
  - 首帧点云建图，体素内平面拟合
- 若一起动就动狗，首帧位姿和地图都不准，后续会一直「有效点为 0」。

---

### 2. 环境要有结构

- 需要**墙面、桌沿、门框、家具棱角**等平面/边缘，室内或结构化室外效果更好。
- **空旷平地、单一平面、透明/反光占多数**时，点云难以形成可靠平面，容易 effective feature 一直为 0。
- 尽量让雷达周围 **2–10 m** 内有明显结构。

---

### 3. 时间同步（IMU 与 LiDAR）

- 若终端出现 **“IMU and LiDAR not synced! delta time: …”** 和 **“HARD time lag is …”**，必须做时间对齐。
- 在本包 `config/mid360_go2.yaml` 里修改：
  - `time_offset/imu_time_offset` 设为终端打印的 **HARD time lag** 数值（例如 `2.012`）。
- 改完后重启 Fast-LIO2，再看是否还有 not synced 和 effective feature 0。

---

### 4. 外参（LiDAR 与 IMU）

- 当前配置里是 Mid360 的**默认/近似外参**，若雷达相对 IMU 有安装偏差，会导致点云和地图对不齐，有效点很少。
- **建议**：用 **LiDAR_IMU_Init** 标定外参和时间偏移，再写回本包 `config/mid360_go2.yaml`：
  - 仓库：<https://github.com/hku-mars/LiDAR_IMU_Init>
  - 标定完成后，把得到的 `extrinsic_T`、`extrinsic_R`（以及若提供 `Rcl`/`Pcl`）更新到：
    - `extrin_calib/extrinsic_T`
    - `extrin_calib/extrinsic_R`
    - `extrin_calib/Rcl`、`extrin_calib/Pcl`

---

### 5. 参数微调（仍为 0 时）

在本包 `config/mid360_go2.yaml` 中可尝试：

| 参数 | 作用 | 建议 |
|------|------|------|
| `lio/sigma_num` | 点-面匹配距离容忍倍数 | 有效点为 0 时可从 4 调到 **4.5 或 5**（过大会引入误匹配） |
| `lio/min_eigen_value` | 体素内平面判定阈值，越小越容易成平面 | 可尝试从 0.0025 降到 **0.002** |
| `preprocess/filter_size_surf` | 降采样体素大小 | 从 0.2 改为 **0.15** 可保留更多点（算力允许时） |
| `preprocess/blind` | 盲区距离(m) | Mid360 约 0.2–0.5，若近距离有结构可适当减小 |

修改后重启 Fast-LIO2 再观察终端里的 **“Raw feature num / downsampled / effective feature num”**。

---

## 点云倾斜（不与地面平行）

**现象**：点云整体倾斜，地面、墙面与 RViz 中的水平网格不平行，Z 轴不竖直。

**原因**：多为 **外参不准** 或 **IMU 重力方向初始化不佳**；少数为时间同步偏差。

**排查与修正步骤（按顺序执行）**：

### 1. 静止启动（必做）

- 启动前：狗子放在**平地上**，不移动、不抬起。
- 先启动 livox_ros_driver2，再启动 Fast-LIO2。
- 启动后：**静止 15–20 秒**，让 IMU 完成重力方向估计和首帧建图。
- 若一起动就动狗，重力方向会偏，整张图会倾斜。

### 2. 核对 IMU 与 LiDAR 时间

- 若终端有 **“IMU and LiDAR not synced!”** 和 **“HARD time lag is …”**，必须做时间对齐。
- 将 `config/mid360_go2.yaml` 中 `time_offset/imu_time_offset` 设为终端打印的 **HARD time lag** 数值（如 `2.012`）。
- 改完后重启 Fast-LIO2 再试。

### 3. 用 LiDAR_IMU_Init 标定外参

若前两步无误仍倾斜，建议用 **LiDAR_IMU_Init** 标定 LiDAR–IMU 外参和时间偏移。

- **仓库**：<https://github.com/hku-mars/LiDAR_IMU_Init>
- **说明**：LiDAR_IMU_Init 使用 **ROS1**，需要单独建 ROS1 工作空间；标定结果可写回本项目的 ROS2 配置。
- **详细步骤**：见 [LIDAR_IMU_INIT_CALIBRATION.md](../../scripts/LIDAR_IMU_INIT_CALIBRATION.md)

标定完成后，将得到的 `extrinsic_R`、`extrinsic_T`、`imu_time_offset` 更新到 `config/mid360_go2.yaml`，重启建图验证。

---

### 6. 检查话题与数据

- 确认雷达和 IMU 话题与配置一致（默认 `/livox/lidar`、`/livox/imu`），若有 remap 以 launch 为准。
- 在 RViz 中确认：
  - 有**连续的点云**（`/cloud_registered` 等）
  - 点云**不是空**、**不是明显错位/扭曲**。
- 若点云很少或异常，先排查 livox_ros_driver2 的配置与连接。

### 小结（effective feature 为 0 时）

1. **静止启动** + 启动后静止 10–20 秒。  
2. **有结构的环境**。  
3. 按终端 **HARD time lag** 设置 `time_offset/imu_time_offset`。  
4. 必要时用 **LiDAR_IMU_Init** 标定外参并更新配置。  
5. 仍为 0 时微调 `lio/sigma_num`、`lio/min_eigen_value` 等。  

若以上都做到且环境合适，effective feature num 应会逐渐增加，平均残差会变为正常数值。

---

## 建图漂移（同一墙面重叠/重影）

**现象**：同一面墙或同一物体在点云里出现两条/多条、重叠或错开，说明轨迹有漂移。

**原因简述**：Fast-LIO2 是**纯里程计**（无回环），误差会随时间/距离累积；匹配过松或时间/外参不准会加重漂移。

**可做措施**（按优先级）：

1. **收紧匹配与体素（当前配置已偏向减漂移）**  
   在 `config/mid360_go2.yaml` 中已设：
   - `lio/sigma_num: 3.5`（原 4.0 更松易重影；若 effective feature 明显变少可改回 4.0）
   - `lio/voxel_size: 0.4`（体素更细、平面更准）
   - `lio/max_iterations: 6`、`preprocess/filter_size_surf: 0.18`  
   若仍漂移明显，可再试：`sigma_num: 3.0`、`voxel_size: 0.35`（注意 effective feature 别掉太多）。

2. **核对 IMU 与 LiDAR 时间**  
   若 `imu_time_offset` 不准，会带来系统性漂移。按终端 “HARD time lag” 把 `time_offset/imu_time_offset` 设准。

3. **核对 LiDAR–IMU 外参**  
   外参偏差会直接导致旋转/平移漂移，建议用 [LiDAR_IMU_Init](https://github.com/hku-mars/LiDAR_IMU_Init) 标定后写回 `extrin_calib/*`。

4. **建图习惯**  
   - 启动后静止 10–20 秒再动。  
   - 尽量在**有墙、门框、家具**的结构化环境建图，避免长走廊来回或长时间无结构。  
   - 走得太快、转弯太猛会加大漂移。

5. **根本限制**  
   无回环时，长距离/大范围建图**必然**会漂移。若必须做大场景一致地图，需要考虑带回环的系统（如 LIO-SAM、FAST-LIO + 后处理回环）或分段建图后人工/算法拼接。

---

## 在 RViz 中看建图过程

- **一键启动**：用 `mapping_with_rviz.launch.py` 会同时启动 Fast-LIO2 和 RViz，默认配置已针对建图做了优化。
- **Registered Cloud**：话题 `/cloud_registered` 显示当前帧在世界系下的点云。RViz 里该显示的 **Decay Time** 已设为 **120 秒**，即会保留最近 2 分钟内的点，随着狗子移动你会看到点云不断累积，形成“地图在长出来”的效果。
- **Trajectory**：`/path` 显示历史轨迹，**Odometry**（`/aft_mapped_to_init`）显示当前位姿朝向。
- **想看更长时间的累积**：在 RViz 左侧选中 “Registered Cloud” → 将 **Decay Time** 调大（如 300、600），或改为 **0** 表示不衰减（会一直保留所有点，建图时间很长时注意内存）。
- **视角**：用 **Focus Camera** 对准某一帧或 **Orbit** 旋转查看，**Fixed Frame** 为 `camera_init`（与 Fast-LIO 一致）。

---

## 如何保存地图

Fast-LIO2 自带按帧累积点云，**在节点退出时（Ctrl+C）** 可把整段建图保存为 PCD 文件。

### 方式一：退出时保存一整张图（推荐）

1. **打开保存开关**  
   编辑本包 `config/mid360_go2.yaml`，将：
   - `pcd_save/pcd_save_en` 改为 **true**
   - `pcd_save/interval` 保持 **-1**（表示不按间隔分片，只在退出时保存）

2. **保证输出目录存在**  
   首次保存前执行（路径为 Fast-LIO2 源码下的 Log）：
   ```bash
   mkdir -p /home/wzy/go2w_slam_ws/src/FAST_LIO2_ROS2/Log/PCD
   ```

3. **正常建图**  
   启动 Fast-LIO2（可配合 RViz），建图跑完后在运行 Fast-LIO 的终端里 **Ctrl+C** 结束节点。

4. **查看结果**  
   退出后会自动写入：
   - `src/FAST_LIO2_ROS2/Log/PCD/all_raw_points.pcd` — 原始累积点云  
   - `src/FAST_LIO2_ROS2/Log/PCD/all_downsampled_points.pcd` — 体素下采样后的点云（体积更小，适合后续定位/可视化）  

   终端会打印保存路径和点数。可把文件拷到常用目录，例如：
   ```bash
   mkdir -p ~/maps
   cp /home/wzy/go2w_slam_ws/src/FAST_LIO2_ROS2/Log/PCD/all_downsampled_points.pcd ~/maps/go2_$(date +%Y%m%d_%H%M).pcd
   ```

### 方式二：按间隔分片保存

若希望**建图过程中**每隔一段时间就存一份（方便备份或分段处理），可把：
- `pcd_save/pcd_save_en` 设为 **true**
- `pcd_save/interval` 设为**正整数**（例如 **100** 表示每 100 帧保存一次）

文件会保存到同一目录下，命名为 `1.pcd`、`2.pcd`、…。同时会生成 `scans_pos.json` 记录每段的位姿。注意：分片会清空当前缓冲，**退出时不会再生成 all_raw / all_downsampled**。

### 按 's' 保存（推荐，避免 Ctrl+C 崩溃）

本工作空间已为 Fast-LIO2 添加 `/save_map` 服务，建图时**另开终端**执行：

```bash
cd ~/go2w_slam_ws
source install/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_DOMAIN_ID=0
python3 scripts/save_map_on_key.py
```

该脚本会监听键盘：按 **s** 触发保存，按 **q** 退出。地图会保存到 `src/FAST_LIO2_ROS2/Log/PCD/all_raw_points.pcd` 与 `all_downsampled_points.pcd`。  
也可直接调用服务：`ros2 service call /save_map std_srvs/srv/Empty`。

### 参数说明（config 中）

| 参数 | 含义 |
|------|------|
| `pcd_save/pcd_save_en` | 是否开启 PCD 保存 |
| `pcd_save/interval` | -1：仅退出时保存一整张；>0：每 N 帧保存一份 |
| `pcd_save/filter_size_pcd` | 下采样体素边长(m)，仅影响 all_downsampled_points.pcd |
