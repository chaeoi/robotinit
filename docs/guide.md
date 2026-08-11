# Jetson AGX Orin 刷机、环境配置与黄金镜像部署

本仓库记录 NVIDIA Jetson AGX Orin 从最小系统刷机、机器人运行环境安装、常用工具配置，到黄金母机备份和目标机恢复的完整流程。

本文档整合刷机、环境配置、常用工具和黄金镜像部署流程。既有操作步骤、命令顺序和参数保持不变，只增加用途、前提、结果和风险说明。仓库脚本的管道执行统一使用 GitHub Raw 源文件地址。

## 适用环境

- NVIDIA Jetson AGX Orin
- Jetson Linux R36.5
- Ubuntu 22.04
- 外置 NVMe：`nvme0n1`
- 默认用户：`ubuntu`
- ROS2 Humble
- Python 3.10
- 刷机主机：x86_64 Ubuntu

不同 Jetson Linux 小版本的 BSP、分区配置和软件包可能不同。执行前应确认目标设备确实使用 R36.5，并确保刷机主机上的 `Linux_for_Tegra` 来自同一版本。

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

五个脚本的职责：

| 脚本 | 执行位置 | 用途 |
| --- | --- | --- |
| `provision.sh` | 正常启动的 Jetson | 安装 ROS2、CAN、CUDA、TensorRT、PyTorch 等运行环境 |
| `sanitize.sh` | 黄金母机 | 清除会被克隆的机器状态并自动关机 |
| `backup.sh` | x86_64 Ubuntu 刷机主机 | 按日期和序号打包完整黄金镜像，并生成 MD5 |
| `finalize.sh` | 恢复后的目标机 | 归一化 NVMe 容量，设置 hostname，重建 machine-id 和 SSH host key，然后重启 |
| `rename.sh` | 已投入使用的 Jetson | 离线迁移用户名、登录界面、home 和 hostname，重建机器身份并重启 |

GitHub Raw 地址使用 `main` 分支。只有文件已经提交并推送到 GitHub 后，远程设备才能通过这些地址下载最新脚本。

---

## 一、刷入最小 Jetson Linux 系统

本章保持既定刷机步骤的执行顺序。

### 1. 更新刷机主机的软件源

```bash
sudo apt update
```

这条命令在 x86 Ubuntu 刷机主机上执行，只刷新 APT 软件包索引，不会升级已经安装的软件。

### 2. 安装刷机依赖

```bash
sudo apt install -y libxml2-utils python3 sshpass abootimg nfs-kernel-server \
                    binfmt-support qemu-user-static device-tree-compiler
```

这些依赖分别用于解析分区 XML、运行 NVIDIA Python 脚本、通过 SSH 控制 initrd、生成启动镜像、提供 NFS、在 x86 主机处理 ARM64 rootfs，以及编译设备树。

`nfs-kernel-server` 在后续黄金镜像备份和恢复阶段仍会使用，因此不要在刷机完成后删除。

### 3. 下载 Jetson Linux R36.5 BSP

```text
https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v5.0/release/Jetson_Linux_r36.5.0_aarch64.tbz2
```

这是 Jetson Linux R36.5 Driver Package。下载完成后，应确认文件名为 `Jetson_Linux_R36.5.0_aarch64.tbz2`。

### 4. 解压 BSP

```bash
tar xf Jetson_Linux_R36.5.0_aarch64.tbz2
```

解压后会生成 `Linux_for_Tegra` 目录。后续制作 rootfs、刷机、备份和恢复都从该目录执行。

### 5. 进入 BSP 目录

```bash
cd Linux_for_Tegra
```

后续相对路径都以当前 `Linux_for_Tegra` 为基准。切换终端后，应重新确认当前目录，避免在错误的 BSP 版本中执行命令。

### 6. 生成 Ubuntu Jammy minimal rootfs

```bash
sudo ./tools/samplefs/nv_build_samplefs.sh \
     --abi aarch64 \
     --distro ubuntu \
     --version jammy \
     --flavor minimal
```

参数说明：

- `--abi aarch64`：生成 ARM64 用户空间。
- `--distro ubuntu`：使用 Ubuntu。
- `--version jammy`：对应 Ubuntu 22.04。
- `--flavor minimal`：生成无桌面的最小系统。

命令完成后，samplefs 工具会生成后续要解压进 `rootfs/` 的归档文件。

### 7. 清空 BSP 当前 rootfs

```bash
sudo rm -rf rootfs/*
```

这条命令会删除 `Linux_for_Tegra/rootfs/` 中现有内容。执行前必须确认当前位于正确的 `Linux_for_Tegra` 目录。

它不会删除整台刷机主机的根目录，但路径使用错误会造成严重数据损失。

### 8. 解压 minimal rootfs

