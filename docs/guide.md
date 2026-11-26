# Jetson AGX Orin 刷机、环境配置与黄金镜像部署

从空白 Jetson 开始，依次完成刷机、运行环境安装、常用工具配置和黄金镜像制作。已有黄金镜像时，从第四章第 7 步开始恢复并初始化目标机。

## 适用环境

- NVIDIA Jetson AGX Orin DevKit
- Jetson Linux R36.5
- Ubuntu 22.04 Jammy，使用 Basic 无桌面 rootfs
- 外置 NVMe：`nvme0n1`
- 默认用户：`ubuntu`
- ROS 2 Humble
- Python 3.10
- 刷机主机：x86_64 Ubuntu 22.04，用于构建 Jammy rootfs

刷机、备份和恢复沿用本手册准备的 R36.5.0 `Linux_for_Tegra`。第二章通过 APT 更新 Jetson 上的 R36.5 系列软件包。实机记录中的 Jetson 软件包更新到了 R36.5.2。

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
| `provision.sh` | 正常启动的 Jetson | 安装 ROS 2、CAN 和 Python 策略所需的 GPU 运行环境 |
| `sanitize.sh` | 黄金母机 | 清除会被克隆的机器状态并自动关机 |
| `backup.sh` | x86_64 Ubuntu 刷机主机 | 按日期和序号打包完整黄金镜像，并生成 MD5 |
| `finalize.sh` | 恢复后的目标机 | 归一化 NVMe 容量，设置 hostname，重建 machine-id 和 SSH host key，然后重启 |
| `rename.sh` | 已投入使用的 Jetson | 离线迁移用户名、登录界面、home 和 hostname，重建机器身份并重启 |

GitHub Raw 地址使用 `main` 分支。只有文件已经提交并推送到 GitHub 后，远程设备才能通过这些地址下载最新脚本。

---

## 一、刷入最小 Jetson Linux 系统

第 1–12 步在 x86_64 Ubuntu 刷机主机上操作。Jetson 刷入 NVMe 并正常启动后，通过 USB SSH 登录，再在 Jetson 上配置联网。

### 1. 更新刷机主机的软件源

```bash
sudo apt update
```

这条命令在 x86 Ubuntu 刷机主机上执行，只刷新 APT 软件包索引，不会升级已经安装的软件。

### 2. 安装刷机依赖

