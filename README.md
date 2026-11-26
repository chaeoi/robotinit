# robotinit

面向 NVIDIA Jetson AGX Orin DevKit 的初始化与黄金镜像部署脚本。仓库用于配置机器人运行环境、制作黄金镜像，以及恢复后初始化每台目标机。

## 适用环境

| 项目 | 配置 |
| --- | --- |
| 刷机主机 | x86_64 Ubuntu 22.04，通过 USB 连接 Jetson |
| Jetson 系统 | Jetson Linux R36.5.0 BSP，Ubuntu 22.04 Jammy Basic 无桌面系统 |
| 系统盘 | Jetson 上的外置 NVMe `nvme0n1`，根分区 `nvme0n1p1` |
| 运行环境 | ROS 2 Humble、Python 3.10、CUDA 12.6 |
| 默认用户 | `ubuntu` |

## 脚本

| 脚本 | 执行位置 | 用途 |
| --- | --- | --- |
| [provision.sh](scripts/provision.sh) | 正常启动的 Jetson | 安装 ROS 2、KH-UCANFD 和策略推理依赖，验证 GPU 推理并设置 MAXN |
| [sanitize.sh](scripts/sanitize.sh) | 黄金母机 | 检查网络绑定，清理设备运行状态并关机 |
| [backup.sh](scripts/backup.sh) | 刷机主机 | 归档 NVIDIA 工具读取的黄金镜像并生成 MD5 |
| [finalize.sh](scripts/finalize.sh) | 恢复后的目标机 | 归一化 NVMe 容量，设置主机名并重建设备身份 |
| [rename.sh](scripts/rename.sh) | 已投入使用的 Jetson | 迁移用户账号、主目录和主机名，当前仍在实机验证阶段 |

## 部署手册

从空白 Jetson 开始，按第一章到第四章完成 Basic 刷机、运行环境配置和黄金镜像制作。已有黄金镜像时，从第四章第 7 步开始校验和恢复，再初始化目标机。 [部署手册](docs/guide.md)