```bash
sudo tar xpf tools/samplefs/sample_fs.tbz2 -C rootfs/
```

参数说明：

- `x`：解包。
- `p`：保留文件权限。
- `f`：指定归档文件。
- `-C rootfs/`：将内容写入 BSP 的 rootfs 目录。

这里必须使用 `sudo`，否则设备文件、所有者和权限可能不正确。

### 9. 应用 NVIDIA 二进制文件

```bash
sudo ./apply_binaries.sh
```

该脚本向 Ubuntu rootfs 中安装 NVIDIA 驱动、固件、库、内核模块及 Jetson 平台组件。只解压 Ubuntu rootfs 而不执行该步骤，系统无法作为完整 Jetson Linux 使用。

### 10. 创建默认用户

```bash
sudo tools/l4t_create_default_user.sh \
     -u ubuntu \
     -p 123 \
     -n m00 \
     -a \
     --accept-license
```

参数说明：

- `-u ubuntu`：创建用户名 `ubuntu`。
- `-p 123`：设置初始密码。
- `-n m00`：将黄金母机初始 hostname 设置为 `m00`。
- `-a`：启用自动登录配置。
- `--accept-license`：预先接受 NVIDIA 许可协议。

该步骤使无显示器设备能够跳过首次开机的 OEM 配置向导。密码会写入待刷 rootfs，公开仓库和生产环境应注意凭据风险。

### 11. 确认设备进入 Recovery 模式

```bash
lsusb | grep -i nvidia
```

Jetson 通过刷机 USB-C 连接 x86 主机并进入 Force Recovery 后，`lsusb` 应显示 NVIDIA APX 设备。没有输出时不要继续刷机，应先检查 USB 线、接口、供电和 Recovery 操作。

### 12. 刷入外置 NVMe

```bash
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
     --external-device nvme0n1p1 \
     -c ./tools/kernel_flash/flash_l4t_t234_nvme.xml \
     --showlogs \
     --network usb0 \
     jetson-agx-orin-devkit external
```

参数说明：

- `--external-device nvme0n1p1`：将根文件系统放到 Jetson 的第一块 NVMe 第一分区。
- `-c flash_l4t_t234_nvme.xml`：使用 T234 平台 NVMe 分区布局。
- `--showlogs`：显示刷写过程日志。
- `--network usb0`：通过 Recovery USB 网络执行 initrd flash。
- `jetson-agx-orin-devkit`：目标板型。
- `external`：使用外置存储启动布局。

这一步会覆盖目标 NVMe。刷机完成后让 Jetson 正常启动。

### 13. 通过 USB Device Mode 登录

```bash
ssh ubuntu@192.168.55.1
```

正常启动后，Jetson 会通过刷机 USB-C 提供 USB 虚拟网卡，设备地址为 `192.168.55.1`。登录密码是创建默认用户时设置的密码。

### 14. 连接指定 Wi-Fi

```bash
sudo nmcli device wifi connect "Cudy-89D0" password "13594954"
```

NetworkManager 会创建并保存 `Cudy-89D0` 的连接 profile。该 profile 后续会被保留进黄金镜像，使恢复后的目标机能够自动连接同一 Wi-Fi。

连接 profile 的 UUID 可以在多台设备上相同，不等于 machine-id，也不会造成网络身份冲突。每台设备仍使用自己的 Wi-Fi MAC、DHCP 租约和 NetworkManager 主机密钥。

---

## 二、安装机器人运行环境

本章保持既定环境配置的14个步骤和执行顺序。

适用环境：

- NVIDIA Jetson AGX Orin
- Ubuntu 22.04 / Jetson Linux R36.5
- Python 3.10
- ROS2 Humble
- 用户名：`ubuntu`

整体顺序：

1. 安装基础下载、编译和 Python 工具。
2. 安装 ROS2、CAN、手柄、IMU 权限和 KH-UCANFD 通信环境。
3. 安装 CUDA、cuDNN、TensorRT、PyTorch 等强化学习推理环境。
4. 最后验证环境并将 Jetson 电源模式设置为 MAXN。

### 自动化脚本

运行 `provision.sh` 前先手动更新系统：

```bash
sudo apt update
sudo apt install -y fwupd curl
sudo apt upgrade -y
sudo reboot
```

重启完成后再运行：

```bash
curl -fsSL https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/robotinit/main/scripts/provision.sh | sudo bash
```

脚本默认配置 `ubuntu` 用户，不会重复更新系统，并在安装完成后自动重启。添加 ROS2 软件源后仍会刷新一次软件源索引，这是安装 ROS2 软件包所必需的。自动化脚本和下面的手动步骤应二选一，不要重复执行。

### 1. 更新系统

```bash
sudo apt update
sudo apt install -y fwupd
sudo apt upgrade -y
sudo reboot
```

作用：

