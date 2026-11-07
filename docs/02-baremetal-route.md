# Route B — bare-metal macOS on the internal NVMe

The idea: **install macOS where you can see it (in the VM), then move only the APFS container to a real
partition** and boot it with a self-built OpenCore. The installer itself never runs on the bare metal —
which matters here, because during installation the internal panel is driven by the dGPU and there is no
usable macOS framebuffer yet, so you would be flying blind.

Everything below assumes the Linux disk is referenced by its by-id path, because **the two NVMe drives
swap `nvme0n1`/`nvme1n1` between boots on this machine**:

```bash
DISK=/dev/disk/by-id/nvme-ZHITAI_TiPlus7100_1TB_ZTA71T0AB252817B43
```

---

## 0. Prerequisites

1. A working macOS installation inside QEMU (see [`01-vm-route.md`](01-vm-route.md)) with:
   - FileVault **off**,
   - NullMoth 1401 installed and verified **with GPU passthrough** (Metal 3, panel lit),
   - a user account with a password you know.
2. Free space at the end of the Linux NVMe (here: a 256 GiB gap, later used as 512 MiB + 237.9 GiB).
3. `qemu-img`, `python3`, and `pyfatfs` (`python3 -m pip install --target .pylib pyfatfs`).

---

## 1. Turn the Linux disk from MBR into GPT

`tools/misc/gpt-convert.sh` rewrites the partition table **without touching any filesystem**: it reads the
four MBR entries, writes an equivalent GPT (same start/size/type), adds the protective MBR and the backup
header at the end of the disk, and then re-installs GRUB plus the firmware fallback loader.

```bash
sudo bash tools/misc/gpt-convert.sh --dry-run      # print the mapping
sudo bash tools/misc/gpt-convert.sh
```

Afterwards the layout is:

```
p1  459.4G  NTFS    games (still mounted by Windows)
p2    1.0G  ESP     /boot/efi  (Ubuntu)
p3  255G    ext4    /
p4  512M    ESP     OpenCore           ← created in step 2
p5  237.9G  APFS    macOS             ← created in step 2
```

Two independent GRUB fallbacks are installed on purpose (`grub-install` re-run + a copy of
`\EFI\BOOT\BOOTX64.EFI` on the Ubuntu ESP), because losing the firmware boot entry on a disk you just
re-partitioned is unrecoverable without a live USB.

### Create p4 and p5

```bash
sudo sgdisk -n 4:0:+512M  -t 4:EF00 -c 4:"OC"    "$DISK"
sudo sgdisk -n 5:0:0      -t 5:AF00 -c 5:"macOS" "$DISK"
```

`p5` should be at least as large as the APFS container (229.8 GiB here); 237.9 GiB leaves ~8 GiB of slack.

---

## 2. Work out the APFS transplant parameters

Read the GPT **inside** `macreal.qcow2` and convert the APFS partition's start/size into 4 KiB blocks:

```bash
qemu-img dd -f qcow2 -O raw if=macreal.qcow2 of=/tmp/hdr.raw bs=1M count=2
python3 - <<'PY'
import struct
f = open('/tmp/hdr.raw','rb'); f.seek(512); h = f.read(92)
pl = struct.unpack_from('<Q', h, 72)[0]; n = struct.unpack_from('<I', h, 80)[0]; sz = struct.unpack_from('<I', h, 84)[0]
f.seek(pl * 512)
for i in range(n):
    e = f.read(sz)
    if e[:16] == b'\0' * 16: continue
    s = struct.unpack_from('<Q', e, 32)[0]; l = struct.unpack_from('<Q', e, 40)[0]
    cnt = l - s + 1
    print(f"part {i+1}: start={s} count={cnt}  -> 4K skip={s*512//4096} count={cnt*512//4096}")
PY
```

On our image that prints `skip=51205 count=60241910` (start 209,735,680 bytes, size 246,750,863,360 bytes).

---

## 3. Build the OpenCore ESP image (in user space)

`tools/baremetal/build-efi-ref.py` builds a 512 MiB FAT32 image from a **known-good reference EFI tree**
(`reference-efi/`) plus the extra kexts in `kexts/`, and patches a few machine-specific values:

```bash
python3 tools/baremetal/build-efi-ref.py --cores 12 --wifi --wifi-noverify \
        --voodoo-i2c --restrictevents --acpibl --shutdown-tool --out esp-baremetal.img
```

What it changes relative to the reference config:

| Flag | Effect |
|---|---|
| `--cores 12` | rewrites the four `algrey | Force cpuid_cores_per_package` patches from `16` to `12` (8945HX → 7845HX) |
| `--wifi` | adds `YYavicWiFi.kext` (MT7922) and `yyavic-cc=CN` to boot-args |
| `--wifi-noverify` | also adds `-yyavicnoverify`; required on 15.8.2 because 0.7.2 only accepts 24H32 |
| `--voodoo-i2c` | adds VoodooI2C 2.9.1 + VoodooI2CHID, disables the PS/2 `VoodooInput`, appends `-vi2c-force-polling` |
| `--restrictevents` | enables `RestrictEvents.kext` with `revpatch=sbvmm,cpuname` and `revcpuname=AMD Ryzen 9 7845HX` (update visibility; CPU name is cosmetic) |
| `--acpibl` | adds `nvrmacpibl=1` — **this is what makes brightness work** |
| `--shutdown-tool` | adds `ResetSystem.efi` as a menu item named "关机 Shutdown" (`Arguments = shutdown`) |
| `--voodoo-hda` | replaces AppleALC with VoodooHDA (did **not** produce audio on this machine — see troubleshooting) |
| `--no-ec-ssdt` | disables the reference `SSDT-EC` (hangs boot on this machine — do not use) |

The PS/2 keyboard kexts (`VoodooPS2Controller` + plugins) are always added, in the correct order
(controller first, then its PlugIns). With `--voodoo-i2c`, the PS/2 copy of `VoodooInput.kext` is
disabled so only the VoodooI2C copy provides `VoodooInput`.

> Why not build the ESP with `mtools`/`mount`? `mtools` isn't installed, and mounting a FAT image needs
> root. The script writes the FAT32 filesystem directly with `pyfatfs`, so the whole build is a normal
> user command and the only root operation is the final `dd`.

---

## 4. Write p4 + p5

`tools/baremetal/install-baremetal.sh` does all three steps with size/sanity checks (it refuses to run if
`p5` is mounted, if `p4` isn't exactly 512 MiB, or if `p5` is smaller than the container):

```bash
bash tools/baremetal/install-baremetal.sh --dry-run
sudo bash tools/baremetal/install-baremetal.sh
```

1. `dd` the ESP image to `p4`
2. `qemu-img dd -f qcow2 -O raw if=macreal.qcow2 of=$p5 bs=4096 skip=51205 count=60241910`
3. register a firmware boot entry `OpenCore` pointing at `\EFI\BOOT\BOOTx64.EFI` on partition 4
   (**not** made the default — Ubuntu stays first)

It finishes by printing the APFS magic at offset 32 of `p5`, which must be `NXSB`.

---

## 5. First boot

Reboot → firmware boot menu → **OpenCore** → `mac HD`.

Expect, on a good boot: a few seconds of verbose output, the NVIDIA driver taking over the panel, then
the desktop. Our first successful boot came from adopting the reference config wholesale (see
[`04-reference-notes.md`](04-reference-notes.md)); every earlier attempt with a config derived from the VM
stalled at `pci (build …)` or reset instantly.

If it stops, the useful signals are:

| Symptom | Meaning |
|---|---|
| verbose text stops at `pci (build …)` | kernel is running, display was taken over (or PCI enumeration stalled) |
| 🚫 prohibited sign, no text | boot.efi could not validate the system volume — usually a dirty APFS, re-transplant |
| instant reset with no output at all | boot.efi handed off (check the OpenCore log for `EXITBS`) and the kernel died immediately — very often a BAR/Booter quirk problem |

### Reading the OpenCore log from Linux

The ESP is FAT32 and readable from Ubuntu **without root**:

```bash
udisksctl mount -b "$DISK-part4" -o ro
ls /run/media/$USER/EFI/            # opencore-YYYY-MM-DD-HHMMSS.txt
```

`tools/baremetal/oc-esp.sh` wraps the root-only variants: `debug-on` raises the log level
(`Target=0x47`, `DisplayLevel=0x80000042` — note that the file log honours `DisplayLevel`, so with only
WARN/ERROR enabled the log stays almost empty) and `log` prints and backs up the files.

`tools/baremetal/mac-collect.sh` runs **on macOS** and dumps displays/audio/power/USB/ioreg/loaded kexts
plus `pmset -g log` and the recent shutdown log into `handoff-out/` on the same ESP, so the next Ubuntu
session can read everything without asking the user to copy anything.

---

## 6. Recovery

- **Keep a known-good ESP image.** Re-flashing `p4` is a 2-second `dd` and fixes every config experiment.
- **Re-transplanting** `p5` takes ~3 minutes and fixes APFS damage (e.g. a lost
  `usr/standalone/OS.dmg.root_hash`, which shows up as the prohibited sign after a hard power-off).
- macOS itself can flash `p4`: `tools/baremetal/mac-flash.sh` (run on macOS) finds the ESP that contains
  `EFI/OC/config.plist` and writes a new image to it — so config experiments do not require booting Linux.
- **Do not force power-off** unless the machine has been idle for several minutes. Repeated hard resets
  are what dirtied the APFS and cost us a re-transplant. Prefer the OpenCore "Shutdown" item once it is
  installed.
