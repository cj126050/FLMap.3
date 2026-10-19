#!/usr/bin/env python3
"""一键启动 Fast-LIO + RViz2（先起 Fast-LIO，再起 RViz）。"""

import os
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, GroupAction
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    pkg_share = get_package_share_directory('go2_fastlio')
    config_path = os.path.join(pkg_share, 'config', 'mid360_go2.yaml')
    rviz_config = os.path.join(pkg_share, 'rviz', 'fastlio_mid360.rviz')

    lid_topic = LaunchConfiguration('lid_topic', default='/livox/lidar')
    imu_topic = LaunchConfiguration('imu_topic', default='/livox/imu')

    fastlio_node = Node(
        package='fast_lio2',
        executable='fastlio2_mapping',
        name='fastlio2_mapping',
        output='screen',
        parameters=[config_path],
        remappings=[
            ('/livox/lidar', lid_topic),
            ('/livox/imu', imu_topic),
        ],
    )

    rviz_node = Node(
        package='rviz2',
        executable='rviz2',
        name='rviz2',
        arguments=['-d', rviz_config],
        output='screen',
    )

    return LaunchDescription([
        DeclareLaunchArgument('lid_topic', default_value='/livox/lidar', description='LiDAR topic'),
        DeclareLaunchArgument('imu_topic', default_value='/livox/imu', description='IMU topic'),
        fastlio_node,
        rviz_node,
    ])
