#!/usr/bin/env bash

set -Eeuo pipefail
umask 022
trap '' HUP

ASSUME_YES=0
PURGE_APT_LISTS=0
CHECK_ONLY=0

usage() {
  cat <<'EOF'
用法：sudo ./sanitize.sh [选项]

净化 Jetson 黄金母机，清理可克隆的每机状态并自动关机。
hostname、SSH host key 和 NetworkManager 连接配置会保留，以保证目标机首次开机后可 SSH 登录；
目标机开机后运行 finalize.sh 完成最终身份初始化。

选项：
  --check            只执行环境和网络绑定检查，不做任何清理
  --yes              跳过 CLEAN 确认，供自动化流程使用
  --purge-apt-lists  同时删除 /var/lib/apt/lists/*
  -h, --help         显示帮助
EOF
}

while (($# > 0)); do
  case "$1" in
    --yes)
      ASSUME_YES=1
      ;;
    --check)
      CHECK_ONLY=1
      ;;
    --purge-apt-lists)
      PURGE_APT_LISTS=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "错误：未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ $EUID -ne 0 ]]; then
  echo "错误：请使用 sudo 执行本脚本。" >&2
  exit 1
fi

if [[ ! -r /etc/nv_tegra_release ]]; then
  echo "错误：当前系统不是可识别的 Jetson Linux，拒绝执行。" >&2
  exit 1
fi

check_network_bindings() {
  local found=0

  if grep -RniE \
    '^[[:space:]]*(macaddress|set-name|gateway4|gateway6):|^[[:space:]]*addresses:[[:space:]]*\[[^]]*/[0-9]+|^[[:space:]]*-[[:space:]]*[0-9A-Fa-f:.]+/[0-9]+' \
    /etc/netplan 2>/dev/null; then
    found=1
  fi

  if grep -RniE \
    '^(mac-address|cloned-mac-address|address[0-9]+|method=manual)=' \
    /etc/NetworkManager/system-connections 2>/dev/null; then
    found=1
  fi

  if grep -RniE \
    --include='*net*.rules' \
    --include='70-persistent-net.rules' \
    'ATTR\{address\}|MACAddress=|NAME=' \
    /etc/udev/rules.d 2>/dev/null; then
    found=1
  fi

  if ((found)); then
    echo >&2
    echo "错误：发现固定 MAC、接口名或静态 IP 配置。" >&2
    echo "请先确认并删除每台设备不应共享的网络绑定，再重新执行。" >&2
    exit 1
  fi
}

confirm_cleanup() {
  local answer

  ((ASSUME_YES)) && return

  if [[ ! -r /dev/tty ]]; then
    echo "错误：无法交互确认；自动化执行请添加 --yes。" >&2
    exit 1
  fi

  cat >/dev/tty <<'EOF'

警告：该操作会清除母机唯一状态、日志、缓存和历史，并自动关机。
hostname、NetworkManager 连接配置、authorized_keys 和用户 SSH 私钥会保留。
SSH host key 会临时保留，目标机首次开机后必须运行 finalize.sh 重建。
输入 CLEAN 继续：
EOF
  read -r answer </dev/tty
  if [[ "$answer" != "CLEAN" ]]; then
    echo "已取消。"
    exit 0
  fi
}

step() {
  printf '\n==> %s\n' "$1"
}

on_error() {
  local exit_code=$?
  echo >&2
  echo "净化失败，退出码 ${exit_code}。修复问题后必须重新运行并关机，不能直接读取镜像。" >&2
  exit "$exit_code"
}

trap on_error ERR

check_network_bindings

if ((CHECK_ONLY)); then
  echo "检查通过：当前是 Jetson Linux，未发现固定 MAC、接口名或静态 IP 绑定。"
  exit 0
fi

confirm_cleanup

step "重置 cloud-init 状态"
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init clean --logs 2>/dev/null || true
fi

step "停止会写回状态的服务"
systemctl stop systemd-random-seed.service 2>/dev/null || true
systemctl stop systemd-timesyncd.service 2>/dev/null || true
systemctl stop chrony.service 2>/dev/null || true
systemctl stop bluetooth.service 2>/dev/null || true
systemctl stop '*.timer' 2>/dev/null || true
systemctl stop docker.service docker.socket containerd.service \
  2>/dev/null || true

