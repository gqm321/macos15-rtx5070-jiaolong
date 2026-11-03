#!/usr/bin/env bash
# 日常启动 macOS 15（Sequoia）+ RTX 5070 直通。
# 需要 root：VFIO 要 pin 住 10 GB 客机内存，而本机 RLIMIT_MEMLOCK 硬上限只有 8 MB，
# 所以由 root 起 QEMU，再在 start-vm.sh 里降权回桌面用户。
#
#   sudo bash ~/vm-macos-qemu/start-mac15.sh                  # 窗口 + GPU
#   sudo QEMU_DISPLAY=none bash ~/vm-macos-qemu/start-mac15.sh  # 无头（SSH 用）
#   sudo bash ~/vm-macos-qemu/start-mac15.sh --no-gpu          # 不给 GPU，免 sudo 也能起
#
# 分辨率：VGA_MEM=64 + VGA_XRES/VGA_YRES 默认 2560x1600（16 MB 显存放不下 2560x1600）。
#
# No installer media here: OpenCore-mac15-gpu.qcow2 scans APFS on SATA only, so
# it boots macOS 15 from macOS15.qcow2 straight away.
set -uo pipefail
W="$(cd "$(dirname "$0")" && pwd)"

# 显示：有桌面会话就开窗口（默认），没有就无头（切了 MUX 的情况）。
# 模拟 VGA 给足显存，才能上 2560x1600（默认 16 MB 不够）。
export VM_NAME="${VM_NAME:-macOS15}"
export VGA_MEM="${VGA_MEM:-256}"
export VGA_XRES="${VGA_XRES:-2560}"
export VGA_YRES="${VGA_YRES:-1600}"
# 默认无头。只有显式 QEMU_DISPLAY=gtk 才开窗口 —— 切了 MUX 之后宿主没有显示服务，
# 而残留的 X/Wayland socket 会让"自动探测"误判，QEMU 会以 "gtk initialization failed" 退出。
if [ -z "${QEMU_DISPLAY:-}" ]; then
  QEMU_DISPLAY=none
fi
if [ "$QEMU_DISPLAY" = gtk ] \
   && ! { [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}" ] \
          || ls /tmp/.X11-unix/X* >/dev/null 2>&1; }; then
  echo "$0: 没有可用的显示服务，QEMU_DISPLAY 回落到 none" >&2
  QEMU_DISPLAY=none
fi
export QEMU_DISPLAY
# 默认就是「内屏由 NVIDIA 驱动」这套（2026-11-01 验证通过）：
#   VGA=none + RAMFB=1  -> 固件有 ramfb 控制台，客机里没有 PCI 显示设备
#   OC_IMG=...-mbp.qcow2 -> SMBIOS MacBookPro16,2（关键：iMac20,2 下 CoreDisplay 不认这块 NVRMFB）
#   SMC_OSK=...          -> 与 OSX-KVM / ULTMOS 相同的 64 字节 OSK
# 想回到「宿主窗口 + 2560x1600」的混合模式：
#   sudo VGA=std VGA_MEM=256 OC_IMG=$HOME/vm-macos-qemu/OpenCore-mac15-bar.qcow2 bash start-mac15.sh
export VGA="${VGA:-none}"
export RAMFB="${RAMFB:-1}"
export OC_IMG="${OC_IMG:-$W/OpenCore-mac15-mbp2.qcow2}"
export MAC_IMG="${MAC_IMG:-$W/macOS15.qcow2}"
export SMC_OSK="${SMC_OSK:-ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc}"
# 把笔记本自带的键盘/触摸板直通给客机（PS/2 + I2C，只能走 evdev）。
# 需要先跑过一次 tools/grant-input.sh。
export INPUT_EVDEV="${INPUT_EVDEV:-1}"
# 真鼠标直通（G502 X）。手感原生；触摸板这时就不挂给客机了。
export USB_MOUSE="${USB_MOUSE:-0}"
export REL_MOUSE="${REL_MOUSE:-1}"
export MEM="${MEM:-16384}"
# 8 核：OpenCore 的 cores-per-package 补丁是 0x08，12 核会 panic（试过）
export SMP="${SMP:-8}"
# 显卡必须挂在 PCIe root port 后面：驱动 placeLargeBar1() 要靠父 root port 的窗口
# 才能放 4 GiB 的 BAR1，否则串口里是 "parent root port not found — not placing"，
# BAR1 退回 32 MB、内屏黑。
export GPU_ROOT_PORT="${GPU_ROOT_PORT:-1}"
# 真鼠标（USB）走 input-linux；auto = 自动找 by-id 里第一个 *-event-mouse
export MOUSE_EVDEV="${MOUSE_EVDEV:-auto}"
# 触摸板：宿主侧把绝对坐标转成相对位移（tools/touchpad-rel.py），轻点=左键、双指=右键/滚轮
export TOUCHPAD_REL="${TOUCHPAD_REL:-1}"

# 预检 BAR1：不是 4 GiB 就别起 —— 8 GiB 会让客机卡在 "PCI configuration"，
# 反复启动会把宿主拖死（要靠长按电源键重启）。
BAR1_MB=$(python3 - <<'PY2'
try:
    l = open("/sys/bus/pci/devices/0000:01:00.0/resource").readlines()
    a, b = [int(x, 16) for x in l[1].split()[:2]]
    print((b - a + 1) // (1024 * 1024) if b > a else 0)
except Exception:
    print(0)
PY2
)
if [ "${BAR1_MB:-0}" != "4096" ]; then
  echo "BAR1 是 ${BAR1_MB} MiB，需要 4096 MiB。先跑（宿主刚重启过就加 --no-flr）：" >&2
  echo "  sudo bash $W/tools/bar1-set.sh 12 --no-flr" >&2
  exit 1
fi

if [ "$TOUCHPAD_REL" = 1 ] && [ -r /dev/input/event7 ]; then
  pkill -f "[t]ouchpad-rel" 2>/dev/null || true
  setsid nohup python3 "$W/tools/touchpad-rel.py" --gain 0.7 --accel 0.04 \
    > /tmp/opencode/touchpad-rel.log 2>&1 &
fi

exec bash "$W/start-vm.sh" "$@"
