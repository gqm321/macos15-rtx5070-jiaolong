# Scripts

> Inline comments in these scripts are a mix of English and Chinese — they were written while debugging
> and were not normalised. Variable names, flags and output messages are English where it matters.

## `baremetal/` — building and flashing the OpenCore ESP

| Script | What it does |
|---|---|
| `build-efi-ref.py` | builds a 512 MiB FAT32 ESP image in user space from `reference-efi/` + `kexts/`; patches core count, boot-args, kext list and menu items (see `configs/esp-recipes.md`) |
| `build-efi.py` | the older, obsolete builder (VM-derived config, no reference tree). Kept only for history — **do not use** |
| `install-baremetal.sh` | writes the ESP image to `p4`, transplants the APFS container from `macreal.qcow2` into `p5`, registers the firmware boot entry. `--dry-run` prints the plan and validates sizes |
| `verify-transplant.sh` | samples APFS blocks in `p5` and compares their md5 against the same blocks in `macreal.qcow2` |
| `oc-esp.sh` | `debug-on` raises the OpenCore log level (`Target=0x47`, `DisplayLevel=0x80000042`); `log` prints and backs up the log files; `mount` mounts the ESP |
| `mac-flash.sh` | **runs on macOS**: finds the ESP containing `EFI/OC/config.plist`, `dd`s a new image into it, verifies the first block |
| `mac-collect.sh` | **runs on macOS**: dumps displays/audio/power/USB/ioreg/loaded kexts, `pmset -g log`, the recent shutdown log and OpenCore logs into `handoff-out/` on the ESP |

## `vm/` — the retired QEMU route

| Script | What it does |
|---|---|
| `prep-realmac.sh` | QEMU launcher used for the VM that produced the transplanted install (`GPU=1` for vfio passthrough, `--stop` for an ACPI shutdown) |
| `start-mac15.sh`, `run-macos.sh`, `run-macos15.sh`, `start-vm.sh` | older launchers, different eras of the project |
| `bar1-set.sh` | shrinks/restores BAR1 (`12` = 4 GiB); required before the guest firmware boots with the GPU passed through |
| `bar1-boot.sh` | boot-time BAR1 shrink used by the systemd unit |
| `vfio-bind.sh`, `vfio-unbind.sh`, `vfio-status.sh` | bind the GPU (and its audio function) to `vfio-pci` and report the state |
| `vfio-boot-setup.sh`, `vfio-boot-revert.sh`, `vfio-perms.sh` | persistent boot-time binding, reverting it, and device permissions |
| `install-grub-vm-entry.sh` | installs `attic/grub-40_macos_vm` into `/etc/grub.d` and runs `update-grub` |
| `vm-stop.sh`, `vm-poweroff-maybe.sh` | graceful guest stop; "power the host off only if the VM actually ran for a while" logic (avoids a reboot loop) |
| `cleanup-vm.sh` | retires the VM route: disables `macos-vm.service`, removes the GRUB entry, deletes the images (keeps `macreal.qcow2` unless `--with-backup`) |

## `misc/` — small tools

| Script | What it does |
|---|---|
| `qmp.py` | QMP client (guest shutdown, `system_powerdown`, status) |
| `fat32-replace.py` | replaces a file inside a FAT32 image in place, without `mtools` |
| `gpt-convert.sh` | converts the Linux disk from MBR to GPT without touching filesystems, then re-installs GRUB |
| `gpt-wrap.py` | builds a GPT header for the APM-partitioned macOS installer ISO so OpenCore can see it |
| `oc-edit.py` | tiny helper to read/patch OpenCore `config.plist` fields |

## Conventions used everywhere

- **Never** reference `/dev/nvme0n1` or `/dev/nvme1n1` — the two NVMe drives swap names between boots.
  Use `/dev/disk/by-id/nvme-ZHITAI_TiPlus7100_1TB_ZTA71T0AB252817B43-partN`.
- Anything that writes to a disk is `--dry-run` first.
- Anything that touches the guest VM uses ACPI shutdown (`--stop`), never `kill`, because a killed
  GPU-passthrough guest leaves the device in a state that can wedge the host.
