# Troubleshooting log — symptom → root cause → fix

Everything below actually happened on this machine. Each entry lists the symptom we saw, what the cause
turned out to be, and what fixed it (or why it cannot be fixed). The **dead ends** section at the end is
deliberately blunt: those were tested and do not work here.

Machine: MECHREVO JIAOLONG, Ryzen 9 7845HX, RTX 5070 Laptop (MUX), macOS 15.8.1 (24H32),
NullMoth 1401 / driver 2.6.5, OpenCore with the reference config (MacPro7,1).

---

## 1. Early boot: the kernel stops at `pci (build …)`, or resets instantly

**Symptom.** With a hand-made config derived from the VM, verbose output stopped at

```
ACPI Error: 1 table load failures, 23 successful
pci (build 20:23:55 Aug 23 2026), flags 0xc3080
```

and never continued. Other variants reset with no output at all.

**Cause (two separate ones).**

1. *No output at all* but the log ends at `AAPL: #[EB|LOG:EXITBS:START]` — boot.efi handed off fine, the
   kernel died within milliseconds. In our case this was self-inflicted: we set
   `Booter>Quirks>ResizeAppleGpuBars = 12`, believing it meant "4 GiB". It does not.
2. *Stall at `pci (build …)`* — the config was missing what the reference EFI has: the iGPU not disabled,
   `IONDRVSupport` not blocked, an older 36-patch set, MacBookPro16,2 SMBIOS, no ACPI SSDTs.

**Fix.** Adopt the reference config (`docs/04-reference-notes.md`) and change only the core count. Also
remove the BAR quirks entirely — the reference config has none, and 8 GiB BAR1 is fine for macOS.

### BAR quirk semantics (worth memorising)

| Key | Section | When it runs | Value encoding |
|---|---|---|---|
| `ResizeAppleGpuBars` | `Booter>Quirks` | **after** boot.efi | PCI Resizable BAR spec; OpenCore docs state the only supported value is `0` (smallest the device supports); `-1` disables |
| `ResizeGpuBars` | `UEFI>Quirks` | **before** boot.efi | `n` = 2^n MB (`8` = 256 MB, `12` = 4 GiB) |

`ResizeAppleGpuBars = 12` therefore means **4 KiB**, not 4 GiB — it destroys the boot ("prohibited sign"
or an instant reset with no text). `ResizeGpuBars` placed in `Booter>Quirks` produces
`OCS: No schema for ResizeGpuBars at NN index, context <Quirks>!` in the log and is ignored.

---

## 2. 🚫 prohibited sign, `OS.dmg.root_hash` missing

**Symptom.**

```
AAPL: #[EB|OFS|OPEN] Err(0xE) <"usr\standalone\OS.dmg.root_hash">
AAPL: #[EB|RH.LRH|P!] Err(0xE) <- EB.LD.LF
```

**Cause.** The Signed System Volume's root hash could not be read. In our case it appeared after several
hard power-offs (holding the power button while the kernel was mid-handoff). APFS rolled back an
uncommitted transaction and the file's directory entry was gone.

**Fix.** Re-transplant `p5` from `macreal.qcow2` (3 minutes). Then stop force-powering: wait a full 5
minutes before deciding a boot is dead, and use the OpenCore "Shutdown" item when you need to power off.

---

## 3. Keyboard types nothing at the login window

**Symptom.** Mouse works, keyboard does not — no typing possible, cannot log in.

**Cause.** The internal keyboard is **PS/2**:

```
N: Name="AT Translated Set 2 keyboard"      Bus=0011  (i8042)
serio0: i8042 KBD port
```

The reference EFI contains no PS/2 driver, because the machine it came from has a USB keyboard. macOS has
no built-in PS/2 keyboard driver.

**Fix.** Add `VoodooPS2Controller.kext` **and its plugins**, in this order:

```
VoodooPS2Controller.kext
VoodooPS2Controller.kext/Contents/PlugIns/VoodooInput.kext
VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Keyboard.kext
VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Mouse.kext
VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Trackpad.kext
```

`build-efi-ref.py` adds them by default. The touchpad itself is I2C HID (`093A:0255`) and still needs
VoodooI2C + GPIO pinning — out of scope here.

---

## 4. Mouse cursor works but nothing else on the touchpad

**Cause.** `UNIW0001:00 093A:0255` is an **I2C HID** device. macOS needs `VoodooI2C` + `VoodooI2CHID`,
plus an `SSDT` that pins the GPIO interrupt (the exact pin differs per board and has to be read out of the
DSDT). A USB mouse works out of the box.

