#!/usr/bin/env bash
# 一次性（root）：装一个 GRUB 启动项「macOS VM」，选中它开机后自动把 macOS 15 拉起来。
#
#   sudo bash ~/vm-macos-qemu/tools/install-grub-vm-entry.sh
#
# 做的事：
#   1) /etc/systemd/system/macos-vm.service —— 只在 /proc/cmdline 含 macosvm=1 时才启动
#   2) /etc/grub.d/40_macos_vm              —— 生成带 macosvm=1 的启动项（内核升级后自动跟上）
#   3) update-grub
#
# 撤销：
#   sudo systemctl disable macos-vm.service
#   sudo rm /etc/systemd/system/macos-vm.service /etc/grub.d/40_macos_vm
#   sudo update-grub
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo bash $0" >&2; exit 1; }

W="/home/guqiaomu/vm-macos-qemu"
OWNER="guqiaomu"

# ---- 1) systemd 服务 -------------------------------------------------------
# 注意：绝对不要写 After=multi-user.target —— 本服务是 WantedBy=multi-user.target，
# systemd 给 target 的依赖加了隐含的 Before，两者成环会被砍 job。
# （昨天 vm-poweroff-watch.service 就是这么被 systemd 开机删掉的，所以一直没关机。）
cat > /etc/systemd/system/macos-vm.service <<EOF
[Unit]
Description=macOS 15 VM (RTX 5070 passthrough, MUX to dGPU)
# 只有 GRUB 里「macOS VM」那个启动项才生效（普通启动完全不碰）
ConditionKernelCommandLine=macosvm=1
After=local-fs.target systemd-user-sessions.service

[Service]
Type=forking
PIDFile=$W/dump/mac.pid
# 清掉上次的启动标记：ExecStart 失败时 ExecStopPost 看到「没有标记」就不会关宿主，
# 避免「VM 起不来 → 宿主关机 → 开机 → 又起不来」的死循环。
ExecStartPre=/bin/rm -f $W/dump/vm-started-at
# BAR1 必须是 4 GiB：8 GiB 会让客机卡在 "PCI configuration" 把宿主拖死
ExecStartPre=$W/tools/bar1-boot.sh
# 以桌面用户身份起，串口日志/socket 的属主才是 $OWNER
ExecStart=/usr/bin/setpriv --reuid=$OWNER --regid=$OWNER --init-groups /bin/bash -c 'cd $W && exec bash start-mac15.sh'
# 正常起来后打时间戳，ExecStopPost 用它区分「跑过一阵才退出」和「启动就崩」
ExecStartPost=/bin/sh -c 'rm -f /run/macosvm-stopping; date +%s > $W/dump/vm-started-at; chown $OWNER:$OWNER $W/dump/vm-started-at'
ExecStop=$W/tools/vm-stop.sh
# 关键：VM 自己退出（客机里关机）→ 关宿主；主动停止不关。
# 不用 RemainAfterExit，否则 QEMU 退了 systemd 也不知道，ExecStopPost 不会跑。
ExecStopPost=$W/tools/vm-poweroff-maybe.sh
TimeoutStopSec=200

[Install]
WantedBy=multi-user.target
EOF

# ---- 1b) 删掉昨天那个会成环的看护服务 --------------------------------------
systemctl disable macos-vm-poweroff.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/macos-vm-poweroff.service \
      /etc/systemd/system/multi-user.target.wants/macos-vm-poweroff.service \
      /etc/systemd/system/graphical.target.wants/macos-vm-poweroff.service
rm -f "$W/tools/vm-poweroff-watch.sh"

# ---- 2) GRUB 启动项 --------------------------------------------------------
cat > /etc/grub.d/40_macos_vm <<'SCRIPT'
#!/bin/sh
set -e
KERNEL=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
INITRD=$(ls -1 /boot/initrd.img-* 2>/dev/null | sort -V | tail -1)
[ -n "$KERNEL" ] && [ -n "$INITRD" ] || exit 0
ROOTUUID=$(findmnt -no UUID /)
# 沿用当前内核命令行，去掉 BOOT_IMAGE= 和可能已有的 macosvm=
CMDLINE=$(tr ' ' '\n' < /proc/cmdline | grep -vE '^(BOOT_IMAGE=|macosvm=)' | tr '\n' ' ')
cat <<ENTRY
menuentry 'macOS VM  (RTX 5070 passthrough, MUX)' --id macosvm --class macos --class gnu-linux --class os {
	recordfail
	load_video
	gfxmode \$linux_gfx_mode
	insmod gzio
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root ${ROOTUUID}
	linux	${KERNEL} ${CMDLINE} macosvm=1
	initrd	${INITRD}
}
ENTRY
SCRIPT
chmod 755 /etc/grub.d/40_macos_vm
chmod 644 /etc/systemd/system/macos-vm.service

systemctl daemon-reload
systemctl enable macos-vm.service >/dev/null

# ---- 3) 重新生成 grub.cfg --------------------------------------------------
if command -v update-grub >/dev/null 2>&1; then
  update-grub
elif command -v grub-mkconfig >/dev/null 2>&1; then
  grub-mkconfig -o /boot/grub/grub.cfg
fi

echo
echo "✅ 装好了。GRUB 菜单里多了：macOS VM  (RTX 5070 passthrough, MUX)"
echo "   选它 → Linux 带 macosvm=1 启动 → 自动把 BAR1 设成 4 GiB 并拉起 VM"
echo "   普通启动项不会起 VM"
echo "   在 macOS 里关机 → VM 退出 → 宿主自动关机（systemctl stop 不会）"
echo
echo "自检："
echo "  grep -A7 'macOS VM' /boot/grub/grub.cfg | head -12"
echo "  systemctl cat macos-vm.service | head -20"
echo
echo "本次生效的关机逻辑（必须是 vm-poweroff-maybe.sh，不能是 watch）："
systemctl show -p ExecStopPost --value macos-vm.service
if systemctl is-active --quiet macos-vm.service; then
  echo
  echo "⚠️  macos-vm.service 现在还在跑（本次开机起的那个 VM）。"
  echo "    新的 ExecStopPost 已经载入，但你这次关机时还需要一个启动标记才认；"
  echo "    跑一下这条补上："
  echo "      date +%s > $W/dump/vm-started-at"
fi
