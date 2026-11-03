#!/usr/bin/env bash
# P1: boot the existing macOS 26.4.1 install in QEMU, with the dGPU passed in.
#
#   bash ~/vm-macos-qemu/run-macos.sh [--daemon] [--no-rom] [--no-gpu]
#
# VNC: 127.0.0.1:0 (port 5900).  Monitor socket: dump/mac-monitor.sock
# Serial: dump/mac-serial.log.  Screenshot: tools/vncsnap.py (no root needed).
set -uo pipefail
umask 022

WORK="/home/guqiaomu/vm-macos-qemu"
DUMP="$WORK/dump"
GPU="0000:01:00.0"
GPU_AUD="0000:01:00.1"
ROM="$DUMP/vbios-full.rom"
GPU_EXTRA="${GPU_EXTRA:-}"
OC_IMG="${OC_IMG:-$WORK/OpenCore-mac15-mbp2.qcow2}"
MAC_IMG="${MAC_IMG:-$WORK/macOS26-overlay.qcow2}"
# Optional installer media (createinstallmedia-style HFS volume) as a SATA CD-ROM.
INSTALLER="${INSTALLER:-}"

DAEMON=0
WITH_ROM=1
WITH_GPU=1
DEBUG=0
WITH_USB=1
VGA="${VGA:-std}"
# 模拟 VGA 的显存和初始分辨率（只对 std 有效）：VGA_MEM=64 VGA_XRES=1920 VGA_YRES=1080
VGAARGS=()
if [ "$VGA" = "std" ]; then
  [ -n "${VGA_MEM:-}" ]  && VGAARGS+=(-global "VGA.vgamem_mb=$VGA_MEM")
  [ -n "${VGA_XRES:-}" ] && VGAARGS+=(-global "VGA.xres=$VGA_XRES")
  [ -n "${VGA_YRES:-}" ] && VGAARGS+=(-global "VGA.yres=$VGA_YRES")
fi
# AppleSMC 设备：VirtualSMC 需要一块真实的 SMC 后端。NullMoth 的参考配置给的是
#   -device isa-applesmc,osk=<64 字节真 OSK>
# 缺它时 macOS 能启动、能 SSH、kext 全加载、BAR1 也放对，但显示永远不初始化。
# SMC_OSK 为空则不传（保持原来的 VirtualSMC 独立路径）。
SMCARGS=()
[ -n "${SMC_OSK:-}" ] && SMCARGS=(-device "isa-applesmc,osk=$SMC_OSK")
# RAMFB=1：给固件一块 ramfb（OVMF 的 QemuRamfbDxe 会驱动它），客机里**没有 PCI 显示设备**，
# 所以 macOS 不会建 IONDRVFramebuffer / .Display_boot，NVRMFB 是唯一的 display 0。
# 配合 VGA=none 使用。
FBARGS=()
[ "${RAMFB:-0}" = 1 ] && FBARGS=(-device ramfb)