**Status.** Not attempted. If you want it: start from `VoodooI2C`'s pinning guide and expect several
reboots.

---

## 5. Internal audio: no devices at all

**Symptom.** `系统设置 → 声音` is empty; `system_profiler SPAudioDataType` lists nothing. In ioreg the
HDA controller exists, `AppleHDACodecGeneric` binds, but `AppleHDADriver` is `!registered, !matched`.

**Cause.** The codec is a **Conexant SN6140**:

```
/proc/asound/card2/codec#0     Codec: Conexant SN6140
Vendor Id: 0x14f11f87          Subsystem Id: 0x1d053010
```

AppleALC 1.9.9's codec table (checked by downloading the source tree) contains these Conexant IDs:

```
0x14f11f72 (CX8050)  0x14f11f86 (CX8070 / CX11880)  0x14f11fd6 (CX8150)
0x14f12008 (CX8200)  0x14f120d0 (CX8400)   0x14f150xx (CX20561…CX20757)
```

**`0x14f11f87` is not there** — it differs from CX8070 by one in the last nibble. No `layout-id` can fix
this: AppleALC matches `vendor<<16 | codec` against its embedded pin-config table and the codec is simply
absent. (Also note the reference config's `layout-id` was written as an *integer*; OpenCore requires
`data`, so it never applied at all.)

**Attempted.** VoodooHDA 3.6.8 (CloverHackyColor), with its personality retargeted:

```xml
IOPCIPrimaryMatch = 0x15e31022     <!-- AMD 1022:15e3 HD Audio -->
IOMatchCategory   = "VoodooHDA"    <!-- coexist with the system AppleHDAController -->
```

(the stock kext only matches `IONameMatch = HDAS`, and our device is `HDEF`/`IOName pci1022,15e3`, so
unmodified it never attaches). Result: still no audio devices.

**Recommendation.** A **USB sound card** (any CDC/UAC dongle) is the pragmatic answer — the same way a USB
Bluetooth dongle solves the next item.

---

## 6. Internal Bluetooth does not work

**Symptom.** No Bluetooth hardware in System Settings; a USB BT dongle works fine (A2DP audio verified).

**Cause.** The MT7922's Bluetooth half is a USB device `0489:E0D8`. The YYavic kext contains 27
`IOProviderMergeProperties` personalities that **rewrite other MT7922 Bluetooth IDs into `0489:E0D8`** —
i.e. `0489:E0D8` is the ID it *presents*, not one it drives. Our device already has that ID, and there is
no MT7922 Bluetooth transport in macOS.

**Status.** Not fixable without a new driver. Use a USB BT dongle.

---

## 7. Wi-Fi (works)

YYavicWiFi 0.7.2 drives the MT7922 (`14C3:7922`) natively. Requirements observed:

- macOS 15.8.1 (24H32) — the kext checks the build,
- `yyavic-cc=CN` in boot-args,
- `csr-active-config = 0x0A43` plus the AMFI bypass arguments (`amfi=0x80 amfi_get_out_of_my_way=0x1`).

Captive-portal Wi-Fi (campus network) works. Joining from the shell:

```bash
networksetup -listallhardwareports
networksetup -setairportnetwork en0 "SSID" "password"
```

Harmless noise: the kext prints a heartbeat to the console (`YYavicMtkWlan: hb t=… poll_fires=0 delta=0`)
and, on some builds, `YYavicWiFi: native Wi-Fi layer disabled, unsupported macOS: OS build not published yet`.
That message alone does not mean Wi-Fi is broken.

---

## 8. Brightness: no slider, no keys

**Symptom.** No brightness slider in Control Center, Fn keys do nothing. In ioreg the class counter shows
`NVRMBacklightHandler = 0` — the handler was never published.

**Cause.** NullMoth's NVRM already implements laptop backlight, but only through the firmware's **NBCI
`_DSM`** (`GETOBJBYTYPE 0x10`, `GETBACKLIGHT 0x14`) and `_DOD`. Without them
`NV0073_CTRL_CMD_SPECIFIC_GET_BACKLIGHT_BRIGHTNESS` returns `NV_ERR_NOT_SUPPORTED`, NVKMS never calls
`nvkms_register_backlight()`, and NVRMFB logs
`internal panel, but NVKMS registered no backlight (0x…) -- no brightness control`.

This path is **opt-in** in the driver:

