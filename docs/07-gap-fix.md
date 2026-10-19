# 断流鲁棒性修复说明（gap-fix）

## 问题现象

使用 FAST-LIO2 对 Livox Mid360 数据建图时，在某个时刻会出现**点云向某一方向移动的畸变**——在 RViz 里表现为整幅点云像被"甩出去"一样加速飞走，轨迹发散，无法完成完整建图。

## 根因分析（已实证）

通过对真实数据的逐帧分析，定位到根因是**雷达 + IMU 数据流的同步断档**：

1. **数据流周期性断档**：bag 或实时传输中，雷达和 IMU 会**同时停止输出**约 1~1.3 秒（录制丢帧、网络抖动、SD 卡写入卡顿等）。
2. **跨断档的错误积分**：FAST-LIO2 的 `UndistortPcl` 传播循环用相邻两个 IMU 采样做中值积分。跨过断档时，两个采样之间的 `dt` 会变成整段断档时长（约 1.3s），一步积分就把**重力残差**和断档期的真实运动积成了数 m/s 的虚假速度。
3. **EKF 无法自恢复**：断档后有效特征点骤减，激光匹配拉不回来，速度越积越大，位姿发散。

实测证据：里程计位姿突跳**精确**对齐断流时刻（如 39.70s 处单帧跳 2.23m，73.56s 处跳 5.16m 后彻底发散，96 秒"走了"1273 米）。

## 修复方案（三处改动）

### 1. 断档检测 + 协方差膨胀（核心修复）

文件：`src/FAST_LIO2_ROS2/src/IMU_Processing.cpp`，`UndistortPcl` 积分循环内。

```cpp
/**** [gap-fix] 数据流中断保护 ****/
if (dt > 0.2)
{
    printf("[IMU][gap-fix] stream gap %.3f s -> hold pose, zero vel, inflate cov\n", dt);
    vel_imu.setZero();
    dt = 0.0;
    state_inout.cov.block<3, 3>(3, 3).diagonal().array() += 1.0; // 位置方差 +1 m^2
    state_inout.cov.block<3, 3>(7, 7).diagonal().array() += 4.0; // 速度方差 +4 (m/s)^2
}
```

检测相邻 IMU 采样的 `dt > 0.2s` 即判定断档，做三件事：
- **不跨断档积分**（`dt = 0.0`）：位姿保持不动；
- **速度清零**（`vel_imu.setZero()`）：避免虚假速度累积；
- **膨胀协方差**：位置 +1 m²、速度 +4 (m/s)²，明确告诉 EKF"这段不可信"，让断档后的激光匹配主导状态估计。

> **关键教训**：只清零速度、不膨胀协方差会**破坏 EKF 一致性**——实测速度从 24s 起指数发散到 21 m/s。膨胀协方差这一步必不可少。

### 2. 速度护栏（最后防线）

文件：`src/FAST_LIO2_ROS2/src/LIVMapper.cpp`，`stateEstimationAndMapping()` 之后。

```cpp
/**** [vel-guard] 速度护栏 ****/
{
    const double v_max = 3.0;
    const double vn = _state.vel_end.norm();
    if (vn > v_max)
    {
        _state.vel_end *= v_max / vn;
        printf("[LIO][vel-guard] |v|=%.2f m/s > %.1f, clamped\n", vn, v_max);
    }
}
```

手持/移动机器人（Go2 等）真实速度远低于 3 m/s，超限只可能是估计发散，直接钳制。

### 3. 删除调试打印（附带修复）

文件：`src/FAST_LIO2_ROS2/src/voxel_map.cpp`。

原代码每次迭代把 `feats_down_body_` 全部点打印到 stdout，90 秒产生 100+ MB 日志，且用 `feats_down_body_->size()` 索引 `pv_list_`（后者只 resize 到 `feats_down_size_`）存在越界隐患。已注释删除。

## 修复效果

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 最大速度 | 发散到 20+ m/s | 1.91 m/s（真实步速） |
| 单帧位移跳变 | 2~5 m（多次） | 全程 < 0.5 m，0 次 |
| 速度护栏触发 | — | 0 次（无需触发即稳定） |
| 轨迹范围 | 1273 m（发散） | ~6×7 m（闭环回起点） |

## 已知盲区与边界

1. **96 点冻结时间戳占位帧**：某些采集端在断流期间持续发送固定 96 点、时间戳冻结的占位帧，这些帧会打断 IMU 积分循环，把大 `dt` 分割成小段，**绕过 0.2s 阈值**。此时 gap-fix 只对"雷达帧也恰好断"的少数情况生效。若遇到此类数据，需在**雷达帧层面**检测（连续同 timestamp 或点数骤降即判占位帧并丢弃 + 重置 IMU buffer）。

2. **高度（z 轴）漂移**：严重断流下重力方向可能被污染，导致 z 轴漂移。根治需额外的高度约束（如 z 轴零速更新 ZUPT）。

3. **实时直连无断流**：网线直连雷达的实时场景（本工程主推用法）实测无断流，gap-fix / vel-guard 零触发，稳定性最好。

## 参考

- 相关分析脚本与数据见本仓库 `scripts/` 及历史提交记录。
- 原始 FAST-LIO2：https://github.com/hku-mars/FAST_LIO
