#!/usr/bin/env bash
# 阶段 B：把 nvme0n1 从 MBR 转成 GPT，并在 256 GB 空隙里建 macOS 用的两个分区。
#
#   sudo bash tools/gpt-convert.sh            # 真做
#   bash tools/gpt-convert.sh --dry-run       # 只打印计划（不需要 root）
#
# 做的事：
#   1. 备份 MBR（前 34 扇区 + 整表 dump）
#   2. sgdisk -g 转 GPT（分区起止扇区不变，数据不动）
#   3. 在空隙里建 p4 = 512 MiB ESP、p5 = 其余（APFS 类型）
#   4. 重建 GRUB 启动项 + 在 ESP 里放 \EFI\BOOT\BOOTX64.EFI 兜底
#
# 撤销：把备份的 MBR 写回前 34 扇区（见脚本最后打印的命令），再重启。
set -uo pipefail
DISK=/dev/nvme0n1
ESP_MIB=512
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
W="/home/guqiaomu/vm-macos-qemu"

sect() {  # sect <part> <start|size>
  cat "/sys/class/block/$(basename "$1")/$2" 2>/dev/null
}

P1=$DISK"p1"; P2=$DISK"p2"; P3=$DISK"p3"
for p in "$P1" "$P2" "$P3"; do [ -b "$p" ] || { echo "找不到 $p" >&2; exit 1; }; done

p1s=$(sect "$P1" start); p1n=$(sect "$P1" size)
p2s=$(sect "$P2" start); p2n=$(sect "$P2" size)
p3s=$(sect "$P3" start); p3n=$(sect "$P3" size)

echo "当前布局（扇区）："
echo "  p1 start=$p1s size=$p1n  ($((p1n*512/1024/1024/1024)) GiB)"
echo "  p2 start=$p2s size=$p2n"
echo "  p3 start=$p3s size=$p3n"
echo "  空隙: $((p1s+p1n)) .. $((p2s-1))  共 $(python3 -c "print(f'{($p2s-($p1s+$p1n))*512/2**30:.1f} GiB')")"

# 安全检查：只在预期布局上动手（p1 是 NTFS 游戏盘、p2 是 ESP、p3 是根）
[ "$p1n" -gt 900000000 ] || { echo "p1 大小不对（$p1n），中止" >&2; exit 1; }
[ "$p2n" -lt 3000000 ]  || { echo "p2 不像 ESP（$p2n），中止" >&2; exit 1; }
[ $((p3s+p3n)) -ge $((p2s+p2n)) ] || { echo "p3 位置不对，中止" >&2; exit 1; }

gap_start=$((p1s+p1n))
gap_end=$((p2s-1))
s4=$gap_start
e4=$((gap_start+ESP_MIB*2048-1))
s5=$((e4+1))
e5=$gap_end

echo
echo "计划："
echo "  p4  ESP   $s4..$e4  ($ESP_MIB MiB, type EF00)"
echo "  p5  APFS  $s5..$e5  ($(python3 -c "print(f'{($e5-$s5+1)*512/2**30:.1f} GiB')"), type 7C3457EF-...)"

if [ "$DRY" = 1 ]; then echo; echo "（--dry-run：什么都没做）"; exit 0; fi
[ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo bash $0" >&2; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$W/dump"
BACK="$W/dump/mbr-$TS.bin"
echo
echo "=== 1. 备份 MBR 到 $BACK ==="
dd if="$DISK" of="$BACK" bs=512 count=34 status=none || { echo "备份失败，中止" >&2; exit 1; }
sfdisk -d "$DISK" > "$W/dump/mbr-$TS.sfdisk" 2>/dev/null || true
ls -l "$BACK" | awk '{print "  " $5, $9}'

echo "=== 2. MBR -> GPT ==="
sgdisk -g "$DISK" || { echo "sgdisk -g 失败" >&2; exit 1; }
sgdisk -p "$DISK" | tail -5

echo "=== 3. 建 p4 / p5 ==="
sgdisk -n "4:$s4:$e4" -t 4:ef00 -c 4:"MACESP" "$DISK" || exit 1
sgdisk -n "5:$s5:$e5" -t 5:7C3457EF-0000-11AA-AA11-00306543ECAC -c 5:"Macintosh HD" "$DISK" || exit 1
partprobe "$DISK" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sgdisk -p "$DISK" | tail -6

echo "=== 4. 重建 GRUB 启动项 ==="
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck || {
  echo "grub-install 失败 —— 但 ESP 里的文件还在，可以先把 \\EFI\\BOOT\\BOOTX64.EFI 放好再重启" >&2; }
update-grub >/dev/null 2>&1 || true

echo "=== 5. 兜底引导 \EFI\BOOT\BOOTX64.EFI ==="
mkdir -p /boot/efi/EFI/BOOT
for f in shimx64.efi grubx64.efi; do
  [ -f "/boot/efi/EFI/ubuntu/$f" ] && cp -f "/boot/efi/EFI/ubuntu/$f" "/boot/efi/EFI/BOOT/$f" && echo "  复制 $f"
done
[ -f /boot/efi/EFI/ubuntu/grubx64.efi ] && cp -f /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI && echo "  BOOTX64.EFI = grubx64.efi"

echo
echo "=== 完成。分区表现在是 ==="
sgdisk -p "$DISK" | tail -7
echo
echo "下一步：重启，确认 Ubuntu 和 Windows 都还能进。"
echo "如果不进：用备份写回前 34 扇区再重启 ——"
echo "  sudo dd if=$BACK of=$DISK bs=512 count=34 conv=notrunc"
