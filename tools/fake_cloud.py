#!/usr/bin/env python3
"""fake_cloud.py —— 没有雷达也能压测 /cloud_registered 链路

模拟 FAST-LIO2 的输出特征，用来在 PC 上验证 flmap_bridge 的降采样比与带宽：

  * 点格式：48 B/点（对齐 pcl::PointXYZINormal 的点步长，x,y,z,intensity,normal*）
  * 点数：默认 20000 点/帧（Mid360 200k 点/s ÷ 10 Hz，point_filter_num=1）
  * 频率：默认 10 Hz（FAST-LIO2 的雷达帧率）
  * 几何：8x8x3 m 房间的墙面 + 地面 + 随机杂点，保证体素内有多个点，
          这样降采样才有意义（否则一个体素一个点，降不下来）

用法:
    source /opt/ros/humble/setup.bash
    python3 tools/fake_cloud.py --points 20000 --rate 10
"""

import argparse
import math

import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from sensor_msgs.msg import PointCloud2, PointField

# 48 B/点：x,y,z | pad | intensity | pad | normal_x,normal_y,normal_z | pad | curvature | pad
POINT_STEP = 48
FIELDS = [
    PointField(name='x', offset=0, datatype=PointField.FLOAT32, count=1),
    PointField(name='y', offset=4, datatype=PointField.FLOAT32, count=1),
    PointField(name='z', offset=8, datatype=PointField.FLOAT32, count=1),
    PointField(name='intensity', offset=16, datatype=PointField.FLOAT32, count=1),
    PointField(name='normal_x', offset=32, datatype=PointField.FLOAT32, count=1),
    PointField(name='normal_y', offset=36, datatype=PointField.FLOAT32, count=1),
    PointField(name='normal_z', offset=40, datatype=PointField.FLOAT32, count=1),
    PointField(name='curvature', offset=44, datatype=PointField.FLOAT32, count=1),
]


def make_room(n_points: int, seed: int = 0) -> np.ndarray:
    """生成一个 8x8x3 m 房间的点（世界系，z 向上）。"""
    rng = np.random.default_rng(seed)
    half, height = 4.0, 3.0
    per = n_points // 5
    pts = []

    # 四面墙
    for axis, sign in ((0, -1), (0, 1), (1, -1), (1, 1)):
        p = rng.uniform(-half, half, (per, 3))
        p[:, 2] = rng.uniform(0.0, height, per)
        p[:, axis] = sign * half
        pts.append(p)

    # 地面
    p = rng.uniform(-half, half, (n_points - 4 * per, 3))
    p[:, 2] = 0.0
    pts.append(p)

    cloud = np.vstack(pts).astype(np.float32)
    cloud += rng.normal(0.0, 0.01, cloud.shape).astype(np.float32)  # 1 cm 噪声
    return cloud


class FakeCloud(Node):
    def __init__(self, points: int, rate: float):
        super().__init__('fake_cloud')
        qos = QoSProfile(
            reliability=ReliabilityPolicy.RELIABLE,   # 与 FAST-LIO2 的 /cloud_registered 一致
            history=HistoryPolicy.KEEP_LAST,
            depth=5,
        )
        self.pub = self.create_publisher(PointCloud2, '/cloud_registered', qos)
        self.pts = make_room(points)
        self.frame = 0

        # 预建 12 个 float 的缓冲，每帧只改 x/y/z 与 intensity
        self.buf = np.zeros((self.pts.shape[0], POINT_STEP // 4), dtype=np.float32)
        self.buf[:, 0:3] = self.pts
        self.buf[:, 4] = np.random.default_rng(1).uniform(0, 255, self.pts.shape[0])
        self.buf[:, 6:9] = (0.0, 0.0, 1.0)  # 法向随便给个值，桥接节点不读

        # 关键：负载预序列化。否则每帧现算 960 KB 的 tobytes()，Python 只能跑到
        # 7.5 Hz 左右，压测结果会被源端拖累，误判成桥接节点限流失效。
        self.payload = self.buf.tobytes()

        self.timer = self.create_timer(1.0 / rate, self.tick)
        self.get_logger().info(
            f'fake_cloud: {self.pts.shape[0]} 点/帧 @ {rate:.1f} Hz, '
            f'{POINT_STEP} B/点 -> {self.pts.shape[0] * POINT_STEP * rate / 1e6:.1f} MB/s'
        )

    def tick(self):
        msg = PointCloud2()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = 'camera_init'
        msg.height = 1
        msg.width = self.pts.shape[0]
        msg.fields = FIELDS
        msg.is_bigendian = False
        msg.point_step = POINT_STEP
        msg.row_step = POINT_STEP * msg.width
        msg.is_dense = True
        msg.data = self.payload
        self.pub.publish(msg)
        self.frame += 1


def main():
    ap = argparse.ArgumentParser(description='合成 /cloud_registered 点云用于压测')
    ap.add_argument('--points', type=int, default=20000, help='每帧点数')
    ap.add_argument('--rate', type=float, default=10.0, help='发布频率 Hz')
    args = ap.parse_args()

    rclpy.init()
    node = FakeCloud(args.points, args.rate)
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