- `apt update`：刷新软件源索引。
- `fwupd`：提供 Jetson bootloader 升级过程所需的 `fwupdmgr` 和 `fwupdtool`。
- `apt upgrade`：升级当前系统中已经安装的软件包。
- `reboot`：让升级后的 bootloader、内核和对应内核模块生效。

### 2. 安装基础下载和编译工具

```bash
sudo apt install -y \
  curl \
  wget \
  unzip \
  build-essential \
  cmake \
  libpopt-dev
```

作用：

- `curl`：下载 ROS2 密钥和 NVIDIA 依赖文件。
- `wget`、`unzip`：下载并解压 KH-UCANFD SDK。
- `build-essential`：提供 C/C++ 编译工具。
- `cmake`、`libpopt-dev`：提供 KH-UCANFD 驱动所需的构建工具和开发库。

`git` 在后面的常用工具配置章节安装，原步骤顺序保持不变。

### 3. 安装基础 Python 工具

```bash
sudo apt install -y \
  python3-numpy \
  python3-psutil \
  python3-empy \
  python3-pip
```

作用：

- `python3-numpy`：提供基础数组和矩阵运算。
- `python3-psutil`：读取系统进程和资源信息。
- `python3-empy`：ROS2 接口和代码生成依赖。
- `python3-pip`：安装 Python 软件包。

### 4. 安装 ROS2 Humble

添加南京大学 ROS2 软件源密钥：

```bash
curl -sSL https://mirror.nju.edu.cn/rosdistro/ros.asc | \
  gpg --dearmor | \
  sudo tee /usr/share/keyrings/ros-archive-keyring.gpg > /dev/null
```

该命令下载 ROS 软件源签名密钥，转换成 GPG keyring 格式并保存到系统 keyring 目录。

添加 ROS2 Humble 软件源：

```bash
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] https://mirror.nju.edu.cn/ros2/ubuntu $(lsb_release -sc) main" | \
  sudo tee /etc/apt/sources.list.d/ros2.list > /dev/null
```

命令会自动读取当前 CPU 架构和 Ubuntu 代号，生成 ROS2 APT 软件源配置。

刷新软件源并安装 ROS2：

```bash
sudo apt update

sudo apt install -y ros-humble-ros-base

sudo apt install -y \
  python3-colcon-core \
  python3-colcon-common-extensions \
  python3-rosdep \
  python3-argcomplete
```

作用：

- `ros-humble-ros-base`：提供 ROS2 Humble 基础运行环境、`rclpy` 和基础消息类型。
- `python3-colcon-core`、`python3-colcon-common-extensions`：构建 ROS2 工作空间。
- `python3-rosdep`：提供 ROS 依赖管理工具。
- `python3-argcomplete`：提供 ROS2 命令行补全支持。

配置 ROS2 环境：

```bash
source /opt/ros/humble/setup.bash

grep -q "ros/humble/setup.bash" ~/.bashrc || \
  echo "source /opt/ros/humble/setup.bash" >> ~/.bashrc

grep -Fqx "export ROS_LOCALHOST_ONLY=1" ~/.bashrc || \
  echo "export ROS_LOCALHOST_ONLY=1" >> ~/.bashrc

source ~/.bashrc

ros2 --help
```

第一次 `source` 让当前终端立即获得 ROS2 环境；两项配置写入 `.bashrc` 后，`ubuntu` 用户以后登录会自动加载 ROS2 并设置 `ROS_LOCALHOST_ONLY=1`。该变量会将 ROS2 topic、service 和 action 限制在本机；需要跨机器使用 ROS2 时不要启用。systemd 服务不会读取 `.bashrc`，以后如用服务启动 ROS2 节点，还需在对应 unit 中设置 `Environment=ROS_LOCALHOST_ONLY=1`。最后通过 `ros2 --help` 验证命令可用。

### 5. 安装 CAN、手柄和数据通信依赖

```bash
sudo apt install -y \
  can-utils \
  python3-pygame \
  python3-zmq

sudo python3 -m pip install --no-input --no-cache-dir "python-can==4.6.1"
```

作用：

- `can-utils`：提供 SocketCAN 检查和调试工具。
- `python-can`：在 Python 中访问 SocketCAN 接口。当前 CAN 工具使用 `sudo python3` 配置接口，因此固定安装 `4.6.1` 到系统 Python 路径，使 root 和 `ubuntu` 都能导入同一份模块。
- `python3-pygame`：读取 USB 手柄摇杆和按键。
- `python3-zmq`：通过 ZeroMQ 发布控制和关节数据。

### 6. 配置 IMU 和手柄访问权限

```bash
sudo usermod -aG dialout,input ubuntu
```

作用：

- `dialout`：允许用户访问 Yesense IMU 使用的 `/dev/ttyACM0`。
- `input`：允许用户读取 USB 手柄输入设备。

