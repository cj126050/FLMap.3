#!/usr/bin/env python3
"""bridge_selftest.py —— flmap_bridge 的回归测试：重打包后几何还在不在

背景
----
`flmap_bridge` 的核心动作是"读 x/y/z/intensity → 体素平均 → 重新打包"。这一步
一旦写错，消息头依然自洽（point_step=16、len(data) 正好），RViz 也照样出图，
但每个点的分量已经串位，整张地图几何被搅乱 —— 从外部极难发现。

这个测试用"每个分量自带身份"的数据打进去：

    点 k:  x = k,  y = k + 1e5,  z = k + 2e5,  intensity = k + 3e5

于是输出里任意一组四个 float 都能反查出"它原本是第几个点的哪个分量"，可以精确定位
任何串位。体素叶子取极小值（默认 1 mm）让每个点独占一个体素，平均退化为恒等映射，
所以输出必须逐个点、逐个分量都和输入一致（顺序会变，因为来自哈希表）。

用法:
    # 终端 1：起一个只用于测试的 bridge 实例
    ros2 run flmap_bridge flmap_bridge_node --ros-args \\
        -p input_topic:=/_syn_in -p output_topic:=/_syn_out \\
        -p voxel_leaf:=0.001 -p max_points:=60000 \\
        -p range_min:=0.0 -p range_max:=1000000.0

    # 终端 2：
    python3 tools/diag/bridge_selftest.py -n 5000

退出码 0 表示 100% 一致；非 0 表示存在串位，会打印坏点样本。
"""

import argparse
import struct
import sys
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import PointCloud2, PointField

BASE = (0.0, 1e5, 2e5, 3e5)
CNAME = ('x', 'y', 'z', 'i')


class Tagger(Node):
    def __init__(self, npts, in_topic, out_topic, send):
        super().__init__('bridge_selftest')
        self.npts = npts
        self.send = send
        self.sent = 0
        self.got = []
        q = QoSProfile(depth=1, history=HistoryPolicy.KEEP_LAST,
                       reliability=ReliabilityPolicy.RELIABLE)
        self.pub = self.create_publisher(PointCloud2, in_topic, q)
        self.create_subscription(PointCloud2, out_topic, self.cb, q)
        self.timer = self.create_timer(0.5, self.tick)

    def build(self):
        m = PointCloud2()
        m.header.frame_id = 'synthetic'
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
        m.data = b''.join(
            struct.pack('<4f', float(k), k + BASE[1], k + BASE[2], k + BASE[3])
            for k in range(self.npts))
        return m

    def tick(self):
        if self.sent >= self.send:
            return
        m = self.build()
        m.header.stamp = self.get_clock().now().to_msg()
        self.pub.publish(m)
        self.sent += 1

    def cb(self, msg):
        self.got.append(msg)


def tag(v):
    """把输出里的一个 float 反解成 (点号, 分量下标)；解不出返回 None。"""
    if v < 0:
        return None
    for c in (3, 2, 1, 0):
        if v >= BASE[c]:
            k = v - BASE[c]
            if abs(k - round(k)) < 1e-3:
                return (int(round(k)), c)
            return None
    return None


def main():
    ap = argparse.ArgumentParser(description='flmap_bridge 重打包正确性回归测试')
    ap.add_argument('-n', '--points', type=int, default=5000)
    ap.add_argument('--in-topic', default='/_syn_in')
    ap.add_argument('--out-topic', default='/_syn_out')
    ap.add_argument('--send', type=int, default=4, help='连发几帧')
    ap.add_argument('--timeout', type=float, default=25.0)
    args = ap.parse_args()

    rclpy.init()
    node = Tagger(args.points, args.in_topic, args.out_topic, args.send)
    t0 = time.time()
    while len(node.got) < 3 and time.time() - t0 < args.timeout:
        rclpy.spin_once(node, timeout_sec=0.2)

    if not node.got:
        print('!! 没有收到 %s 的输出。bridge 起了吗？参数对吗？' % args.out_topic)
        rclpy.shutdown()
        return 1

    msg = node.got[-1]
    npt = msg.width * msg.height
    data = bytes(msg.data)
    print('输入 %d 点 -> 输出 %d 点   step=%d  len=%d' % (
        args.points, npt, msg.point_step, len(data)))

    flat = struct.unpack_from('<%df' % (npt * 4), data, 0)
    good = 0
    bad = []
    for k in range(npt):
        quad = flat[k * 4:k * 4 + 4]
        ds = [tag(v) for v in quad]
        ok = (all(d is not None for d in ds) and
              all(d[0] == ds[0][0] for d in ds) and
              [d[1] for d in ds] == [0, 1, 2, 3])
        if ok:
            good += 1
        elif len(bad) < 5:
            bad.append((quad, ds))

    pct = 100.0 * good / max(1, npt)
    print('分量为同一整点且顺序正确的点: %d/%d = %.1f%%' % (good, npt, pct))
    for quad, ds in bad:
        print('  坏点 %s  解码=%s' % ('(' + ','.join('%.1f' % v for v in quad) + ')', ds))

    if good == npt:
        print('结论: 重打包无损 ✅')
        rclpy.shutdown()
        return 0
    print('结论: 存在串位 ❌ —— 检查读点/写点是否按 point_step 前进')
    rclpy.shutdown()
    return 1


if __name__ == '__main__':
    sys.exit(main())
