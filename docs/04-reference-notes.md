# Reference material, provenance and caveats

## The EFI that made it work

After weeks of (failed) hand-tuning of a config derived from our QEMU setup, the breakthrough came from
the NullMoth community Discord: a user with an **HP Omen 16 (R9 8945HX + RTX 5060 Laptop)** had booted
macOS 15 with working graphics and shared their whole `EFI.zip`.

We used it as the base and changed **one value**: the core count in the `algrey | Force
cpuid_cores_per_package` patches (`16` → `12`, because 8945HX is 16-core and 7845HX is 12-core).
The machine booted to the desktop on the first try.

The binary tree is **not** redistributed here (it contains another person's SMBIOS serials and
third-party kexts). What is included is
[`../configs/reference-efi-config.sanitized.plist`](../configs/reference-efi-config.sanitized.plist) —
the exact same config with `SystemSerialNumber`, `MLB`, `SystemUUID` and `ROM` replaced by placeholders.
Regenerate your own with [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) or OCAT for **MacPro7,1**.

### What was different from our VM-derived config

| Area | Reference EFI | Our VM config | Why it matters |
|---|---|---|---|
| SMBIOS | **MacPro7,1**, `UpdateSMBIOSMode = Custom`, `CustomSMBIOSGuid = True`, `ProcessorType = 3841` | MacBookPro16,2 | the AMD-friendly choice; avoids laptop-specific power/display assumptions |
| iGPU | `DeviceProperties` → `PciRoot(0x0)/Pci(0x8,0x1)/Pci(0x0,0x0)` `disable-gpu = True` | absent | Raphael iGPU (`1002:164e`) is visible on the PCI bus and confuses enumeration |
| Boot framebuffer | `Kernel>Block`: `com.apple.iokit.IONDRVSupport` (Strategy `Exclude`) | empty | comment in the config: *"boot framebuffer IONDRVFramebuffer steals index 0 from NVRMFB"* |
| ACPI | `SSDT-EC`, `SSDT-PLUG-ALT`, `SSDT-RTCAWAC`, `SSDT-USB-Reset`, `SSDT-USBX` | `Add` empty | CPU power management, EC facade, USB power |
| Kernel patches | 27 patches, incl. `CaseySJ | IOPCIIsHotplugPort | Fix PCI bus enumeration on AM5`, `Fix PAT 15.0+`, `probeBusGated 10-bit tags`, `thread_* non-monotonic time` | 36 older patches | the newer set matches macOS 15.x |
| Booter quirks | `DevirtualiseMmio`, `AllowRelocationBlock`, `FixupAppleEfiImages`, `RebuildAppleMemoryMap`, `SyncRuntimePermissions`, `SetupVirtualMap`, `ProvideCustomSlide`, `AvoidRuntimeDefrag` | subset, no `DevirtualiseMmio` | the memory-map quirks are what AMD boards need |
| UEFI quirks | `EnableVectorAcceleration`, `ReleaseUsbOwnership`, `RequestBootVarRouting`, `UnblockFsConnect` | subset | |
| BAR quirks | **none** | we had tried `ResizeAppleGpuBars`/`ResizeGpuBars` | proving 8 GiB BAR1 is fine for macOS |
| boot-args | `-v debug=0x100 keepsyms=1 nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80 ipc_control_port_options=0 gfxrst=4` | VM-flavoured set + `npci=0x2000` | `nvfb*`/`gfxrst=4` are NullMoth-specific |
| Kexts | Lilu, AMFIPass, AppleALC, AppleMCEReporterDisabler, NVMeFix, RealtekRTL8111, USBToolBox, UTBDefault, VirtualSMC, ForgedInvariant (RestrictEvents and WhateverGreen present but disabled) | Lilu, VirtualSMC, AMFIPass, USBPorts, VMHide | `ForgedInvariant` and `USBToolBox` matter on AMD |

`--cores`, `--wifi`, `--wifi-noverify`, `--voodoo-i2c`, `--acpibl`, `--shutdown-tool` in
`build-efi-ref.py` are the deltas we apply on top of it today. `--wifi-noverify` adds
`-yyavicnoverify` (YYavicWiFi 0.7.2 only accepts 24H32; 15.8.2 is 24H232) and `--voodoo-i2c` adds
VoodooI2C 2.9.1 + VoodooI2CHID + `-vi2c-force-polling` for the I2C touchpad. `RestrictEvents` is
enabled with `revpatch=sbvmm,cpuname` to make the 15.8.2 update appear in System Settings; the
`cpuname` part is cosmetic (the reference EFI came from an 8945HX machine, corrected to 7845HX).
Everything else is left exactly as the reference had it — that is deliberate.

---

## NullMoth / 1401 driver references

Repository: **https://github.com/nullmoth/nvidia-macos-driver** (NVIDIA driver for macOS Sequoia).
The driver package we run is **2.6.5**; the 1401 installer app distributes it as `nullmoth-nvidia-<ver>.tar.gz`
(`pkgroot/Library/Extensions/{NVRM,NVRMFB,NVRMAGDC,NVAccel}.kext`).

