#!/usr/bin/env bash
# 操作裸机 ESP（p4）：开 OpenCore 调试日志 / 读回日志。
#
#   sudo bash tools/oc-esp.sh debug-on     # 开 AppleDebug + ApplePanic + 文件日志
#   sudo bash tools/oc-esp.sh log          # 打印 ESP 上的日志文件
#   sudo bash tools/oc-esp.sh mount        # 挂到 /mnt/oc 自己看
set -uo pipefail
P4=${P4:-${DISK:-/dev/disk/by-id/nvme-ZHITAI_TiPlus7100_1TB_ZTA71T0AB252817B43}-part4}
MNT=/mnt/oc
W="/home/guqiaomu/vm-macos-qemu"

mount_p4() {
  mkdir -p "$MNT"
  mountpoint -q "$MNT" || mount "$P4" "$MNT" || { echo "挂载失败" >&2; exit 1; }
}

case "${1:-}" in
  mount) mount_p4; echo "已挂到 $MNT"; ls -la "$MNT" | head ;;
  log)
    mount_p4
    echo "=== ESP 根目录 ==="
    ls -la "$MNT"
    shopt -s nullglob
    mkdir -p "$W/dump/oclog"
    found=0
    for f in "$MNT"/*.txt "$MNT"/*.log "$MNT"/EFI/OC/*.txt "$MNT"/EFI/OC/*.log; do
      found=1
      b=$(basename "$f")
      cp -f "$f" "$W/dump/oclog/$b" 2>/dev/null || true
      echo; echo "=== $b （共 $(wc -l < "$f") 行，尾部 40 行）==="
      tail -40 "$f"
    done
    [ "$found" = 0 ] && echo "（ESP 上没有任何日志文件 —— 说明 OpenCore 没写出文件日志，或者本次根本没跑到写日志的阶段）"
    echo; echo "已备份到 $W/dump/oclog/"
    umount "$MNT" 2>/dev/null || true
    ;;
  debug-on)
    mount_p4
    PYTHONPATH=$W/.pylib python3 - "$MNT" <<'PY'
import plistlib, sys
p = sys.argv[1] + "/EFI/OC/config.plist"
pl = plistlib.load(open(p, "rb"))
d = pl["Misc"]["Debug"]
nv = pl["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]
# debug=0x100 = DB_LOG_PI_SCRN：panic 时把内容留在屏幕上、并且不自动重启
nv["boot-args"] = nv["boot-args"].replace("debug=0x8", "debug=0x100")
if "debug=0x100" not in nv["boot-args"]:
    nv["boot-args"] += " debug=0x100"
d["AppleDebug"] = True
d["ApplePanic"] = True
d["DisableWatchDog"] = True
d["Target"] = 0x43          # 0x01 开日志 + 0x02 控制台 + 0x40 写文件
d["DisplayLevel"] = 0x80000042
open(p, "wb").write(plistlib.dumps(pl, fmt=plistlib.FMT_XML))
print("已写入:", {k: d[k] for k in ("AppleDebug","ApplePanic","Target","DisplayLevel","DisableWatchDog")})
print("boot-args:", pl["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["boot-args"])
PY
    sync
    umount "$MNT"
    echo "已卸载。现在开机测试，回来再跑：sudo bash $0 log"
    ;;
  *) echo "用法: $0 debug-on|log|mount"; exit 1 ;;
esac
