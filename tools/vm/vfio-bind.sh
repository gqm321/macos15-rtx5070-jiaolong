#!/usr/bin/env bash
# P0 step 2: give the dGPU (and its HDMI audio function) to vfio-pci.
# Run as root:  sudo bash ~/vm-macos-qemu/vfio-bind.sh
set -uo pipefail

DEVS=(0000:01:00.0 0000:01:00.1)   # VGA + HDMI audio, IOMMU group 14

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }

group=$(basename "$(readlink -f /sys/bus/pci/devices/0000:01:00.0/iommu_group)")
echo "IOMMU group: $group"

modprobe vfio-pci || { echo "cannot load vfio-pci" >&2; exit 1; }

# Keep the card powered: a laptop dGPU in D3cold cannot be woken by the guest.
for d in "${DEVS[@]}"; do
  echo on > "/sys/bus/pci/devices/$d/power/control" 2>/dev/null || true
done

# Unbind native drivers, audio first.  NOTE: on this laptop the live nvidia
# unbind hangs half-way (device detached, remove() never returns).  Use
# vfio-boot-setup.sh instead; --force is only for when you know it is safe.
for d in 0000:01:00.1 0000:01:00.0; do
  drv=$(basename "$(readlink -f "/sys/bus/pci/devices/$d/driver" 2>/dev/null)" 2>/dev/null)
  if [ -n "${drv:-}" ] && [ "$drv" != "vfio-pci" ]; then
    if [ "${1:-}" != "--force" ]; then
      echo "REFUSING: $d is bound to $drv."
      echo "  runtime unbind hangs on this machine; use:"
      echo "    sudo bash $PWD/vfio-boot-setup.sh && sudo reboot"
      echo "  or re-run with --force and a 20s timeout."
      exit 2
    fi
    echo "unbind $d from $drv"
    timeout 20 sh -c "echo '$d' > '/sys/bus/pci/drivers/$drv/unbind'" \
      || { echo "  timed out / failed - reboot to recover"; exit 1; }
  fi
done

for d in "${DEVS[@]}"; do
  cur=$(basename "$(readlink -f "/sys/bus/pci/devices/$d/driver" 2>/dev/null)" 2>/dev/null)
  if [ "$cur" != "vfio-pci" ]; then
    echo vfio-pci > "/sys/bus/pci/devices/$d/driver_override"
    echo "$d" > /sys/bus/pci/drivers/vfio-pci/bind || { echo "bind $d failed"; exit 1; }
  fi
  echo "$d -> $(basename "$(readlink -f "/sys/bus/pci/devices/$d/driver")")"
done

echo
echo "group devices:"
for d in /sys/kernel/iommu_groups/"$group"/devices/*; do
  echo "  $(basename "$d")  $(basename "$(readlink -f "$d/driver")" 2>/dev/null)"
done
ls -l /dev/vfio/ 2>/dev/null
echo
echo "OK. Undo with: sudo bash $PWD/vfio-unbind.sh"
