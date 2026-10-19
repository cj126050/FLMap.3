#!/bin/bash
# patch_foxy.sh —— 把本仓库源码从 Humble 适配到 Ubuntu 20.04 + ROS 2 Foxy（幂等）
#
# 为什么需要：Go2 拓展坞（Orin Nano）出厂是 Ubuntu 20.04 + ROS 2 Foxy，
# 而本仓库默认按 Humble 写。**只应在狗端的副本上执行本脚本**，
# PC 端保持 Humble 干净源码；deploy_edge.sh 会在远端自动调用它。
#
# 用法: ./patch_foxy.sh <工作空间目录>
#   例: ./patch_foxy.sh ~/flmap_ws
#
# 改了什么（都是最小改动，不动算法）:
#   1. fast_lio2/include/common_lib.h   去掉 sophus/se3.h（Foxy 上没有这个包，
#      且 SE3 只在从未被 include 的 feature.h 里用到，属于 FAST-LIVO2 残留）
#   2. fast_lio2/CMakeLists.txt          去掉 find_package(Sophus) 与 include 路径
#   3. fast_lio2/package.xml             去掉 pcl_ros 依赖（Foxy 的 PCL 集成包只有
#      pcl_conversions / pcl_msgs，代码里也没有用到 pcl_ros）
#   4. livox_ros_driver2/package.xml     用 package_ROS2.xml 替换，并去掉
#      libpcl-all-dev（那是 apt 包名，不是 CMake 包，ament_auto 会找失败）
#   5. livox_ros_driver2/launch/         用 launch_ROS2/ 的内容

set -euo pipefail

WS="${1:-$PWD}"
[ -d "$WS/src" ] || { echo "[ERROR] $WS/src 不存在"; exit 1; }

SRC="$WS/src"
FL="$SRC/FAST_LIO2_ROS2"
DRI="$SRC/livox_ros_driver2"

echo "== 1. 检查 Sophus（Foxy 上没有）=="
if [ -d /usr/include/sophus ]; then
  echo "   检测到系统已装 Sophus，跳过补丁 1/2"
else
  H="$FL/include/common_lib.h"
  if [ -f "$H" ]; then
    sed -i 's|^#include <sophus/se3.h>|// [foxy-patch] no sophus on foxy: #include <sophus/se3.h>|' "$H"
    sed -i 's|^using namespace Sophus;|// [foxy-patch] using namespace Sophus;|' "$H"
    echo "   common_lib.h 已处理"
  fi
  C="$FL/CMakeLists.txt"
  if [ -f "$C" ]; then
    sed -i 's|^find_package(Sophus REQUIRED)|# [foxy-patch] find_package(Sophus REQUIRED)|' "$C"
    sed -i 's|^\(\s*\)${Sophus_INCLUDE_DIRS}|\1# [foxy-patch] ${Sophus_INCLUDE_DIRS}|' "$C"
    echo "   CMakeLists.txt 已处理"
  fi
fi

echo "== 2. 去掉 pcl_ros 依赖 =="
P="$FL/package.xml"
if [ -f "$P" ]; then
  sed -i '\|<depend>pcl_ros</depend>|d' "$P"
  echo "   package.xml 已处理"
fi

echo "== 2b. tf2_geometry_msgs 头文件名（.hpp 是 Humble 才有的）=="
if [ ! -f /opt/ros/foxy/include/tf2_geometry_msgs/tf2_geometry_msgs.hpp ]; then
  grep -rl "tf2_geometry_msgs/tf2_geometry_msgs.hpp" "$FL/include" "$FL/src" 2>/dev/null | while read -r f; do
    sed -i 's|tf2_geometry_msgs/tf2_geometry_msgs.hpp|tf2_geometry_msgs/tf2_geometry_msgs.h|g' "$f"
    echo "   $f 已改"
  done
fi

echo "== 3. Livox 驱动切到 ROS2 布局 =="
if [ -d "$DRI" ]; then
  # 板上预编译的 Livox-SDK2（2023-11）没有 kLivoxLidarTypeMid360s 枚举，
  # 该分支只用于 MID360s 机型，删掉不影响 MID360
  if [ -f "$DRI/src/comm/pub_handler.cpp" ]; then
    sed -i 's#||dev_type==LivoxLidarDeviceType::kLivoxLidarTypeMid360s##' "$DRI/src/comm/pub_handler.cpp"
    echo "   pub_handler.cpp: 去掉 Mid360s 枚举引用（SDK 版本差异）"
  fi
  [ -f "$DRI/package_ROS2.xml" ] && cp -f "$DRI/package_ROS2.xml" "$DRI/package.xml"
  # libpcl-all-dev 是 apt 包名，ament_auto_find_build_dependencies 会当成 CMake 包去找
  sed -i '\|<depend>libpcl-all-dev</depend>|d' "$DRI/package.xml"
  if [ -d "$DRI/launch_ROS2" ]; then
    # 不用 rm：只做覆盖拷贝，launch_ROS2 里的文件名与 ROS1 版不冲突
    mkdir -p "$DRI/launch"
    cp -a "$DRI/launch_ROS2/." "$DRI/launch/"
  fi
  echo "   package.xml / launch 已切换"
fi

echo "== 4. 显式链接 PCL/Boost/OpenMP（Foxy 不传递）=="
if [ -f "$FL/CMakeLists.txt" ] && ! grep -q "foxy-patch:link" "$FL/CMakeLists.txt"; then
  python3 - "$FL/CMakeLists.txt" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
marker = "install(DIRECTORY launch DESTINATION share/${PROJECT_NAME})"
block = """# [foxy-patch:link] Foxy 的 pcl_conversions 不会像 Humble 的 pcl_ros 那样把
# PCL / Boost / OpenMP 传递给下游，必须显式链接，否则 .so 里留下未定义符号
if(NOT TARGET fl_basic_libs)
  add_library(fl_basic_libs INTERFACE)
  target_link_libraries(fl_basic_libs INTERFACE ${PCL_LIBRARIES} ${Boost_LIBRARIES})
  if(TARGET OpenMP::OpenMP_CXX)
    target_link_libraries(fl_basic_libs INTERFACE OpenMP::OpenMP_CXX)
  elseif(OpenMP_CXX_LIBRARIES)
    target_link_libraries(fl_basic_libs INTERFACE ${OpenMP_CXX_LIBRARIES})
  endif()
endif()
foreach(_t lio pre imu_proc laser_mapping fastlio2_mapping)
  if(TARGET ${_t})
    target_link_libraries(${_t} fl_basic_libs)
  endif()
endforeach()

"""
if marker in s:
    s = s.replace(marker, block + marker, 1)
    open(p, "w").write(s)
    print("   已插入链接块")
PY
fi

echo "== 5. 校验 =="
grep -n "sophus" "$FL/include/common_lib.h" "$FL/CMakeLists.txt" | head -4 || true
grep -c "pcl_ros" "$FL/package.xml" 2>/dev/null | sed 's/^/   package.xml 中 pcl_ros 残留: /'
echo "== 补丁完成 =="
