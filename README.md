# robotinit

`robotinit` 是一组面向 NVIDIA Jetson AGX Orin 的部署脚本，用于完成机器人运行环境安装、黄金母机净化、克隆设备首次启动后的身份初始化，以及已投入使用设备的账户与主机身份迁移。

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
恢复目标 NVMe
      |
      v
finalize.sh        归一化 NVMe 容量并为每台目标机生成独立身份
```

母机镜像读取和目标机刷写按 [部署手册](docs/guide.md) 执行；`backup.sh` 只负责打包读取完成的黄金镜像。每台恢复后的目标机都必须运行 `finalize.sh`，由它先归一化 NVMe 容量，再完成设备身份初始化。

## 脚本

| 脚本 | 运行位置 | 作用 |
| --- | --- | --- |
| [`provision.sh`](scripts/provision.sh) | 正常启动的 Jetson | 安装 ROS 2、系统级 `python-can`、KH-UCANFD、CUDA、TensorRT 和 PyTorch，并配置 ROS 本机通信与 MAXN 电源模式 |
| [`sanitize.sh`](scripts/sanitize.sh) | 黄金母机 | 检查网络绑定，清除不应被克隆的机器状态，并自动关机 |
| [`backup.sh`](scripts/backup.sh) | x86_64 Ubuntu 刷机主机 | 按日期和序号打包完整 `images/`，并生成 MD5 |
| [`finalize.sh`](scripts/finalize.sh) | 恢复后的目标机 | 归一化 NVMe 容量，设置 hostname，重建 machine-id 和 SSH host key，并自动重启 |
| [`rename.sh`](scripts/rename.sh) | 已投入使用的 Jetson | 离线迁移用户名、登录界面、home 和 hostname，重建机器身份并自动重启 |

黄金镜像读取完成后，可以直接归档到当前用户 HOME 下的
`backup/`：

```bash
curl -fsSL https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/robotinit/main/scripts/backup.sh | bash -s -- /home/ubuntu/Linux_for_Tegra
```

删除旧镜像、解包和刷机命令见 [部署手册](docs/guide.md)。

已投入使用的机器不能在当前用户会话中直接运行 `usermod`。先下载脚本，再用只检查模式确认；实际执行时脚本会投递开机前任务并连续启动两次：

> **实机验证状态：** `rename.sh` 的修正版尚未完整跑通一次改名流程，当前不要用于生产机器。

```bash
curl -fsSL https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/robotinit/main/scripts/rename.sh \
  -o /tmp/rename.sh
sudo bash /tmp/rename.sh -u m04 -h m04 --check
sudo bash /tmp/rename.sh -u m04 -h m04
```

`-u` 和 `-h` 分别表示新用户名和新 hostname。该脚本的帮助参数是 `--help`。

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
    ├── finalize.sh
    └── rename.sh
```
