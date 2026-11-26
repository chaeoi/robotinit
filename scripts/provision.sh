#!/usr/bin/env bash

# Jetson robot environment provisioner.
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
TOTAL_STEPS=12
ROS_KEY_TMP=""
DOWNLOAD_DIR=""
NVP_REBOOT_HELPER_DIR=""

cleanup() {
  [[ -z "$ROS_KEY_TMP" ]] || rm -f "$ROS_KEY_TMP"
  [[ -z "$DOWNLOAD_DIR" ]] || rm -rf -- "$DOWNLOAD_DIR"
  if [[ -n "$NVP_REBOOT_HELPER_DIR" ]]; then
    rm -f "$NVP_REBOOT_HELPER_DIR/reboot"
    rmdir "$NVP_REBOOT_HELPER_DIR" 2>/dev/null || true
  fi
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

step "安装下载、编译和 Python 工具"
# samplefs 可能保留旧索引；先刷新，避免已安装包与待安装依赖版本冲突。
"${APT_GET[@]}" -o APT::Update::Error-Mode=any update
# basic rootfs 不包含 minimal 中的全部工具，不能依赖镜像预装。
"${APT_GET[@]}" install -y --no-install-recommends \
  curl \
  gpg \
  unzip \
  xz-utils \
  build-essential \
  python3-pip

step "添加 ROS2 Humble 软件源"
ROS_KEY_TMP="$(mktemp)"
curl -fsSL https://mirror.nju.edu.cn/rosdistro/ros.asc |
  gpg --dearmor --batch --yes --output "$ROS_KEY_TMP"
install -m 0644 "$ROS_KEY_TMP" /usr/share/keyrings/ros-archive-keyring.gpg
rm -f "$ROS_KEY_TMP"
ROS_KEY_TMP=""

ARCHITECTURE="$(dpkg --print-architecture)"
# shellcheck disable=SC1091
source /etc/os-release
printf '%s\n' \
  "deb [arch=${ARCHITECTURE} signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] https://mirror.nju.edu.cn/ros2/ubuntu ${VERSION_CODENAME} main" \
  > /etc/apt/sources.list.d/ros2.list

"${APT_GET[@]}" -o APT::Update::Error-Mode=any update

step "安装 ROS2 Humble 和工作空间构建工具"
"${APT_GET[@]}" install -y --no-install-recommends \
  ros-humble-ros-core \
  python3-colcon-bash \
  python3-colcon-package-selection \
  python3-colcon-ros

ROS_SETUP_LINE="source /opt/ros/humble/setup.bash"
ROS_LOCALHOST_LINE="export ROS_LOCALHOST_ONLY=1"
TARGET_BASHRC="${TARGET_HOME}/.bashrc"
touch "$TARGET_BASHRC"
if ! grep -Fqx "$ROS_SETUP_LINE" "$TARGET_BASHRC"; then
  printf '\n%s\n' "$ROS_SETUP_LINE" >> "$TARGET_BASHRC"
fi
if ! grep -Fqx "$ROS_LOCALHOST_LINE" "$TARGET_BASHRC"; then
  printf '%s\n' "$ROS_LOCALHOST_LINE" >> "$TARGET_BASHRC"
fi
chown "$TARGET_USER:$TARGET_USER" "$TARGET_BASHRC"

export ROS_LOCALHOST_ONLY=1

run_as_target bash -c \
  'source /opt/ros/humble/setup.bash && ros2 --help >/dev/null'

step "安装 CAN、手柄和策略计算依赖"
"${APT_GET[@]}" install -y --no-install-recommends \
  python3-pygame \
  python3-scipy \
  python3-yaml \
  python3-zmq

python3 -m pip install \
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
DOWNLOAD_DIR="$(mktemp -d)"
KH_WORK_DIR="${DOWNLOAD_DIR}/KH-UCANFD"
KH_ZIP="${KH_WORK_DIR}/KH-UCANFD_Linux_SDK.zip"
mkdir -p "$KH_WORK_DIR"

curl -fL --retry 3 --retry-all-errors -o "$KH_ZIP" \
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

step "安装 CUDA、cuDNN 和 TensorRT 运行库"
"${APT_GET[@]}" install -y --no-install-recommends \
  cuda-cudart-12-6 \
  cuda-cupti-12-6 \
  cuda-nvrtc-12-6 \
  cuda-nvtx-12-6 \
  libcublas-12-6 \
  libcudla-12-6 \
  libcufft-12-6 \
  libcurand-12-6 \
  libcusolver-12-6 \
  libcusparse-12-6 \
  libnvjitlink-12-6 \
  nvidia-cudnn \
  python3-libnvinfer \
  nvidia-l4t-dla-compiler
ldconfig

step "安装 cuSPARSELt 0.6.2.3"
CUSPARSELT_DIR="${DOWNLOAD_DIR}/cusparselt"
CUSPARSELT_ARCHIVE="libcusparse_lt-linux-sbsa-0.6.2.3-archive"
CUSPARSELT_TAR="${CUSPARSELT_ARCHIVE}.tar.xz"
mkdir -p "$CUSPARSELT_DIR"
cd "$CUSPARSELT_DIR"

curl -fL --retry 3 --retry-all-errors -O \
  "https://developer.download.nvidia.cn/compute/cusparselt/redist/libcusparse_lt/linux-sbsa/${CUSPARSELT_TAR}"
tar -xf "$CUSPARSELT_TAR"

cp -a --no-preserve=ownership \
  "${CUSPARSELT_ARCHIVE}"/lib/libcusparseLt.so.0* \
  /usr/local/cuda-12.6/targets/aarch64-linux/lib/
ldconfig

step "安装 Jetson CUDA 版 PyTorch 和 NumPy 1.24.4"
run_as_target python3 -m pip install \
  --user \
  --no-input \
  --no-cache-dir \
  "numpy==1.24.4" \
  "https://developer.download.nvidia.cn/compute/redist/jp/v61/pytorch/torch-2.5.0a0+872d972e41.nv24.08.17622132-cp310-cp310-linux_aarch64.whl"

step "验证安装结果"
grep -Fqx "$ROS_LOCALHOST_LINE" "$TARGET_BASHRC"

python3 - <<'PY'
import can

assert can.__version__ == "4.6.1"
print("System python-can:", can.__version__, can.__file__)
PY

run_as_target python3 - <<'PY'
import can
import numpy
import pygame
import tensorrt
import torch
import yaml
import zmq
from scipy.spatial.transform import Rotation

assert can.__version__ == "4.6.1"
assert numpy.__version__ == "1.24.4"
assert torch.cuda.is_available()
assert numpy.allclose(Rotation.identity().as_matrix(), numpy.eye(3))

logger = tensorrt.Logger(tensorrt.Logger.ERROR)
builder = tensorrt.Builder(logger)
network = builder.create_network(0)
tensor = network.add_input("input", tensorrt.float32, (1, 4))
output = network.add_identity(tensor).get_output(0)
output.name = "output"
network.mark_output(output)
serialized = builder.build_serialized_network(network, builder.create_builder_config())
assert serialized is not None
runtime = tensorrt.Runtime(logger)
engine = runtime.deserialize_cuda_engine(serialized)
context = engine.create_execution_context()
input_gpu = torch.arange(4, device="cuda", dtype=torch.float32).reshape(1, 4)
output_gpu = torch.empty_like(input_gpu)
assert context.set_tensor_address("input", input_gpu.data_ptr())
assert context.set_tensor_address("output", output_gpu.data_ptr())
assert context.execute_async_v3(torch.cuda.current_stream().cuda_stream)
torch.cuda.synchronize()
assert torch.equal(input_gpu, output_gpu)

print("python-can:", can.__version__)
print("NumPy:", numpy.__version__)
print("Pygame:", pygame.version.ver)
print("PyYAML:", yaml.__version__)
print("pyzmq:", zmq.__version__)
print("PyTorch:", torch.__version__)
print("TensorRT:", tensorrt.__version__, "CUDA inference passed")
PY

run_as_target bash -c \
  'source /opt/ros/humble/setup.bash && colcon build --help | grep -F -- "  --packages-select " >/dev/null'
modprobe can
modprobe can_raw
modprobe can_bcm
modprobe joydev
modprobe kcan

step "配置 Jetson MAXN 电源模式"
if [[ ! -x /usr/sbin/nvpmodel ]]; then
  echo "错误：找不到 Jetson 电源模式工具：/usr/sbin/nvpmodel" >&2
  exit 1
fi

# nvpmodel --force 是切换到 MAXN 的可靠非交互方式，但它会立即调用 reboot。
# 用临时 PATH 提供成功返回的 reboot 包装器，待全部步骤完成后再由脚本统一重启。
NVP_REBOOT_HELPER_DIR="$(mktemp -d)"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$NVP_REBOOT_HELPER_DIR/reboot"
chmod 755 "$NVP_REBOOT_HELPER_DIR/reboot"
NVP_MODEL_SET_OUTPUT=""
if NVP_MODEL_SET_OUTPUT="$(
  PATH="$NVP_REBOOT_HELPER_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    /usr/sbin/nvpmodel --force -m 0 2>&1
)"; then
  :
