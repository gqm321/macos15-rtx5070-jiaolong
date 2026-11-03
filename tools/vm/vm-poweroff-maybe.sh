#!/usr/bin/env bash
# macos-vm.service 的 ExecStopPost：
#   VM 自己在客机里关机退出  → 把宿主也关掉
#   主动停止（systemctl stop / 宿主重启）→ 不关（vm-stop.sh 会先建 /run/macosvm-stopping）
#
# 为什么不轮询：昨天的 vm-poweroff-watch.service 跟 macos-vm.service 形成了
# ordering cycle，systemd 开机就把它的 start job 删了，所以一直没关机。
set -uo pipefail
W="/home/guqiaomu/vm-macos-qemu"
FLAG=/run/macosvm-stopping
MARK="$W/dump/vm-started-at"
MIN_RUN="${MIN_RUN:-60}"   # 跑不够这么久就退出 = 启动失败，别关宿主（否则会变成开机死循环）

log() { echo "poweroff-maybe: $*"; }

if [ -f "$FLAG" ]; then
  rm -f "$FLAG"
  log "主动停止（$FLAG 存在），不关宿主"
  exit 0
fi

started=$(cat "$MARK" 2>/dev/null || echo 0)
case "$started" in ''|*[!0-9]*) started=0 ;; esac
if [ "$started" -eq 0 ]; then
  log "没有启动标记（VM 没正常起来过），不关宿主"
  exit 0
fi

ran=$(( $(date +%s) - started ))
if [ "$ran" -lt "$MIN_RUN" ]; then
  log "VM 只跑了 ${ran}s（< ${MIN_RUN}s），当成启动失败，不关宿主"
  exit 0
fi

log "VM 跑了 ${ran}s 后自己退出 → 3 秒后关宿主"
if [ "${DRY_RUN:-0}" = 1 ]; then
  log "DRY_RUN=1：这里本该执行 systemctl poweroff"
  exit 0
fi
sleep 3
sync
systemctl poweroff