用户组变更需要重新登录或重启后生效。Yesense IMU 使用的 `cdc_acm` 是系统原有内核模块，不需要额外安装。

### 7. 禁用 Jetson 自带的 mttcan

```bash
echo "blacklist mttcan" | sudo tee /etc/modprobe.d/denylist-mttcan.conf
```

该配置阻止 Jetson 自带 `mttcan` 模块在后续启动时自动加载，避免与外接 KH-UCANFD 驱动的使用方式冲突。

写入黑名单后重启，使黑名单和用户组配置生效：

```bash
sudo reboot
```

重启会中断 SSH。等待设备重新上线后，再继续下一步。

### 8. 重启后加载 CAN 和手柄内核模块

重新登录 Jetson 后执行：

```bash
sudo modprobe can
sudo modprobe can_raw
sudo modprobe can_bcm
sudo modprobe joydev
```

作用：

- `can`：Linux CAN 核心模块。
- `can_raw`：提供 SocketCAN RAW socket。
- `can_bcm`：提供 SocketCAN Broadcast Manager。
- `joydev`：为 USB 手柄提供 `/dev/input/js*` 输入接口。

### 9. 安装 KH-UCANFD 驱动

```bash
mkdir -p /tmp/KH-UCANFD
cd /tmp/KH-UCANFD

wget -O KH-UCANFD_Linux_SDK.zip \
  https://gitee.com/ChengDu-KunHong/KH-UCANFD_Linux_SDK/releases/download/latest/KH-UCANFD_Linux_SDK.zip

unzip -o KH-UCANFD_Linux_SDK.zip

cd "$(find . -maxdepth 1 -type d -name 'KH-UCANFD_Linux_SDK*' | sort -V | tail -n 1)"

sudo ./build.sh
sudo modprobe kcan
```

作用：

- 在 `/tmp` 中下载并解压 KH-UCANFD SDK。
- 自动进入当前目录下版本号最新的 `KH-UCANFD_Linux_SDK*` 目录，避免写死 `1.4.1`。
- 编译并安装 `kcan` 内核驱动。
- 加载 `kcan`，将外接 USB-CANFD 设备注册为 Linux SocketCAN 接口。

如果上游目录结构变化导致找不到 `build.sh`，先执行 `find . -name build.sh -print` 查看实际路径。

### 10. 安装 CUDA、cuDNN 和 TensorRT

```bash
sudo apt-get install -y \
  nvidia-cuda \
  nvidia-cudnn \
  cuda-cupti-12-6 \
  cuda-nvtx-12-6 \
  tensorrt \
  nvidia-l4t-dla-compiler

sudo ldconfig
```

作用：

- `nvidia-cuda`：安装 Jetson CUDA 12.6 运行环境和基础 GPU 计算库。
- `nvidia-cudnn`：提供神经网络 GPU 算子。
- `cuda-cupti-12-6`：提供 CUDA Profiling Tools Interface。
- `cuda-nvtx-12-6`：提供 PyTorch 需要的 `libnvToolsExt.so.1`。
- `tensorrt`：提供 TensorRT 运行时、Python 绑定和 ONNX 解析器。
- `nvidia-l4t-dla-compiler`：提供 TensorRT 导入需要的 `libnvdla_compiler.so`。
- `ldconfig`：更新系统动态链接库缓存。

### 11. 安装 cuSPARSELt

```bash
mkdir -p /tmp/codex-cusparselt-0.6.2.3
cd /tmp/codex-cusparselt-0.6.2.3

curl -fL --retry 3 -O \
  "https://developer.download.nvidia.cn/compute/cusparselt/redist/libcusparse_lt/linux-sbsa/libcusparse_lt-linux-sbsa-0.6.2.3-archive.tar.xz"

tar -xf libcusparse_lt-linux-sbsa-0.6.2.3-archive.tar.xz

sudo cp -a \
  libcusparse_lt-linux-sbsa-0.6.2.3-archive/include/. \
  /usr/local/cuda/include/

sudo cp -a \
  libcusparse_lt-linux-sbsa-0.6.2.3-archive/lib/. \
  /usr/local/cuda/targets/aarch64-linux/lib/

sudo ldconfig
```

作用：

- 安装 cuSPARSELt 0.6.2.3。
- 将头文件复制到 CUDA include 目录。
- 将 SBSA ARM64 动态库复制到 Jetson CUDA 库目录。
- 提供 NVIDIA Jetson PyTorch 需要的 `libcusparseLt.so.0`。

### 12. 安装 Jetson CUDA 版 PyTorch

```bash
python3 -m pip install --user --no-cache-dir \
  "https://developer.download.nvidia.cn/compute/redist/jp/v61/pytorch/torch-2.5.0a0+872d972e41.nv24.08.17622132-cp310-cp310-linux_aarch64.whl"
```

