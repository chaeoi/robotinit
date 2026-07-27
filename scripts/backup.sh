#!/usr/bin/env bash

set -Eeuo pipefail
umask 022

if [[ $# -gt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
用法：bash backup.sh [Linux_for_Tegra目录]

将 tools/backup_restore/images/ 完整打包到 ~/backup/。
文件名使用当前日期和两位序号，例如 goldimage_26072701.tar 和 goldimage_26072701.md5。
Linux_for_Tegra 目录默认使用 ~/Linux_for_Tegra。
EOF
  exit 0
fi

if [[ $EUID -eq 0 ]]; then
  echo "错误：不要使用 sudo 启动脚本，脚本会在需要时自行调用 sudo。" >&2
  exit 1
fi

L4T_DIR="${1:-$HOME/Linux_for_Tegra}"
IMAGES_DIR="${L4T_DIR}/tools/backup_restore/images"
BACKUP_DIR="${HOME}/backup"
ARCHIVE=""
PARTIAL=""
MD5_FILE=""
MD5_PARTIAL=""

cleanup() {
  if [[ -n "$PARTIAL" ]]; then
    sudo rm -f -- "$PARTIAL" 2>/dev/null || true
  fi
  if [[ -n "$MD5_PARTIAL" ]]; then
    rm -f -- "$MD5_PARTIAL" 2>/dev/null || true
  fi
}

trap cleanup EXIT

command -v sudo >/dev/null 2>&1 || {
  echo "错误：缺少 sudo。" >&2
  exit 1
}
command -v tar >/dev/null 2>&1 || {
  echo "错误：缺少 tar。" >&2
  exit 1
}
command -v md5sum >/dev/null 2>&1 || {
  echo "错误：缺少 md5sum。" >&2
  exit 1
}
command -v seq >/dev/null 2>&1 || {
  echo "错误：缺少 seq。" >&2
  exit 1
}

[[ -d "$IMAGES_DIR" ]] || {
  echo "错误：镜像目录不存在：${IMAGES_DIR}" >&2
  exit 1
}
[[ -f "$IMAGES_DIR/nvpartitionmap.txt" ]] || {
  echo "错误：镜像目录缺少 nvpartitionmap.txt。" >&2
  exit 1
}

mkdir -p "$BACKUP_DIR"

DAY="$(date +%y%m%d)"
for INDEX in $(seq -w 1 99); do
  NAME="goldimage_${DAY}${INDEX}"
  if [[ ! -e "$BACKUP_DIR/${NAME}.tar" && ! -e "$BACKUP_DIR/${NAME}.md5" ]]; then
    ARCHIVE="$BACKUP_DIR/${NAME}.tar"
    MD5_FILE="$BACKUP_DIR/${NAME}.md5"
    break
  fi
done

[[ -n "$ARCHIVE" ]] || {
  echo "错误：goldimage_${DAY} 当天的 01-99 编号已经全部使用。" >&2
  exit 1
}

PARTIAL="${ARCHIVE}.part"
MD5_PARTIAL="${MD5_FILE}.part"
sudo -v

echo "正在打包：${IMAGES_DIR}"
echo "保存到：${ARCHIVE}"

sudo tar \
  --sparse \
  --acls \
  --xattrs \
  --numeric-owner \
  -cf "$PARTIAL" \
  -C "${L4T_DIR}/tools/backup_restore" \
  images

sudo chown "$(id -u):$(id -g)" "$PARTIAL"
mv -- "$PARTIAL" "$ARCHIVE"
PARTIAL=""

(
  cd "$BACKUP_DIR"
  md5sum "$(basename "$ARCHIVE")" > "$(basename "$MD5_PARTIAL")"
)
mv -- "$MD5_PARTIAL" "$MD5_FILE"
MD5_PARTIAL=""
sync

echo "打包完成："
echo "  ${ARCHIVE}"
echo "  ${MD5_FILE}"
