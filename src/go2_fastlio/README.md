# go2_fastlio

Unitree Go2 + Livox Mid360 的 Fast-LIO2 启动与配置包。

## 内容

- **config/mid360_go2.yaml** — Fast-LIO2 参数（话题、外参、时间偏移、LIO、保存等）
- **launch/** — `mapping_mid360_go2.launch.py`、`mapping_with_rviz.launch.py`、`rviz.launch.py`
- **rviz/fastlio_mid360.rviz** — 建图用 RViz 配置（点云累积、轨迹、里程计）
- **TROUBLESHOOTING.md** — 常见问题（effective feature 0、RViz 建图、保存地图）

## 快速运行

从工作空间根目录：

```bash
source install/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=0
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib
ros2 launch go2_fastlio mapping_with_rviz.launch.py
```

若需连狗子一起一键启动 Mid360，可在根目录执行 `./scripts/start_go2_fastlio.sh`（详情见主 README）。

完整说明见工作空间 [README](../../README.md) 与 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)。
