#!/usr/bin/env bash
# Show who owns the dGPU and whether vfio is ready.
#   bash ~/vm-macos-qemu/vfio-status.sh
set -uo pipefail

GPU="0000:01:00.0"
GPU_AUD="0000:01:00.1"

for d in "$GPU" "$GPU_AUD"; do
  drv=$(basename "$(readlink -f "/sys/bus/pci/devices/$d/driver" 2>/dev/null)" 2>/dev/null)
  grp=$(basename "$(readlink -f "/sys/bus/pci/devices/$d/iommu_group" 2>/dev/null)" 2>/dev/null)
  echo "$d  driver=${drv:-none}  iommu_group=${grp:-?}  power=$(cat /sys/bus/pci/devices/$d/power/runtime_status 2>/dev/null)"
done
echo
echo "vfio nodes:"; ls -l /dev/vfio/ 2>/dev/null || echo "  none"
echo
echo "nvidia modules:"; lsmod | grep -E '^nvidia' || echo "  not loaded"
echo
if [ "$(basename "$(readlink -f /sys/bus/pci/devices/$GPU/driver 2>/dev/null)" 2>/dev/null)" = "vfio-pci" ]; then
  echo "READY: pass the GPU to QEMU."
else
  echo "NOT READY: run vfio-boot-setup.sh + reboot (runtime unbind hangs here)."
fi
