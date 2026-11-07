#!/usr/bin/env python3
"""用「同代 AMD + 50 系笔记本已经跑通」的参考 EFI 作为基座，构建裸机 ESP。

    python3 tools/baremetal/build-efi-ref.py [--cores 12] [--wifi] [--out esp-baremetal.img]

参考配置来自: R9 8945HX + RTX 5060 笔记本（macOS 15 已跑通、显卡可用）的 EFI，
已解包到 reference-efi/。

相对参考配置只做「必须按本机硬件改」的调整：
  - cpuid_cores_per_package: 16（8945HX 是 16 核）-> 12（7845HX 是 12 核）
  - 可选 --wifi：加 YYavicWiFi.kext（MT7922），默认不加
  - 可选 --wifi-noverify：再加 -yyavicnoverify（15.8.2 需要；0.7.2 只认 24H32）
  - 可选 --voodoo-i2c：加 VoodooI2C/VoodooI2CHID 和 -vi2c-force-polling（I2C 触控板）
其余（SMBIOS MacPro7,1 / ACPI SSDT / 27 条内核补丁 / IONDRVFramebuffer Block /
iGPU disable-gpu / NullMoth boot-args / quirk 全集）一律照抄，因为它们是验证过的。
"""
import argparse
import os
import plistlib
import subprocess
import sys
import warnings

warnings.filterwarnings("ignore")
W = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(W, ".pylib"))
from pyfatfs.PyFatFS import PyFatFS  # noqa: E402

SRC = os.path.join(W, "reference-efi")
SIZE_MB = 512

# 本机键盘是 PS/2（i8042 "AT Translated Set 2 keyboard"），参考配置里没有 PS/2 驱动，
# 所以进了桌面也打不了字。VoodooPS2Controller 的插件必须排在 Controller 之后。
PS2_ROOT = os.path.join(W, "kexts", "voodoo-ps2", "VoodooPS2Controller.kext")
HDA_ROOT = os.path.join(W, "kexts", "voodoo-hda", "VoodooHDA.kext")
I2C_ROOT = os.path.join(W, "kexts", "voodoo-i2c")
SHUTDOWN_TOOL = os.path.join(W, "tools", "efi", "ResetSystem.efi")
PS2_ENTRIES = [
    ("VoodooPS2Controller.kext", "Contents/MacOS/VoodooPS2Controller", "PS/2 控制器"),
    ("VoodooPS2Controller.kext/Contents/PlugIns/VoodooInput.kext", "Contents/MacOS/VoodooInput", "VoodooInput"),
    ("VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Keyboard.kext", "Contents/MacOS/VoodooPS2Keyboard", "PS/2 键盘"),
    ("VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Mouse.kext", "Contents/MacOS/VoodooPS2Mouse", "PS/2 鼠标"),
    ("VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Trackpad.kext", "Contents/MacOS/VoodooPS2Trackpad", "PS/2 触控板"),
]
# I2C 触控板（093A:0255）：插件必须排在 VoodooI2C 主 kext 之前，VoodooI2CHID 最后。
I2C_ENTRIES = [
    ("VoodooI2C.kext/Contents/PlugIns/VoodooInput.kext", "Contents/MacOS/VoodooInput", "VoodooInput"),
    ("VoodooI2C.kext/Contents/PlugIns/VoodooGPIO.kext", "Contents/MacOS/VoodooGPIO", "GPIO"),
    ("VoodooI2C.kext/Contents/PlugIns/VoodooI2CServices.kext", "Contents/MacOS/VoodooI2CServices", "Services"),
    ("VoodooI2C.kext", "Contents/MacOS/VoodooI2C", "controller"),
    ("VoodooI2CHID.kext", "Contents/MacOS/VoodooI2CHID", "HID"),
]


