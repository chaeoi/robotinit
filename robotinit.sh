#!/usr/bin/env bash

# Jetson environment installer.
set -Eeuo pipefail
umask 022

TARGET_USER="${TARGET_USER:-ubuntu}"
AUTO_REBOOT="${AUTO_REBOOT:-1}"

if [[ $EUID -ne 0 ]]; then
  echo "错误：请通过文档中的在线命令以 root 身份执行本脚本。" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONUNBUFFERED=1

STEP=0
TOTAL_STEPS=13
ROS_KEY_TMP=""

cleanup() {
  [[ -z "$ROS_KEY_TMP" ]] || rm -f "$ROS_KEY_TMP"
}

on_error() {
  local exit_code=$?
  echo
  echo "安装失败：步骤 ${STEP}/${TOTAL_STEPS}，脚本第 ${BASH_LINENO[0]} 行，退出码 ${exit_code}。"
  exit "$exit_code"
}

trap cleanup EXIT
trap on_error ERR

step() {
  STEP=$((STEP + 1))
  echo
  echo "================================================================"
  echo "[${STEP}/${TOTAL_STEPS}] $1"
  echo "================================================================"
}

APT_GET=(
  apt-get
  -o Dpkg::Use-Pty=0
  -o DPkg::Lock::Timeout=600
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
)

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "错误：用户 ${TARGET_USER} 不存在。" >&2
  exit 1
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
  echo "错误：无法确定用户 ${TARGET_USER} 的主目录。" >&2
  exit 1
fi

run_as_target() {
  sudo -u "$TARGET_USER" -H "$@"
}

echo "Jetson 一键环境配置开始"
echo "目标用户：$TARGET_USER"

step "更新系统"
"${APT_GET[@]}" update
"${APT_GET[@]}" upgrade -y

step "安装基础下载、编译和 Python 工具"
"${APT_GET[@]}" install -y \
  curl \
  wget \
  unzip \
  build-essential \
  cmake \
  libpopt-dev \
  python3-numpy \
  python3-psutil \
  python3-empy \
  python3-pip

for command_name in curl gpg lsb_release unzip wget; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "错误：缺少文件 5 所依赖的系统命令：${command_name}" >&2
    exit 1
  fi
done

step "添加 ROS2 Humble 软件源"
ROS_KEY_TMP="$(mktemp)"
curl -fsSL https://mirror.nju.edu.cn/rosdistro/ros.asc |
  gpg --dearmor --batch --yes --output "$ROS_KEY_TMP"
install -m 0644 "$ROS_KEY_TMP" /usr/share/keyrings/ros-archive-keyring.gpg
rm -f "$ROS_KEY_TMP"
ROS_KEY_TMP=""

ARCHITECTURE="$(dpkg --print-architecture)"
UBUNTU_CODENAME="$(lsb_release -sc)"
printf '%s\n' \
  "deb [arch=${ARCHITECTURE} signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] https://mirror.nju.edu.cn/ros2/ubuntu ${UBUNTU_CODENAME} main" \
  > /etc/apt/sources.list.d/ros2.list

"${APT_GET[@]}" update

step "安装并配置 ROS2 Humble"
"${APT_GET[@]}" install -y \
  ros-humble-ros-base \
  python3-colcon-core \
  python3-colcon-common-extensions \
  python3-rosdep \
  python3-argcomplete

ROS_SETUP_LINE="source /opt/ros/humble/setup.bash"
TARGET_BASHRC="${TARGET_HOME}/.bashrc"
touch "$TARGET_BASHRC"
if ! grep -Fqx "$ROS_SETUP_LINE" "$TARGET_BASHRC"; then
  printf '\n%s\n' "$ROS_SETUP_LINE" >> "$TARGET_BASHRC"
fi
chown "$TARGET_USER:$TARGET_USER" "$TARGET_BASHRC"

run_as_target bash -c \
  'source /opt/ros/humble/setup.bash && ros2 --help >/dev/null'

step "安装 CAN、手柄和数据通信依赖"
"${APT_GET[@]}" install -y \
  can-utils \
  python3-pygame \
  python3-zmq

run_as_target python3 -m pip install \
  --user \
  --no-input \
  --no-cache-dir \
  "python-can==4.6.1"

step "配置 IMU、手柄权限和内核模块"
usermod -aG dialout,input "$TARGET_USER"
printf '%s\n' "blacklist mttcan" > /etc/modprobe.d/denylist-mttcan.conf

cat > /etc/modules-load.d/q2-robot.conf <<'EOF'
can
can_raw
can_bcm
joydev
kcan
EOF

