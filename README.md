# macOS 15 on a MECHREVO JIAOLONG (Ryzen 9 7845HX + RTX 5070 Laptop)

A complete write-up of getting **macOS Sequoia 15.8.1** running on an AMD Ryzen 9 7845HX laptop
with an NVIDIA RTX 5070 Laptop GPU in **MUX (discrete-only) mode** — first inside QEMU/KVM with
GPU passthrough, then **migrated to a bare-metal partition** driven by a self-built OpenCore.

> **TL;DR** — bare metal is usable: desktop, Metal 3, brightness keys/slider, internal keyboard and
> Wi-Fi all work. Internal audio (Conexant SN6140) and internal Bluetooth (MT7922) are unsupported,
> "shut down" reboots (with a working workaround), and the I2C touchpad is not configured.

---

## Hardware

| Part | Model | Notes |
|---|---|---|
| CPU | AMD Ryzen 9 7845HX, 12C/24T (Zen 4, Raphael/Hawk Point) | kernel patch `cpuid_cores_per_package = 12` |
| dGPU | NVIDIA RTX 5070 Laptop (GB206M, 8 GB) | `01:00.0`, internal panel wired to it (MUX) |
| iGPU | AMD Raphael `1002:164e` | must be **disabled** in macOS (`disable-gpu`) |
| Panel | NE160QDM-NZL, 2560×1600 **300 Hz** | macOS runs 2048×1280 @ 300 Hz scaled mode |
| Wi-Fi | MediaTek MT7922 (`14C3:7922`) | works; its Bluetooth half is USB `0489:E0D8` and does **not** work |
| Ethernet | Realtek RTL8125 | no macOS driver available |
| Audio | **Conexant SN6140** (`14F1:1F87`, subsystem `1D05:3010`) | not in AppleALC's codec table |
| Input | internal keyboard is **PS/2 (i8042)**; touchpad is I2C HID (`093A:0255`) | keyboard needs VoodooPS2 |
| Storage | ZHITAI TiPlus7100 1 TB (Linux + macOS); YMTC PC41Q (Windows) | ⚠️ NVMe numbering **swaps between boots** — always use `/dev/disk/by-id/` |

Software: **macOS 15.8.1 (24H32)**, **NullMoth 1401 / NVIDIA driver 2.6.5**, OpenCore with a config
derived from the community EFI described in [`docs/04-reference-notes.md`](docs/04-reference-notes.md),
SMBIOS **MacPro7,1** (`UpdateSMBIOSMode = Custom`).

---

## Two routes

### A. VM route (worked, now retired)

QEMU/KVM with **vfio passthrough of the 5070**, plus a GRUB entry and a systemd unit so that the
machine "boots into macOS" and powering the guest off powers the host off — close enough to a real Mac.
See [`docs/01-vm-route.md`](docs/01-vm-route.md).

- Hard requirement: **BAR1 must be shrunk to 4 GiB** first; with 8 GiB the guest firmware hangs at
  `PCI configuration`.
- Traps: systemd ordering cycle, APM-partitioned installer ISO, host loses its display once vfio grabs the GPU.

### B. Bare-metal route (current)

Install macOS inside the VM → **transplant only the APFS container** onto a real partition → boot it
with a self-built OpenCore. See [`docs/02-baremetal-route.md`](docs/02-baremetal-route.md).

- Partitions: `p4` 512 MiB ESP (OpenCore) + `p5` 237.9 GiB APFS (macOS).
- Transplant: `qemu-img dd ... bs=4096 skip=51205 count=60241910`.
- Bootloader: `tools/baremetal/build-efi-ref.py` builds a 512 MiB FAT32 image, `dd` it to `p4`.

---

## Status