在刷机主机安装以下软件包。该列表沿用当前 BSP 已跑通的安装配置。NVIDIA 的 `tools/l4t_flash_prerequisites.sh` 还覆盖其他板型和刷机方式。 [NVIDIA 刷机依赖说明](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/FlashingSupport.html#installing-the-flash-requirements)

```bash
sudo apt install -y libxml2-utils python3 sshpass abootimg nfs-kernel-server \
                    binfmt-support binutils qemu-user-static device-tree-compiler \
                    lbzip2 lz4 whois xmlstarlet zstd
```

| 软件包 | 用途 |
| --- | --- |
| `libxml2-utils` | 提供 `xmllint`，NVIDIA 刷机工具用它查询分区布局 XML。 |
| `python3` | 执行 BSP 中的 `tegraflash.py` 等 Python 工具。 |
| `sshpass` | 让刷机主机通过 SSH 自动连接 Jetson 的临时 initrd。 |
| `abootimg` | 提取 `recovery.img` 中的内核和 ramdisk，供刷机工具生成临时 initrd。 |
| `nfs-kernel-server` | 为 USB initrd 刷机、备份和恢复提供文件传输服务。 |
| `binfmt-support`、`qemu-user-static` | 在 x86 主机上注册并运行 ARM64 程序，供 rootfs 构建、安装 NVIDIA 软件包和创建默认用户使用。 |
| `binutils` | 提供 `strings`，initrd 工具用它从 `kernel/Image` 提取内核版本。 |
| `device-tree-compiler` | 提供设备树编译工具。当前 `flash.sh` 优先使用 BSP 自带的 `kernel/dtc`，系统包来自 NVIDIA 通用依赖清单。 |
| `lbzip2` | 供 `apply_binaries.sh` 解包 NVIDIA 组件及内核头文件。 |
| `lz4` | 提供 `lz4c`，供 BSP 的 T194 BPMP 设备树分支使用。当前 AGX Orin 流程没有进入该分支。 |
| `whois` | 提供 `mkpasswd`，供 NVIDIA 的 `nv_preseed.sh` 使用。第 10 步的 `l4t_create_default_user.sh` 使用 `openssl passwd`。 |
| `xmlstarlet` | 供 `flash.sh` 的 `-S` 选项修改 APP 分区 XML。第 12 步使用 BSP 的默认大小。 |
| `zstd` | 压缩和解压刷机及备份的分区镜像，并在打包前校验 APP 归档。 |

新装的刷机主机还需核对已有工具。`wget` 下载基础系统，`bzip2` 供 `tar` 生成 `sample_fs.tbz2`，`cpio` 用于重打包 initrd，`cpp` 用于预处理板级配置，`openssl` 用于生成默认用户的密码哈希，`usbutils` 提供第 11 步的 `lsusb`。如果下面少输出了某一条命令的路径，就补装对应的软件包。

```bash
command -v wget bzip2 cpio cpp openssl lsusb
```

### 3. 下载 Jetson Linux R36.5 BSP

```text
https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v5.0/release/Jetson_Linux_r36.5.0_aarch64.tbz2
```

将 Jetson Linux R36.5.0 Driver Package 保存到刷机主机的用户主目录。下载文件名为 `Jetson_Linux_r36.5.0_aarch64.tbz2`。

### 4. 解压 BSP

```bash
tar xf "$HOME/Jetson_Linux_r36.5.0_aarch64.tbz2" -C "$HOME"
```

解压后会生成 `Linux_for_Tegra` 目录。后续制作 rootfs、刷机、备份和恢复都从该目录执行。

### 5. 进入 BSP 目录

```bash
cd "$HOME/Linux_for_Tegra"
```

后续相对路径都以当前 `Linux_for_Tegra` 为基准。切换终端后，应重新确认当前目录，避免在错误的 BSP 版本中执行命令。

### 6. 生成 Ubuntu Jammy Basic rootfs

Basic 的包列表需要补上 `gdisk`。后续 NVIDIA 会从 BSP 的 `rootfs/usr/sbin/sgdisk` 复制该工具到备份和恢复用的 initrd，因此要在生成 rootfs 时加入。

```bash
grep -Fqx gdisk tools/samplefs/nvubuntu-jammy-basic-aarch64-packages || \
  echo gdisk | sudo tee -a tools/samplefs/nvubuntu-jammy-basic-aarch64-packages
```

```bash
sudo ./tools/samplefs/nv_build_samplefs.sh \
     --abi aarch64 \
     --distro ubuntu \
     --version jammy \
     --flavor basic
```

参数说明：

- `--abi aarch64`：生成 ARM64 用户空间。
- `--distro ubuntu`：使用 Ubuntu。
- `--version jammy`：对应 Ubuntu 22.04。
- `--flavor basic`：生成只保留 BSP 和 NVIDIA 容器基础依赖的无桌面系统。

刷入 Basic 后，通过 USB SSH 安装 NetworkManager，再连接 Wi-Fi。详见本章第 13、14 步。 [NVIDIA Basic rootfs 文档](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/RootFileSystem.html#basic-flavor-root-file-system)

命令完成后应得到 `tools/samplefs/sample_fs.tbz2`。确认文件已生成，再清空旧的 rootfs 目录。

### 7. 清空 BSP 当前 rootfs

```bash
sudo rm -rf rootfs/*
```

执行前用 `pwd` 确认位于第 5 步进入的 `Linux_for_Tegra` 目录。这条命令删除该 BSP 的旧 rootfs，使下一步能够解出一份干净的系统。

### 8. 解压 rootfs

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

该脚本向 Ubuntu rootfs 安装 NVIDIA 驱动、固件、库、内核模块和 Jetson 平台组件。完成后可用 `test -x rootfs/usr/sbin/sgdisk` 核对备份和恢复需要的工具已写入 BSP。

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
lsusb | grep -i 'NVIDIA.*APX'
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

实测该命令会写入目标 NVMe、内部 eMMC 和 QSPI。刷机前先备份需要保留的数据，尤其是内部 eMMC。第四章的 `-e nvme0n1` 黄金镜像只包含 NVMe 和 QSPI。刷机完成后让 Jetson 正常启动。

### 13. 通过 USB Device Mode 登录并安装 NetworkManager

Basic 首次启动后，Jetson 通过刷机 USB-C 提供地址为 `192.168.55.1` 的 USB 网络。用第 10 步设置的密码登录。以下命令在刷机主机执行，登录的同时为 Jetson 提供临时 SOCKS 代理。保持该会话连接。

```bash
ssh -o ExitOnForwardFailure=yes -R 127.0.0.1:1080 ubuntu@192.168.55.1
```

在这个 Jetson SSH 会话里刷新软件包索引并安装 `network-manager`。它提供下一步扫描、连接和保存 Wi-Fi 所需的 `nmcli`。

```bash
sudo apt-get \
  -o Acquire::http::Proxy="socks5h://127.0.0.1:1080" \
  -o Acquire::https::Proxy="socks5h://127.0.0.1:1080" \
  -o APT::Update::Error-Mode=any update
```

```bash
sudo apt-get \
  -o Acquire::http::Proxy="socks5h://127.0.0.1:1080" \
  -o Acquire::https::Proxy="socks5h://127.0.0.1:1080" \
  install -y --no-install-recommends network-manager
```

```bash
sudo systemctl enable --now NetworkManager
```

`-R` 在 Jetson 上监听 `127.0.0.1:1080`，由刷机电脑发起外部连接；`socks5h` 也通过代理解析域名。这些 APT 代理参数只对当前命令生效，连上 Wi-Fi 后无需保留代理配置。普通 USB SSH 连接本身不会自动共享电脑的互联网连接。

### 14. 连接指定 Wi-Fi

刚启动 NetworkManager 时，Wi-Fi 扫描可能还没完成。先确认列表里出现目标 SSID，再连接。

```bash
nmcli device wifi list --rescan yes
```

```bash
sudo nmcli --wait 60 device wifi connect "Cudy-89D0" password "13594954"
```

NetworkManager 会创建并保存 `Cudy-89D0` 的连接 profile。该 profile 后续会被保留进黄金镜像，使恢复后的目标机能够自动连接同一 Wi-Fi。

连接 profile 的 UUID 可以在多台设备上相同，不等于 machine-id，也不会造成网络身份冲突。每台设备仍使用自己的 Wi-Fi MAC、DHCP 租约和 NetworkManager 主机密钥。

---

## 二、安装机器人运行环境

在已联网的 Jetson 上以 `ubuntu` 登录。完成第 0 步并重启后，执行自动化脚本或按第 1–13 步手动安装。按顺序逐块执行命令，上一条成功后再继续。用到同一变量的命令在同一个终端运行。

### 0. 更新系统并安装前置组件

```bash
sudo apt-get -o APT::Update::Error-Mode=any update
```

```bash
sudo apt-get install -y --no-install-recommends fwupd udisks2 i2c-tools curl
```

```bash
sudo apt-get upgrade -y
```

```bash
sudo reboot
```

- `fwupd` 提供 Jetson bootloader 升级使用的 `fwupdmgr` 和 `fwupdtool`。
- `udisks2` 帮助 `fwupd` 识别 EFI 系统分区。Basic 实机曾因缺少它而报 `UEFI ESP partition not detected or configured`。补齐软件包并核对 ESP 挂载后，可用 `sudo dpkg --configure -a` 完成中断的升级。
- `i2c-tools` 提供 bootloader 配置读取板卡信息所用的 `i2cget`。
- `curl` 用于后续下载配置脚本、ROS 2 签名密钥、驱动和推理依赖。

重启使更新后的 bootloader 和内核生效。重新登录后，确认运行中的内核和编译目录。KH-UCANFD 将使用这个目录编译驱动。

```bash
uname -r
```

```bash
test -d "/lib/modules/$(uname -r)/build"
```

### 自动化脚本

第 0 步检查通过后，在 Jetson 上执行以下命令。脚本安装并验证运行环境，设置 MAXN 后自动重启。重新登录后直接进入第三章。

```bash
curl -fsSL https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/robotinit/main/scripts/provision.sh | sudo bash
```

### 手动安装步骤

选择手动安装时，从第 1 步开始。

### 1. 安装基础下载和编译工具

```bash
sudo apt-get install -y --no-install-recommends curl gpg unzip xz-utils build-essential
```

- `curl` 用于下载 ROS 2 签名密钥和后续安装文件。第 0 步已安装时，APT 会复用。
- `gpg` 将 ROS 2 软件源的签名密钥转成 APT 使用的二进制 keyring。
- `unzip` 解开 KH-UCANFD SDK 的 ZIP 包。
- `xz-utils` 提供 cuSPARSELt 的 `.tar.xz` 归档所需的解压程序。
- `build-essential` 提供 GCC、G++ 和 Make，用于编译 `kcan` 和项目里的 ROS 2 C++ 节点。

### 2. 安装基础 Python 工具

```bash
sudo apt-get install -y --no-install-recommends python3-pip
```

`python3-pip` 用于安装系统级 `python-can`，以及 `ubuntu` 用户下的 NVIDIA PyTorch wheel 和固定版本的 NumPy。

### 3. 安装 ROS 2 Humble

先下载南京大学 ROS 2 镜像的签名密钥并写入 APT keyring，再添加 Ubuntu Jammy 软件源。

```bash
ros_key="$(mktemp)"
```

```bash
curl -fsSL https://mirror.nju.edu.cn/rosdistro/ros.asc |
  gpg --dearmor --batch --yes --output "$ros_key"
```

```bash
sudo install -m 0644 "$ros_key" /usr/share/keyrings/ros-archive-keyring.gpg
```

```bash
unlink "$ros_key"
```

密钥写入成功后，登记软件源。

```bash
source /etc/os-release
```

```bash
printf '%s\n' \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] https://mirror.nju.edu.cn/ros2/ubuntu ${VERSION_CODENAME} main" |
  sudo tee /etc/apt/sources.list.d/ros2.list >/dev/null
```

APT 使用 `signed-by` 指定的密钥校验该软件源。添加软件源后重新刷新索引，再安装 ROS 2 和工作空间构建组件。

```bash
sudo apt-get -o APT::Update::Error-Mode=any update
```

```bash
sudo apt-get install -y --no-install-recommends \
  ros-humble-ros-core \
  python3-colcon-bash \
  python3-colcon-package-selection \
  python3-colcon-ros
```

- `ros-humble-ros-core` 提供 `ros2`、`rclcpp`、`rclpy`、基础消息以及构建接口所需的 ament 和 rosidl。Yesense、电机主控和策略通过它们交换数据。
- `python3-colcon-bash` 生成工作空间的 Bash 环境文件，使启动脚本可加载 `install/setup.bash`。
- `python3-colcon-package-selection` 提供 `--packages-select`，用于只编译指定的 IMU 或电机包。
- `python3-colcon-ros` 提供对 ROS 工作空间的识别和构建支持，并通过依赖安装 colcon 主程序和相应的 CMake 扩展。

以 `ubuntu` 执行以下命令，让当前及后续打开的 Bash 终端可直接使用 ROS 2，并将节点通信限制在本机。

```bash
grep -Fxq 'source /opt/ros/humble/setup.bash' ~/.bashrc ||
  printf '\n%s\n' 'source /opt/ros/humble/setup.bash' >> ~/.bashrc
```

```bash
grep -Fxq 'export ROS_LOCALHOST_ONLY=1' ~/.bashrc ||
  printf '%s\n' 'export ROS_LOCALHOST_ONLY=1' >> ~/.bashrc
```

```bash
source /opt/ros/humble/setup.bash
```

```bash
export ROS_LOCALHOST_ONLY=1
```

```bash
ros2 --help
```

```bash
colcon build --help | grep -F -- '  --packages-select '
```

### 4. 安装 CAN、手柄和策略所用的 Python 库

```bash
sudo apt-get install -y --no-install-recommends \
  python3-pygame python3-scipy python3-yaml python3-zmq
```

```bash
sudo python3 -m pip install --no-input --no-cache-dir 'python-can==4.6.1'
```

- `python3-pygame` 读取 USB 手柄摇杆和按键。
- `python3-scipy` 为策略提供姿态旋转计算。
- `python3-yaml` 用于读取策略的 YAML 配置。
- `python3-zmq` 用于发布控制和关节遥测。
- `python-can` 提供 Python 工具使用的 SocketCAN 接口。安装到系统 Python 路径后，`ubuntu` 和通过 `sudo python3` 运行的 CAN 工具可以导入同一版本。

### 5. 配置 IMU 和手柄访问权限

```bash
sudo usermod -aG dialout,input ubuntu
```

`dialout` 允许 `ubuntu` 访问 Yesense IMU 对应的 `/dev/ttyACM0`，`input` 用于读取手柄设备。IMU 的 `cdc_acm` 由 Jetson 内核提供。下一步重启后，新用户组生效。

### 6. 禁用 Jetson 自带的 mttcan

在使用 KH-UCANFD 的主控上，写入黑名单，避免 Jetson 自带的 `mttcan` 自动加载。重启后重新登录。

```bash
printf '%s\n' 'blacklist mttcan' | sudo tee /etc/modprobe.d/denylist-mttcan.conf
```

```bash
sudo reboot
```

### 7. 重启后加载 CAN 和手柄内核模块

```bash
sudo modprobe can
```

```bash
sudo modprobe can_raw
```

```bash
sudo modprobe can_bcm
```

```bash
sudo modprobe joydev
```

`can` 提供内核 CAN 支持，`can_raw` 提供 SocketCAN 的 RAW socket，`can_bcm` 提供 CAN Broadcast Manager，`joydev` 为手柄提供 `/dev/input/js*` 接口。

### 8. 安装 KH-UCANFD 驱动

在临时目录下载并解压 SDK。`build.sh` 根据运行中的 Jetson 内核构建并安装 `kcan`。确认编译目录和安装入口都存在，再运行安装。

```bash
sdk_dir="$(mktemp -d)"
```

```bash
curl -fL --retry 3 -o "$sdk_dir/KH-UCANFD_Linux_SDK.zip" \
  https://gitee.com/ChengDu-KunHong/KH-UCANFD_Linux_SDK/releases/download/latest/KH-UCANFD_Linux_SDK.zip
```

```bash
unzip -o "$sdk_dir/KH-UCANFD_Linux_SDK.zip" -d "$sdk_dir"
```

```bash
kh_build_script="$(find "$sdk_dir" -mindepth 2 -maxdepth 3 -type f -name build.sh \
  -path '*/KH-UCANFD_Linux_SDK*/*' -print | sort -V | tail -n 1)"
```

```bash
test -d "/lib/modules/$(uname -r)/build"
```

```bash
test -f "$kh_build_script"
```

```bash
sudo bash "$kh_build_script"
```

```bash
sudo modprobe kcan
```

安装成功后，写入开机加载列表。`kcan` 负责把 KH-UCANFD 设备注册为 SocketCAN 接口，有转接器插入时可用 `ip -br link show type can` 查看。

```bash
printf '%s\n' can can_raw can_bcm joydev kcan |
  sudo tee /etc/modules-load.d/q2-robot.conf >/dev/null
```

```bash
modinfo -F version kcan
```

### 9. 安装 CUDA、cuDNN 和 TensorRT 运行库

```bash
sudo apt-get install -y --no-install-recommends \
  cuda-cudart-12-6 cuda-cupti-12-6 cuda-nvrtc-12-6 cuda-nvtx-12-6 \
  libcublas-12-6 libcudla-12-6 libcufft-12-6 libcurand-12-6 \
  libcusolver-12-6 libcusparse-12-6 libnvjitlink-12-6 \
  nvidia-cudnn python3-libnvinfer nvidia-l4t-dla-compiler
```

```bash
sudo ldconfig
```

| 软件包 | 安装原因 |
| --- | --- |
| `cuda-cudart-12-6` | 提供 CUDA 设备、内存和执行流所用的运行时。 |
| `cuda-cupti-12-6`、`cuda-nvtx-12-6` | 提供 Jetson 版 PyTorch 加载的 `libcupti.so.12` 和 `libnvToolsExt.so.1`。 |
| `cuda-nvrtc-12-6`、`libnvjitlink-12-6` | 为 CUDA 库提供运行时编译和链接支持。 |
| `libcublas-12-6`、`libcufft-12-6`、`libcurand-12-6`、`libcusolver-12-6`、`libcusparse-12-6` | 提供已验证运行环境中的矩阵乘法、FFT、随机数、线性求解和稀疏运算库。 |
| `libcudla-12-6`、`nvidia-l4t-dla-compiler` | 提供 Jetson TensorRT 引擎库链接所需的 `libcudla.so.1` 和 `libnvdla_compiler.so`。 |
| `nvidia-cudnn` | 安装 NVIDIA PyTorch 所需的 cuDNN GPU 算子库。 |
| `python3-libnvinfer` | 提供 `import tensorrt` 所需的 Python 绑定，并通过依赖安装推理引擎、插件和 ONNX 解析器。 |

`ldconfig` 更新动态链接库缓存。当前 Python 策略使用这些运行库从 ONNX 构建 TensorRT 引擎并推理。

### 10. 安装 cuSPARSELt

当前 Jetson PyTorch wheel 加载 `libcusparseLt.so.0`。将 cuSPARSELt 0.6.2.3 归档中的这个动态库及版本文件复制到 CUDA 12.6 库目录。

```bash
gpu_dir="$(mktemp -d)"
```

```bash
cusparselt=libcusparse_lt-linux-sbsa-0.6.2.3-archive
```

```bash
curl -fL --retry 3 -o "$gpu_dir/$cusparselt.tar.xz" \
  "https://developer.download.nvidia.cn/compute/cusparselt/redist/libcusparse_lt/linux-sbsa/$cusparselt.tar.xz"
```

```bash
tar -xf "$gpu_dir/$cusparselt.tar.xz" -C "$gpu_dir"
```

```bash
sudo cp -a --no-preserve=ownership \
  "$gpu_dir/$cusparselt"/lib/libcusparseLt.so.0* \
  /usr/local/cuda-12.6/targets/aarch64-linux/lib/
```

```bash
sudo ldconfig
```

### 11. 安装 Jetson CUDA 版 PyTorch

以 `ubuntu` 执行，安装在当前用户的 Python 环境中。这个 NVIDIA wheel 对应 ARM64 和 Python 3.10。策略用它管理 TensorRT 的 CUDA 张量，也可用它加载 TorchScript 模型。NumPy 与 PyTorch 在同一条命令安装，以锁定该 wheel 已验证的 NumPy 版本。

```bash
python3 -m pip install --user --no-input --no-cache-dir 'numpy==1.24.4' \
  'https://developer.download.nvidia.cn/compute/redist/jp/v61/pytorch/torch-2.5.0a0+872d972e41.nv24.08.17622132-cp310-cp310-linux_aarch64.whl'
```

### 12. 检查 NumPy 和 Python 推理环境

NumPy 1.24.4 满足当前 PyTorch wheel 的 NumPy C API 要求。以下命令检查安装版本、Python 模块和基本 CUDA 运算。自动化脚本还会构建并执行一次 TensorRT GPU 推理。

```bash
python3 - <<'PY'
import can
import numpy as np
import pygame
import tensorrt
import torch
import yaml
import zmq
from scipy.spatial.transform import Rotation

assert can.__version__ == "4.6.1"
assert np.__version__ == "1.24.4"
assert np.allclose(Rotation.identity().as_matrix(), np.eye(3))
tensor = torch.arange(4, device="cuda", dtype=torch.float32)
assert torch.equal(tensor.cpu(), torch.arange(4, dtype=torch.float32))
print("PyTorch", torch.__version__)
print("TensorRT", tensorrt.__version__)
print("CUDA device", torch.cuda.get_device_name(0))
PY
```

### 13. 配置 Jetson MAXN 电源模式

在 AGX Orin 上选择 `mode 0`，使策略运行时可用 MAXN 的核心和频率上限。如果命令询问是否重启，输入 `YES`。重启后查询当前电源模式。

```bash
sudo /usr/sbin/nvpmodel -m 0
```

```bash
sudo /usr/sbin/nvpmodel -q
```

预期显示 `NV Power Mode: MAXN` 和模式号 `0`。确认后继续安装常用工具。

---

## 三、安装常用工具

在运行环境安装完成的 Jetson 上，以 `ubuntu` 登录并按顺序配置 Git、mDNS 和 code-server。

### 1. 更新软件源

```bash
sudo apt update
```

确保后续安装 `git` 和 `avahi-daemon` 时使用最新的软件包索引。

### 2. 安装 Git

```bash
sudo apt install git
```

`git` 用于获取和管理机器人应用代码。电机工作空间首次构建时，CMake 也会用它获取项目指定版本的 spdlog。

### 3. 安装 mDNS 服务

```bash
sudo apt install avahi-daemon
```

Avahi 提供 `.local` 主机名解析。设备 hostname 为 `m00` 时，同一局域网通常可以通过 `m00.local` 访问。

多台克隆设备必须在运行 `finalize.sh` 后拥有不同 hostname，否则 `.local` 名称会冲突。

### 4. 编辑 code-server 配置

```bash
mkdir -p /home/ubuntu/.config/code-server
```

```bash
cat > /home/ubuntu/.config/code-server/config.yaml <<'EOF'
bind-addr: 0.0.0.0:80
auth: password
password: 123
cert: false
EOF
```

```bash
chmod 600 /home/ubuntu/.config/code-server/config.yaml
```

这组命令直接生成 `config.yaml`，供 code-server 启动时读取。

字段说明：

- `bind-addr`：监听所有网络接口的80端口。80是特权端口，普通用户需要通过
  systemd capability 配置才能监听。
- `auth: password`：启用密码认证。
- `password: 123`：设置访问密码。
- `cert: false`：不在 code-server 内部启用 TLS。

该服务会暴露到局域网，生产环境应通过可信网络、防火墙或反向代理限制访问。

### 5. 安装 code-server

在 Jetson 上运行 code-server 官方安装脚本。脚本会识别 Ubuntu 和 ARM64，安装当前发布的对应软件包。安装后可通过浏览器编辑代码和使用终端。 [code-server 官方安装说明](https://coder.com/docs/code-server/install#installsh)

```bash
curl -fsSL https://code-server.dev/install.sh | sh
```

### 6. 为服务授予监听80端口的 capability

code-server 默认以当前用户运行，不能直接监听80端口。为当前用户的 systemd
实例创建 drop-in：

```bash
sudo mkdir -p "/etc/systemd/system/code-server@${USER}.service.d"
```

```bash
sudo tee "/etc/systemd/system/code-server@${USER}.service.d/override.conf" >/dev/null <<'EOF'
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
EOF
```

`AmbientCapabilities=CAP_NET_BIND_SERVICE` 仅授予绑定1024以下端口所需的 capability。

```bash
sudo systemctl daemon-reload
```

### 7. 启用并启动服务

```bash
sudo systemctl enable code-server@$USER
```

```bash
sudo systemctl restart code-server@$USER
```

- `enable`：设置开机自动启动。
- `restart`：立即启动服务；如果服务已经运行，则重新创建进程以应用新的 capability。
- `$USER`：使用当前登录用户的 systemd 实例，正常情况下为 `ubuntu`。

用 `systemctl is-active code-server@$USER` 确认服务已运行，再从同一局域网用 Jetson 的 IP 或 `m00.local` 打开登录页。

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
cd "$HOME/Linux_for_Tegra"
```

进入第一章准备的 R36.5.0 BSP 目录。后续备份镜像会写入该目录的 `tools/backup_restore/images/`。

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

确认母机已进入 Force Recovery，且刷机主机只连接这一台 Jetson。随后在刷机主机读取镜像。

```bash
lsusb | grep -i 'NVIDIA.*APX'
```

```bash
sudo ./tools/backup_restore/l4t_backup_restore.sh \
     --network usb0 \
     -e nvme0n1 \
     -b \
     jetson-agx-orin-devkit
```

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

脚本先用 `zstd -t` 检查分区归档能否完整解压，再把完整 `images/` 打包并生成对应 MD5。分区归档如果报校验错误，需要重新读取母机。例如 2026 年 7 月 27 日第一次打包会生成：

```text
/home/ubuntu/backup/goldimage_26072701.tar
/home/ubuntu/backup/goldimage_26072701.md5
```

文件名格式是 `goldimage_YYMMDD` 加两位序号。同一天再次打包会依次生成 `goldimage_26072702`、`goldimage_26072703`，不会覆盖已有归档。

实机遇到过 `Restored data doesn't match checksum`。这时先移走本次的 `images/`，把 BSP 的 `tools/backup_restore/nvbackup_partitions.sh` 中的 `zstd -T0` 改成 `zstd -T1`，再读取一次母机。重新生成的分区归档通过解压校验后再打包和恢复。

### 7. 删除旧镜像并解包

在刷机主机核对归档与对应的 MD5 文件。以下以 `goldimage_26072701` 为例。

```bash
cd "$HOME/backup"
```

```bash
md5sum -c goldimage_26072701.md5
```

看到 `OK` 后，确认下面指向本次使用的 BSP，再删除原有 `images/` 并解包。

```bash
sudo rm -rf /home/ubuntu/Linux_for_Tegra/tools/backup_restore/images
```

```bash
sudo tar -xf goldimage_26072701.tar \
  -C /home/ubuntu/Linux_for_Tegra/tools/backup_restore
```

解包后应在 BSP 的 `tools/backup_restore/images/` 下看到 `nvpartitionmap.txt` 和各分区镜像。

### 8. 刷写目标机 NVMe

让目标 Jetson 进入 Force Recovery，确认刷机主机能够识别：

```bash
lsusb | grep -i 'NVIDIA.*APX'
```

然后执行：

```bash
cd "$HOME/Linux_for_Tegra"
```

```bash
sudo systemctl stop udisks2.service
```

```bash
sudo service nfs-kernel-server start
```

```bash
sudo ./tools/backup_restore/l4t_backup_restore.sh \
     --network usb0 \
     -e nvme0n1 \
     -r \
     jetson-agx-orin-devkit
```

恢复过程会覆盖目标机的 NVMe 数据。归档包含 `QSPI0.img` 时，也会写入 QSPI。

参数说明：

- `--network usb0`：通过 Recovery USB 网络控制临时 initrd。
- `-e nvme0n1`：恢复到目标机的整块第一 NVMe。
- `-r`：从 `tools/backup_restore/images/` 执行 restore。
- `jetson-agx-orin-devkit`：要求目标板型与母机兼容。

目标 NVMe 可以是空盘，也可以已有分区。恢复脚本会先写入黄金镜像的 GPT，再执行 `partprobe`，然后重新格式化和恢复各分区，因此不依赖目标盘原有分区名称。

看到 `Successful restore of partitions on target board` 后，设备仍在临时 initrd 中。重启 Jetson，等待正常系统启动，再执行下一步。

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

恢复并初始化后，可用 `sudo nvbootctrl dump-slots-info` 查看实际启动的 bootloader 版本。如果 `Capsule update status` 为 `2` 且 `Current version` 低于 `dpkg-query -W nvidia-l4t-bootloader` 显示的版本，可重新应用已安装包的固件，再重启验证。

```bash
sudo dpkg-reconfigure nvidia-l4t-bootloader
```

```bash
sudo reboot
```

实机记录中，恢复后最初从 36.5.0 bootloader 启动。重新应用已安装的固件并重启后，`Current version` 为 36.5.2，`Capsule update status` 为 `1`。 [NVIDIA Bootloader 更新文档](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/Bootloader/UpdateAndRedundancy.html#manually-trigger-the-capsule-update)

---

## 五、脚本行为说明

### provision.sh

GitHub Raw 地址：

```text
https://gitwarp.canghai.org/raw.githubusercontent.com/chaeoi/robotinit/main/scripts/provision.sh
```

脚本自动安装机器人运行环境，默认目标用户为 `ubuntu`，并在该用户的 `.bashrc` 中配置 ROS2 本机通信，同时安装系统级 `python-can 4.6.1`、设置 Jetson MAXN 电源模式，默认结束后重启。验证覆盖 ROS 2、colcon、Python 依赖、TensorRT GPU 运算、MAXN 和内核模块。

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

1. 刷机、备份和恢复使用第一章准备的 R36.5.0 `Linux_for_Tegra`。
2. `sanitize.sh` 执行关机后，母机不要再次正常启动，应直接进入 Recovery。
3. backup_restore 的 `-e nvme0n1` 表示整块目标 NVMe，不是刷机主机自己的 NVMe。
4. 恢复会覆盖目标机 NVMe 上的现有数据。
5. 黄金母机应使用所有量产 NVMe 中实际容量最小的型号；目标盘实际扇区数不能小于镜像 GPT 记录的容量。
6. 每台恢复后的目标机第一次正常启动时都必须运行 `finalize.sh`；脚本会先完成 NVMe 容量归一化，再修改设备身份。
7. GPT PARTUUID 相同在一台 Jetson 只安装一块 NVMe 时没有影响，不要脱离启动配置单独修改。
8. 黄金镜像必须保存完整 `images/`，并在每次恢复前验证对应 MD5。
9. HOME 下的归档仍需再复制到另一块硬盘、NAS 或对象存储，不能作为唯一副本。
10. `rename.sh` 会连续启动两次并更换 SSH host key；远程执行前必须确保设备断电恢复后仍能正常启动，并保留本地控制台或 Recovery 手段。
