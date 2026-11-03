#!/usr/bin/env bash
# 阶段 A：起一个「准备用 VM」——不直通显卡，用 std VGA + VNC(:1) 操作。
# 用途：在 macreal.qcow2 上装 macOS 15.8.1，装好 1401、预置网络配置，
#       之后把这块 APFS 搬到真机分区。
#
# 它和日常的 macOS VM 并行运行，互不影响：
#   日常 VM    : dump/mac-*.sock / mac-serial.log / VNC 5900
#   准备用 VM  : dump/prep-*    / prep-serial.log / VNC 5901
#
#   bash prep-realmac.sh          # 起（后台）
#   bash prep-realmac.sh --stop   # 优雅关机（ACPI，不会硬杀）
set -uo pipefail
W="$(cd "$(dirname "$0")" && pwd)"
DUMP="$W/dump"
ISO="${ISO:-/mnt/games/macOS Sequoia 15.8.1 (24H32).iso}"
IMG="${IMG:-$W/macreal.qcow2}"
# ide-hd 不接受只读块节点，而 ISO 在只读挂载的 NTFS 上。
# 用一个 qcow2 覆盖层当安装盘：写入落在覆盖层，ISO 本身不动。
INS_IMG="${INS_IMG:-$W/mac15-installer-prep.qcow2}"
# 必须用独立副本：日常 VM 用着的 OpenCore 镜像加了写锁，第二个 QEMU 打不开
OC_IMG="${OC_IMG:-$W/OpenCore-prep2.qcow2}"
MEM="${MEM:-6144}"
# 必须和 OpenCore 里的 cores-per-package 补丁（0x08 = 8 核）一致，否则内核 panic
SMP="${SMP:-8}"
SIZE="${SIZE:-230G}"
SMC_OSK="${SMC_OSK:-ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc}"
PID="$DUMP/prep.pid"

running() { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; }

if [ "${1:-}" = "--stop" ]; then
  running || { echo "准备用 VM 没在跑"; exit 0; }
  echo "发 ACPI 关机（优雅）…"
  python3 "$W/tools/hmp.py" "$DUMP/prep-monitor.sock" system_powerdown 2>/dev/null \
    || echo "（发送失败，看 dump/prep-qemu.log）"
  for _ in $(seq 1 60); do running || { echo "已退出"; exit 0; }; sleep 2; done
  echo "还在跑，等它自己关（不强杀）"
  exit 0
fi

[ -r "$ISO" ] || { echo "安装 ISO 读不到：$ISO" >&2; echo "先：sudo mount -o ro /dev/nvme0n1p1 /mnt/games" >&2; exit 1; }
running && { echo "准备用 VM 已经在跑（pid $(cat "$PID")）"; exit 0; }
[ -s "$DUMP/pci-mmio64.bin" ] || { echo "缺 $DUMP/pci-mmio64.bin（先起一次日常 VM 让它生成）" >&2; exit 1; }

if [ ! -f "$IMG" ]; then
  echo "新建目标盘 $IMG ($SIZE)…"
  qemu-img create -f qcow2 "$IMG" "$SIZE" >/dev/null
fi
if [ ! -f "$INS_IMG" ]; then
  echo "建安装盘覆盖层 $INS_IMG → $ISO"
  qemu-img create -f qcow2 -F raw -b "$ISO" "$INS_IMG" >/dev/null
fi
cp --update=none /usr/share/OVMF/OVMF_VARS_4M.fd "$DUMP/prep-OVMF_VARS.fd" 2>/dev/null || true

# GPU=1：把 RTX 5070 直通进来（装 1401 必须 —— install.sh 会检查 PCI 上有没有 NVIDIA 卡）
# 这时没有 VGA 设备，固件控制台用 ramfb，客机画面由 1401 驱动后直接出在面板上。
GPU="${GPU:-0}"
GPU_ROOT_PORT="${GPU_ROOT_PORT:-1}"
GPUARGS=()
if [ "$GPU" = 1 ]; then
  if [ "$GPU_ROOT_PORT" = 1 ]; then
    GPUARGS+=(-device pcie-root-port,id=gpu_rp,chassis=1,slot=2)
    _GB1=",bus=gpu_rp,addr=0x0,multifunction=on"
    _GB2=",bus=gpu_rp,addr=0x0.1"
  else
    _GB1=""; _GB2=""
  fi
  GPUARGS+=(-device "vfio-pci,host=0000:01:00.0${_GB1},rombar=0")
  GPUARGS+=(-device "vfio-pci,host=0000:01:00.1${_GB2}")
  VGAARGS=(-vga none -device ramfb)
else
  VGAARGS=(-vga std -global VGA.vgamem_mb=256 -global VGA.xres=1920 -global VGA.yres=1200)
fi

# 注意：APM 封装的 ISO 必须当硬盘挂（ide-hd）。当 CD-ROM 挂时 OpenCore 的 HFS
# 驱动扫不到它，菜单里就只有 OPENCORE 一项。
qemu-system-x86_64 \
  -name macos15-prep \
  -machine q35,accel=kvm \
  -global ICH9-LPC.disable_s3=1 \
  -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off \
  -cpu "EPYC-Genoa,topoext=on,+invtsc,+hypervisor" \
  -smp "$SMP",sockets=1,cores="$SMP",threads=1 \
  -m "$MEM" \
  -smbios "type=1,manufacturer=Apple Inc.,product=iMac20,,2,version=1.0" \
  -device "isa-applesmc,osk=$SMC_OSK" \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file="$DUMP/prep-OVMF_VARS.fd" \
  -global q35-pcihost.pci-hole64-size=64G \
  -fw_cfg "name=opt/ovmf/X-PciMmio64Mb,file=$DUMP/pci-mmio64.bin" \
  -drive if=none,id=oc,file="$OC_IMG",format=qcow2 \
  -device ide-hd,drive=oc,bus=ide.0 \
  -drive if=none,id=mac,file="$IMG",format=qcow2,discard=unmap,detect-zeroes=unmap \
  -device ide-hd,drive=mac,bus=ide.1 \
  -drive "if=none,id=ins,file=$INS_IMG,format=qcow2" \
  -device ide-hd,drive=ins,bus=ide.2 \
  -device qemu-xhci,id=xhci,p2=8,p3=8 \
  -device usb-kbd -device usb-tablet \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2223-:22 \
  -device usb-net,netdev=net0 \
  "${GPUARGS[@]}" \
  "${VGAARGS[@]}" \
  -display none \
  -vnc 127.0.0.1:1 \
  -serial file:"$DUMP/prep-serial.log" \
  -monitor unix:"$DUMP/prep-monitor.sock",server,nowait \
  -qmp unix:"$DUMP/prep-qmp.sock",server,nowait \
  -D "$DUMP/prep-qemu.log" \
  -daemonize -pidfile "$PID"

sleep 1
if running; then
  echo "准备用 VM 已启动  pid=$(cat "$PID")"
  echo "  画面:  VNC 127.0.0.1:5901   （VNC_PORT=5901 python3 tools/vncctl.py snap /tmp/opencode/prep.png）"
  echo "  串口:  $DUMP/prep-serial.log"
  echo "  目标盘: $IMG  $(du -h "$IMG" | cut -f1)（稀疏）"
else
  echo "启动失败，看 $DUMP/prep-qemu.log" >&2
  tail -5 "$DUMP/prep-qemu.log" 2>/dev/null
  exit 1
fi
