#!/usr/bin/env python3
"""flmap_accumulator —— PC 端点云累加器

背景
----
狗端只发「当前这一帧」的点云（默认约 33 kB/帧 @5 Hz）。如果 RViz 直接显示这一帧，
你会看到一团跟着狗跑的局部点云，看不出建图效果；而如果把狗端整张地图发过来，
带宽又吃不消（几十 MB 且持续增长）。

解法：让 PC 自己攒地图。
    /flmap/cloud  (5 Hz, 每帧 0.2 m 体素化后的当前帧)
        -> 直接 append 到本地缓冲（PC 内存和 CPU 都富余）
        -> 以 1 Hz 重发成 /flmap/map
    RViz 里 /flmap/map 用 Decay=0 显示，就能看到地图一点点长出来。

为什么不在这里做逐帧去重
------------------------
每帧已经是 0.2 m 体素化的结果，重复点只出现在狗走回头路时，视觉上几乎看不出来。
只有当缓冲达到 max_points 上限时才做一次全局去重（np.unique），把内存压回去。
这样每帧的开销是 O(1) 的数组写入，而不是 O(n log n) 的集合运算。

谁跑这个节点：**只跑在 PC 端**，狗端不需要。
"""

import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from sensor_msgs.msg import PointCloud2, PointField


class Accumulator(Node):
    def __init__(self):
        super().__init__('flmap_accumulator')

        self.input_topic = self.declare_parameter(
            'input_topic', '/flmap/cloud').value
        self.output_topic = self.declare_parameter(
            'output_topic', '/flmap/map').value
        self.voxel_leaf = self.declare_parameter('voxel_leaf', 0.15).value
        self.publish_rate = self.declare_parameter('publish_rate', 1.0).value
        self.max_points = int(self.declare_parameter('max_points', 2000000).value)
        self.frame_id = self.declare_parameter('frame_id', 'camera_init').value
        # 必须和 flmap_bridge 的输出侧一致。实测 CycloneDDS：发布 RELIABLE 而订阅
        # BEST_EFFORT 会完全收不到数据，所以这里跟着发布端走（默认 reliable）。
        reliability = self.declare_parameter(
            'input_reliability', 'reliable').value

        # (N, 4) float32: x, y, z, intensity —— 与输出点云的内存布局完全一致，
        # 发布时 self.data[:n].tobytes() 就是现成的 payload，不需要再拷贝一次。
        self.data = np.zeros((min(200000, self.max_points), 4), dtype=np.float32)
        self.n = 0
        self.added_total = 0

        qos_in = QoSProfile(
            reliability=(ReliabilityPolicy.BEST_EFFORT
                         if reliability in ('best_effort', 'besteffort')
                         else ReliabilityPolicy.RELIABLE),
            history=HistoryPolicy.KEEP_LAST,
            depth=1,
        )
        qos_out = QoSProfile(
            reliability=ReliabilityPolicy.RELIABLE,
            history=HistoryPolicy.KEEP_LAST,
            depth=1,
        )
        self.create_subscription(PointCloud2, self.input_topic, self.on_cloud, qos_in)
        self.pub = self.create_publisher(PointCloud2, self.output_topic, qos_out)

        self.create_timer(1.0 / self.publish_rate, self.publish_map)
        self.create_timer(10.0, self.report)

        self.get_logger().info(
            f'flmap_accumulator: {self.input_topic} -> {self.output_topic} | '
            f'发布 {self.publish_rate:.1f} Hz | 上限 {self.max_points} 点'
        )

    # ------------------------------------------------------------------ 收帧
    def on_cloud(self, msg: PointCloud2):
        pts = self.extract_xyz(msg)
        if pts is None or pts.shape[0] == 0:
            return

        need = self.n + pts.shape[0]
        if need > self.max_points:
            self.dedupe()
            if self.n + pts.shape[0] > self.max_points:
                return  # 去重后仍满，丢新点，保住已建地图不抖
        if need > self.data.shape[0]:
            self.grow(need)

        self.data[self.n:self.n + pts.shape[0]] = pts
        self.n += pts.shape[0]
        self.added_total += pts.shape[0]

    @staticmethod
    def extract_xyz(msg: PointCloud2):
        """按 fields 里的偏移取 x/y/z/intensity，不假设点步长固定。"""
        offsets = {f.name: f.offset for f in msg.fields}
        if not {'x', 'y', 'z'} <= offsets.keys():
            return None
        step = msg.point_step
        n = msg.width * msg.height
        if n == 0 or step == 0:
            return None

        raw = np.frombuffer(msg.data, dtype=np.uint8)
        n = min(n, raw.size // step)
        if n == 0:
            return None
        raw = raw[:n * step].reshape(n, step)

        out = np.empty((n, 4), dtype=np.float32)
        for i, name in enumerate(('x', 'y', 'z')):
            o = offsets[name]
            out[:, i] = raw[:, o:o + 4].copy().view(np.float32).ravel()
        if 'intensity' in offsets:
            o = offsets['intensity']
            out[:, 3] = raw[:, o:o + 4].copy().view(np.float32).ravel()
        else:
            out[:, 3] = 0.0
        return out

    def grow(self, need: int):
        size = self.data.shape[0]
        while size < need and size < self.max_points:
            size = min(size * 2, self.max_points)
        new = np.zeros((size, 4), dtype=np.float32)
        new[:self.n] = self.data[:self.n]
        self.data = new

    def dedupe(self):
        """按体素做一次全局去重（只在触顶时调用，很便宜）。"""
        if self.n == 0:
            return
        pts = self.data[:self.n]
        idx = np.floor(pts[:, :3] / self.voxel_leaf).astype(np.int64) + (1 << 20)
        key = (idx[:, 0] << 42) | (idx[:, 1] << 21) | idx[:, 2]
        _, first = np.unique(key, return_index=True)
        first.sort()
        keep = pts[first]
        self.n = keep.shape[0]
        self.data[:self.n] = keep
        self.get_logger().info(f'触顶去重: -> {self.n} 点')

    # ------------------------------------------------------------------ 发图
    def publish_map(self):
        if self.n == 0:
            return
        msg = PointCloud2()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = self.frame_id
        msg.height = 1
        msg.width = self.n
        msg.fields = [
            PointField(name='x', offset=0, datatype=PointField.FLOAT32, count=1),
            PointField(name='y', offset=4, datatype=PointField.FLOAT32, count=1),
            PointField(name='z', offset=8, datatype=PointField.FLOAT32, count=1),
            PointField(name='intensity', offset=12, datatype=PointField.FLOAT32, count=1),
        ]
        msg.is_bigendian = False
        msg.point_step = 16
        msg.row_step = 16 * msg.width
        msg.is_dense = True
        msg.data = self.data[:self.n].tobytes()
        self.pub.publish(msg)

    def report(self):
        self.get_logger().info(
            f'地图 {self.n} 点 | 累计接收 {self.added_total} 点 | '
            f'内存 {self.data.nbytes / 1e6:.1f} MB'
        )


def main():
    rclpy.init()
    node = Accumulator()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == '__main__':
    main()
