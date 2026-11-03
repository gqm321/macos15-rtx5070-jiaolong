#!/usr/bin/env bash
# Let the desktop user (not root) drive QEMU with the vfio group.
#   sudo bash ~/vm-macos-qemu/vfio-perms.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }
USER_NAME="${SUDO_USER:-guqiaomu}"

chown "$USER_NAME" /dev/vfio/14

cat > /etc/udev/rules.d/99-vfio-macos.rules <<EOF
# keep /dev/vfio/14 usable by $USER_NAME after every boot
SUBSYSTEM=="vfio", KERNEL=="14", OWNER="$USER_NAME", MODE="0660"
EOF

udevadm control --reload-rules
udevadm trigger --subsystem-match=vfio
sleep 0.5
ls -l /dev/vfio/14
echo "OK: $USER_NAME can now run QEMU with this group."
