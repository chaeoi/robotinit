# robotinit

`robotinit` 是一组面向 NVIDIA Jetson AGX Orin 的部署脚本，用于完成机器人运行环境安装、黄金母机净化，以及克隆设备首次启动后的身份初始化。

完整的刷机、环境配置和黄金镜像操作手册见 [项目 Wiki](https://github.com/chaeoi/robotinit/wiki)。

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
读取并恢复镜像
      |
      v
finalize.sh        为每台目标机生成独立身份
```

刷机和镜像读写命令没有封装在脚本中，请严格按照 [Wiki](https://github.com/chaeoi/robotinit/wiki) 操作。

## 脚本

| 脚本 | 运行位置 | 作用 |
| --- | --- | --- |
| [`provision.sh`](scripts/provision.sh) | 正常启动的 Jetson | 安装 ROS 2、CAN、KH-UCANFD、CUDA、TensorRT 和 PyTorch 等运行环境 |
| [`sanitize.sh`](scripts/sanitize.sh) | 黄金母机 | 检查网络绑定，清除不应被克隆的机器状态，并自动关机 |
| [`finalize.sh`](scripts/finalize.sh) | 恢复后的目标机 | 设置 hostname，重建 machine-id 和 SSH host key，并自动重启 |

## 快速使用

先克隆仓库：

```bash
git clone https://github.com/chaeoi/robotinit.git
cd robotinit
```

在新刷好的 Jetson 上安装运行环境：

```bash
sudo bash ./scripts/provision.sh
```

默认目标用户为 `ubuntu`，安装完成后会重启。可通过环境变量调整：

```bash
sudo TARGET_USER=<user> AUTO_REBOOT=0 bash ./scripts/provision.sh
```

制作黄金镜像前，先执行只读检查，再执行净化：

```bash
sudo bash ./scripts/sanitize.sh --check
sudo bash ./scripts/sanitize.sh
```

净化成功后设备会自动关机。不要再次启动母机，直接按照 Wiki 从 Recovery 模式读取镜像。

目标机恢复镜像并首次启动后，为其设置唯一 hostname 和机器身份：

```bash
sudo bash ./scripts/finalize.sh robot-01 --check
sudo bash ./scripts/finalize.sh robot-01
```

初始化完成后设备会重启，原 SSH host key 将失效，需要更新客户端的 `known_hosts`。

## 注意事项

- 运行前先阅读脚本和 Wiki，并备份目标设备上的重要数据。
- `provision.sh` 会升级系统、修改 APT 源和内核模块配置，并安装第三方驱动。
- `sanitize.sh` 会删除机器身份、日志、缓存和命令历史，成功后自动关机；该操作不能作为普通清理脚本使用。
- `finalize.sh` 会替换目标机的 machine-id、hostname 和 SSH host key。
- Wiki 中的刷机与镜像恢复命令会覆盖 NVMe，必须再次核对设备名和 BSP 版本。
- 生产部署建议检出已验证的 commit，不要让设备长期依赖可变的 `main` 分支。

## 仓库结构

```text
robotinit/
├── README.md
└── scripts/
    ├── provision.sh
    ├── sanitize.sh
    └── finalize.sh
```

## License

本仓库目前未声明开源许可证。