modprobe can
modprobe can_raw
modprobe can_bcm
modprobe joydev

step "下载并安装 KH-UCANFD 驱动"
KH_WORK_DIR="/tmp/KH-UCANFD"
KH_ZIP="${KH_WORK_DIR}/KH-UCANFD_Linux_SDK.zip"
mkdir -p "$KH_WORK_DIR"

wget --no-verbose -O "$KH_ZIP" \
  https://gitee.com/ChengDu-KunHong/KH-UCANFD_Linux_SDK/releases/download/latest/KH-UCANFD_Linux_SDK.zip
unzip -o "$KH_ZIP" -d "$KH_WORK_DIR"

KH_BUILD_SCRIPT="$(
  find "$KH_WORK_DIR" \
    -mindepth 2 \
    -maxdepth 3 \
    -type f \
    -name build.sh \
    -path '*/KH-UCANFD_Linux_SDK*/*' \
    -print |
    sort -V |
    tail -n 1
)"

if [[ -z "$KH_BUILD_SCRIPT" ]]; then
  echo "错误：解压后没有找到 KH-UCANFD build.sh。" >&2
  exit 1
fi

if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
  echo "错误：当前 Jetson 缺少 KH-UCANFD 已实测使用的内核编译目录：" >&2
  echo "/lib/modules/$(uname -r)/build" >&2
  exit 1
fi

bash "$KH_BUILD_SCRIPT"
modprobe kcan

step "安装 CUDA、cuDNN 和 TensorRT"
"${APT_GET[@]}" install -y \
  nvidia-cuda \
  nvidia-cudnn \
  cuda-cupti-12-6 \
  cuda-nvtx-12-6 \
  tensorrt \
  nvidia-l4t-dla-compiler
ldconfig

step "安装 cuSPARSELt 0.6.2.3"
CUSPARSELT_DIR="/tmp/codex-cusparselt-0.6.2.3"
CUSPARSELT_ARCHIVE="libcusparse_lt-linux-sbsa-0.6.2.3-archive"
CUSPARSELT_TAR="${CUSPARSELT_ARCHIVE}.tar.xz"
mkdir -p "$CUSPARSELT_DIR"
cd "$CUSPARSELT_DIR"

curl -fL --retry 3 --retry-all-errors -O \
  "https://developer.download.nvidia.cn/compute/cusparselt/redist/libcusparse_lt/linux-sbsa/${CUSPARSELT_TAR}"
tar -xf "$CUSPARSELT_TAR"

cp -a \
  "${CUSPARSELT_ARCHIVE}/include/." \
  /usr/local/cuda/include/
cp -a \
  "${CUSPARSELT_ARCHIVE}/lib/." \
  /usr/local/cuda/targets/aarch64-linux/lib/
ldconfig

step "安装 Jetson CUDA 版 PyTorch"
run_as_target python3 -m pip install \
  --user \
  --no-input \
  --no-cache-dir \
  "https://developer.download.nvidia.cn/compute/redist/jp/v61/pytorch/torch-2.5.0a0+872d972e41.nv24.08.17622132-cp310-cp310-linux_aarch64.whl"

step "安装项目指定的 NumPy 1.24.4"
run_as_target python3 -m pip install \
  --user \
  --no-input \
  --no-cache-dir \
  "numpy==1.24.4"

step "验证安装结果"
run_as_target python3 - <<'PY'
import can
import numpy
import pygame
import tensorrt
import torch
import zmq

assert can.__version__ == "4.6.1"
assert numpy.__version__ == "1.24.4"
assert torch.cuda.is_available()

print("python-can:", can.__version__)
print("NumPy:", numpy.__version__)
print("Pygame:", pygame.version.ver)
print("pyzmq:", zmq.__version__)
print("PyTorch:", torch.__version__)
print("CUDA available:", torch.cuda.is_available())
print("TensorRT:", tensorrt.__version__)
PY

run_as_target bash -c \
  'source /opt/ros/humble/setup.bash && ros2 --help >/dev/null'
modprobe can
modprobe can_raw
modprobe can_bcm
modprobe joydev
modprobe kcan

step "完成配置"
echo "全部环境配置和验证已经完成。"

if [[ "$AUTO_REBOOT" == "1" ]]; then
  echo "系统将在 5 秒后自动重启，使用户组、mttcan 黑名单和模块配置全部生效。"
  sync
  sleep 5
  systemctl reboot
else
  echo "AUTO_REBOOT=${AUTO_REBOOT}，已跳过自动重启。"
fi
