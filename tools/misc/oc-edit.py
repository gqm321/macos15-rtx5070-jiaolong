#!/usr/bin/env python3
"""Edit OpenCore config.plist inside a qcow2 disk image, without root.

The ESP lives at offset 1 MiB; mtools reads/writes it from a raw image.
We convert qcow2 -> raw (temp), edit the plist, put it back, then convert
raw -> qcow2 (new file).  The source image is never modified.

Examples:
  # replace boot-args in a copy of the driver8 disk
  tools/oc-edit.py --src OpenCore-driver8.qcow2 --dst OpenCore-nvfb0.qcow2 \
      --boot-args "-v keepsyms=1 debug=0x100 serial=1 -topo"

  # block the NullMoth kexts (device still attached, driver never loads)
  tools/oc-edit.py --src OpenCore-driver8.qcow2 --dst OpenCore-nodrv.qcow2 \
      --block NVRM.kext --block NVAccel.kext --block NVRMFB.kext --block NVRMAGDC.kext

  # set the "Force cpuid_cores_per_package" patch value (also done for you
  # when --smp is passed: patch byte = cores)
  tools/oc-edit.py --src OpenCore-driver8.qcow2 --dst OpenCore-12c.qcow2 --smp 12
"""
import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

MTOOLS = os.environ.get("MTOOLS", "/home/guqiaomu/macos26-tools/mtools/usr/bin")
ESP_OFFSET = 1048576
PLIST = "::/EFI/OC/config.plist"

# Third-party kexts are disabled by bundle identifier with Strategy "Disable".
# OpenCore's "Exclude" strategy only works for Apple's own kexts.
KEXT_IDS = {
    "NVRM.kext": "com.nullmoth.NVRM",
    "NVAccel.kext": "com.nullmoth.NVAccel",
    "NVRMFB.kext": "com.nullmoth.NVRMFB",
    "NVRMAGDC.kext": "com.nullmoth.NVRMAGDC",
}


