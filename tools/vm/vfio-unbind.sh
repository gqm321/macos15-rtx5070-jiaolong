#!/usr/bin/env bash
# Give the dGPU back to the host drivers.
# Run as root:  sudo bash ~/vm-macos-qemu/vfio-unbind.sh
set -uo pipefail

DEVS=(0000:01:00.1 0000:01:00.0)   # detach audio first, then the GPU

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }

for d in "${DEVS[@]}"; do
  if [ -e "/sys/bus/pci/devices/$d/driver_override" ]; then
    printf '' > "/sys/bus/pci/devices/$d/driver_override"
  fi
  cur=$(basename "$(readlink -f "/sys/bus/pci/devices/$d/driver" 2>/dev/null)" 2>/dev/null)
  if [ "$cur" = "vfio-pci" ]; then
    echo "$d" > /sys/bus/pci/drivers/vfio-pci/unbind || echo "unbind $d failed"
  fi
done

# Let the normal probe path pick them up again.
echo 0000:01:00.1 > /sys/bus/pci/drivers_probe 2>/dev/null || true
echo 0000:01:00.0 > /sys/bus/pci/drivers_probe 2>/dev/null || true
sleep 1

for d in 0000:01:00.0 0000:01:00.1; do
  echo "$d -> $(basename "$(readlink -f "/sys/bus/pci/devices/$d/driver" 2>/dev/null)" 2>/dev/null || echo none)"
done
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "(nvidia-smi still down, a reboot is the sure fix)"
