#!/usr/bin/env python3
"""edge_mapping.launch.py —— 狗端一键起建图（驱动 + FAST-LIO2 + 瘦身桥）

跑在 Go2 拓展坞上（ROS 2 Foxy 或 Humble）。**不启动 RViz** —— 可视化在 PC 端做。

    ros2 launch flmap_bringup edge_mapping.launch.py

常用覆盖:

    # 雷达已经不是出厂 IP / 换了话题名
    ros2 launch flmap_bringup edge_mapping.launch.py lid_topic:=/livox/lidar

    # 链路很差，临时把流量压到最低
    ros2 launch flmap_bringup edge_mapping.launch.py \
        voxel_leaf:=0.30 max_rate_hz:=3.0 keep_intensity:=false

    # 驱动已经在跑（比如用 edge_control.sh 起的），只起 LIO + 桥
    ros2 launch flmap_bringup edge_mapping.launch.py start_driver:=false

参数说明见 docs/edge-deployment.md 与 docs/bandwidth-tuning.md。
"""

import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription
from launch.conditions import IfCondition
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue


def generate_launch_description():
    bridge_share = get_package_share_directory('flmap_bridge')
    default_bridge_cfg = os.path.join(bridge_share, 'config', 'bridge_default.yaml')

    start_driver = LaunchConfiguration('start_driver')
    use_sim_time = LaunchConfiguration('use_sim_time')
    lid_topic = LaunchConfiguration('lid_topic')
    imu_topic = LaunchConfiguration('imu_topic')
    voxel_leaf = LaunchConfiguration('voxel_leaf')
    max_rate_hz = LaunchConfiguration('max_rate_hz')
    keep_intensity = LaunchConfiguration('keep_intensity')
    max_points = LaunchConfiguration('max_points')
    bridge_cfg = LaunchConfiguration('bridge_config')

    args = [
        DeclareLaunchArgument(
            'start_driver', default_value='true',
            description='是否同时启动 livox_ros_driver2（驱动已在跑就设 false）'),
        DeclareLaunchArgument(
            'use_sim_time', default_value='false',
            description='实时建图必须 false；回放 bag 时设 true'),
        DeclareLaunchArgument('lid_topic', default_value='/livox/lidar'),
        DeclareLaunchArgument('imu_topic', default_value='/livox/imu'),

        # 桥接参数：直接覆盖 yaml 里的值，方便现场调，不用改文件
        DeclareLaunchArgument(
            'bridge_config', default_value=default_bridge_cfg,
            description='flmap_bridge 参数文件'),
        DeclareLaunchArgument(
            'voxel_leaf', default_value='0.20',
            description='桥接降采样体素（m），越大越省流量'),
        DeclareLaunchArgument(
            'max_rate_hz', default_value='5.0',
            description='发给 PC 的点云帧率上限'),
        DeclareLaunchArgument(
            'keep_intensity', default_value='true',
            description='是否保留 intensity（false 再省 25% 带宽）'),
        DeclareLaunchArgument(
            'max_points', default_value='20000',
            description='单帧点数上限，防止开阔场地爆量'),
    ]

    # ---- 1. Livox 驱动（可选）----
    driver = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            os.path.join(
                get_package_share_directory('livox_ros_driver2'),
                'launch', 'msg_MID360_launch.py')),
        condition=IfCondition(start_driver),
    )

    # ---- 2. FAST-LIO2 ----
    lio = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            os.path.join(
                get_package_share_directory('go2_fastlio'),
                'launch', 'mapping_mid360_go2.launch.py')),
        launch_arguments={
            'use_sim_time': use_sim_time,
            'lid_topic': lid_topic,
            'imu_topic': imu_topic,
        }.items(),
    )

    # ---- 3. 瘦身桥 ----
    bridge = Node(
        package='flmap_bridge',
        executable='flmap_bridge_node',
        name='flmap_bridge',
        output='screen',
        parameters=[
            bridge_cfg,
            {
                'voxel_leaf': ParameterValue(voxel_leaf, value_type=float),
                'max_rate_hz': ParameterValue(max_rate_hz, value_type=float),
                'keep_intensity': ParameterValue(keep_intensity, value_type=bool),
                'max_points': ParameterValue(max_points, value_type=int),
            },
        ],
    )

    return LaunchDescription(args + [driver, lio, bridge])
