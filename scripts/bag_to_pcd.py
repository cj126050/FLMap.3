#!/usr/bin/env python3
"""从 rosbag 转换 /cloud_registered 为二进制 PCD。
用法: bag_to_pcd.py <bag目录> <输出.pcd>
"""
import sys
import numpy as np
import rosbag2_py
from rclpy.serialization import deserialize_message
from rosidl_runtime_py.utilities import get_message
from sensor_msgs_py import point_cloud2 as pc2

def main():
    bag, out = sys.argv[1], sys.argv[2]
    r = rosbag2_py.SequentialReader()
    r.open(rosbag2_py.StorageOptions(uri=bag, storage_id="sqlite3"),
           rosbag2_py.ConverterOptions("cdr", "cdr"))
    types = {t.name: t.type for t in r.get_all_topics_and_types()}
    if "/cloud_registered" not in types:
        print(f"[ERROR] bag 里没有 /cloud_registered 话题，只有: {list(types.keys())}")
        sys.exit(2)
    cls = get_message(types["/cloud_registered"])
    chunks, n, frames = [], 0, 0
    while r.has_next():
        t, d, _ = r.read_next()
        if t != "/cloud_registered":
            continue
        m = deserialize_message(d, cls)
        arr = pc2.read_points(m, field_names=("x", "y", "z", "intensity"), skip_nans=True)
        a = np.stack([arr["x"], arr["y"], arr["z"], arr["intensity"]], axis=1).astype(np.float32)
        if a.size:
            chunks.append(a); n += a.shape[0]; frames += 1
    if not chunks:
        print("[ERROR] bag 中没有任何点云数据")
        sys.exit(3)
    pts = np.vstack(chunks)
    hdr = (f"# .PCD v0.7 - Point Cloud Data file format\nVERSION 0.7\nFIELDS x y z intensity\n"
           f"SIZE 4 4 4 4\nTYPE F F F F\nCOUNT 1 1 1 1\nWIDTH {n}\nHEIGHT 1\n"
           f"VIEWPOINT 0 0 0 1 0 0 0\nPOINTS {n}\nDATA binary\n").encode()
    with open(out, "wb") as f:
        f.write(hdr + pts.tobytes())
    print(f"[OK] {frames} 帧, {n} 点 -> {out}")

if __name__ == "__main__":
    main()
