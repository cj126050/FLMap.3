// flmap_bridge_node.cpp
//
// Edge-side bridge: take FAST-LIO2's full-resolution registered cloud and turn it into
// a wireless-friendly stream.
//
// Why this node exists
// --------------------
// FAST-LIO2 publishes `/cloud_registered` as `pcl::PointXYZINormal`
// (x,y,z,pad,intensity,pad,normal[3],pad,curvature,pad = 48 B/point). With Mid360 at
// ~200k points/s (point_filter_num=1 -> ~20k points/frame @10 Hz) that is roughly
// 9.6 MB/s ≈ 77 Mbit/s of payload. A 5 GHz Wi-Fi link can survive that in a quiet lab,
// but it collapses the moment anyone else shares the channel, and every lost UDP
// fragment triggers a reliable-QoS retransmission storm.
//
// This node does three cheap things on the edge (where the data is already in cache):
//   1. voxel-grid downsample  (default 0.20 m)      -> typically 4-8x fewer points
//   2. repack to x,y,z,intensity (16 B/point)       -> 3x smaller per point
//   3. rate limit (default 5 Hz)                    -> 2x fewer messages
//
// Net effect for a typical indoor scan: ~77 Mbit/s -> ~3-6 Mbit/s. See
// docs/bandwidth-tuning.md for the numbers and the knobs.
//
// Deliberately dependency-free: only rclcpp + sensor_msgs, no PCL / Eigen / OpenMP.
// That keeps it buildable on the Go2 dock (Jetson Orin Nano, ROS 2 Foxy) and on a PC
// (ROS 2 Humble) without any version gymnastics.
//
// Author: FLMap.2 contributors
// License: BSD-3-Clause

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/point_cloud2.hpp>
// 刻意不 include point_cloud2_iterator.hpp：本文件全部按 point_step 手算偏移，
// 不使用 PointCloud2(Const)Iterator，原因见 onCloud() 里的注释。

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace flmap
{

// Accumulator for one voxel. We average instead of "first point wins" because the
// averaged centroid is visibly cleaner on thin structures (railings, chair legs)
// at the same bandwidth cost.
struct VoxelAcc
{
  float x = 0.0F;
  float y = 0.0F;
  float z = 0.0F;
  float i = 0.0F;
  std::uint32_t n = 0;
};

class BridgeNode : public rclcpp::Node
{
public:
  BridgeNode()
  : rclcpp::Node("flmap_bridge")
  {
    input_topic_ = declare_parameter<std::string>("input_topic", "/cloud_registered");
    output_topic_ = declare_parameter<std::string>("output_topic", "/flmap/cloud");
    voxel_leaf_ = declare_parameter<double>("voxel_leaf", 0.10);
    max_rate_hz_ = declare_parameter<double>("max_rate_hz", 10.0);
    // 允许比目标周期早 15% 发布。为什么要容差：真实链路（以及 Wi-Fi 抖动下的输入）
    // 帧间隔并不是均匀的。若严格用"间隔 >= 周期"判定，输入抖动时大量帧会被拒绝，
    // 实际输出频率会明显低于设定值（实测输入 7.5 Hz 抖动、目标 5 Hz 时只有 2.9 Hz）。
    // 加容差后等价于一个带信用额度的限流器，输出能贴着目标频率走。
    rate_tolerance_ = declare_parameter<double>("rate_tolerance", 0.85);
    max_points_ = declare_parameter<int>("max_points", 60000);
    range_min_ = declare_parameter<double>("range_min", 0.5);
    range_max_ = declare_parameter<double>("range_max", 40.0);
    keep_intensity_ = declare_parameter<bool>("keep_intensity", true);
    stats_period_ = declare_parameter<int>("stats_period", 60);  // frames between log lines
    // 调试开关：>0 时在发布前把前 3 个点的原始字节打进日志，用于排查打包问题。
    debug_dump_ = declare_parameter<int>("debug_dump", 0);

    // QoS 必须两端成对匹配。实测（CycloneDDS 0.10 / Humble）：
    //   发布 RELIABLE + 订阅 BEST_EFFORT  -> 收不到任何数据（不是"降级"，是压根不匹配）
    // FAST-LIO2 的 /cloud_registered 默认就是 RELIABLE，所以输入侧默认 reliable。
    // 输出侧也用 reliable：33 kB × 5 Hz 的重传代价远小于"RViz 默认按 Reliable 订阅却看不见"的坑。
    // 链路很差时可两边一起改成 best_effort（同时把 RViz 显示项的 Reliability Policy 也改掉）。
    input_reliability_ = declare_parameter<std::string>("input_reliability", "reliable");
    output_reliability_ = declare_parameter<std::string>("output_reliability", "reliable");

    if (voxel_leaf_ <= 0.0) {
      RCLCPP_WARN(get_logger(), "voxel_leaf <= 0 is invalid, falling back to 0.20 m");
      voxel_leaf_ = 0.20;
    }
    if (max_rate_hz_ <= 0.0) {
      max_rate_hz_ = 5.0;
    }
    min_period_ = 1.0 / max_rate_hz_;
    leaf_inv_ = 1.0 / voxel_leaf_;

    // Best-effort 适合丢包无所谓的实时可视化；reliable 则是为了和上下游严格匹配。
    // 见上面 input_reliability_ 的注释。
    auto sub_qos = makeQos(input_reliability_);
    auto pub_qos = makeQos(output_reliability_);

    sub_ = create_subscription<sensor_msgs::msg::PointCloud2>(
      input_topic_, sub_qos,
      std::bind(&BridgeNode::onCloud, this, std::placeholders::_1));
    pub_ = create_publisher<sensor_msgs::msg::PointCloud2>(output_topic_, pub_qos);

    grid_.reserve(1U << 15);

    RCLCPP_INFO(
      get_logger(),
      "flmap_bridge: %s -> %s | voxel %.2f m | <= %.1f Hz (tol %.2f) | <= %d pts | range %.1f-%.1f m | qos %s->%s",
      input_topic_.c_str(), output_topic_.c_str(), voxel_leaf_, max_rate_hz_, rate_tolerance_,
      max_points_, range_min_, range_max_, input_reliability_.c_str(), output_reliability_.c_str());
  }

private:
  void onCloud(const sensor_msgs::msg::PointCloud2::ConstSharedPtr msg)
  {
    // ---- 1. rate limit first: cheapest possible rejection -------------------
    const rclcpp::Time now = this->now();
    if (have_published_ && (now - last_pub_).seconds() < min_period_ * rate_tolerance_) {
      ++skipped_by_rate_;
      return;
    }

    if (msg->width * msg->height == 0U) {
      return;
    }

    const bool has_intensity = hasFloat32Field(*msg, "intensity") && keep_intensity_;

    // ---- 2. voxel accumulate ------------------------------------------------
    // 这里刻意不用 sensor_msgs::PointCloud2ConstIterator 的 operator[]。
    //
    // 坑：operator[] 的语义是「从当前指针起第 i 个元素」，实现就是 *(data_ + i)，
    // 步长是 sizeof(T)（float 就是 4 B），**不是 point_step**。只有 operator++
    // 才按 point_step 前进。把它当随机访问数组用（ix[idx] / iy[idx] / iz[idx]），
    // 读到的就是"错开一个 float"的相邻分量：
    //     输入点 k = (x, y, z, i)
    //     ix[k] iy[k] iz[k] ii[k] 实际读到 (上一分量, 上一分量, 上一分量, x_k)
    //
    // 这种错误的隐蔽之处：消息头完全自洽（point_step / row_step / len(data) 全对），
    // RViz 也照常出图，只是整片点云的分量互相串位、几何被搅乱。从"有没有数据、
    // 频率对不对"完全看不出来，必须看数值分布才能发现。
    //
    // 所以这里直接按 point_step 手算偏移 + memcpy 取 4 字节：行为确定、不依赖任何
    // 迭代器语义，也顺便保持了这个包的"零 PCL / 零 Eigen"风格。
    grid_.clear();
    std::uint32_t kept = 0;
    std::uint32_t capped = 0;

    const std::uint32_t step = msg->point_step;
    const std::uint32_t off_x = fieldOffset(*msg, "x");
    const std::uint32_t off_y = fieldOffset(*msg, "y");
    const std::uint32_t off_z = fieldOffset(*msg, "z");
    const std::uint32_t off_i = fieldOffset(*msg, "intensity");

    const std::size_t total = static_cast<std::size_t>(msg->width) * msg->height;
    const std::size_t need = total * static_cast<std::size_t>(step);
    if (off_x == kNoField || off_y == kNoField || off_z == kNoField ||
      step < 16U || msg->data.size() < need)
    {
      RCLCPP_WARN_THROTTLE(
        get_logger(), *get_clock(), 5000,
        "skip: layout not usable (step=%u len=%zu need=%zu, x/y/z offsets %u/%u/%u)",
        step, msg->data.size(), need, off_x, off_y, off_z);
      return;
    }

    const float r2_min = static_cast<float>(range_min_ * range_min_);
    const float r2_max = static_cast<float>(range_max_ * range_max_);
    const std::uint8_t * base_ptr = msg->data.data();

    // 输入侧自检：印出真实读到的前 3 个点，用于和上游工具（ros2 topic echo 等）对照。
    if (debug_dump_ > 0 && frame_count_ < 2) {
      std::string s;
      char buf[200];
      std::snprintf(
        buf, sizeof(buf), "DEBUG input: %ux%u step=%u row_step=%u len=%zu\n",
        static_cast<unsigned>(msg->width), static_cast<unsigned>(msg->height),
        static_cast<unsigned>(msg->point_step), static_cast<unsigned>(msg->row_step),
        msg->data.size());
      s += buf;
      for (std::size_t k = 0; k < 3 && k < total; ++k) {
        const std::uint8_t * p = base_ptr + k * step;
        std::snprintf(
          buf, sizeof(buf), "  in[%zu] x=%.3f y=%.3f z=%.3f i=%.3f\n", k,
          loadF32(p + off_x), loadF32(p + off_y), loadF32(p + off_z),
          has_intensity ? loadF32(p + off_i) : -1.0F);
        s += buf;
      }
      RCLCPP_INFO(get_logger(), "%s", s.c_str());
    }

    for (std::size_t idx = 0; idx < total; ++idx) {
      const std::uint8_t * p = base_ptr + idx * step;
      const float x = loadF32(p + off_x);
      const float y = loadF32(p + off_y);
      const float z = loadF32(p + off_z);
      if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) {
        continue;
      }
      const float r2 = x * x + y * y + z * z;
      if (r2 < r2_min || r2 > r2_max) {
        continue;
      }

      const std::int64_t kx = static_cast<std::int64_t>(std::floor(x * leaf_inv_));
      const std::int64_t ky = static_cast<std::int64_t>(std::floor(y * leaf_inv_));
      const std::int64_t kz = static_cast<std::int64_t>(std::floor(z * leaf_inv_));
      const std::int64_t key = packKey(kx, ky, kz);

      auto it = grid_.find(key);
      if (it == grid_.end()) {
        if (static_cast<int>(grid_.size()) >= max_points_) {
          ++capped;
          continue;
        }
        VoxelAcc acc;
        acc.x = x;
        acc.y = y;
        acc.z = z;
        acc.i = has_intensity ? loadF32(p + off_i) : 0.0F;
        acc.n = 1;
        grid_.emplace(key, acc);
      } else {
        VoxelAcc & acc = it->second;
        acc.x += x;
        acc.y += y;
        acc.z += z;
        if (has_intensity) {
          acc.i += loadF32(p + off_i);
        }
        ++acc.n;
      }
      ++kept;
    }

    if (grid_.empty()) {
      return;
    }

    // ---- 3. repack ----------------------------------------------------------
    // 写入侧同样不用 sensor_msgs::PointCloud2Modifier / PointCloud2Iterator：
    // 四个迭代器各持一个 data_ 指针、靠 ++ 同步推进，读代码时很难一眼确认四路
    // 是不是始终对齐；一旦某个环节让某个指针多走一步，落盘的就是旋转错位的元组，
    // 而消息头依旧自洽。这里改成自己算偏移、每点 memcpy 16 字节，读写对称、可验证。
    // （回归测试见 tools/diag/run_bridge_selftest.sh）
    auto out = std::make_unique<sensor_msgs::msg::PointCloud2>();
    out->header = msg->header;          // keep frame_id (usually "camera_init")
    out->header.stamp = now;            // publish time, not sensor time
    out->height = 1;
    out->width = static_cast<std::uint32_t>(grid_.size());
    out->is_bigendian = false;
    out->is_dense = true;
    out->point_step = kPointStep;

    out->fields.reserve(4);
    setField(out->fields, "x", 0);
    setField(out->fields, "y", 4);
    setField(out->fields, "z", 8);
    setField(out->fields, "intensity", 12);

    out->row_step = out->point_step * out->width;
    out->data.resize(static_cast<std::size_t>(out->row_step) * out->height, 0U);

    std::uint8_t * dst = out->data.data();
    for (const auto & kv : grid_) {
      const VoxelAcc & acc = kv.second;
      const float inv_n = 1.0F / static_cast<float>(acc.n);
      const float quad[4] = {
        acc.x * inv_n,
        acc.y * inv_n,
        acc.z * inv_n,
        has_intensity ? acc.i * inv_n : 0.0F};
      std::memcpy(dst, quad, kPointStep);   // 16 B，不依赖对齐
      dst += kPointStep;
    }

    // 自检：把内存里真正的字节打出来，用来区分"写循环写错了"和"发布/序列化被动过"。
    if (debug_dump_ > 0 && frame_count_ < 2) {
      std::string s;
      char buf[64];
      const auto & d = out->data;
      for (std::size_t k = 0; k < 3 && (k + 1) * out->point_step <= d.size(); ++k) {
        float v[4];
        std::memcpy(v, d.data() + k * out->point_step, 16);
        std::snprintf(buf, sizeof(buf), "  [%zu] %.1f %.1f %.1f %.1f\n", k, v[0], v[1], v[2], v[3]);
        s += buf;
      }
      RCLCPP_INFO(
        get_logger(), "DEBUG pre-publish: %zu pts  point_step=%u  data=%zu B\n%s",
        grid_.size(), out->point_step, d.size(), s.c_str());
    }

    pub_->publish(std::move(out));

    last_pub_ = now;
    have_published_ = true;
    ++frame_count_;

    // ---- 4. periodic reporter (for docs/bandwidth-tuning.md) ----------------
    if (stats_period_ > 0 && frame_count_ % static_cast<std::uint64_t>(stats_period_) == 0) {
      const double bytes = static_cast<double>(grid_.size()) * 16.0;
      const double kbps = bytes * max_rate_hz_ * 8.0 / 1000.0;
      RCLCPP_INFO(
        get_logger(),
        "in %zu pts -> out %zu pts (%.1f%%), ~%.0f kB/msg, ~%.1f Mbit/s @%.1f Hz%s",
        total, grid_.size(), 100.0 * static_cast<double>(grid_.size()) / static_cast<double>(total),
        bytes / 1000.0, kbps / 1000.0, max_rate_hz_,
        capped > 0 ? " [hit max_points cap]" : "");
    }
  }

  // 21 bits per axis, offset by 2^20 -> covers +-1.05e6 voxels (~+-200 km @0.2 m).
  static std::int64_t packKey(std::int64_t x, std::int64_t y, std::int64_t z)
  {
    constexpr std::int64_t kOffset = 1LL << 20;
    return ((x + kOffset) << 42) | ((y + kOffset) << 21) | (z + kOffset);
  }

  // 每个点 4 个 float32 = 16 B，x/y/z/intensity 依次排在 0/4/8/12。
  static constexpr std::uint32_t kPointStep = 16U;
  static constexpr std::uint32_t kNoField = 0xFFFFFFFFU;

  // 4 字节未对齐读取。不能直接 cast 成 float*，sensor_msgs 的 data 只保证字节对齐。
  static inline float loadF32(const std::uint8_t * p)
  {
    float v;
    std::memcpy(&v, p, sizeof(float));
    return v;
  }

  static std::uint32_t fieldOffset(
    const sensor_msgs::msg::PointCloud2 & msg, const std::string & name)
  {
    for (const auto & f : msg.fields) {
      if (f.name == name && f.datatype == sensor_msgs::msg::PointField::FLOAT32) {
        return f.offset;
      }
    }
    return kNoField;
  }

  static void setField(
    std::vector<sensor_msgs::msg::PointField> & fields,
    const std::string & name, std::uint32_t offset)
  {
    sensor_msgs::msg::PointField f;
    f.name = name;
    f.offset = offset;
    f.datatype = sensor_msgs::msg::PointField::FLOAT32;
    f.count = 1;
    fields.push_back(f);
  }

  static bool hasFloat32Field(
    const sensor_msgs::msg::PointCloud2 & msg, const std::string & name)
  {
    for (const auto & f : msg.fields) {
      if (f.name == name) {
        return f.datatype == sensor_msgs::msg::PointField::FLOAT32;
      }
    }
    return false;
  }

  static rclcpp::QoS makeQos(const std::string & reliability)
  {
    rclcpp::QoS qos(rclcpp::KeepLast(1));
    if (reliability == "best_effort" || reliability == "besteffort") {
      qos.best_effort();
    } else {
      qos.reliable();
    }
    return qos.durability_volatile();
  }

  // parameters
  std::string input_topic_;
  std::string output_topic_;
  double voxel_leaf_ = 0.20;
  double max_rate_hz_ = 5.0;
  double rate_tolerance_ = 0.85;
  int max_points_ = 20000;
  double range_min_ = 0.5;
  double range_max_ = 40.0;
  bool keep_intensity_ = true;
  int stats_period_ = 60;
  int debug_dump_ = 0;
  std::string input_reliability_ = "reliable";
  std::string output_reliability_ = "reliable";

  // derived
  double min_period_ = 0.2;
  double leaf_inv_ = 5.0;

  // state
  std::unordered_map<std::int64_t, VoxelAcc> grid_;
  rclcpp::Time last_pub_;
  bool have_published_ = false;
  std::uint64_t frame_count_ = 0;
  std::uint64_t skipped_by_rate_ = 0;

  rclcpp::Subscription<sensor_msgs::msg::PointCloud2>::SharedPtr sub_;
  rclcpp::Publisher<sensor_msgs::msg::PointCloud2>::SharedPtr pub_;
};

}  // namespace flmap

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<flmap::BridgeNode>());
  rclcpp::shutdown();
  return 0;
}