def run(cmd):
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit("failed: %s\n%s%s" % (" ".join(cmd), proc.stdout, proc.stderr))
    return proc.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--dst", required=True)
    ap.add_argument("--boot-args")
    ap.add_argument("--block", action="append", default=[],
                    help="kext bundle name to block (repeatable)")
    ap.add_argument("--unblock", action="append", default=[])
    ap.add_argument("--exclude", action="append", default=[],
                    help="Apple kext bundle identifier to Exclude (repeatable)")
    ap.add_argument("--smp", type=int, help="rewrite the cores-per-package patch byte")
    ap.add_argument("--scan-policy", type=lambda x: int(x, 0),
                    help="Misc>Security>ScanPolicy (0 = scan every filesystem/device)")
    ap.add_argument("--timeout", type=int, help="Misc>Boot>Timeout (picker seconds)")
    ap.add_argument("--resize-gpu-bars", type=int,
                    help="Booter>Quirks>ResizeGpuBars (MB; -1 disables)")
    ap.add_argument("--resize-apple-gpu-bars", type=int,
                    help="Booter>Quirks>ResizeAppleGpuBars (MB; -1 disables)")
    ap.add_argument("--show-picker", type=int, choices=(0, 1),
                    help="Misc>Boot>ShowPicker (0 = boot the default entry directly)")
    ap.add_argument("--patch-json", help="JSON list of {Comment,Find,Replace,MinKernel} to append to Kernel>Patch")
    ap.add_argument("--show", action="store_true", help="print the result and exit")
    args = ap.parse_args()

    tmpdir = tempfile.mkdtemp(prefix="oc-edit-", dir="/tmp/opencode")
    raw = os.path.join(tmpdir, "esp.raw")
    cfg = os.path.join(tmpdir, "config.plist")
    copy = os.path.join(tmpdir, "src.qcow2")
    try:
        # The source may be in use by a running VM, whose write lock blocks
        # qemu-img.  A plain copy has no such lock, so read the copy instead.
        shutil.copyfile(args.src, copy)
        run(["qemu-img", "convert", "-f", "qcow2", "-O", "raw", copy, raw])
        drive = "%s@@%d" % (raw, ESP_OFFSET)
        run([os.path.join(MTOOLS, "mcopy"), "-o", "-i", drive, PLIST, cfg])

        with open(cfg, "rb") as fh:
            plist = plistlib.load(fh)

        if args.boot_args is not None:
            nvram = plist["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]
            nvram["boot-args"] = args.boot_args

        for name in args.block:
            ident = KEXT_IDS.get(name, name)
            plist["Kernel"]["Block"] = [
                b for b in plist["Kernel"].get("Block", [])
                if b.get("Identifier") != ident
            ] + [{"Arch": "Any", "Comment": "blocked by oc-edit.py",
                  "Enabled": True, "Identifier": ident, "Strategy": "Disable"}]

        for name in args.unblock:
            ident = KEXT_IDS.get(name, name)
            plist["Kernel"]["Block"] = [
                b for b in plist["Kernel"].get("Block", [])
                if b.get("Identifier") != ident
            ]

        for ident in args.exclude:
            plist["Kernel"]["Block"] = [
                b for b in plist["Kernel"].get("Block", [])
                if b.get("Identifier") != ident
            ] + [{"Arch": "Any", "Comment": "excluded by oc-edit.py",
                  "Enabled": True, "Identifier": ident, "Strategy": "Exclude"}]

        if args.scan_policy is not None:
            plist["Misc"]["Security"]["ScanPolicy"] = args.scan_policy

        if args.timeout is not None:
            plist["Misc"]["Boot"]["Timeout"] = args.timeout

        if args.resize_gpu_bars is not None:
            plist["Booter"]["Quirks"]["ResizeGpuBars"] = args.resize_gpu_bars

        if args.resize_apple_gpu_bars is not None:
            plist["Booter"]["Quirks"]["ResizeAppleGpuBars"] = args.resize_apple_gpu_bars

        if args.show_picker is not None:
            plist["Misc"]["Boot"]["ShowPicker"] = bool(args.show_picker)

        if args.smp:
            hit = 0
            for patch in plist["Kernel"]["Patch"]:
                if "user-specified" in (patch.get("Comment") or ""):
                    repl = bytearray(patch["Replace"])
                    repl[1] = args.smp & 0xFF
                    patch["Replace"] = bytes(repl)
                    hit += 1
            print("cores-per-package patch entries updated: %d" % hit)

        if args.patch_json:
            import json
            for spec in json.load(open(args.patch_json)):
                find = bytes.fromhex(spec["Find"])
                repl = bytes.fromhex(spec["Replace"])
                if len(find) != len(repl):
                    sys.exit("Find/Replace length mismatch in %r" % spec.get("Comment"))
                plist["Kernel"]["Patch"].append({
                    "Arch": "x86_64",
                    "Base": "",
                    "Comment": spec.get("Comment", "oc-edit.py"),
                    "Count": spec.get("Count", 0),
                    "Enabled": True,
                    "Find": find,
                    "Identifier": spec.get("Identifier", "kernel"),
                    "Limit": 0,
                    "Mask": b"",
                    "MaxKernel": spec.get("MaxKernel", ""),
                    "MinKernel": spec.get("MinKernel", ""),
                    "Replace": repl,
                    "ReplaceMask": b"",
                    "Skip": 0,
                })
                print("added patch: %s" % spec.get("Comment"))

        with open(cfg, "wb") as fh:
            plistlib.dump(plist, fh, sort_keys=False)
        plistlib.load(open(cfg, "rb"))  # sanity check

        if args.show:
            print(plist["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"].get("boot-args"))
            for b in plist["Kernel"]["Block"]:
                print("block:", b.get("Identifier"), b.get("Strategy"), b.get("Enabled"))
            return

        run([os.path.join(MTOOLS, "mcopy"), "-o", "-i", drive, cfg, PLIST])
        tmp_dst = args.dst + ".tmp"
        run(["qemu-img", "convert", "-f", "raw", "-O", "qcow2", raw, tmp_dst])
        os.replace(tmp_dst, args.dst)
        print("wrote %s" % args.dst)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
