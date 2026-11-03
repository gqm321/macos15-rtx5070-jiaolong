#!/usr/bin/env bash
# 校验 p5 上的 APFS 容器和 macreal.qcow2 里的源是否一致（抽样关键块）。
#
#   sudo bash tools/verify-transplant.sh
set -uo pipefail
W="/home/guqiaomu/vm-macos-qemu"
P5=${P5:-${DISK:-/dev/disk/by-id/nvme-ZHITAI_TiPlus7100_1TB_ZTA71T0AB252817B43}-part5}
SKIP=51205
COUNT=60241910
[ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo bash $0" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
blk() {  # blk <source|target> <index>
  local n=$2 f="$TMP/b"
  if [ "$1" = source ]; then
    qemu-img dd -f qcow2 -O raw if="$W/macreal.qcow2" of="$f" bs=4096 skip=$((SKIP+n)) count=1 >/dev/null 2>&1
  else
    dd if="$P5" of="$f" bs=4096 skip=$n count=1 status=none
  fi
  md5sum "$f" | cut -d' ' -f1
}

echo "取样比较（APFS 块号，块大小 4096）："
for n in 0 1 100 1000000 30000000 60000000 $((COUNT-2)) $((COUNT-1)); do
  a=$(blk source $n); b=$(blk target $n)
  if [ "$a" = "$b" ]; then s="一致"; else s="❌ 不一致"; fi
  printf "  块 %-10s 源=%s 目标=%s  %s\n" "$n" "${a:0:8}" "${b:0:8}" "$s"
done

echo
echo "APFS 容器超块头部（目标）："
dd if="$P5" bs=4096 count=1 status=none | xxd -l 96
echo
echo "APFS 容器超块头部（源）："
qemu-img dd -f qcow2 -O raw if="$W/macreal.qcow2" of="$TMP/srcblk" bs=4096 skip=$SKIP count=1 >/dev/null 2>&1
xxd -l 96 "$TMP/srcblk"
