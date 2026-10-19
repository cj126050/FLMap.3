import os
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    # .lvx2 回放：把录制好的雷达数据当实时数据源喂给 FAST-LIO2，
    # 用来在**不接雷达**的情况下复现建图问题，或对同一段数据反复调参。
    #
    #   ros2 launch livox_ros_driver2 lvx2_playback.launch.py \
    #       lvx_file_path:=$HOME/data/scan.lvx2
    lvx_file_path = LaunchConfiguration('lvx_file_path')

    config_file = os.path.join(
        get_package_share_directory('livox_ros_driver2'),
        'config',
        'lvx2_playback_config.json'
    )

    livox_driver_node = Node(
        package='livox_ros_driver2',
        executable='livox_ros_driver2_node',
        name='livox_lidar_publisher',
        output='screen',
        parameters=[
            {'data_src': 2},              # 2 = 文件回放模式
            {'lvx_file_path': lvx_file_path},
            {'xfer_format': 1},           # 1 = Livox CustomMsg
            {'publish_freq': 10.0},
            {'frame_id': 'livox_frame'},
            {'config_file': config_file}
        ]
    )

    return LaunchDescription([
        DeclareLaunchArgument(
            'lvx_file_path', default_value='',
            description='要回放的 .lvx2 文件绝对路径'),
        livox_driver_node,
    ])
