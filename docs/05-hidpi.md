# HiDPI "looks like" sizes on the internal 2560x1600 panel

Panel: NE160QDM-NZL (16", 2560x1600, up to 300 Hz), RTX 5070 Laptop, NullMoth NVIDIA driver 3.0.
Display IDs: vendor 2533 (0x9e5), product 3413 (0xd55).

## Symptom

Only 2560x1600 and 1280x800 looked sharp. Other sizes (for example 1600x1000) looked soft.

## Root cause

Two different kinds of modes are mixed in the Displays list:

- **1x scaled modes** (logical size = pixel size, for example 1600x1000 with 1600x1000 pixels). The GPU's head
  scaler upscales them to the panel's 2560x1600, so every pixel is interpolated. These are the soft ones.
- **HiDPI modes** (pixels = 2x logical size). macOS renders a desktop twice the logical size and the GPU scales it
  down to the panel. 1280x800 is exactly 2560x1600, so it is 1:1 and the sharpest. Other HiDPI sizes are a
  downscale, which is much cleaner than a 1x upscale but not 1:1.

Without an override, macOS lists only these HiDPI sizes for this panel: 1280x800, 1024x640, 800x500, 800x600.

Check which kind a mode is with `CGDisplayCopyDisplayMode`: `width`/`height` against `pixelWidth`/`pixelHeight`.
Pass `kCGDisplayShowDuplicateLowResolutionModes` to `CGDisplayCopyAllDisplayModes`, or HiDPI modes are not returned.

## Fix

1. Turn on **HiDPI** in the driver's settings (boot-arg `nvfbhidpi=1`). This raises the scaler/scanout ceiling
   (log: `nvfbhidpi: scaled desktops up to 5120x3200 on a 2560x1600 raster`). It does not add modes by itself.
2. Install a display override that lists the extra HiDPI desktops:
   [`../configs/display-override-hidpi.plist`](../configs/display-override-hidpi.plist) to
   `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-9e5/DisplayProductID-d55` (owner root:wheel).
   Each `scale-resolutions` entry is **12 bytes**: width, height, 1, big-endian (the 16-byte form carries flag
   `0x00200000`, which CoreGraphics hides; see upstream issue nullmoth/nvidia-macos-driver#341).
3. Reboot, then pick the HiDPI size in System Settings > Displays > Show all resolutions.

| Backing desktop | Looks like | Scale on a 1600-line panel |
|---|---|---|
| 2880x1800 | 1440x900 | 178% |
| 3200x2000 | 1600x1000 | 160% |
| 3360x2100 | 1680x1050 | 152% |
| 3456x2160 | 1728x1080 | 148% |
| 3840x2400 | 1920x1200 | 133% |

1728x1080 is the closest to a 150% Windows/Linux setting, and about the logical size of a 16" MacBook Pro's
default (1728x1117). It was confirmed on this machine: logical 1728x1080, pixels 3456x2160, 300 Hz.

## Traps

- `sudo nvram boot-args="... nvfbhidpi=1"` printed `Error creating CFTypeRef for value IONVRAM-SYNCNOW-PROPERTY`
  and the argument was gone after the reboot (the write stayed in memory). Setting it from the 1401 app's driver
  settings persisted. After the reboot, check `sysctl -n kern.bootargs | grep nvfbhidpi`.
- The override alone does nothing without `nvfbhidpi=1`: the larger desktops are refused as larger than the
  scanout allocation.
- Non-integer HiDPI sizes are a GPU downscale and stay slightly softer than 1280x800. The driver has no scaler
  filter or sharpness setting.