# INPUT_EVDEV=1：把宿主自带的键盘/触摸板直通给客机（笔记本键盘是 PS/2、触摸板是 I2C，
# 都没法 usb-host 直通）。需要 tools/grant-input.sh 先授权 /dev/input/event* 给 plugdev。
# grab_all=on：没有 QEMU 窗口时也必须独占，否则按键到不了客机。
find_evdev() {   # $1 = 设备名里的一段
  for d in /sys/class/input/event*/device/name; do
    [ -f "$d" ] || continue
    case "$(cat "$d" 2>/dev/null)" in
      *"$1"*) echo "/dev/input/$(basename "$(dirname "$(dirname "$d")")")"; return 0 ;;
    esac
  done
  return 1
}
INPUTARGS=()
USBHOSTARGS=()
if [ "${INPUT_EVDEV:-0}" = 1 ]; then
  KBD_DEV="${KBD_DEV:-$(find_evdev "AT Translated Set 2 keyboard" || true)}"
  # 触摸板要用带 ABS_X/ABS_Y 的那个节点：QEMU 的 input-linux 只能把绝对坐标喂给
  # usb-tablet，相对节点（"...Mouse"）的事件会被丢掉，光标不动。
  if [ "${REL_MOUSE:-0}" = 1 ]; then
    MOUSE_DEV="${MOUSE_DEV:-$(find_evdev "UNIW0001:00 093A:0255 Mouse" || true)}"
  else
    MOUSE_DEV="${MOUSE_DEV:-$(find_evdev "UNIW0001:00 093A:0255 Touchpad" || true)}"
  fi
  [ -r "$KBD_DEV" ]   && INPUTARGS+=(-object "input-linux,id=vmkbd,evdev=$KBD_DEV,grab_all=on,repeat=on")
  # USB_MOUSE=1：把真鼠标（G502 X）用 usb-host 直通给客机，手感才是原生的。
  # 这时不再挂触摸板的 input-linux（那个是绝对坐标，像数位板）。
  if [ "${USB_MOUSE:-0}" = 1 ]; then
    USBHOSTARGS=(-device "usb-host,bus=xhci.0,vendorid=0x${USB_MOUSE_VID:-046d},productid=0x${USB_MOUSE_PID:-c099}")
    MOUSE_DEV=""
  fi
  [ -n "$MOUSE_DEV" ] && [ -r "$MOUSE_DEV" ] && INPUTARGS+=(-object "input-linux,id=vmmouse,evdev=$MOUSE_DEV,grab_all=on")

  # 真 USB 鼠标：evdev 走 input-linux（相对事件），macOS 拿到的是原生鼠标。
  # MOUSE_EVDEV=auto 自动挑第一个 by-id 里的 *-event-mouse（优先 Logitech）；
  # 设成 none 或找不到可读节点就跳过。
  if [ "${MOUSE_EVDEV:-auto}" != "none" ]; then
    if [ "${MOUSE_EVDEV:-auto}" = "auto" ]; then
      MOUSE_EVDEV=""
      for c in /dev/input/by-id/usb-Logitech*-event-mouse /dev/input/by-id/*-event-mouse; do
        [ -r "$c" ] && { MOUSE_EVDEV="$c"; break; }
      done
    fi
    [ -n "${MOUSE_EVDEV:-}" ] && [ -r "$MOUSE_EVDEV" ] && \
      INPUTARGS+=(-object "input-linux,id=usbmouse,evdev=$MOUSE_EVDEV,grab_all=on")
  fi
  echo "input: kbd=$KBD_DEV mouse=$MOUSE_DEV usbmouse=${MOUSE_EVDEV:-none}" >&2
fi
SMP="${SMP:-8}"
CPU="${CPU:-EPYC-Genoa,topoext=on,+invtsc,+hypervisor}"
while [ $# -gt 0 ]; do
  case "$1" in
    --daemon) DAEMON=1 ;;
    --no-rom) WITH_ROM=0 ;;
    --no-gpu) WITH_GPU=0 ;;
    --no-usb) WITH_USB=0 ;;
    --debug) DEBUG=1 ;;
    --smp) SMP="$2"; shift ;;
    --cpu) CPU="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$WITH_GPU" = 1 ]; then
  if [ "$(basename "$(readlink -f "/sys/bus/pci/devices/$GPU/driver" 2>/dev/null)" 2>/dev/null)" != "vfio-pci" ]; then
    echo "dGPU is not on vfio-pci; run vfio-boot-setup.sh + reboot" >&2
    exit 1
  fi
  if [ -n "${SUDO_USER:-}" ]; then :; fi
  if [ ! -r /dev/vfio/14 ]; then
    echo "/dev/vfio/14 not readable by $USER (sudo chown $USER /dev/vfio/14)" >&2
    exit 1
  fi
fi

# VFIO pins all guest RAM; the default 8 MB RLIMIT_MEMLOCK gives -ENOMEM.
if [ "$(id -u)" -eq 0 ]; then
  ulimit -l unlimited 2>/dev/null || true
fi
if [ "$(ulimit -l)" != "unlimited" ]; then
  echo "warning: RLIMIT_MEMLOCK=$(ulimit -l) KB - vfio will fail with -12." >&2
  echo "  raise it for the agent process, or run this script with sudo." >&2
fi

GPUARGS=()
if [ "$WITH_GPU" = 1 ]; then
  # GPU_ROOT_PORT=1: 把显卡挂在一个 PCIe root port 后面（客机里是 bus 01 而不是 00），
  # 这是 macOS 直通常见写法，也给固件一个可以分配 BAR 的桥窗口。
  if [ "${GPU_ROOT_PORT:-0}" = 1 ]; then
    GPUARGS+=(-device pcie-root-port,id=gpu_rp,chassis=1,slot=2)
    GPUBUS=",bus=gpu_rp,addr=0x0,multifunction=on"
    GPUBUS2=",bus=gpu_rp,addr=0x0.1"
  else
    GPUBUS=""; GPUBUS2=""
  fi
  if [ "$WITH_ROM" = 1 ] && [ -s "$ROM" ] && [ "$(xxd -p -l2 "$ROM")" = "55aa" ]; then
    GPUARGS+=(-device "vfio-pci,host=$GPU${GPUBUS}${GPU_EXTRA},romfile=$ROM")
  else
    GPUARGS+=(-device "vfio-pci,host=$GPU${GPUBUS}${GPU_EXTRA}")
  fi
  GPUARGS+=(-device "vfio-pci,host=$GPU_AUD${GPUBUS2}")
fi

cp --update=none /usr/share/OVMF/OVMF_VARS_4M.fd "$DUMP/OVMF_VARS-mac.fd" 2>/dev/null || true

# OVMF 的 PciHostBridgeLib 读 fw_cfg "opt/ovmf/X-PciMmio64Mb" 时要求数据**正好 8 字节**
# （sizeof UINT64，小端，单位 MB），qemu 的 string=65536 只有 6 字节 → 被忽略 →
# OVMF 没有 64 位窗口 → 8 GB 的 ReBAR BAR1 被硬塞进 32 位空间并写坏地址。
# 这里改成写一个 8 字节二进制文件。
MMIO64_MB="${MMIO64_MB:-65536}"
if [ "${MMIO64_MODE:-binary}" = binary ]; then
  esc=$(printf '\\x%02x\\x%02x\\x%02x\\x%02x\\x00\\x00\\x00\\x00' \
    $(( MMIO64_MB & 255 )) $(( (MMIO64_MB >> 8) & 255 )) \
    $(( (MMIO64_MB >> 16) & 255 )) $(( (MMIO64_MB >> 24) & 255 )))
  printf "$esc" > "$DUMP/pci-mmio64.bin"
  MMIO64_ARGS=(-fw_cfg "name=opt/ovmf/X-PciMmio64Mb,file=$DUMP/pci-mmio64.bin")
else
  MMIO64_ARGS=(-fw_cfg "name=opt/ovmf/X-PciMmio64Mb,string=$MMIO64_MB")
fi

ARGS=(
  -name "${VM_NAME:-macos26}"
  -machine q35,accel=kvm
  -global ICH9-LPC.disable_s3=1
  # 关键：QEMU 默认让 PCIe root port 的 ACPI 窗口报零尺寸，macOS 读到就认为桥后面
  # 没有地址空间 → 设备在 config space 可见但没有 BAR/中断/IORegistry 节点，
  # 驱动不会 attach，placeLargeBar1() 也拿不到父桥。关掉后窗口才是真的。
  -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
  -cpu "$CPU"
  -smp "$SMP",sockets=1,cores="$SMP",threads=1
  -m "${MEM:-16384}"
  -smbios "type=1,manufacturer=Apple Inc.,product=iMac20,,2,version=1.0"
  "${SMCARGS[@]}"
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
  -drive if=pflash,format=raw,file="$DUMP/OVMF_VARS-mac.fd"
  -global q35-pcihost.pci-hole64-size=64G
  "${MMIO64_ARGS[@]}"
  -drive if=none,id=oc,file="$OC_IMG",format=qcow2
  -device ide-hd,drive=oc,bus=ide.0
  -drive if=none,id=mac,file="$MAC_IMG",format=qcow2,discard=unmap,detect-zeroes=unmap
  -device ide-hd,drive=mac,bus=ide.1
  "${GPUARGS[@]}"
  -vga "$VGA" "${VGAARGS[@]}" "${FBARGS[@]}"
  "${INPUTARGS[@]}"
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22
  -display "${QEMU_DISPLAY:-none}"
  -vnc 127.0.0.1:0
  -serial file:"$DUMP/mac-serial.log"
  -monitor unix:"$DUMP/mac-monitor.sock",server,nowait
  -qmp unix:"$DUMP/mac-qmp.sock",server,nowait
  -D "$DUMP/mac-qemu.log"
)

# Installer media: a createinstallmedia-style HFS(+) volume, exposed as SATA CD-ROM
# (default) or SATA hard disk (INSTALLER_AS_HD=1, needed for APM-wrapped ISOs).
if [ -n "$INSTALLER" ]; then
  if [ "${INSTALLER_AS_HD:-0}" = 1 ]; then
    ARGS+=(-drive "if=none,id=ins,file=$INSTALLER,format=${INSTALLER_FMT:-qcow2}"
           -device ide-hd,drive=ins,bus=ide.2)
  else
    ARGS+=(-drive "if=none,id=ins,file=$INSTALLER,format=raw,media=cdrom,readonly=on"
           -device ide-cd,drive=ins,bus=ide.2)
  fi
fi

# NOREB00T=1: exit instead of letting the guest reset (useful for panics).
if [ "${NOREB00T:-0}" = 1 ]; then
  ARGS+=(-no-reboot)
fi

if [ "$WITH_USB" = 1 ]; then
  # REL_MOUSE=1：用 usb-mouse（相对 HID 鼠标）而不是 usb-tablet（绝对），
  # 这样 macOS 才会对指针做自己的加速度，手感正常；配合触摸板的相对节点（"...Mouse"）。
  PTRDEV=usb-tablet
  [ "${REL_MOUSE:-0}" = 1 ] && PTRDEV=usb-mouse
  # p2/p3=8：qemu-xhci 默认只有 4 个 USB2 口，键盘/鼠标/网卡占 3 个之后，
  # 第 4 个设备（U 盘直通）会被 QEMU 自动挂到一个模拟 hub 后面 —— 而 macOS 的
  # IOUSBHost **不枚举 QEMU 模拟 hub 后面的设备**（实测：第二个鼠标、usb-storage 都看不见）。
  # 加口之后直通设备直接落在根端口上。
  ARGS+=(-device qemu-xhci,id=xhci,p2=8,p3=8 -device usb-kbd,id=kbd -device "$PTRDEV",id=tablet
         -device usb-net,netdev=net0)
  # 真鼠标直通放在 xhci 之后（usb-host 需要一个已经存在的 usb-bus）
  ARGS+=("${USBHOSTARGS[@]}")
fi

if [ "$DEBUG" = 1 ]; then
  ARGS+=(
    -chardev "file,id=dbg,path=$DUMP/ovmf-debug.log"
    -device isa-debugcon,iobase=0x402,chardev=dbg
  )
fi

rm -f "$DUMP/mac-serial.log" "$DUMP/mac-qemu.log" "$DUMP/mac.pid" "$DUMP/mac-monitor.sock" "$DUMP/mac-qmp.sock"

if [ "$DAEMON" = 1 ] && [ -n "${QEMU_STDERR_LOG:-}" ]; then
  # 后台跑但保留 stderr，且用 setsid 脱离终端会话（前台模式会被 SIGHUP 带走）。
  setsid nohup qemu-system-x86_64 "${ARGS[@]}" >"$QEMU_STDERR_LOG" 2>&1 &
  echo $! > "$DUMP/mac.pid"
  sleep 1
  kill -0 "$(cat "$DUMP/mac.pid")" 2>/dev/null || { echo "qemu failed to start, see $QEMU_STDERR_LOG" >&2; tail -3 "$QEMU_STDERR_LOG" >&2; exit 1; }
  chmod 0666 "$DUMP/mac-monitor.sock" "$DUMP/mac-qmp.sock" 2>/dev/null || true
  chmod 0644 "$DUMP/mac-serial.log" "$DUMP/mac-qemu.log" "$DUMP/mac.pid" 2>/dev/null || true
  echo "started pid $(cat "$DUMP/mac.pid") (stderr -> $QEMU_STDERR_LOG)"
elif [ "$DAEMON" = 1 ]; then
  qemu-system-x86_64 "${ARGS[@]}" -daemonize -pidfile "$DUMP/mac.pid" || exit 1
  sleep 0.5
  chmod 0666 "$DUMP/mac-monitor.sock" "$DUMP/mac-qmp.sock" 2>/dev/null || true
  chmod 0644 "$DUMP/mac-serial.log" "$DUMP/mac-qemu.log" "$DUMP/mac.pid" 2>/dev/null || true
  echo "started pid $(cat "$DUMP/mac.pid" 2>/dev/null)"
else
  exec qemu-system-x86_64 "${ARGS[@]}"
fi
