cmake_minimum_required(VERSION 3.10)
project(flmap_accumulator)

find_package(ament_cmake REQUIRED)

# 纯 Python 节点，用 ament_cmake 安装即可，避免 setup.py / entry_points 在
# Foxy 与 Humble 之间的差异。
install(PROGRAMS
  scripts/flmap_accumulator.py
  DESTINATION lib/${PROJECT_NAME}
)

install(DIRECTORY config
  DESTINATION share/${PROJECT_NAME}
)

ament_package()