作用：

- 安装适配 JetPack 6.1、Python 3.10 和 ARM64 的 NVIDIA PyTorch wheel。
- 加载 TorchScript 强化学习策略。
- 为 TensorRT 提供 CUDA Tensor。
- TensorRT 不可用时作为 GPU 或 CPU 推理后端。

`--user` 会将 Python 包安装到当前 `ubuntu` 用户目录，不覆盖系统 Python 包。

### 13. 将 NumPy 调整到项目指定版本

```bash
python3 -m pip install --user --no-cache-dir "numpy==1.24.4"
```

作用：

- 满足当前 PyTorch wheel 的 NumPy C API 要求。
- 保持与项目指定的 NumPy 版本一致。

### 14. 配置 Jetson MAXN 电源模式

```bash
sudo /usr/sbin/nvpmodel -m 0
```

如果命令提示切换模式需要重启，输入 `YES`。重新登录后验证：

```bash
sudo /usr/sbin/nvpmodel -q
```

预期输出包含：

```text
NV Power Mode: MAXN
0
```

AGX Orin 的 mode `0` 为 MAXN。该模式会开放最高核心数量和频率上限，但仍会受到供电和温度限制；持续重负载运行前应确认电源与散热满足要求。电源模式会跨重启保持。

---

## 三、安装常用工具

本章保持既定常用工具配置的执行顺序。

### 1. 更新软件源

```bash
sudo apt update
```

确保后续安装 `git` 和 `avahi-daemon` 时使用最新的软件包索引。

### 2. 安装 Git

```bash
sudo apt install git
```

Git 用于获取和管理项目代码。命令未使用 `-y`，APT 会按照原步骤要求交互确认。

### 3. 安装 mDNS 服务

```bash
sudo apt install avahi-daemon
```

Avahi 提供 `.local` 主机名解析。设备 hostname 为 `m00` 时，同一局域网通常可以通过 `m00.local` 访问。

多台克隆设备必须在运行 `finalize.sh` 后拥有不同 hostname，否则 `.local` 名称会冲突。

### 4. 编辑 code-server 配置

```bash
mkdir -p /home/ubuntu/.config/code-server
vi /home/ubuntu/.config/code-server/config.yaml
```

先创建配置目录，再编辑 `config.yaml`。配置内容保持如下：

```yaml
bind-addr: 0.0.0.0:80
auth: password
password: 123
cert: false
```

字段说明：

- `bind-addr`：监听所有网络接口的80端口。80是特权端口，普通用户需要通过
  systemd capability 配置才能监听。
- `auth: password`：启用密码认证。
- `password: 123`：设置访问密码。
- `cert: false`：不在 code-server 内部启用 TLS。

该服务会暴露到局域网，生产环境应通过可信网络、防火墙或反向代理限制访问。

### 5. 安装 code-server

```bash
curl -fsSL https://code-server.dev/install.sh | sh
```

这条命令使用 code-server 官方安装脚本。它不是本仓库脚本，因此继续使用 code-server 官方源地址。

### 6. 为服务授予监听80端口的 capability

code-server 默认以当前用户运行，不能直接监听80端口。为当前用户的 systemd
实例创建 drop-in：

```bash
sudo systemctl edit code-server@$USER
```

在编辑器中填入：

```ini
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
```

`CAP_NET_BIND_SERVICE` 只允许服务绑定1024以下端口，服务仍以普通用户运行。
`CapabilityBoundingSet` 将该服务的 capability 上限限制为这一项。保存后重新加载
systemd 配置：

```bash
sudo systemctl daemon-reload
```

### 7. 启用并启动服务

```bash
sudo systemctl enable code-server@$USER
sudo systemctl restart code-server@$USER
```

- `enable`：设置开机自动启动。
- `restart`：立即启动服务；如果服务已经运行，则重新创建进程以应用新的 capability。
- `$USER`：使用当前登录用户的 systemd 实例，正常情况下为 `ubuntu`。

---

## 四、制作黄金镜像并恢复目标机

本章先使用 NVIDIA 工具读取母机镜像，再使用脚本打包，并给出删除旧镜像、解包、刷写目标机、归一化 NVMe 容量和初始化设备身份的命令。在线脚本统一使用 GitHub Raw 源文件地址。

### 1. 净化黄金母机

在黄金母机正常运行、软件和 Wi-Fi 均配置完成后执行：

```bash
curl -fsSL https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/robotinit/main/scripts/sanitize.sh | sudo bash -s -- --yes
```

管道各部分含义：

- `curl -fsSL`：下载 GitHub 上的原始脚本；HTTP 失败时返回错误。
- `sudo bash -s`：以 root 身份从标准输入执行脚本。
- 第一个 `--`：结束 Bash 自身参数。
- `--yes`：跳过 `CLEAN` 人工确认，直接开始净化。

