#!/usr/bin/env bash

set -Eeuo pipefail
umask 022
trap '' HUP

TARGET_HOSTNAME=""
NO_REBOOT=0
CHECK_ONLY=0

usage() {
  cat <<'EOF'
用法：sudo ./finalize.sh <hostname> [选项]
      sudo ./finalize.sh --hostname <hostname> [选项]

目标机首次开机后执行一次，设置本机 hostname，重建 machine-id 和 SSH host key，
清理克隆残留状态，最后默认自动重启。

选项：
  --hostname <name>  目标机 hostname
  --check            只检查环境和参数，不修改系统
  --no-reboot        完成后不自动重启，仅用于调试
  -h, --help         显示帮助
EOF
}

validate_hostname() {
  local name="$1"
  [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

while (($# > 0)); do
  case "$1" in
    --hostname)
      if [[ $# -lt 2 ]]; then
        echo "错误：--hostname 缺少参数。" >&2
        exit 2
      fi
      TARGET_HOSTNAME="$2"
      shift 2
      ;;
    --no-reboot)
      NO_REBOOT=1
      shift
      ;;
    --check)
      CHECK_ONLY=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "错误：未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$TARGET_HOSTNAME" ]]; then
        echo "错误：只能指定一个 hostname。" >&2
        exit 2
      fi
      TARGET_HOSTNAME="$1"
      shift
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "错误：请使用 sudo 执行本脚本。" >&2
  exit 1
fi

if [[ ! -r /etc/nv_tegra_release ]]; then
  echo "错误：当前系统不是可识别的 Jetson Linux，拒绝执行。" >&2
  exit 1
fi

if [[ -z "$TARGET_HOSTNAME" ]] || ! validate_hostname "$TARGET_HOSTNAME"; then
  echo "错误：hostname 必须为 1-63 位小写字母、数字或连字符，且不能以连字符开头/结尾。" >&2
  exit 2
fi

if ((CHECK_ONLY)); then
  echo "检查通过：当前是 Jetson Linux，目标 hostname 为 $TARGET_HOSTNAME。"
  echo "当前 hostname：$(hostnamectl --static 2>/dev/null || hostname)"
  echo "当前 machine-id：$(cat /etc/machine-id 2>/dev/null || true)"
  exit 0
fi

step() {
  printf '\n==> %s\n' "$1"
}

on_error() {
  local exit_code=$?
  echo >&2
  echo "初始化失败，退出码 ${exit_code}。请修复后重新运行 finalize.sh。" >&2
  exit "$exit_code"
}

trap on_error ERR

step "设置 hostname"
hostnamectl set-hostname "$TARGET_HOSTNAME"
printf '%s\n' "$TARGET_HOSTNAME" > /etc/hostname
chmod 0644 /etc/hostname
chown root:root /etc/hostname

if [[ -f /etc/hosts ]]; then
  sed -i -E '/^[[:space:]]*127\.0\.1\.1([[:space:]]|$)/d' /etc/hosts
else
  touch /etc/hosts
fi
printf '127.0.1.1\t%s\n' "$TARGET_HOSTNAME" >> /etc/hosts
chmod 0644 /etc/hosts
chown root:root /etc/hosts

step "重建 machine-id"
rm -f /etc/machine-id /var/lib/dbus/machine-id
new_machine_id="$(tr -d '-' </proc/sys/kernel/random/uuid)"
if [[ ! "$new_machine_id" =~ ^[0-9a-f]{32}$ ]]; then
  echo "错误：随机 machine-id 生成失败。" >&2
  exit 1
fi
printf '%s\n' "$new_machine_id" > /etc/machine-id
chmod 0444 /etc/machine-id
chown root:root /etc/machine-id
mkdir -p /var/lib/dbus
ln -sfn /etc/machine-id /var/lib/dbus/machine-id

step "重建 SSH host key"
rm -f /etc/ssh/ssh_host_*
ssh-keygen -q -t rsa -b 3072 -N "" -C "$TARGET_HOSTNAME" \
  -f /etc/ssh/ssh_host_rsa_key
ssh-keygen -q -t ecdsa -b 256 -N "" -C "$TARGET_HOSTNAME" \
  -f /etc/ssh/ssh_host_ecdsa_key
ssh-keygen -q -t ed25519 -N "" -C "$TARGET_HOSTNAME" \
  -f /etc/ssh/ssh_host_ed25519_key

echo "新的 SSH host key 指纹："
for public_key in /etc/ssh/ssh_host_*_key.pub; do
  ssh-keygen -lf "$public_key"
done

systemctl reload ssh.service 2>/dev/null ||
  systemctl reload sshd.service 2>/dev/null ||
  true

step "清理克隆残留状态"
systemctl stop systemd-timesyncd.service 2>/dev/null || true
systemctl stop chrony.service 2>/dev/null || true
systemctl stop bluetooth.service 2>/dev/null || true
systemctl stop '*.timer' 2>/dev/null || true

rm -f \
  /var/lib/systemd/random-seed \
  /var/lib/systemd/credential.secret \
  /var/lib/urandom/random-seed \
  /var/lib/libuuid/clock.txt \
  /opt/nvidia/l4t-usb-device-mode/mac-addresses

for state_dir in \
  /var/lib/NetworkManager \
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
    find "$state_dir" -xdev -mindepth 1 -delete 2>/dev/null || true
  fi
done

if [[ -d /var/lib/dhcp ]]; then
  find /var/lib/dhcp -xdev -type f -name '*.lease*' -delete 2>/dev/null || true
fi

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

mkdir -p /var/lib/robotinit
{
  printf 'hostname=%s\n' "$TARGET_HOSTNAME"
  printf 'machine-id=%s\n' "$(cat /etc/machine-id)"
  date -u '+initialized-at=%Y-%m-%dT%H:%M:%SZ'
} > /var/lib/robotinit/initialized
chmod 0644 /var/lib/robotinit/initialized

sync

if ((NO_REBOOT)); then
  echo "初始化完成。已跳过自动重启；NetworkManager 状态可能重新生成，请尽快手动 reboot。"
  exit 0
fi

echo "初始化完成，系统将在 5 秒后重启。后续 SSH 连接需要更新 known_hosts。"
sleep 5

systemctl stop NetworkManager.service >/dev/null 2>&1 || true
if [[ -d /var/lib/NetworkManager ]]; then
  find /var/lib/NetworkManager -xdev -mindepth 1 -delete 2>/dev/null || true
fi

script_path="$(readlink -f "$0" 2>/dev/null || true)"
if [[ "$script_path" == /tmp/* ]]; then
  rm -f -- "$script_path"
fi

sync
systemctl reboot
