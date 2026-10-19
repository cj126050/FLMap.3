#!/usr/bin/env python3
"""
Fast-LIO 启动文件 - Unitree Go2 + Livox Mid360

使用场景：
- 狗子 (Go2) 上已运行 livox_ros_driver2，发布 /livox/lidar 和 /livox/imu
- 本机 (VM) 通过 DDS 订阅话题并运行 Fast-LIO

若狗子话题不同，使用 remapping 或修改 config 中的话题名。
示例：ros2 launch go2_fastlio mapping_mid360_go2.launch.py lid_topic:=/custom/lidar imu_topic:=/custom/imu
"""

import os
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    pkg_share = get_package_share_directory('go2_fastlio')
    config_path = os.path.join(pkg_share, 'config', 'mid360_go2.yaml')

    # 可选：通过参数覆盖话题名
    lid_topic_arg = DeclareLaunchArgument(
        'lid_topic',
        default_value='/livox/lidar',
        description='LiDAR point cloud topic (CustomMsg)'
    )
    imu_topic_arg = DeclareLaunchArgument(
        'imu_topic',
        default_value='/livox/imu',
        description='IMU topic'
    )

    # use_sim_time：回放建图用 true，实时建图必须 false（实时数据没有 /clock）
    sim_time_arg = DeclareLaunchArgument(
        'use_sim_time',
        default_value='false',
        description='Use simulation time (true for bag replay, false for live)'
    )

    fastlio_node = Node(
        package='fast_lio2',
        executable='fastlio2_mapping',
        name='fastlio2_mapping',
        output='screen',
        parameters=[config_path,
                    {'use_sim_time': LaunchConfiguration('use_sim_time')}],
        remappings=[
            ('/livox/lidar', LaunchConfiguration('lid_topic')),
            ('/livox/imu', LaunchConfiguration('imu_topic')),
        ]
    )

    return LaunchDescription([
        lid_topic_arg,
        imu_topic_arg,
        sim_time_arg,
        fastlio_node,
    ])
