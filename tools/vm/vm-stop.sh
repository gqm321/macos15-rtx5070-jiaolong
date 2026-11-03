#!/usr/bin/env bash
# 优雅停 VM：先发 ACPI 关机（等价于点苹果菜单里的关机），等它自己退出；
# 超时才 SIGTERM。systemd 的 ExecStop 用。
set -uo pipefail
W="/home/guqiaomu/vm-macos-qemu"
DUMP="$W/dump"
PAT="qemu-system-x86_64 -name macOS15"

running() { pgrep -f "$PAT" >/dev/null 2>&1; }

# 主动停止的标记：vm-poweroff-watch.sh 看到它就不关机
mkdir -p /run && touch /run/macosvm-stopping

if ! running; then
  echo "vm-stop: 没有在跑的 VM"
  exit 0
fi

# ACPI 关机：HMP system_powerdown 会触发客机的正常关机流程
if [ -S "$DUMP/mac-monitor.sock" ]; then
  python3 "$W/tools/hmp.py" "$DUMP/mac-monitor.sock" system_powerdown >/dev/null 2>&1 || true
  echo "vm-stop: 已发送 ACPI 关机"
fi

for _ in $(seq 1 60); do
  running || { echo "vm-stop: 已优雅退出"; exit 0; }
  sleep 2
done

echo "vm-stop: 120 秒没退，发 SIGTERM" >&2
pkill -TERM -f "$PAT" 2>/dev/null || true
for _ in $(seq 1 15); do
  running || { echo "vm-stop: SIGTERM 后退出"; exit 0; }
  sleep 2
done

echo "vm-stop: 仍然在跑，交给 systemd 强杀" >&2
exit 0
