#!/usr/bin/env bash
# 在 macOS 里把新的 ESP 镜像写到 OpenCore 那个 ESP（p4）。
# 这样换配置不用回 Ubuntu，也不用重装。
#
#   sudo bash mac-flash.sh esp-baremetal-wifi.img
#   sudo bash mac-flash.sh esp-baremetal-wifi.img /dev/disk0s4
#
# 自动检测：挂载每个 EFI 分区，挑「里面有 EFI/OC/config.plist」的那个，
# 所以不会误写到 Ubuntu 的 1 GiB ESP。
set -uo pipefail

IMG="${1:-}"
DEV_ARG="${2:-}"
if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
  echo "用法: sudo bash $0 <ESP镜像> [diskXsY]"
  exit 1
fi
[ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo bash $0 ..."; exit 1; }
SIZE=$(stat -f%z "$IMG")
echo "镜像: $IMG ($((SIZE/1024/1024)) MiB)"

find_oc_esp() {
  local part mnt
  for part in $(diskutil list | awk '/EFI/ {print $NF}' | grep -E '^disk[0-9]+s[0-9]+$'); do
    mnt=$(mktemp -d /tmp/espcheck.XXXXXX)
    if diskutil mount -mountPoint "$mnt" "/dev/$part" >/dev/null 2>&1; then
      if [ -f "$mnt/EFI/OC/config.plist" ]; then
        diskutil unmount "$mnt" >/dev/null 2>&1
        rmdir "$mnt" 2>/dev/null
        echo "$part"
        return 0
      fi
      diskutil unmount "$mnt" >/dev/null 2>&1
    fi
    rmdir "$mnt" 2>/dev/null
  done
  return 1
}

if [ -n "$DEV_ARG" ]; then
  PART="${DEV_ARG#/dev/}"; PART="${PART#r}"
else
  echo "查找 OpenCore 的 ESP ..."
  PART=$(find_oc_esp)
  if [ -z "${PART:-}" ]; then
    echo "没找到含 EFI/OC/config.plist 的 ESP。当前分区："
    diskutil list
    echo "请手动指定，例如：sudo bash $0 $IMG /dev/disk0s4"
    exit 1
  fi
fi
echo "目标: /dev/$PART"

diskutil unmount "/dev/$PART" >/dev/null 2>&1
echo "写入中 ..."
dd if="$IMG" of="/dev/r$PART" bs=2m || { echo "dd 失败"; exit 1; }
sync

A=$(dd if="$IMG" bs=4096 count=1 2>/dev/null | md5)
B=$(dd if="/dev/r$PART" bs=4096 count=1 2>/dev/null | md5)
if [ "$A" = "$B" ]; then
  echo "✅ 写入完成（首块校验一致）。重启后进 OpenCore，选 mac HD。"
else
  echo "⚠️ 首块校验不一致：$A vs $B，请再写一次。"
  exit 1
fi
