#!/usr/bin/env bash
# 用 root 抬 RLIMIT_MEMLOCK 后降权到 guqiaomu 启动 VM。
#
# 为什么需要：vfio 会把整块客机内存 pin 住（10 GB），而本机 tty/agent 的
# memlock 硬上限是 8192 KB → QEMU 报
#   vfio_container_dma_map(...) = -12 (Cannot allocate memory)
# root 才能把硬上限抬到 infinity；抬完再 setpriv 回普通用户，避免 dump/
# 里的串口日志、monitor socket、pidfile 变成 root 属主（mux-verify.sh 会读不了）。
#
#   sudo bash ~/vm-macos-qemu/start-vm.sh                 # 默认 --daemon --no-rom
#   sudo bash ~/vm-macos-qemu/start-vm.sh --no-rom        # 前台跑，看串口
#   sudo GPU_EXTRA=,rombar=0 sudo bash .../start-vm.sh    # 覆盖 GPU 参数
#
# 长期方案（可选，就不用每次 sudo 了）：
#   echo 'guqiaomu - memlock unlimited' | sudo tee /etc/security/limits.d/90-vfio-memlock.conf
#   # 然后重新登录（或 systemctl --user daemon-reexec 后重开终端）
set -euo pipefail

WORK="$(cd "$(dirname "$0")" && pwd)"
OWNER="guqiaomu"
HOME_DIR="/home/$OWNER"
# 注意：**不要**加 x-no-mmap=on。它会让客机对 BAR1 的每次访问都被 KVM 截获，
# 显示走拷贝路径时一帧要几分钟（画面从上往下慢慢刷）。BAR1 由驱动自己放置之后
# 已经不需要它了。早期版本为了绕 QEMU abort 加过，现在默认去掉。
EXTRA="${GPU_EXTRA:-,rombar=0}"
VGAENV=()
[ -n "${VGA:-}" ] && VGAENV=(VGA="$VGA")
OCENV=()
[ -n "${OC_IMG:-}" ] && OCENV=(OC_IMG="$OC_IMG")
VGAMEM=()
for v in VGA_MEM VGA_XRES VGA_YRES; do eval "val=\${$v:-}"; [ -n "$val" ] && VGAMEM+=("$v=$val"); done

ARGS=("$@")
# --patch-test: 用可丢弃的测试 overlay（dump/test-patch.qcow2）起 VM，
# 里面的 kext 改动不会碰真实系统盘。
IMG_ENV=()
if [ "${1:-}" = "--patch-test" ]; then
  shift
  ARGS=("$@")
  [ ${#ARGS[@]} -gt 0 ] || ARGS=(--daemon --no-rom)
  IMG_ENV=(MAC_IMG="$WORK/dump/test-patch.qcow2")
fi
[ ${#ARGS[@]} -gt 0 ] || ARGS=(--daemon --no-rom)

# 不需要 root：qemu 二进制带了 CAP_IPC_LOCK（tools/grant-agent-vm.sh），
# 内核在 __account_locked_vm() 里放行，RLIMIT_MEMLOCK 的 8 MB 硬上限绕开了。
# 仍然兼容 `sudo bash start-vm.sh`：那时会先抬 ulimit 再 setpriv 降权。
if [ "$(id -u)" -eq 0 ]; then
  ulimit -l unlimited 2>/dev/null || true
  echo "memlock=$(ulimit -l) -> 以 $OWNER 启动: run-macos.sh ${ARGS[*]}  (GPU_EXTRA=$EXTRA VGA=${VGA:-std}) ${IMG_ENV[*]:-}"
else
  echo "memlock=$(ulimit -l)（CAP_IPC_LOCK 生效，不需要 root）-> run-macos.sh ${ARGS[*]}  (GPU_EXTRA=$EXTRA VGA=${VGA:-std}) ${IMG_ENV[*]:-}"
fi

EXTRAENV=()
for v in VM_NAME QEMU_DISPLAY NOREB00T INSTALLER INSTALLER_AS_HD INSTALLER_FMT GPU_ROOT_PORT QEMU_STDERR_LOG SMC_OSK RAMFB INPUT_EVDEV KBD_DEV MOUSE_DEV USB_MOUSE REL_MOUSE MEM SMP MOUSE_EVDEV TOUCHPAD_REL; do
  eval "val=\${$v:-}"; [ -n "$val" ] && EXTRAENV+=("$v=$val")
done

if [ "$(id -u)" -eq 0 ]; then
  exec setpriv --reuid="$OWNER" --regid="$OWNER" --init-groups --inh-caps=-all \
    env HOME="$HOME_DIR" GPU_EXTRA="$EXTRA" "${EXTRAENV[@]+"${EXTRAENV[@]}"}" "${IMG_ENV[@]+"${IMG_ENV[@]}"}" "${VGAENV[@]+"${VGAENV[@]}"}" "${OCENV[@]+"${OCENV[@]}"}" "${VGAMEM[@]+"${VGAMEM[@]}"}" \
    bash -c 'cd "$1" && shift && exec bash run-macos.sh "$@"' _ "$WORK" "${ARGS[@]}"
else
  exec env GPU_EXTRA="$EXTRA" "${EXTRAENV[@]+"${EXTRAENV[@]}"}" "${IMG_ENV[@]+"${IMG_ENV[@]}"}" "${VGAENV[@]+"${VGAENV[@]}"}" "${OCENV[@]+"${OCENV[@]}"}" "${VGAMEM[@]+"${VGAMEM[@]}"}" \
    bash -c 'cd "$1" && shift && exec bash run-macos.sh "$@"' _ "$WORK" "${ARGS[@]}"
fi
