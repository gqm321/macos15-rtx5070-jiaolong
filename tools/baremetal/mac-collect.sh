#!/usr/bin/env bash
# 在 macOS 里收集诊断信息，写到 OpenCore ESP 的 handoff-out/ 目录。
# 那个目录两边的系统都能读（FAT32），回 Ubuntu 后我直接读。
#
#   sudo bash mac-collect.sh
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo bash $0"; exit 1; }

find_oc_esp() {
  local part mnt
  for part in $(diskutil list | awk '/EFI/ {print $NF}' | grep -E '^disk[0-9]+s[0-9]+$'); do
    mnt=$(mktemp -d /tmp/espcheck.XXXXXX)
    if diskutil mount -mountPoint "$mnt" "/dev/$part" >/dev/null 2>&1; then
      if [ -f "$mnt/EFI/OC/config.plist" ]; then
        echo "$part|$mnt"
        return 0
      fi
      diskutil unmount "$mnt" >/dev/null 2>&1
    fi
    rmdir "$mnt" 2>/dev/null
  done
  return 1
}

FOUND=$(find_oc_esp) || { echo "没找到 OpenCore 的 ESP"; exit 1; }
PART="${FOUND%%|*}"; MNT="${FOUND##*|}"
OUT="$MNT/handoff-out"
mkdir -p "$OUT"
echo "ESP: /dev/$PART  -> $OUT"

{
  date
  sw_vers
  uname -a
  echo
  echo "== nvram boot-args =="
  nvram boot-args 2>/dev/null
  echo "== csr =="
  nvram csr-active-config 2>/dev/null
} > "$OUT/summary.txt" 2>&1

system_profiler SPDisplaysDataType > "$OUT/displays.txt" 2>&1
system_profiler SPAudioDataType   > "$OUT/audio.txt"    2>&1
system_profiler SPPowerDataType   > "$OUT/power.txt"    2>&1
system_profiler SPUSBDataType     > "$OUT/usb.txt"      2>&1
ioreg -lw0                        > "$OUT/ioreg.txt"    2>&1
{ kmutil showloaded --list-only 2>/dev/null || kextstat 2>/dev/null; } \
  | grep -vi "com.apple" > "$OUT/kexts-nonapple.txt" 2>&1
ls -la /Library/Extensions > "$OUT/library-extensions.txt" 2>&1
cp -f "$MNT"/opencore-*.txt "$OUT"/ 2>/dev/null
cp -f "$MNT"/panic-*.txt    "$OUT"/ 2>/dev/null
cp -f /var/db/PanicReporter/*.panic "$OUT"/ 2>/dev/null || true

# 电源/关机/唤醒 相关：判断"关机变重启"是复位还是被唤醒
pmset -g > "$OUT/pmset.txt" 2>&1
pmset -g log 2>/dev/null | tail -400 > "$OUT/pmset-log.txt" 2>&1
nvram -p > "$OUT/nvram.txt" 2>&1
{
  echo "== pmset -g assertions =="; pmset -g assertions 2>&1 | head -30
  echo; echo "== 最近的关机/唤醒日志 =="
  log show --last 2h --style compact 2>/dev/null \
    | grep -iE "shutdown|power.?off|S5|Wake reason|sleep transition|restart" | tail -120
} > "$OUT/shutdown-log.txt" 2>&1
sysctl -a 2>/dev/null | grep -iE "nvrmfb|NVRM" > "$OUT/sysctl-nvrm.txt" 2>&1

echo
echo "已写入："
ls -la "$OUT"
diskutil unmount "$MNT" >/dev/null 2>&1
echo
echo "完成。下次回 Ubuntu 时我能直接读到这些。"
