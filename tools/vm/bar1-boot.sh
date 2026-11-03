#!/usr/bin/env bash
# 开机时把 BAR1 调到 4 GiB：先试 --no-flr（刚上电卡是干净的），不行再带 FLR 重试。
# 供 macos-vm.service 的 ExecStartPre 调用（root）。
set -uo pipefail
G=/sys/bus/pci/devices/0000:01:00.0
HERE="$(cd "$(dirname "$0")" && pwd)"

bar1_mb() {
  python3 - "$G" <<'PY'
import sys
try:
    l = open(sys.argv[1] + "/resource").readlines()
    a, b = [int(x, 16) for x in l[1].split()[:2]]
    print((b - a + 1) // (1024 * 1024) if b > a else 0)
except Exception:
    print(0)
PY
}

if [ "$(bar1_mb)" = "4096" ]; then
  echo "bar1: 已经是 4 GiB"
  exit 0
fi

echo "bar1: 现在是 $(bar1_mb) MiB，先试 --no-flr"
bash "$HERE/bar1-set.sh" 12 --no-flr >/dev/null 2>&1 || true
if [ "$(bar1_mb)" = "4096" ]; then
  echo "bar1: 已设为 4 GiB（无 FLR）"
  exit 0
fi

echo "bar1: 重试（带 FLR）"
bash "$HERE/bar1-set.sh" 12 >/dev/null 2>&1 || true
if [ "$(bar1_mb)" = "4096" ]; then
  echo "bar1: 已设为 4 GiB（FLR）"
  exit 0
fi

echo "bar1: 失败，仍是 $(bar1_mb) MiB" >&2
exit 1