# Resources 只给 OpenCanopy 图形选择菜单用；参考配置是 PickerMode=Builtin，
# 用不到它（而且那堆 2.5MB 的 .icns 会让 pyfatfs 写坏 FAT 链）。
SKIP_DIRS = {"Resources"}
SKIP_PREFIX = ("config.plist.", ".content")
# config.plist 单独写：pyfatfs 覆盖写入已存在文件时会把 FAT 链写坏
SKIP_FILES = {"config.plist"}


def copy_tree(fs, src_dir, dst_dir, top=False):
    for name in sorted(os.listdir(src_dir)):
        if name.startswith("._") or name.startswith(SKIP_PREFIX) or name in SKIP_FILES:
            continue
        if name in SKIP_DIRS:
            continue
        s = os.path.join(src_dir, name)
        d = dst_dir.rstrip("/") + "/" + name
        if os.path.isdir(s):
            fs.makedirs(d)
            copy_tree(fs, s, d)
        else:
            with open(s, "rb") as f:
                fs.writebytes(d, f.read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(W, "esp-baremetal.img"))
    ap.add_argument("--cores", type=int, default=12,
                    help="物理核心数，写进 algrey 的 cpuid_cores_per_package 补丁")
    ap.add_argument("--wifi", action="store_true", help="加 YYavicWiFi.kext（MT7922）")
    ap.add_argument("--wifi-noverify", action="store_true",
                    help="给 YYavicWiFi 加 -yyavicnoverify（15.8.2 需要；0.7.2 只认 24H32）")
    ap.add_argument("--voodoo-i2c", action="store_true",
                    help="加 VoodooI2C + VoodooI2CHID（I2C 触控板）并加 -vi2c-force-polling")
    ap.add_argument("--restrictevents", action="store_true",
                    help="启用 RestrictEvents.kext 并设置 revpatch=sbvmm,cpuname / revcpuname=7845HX（让系统设置里能看到新版本）")
    ap.add_argument("--no-ps2", action="store_true", help="不加 VoodooPS2Controller（排查用）")
    ap.add_argument("--no-ec-ssdt", action="store_true",
                    help="停用参考配置的 SSDT-EC（它会 _STA=0 关掉真 EC0，导致电池/关机异常）和 SSDT-RTCAWAC")
    ap.add_argument("--shutdown-tool", action="store_true",
                    help="加一个 OpenCore 菜单项「关机」：ResetSystem.efi shutdown，直接调固件关机")
    ap.add_argument("--acpibl", action="store_true",
                    help="加 nvrmacpibl=1：让 NVRM 读 ACPI 的 NBCI _DSM/_DOD，笔记本内置屏亮度靠它（上游默认关闭，少数机器会挂）")
    ap.add_argument("--voodoo-hda", action="store_true",
                    help="用 VoodooHDA 顶替 AppleALC（本机 codec 是 Conexant SN6140，AppleALC 不支持）")
    a = ap.parse_args()
    if a.wifi_noverify:
        a.wifi = True

    if not os.path.isdir(os.path.join(SRC, "OC")):
        sys.exit(f"缺参考 EFI 树: {SRC}")

    img = a.out
    if os.path.exists(img):
        os.remove(img)
    subprocess.run(["truncate", "-s", f"{SIZE_MB}M", img], check=True)
    subprocess.run(["mkfs.vfat", "-F", "32", "-n", "EFI", img],
                   check=True, stdout=subprocess.DEVNULL)

    fs = PyFatFS(img)
    fs.makedirs("/EFI")
    copy_tree(fs, SRC, "/EFI", top=True)

    if not a.no_ps2:
        if not os.path.isdir(PS2_ROOT):
            sys.exit(f"缺 PS/2 kext: {PS2_ROOT}")
        copy_tree(fs, PS2_ROOT, "/EFI/OC/Kexts/VoodooPS2Controller.kext")

    if a.voodoo_hda:
        if not os.path.isdir(HDA_ROOT):
            sys.exit(f"缺 VoodooHDA: {HDA_ROOT}")
        copy_tree(fs, HDA_ROOT, "/EFI/OC/Kexts/VoodooHDA.kext")

    if a.wifi:
        copy_tree(fs, os.path.join(W, "kexts", "yyavic", "YYavicWiFi.kext"),
                  "/EFI/OC/Kexts/YYavicWiFi.kext")

    if a.voodoo_i2c:
        for name in ("VoodooI2C.kext", "VoodooI2CHID.kext"):
            src = os.path.join(I2C_ROOT, name)
            if not os.path.isdir(src):
                sys.exit(f"缺 I2C kext: {src}")
            copy_tree(fs, src, f"/EFI/OC/Kexts/{name}")

    pl = plistlib.load(open(os.path.join(SRC, "OC/config.plist"), "rb"))

    # --- 核心数：只换 algrey 那 4 条补丁里的立即数（BA imm32 / B8 imm32）---
    changed = 0
    for p in pl["Kernel"]["Patch"]:
        if "cores_per_package" in p.get("Comment", ""):
            rep = bytearray(p["Replace"])
            assert rep[0] in (0xBA, 0xB8), rep.hex()
            rep[1] = a.cores
            p["Replace"] = bytes(rep)
            changed += 1
    assert changed == 4, f"cores 补丁数量异常: {changed}"

    # --- 可选：RestrictEvents（系统设置里显示新版本；revcpuname 显示 7845HX）---
    if a.restrictevents:
        found = False
        for k in pl["Kernel"]["Add"]:
            if k["BundlePath"] == "RestrictEvents.kext":
                k["Enabled"] = True
                found = True
        if not found:
            pl["Kernel"]["Add"].append({
                "Arch": "Any", "BundlePath": "RestrictEvents.kext",
                "Comment": "RestrictEvents — OTA update visibility", "Enabled": True,
                "ExecutablePath": "Contents/MacOS/RestrictEvents", "MaxKernel": "",
                "MinKernel": "", "PlistPath": "Contents/Info.plist",
            })
        rev = pl["NVRAM"]["Add"].setdefault("4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102", {})
        rev["revcpu"] = 1
        rev["revcpuname"] = "AMD Ryzen 9 7845HX"
        rev["revpatch"] = "sbvmm,cpuname"

    # --- PS/2 键盘（本机内置键盘是 i8042 PS/2）---
    if not a.no_ps2:
        for bundle, exe, comment in PS2_ENTRIES:
            if any(k["BundlePath"] == bundle for k in pl["Kernel"]["Add"]):
                continue
            pl["Kernel"]["Add"].append({
                "Arch": "Any", "BundlePath": bundle,
                "Comment": f"VoodooPS2 — {comment}", "Enabled": True,
                "ExecutablePath": exe, "MaxKernel": "", "MinKernel": "",
                "PlistPath": "Contents/Info.plist",
            })

    # --- 可选：VoodooHDA 顶替 AppleALC ---
    if a.voodoo_hda:
        for k in pl["Kernel"]["Add"]:
            if k["BundlePath"] == "AppleALC.kext":
                k["Enabled"] = False      # 两者会抢同一个 HDA 控制器，必须只留一个
        if not any(k["BundlePath"] == "VoodooHDA.kext" for k in pl["Kernel"]["Add"]):
            pl["Kernel"]["Add"].append({
                "Arch": "Any", "BundlePath": "VoodooHDA.kext",
                "Comment": "VoodooHDA — 通用 HDA（Conexant SN6140）", "Enabled": True,
                "ExecutablePath": "Contents/MacOS/VoodooHDA", "MaxKernel": "",
                "MinKernel": "", "PlistPath": "Contents/Info.plist",
            })

    # --- 可选：Wi-Fi ---
    if a.wifi:
        if not any(k["BundlePath"] == "YYavicWiFi.kext" for k in pl["Kernel"]["Add"]):
            pl["Kernel"]["Add"].append({
                "Arch": "Any", "BundlePath": "YYavicWiFi.kext",
                "Comment": "YYavicWiFi (MT7922 原生 Wi-Fi)", "Enabled": True,
                "ExecutablePath": "Contents/MacOS/YYavicWiFi", "MaxKernel": "",
                "MinKernel": "", "PlistPath": "Contents/Info.plist",
            })
        nv = pl["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]
        if "yyavic-cc=CN" not in nv["boot-args"]:
            nv["boot-args"] += " yyavic-cc=CN"

    # --- 可选：I2C 触控板（VoodooI2C）---
    if a.voodoo_i2c:
        for bundle, exe, comment in I2C_ENTRIES:
            existing = next((k for k in pl["Kernel"]["Add"]
                             if k["BundlePath"] == bundle), None)
            if existing is not None:
                existing["Enabled"] = True
                continue
            pl["Kernel"]["Add"].append({
                "Arch": "Any", "BundlePath": bundle,
                "Comment": f"VoodooI2C — {comment}", "Enabled": True,
                "ExecutablePath": exe, "MaxKernel": "", "MinKernel": "",
                "PlistPath": "Contents/Info.plist",
            })
        # 只保留一个 VoodooInput：VoodooI2C 的插件已经提供，PS/2 那份必须关掉
        for k in pl["Kernel"]["Add"]:
            if k["BundlePath"] == "VoodooPS2Controller.kext/Contents/PlugIns/VoodooInput.kext":
                k["Enabled"] = False

    if a.no_ec_ssdt:
        for x in pl["ACPI"]["Add"]:
            if x["Path"] in ("SSDT-EC.aml", "SSDT-RTCAWAC.aml"):
                x["Enabled"] = False

    nv = pl["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]
    if a.acpibl and "nvrmacpibl=1" not in nv["boot-args"]:
        nv["boot-args"] += " nvrmacpibl=1"
    if a.voodoo_i2c and "-vi2c-force-polling" not in nv["boot-args"]:
        nv["boot-args"] += " -vi2c-force-polling"
    if a.wifi_noverify and "-yyavicnoverify" not in nv["boot-args"]:
        nv["boot-args"] += " -yyavicnoverify"

    if a.shutdown_tool:
        if not any(t.get("Path") == "ResetSystem.efi" for t in pl["Misc"]["Tools"]):
            pl["Misc"]["Tools"].append({
                "Arguments": "shutdown",
                "Auxiliary": False,
                "Comment": "Power off via ResetSystem(EfiResetShutdown)",
                "Enabled": True,
                "Flavour": "Auto",
                "FullNvramAccess": False,
                "Name": "关机 Shutdown",
                "Path": "ResetSystem.efi",
                "RealPath": False,
                "TextMode": False,
            })

    fs.writebytes("/EFI/OC/config.plist", plistlib.dumps(pl, fmt=plistlib.FMT_XML))
    fs.close()

    nv = pl["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]
    print(f"✅ {img}  ({os.path.getsize(img)/2**20:.0f} MiB)")
    print(f"   SMBIOS: {pl['PlatformInfo']['Generic']['SystemProductName']}"
          f"  ProcessorType={pl['PlatformInfo']['Generic'].get('ProcessorType')}")
    print(f"   cores: {a.cores}   内核补丁: {len(pl['Kernel']['Patch'])} 条"
          f"   Block: {[b['Identifier'] for b in pl['Kernel'].get('Block', [])]}")
    print(f"   ACPI: {[x['Path'] for x in pl['ACPI']['Add']]}")
    print(f"   kexts: {[k['BundlePath'] for k in pl['Kernel']['Add'] if k['Enabled']]}")
    print(f"   boot-args: {nv['boot-args']}")
    print("\n写到 p4（需要 root）：")
    print(f"   sudo dd if={img} of=/dev/disk/by-id/nvme-ZHITAI_TiPlus7100_1TB_ZTA71T0AB252817B43-part4 bs=4M conv=fsync")


if __name__ == "__main__":
    main()
