# ESP build recipes

All images are built by `tools/baremetal/build-efi-ref.py`, which always starts from the *same*
reference tree and applies flags. Keeping one base and adding flags (instead of editing plists by hand)
is what made the debugging loop survivable: each image differs from the previous one in exactly one
dimension.

```bash
python3 tools/baremetal/build-efi-ref.py [flags] --out <image>
```

## Flag reference

| Flag | Changes |
|---|---|
| `--cores N` | rewrites the four `algrey | Force cpuid_cores_per_package` patches to `N` (12 for 7845HX; the reference used 16) |
| `--wifi` | adds `YYavicWiFi.kext` and appends `yyavic-cc=CN` to boot-args |
| `--wifi-noverify` | also appends `-yyavicnoverify` (required on 15.8.2: 0.7.2 only accepts 24H32) |
| `--voodoo-i2c` | adds VoodooI2C 2.9.1 + VoodooI2CHID, disables the PS/2 `VoodooInput`, appends `-vi2c-force-polling` |
| `--restrictevents` | enables `RestrictEvents.kext` with `revpatch=sbvmm,cpuname` / `revcpuname=AMD Ryzen 9 7845HX` (update visibility) |
| `--acpibl` | appends `nvrmacpibl=1` — required for brightness |
| `--shutdown-tool` | adds `ResetSystem.efi` as menu entry "关机 Shutdown" with `Arguments = shutdown` |
| `--voodoo-hda` | disables `AppleALC.kext`, adds `VoodooHDA.kext` (no audio on this machine) |
| `--sn6140-audio` | swaps in the community SN6140 AppleALC (`kexts/applealc-sn6140/`), appends `alcid=15 alcdelay=1000`, writes `layout-id` as data 15 (mutually exclusive with `--voodoo-hda`) |
| `--no-ec-ssdt` | disables `SSDT-EC.aml` and `SSDT-RTCAWAC.aml` (hangs boot here — reproduce only) |
| `--no-ps2` | omits `VoodooPS2Controller` (debug only: without it the internal keyboard is dead) |
| `--out PATH` | output image (default `esp-baremetal.img`) |

PS/2 kexts are added by default; the image is always 512 MiB FAT32, label `EFI`.

## The images used during development

| Image | Command | Purpose |
|---|---|---|
| `esp-baremetal-15.8.2.img` | `--cores 12 --wifi --wifi-noverify --voodoo-i2c --restrictevents --acpibl --shutdown-tool` | **current daily driver (15.8.2)** |
| `esp-baremetal.img` | `--cores 12 --wifi --acpibl --shutdown-tool` | 15.8.1 daily driver |
| `esp-baremetal-bright.img` | `--cores 12 --wifi --acpibl` | brightness fix, before the shutdown tool existed |
| `esp-baremetal-noacpibl.img` | `--cores 12 --wifi` | ruled `nvrmacpibl=1` out as the shutdown cause |
| `esp-baremetal-ec.img` | `--cores 12 --wifi --acpibl --no-ec-ssdt` | the EC experiment that hangs boot (kept for reproduction) |
| `esp-baremetal-audio.img` | `--cores 12 --wifi --acpibl --voodoo-hda` | VoodooHDA attempt (no audio) |
| `esp-baremetal-sn6140.img` | `--cores 12 --wifi --wifi-noverify --voodoo-i2c --restrictevents --acpibl --shutdown-tool --sn6140-audio` | **audio works (2026-11-07)** — live ESP was patched in place; this image is the reproducible form |
| `esp-baremetal-wifi.img` | `--cores 12 --wifi` (before PS/2 support existed) | first successful desktop + Wi-Fi |

## Effective configuration of the daily driver

**boot-args**

```
-v debug=0x100 keepsyms=1 nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth
amfi_get_out_of_my_way=0x1 amfi=0x80 ipc_control_port_options=0 gfxrst=4
yyavic-cc=CN nvrmacpibl=1 -yyavicnoverify -vi2c-force-polling
```

`-yyavicnoverify` is the YYavicWiFi 0.7.2 tester switch that bypasses its `24H32` build gate; 15.8.2
is `24H232`. `-vi2c-force-polling` makes the I2C touchpad use polling instead of a GPIO interrupt.

