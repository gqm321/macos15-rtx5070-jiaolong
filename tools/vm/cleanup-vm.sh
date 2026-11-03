#!/usr/bin/env bash
# 退役「VM 跑 macOS」这条路：删掉 GRUB 的 VM 启动项和 VM 磁盘镜像。
# 脚本、工具、配置、文档全部保留（GRUB 项和 systemd 单元已归档到 attic/）。
#
#   sudo bash tools/cleanup-vm.sh --dry-run      # 只看会做什么
#   sudo bash tools/cleanup-vm.sh                # 真做（保留 macreal.qcow2 备份）
#   sudo bash tools/cleanup-vm.sh --with-backup  # 连 macreal.qcow2 也删（p5 的唯一来源备份）
set -euo pipefail

W=/home/guqiaomu/vm-macos-qemu
DRY=0
WITH_BACKUP=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --with-backup) WITH_BACKUP=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 1 ;;
  esac
done

run() {
  if [ "$DRY" = 1 ]; then
    echo "  [dry-run] $*"
  else
    echo "  + $*"
    "$@"
  fi
}

[ "$DRY" = 1 ] || [ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo bash $0" >&2; exit 1; }

echo "== 1/4 停用并禁止 macos-vm.service =="
run systemctl disable --now macos-vm.service || true

echo
echo "== 2/4 删除 GRUB 的 VM 启动项（已归档到 attic/grub-40_macos_vm）=="
if [ -f /etc/grub.d/40_macos_vm ]; then
  run rm -f /etc/grub.d/40_macos_vm
else
  echo "  （已不存在）"
fi

echo
echo "== 3/4 重新生成 grub.cfg =="
run update-grub

echo
echo "== 4/4 删除 VM 磁盘镜像 =="
FILES=(
  "$W/macOS15.qcow2"
  "$W/OpenCore-prep.qcow2"
  "$W/OpenCore-prep2.qcow2"
  "$W/OpenCore-mac15-mbp2.qcow2"
  "$W/mac15-gpt.qcow2"
  "$W/mac15-installer.qcow2"
  "$W/mac15-installer-gpt.qcow2"
  "$W/mac15-installer-prep.qcow2"
  "$W/esp-baremetal-audio.img"
  "$W/esp-baremetal-ec.img"
  "$W/esp-baremetal-nobar.img"
  "$W/esp-baremetal-noacpibl.img"
  "$W/esp-baremetal-wifi.img"
  "$W/esp-baremetal-working.img"
)
if [ "$WITH_BACKUP" = 1 ]; then
  FILES+=("$W/macreal.qcow2")
fi

freed=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  sz=$(du -k "$f" | cut -f1)
  printf "  %-52s %6s MiB\n" "$(basename "$f")" "$((sz/1024))"
  freed=$((freed + sz))
  run rm -f "$f"
done
echo "  释放约 $((freed/1024/1024)) GiB"

if [ "$WITH_BACKUP" != 1 ] && [ -f "$W/macreal.qcow2" ]; then
  echo
  echo "  保留 macreal.qcow2（$(du -h "$W/macreal.qcow2" | cut -f1)）：它是 p5 上那套 macOS 的唯一来源备份，"
  echo "  p5 被弄脏时可以 3 分钟重新移植。确定不需要了就再跑一次 --with-backup。"
fi

echo
echo "保留：esp-baremetal-bright.img（亮度可用）、esp-baremetal-shutdown.img（带关机菜单）"
echo "      tools/、reference-efi/、kexts/、pkg/、README 等全部不动"
echo
df -h / | tail -1
if [ "$DRY" = 0 ]; then
  echo
  echo "grub.cfg 里还有 'macOS VM' 字样吗：$(grep -c 'macOS VM' /boot/grub/grub.cfg 2>/dev/null || echo 0) 处（应为 0）"
fi
