#!/usr/bin/env python3
"""dds_loopback.py —— 本机已知答案闭环，用来判定"到底是链路坏了还是代码坏了"

排查点云显示异常时，第一个要排除的是 DDS 自己：如果连"发布→订阅"这一层都会
改动 payload，那后面所有代码的分析都是白费。这个脚本在本机发一条数值完全已知的
PointCloud2（点 k = (k, -2k, k/2, 100+k)），再用原始字节读回来逐点比对。

三种典型结果:
    100% 一致       DDS 干净，问题在发布方的数据生成/打包逻辑
    部分点错位      大包分片重组有问题（用 -n 逐步加大点数可以定位分片阈值）
    收不到          域号 / RMW / QoS 不匹配

用法:
    python3 tools/diag/dds_loopback.py -n 50
    python3 tools/diag/dds_loopback.py -n 5000      # 80 kB，跨分片
"""

import argparse
import struct
import sys
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import PointCloud2, PointField


def expected(k):
    return (float(k), -2.0 * k, 0.5 * k, 100.0 + k)


class Loop(Node):
    def __init__(self, npts, topic):
        super().__init__('dds_loopback')
        self.npts = npts
        self.sent = 0
        self.got = None
        q = QoSProfile(depth=1, history=HistoryPolicy.KEEP_LAST,
                       reliability=ReliabilityPolicy.RELIABLE)
        self.pub = self.create_publisher(PointCloud2, topic, q)
        self.create_subscription(PointCloud2, topic, self.cb, q)
        self.timer = self.create_timer(0.2, self.tick)

    def tick(self):
        if self.sent >= 3:
            return
        m = PointCloud2()
        m.header.stamp = self.get_clock().now().to_msg()
        m.header.frame_id = 'loopback'
        m.height, m.width = 1, self.npts
        m.is_bigendian = False
        m.is_dense = True
        m.point_step, m.row_step = 16, self.npts * 16
        m.fields = [
            PointField(name='x', offset=0, datatype=PointField.FLOAT32, count=1),
            PointField(name='y', offset=4, datatype=PointField.FLOAT32, count=1),
            PointField(name='z', offset=8, datatype=PointField.FLOAT32, count=1),
            PointField(name='intensity', offset=12, datatype=PointField.FLOAT32, count=1),
        ]
        m.data = b''.join(struct.pack('<4f', *expected(k)) for k in range(self.npts))
        self.pub.publish(m)
        self.sent += 1

    def cb(self, msg):
        if self.got is None:
            self.got = msg


def main():
    ap = argparse.ArgumentParser(description='PointCloud2 本机闭环一致性验证')
    ap.add_argument('-n', '--points', type=int, default=50)
    ap.add_argument('-t', '--topic', default='/_loopback')
    ap.add_argument('--timeout', type=float, default=15.0)
    args = ap.parse_args()

    rclpy.init()
    node = Loop(args.points, args.topic)
    t0 = time.time()
    while node.got is None and time.time() - t0 < args.timeout:
        rclpy.spin_once(node, timeout_sec=0.2)

    if node.got is None:
        print('!! 本机闭环都收不到 —— 检查 ROS_DOMAIN_ID / RMW_IMPLEMENTATION / 是否同名域里已有残留')
        rclpy.shutdown()
        return 1

    msg = node.got
    data = bytes(msg.data)
    print('round-trip: %dx%d  step=%d  len=%d  payload=%d B' % (
        msg.height, msg.width, msg.point_step, len(data), args.points * 16))

    bad = 0
    for k in range(args.points):
        v = struct.unpack_from('<4f', data, k * msg.point_step)
        if any(abs(a - b) > 1e-6 for a, b in zip(v, expected(k))):
            bad += 1
            if bad <= 3:
                print('  点 %d 收到 %s 期望 %s' % (
                    k, ['%.2f' % x for x in v], ['%.2f' % x for x in expected(k)]))

    print('错位/错值 %d / %d 点' % (bad, args.points))
    print('结论: %s' % ('DDS 无损 ✅ —— 问题不在传输层' if bad == 0
                      else 'DDS 改动了 payload ❌'))
    rclpy.shutdown()
    return 0 if bad == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
