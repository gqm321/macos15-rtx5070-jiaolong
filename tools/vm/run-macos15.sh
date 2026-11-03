#!/usr/bin/env bash
# macOS 15 (Sequoia) VM: OpenCore + target disk + installer media.
#
#   bash run-macos15.sh --daemon --no-gpu          # installer, no GPU
#   bash run-macos15.sh --daemon                   # needs vfio + root memlock
#
# The installer ISO is an APM image, which UEFI cannot parse; mac15-installer.qcow2
# is a qcow2 overlay over it with a GPT written on top (tools/gpt-wrap.py), so the
# HFS volume shows up as a normal SATA partition.
set -uo pipefail
W="$(cd "$(dirname "$0")" && pwd)"

export INSTALLER="${INSTALLER:-$W/mac15-installer.qcow2}"
export INSTALLER_AS_HD=1
export INSTALLER_FMT=qcow2
export OC_IMG="${OC_IMG:-$W/OpenCore-mac15-mbp2.qcow2}"
export MAC_IMG="${MAC_IMG:-$W/macOS15.qcow2}"

exec bash "$W/run-macos.sh" "$@"