`sanitize.sh` 会：

- 清空 machine-id。
- 清除 random-seed、NetworkManager 运行状态和 USB Device Mode MAC。
- 清除日志、缓存、历史和临时文件。
- 保留 hostname、SSH host key、Wi-Fi profile、用户密码和登录配置。
- 完成后自动关机。

保留 SSH host key 的目的是确保目标机第一次开机时仍能通过 SSH 登录。目标机运行 `finalize.sh` 后会重新生成自己的 SSH host key。

该命令会自动关机。关机后不要再次正常启动母机，应直接让母机进入 Force Recovery 并开始备份；否则被清除的运行状态会重新生成。

### 2. 进入 BSP 目录

```bash
cd Linux_for_Tegra
```

这里必须进入与母机 Jetson Linux R36.5 完全匹配的 BSP 目录。后续备份镜像会写入当前 BSP 的 `tools/backup_restore/images/`。

### 3. 停止自动挂载服务

```bash
sudo systemctl stop udisks2.service
```

NVIDIA 要求备份和恢复期间暂时关闭自动挂载，防止刷机主机自动占用恢复过程中出现的存储设备。

这只停止当前运行，不会永久禁用 `udisks2`。

### 4. 启动 NFS 服务

```bash
sudo service nfs-kernel-server start
```

`l4t_backup_restore.sh` 会让 Jetson 启动临时 initrd，并通过 Recovery USB 网络挂载刷机主机上的 NFS 目录。备份数据通过该通道写回主机。

### 5. 读取母机 NVMe

```bash
sudo ./tools/backup_restore/l4t_backup_restore.sh \
     --network usb0 \
     -e nvme0n1 \
     -b \
     jetson-agx-orin-devkit
```

执行前，母机必须处于 Force Recovery，并且刷机主机只连接这一台需要备份的 Jetson。

参数说明：

- `--network usb0`：通过刷机 USB 建立 initrd 网络。
- `-e nvme0n1`：备份 Jetson 端整块 NVMe，而不是只备份 `nvme0n1p1`。
- `-b`：执行 backup。
- `jetson-agx-orin-devkit`：使用 AGX Orin DevKit 板型配置。

这里使用 `nvme0n1` 而不是 `nvme0n1p1`，因为 backup_restore 需要保存 GPT 分区表以及 NVMe 上的全部相关分区。

备份输出位于：

```text
Linux_for_Tegra/tools/backup_restore/images/
```

目录中的 `nvpartitionmap.txt` 记录镜像文件、分区设备、起始扇区、大小和校验值。应完整保存整个 `images/` 目录，而不是只保存 APP 镜像。

### 6. 使用脚本打包黄金镜像

读取母机 NVMe 成功后，在刷机主机以普通用户执行一条命令：

```bash
curl -fsSL https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/robotinit/main/scripts/backup.sh | bash -s -- /home/ubuntu/Linux_for_Tegra
```

脚本会把完整 `images/` 打包，并生成对应 MD5。例如 2026 年 7 月 27 日第一次打包会生成：

```text
/home/ubuntu/backup/goldimage_26072701.tar
/home/ubuntu/backup/goldimage_26072701.md5
```

文件名格式是 `goldimage_YYMMDD` 加两位序号。同一天再次打包会依次生成 `goldimage_26072702`、`goldimage_26072703`，不会覆盖已有归档。

### 7. 删除旧镜像并解包

下面以 `goldimage_26072701` 为例。先确认 MD5 显示 `OK`，再删除 BSP 中原有的 `images/` 并解压备份：

```bash
cd "$HOME/backup"

md5sum -c goldimage_26072701.md5

sudo rm -rf /home/ubuntu/Linux_for_Tegra/tools/backup_restore/images

sudo tar -xf goldimage_26072701.tar \
  -C /home/ubuntu/Linux_for_Tegra/tools/backup_restore
```

### 8. 刷写目标机 NVMe

让目标 Jetson 进入 Force Recovery，确认刷机主机能够识别：

```bash
lsusb | grep -i nvidia
```

然后执行：

```bash
cd /home/ubuntu/Linux_for_Tegra

sudo systemctl stop udisks2.service

sudo service nfs-kernel-server start

sudo ./tools/backup_restore/l4t_backup_restore.sh \
     --network usb0 \
     -e nvme0n1 \
     -r \
     jetson-agx-orin-devkit
```

恢复过程会覆盖目标机的 NVMe 数据。

参数说明：

- `--network usb0`：通过 Recovery USB 网络控制临时 initrd。
- `-e nvme0n1`：恢复到目标机的整块第一 NVMe。
- `-r`：从 `tools/backup_restore/images/` 执行 restore。
- `jetson-agx-orin-devkit`：要求目标板型与母机兼容。

