#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
render_cloud.py —— 不开 RViz 也能看图：抓一帧点云渲染成 PNG

用途
----
* 服务器 / 无显示器环境验证链路（RViz 要 OpenGL，很多远程环境起不来）
* 写文档、发 issue 时附一张真实数据截图
* 快速判断"点云形状对不对"，比盯着 RViz 转半天快

依赖: numpy, matplotlib, sensor_msgs_py（ROS 2 自带）

用法
----
    python3 tools/render_cloud.py                          # 默认 /flmap/cloud
    python3 tools/render_cloud.py -t /flmap/map            # 累积地图
    python3 tools/render_cloud.py -t /cloud_registered --range 15
    python3 tools/render_cloud.py -o docs/images/frame.png --view top

    # 需要先 source ROS 环境并设置 ROS_DOMAIN_ID
"""

import argparse
import sys
import time

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from sensor_msgs.msg import PointCloud2
from sensor_msgs_py import point_cloud2


class Grabber(Node):
    def __init__(self, topic):
        super().__init__('render_cloud_grabber')
        self.msg = None
        qos = QoSProfile(depth=5, history=HistoryPolicy.KEEP_LAST,
                         reliability=ReliabilityPolicy.RELIABLE)
        self.create_subscription(PointCloud2, topic, self._cb, qos)

    def _cb(self, m):
        self.msg = m


def grab(topic, timeout):
    rclpy.init()
    node = Grabber(topic)
    t0 = time.time()
    while node.msg is None and time.time() - t0 < timeout:
        rclpy.spin_once(node, timeout_sec=0.3)
    msg = node.msg
    node.destroy_node()
    rclpy.shutdown()
    return msg


def to_arrays(msg):
    """用官方 API 解析，别手搓 byte offset —— 手搓极易把 y/z 读错位。"""
    names = [f.name for f in msg.fields]
    fields = [n for n in ('x', 'y', 'z', 'intensity') if n in names]
    rec = np.array(list(point_cloud2.read_points(
        msg, field_names=tuple(fields), skip_nans=True)))
    if rec.size == 0:
        return None
    x, y, z = rec['x'], rec['y'], rec['z']
    inten = rec['intensity'] if 'intensity' in fields else None
    return x, y, z, inten


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-t', '--topic', default='/flmap/cloud')
    ap.add_argument('-o', '--out', default='cloud.png')
    ap.add_argument('--range', type=float, default=0.0,
                    help='只保留该半径内的点（0 = 不过滤）。室内建议 15-20')
    ap.add_argument('--view', choices=['both', 'top', '3d'], default='both')
    ap.add_argument('--timeout', type=float, default=15.0)
    ap.add_argument('--zmax', type=float, default=0.0, help='3D 视图的 Z 轴上限（0 = 自动）')
    args = ap.parse_args()

    print('等待 %s（最多 %.0f 秒）…' % (args.topic, args.timeout))
    msg = grab(args.topic, args.timeout)
    if msg is None:
        print('✗ 没收到数据。检查：ROS_DOMAIN_ID 是否一致、狗端节点是否在跑、'
              'DDS 是否绑到了正确的网卡', file=sys.stderr)
        return 1

    got = to_arrays(msg)
    if got is None:
        print('✗ 点云为空', file=sys.stderr)
        return 1
    x, y, z, inten = got
    raw_n = x.size

    r = np.sqrt(x * x + y * y + z * z)
    if args.range > 0:
        keep = r < args.range
        x, y, z, r = x[keep], y[keep], z[keep], r[keep]
        if inten is not None:
            inten = inten[keep]

    print('话题          : %s' % args.topic)
    print('frame_id      : %s' % msg.header.frame_id)
    print('字段 / 点步长 : %s / %d B' % (','.join(f.name for f in msg.fields), msg.point_step))
    print('点数          : %d%s' % (x.size, '' if x.size == raw_n else ' (原 %d，已按 %.0fm 裁掉离群点)' % (raw_n, args.range)))
    if x.size == 0:
        print('✗ 过滤后没有点', file=sys.stderr)
        return 1
    print('X 范围        : %7.2f .. %7.2f m' % (x.min(), x.max()))
    print('Y 范围        : %7.2f .. %7.2f m' % (y.min(), y.max()))
    print('Z 范围        : %7.2f .. %7.2f m' % (z.min(), z.max()))
    print('距离 p5/50/95 : %.2f / %.2f / %.2f m' % tuple(np.percentile(r, [5, 50, 95])))

    if args.view == 'both':
        fig = plt.figure(figsize=(15, 6.4))
        ax1 = fig.add_subplot(1, 2, 1)
        ax2 = fig.add_subplot(1, 2, 2, projection='3d')
    elif args.view == 'top':
        fig = plt.figure(figsize=(8, 7.6))
        ax1 = fig.add_subplot(1, 1, 1)
        ax2 = None
    else:
        fig = plt.figure(figsize=(9, 7.6))
        ax1 = None
        ax2 = fig.add_subplot(1, 1, 1, projection='3d')

    if ax1 is not None:
        ax1.set_facecolor('#0d0d0d')
        sc = ax1.scatter(x, y, c=z, s=1.2, cmap='viridis', linewidths=0)
        ax1.set_title('Top view (X-Y), color = height Z')
        ax1.set_xlabel('X [m]')
        ax1.set_ylabel('Y [m]')
        ax1.set_aspect('equal', 'box')
        ax1.grid(alpha=0.2, color='gray')
        plt.colorbar(sc, ax=ax1, shrink=0.85, label='Z [m]')

    if ax2 is not None:
        idx = np.arange(x.size)
        if x.size > 20000:
            idx = np.random.choice(x.size, 20000, replace=False)
        ax2.scatter(x[idx], y[idx], z[idx], c=z[idx], s=0.5, cmap='viridis', linewidths=0)
        ax2.set_title('3D view')
        ax2.set_xlabel('X [m]')
        ax2.set_ylabel('Y [m]')
        ax2.set_zlabel('Z [m]')
        if args.zmax > 0:
            ax2.set_zlim(0, args.zmax)

    plt.tight_layout()
    plt.savefig(args.out, dpi=140, facecolor='white')
    print('已保存        : %s' % args.out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
