# Route A — macOS in QEMU/KVM with RTX 5070 passthrough

This is the route we validated first, and the one that produced the macOS installation we later
transplanted to bare metal. It is **retired** now, but the parts that were hard to figure out are
worth keeping.

The goal was not "a VM window on the desktop" but **"boot the machine and land in macOS"**: a GRUB
entry that starts the host in a special mode, a systemd unit that brings the VM up with the GPU
passed through, and a guest shutdown that powers the *host* off. Close to a real Mac.

---

## 1. Host preparation

```bash
# AMD-V / IOMMU must be on in firmware (SVM + IOMMU), and the kernel needs:
#   amd_iommu=on iommu=pt
# Check that the GPU sits in its own IOMMU group:
for g in /sys/kernel/iommu_groups/*/devices/*; do echo "$g"; done | grep -i 01:00
```

The RTX 5070 (`01:00.0`) and its HDMI audio function (`01:00.1`) must be in a group that contains
nothing else you need. `tools/vm/vfio-bind.sh` / `vfio-unbind.sh` bind and unbind `vfio-pci`,
`vfio-status.sh` prints what is currently bound.

### BAR1 — the single most important prerequisite

The firmware gives the GPU an **8 GiB** BAR1 (Resizable BAR). QEMU's guest firmware (OVMF) **hangs at
`PCI configuration`** with 8 GiB. Shrink it to 4 GiB *before* the guest starts:

```bash
sudo bash tools/vm/bar1-set.sh 12 --no-flr      # 12 => 4 GiB, --no-flr avoids a function-level reset
python3 -c "l=open('/sys/bus/pci/devices/0000:01:00.0/resource').readlines(); \
a,b=[int(x,16) for x in l[1].split()[:2]]; print('%.2f GiB'%((b-a+1)/2**30))"
```

`tools/vm/bar1-boot.sh` does the same at boot time and is what the systemd unit calls.

> Note: on bare metal, 8 GiB is **not** a problem for macOS itself (see the bare-metal doc). The 8 GiB
> limit here is a QEMU/OVMF limitation, not a macOS one.

---

## 2. Launching the guest

`tools/vm/prep-realmac.sh` is the launcher used to prepare the installation that was later transplanted:

```bash
GPU=1 INS_IMG=mac15-gpt.qcow2 bash tools/vm/prep-realmac.sh          # start with GPU passthrough
bash tools/vm/prep-realmac.sh --stop                                  # ACPI shutdown of the guest
```

Highlights of what it does (see the script for the full argument list):

- `-M q35`, OVMF, `ide-hd` for the macOS disk (virtio-blk does not work for this installer),
- the GPU plus its audio function passed through, host display untouched,
- VNC on `5901` for the pre-GPU phase (once the NVIDIA driver loads, the guest owns the panel),
- QMP socket in `dump/` so the guest can be shut down cleanly instead of being killed
  (`tools/misc/qmp.py`),
- `--stop` performs an **ACPI shutdown**, never a `kill`. Killing a GPU-passthrough guest leaves the
  device in a state that can wedge the host.

### The installer ISO problem

The retail ISO is **APM-partitioned** (`Apple_partition_map`). OpenCore's `ScanPolicy = 0` still does
not see a boot entry on it. `mac15-gpt.qcow2` is a small overlay whose first sectors were replaced with
a hand-built **GPT** describing the same Apple_HFS partition, so OpenCore recognises it.
`tools/misc/gpt-wrap.py` builds that header.

---

## 3. Autostart: GRUB entry + systemd unit

The pieces are archived verbatim in [`../attic/`](../attic/):

| File | Role |
|---|---|
| `attic/grub-40_macos_vm` | generates the GRUB menu entry `macOS VM (RTX 5070 passthrough, MUX)`; it boots the normal Ubuntu kernel with an extra `macosvm=1` on the command line |
| `attic/macos-vm.service` | starts the VM **only** when `macosvm=1` is present (`ConditionKernelCommandLine=`) |

That design means normal boots never touch vfio: the GPU stays with the `nvidia` driver for daily use.

```bash
sudo install -m 755 attic/grub-40_macos_vm /etc/grub.d/40_macos_vm
sudo install -m 644 attic/macos-vm.service /etc/systemd/system/macos-vm.service
sudo systemctl enable macos-vm.service
sudo update-grub                      # or: bash tools/vm/install-grub-vm-entry.sh
```

### Traps we hit here

- **systemd ordering cycle.** Starting the VM from a unit that pulls in the graphical session creates
  a dependency loop; the unit needs `After=local-fs.target systemd-user-sessions.service` and must run
  the emulator as the desktop user (via `setpriv`), otherwise the serial/QMP sockets end up owned by root.
- **"VM fails to start → host powers off → boots → fails again" loop.** Solved by writing a timestamp
  after a successful start (`ExecStartPost`) and having `ExecStopPost` power the host off *only* if that
  timestamp exists (`tools/vm/vm-poweroff-maybe.sh`).
- **Host loses its display** the moment vfio grabs the GPU. Do the first boots over SSH/VNC.
- **VMware Workstation's modules** conflict with KVM on some kernels; it was removed entirely on this machine.

---

## 4. Why this route was abandoned

It worked (macOS 15.8.1 booted with `nvrmfb`, 2560×1600, Metal 3, NullMoth 2.6.5 running), but:

- the host cannot use the GPU while the guest has it, and the panel is wired to the GPU (MUX) — so the
  host is effectively headless in VM mode;
- BAR1 has to be re-shrunk on every boot;
- the extra virtualization layer makes ACPI/power behaviour differ from the real machine, which is
  exactly what we wanted to test.

Once the APFS container had been transplanted, the VM's only remaining value was "a place to read the
macOS disk from Linux". That is why `macreal.qcow2` is kept as a backup and everything else was removed.

## 5. Retiring it

```bash
sudo bash tools/vm/cleanup-vm.sh --dry-run     # show what would go
sudo bash tools/vm/cleanup-vm.sh               # disable the unit, drop the GRUB entry, delete images
```

It disables `macos-vm.service`, deletes `/etc/grub.d/40_macos_vm`, runs `update-grub` and removes the
VM disk images — while **keeping** the scripts, configs and documentation. `macreal.qcow2` is kept by
default because it is the only source backup of the macOS installation; add `--with-backup` to drop it too.