| Item | State | Notes |
|---|---|---|
| Desktop / WindowServer | ✅ | MacPro7,1, Metal 3 |
| GPU | ✅ | NVRM / NVRMFB / NVAccel / NVRMAGDC all loaded, 8 GiB BAR is fine |
| Brightness (keys + slider) | ✅ | needs `nvrmacpibl=1` boot-arg — see troubleshooting #6 |
| Internal keyboard | ✅ | VoodooPS2Controller + plugins |
| Wi-Fi | ✅ | YYavicWiFi 0.7.2; captive-portal login works |
| External mouse / USB | ✅ | |
| Touchpad | ❌ | `093A:0255` I2C HID; needs VoodooI2C + GPIO pinning, not attempted |
| Internal audio | ❌ | Conexant SN6140 is not in AppleALC; use a USB sound card |
| Internal Bluetooth | ❌ | no MT7922 BT transport in macOS; a USB BT dongle works (A2DP verified) |
| Battery | ❌ | the real EC is shadowed by a fake one; enabling it hangs boot |
| Shut down | 🟡 | macOS S5 resets instead of powering off; **workaround**: the "Shutdown" item in the OpenCore menu |
| Resolution / HiDPI | 🟡 | 1280×800 is the only crisp mode; the driver rejects custom HiDPI framebuffers |

---

## Repository layout

```
docs/01-vm-route.md         VM + autostart (GRUB entry + systemd), history and traps
docs/02-baremetal-route.md  bare-metal transplant: partitions, APFS copy, ESP build, first boot
docs/03-troubleshooting.md  ★ every symptom → root cause → fix, including dead ends
docs/04-reference-notes.md  where the reference EFI came from, upstream NullMoth issues, caveats
configs/                    sanitized OpenCore config, ESP build recipes, SSDTs
tools/baremetal/            ESP builder, installer, OpenCore log reader, macOS-side helpers
tools/vm/                   vfio / BAR1 / launcher / GRUB+systemd install / cleanup
tools/misc/                 QMP, in-place FAT32 patcher, GPT conversion
attic/                      retired GRUB entry and systemd unit, kept verbatim
```

---

## Quick start (bare metal)

```bash
# 0) deps: python3 + pyfatfs (builds the FAT32 image entirely in user space, no root needed)
python3 -m pip install --target .pylib pyfatfs

# 1) build the ESP image (brightness arg, Wi-Fi, PS/2 keyboard, Shutdown menu item)
python3 tools/baremetal/build-efi-ref.py --cores 12 --wifi --acpibl --shutdown-tool \
        --out esp-baremetal.img

# 2) flash it to p4 (⚠️ by-id only — nvme0n1/nvme1n1 swap on this machine)
sudo dd if=esp-baremetal.img \
     of=/dev/disk/by-id/nvme-ZHITAI_TiPlus7100_1TB_ZTA71T0AB252817B43-part4 bs=4M conv=fsync
```

`build-efi-ref.py` expects `reference-efi/` (the OpenCore + kext tree) and `kexts/` (YYavicWiFi,
VoodooPS2, VoodooHDA) next to the repo root. Those third-party binaries are **not** included here;
see [`docs/04-reference-notes.md`](docs/04-reference-notes.md) for how to obtain them.

---

## Three lessons that cost us the most time

1. **Do not extrapolate a working VM config to bare metal.** The VM config carried
   `Booter>Quirks>DisableVariableWrite = True`, which silently blocks NVRAM writes — so NullMoth's
   "start once without the driver" flag never persisted and *every* "driver disabled" test was
   actually running with the driver. Wasted days.
2. **A known-good EFI from the same platform class is worth more than any amount of tweaking.**
   What finally worked was a community EFI from an *R9 8945HX + RTX 5060 laptop*: it already had
   `disable-gpu` for the iGPU, `Kernel>Block` of `IONDRVSupport`, five SSDTs, 27 kernel patches and
   MacPro7,1. We changed one value (core count) and reached the desktop.
3. **Know which layer you are resizing BARs in.** `Booter>ResizeAppleGpuBars` runs *after* boot.efi
   and, per OpenCore's documentation, only supports `0`; `UEFI>ResizeGpuBars` runs *before* boot.efi
   and takes `n` = 2^n MB. Writing `12` into the former means **4 KiB**, not 4 GiB — it kills the boot.
   We made exactly that mistake.

---

## License

Scripts and text in this repository (`tools/`, `docs/`, `configs/`) are MIT.
Third-party binaries (OpenCore, kexts, the NullMoth driver) are **not** redistributed here and carry
their own licenses — several forbid commercial use. Check each project's LICENSE before shipping anything.