else
  NVP_MODEL_SET_RC=$?
  printf '%s\n' "$NVP_MODEL_SET_OUTPUT" >&2
  echo "错误：无法将 Jetson 电源模式设置为 MAXN（退出码 ${NVP_MODEL_SET_RC}）。" >&2
  exit "$NVP_MODEL_SET_RC"
fi
printf '%s\n' "$NVP_MODEL_SET_OUTPUT"
rm -f "$NVP_REBOOT_HELPER_DIR/reboot"
rmdir "$NVP_REBOOT_HELPER_DIR"
NVP_REBOOT_HELPER_DIR=""

NVP_MODE_OUTPUT="$(/usr/sbin/nvpmodel -q)"
printf '%s\n' "$NVP_MODE_OUTPUT"
if ! grep -Fqx "NV Power Mode: MAXN" <<<"$NVP_MODE_OUTPUT" ||
  ! grep -Fqx "0" <<<"$NVP_MODE_OUTPUT"; then
  echo "错误：Jetson 电源模式未设置为 MAXN（mode 0）。" >&2
  exit 1
fi

step "完成配置"
echo "全部环境配置和验证已经完成。"

if [[ "$AUTO_REBOOT" == "1" ]]; then
  echo "系统将在 5 秒后自动重启，使用户组、mttcan 黑名单、模块配置和 MAXN 电源模式全部生效。"
  sync
  sleep 5
  systemctl reboot
else
  echo "AUTO_REBOOT=${AUTO_REBOOT}，已跳过自动重启；MAXN 模式可能需要重启后才能完全生效。"
fi
