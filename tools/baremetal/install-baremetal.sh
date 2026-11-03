#!/usr/bin/env bash
# 阶段 C：把 VM 里装好的 macOS 搬到真机分区，并装上裸机 OpenCore。
#
#   sudo bash tools/install-baremetal.sh            # 真做
#   bash tools/install-baremetal.sh --dry-run       # 只检查参数
#
# 做三件事：
#   1. 把 esp-baremetal.img 写到 p4（512 MiB ESP）
#   2. 把 macreal.qcow2 里的 APFS 容器写到 p5（229.8 GiB）
#   3. 在固件里登记一个 "OpenCore" 启动项（不设成默认）
#
# 注意：磁盘编号会变（这台机器上两块 NVMe 重启后交换过），所以全部走 by-id。
set -euo pipefail
DISK=${DISK:-/dev/disk/by-id/nvme-ZHITAI_TiPlus7100_1TB_ZTA71T0AB252817B43}
P4="$DISK-part4"; P5="$DISK-part5"
W="/home/guqiaomu/vm-macos-qemu"
SKIP=51205          # APFS 在 macreal.qcow2 里的偏移（4 KiB 块）
COUNT=60241910      # APFS 容器大小（4 KiB 块）
EXPECT_P4=$((512*1024*1024))
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

[ -b "$P4" ] && [ -b "$P5" ] || { echo "找不到 $P4 / $P5" >&2; exit 1; }
[ -f "$W/esp-baremetal.img" ] || { echo "缺 esp-baremetal.img，先跑 python3 tools/build-efi.py" >&2; exit 1; }
[ -f "$W/macreal.qcow2" ] || { echo "缺 macreal.qcow2" >&2; exit 1; }

# 非 root 时 blockdev 打不开设备节点，退回 sysfs（扇区数 × 512）
size_of() {
  blockdev --getsize64 "$1" 2>/dev/null && return
  local n; n=$(basename "$(readlink -f "$1")")
  echo $(( $(cat "/sys/class/block/$n/size" 2>/dev/null || echo 0) * 512 ))
}
s4=$(size_of "$P4"); s5=$(size_of "$P5")
echo "p4 = $((s4/1024/1024)) MiB   p5 = $((s5/1024/1024/1024)) GiB"
[ "$s4" -eq "$EXPECT_P4" ] || { echo "p4 大小不对（$s4），中止" >&2; exit 1; }
[ "$s5" -gt $((229*1024*1024*1024)) ] || { echo "p5 太小（$s5），中止" >&2; exit 1; }
[ "$(findmnt -nro TARGET -S "$P5" | head -1)" = "" ] || { echo "p5 还挂着，先卸载" >&2; exit 1; }

echo "将写入："
echo "  $W/esp-baremetal.img  -> $P4  (${s4} 字节)"
echo "  macreal.qcow2 的 APFS -> $P5  (skip=$SKIP count=$COUNT, 约 246.8 GB)"
[ "$DRY" = 1 ] && { echo "（--dry-run：什么都没做）"; exit 0; }
[ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo bash $0" >&2; exit 1; }

echo
echo "=== 1/3 写 ESP ==="
dd if="$W/esp-baremetal.img" of="$P4" bs=4M conv=fsync status=progress

echo
echo "=== 2/3 移植 APFS（这一步要几分钟）==="
qemu-img dd -f qcow2 -O raw if="$W/macreal.qcow2" of="$P5" bs=4096 skip=$SKIP count=$COUNT

echo
echo "=== 校验 APFS 魔数（应为 NXSB）==="
dd if="$P5" bs=1 skip=32 count=4 status=none | xxd | head -1

echo
echo "=== 3/3 登记 OpenCore 启动项 ==="
efibootmgr -c -d "$(readlink -f "$DISK")" -p 4 -L "OpenCore" -l '\EFI\BOOT\BOOTx64.EFI' || \
  echo "  （efibootmgr 失败，可以进 BIOS 手动选或用固件兜底路径）"
efibootmgr | head -6

echo
echo "完成。重启后进 BIOS/启动菜单选 OpenCore，或者在 GRUB 里手动 chainload。"
echo "OpenCore 菜单里应当出现 'mac HD' —— 选它。"
