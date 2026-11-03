#!/usr/bin/env bash
# Bind the dGPU to vfio-pci at boot, so the nvidia driver never owns it.
#
# Why: on this laptop, unbinding the live nvidia driver hangs (the device is
# detached but the remove path never returns).  Binding at boot side-steps the
# whole runtime unbind path.
#
#   sudo bash ~/vm-macos-qemu/vfio-boot-setup.sh
#   sudo reboot
#
# Revert with vfio-boot-revert.sh, or temporarily hand the card back at runtime
# with:  echo 0000:01:00.0 > /sys/bus/pci/drivers/vfio-pci/unbind
#        printf '' > /sys/bus/pci/devices/0000:01:00.0/driver_override
#        echo 0000:01:00.0 > /sys/bus/pci/drivers_probe
set -euo pipefail

IDS="10de:2d18,10de:22eb"
STAMP=$(date +%Y%m%d-%H%M%S)

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }

echo "--- 1. modprobe.d ---"
cat > /etc/modprobe.d/vfio-pci.conf <<EOF
# vfio-pci claims the RTX 5070 Laptop GPU (VGA + HDMI audio) at load time
options vfio-pci ids=$IDS
softdep nvidia pre: vfio-pci
EOF
cat /etc/modprobe.d/vfio-pci.conf

echo "--- 2. initramfs modules ---"
for m in vfio vfio_iommu_type1 vfio-pci; do
  grep -qx "$m" /etc/initramfs-tools/modules 2>/dev/null || echo "$m" >> /etc/initramfs-tools/modules
done

echo "--- 3. kernel command line ---"
cp -n /etc/default/grub "/etc/default/grub.bak-vfio-$STAMP"
if grep -q "vfio-pci.ids=$IDS" /etc/default/grub; then
  echo "already present"
else
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 vfio-pci.ids=$IDS\"|" /etc/default/grub
fi
grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub

echo "--- 4. rebuilding initramfs + grub ---"
update-initramfs -u
update-grub

echo
echo "done. reboot, then check:"
echo "  ls -l /sys/bus/pci/devices/0000:01:00.0/driver   # -> vfio-pci"
echo "  ls -l /dev/vfio/                                  # -> 14"
echo "revert: sudo bash $PWD/vfio-boot-revert.sh && sudo reboot"
