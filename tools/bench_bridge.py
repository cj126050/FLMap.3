#!/usr/bin/env python3
"""bench_bridge.py —— 量测一条点云话题的真实带宽 / 帧率 / 点数

用于验证 flmap_bridge 的效果，也可以直接对着狗端的 /flmap/cloud 测真实链路：

    python3 tools/bench_bridge.py                       # 默认测 /flmap/cloud，10 秒
    python3 tools/bench_bridge.py --topic /cloud_registered --seconds 5

输出示例:
    topic=/flmap/cloud  frames=50  rate=5.0 Hz
    points/frame avg=6123  max=7402
    payload 1901 kB/s  ->  15.2 Mbit/s
"""

import argparse
import statistics
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from sensor_msgs.msg import PointCloud2


class Bench(Node):
    def __init__(self, topic: str, reliable: bool = False):
        super().__init__('bench_bridge')
        qos = QoSProfile(
            reliability=ReliabilityPolicy.RELIABLE if reliable else ReliabilityPolicy.BEST_EFFORT,
            history=HistoryPolicy.KEEP_LAST,
            depth=1,
        )
        self.samples = []
        self.create_subscription(PointCloud2, topic, self.cb, qos)
        self.topic = topic

    def cb(self, msg: PointCloud2):
        self.samples.append((time.time(), msg.width * msg.height, len(msg.data)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--topic', default='/flmap/cloud')
    ap.add_argument('--seconds', type=float, default=10.0)
    ap.add_argument('--best-effort', action='store_true',
                    help='用 BEST_EFFORT 订阅（默认 RELIABLE，与 flmap_bridge 输出一致）')
    args = ap.parse_args()

    rclpy.init()
    node = Bench(args.topic, not args.best_effort)
    t0 = time.time()
    while time.time() - t0 < args.seconds:
        rclpy.spin_once(node, timeout_sec=0.1)

    s = node.samples
    if len(s) < 2:
        print(f'topic={args.topic}  收到 {len(s)} 帧 —— 没数据，检查 publisher 是否在跑 / QoS 是否匹配')
        node.destroy_node()
        rclpy.shutdown()
        return

    span = s[-1][0] - s[0][0]
    pts = [x[1] for x in s]
    total_bytes = sum(x[2] for x in s)
    print(f'topic={args.topic}  frames={len(s)}  rate={len(s) / span:.1f} Hz')
    print(f'points/frame avg={statistics.mean(pts):.0f}  max={max(pts)}')
    print(f'payload {total_bytes / span / 1000:.0f} kB/s  ->  {total_bytes * 8 / span / 1e6:.1f} Mbit/s')

    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()