目标 NVMe 可以是空盘，也可以已有分区。恢复脚本会先写入黄金镜像的 GPT，再执行 `partprobe`，然后重新格式化和恢复各分区，因此不依赖目标盘原有分区名称。

目标盘的实际扇区数不能小于黄金镜像 GPT 记录的容量。黄金母机应使用所有量产 NVMe 中实际容量最小的型号，使镜像能够恢复到相同或更大的目标盘；不能只按厂商标称容量判断。

恢复后两台设备的 GPT PTUUID、各分区 PARTUUID 和 ESP UUID 可能相同，这是克隆分区表的结果。每台 Jetson 只有一块 NVMe 时不会形成网络冲突，也不会影响正常启动。不要单独随机修改 PARTUUID，因为当前 Jetson 启动参数使用 `root=PARTUUID=...`，只改 GUID 会造成无法启动。

### 9. 归一化目标 NVMe 容量并初始化身份

这是每台目标机恢复后的必选步骤，不能因为目标盘与黄金母盘标称容量相同而跳过。目标机恢复完成并第一次正常开机后执行：

```bash
curl -fsSL https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/robotinit/main/scripts/finalize.sh | sudo bash -s -- m02
```

`m02` 是传给脚本的目标 hostname。下一台设备应按照既定命名规则替换为其他名称。

`finalize.sh` 会按以下顺序执行：

- 确认根文件系统位于 `/dev/nvme0n1p1`，并检查 NVIDIA 扩容脚本及依赖。
- 运行 R36.5 自带的 `/usr/lib/nvidia/resizefs/nvresizefs.sh`。目标盘更大时，将 secondary GPT 移到物理磁盘末端，再在线扩展 APP 和 ext4 文件系统；同容量盘已经占满时正常通过。
- 验证 APP 已到达 NVMe 最后可用扇区，并使用 `sgdisk -v` 检查 GPT 完整性。
- 写入 `/etc/hostname` 和 `/etc/hosts`。
- 重新生成 `/etc/machine-id`。
- 删除黄金镜像中的 SSH host key，并生成 RSA、ECDSA 和 ED25519 新 key。
- 清除目标机首次启动产生的 NetworkManager、USB MAC、随机种子和日志状态。
- 写入 `/var/lib/robotinit/initialized` 标记。
- 自动重启。

NVMe 分区和 ext4 文件系统可以在线扩展，不需要为扩容单独重启。`finalize.sh` 完成其他初始化操作后仍会按原流程统一重启一次。容量归一化位于所有身份修改之前；如果扩容或 GPT 验证失败，脚本会立即退出并保留原 hostname、machine-id 和 SSH host key，修复后可以重新运行。

R36.5 的扩容脚本由 `nvidia-l4t-oem-config` 包提供。它的 `--check` 内部可能修正 secondary GPT 的位置，并非普通只读检查；因此实际归一化只在非 `--check` 的 `finalize.sh` 流程中执行。不要在刷机主机或黄金母机备份前手工运行扩容，也不要修改 GPT、PARTUUID 或 `nvpartitionmap.txt`。

重启后，根文件系统会使用目标 NVMe 的可用容量，hostname、machine-id、SSH host key、Wi-Fi MAC、USB MAC、NetworkManager secret key 和随机种子均为当前设备自己的值。

由于 SSH host key 已改变，管理主机再次连接相同 IP 时可能显示 `REMOTE HOST IDENTIFICATION HAS CHANGED`。这表示管理主机仍保存旧 key，不表示脚本执行失败。

### 10. 可选安装最小桌面

```bash
sudo apt install ubuntu-desktop-minimal
```

这是原步骤中的可选项。只有确实需要本地图形桌面时才执行；黄金母机追求无头和最小化时应跳过。

---

## 五、脚本行为说明

### provision.sh

GitHub Raw 地址：

```text
https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/robotinit/main/scripts/provision.sh
```

脚本自动安装机器人运行环境，默认目标用户为 `ubuntu`，并在该用户的 `.bashrc` 中配置 ROS2 本机通信，同时安装系统级 `python-can 4.6.1`、设置 Jetson MAXN 电源模式，默认结束后重启。它还会验证 ROS2、Python 包、TensorRT、PyTorch CUDA、MAXN 和内核模块。

### sanitize.sh

GitHub Raw 地址：

```text
https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/robotinit/main/scripts/sanitize.sh
```

主要选项：

- `--check`：只检查 Jetson 环境和固定网络绑定。
- `--yes`：跳过交互确认。
- `--purge-apt-lists`：额外清除 APT 软件包索引。

该脚本只应在最终黄金母机上运行，执行完成后会自动关机。

### backup.sh

GitHub Raw 地址：

```text
https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/robotinit/main/scripts/backup.sh
```

