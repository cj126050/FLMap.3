#!/usr/bin/env python3
"""pc_view.launch.py —— PC 端一键远程可视化

跑在 PC 上（ROS 2 Humble / Foxy 均可）。它只做两件事：

    1. flmap_accumulator：把狗端发来的当前帧拼成累积地图 /flmap/map
    2. rviz2：用仓库自带的配置打开可视化

它**不启动**任何建图算法 —— 建图在狗上跑。如果 PC 端连不上狗，先跑
scripts/link_probe.sh 排查链路（见 docs/network-and-dds.md）。

    ros2 launch flmap_bringup pc_view.launch.py
    ros2 launch flmap_bringup pc_view.launch.py rviz:=false      # 只看数据不开窗口
    ros2 launch flmap_bringup pc_view.launch.py accumulate:=false # 只看当前帧，不攒图
"""

import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue


def generate_launch_description():
    bringup_share = get_package_share_directory('flmap_bringup')
    accum_cfg = os.path.join(
        get_package_share_directory('flmap_accumulator'), 'config', 'pc_view.yaml')
    rviz_cfg = os.path.join(bringup_share, 'rviz', 'flmap_pc.rviz')

    args = [
        DeclareLaunchArgument(
            'rviz', default_value='true',
            description='是否打开 RViz2 窗口（无显示器的机器设 false）'),
        DeclareLaunchArgument(
            'accumulate', default_value='true',
            description='是否启动累加器（false = 只看狗端发来的当前帧）'),
        DeclareLaunchArgument(
            'accumulator_config', default_value=accum_cfg,
            description='累加器参数文件'),
        DeclareLaunchArgument(
            'voxel_leaf', default_value='0.15',
            description='累加器体素（m），越小越精细、越吃内存'),
        DeclareLaunchArgument('rviz_config', default_value=rviz_cfg),
    ]

    accumulator = Node(
        package='flmap_accumulator',
        executable='flmap_accumulator.py',
        name='flmap_accumulator',
        output='screen',
        condition=IfCondition(LaunchConfiguration('accumulate')),
        parameters=[
            LaunchConfiguration('accumulator_config'),
            {'voxel_leaf': ParameterValue(
                LaunchConfiguration('voxel_leaf'), value_type=float)},
        ],
    )

    rviz = Node(
        package='rviz2',
        executable='rviz2',
        name='rviz2',
        output='log',
        condition=IfCondition(LaunchConfiguration('rviz')),
        arguments=['-d', LaunchConfiguration('rviz_config')],
    )

    return LaunchDescription(args + [accumulator, rviz])
