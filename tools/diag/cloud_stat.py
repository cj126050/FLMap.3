#!/usr/bin/env python3
"""cloud_stat.py —— 一眼看出点云数据有没有被写坏

为什么需要这个
--------------
点云坏掉的时候，消息头往往是"自洽"的：point_step = 16、row_step = width * 16、
len(data) = height * row_step 全部对得上，RViz 也能正常显示——只是几何形状是错的。
所以不能只看"有没有数据"，要看数值分布本身。

这个脚本只做一件事：把 PointCloud2 按 point_step 当原始字节解析，统计每一列
（x / y / z / intensity …）的最小值、最大值、均值和"恰好等于 0 / 恰好等于 1.0"
的比例。正常点云和错位点云的特征差别非常明显：

    正常   x/y/z 三轴范围各不相同，=1.0 的占比 ≈ 0
    错位   x/y/z 三轴范围几乎一样，=1.0 的占比高达 15~25%，
           相邻点还会出现 "后一点的 y 等于前一点的 x" 这种规律

刻意不用 sensor_msgs_py.point_cloud2.read_points：Foxy 上没有这个模块，而且
出问题时要排除的正是"解析工具本身"这一层。

用法:
    source /opt/ros/humble/setup.bash      # 狗端换成 foxy
    python3 tools/diag/cloud_stat.py                        # 默认 /flmap/cloud，2 帧
    python3 tools/diag/cloud_stat.py -t /flmap/map -n 1
    python3 tools/diag/cloud_stat.py -t /cloud_registered   # 48 B/点也能正确分列
"""

import argparse
import struct
import sys
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import PointCloud2

COL_NAMES = ('x', 'y', 'z', 'i', 'nx', 'ny', 'nz', 'cv')


def make_node(topic, keep, reliable):
    class Grab(Node):
        def __init__(self):
            super().__init__('cloud_stat')
            self.msgs = []
            q = QoSProfile(
                depth=5, history=HistoryPolicy.KEEP_LAST,
                reliability=ReliabilityPolicy.RELIABLE if reliable
                else ReliabilityPolicy.BEST_EFFORT)
            # 订阅创建时就把绑定方法存下来了，事后再改 self.cb 不会生效。
            self.create_subscription(PointCloud2, topic, self.cb, q)

        def cb(self, msg):
            if len(self.msgs) < keep:
                self.msgs.append(msg)

    return Grab()


def report(msg, index):
    data = bytes(msg.data)
    step = msg.point_step
    npt = msg.width * msg.height
    nf = step // 4 if step >= 4 else 0
    if nf == 0 or npt == 0:
        print('[帧 %d] 空消息' % index)
        return

    sizes_ok = (msg.row_step == msg.width * step and
                len(data) == msg.height * msg.row_step)
    print('[帧 %d] %d 点  step=%d  row_step=%d  len=%d %s' % (
        index, npt, step, msg.row_step, len(data), 'OK' if sizes_ok else '!! 尺寸不自洽'))

    need = npt * nf
    if len(data) < need * 4:
        print('  !! data 只有 %d B，按 step=%d 需要 %d B' % (len(data), step, need * 4))
        return

    arr = struct.unpack_from('<%df' % need, data, 0)
    cols = [arr[i::nf] for i in range(nf)]

    for name, col in zip(COL_NAMES, cols):
        n = float(len(col))
        zeros = 100.0 * sum(1 for v in col if v == 0.0) / n
        ones = 100.0 * sum(1 for v in col if v == 1.0) / n
        print('  %-2s: min %9.3f  max %9.3f  mean %9.3f | =0 %5.1f%%  =1.0 %5.1f%%' % (
            name, min(col), max(col), sum(col) / n, zeros, ones))

    # 错位点云最典型的指纹：后一点的 y 恰好等于前一点的 x
    xs, ys, zs = cols[0], cols[1], cols[2]
    m = min(len(xs), len(ys), len(zs)) - 1
    if m > 0:
        slide = sum(1 for i in range(m) if ys[i + 1] == xs[i] and zs[i + 1] == ys[i]) / m
        print('  错位指纹 (y[i+1]==x[i] 且 z[i+1]==y[i]): %.1f%%  %s' % (
            100.0 * slide, '← 疑似错位！' if slide > 0.05 else '(正常)'))
    print('  前 3 点: %s' % ['(' + ','.join('%.3f' % v for v in arr[i * nf:i * nf + 3]) + ')'
                            for i in range(min(3, npt))])


def main():
    ap = argparse.ArgumentParser(description='点云数值分布体检（按 point_step 原始字节解析）')
    ap.add_argument('-t', '--topic', default='/flmap/cloud')
    ap.add_argument('-n', '--frames', type=int, default=2)
    ap.add_argument('--best-effort', action='store_true', help='发布端是 best_effort 时用')
    ap.add_argument('--timeout', type=float, default=20.0)
    args = ap.parse_args()

    rclpy.init()
    node = make_node(args.topic, args.frames, not args.best_effort)
    t0 = time.time()
    while len(node.msgs) < args.frames and time.time() - t0 < args.timeout:
        rclpy.spin_once(node, timeout_sec=0.3)

    if not node.msgs:
        print('!! %.0fs 内没收到 %s（检查 ROS_DOMAIN_ID / RMW / 话题名）' % (
            args.timeout, args.topic))
        rclpy.shutdown()
        return 1

    print('topic %s | frame %s | 收到 %d 帧' % (
        args.topic, node.msgs[0].header.frame_id, len(node.msgs)))
    for i, msg in enumerate(node.msgs):
        report(msg, i)
    rclpy.shutdown()
    return 0


if __name__ == '__main__':
    sys.exit(main())
