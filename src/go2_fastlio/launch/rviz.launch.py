#!/usr/bin/env python3
"""一键启动 RViz2，加载 Fast-LIO Mid360 可视化配置。"""

import os
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch_ros.actions import Node


def generate_launch_description():
    pkg_share = get_package_share_directory('go2_fastlio')
    rviz_config = os.path.join(pkg_share, 'rviz', 'fastlio_mid360.rviz')

    rviz_node = Node(
        package='rviz2',
        executable='rviz2',
        name='rviz2',
        arguments=['-d', rviz_config],
        output='screen',
    )

    return LaunchDescription([rviz_node])
