#!/usr/bin/env python3
"""
Livox Mid360 实时采集节点启动文件（ROS 2）

用途：Mid360 雷达通过网线直连本机，本节点以实时模式采集点云与 IMU，
发布 /livox/lidar (CustomMsg) 与 /livox/imu，供 fastlio2_mapping 在线建图。

前置条件：
  1. 本机有线网卡配置静态 IP 192.168.1.5/24（与 MID360_config.json 的 host_net_info 一致）
  2. 雷达目标 IP 为 192.168.1.12（见 config/MID360_config.json 的 lidar_configs.ip）
  3. 用网线直连雷达转接盒的 RJ45 口

关键参数（与 driver 源码 livox_ros_driver2.cpp / comm.h / lddc.h 对齐）：
  - data_src = 0          -> kSourceRawLidar，实时采集（2 = kSourceLvxFile 文件回放）
  - xfer_format = 1       -> kLivoxCustomMsg，Mid360 必须用 CustomMsg（0 = PointCloud2）
  - user_config_path      -> 配置文件路径（参数名是 user_config_path，不是 config_file）

可用 launch 命令行覆盖话题/帧 id 等。
"""

import os
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch_ros.actions import Node


def generate_launch_description():
    pkg_share = get_package_share_directory('livox_ros_driver2')
    config_file = os.path.join(pkg_share, 'config', 'MID360_config.json')

    driver_node = Node(
        package='livox_ros_driver2',
        executable='livox_ros_driver2_node',
        name='livox_lidar_publisher',
        output='screen',
        parameters=[
            {'data_src': 0},                  # 0 = 实时采集（raw lidar）
            {'xfer_format': 1},               # 1 = Livox CustomMsg（Mid360 必须）
            {'multi_topic': 0},
            {'publish_freq': 10.0},
            {'output_data_type': 0},          # 0 = 输出到 ROS 话题
            {'frame_id': 'livox_frame'},
            {'user_config_path': config_file},
        ]
    )

    return LaunchDescription([driver_node])
