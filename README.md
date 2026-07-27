# robotinit

`robotinit` 是一组面向 NVIDIA Jetson AGX Orin 的部署脚本，用于完成机器人运行环境安装、黄金母机净化，以及克隆设备首次启动后的身份初始化。

完整的刷机、环境配置和黄金镜像操作手册见 [部署手册](docs/guide.md)。

## 适用环境

本仓库当前按以下组合开发和验证：

| 组件 | 版本或配置 |
| --- | --- |
| 设备 | NVIDIA Jetson AGX Orin |
| Jetson Linux | R36.5 |
| 操作系统 | Ubuntu 22.04 |
| 系统盘 | 外置 NVMe `nvme0n1` |
| ROS | ROS 2 Humble |
| Python | 3.10 |
| 默认用户 | `ubuntu` |

脚本包含与上述平台和版本绑定的软件源、内核模块、驱动及 Python wheel。不要直接用于其他 Jetson 型号或 Jetson Linux 版本。

## 工作流

```text
刷入最小系统
      |
      v
provision.sh       安装机器人运行环境
      |
      v
sanitize.sh        净化黄金母机并关机
      |
      v
读取母机镜像
      |
      v
backup.sh          打包黄金镜像
      |
      v
finalize.sh        为每台目标机生成独立身份
```

母机镜像读取和目标机刷写按 [部署手册](docs/guide.md) 中的 NVIDIA 命令执行；`backup.sh` 只负责打包读取完成的黄金镜像。

## 脚本

| 脚本 | 运行位置 | 作用 |
| --- | --- | --- |
| [`provision.sh`](scripts/provision.sh) | 正常启动的 Jetson | 安装 ROS 2、CAN、KH-UCANFD、CUDA、TensorRT 和 PyTorch 等运行环境 |
| [`sanitize.sh`](scripts/sanitize.sh) | 黄金母机 | 检查网络绑定，清除不应被克隆的机器状态，并自动关机 |
| [`backup.sh`](scripts/backup.sh) | x86_64 Ubuntu 刷机主机 | 按日期和序号打包完整 `images/`，并生成 MD5 |
| [`finalize.sh`](scripts/finalize.sh) | 恢复后的目标机 | 设置 hostname，重建 machine-id 和 SSH host key，并自动重启 |

黄金镜像读取完成后，可以直接归档到当前用户 HOME 下的
`backup/`：

```bash
curl -fsSL https://raw.githubusercontent.com/chaeoi/robotinit/main/scripts/backup.sh | bash -s -- /home/ubuntu/Linux_for_Tegra
```

删除旧镜像、解包和刷机命令见 [部署手册](docs/guide.md)。

## 仓库结构

```text
robotinit/
├── README.md
├── docs/
│   └── guide.md
└── scripts/
    ├── provision.sh
    ├── sanitize.sh
    ├── backup.sh
    └── finalize.sh
```