Files worth reading if you debug this driver:

| Path in the repo | Why |
|---|---|
| `kexts/NVRMFB/fb/nvrm-fb.cpp` | `NVRMBacklightHandler`; `publishBacklight()` explains the "internal panel, but NVKMS registered no backlight" path |
| `kexts/NVRM/os-xnu2.cpp` | NBCI `_DSM` (`GETOBJBYTYPE 0x10`, `GETBACKLIGHT 0x14`) and `_DOD`; the `nvrmacpibl` boot-arg lives here |
| `kexts/NVRM/nv-xnu.h`, `os-nvkms-xnu.cpp` | `nvkms_xnu_backlight()` → `nvkms_register_backlight()` |
| `docs/NVRMFB-BACKLIGHT-POWER.md` | how the saved brightness target (`nullmoth-backlight` in `/options`) persists |
| `docs/SLEEP-WAKE.md` | power-state expectations |
| `kexts/NVRM/patches/610-backlight-register-log.patch` | the log lines that tell you *why* no backlight was registered |

Issue threads that answered our questions:

- **#211** — laptop brightness. A maintainer's comment is the one that solved it:
  *"try adding `nvrmacpibl=1` to boot-args […] on our RTX 5070 laptop that one boot-arg fixed the slider
  and keys"*, with the warning that it is off by default because those ACPI calls hung a few machines.
- **#488** — *"AM5: board stops POSTing after macOS shutdown with the driver active"* (desktop, different
  failure mode from ours, no workaround).
- **#100** — *"reproducible shutdown/restart hang on macOS 15.8.1"*: freeze rather than reset; a comment
  notes that shutdowns with `-nvoff` were fine.

Driver boot-args we enumerated from the source/binary (useful when you suspect the driver):
`nvcursor`, `nvfbheads`, `nvfbtrace`, `nvmaxbpc`, `nvrmacpibl`, `nvrmdiag`, `nvrmholdcap`,
`nvrmmapowner`, `nvrmsettle`, `nvselector`, `nvregdwords`. There is **no** shutdown-related switch.

---

## Where to get the binaries (not in this repository)

| Component | Source |
|---|---|
| OpenCore + `ResetSystem.efi` + other EFI tools | https://github.com/acidanthera/OpenCorePkg/releases (`OpenCore-*-RELEASE.zip`, `X64/EFI/OC/...`) |
| Lilu / VirtualSMC / AppleALC / NVMeFix / WhateverGreen / RestrictEvents | https://github.com/acidanthera (each release zip) |
| VoodooPS2Controller (PS/2 keyboard + touchpad) | https://github.com/acidanthera/VoodooPS2/releases |
| VoodooI2C 2.9.1 + VoodooI2CHID (I2C touchpad) | https://github.com/VoodooI2C/VoodooI2C/releases |
| VoodooHDA | https://github.com/CloverHackyColor/VoodooHDA/releases (`Release368`) |
| AMFIPass | https://github.com/dhinakg/AMFIPass |
| USBToolBox + UTBDefault | https://github.com/USBToolBox/kext, https://github.com/USBToolBox/tool |
| ForgedInvariant | https://github.com/ChefKissInc/ForgedInvariant |
| RealtekRTL8111 | https://github.com/Mieze/RTL8111_driver_for_OS_X |
| AppleMCEReporterDisabler | https://github.com/acidanthera/bugtracker (attached in the AMD guides) |
| YYavicWiFi (MT7922) | https://github.com/yusufcanyavic/YYavicWiFi (`0.7.2`; needs `-yyavicnoverify` on 15.8.2) |
| NullMoth 1401 / NVIDIA driver | https://github.com/nullmoth/nvidia-macos-driver (releases) |

Expected tree layout for `build-efi-ref.py`:

```
reference-efi/                 OpenCore tree (BOOT/ + OC/{OpenCore.efi,config.plist,Drivers,Kexts,Tools,ACPI})
kexts/yyavic/YYavicWiFi.kext
kexts/voodoo-ps2/VoodooPS2Controller.kext
kexts/voodoo-i2c/VoodooI2C.kext
kexts/voodoo-i2c/VoodooI2CHID.kext
kexts/voodoo-hda/VoodooHDA.kext          (optional, --voodoo-hda)
tools/efi/ResetSystem.efi                (optional, --shutdown-tool)
```

---

## Etiquette and licensing

- **Do not publish someone else's EFI, SMBIOS serials or MLB.** The sanitized config here is the only
  thing we redistribute, and the placeholders must be replaced with values generated on your own machine.
- **NullMoth's driver is PolyForm Noncommercial 1.0.0** — free for personal/non-commercial use, not for
  redistribution in commercial products. It is not included here.
- The kexts above are GPL/BSD/Apache mixes with their own redistribution rules; link to their releases
  instead of vendoring binaries (which is why this repo contains only scripts and text).
- Repartitioning a disk that holds your only Linux install is risky. Keep a live USB and a second copy of
  anything irreplaceable before running `gpt-convert.sh`.