step "清理机器身份"
truncate -s 0 /etc/machine-id
mkdir -p /var/lib/dbus
ln -sfn /etc/machine-id /var/lib/dbus/machine-id

rm -f \
  /var/lib/systemd/random-seed \
  /var/lib/systemd/credential.secret \
  /var/lib/urandom/random-seed \
  /var/lib/libuuid/clock.txt

step "清理硬件和系统运行状态"
rm -f /opt/nvidia/l4t-usb-device-mode/mac-addresses

for state_dir in \
  /var/lib/bluetooth \
  /var/lib/systemd/rfkill \
  /var/lib/systemd/backlight \
  /var/lib/systemd/timesync \
  /var/lib/systemd/timers \
  /var/lib/chrony \
  /var/lib/ntp \
  /var/lib/systemd/coredump \
  /var/crash; do
  if [[ -d "$state_dir" ]]; then
    find "$state_dir" -xdev -mindepth 1 -delete
  fi
done

step "清理日志"
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true
systemctl stop rsyslog.service 2>/dev/null || true

find /var/log -xdev -type f \
  ! -path '/var/log/journal/*' \
  -exec truncate -s 0 {} +

if [[ -d /var/log/journal ]]; then
  find /var/log/journal -xdev -mindepth 1 -delete 2>/dev/null || true
fi

if [[ -d /var/spool/rsyslog ]]; then
  find /var/spool/rsyslog -xdev -mindepth 1 -delete
fi

rm -f \
  /var/lib/rsyslog/imjournal.state \
  /var/lib/logrotate/status

if [[ -d /var/lib/docker/containers ]]; then
  find /var/lib/docker/containers -xdev -type f \
    -name '*-json.log' -exec truncate -s 0 {} +
fi

step "清理 APT 和用户缓存"
apt-get clean
if ((PURGE_APT_LISTS)); then
  rm -rf /var/lib/apt/lists/*
fi

while IFS= read -r -d '' cache_dir; do
  find "$cache_dir" -xdev -mindepth 1 -delete 2>/dev/null || true
done < <(
  find /root /home -xdev -type d \
    \( \
      -name '.cache' -o \
      -name 'ComputeCache' -o \
      -name '.nv' -o \
      -name '.bash_sessions' \
    \) \
    -print0 2>/dev/null
)

rm -rf \
  /var/cache/motd-news/* \
  /var/lib/update-notifier/updates-available \
  /var/lib/update-notifier/release-upgrade-available

step "清理历史和临时文件"
find /root /home -xdev -type f \
  \( \
    -name '.bash_history' -o \
    -name '.lesshst' -o \
    -name '.python_history' -o \
    -name '.viminfo' -o \
    -name '.wget-hsts' -o \
    -name '.Xauthority' -o \
    -name '.ICEauthority' -o \
    -name '.sudo_as_admin_successful' -o \
    -name '.motd_shown' \
  \) \
  -delete 2>/dev/null || true

find /root /home -xdev -type f \
  \( -name 'known_hosts' -o -name 'known_hosts.old' \) \
  -delete 2>/dev/null || true

if [[ -d /var/lib/dhcp ]]; then
  find /var/lib/dhcp -xdev -type f -name '*.lease*' -delete
fi

find /tmp /var/tmp -xdev -mindepth 1 -delete 2>/dev/null || true

step "最终清理 NetworkManager 和日志状态"
echo "网络连接可能即将断开，脚本会继续完成清理并自动关机。"
sleep 3
systemctl stop NetworkManager.service >/dev/null 2>&1 || true

if [[ -d /var/lib/NetworkManager ]]; then
  find /var/lib/NetworkManager -xdev -mindepth 1 -delete
fi

systemctl mask --runtime \
  systemd-journald.service \
  systemd-journald.socket \
  systemd-journald-dev-log.socket \
  systemd-journald-audit.socket \
  systemd-journald-varlink@.socket \
  >/dev/null 2>&1 || true
systemctl stop \
  systemd-journald.socket \
  systemd-journald-dev-log.socket \
  systemd-journald-audit.socket \
  systemd-journald.service \
  >/dev/null 2>&1 || true

if [[ -d /var/log/journal ]]; then
  find /var/log/journal -xdev -mindepth 1 -delete 2>/dev/null || true
fi

find /var/log -xdev -type f \
  ! -path '/var/log/journal/*' \
  -exec truncate -s 0 {} +

sync
systemctl poweroff