```c
// Opt-in (boot-arg nvrmacpibl=1)
on = (PE_parse_boot_argn("nvrmacpibl", &v, sizeof(v)) && v) ? 1 : 0;
```

**Fix.** Add **`nvrmacpibl=1`** to boot-args. Result on this machine: slider and keys work, and the log
shows `NVRM-xnu: backlight registered` / `panel backlight at N% -- brightness keys and slider through
AppleBacklightDisplay`.

**Notes.** It is off by default upstream because the ACPI calls hung a few machines in an older release.
We first suspected it of breaking shutdown — it does not (see #9). `build-efi-ref.py --acpibl` adds it.

---

## 9. "Shut down" reboots the machine (unresolved, workaround available)

**Symptom.** macOS → Shut Down → the machine powers back up, like a restart.

**Evidence gathered.**

- `pmset -g log` records `SMC shutdown cause: 5: Software initiated shutdown` and `powerd process is
  started` in the **same second**, with `Sleep/Wakes since boot: 0` — no sleep/wake cycle happened.
- **Ubuntu** shuts down normally. **OpenCore's own `ResetSystem(EfiResetShutdown)`** powers off normally
  (`ResetSystem.efi` with `Arguments = shutdown`). So firmware S5, the EC and the rails are fine.
- **Recovery** (which does not load `/Library/Extensions`, so no NullMoth) *also* reboots → the NVIDIA
  driver is not the cause.
- `nvrmacpibl=1` removed → still reboots → the brightness ACPI calls are not the cause.
- Charger unplugged, all USB devices removed, lid closed, BIOS wake options all disabled → still reboots →
  no wake source involved.

**What is left.** macOS's own S5 sequence. The firmware's `_PTS` is:

```asl
Method (_PTS, 1) { If (Arg0) { \_SB.PCI0.SBRG.EC0._EPTS(Arg0); \_SB.TPM._TPTS(Arg0);
                               SPTS(Arg0); \_SB.PCI0.GPTS(Arg0); \_SB.PCI0.NPTS(Arg0) } }
```

`_S5` is the standard `Package (0x04) {0x05, 0, 0, 0}`, and `SPTS(Arg0)` is:

```asl
Store (Arg0, P80H)                                  // debug port
If (Arg0 == 3) { Store (1, BLNK) }
If (Arg0 != 4 && Arg0 != 5) { Store (0, BLNK) }
If (Arg0 == 3) { Store (0, RSTU) }
Store (1, CLPS); Store (1, SLPS); Store (PEWS, PEWS)
If (Arg0 == 3) { Store (1, SLPS) }
If (Arg0 == 4) { Store (1, SLPS); Store (1, RSTU) } // RSTU — looks like "reset unit"
If (Arg0 == 5) { Store (1, PWDE) }                  // PWDE lives in GSMM (SystemMemory), write goes through SMI
```

Two plausible remaining causes:

1. the `PWDE` write into the `GSMM` MMIO window entering an SMI handler that resets the platform, or
2. macOS never calling `_PTS` (then `PWDE` is never set and the EC treats the SLP_S5# assertion as a reset).

**Workaround (in use).** `tools/baremetal/build-efi-ref.py --shutdown-tool` adds a menu entry
**"关机 Shutdown"** (`ResetSystem.efi`, `Arguments = shutdown`). When macOS "shuts down", it reboots into
OpenCore; pick that entry and the machine powers off. Two seconds of extra work, zero risk.

**Next experiment (not yet done).** Rename `_PTS`→`ZPTS` with an `ACPI>Patch` and supply an *empty* `_PTS`
from an SSDT. If the machine then powers off, the reset lives inside `SPTS`; if it still reboots, macOS is
not reaching `_PTS` at all. A CMOS "mailbox" byte written from `_PTS` would tell us which argument macOS
passes.

---

## 10. Battery indicator missing (and why you cannot just enable the real EC)

**Cause.** The reference `SSDT-EC` does two things on Darwin:

```asl
Scope (\_SB.PCI0.SBRG.EC0) { Method (_STA) { If (_OSI("Darwin")) { Return (0) } ... } }   // hide the real EC
Scope (\_SB.PCI0.SBRG)     { Device (EC) { Name (_HID, "ACID0001") ... } }                 // fake Apple EC
```

Our DSDT's `EC0` really is a `PNP0C09` device (`_HID` encoded as `0x090CD041`) and **`BAT0` is a child of
`EC0`** — so hiding it also hides the battery.

**Attempted.** Disabling `SSDT-EC` (and `SSDT-RTCAWAC`, which is inert here: this firmware has no `AWAC`
device and its `TAAD` target does not exist) makes macOS hang during boot: AppleACPIEC never finishes
coming up on the real EC. Verbose output keeps scrolling (Wi-Fi heartbeat) but WindowServer never starts.

**Conclusion.** Keep `SSDT-EC`. Battery status is not reachable on this machine without a different EC
strategy. `build-efi-ref.py --no-ec-ssdt` exists only to reproduce the failure.

---

## 11. Display resolution / HiDPI

- The panel is 2560×1600 **300 Hz**, but macOS reports `2048 x 1280 @ 300 Hz` — a scaled mode computed by
  the driver. 300 Hz is genuine: this panel supports it in MUX mode.
- **1280×800** (exact 2×) is the only fully crisp mode; everything in between is non-HiDPI scaling and
  looks blurry.
- A 150 %-style mode requires macOS to render a **larger framebuffer** (e.g. 3414×2134) and downscale it,
  which needs the display override *and* a driver willing to accept a framebuffer larger than the panel
  timing. Tried: **BetterDisplay 5.2.1** (custom resolution + HiDPI) and **one-key-hidpi** (writes
  `/Library/Displays/Contents/Resources/Overrides`, which is *not* on the sealed system volume, so it still
  works on Sequoia). Neither produced a usable mode — the driver rejects the custom framebuffer.
- Practical fallback: stay at 1280×800, or enlarge text via Accessibility → Display → Text Size.

---

## 12. Two NVMe drives swap device names between boots

`nvme0n1` and `nvme1n1` are not stable on this machine (`/dev/nvme0n1p3` was `/` on one boot and
`/dev/nvme1n1p3` on the next). **Always use by-id paths**:

```
/dev/disk/by-id/nvme-ZHITAI_TiPlus7100_1TB_ZTA71T0AB252817B43-part4
```

Every script in `tools/` follows this rule.

---

## 13. `DisableVariableWrite = True` silently broke our tests

The VM-derived config had `Booter>Quirks>DisableVariableWrite = True`. Effect on bare metal:

- NullMoth's boot-picker tools (`1401: Start once without NVIDIA driver`) work by writing an NVRAM flag
  (`nullmoth-remove`). The flag never persisted (`the firmware did not keep the change`), so **every
  "driver disabled" test still ran with the driver**.
- Kernel panic logs could not be stored, so ApplePanic never produced a `panic-*.txt`.

Diagnosis: from Linux, `ls /sys/firmware/efi/efivars | grep -i nullmoth` — it was empty.
The reference config also sets it `True`; keep that in mind when reasoning about NVRAM on this machine.

---

## 14. OpenCore log is almost empty

If `Misc>Debug>Target` has the file bit (`0x40`) but `DisplayLevel` is only `ERROR|WARN`
(`0x80000002`), the file log is filtered the same way and contains almost nothing (typically just the
`OCS: No schema …` warning). Set `DisplayLevel = 0x80000042` (`ERROR|WARN|INFO`) to get a real log.
`oc-esp.sh debug-on` does this.

---

## Dead ends (tested, do not repeat)

| Attempt | Result |
|---|---|
| `ResizeAppleGpuBars = 12` (thinking "4 GiB") | prohibited sign / instant reset — the value is a PCI spec code, `12` = 4 KiB |
| `ResizeAppleGpuBars = 0` | still instantly reset; the quirk is not needed on this machine at all |
| `UEFI>ResizeGpuBars = 8` (256 MB) | instant reset; the firmware's own 8 GiB BAR works fine with macOS |
| `npci=0x2000`, cores = 8, `-v debug=0x100` combinations | no improvement; the reference config uses none of them |
| `AppleDebug = True` + `debug=0x100` | hides the kernel's own verbose output; log stops at `EXITBS` and looks like a hang |
| Removing `SSDT-EC` to expose the real EC | boot hangs (AppleACPIEC on this EC) |
| AppleALC with various `layout-id`s | codec `0x14f11f87` is not in AppleALC at all |
| VoodooHDA 3.6.8 with retargeted match | loads, still no audio devices |
| Internal MT7922 Bluetooth | no macOS transport exists |
| HiDPI custom framebuffers (BetterDisplay / one-key-hidpi) | driver rejects the mode |
| Using `nvme0n1` / `nvme1n1` in scripts | breaks on the next reboot |