该脚本在 x86_64 Ubuntu 刷机主机运行，只负责打包完整 `images/`。默认读取 `~/Linux_for_Tegra`，将归档和 MD5 保存到 `~/backup/`。文件名使用 `goldimage_YYMMDD` 加两位序号，例如 `goldimage_26072701.tar` 和 `goldimage_26072701.md5`。

脚本本身应由普通登录用户运行；读取 root 所有的镜像文件时，脚本会自行执行 `sudo`。可以将 `Linux_for_Tegra` 路径作为唯一参数传入。

### finalize.sh

GitHub Raw 地址：

```text
https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/robotinit/main/scripts/finalize.sh
```

主要参数：

- 第一个位置参数：目标 hostname，例如 `m02`。
- `--hostname <name>`：显式指定 hostname。
- `--check`：只检查环境、hostname 参数和 NVMe 容量归一化依赖，不修改 GPT 或系统身份。
- `--no-reboot`：完成后不自动重启，仅用于调试。

正常生产流程中，每台恢复后的目标机只执行一次。

### rename.sh

该脚本只用于已经投入使用、当前账户仍有进程或桌面会话的 Jetson。它不替代黄金镜像恢复后的 `finalize.sh`。

当前修正版尚未完成一次端到端实机验证，不应直接用于生产设备。

先将脚本下载为本地文件。脚本需要把自身复制到 root-only 工作目录，以便下次开机前执行，因此不支持 `curl | sudo bash`：

```bash
curl -fsSL https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/robotinit/main/scripts/rename.sh \
  -o /tmp/rename.sh
```

只检查当前 `m03` 能否迁移为 `m04`：

```bash
sudo bash /tmp/rename.sh \
  --old-user m03 \
  -u m04 \
  -h m04 \
  --check
```

确认后执行：

```bash
sudo bash /tmp/rename.sh -u m04 -h m04
```

通过 `sudo` 执行时，原用户名默认读取 `SUDO_USER`；root 直接执行或系统中有多个普通用户时应显式添加 `--old-user`。`-h` 在该脚本中表示 hostname，显示帮助必须使用 `--help`。自动化执行可添加 `--yes`，投递任务但暂不重启可添加 `--no-reboot`。

脚本先校验用户名、home、主组、AccountsService 和 Samba 账户冲突，再投递一次性 systemd 任务。第一次重启后，该任务会在 GDM、SSH 和用户会话启动前完成以下操作：

- 保持 UID/GID 不变，迁移用户名、同名主组、home、GECOS 登录显示名称和绝对 home 软链接。
- 迁移 GDM/LightDM/SDDM 自动登录、AccountsService、sudoers、systemd 服务、polkit、cron、systemd linger、subuid/subgid 和邮件文件。
- 更新 `/etc/hostname`、`/etc/hosts` 及文本配置中的旧 home 绝对路径。
- 重建 machine-id 和 SSH host key，清理 NetworkManager 状态、USB MAC、随机种子、DHCP 租约、蓝牙状态、旧日志和机器身份相关缓存。
- 保留用户密码、SSH 私钥、`authorized_keys`、项目数据、Wi-Fi connection profile 和应用配置。

任务完成后自动进行第二次重启，使 PID 1、D-Bus、NetworkManager 和其他服务全部使用新 machine-id。整个过程中 SSH 会断开，客户端还需要删除旧 hostname/IP 对应的 known_hosts 记录。自动备份位于 `/var/lib/robotinit/rename/backup/`，执行日志和残留路径报告位于同一目录；如果任务失败，它会保留并在下次启动时重试。

---

## 六、关键注意事项

1. `Linux_for_Tegra` 必须与 Jetson Linux R36.5 完全匹配。
2. `sanitize.sh` 执行关机后，母机不要再次正常启动，应直接进入 Recovery。
3. backup_restore 的 `-e nvme0n1` 表示整块目标 NVMe，不是刷机主机自己的 NVMe。
4. 恢复会覆盖目标机 NVMe 上的现有数据。
5. 黄金母机应使用所有量产 NVMe 中实际容量最小的型号；目标盘实际扇区数不能小于镜像 GPT 记录的容量。
6. 每台恢复后的目标机第一次正常启动时都必须运行 `finalize.sh`；脚本会先完成 NVMe 容量归一化，再修改设备身份。
7. GPT PARTUUID 相同在一台 Jetson 只安装一块 NVMe 时没有影响，不要脱离启动配置单独修改。
8. 黄金镜像必须保存完整 `images/`，并在每次恢复前验证对应 MD5。
9. HOME 下的归档仍需再复制到另一块硬盘、NAS 或对象存储，不能作为唯一副本。
10. `rename.sh` 会连续启动两次并更换 SSH host key；远程执行前必须确保设备断电恢复后仍能正常启动，并保留本地控制台或 Recovery 手段。
