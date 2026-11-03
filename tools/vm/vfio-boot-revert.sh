#!/usr/bin/env bash
# Undo vfio-boot-setup.sh and give the dGPU back to nvidia at next boot.
#
#   sudo bash ~/vm-macos-qemu/vfio-boot-revert.sh
#   sudo reboot
set -euo pipefail

IDS="10de:2d18,10de:22eb"
STAMP=$(date +%Y%m%d-%H%M%S)

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }

echo "--- removing modprobe.d ---"
rm -f /etc/modprobe.d/vfio-pci.conf

echo "--- cleaning initramfs modules ---"
if [ -f /etc/initramfs-tools/modules ]; then
  cp -n /etc/initramfs-tools/modules "/etc/initramfs-tools/modules.bak-vfio-$STAMP"
  sed -i '/^vfio$/d; /^vfio_iommu_type1$/d; /^vfio-pci$/d' /etc/initramfs-tools/modules
fi

echo "--- restoring kernel command line ---"
cp -n /etc/default/grub "/etc/default/grub.bak-revert-$STAMP"
sed -i "s| vfio-pci.ids=$IDS||g" /etc/default/grub
grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub

echo "--- rebuilding ---"
update-initramfs -u
update-grub

echo
echo "done. reboot to let nvidia take the card back."
