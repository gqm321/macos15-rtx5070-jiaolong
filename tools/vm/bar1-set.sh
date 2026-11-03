#!/usr/bin/env bash
# 把直通显卡的 BAR1 缩到客机固件放得下的尺寸（默认 4 GiB = bit 12）。
#
# 为什么：BIOS 给的 8 GiB ReBAR 会被 OVMF 写到非规范地址（0x85..._00000000），
# 客机里 NVRM 就报 "BAR1 has no address from macOS" 并回退到 32 MB 窗口 —— 内屏
# 2560x1600 的扫描面就塞不下了。缩到 4 GiB 后客机固件能正常落位，驱动随后会
# 自己再放一个 16 GiB 的 BAR，预算 fBarLen/2 = 8 GiB。
#
#   sudo bash tools/bar1-set.sh          # 4 GiB
#   sudo bash tools/bar1-set.sh 11       # 2 GiB
#   sudo bash tools/bar1-set.sh 13       # 8 GiB（原始值，会复现问题）
#   sudo bash tools/bar1-set.sh 12 --no-flr   # 刚断电重启过时跳过复位
#
# 必须在 VM 关闭时跑。
set -euo pipefail
GPU=${GPU:-0000:01:00.0}
BIT=${1:-12}
# 第二个参数 --no-flr：跳过 FLR 复位（宿主刚断电重启过、卡是干净的时候用）。
# 用参数而不是环境变量，因为 sudo 默认会清环境。
NOFLR=0
[ "${2:-}" = "--no-flr" ] && NOFLR=1
G=/sys/bus/pci/devices/$GPU
D=/sys/bus/pci/drivers/vfio-pci

[ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo bash $0 [bit]" >&2; exit 1; }
[ -e "$G" ] || { echo "找不到 $GPU" >&2; exit 1; }
if pgrep -f "qemu-system-x86_64.*$GPU" >/dev/null 2>&1; then
  echo "VM 还在跑，先关掉" >&2; exit 1
fi

show_bar() {
  python3 - "$G" <<'PY'
import sys
l = open(sys.argv[1] + "/resource").readlines()
a, b = [int(x, 16) for x in l[1].split()[:2]]
print("  BAR1 = %.2f GiB  %#x..%#x" % ((b - a + 1) / 2**30, a, b))
PY
}

cur=$(basename "$(readlink -f "$G/driver" 2>/dev/null)" 2>/dev/null || echo none)
echo "GPU $GPU  驱动=$cur  支持位图=$(cat "$G/resource1_resize")"
show_bar

echo "" > "$G/driver_override"
if [ "$cur" != none ]; then
  echo "$GPU" > "/sys/bus/pci/drivers/$cur/unbind"
  echo "已从 $cur 解绑"
fi

# FLR：客机重启不会复位物理卡，残留状态会让驱动静默不点屏（指南 9 节）。
# FLR=0 可跳过（宿主刚断电重启过时卡是干净的，不需要复位）。
if [ "$NOFLR" = 0 ] && [ -w "$G/reset" ]; then
  echo 1 > "$G/reset" 2>/dev/null && echo "已做一次 FLR 复位" || echo "复位失败（继续）"
else
  echo "跳过 FLR（--no-flr）"
fi

echo "$BIT" > "$G/resource1_resize"
echo "已写入 resource1_resize=$BIT"
show_bar

echo "vfio-pci" > "$G/driver_override"
echo "$GPU" > "$D/bind"
echo "已绑回 vfio-pci（$(basename "$(readlink -f "$G/driver")")）"
echo
echo "下一步：sudo OC_IMG=\$HOME/vm-macos-qemu/OpenCore-mac15-bar.qcow2 bash ~/vm-macos-qemu/start-mac15.sh"