The live ESP was additionally patched on 2026-11-07 with the community SN6140 AppleALC (speakers,
wired-headphone output, mic input and headphone hot-plug verified working); its boot-args end in
`alcid=15 alcdelay=1000` and `layout-id` is data 15. Add `--sn6140-audio` to the recipe above to get
that from a clean build (after `tools/baremetal/fetch-sn6140-applealc.sh`).

On 15.8.2, macOS → Shut Down powers off normally; `--shutdown-tool` is kept as a fallback.

`debug=0x100` keeps a panic on screen instead of rebooting — useful, but it also means a panic looks like
a frozen machine.

**Booter quirks** (non-default): `AllowRelocationBlock`, `AvoidRuntimeDefrag`, `DevirtualiseMmio`,
`DisableVariableWrite`, `EnableSafeModeSlide`, `FixupAppleEfiImages`, `ProvideCustomSlide`,
`RebuildAppleMemoryMap`, `SetupVirtualMap`, `SyncRuntimePermissions`. No BAR quirk.

**UEFI quirks**: `EnableVectorAcceleration`, `ReleaseUsbOwnership`, `RequestBootVarRouting`, `UnblockFsConnect`.

**Kernel quirks**: `CustomSMBIOSGuid`, `DisableLinkeditJettison`, `DisableRtcChecksum`, `LapicKernelPanic`,
`PanicNoKextDump`, `PowerTimeoutKernelPanic`, `ProvideCurrentCpuInfo`; `Emulate>DummyPowerManagement = True`.

**ACPI**: `SSDT-EC.aml`, `SSDT-PLUG-ALT.aml`, `SSDT-RTCAWAC.aml`, `SSDT-USB-Reset.aml`, `SSDT-USBX.aml`
(the `.aml` files are in this directory; they came with the reference EFI).

**Kernel>Block**: `com.apple.iokit.IONDRVSupport`, strategy `Exclude`.

**Kexts (enabled, in load order)**

```
Lilu.kext
VirtualSMC.kext            (AMFIPass is also enabled in the reference config)
AppleALC.kext
AppleMCEReporterDisabler.kext
NVMeFix.kext
RealtekRTL8111.kext
RestrictEvents.kext
USBToolBox.kext
UTBDefault.kext
ForgedInvariant.kext
VoodooPS2Controller.kext + PlugIns/{VoodooPS2Keyboard,VoodooPS2Mouse,VoodooPS2Trackpad}
YYavicWiFi.kext
VoodooI2C.kext + PlugIns/{VoodooInput,VoodooGPIO,VoodooI2CServices}
VoodooI2CHID.kext
```

The PS/2 `VoodooInput.kext` entry is disabled when VoodooI2C is present, so only one `VoodooInput`
provider loads. `RestrictEvents.kext` is now enabled (`revpatch=sbvmm,cpuname`,
`revcpuname=AMD Ryzen 9 7845HX`) so the 15.8.2 update appears in System Settings; `revcpuname` is
cosmetic (the reference EFI came from an 8945HX machine). `WhateverGreen.kext` remains disabled.

**Drivers**: `HfsPlus.efi`, `OpenRuntime.efi`, `ResetNvramEntry.efi`.
**Picker**: built-in (`PickerMode = Builtin`), `Timeout = 5`, `ShowPicker = True`, `ScanPolicy = 0`.

## Adding a kext or SSDT later

The build script copies `reference-efi/` verbatim *except* `config.plist` (written last, because pyfatfs
corrupts a FAT chain when a file is overwritten in place) and `Resources/` (only needed for the OpenCanopy
graphical picker, which this config does not use).

So to add something permanently, put the file in `reference-efi/OC/{Kexts,ACPI,Tools}/` and add the
corresponding `Kernel>Add` / `ACPI>Add` / `Misc>Tools` entry in `reference-efi/OC/config.plist` — or add a
flag to the build script when the change is conditional. Never edit the plist inside a built image.

## Flashing

```bash
DISK=/dev/disk/by-id/nvme-ZHITAI_TiPlus7100_1TB_ZTA71T0AB252817B43
sudo dd if=esp-baremetal.img of="${DISK}-part4" bs=4M conv=fsync
```

From macOS, `tools/baremetal/mac-flash.sh` finds the ESP that contains `EFI/OC/config.plist` (so it cannot
hit the Ubuntu ESP) and writes the image for you.
