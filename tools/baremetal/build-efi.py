#!/usr/bin/env python3
"""在用户态构建裸机用的 OpenCore ESP 镜像（不需要 root）。

    python3 tools/build-efi.py [--out esp-baremetal.img]

输入：
  baremetal-efi/        从 VM 的 OpenCore 盘导出的 EFI 树
  kexts/yyavic/...      YYavicWiFi.kext（MT7922 原生 Wi-Fi）
输出：
  一个 512 MiB 的 FAT32 镜像，内容 /EFI/BOOT/BOOTx64.efi + /EFI/OC/...

相对 VM 配置做的改动：
  - Kernel>Add：去掉 USBPorts.kext（QEMU 专用），加 YYavicWiFi.kext
  - boot-args：去掉 VM 专用项，加 yyavic-cc=CN 和 -v
  - 13.3+ 的 cores_per_package 补丁：8 → 12（真机 12 核 24 线程）
  - 选择菜单：ShowPicker=True，Timeout=0（一直等，不自动跳）
"""
import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import warnings

warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".pylib"))
from pyfatfs.PyFatFS import PyFatFS  # noqa: E402

W = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(W, "baremetal-efi")
SIZE_MB = 512

# 只拷这些驱动和 kext（其余留在源目录里不带走）
DRIVERS = ["OpenRuntime.efi", "OpenCanopy.efi", "HfsPlus.efi"]
KEXTS = ["Lilu.kext", "VirtualSMC.kext", "AMFIPass.kext", "YYavicWiFi.kext"]
TOOLS = ["NullMothSafe.efi"]

BOOT_ARGS = ("keepsyms=1 debug=0x8 -v amfi_get_out_of_my_way=0x1 amfi=0x80 npci=0x2000")


def copy_tree(fs, src_dir, dst_dir):
    for name in sorted(os.listdir(src_dir)):
        if name.startswith("._"):
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
    ap.add_argument("--cores", type=int, default=8, help="cpuid_cores_per_package 补丁值")
    ap.add_argument("--no-wifi", action="store_true", help="不装 YYavicWiFi（排查用）")
    ap.add_argument("--bars", type=int, default=-1,
                    help="Booter ResizeAppleGpuBars：-1=关闭（默认）；0=硬件最小。这个 quirk 在 boot.efi 之后才动手，容易把帧缓冲搞死")
    ap.add_argument("--gpu-bars", type=int, default=8,
                    help="UEFI ResizeGpuBars：n 表示 2^n MB（8=256MB, 12=4GB, -1=不动）。在 boot.efi 之前生效")
    a = ap.parse_args()
    global KEXTS
    if a.no_wifi:
        KEXTS = [k for k in KEXTS if k != "YYavicWiFi.kext"]

    img = a.out
    if os.path.exists(img):
        os.remove(img)
    subprocess.run(["truncate", "-s", f"{SIZE_MB}M", img], check=True)
    subprocess.run(["mkfs.vfat", "-F", "32", "-n", "EFI", img],
                   check=True, stdout=subprocess.DEVNULL)

    fs = PyFatFS(img)

    # ---- BOOT ----
    fs.makedirs("/EFI/BOOT")
    shutil.copyfile(os.path.join(SRC, "BOOT/BOOTx64.efi"), "/tmp/oc-boot.efi")
    fs.writebytes("/EFI/BOOT/BOOTx64.efi", open("/tmp/oc-boot.efi", "rb").read())

    # ---- OC 骨架 ----
    fs.makedirs("/EFI/OC")
    fs.writebytes("/EFI/OC/OpenCore.efi",
                  open(os.path.join(SRC, "OC/OpenCore.efi"), "rb").read())
    fs.makedirs("/EFI/OC/Drivers")
    for d in DRIVERS:
        p = os.path.join(SRC, "OC/Drivers", d)
        if os.path.exists(p):
            fs.writebytes("/EFI/OC/Drivers/" + d, open(p, "rb").read())
    fs.makedirs("/EFI/OC/Kexts")
    for k in KEXTS:
        p = os.path.join(SRC, "OC/Kexts", k)
        if not os.path.exists(p):
            p = os.path.join(W, "kexts", "yyavic", k)
        if not os.path.exists(p):
            sys.exit(f"缺 kext: {k}")
        copy_tree(fs, p, "/EFI/OC/Kexts/" + k)
    fs.makedirs("/EFI/OC/Tools")
    for t in TOOLS:
        p = os.path.join(SRC, "OC/Tools", t)
        if os.path.exists(p):
            fs.writebytes("/EFI/OC/Tools/" + t, open(p, "rb").read())

    # ---- config.plist ----
    pl = plistlib.load(open(os.path.join(SRC, "OC/config.plist"), "rb"))

    # Kernel>Add：去掉 USBPorts，加 YYavicWiFi
    keep = {"Lilu.kext", "VirtualSMC.kext", "AMFIPass.kext"}
    pl["Kernel"]["Add"] = [k for k in pl["Kernel"]["Add"]
                           if k.get("BundlePath") in keep]
    if "YYavicWiFi.kext" in KEXTS:
        pl["Kernel"]["Add"].append({
            "Arch": "Any", "BundlePath": "YYavicWiFi.kext",
            "Comment": "YYavicWiFi (MT7922 原生 Wi-Fi)", "Enabled": True,
            "ExecutablePath": "Contents/MacOS/YYavicWiFi", "MaxKernel": "",
            "MinKernel": "", "PlistPath": "Contents/Info.plist",
        })

    # 13.3+ 的 cores_per_package 补丁：8 -> 12
    for p in pl["Kernel"]["Patch"]:
        if "cores_per_package" in p.get("Comment", "") and "13.3+" in p["Comment"]:
            p["Replace"] = bytes([0xBA, 0x00, 0x00, 0x00, 0x00])
            p["Replace"] = bytes([0xBA, a.cores, 0x00, 0x00, 0x00])

    nv = pl["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]
    nv["boot-args"] = BOOT_ARGS

    pl["Misc"]["Boot"]["ShowPicker"] = True
    pl["Misc"]["Boot"]["Timeout"] = 0
    pl["Misc"]["Boot"]["HideAuxiliary"] = False
    pl["Misc"]["Security"]["ScanPolicy"] = 0
    # 显卡 BAR 的两条路，务必分清：
    #   UEFI>Quirks>ResizeGpuBars  —— n 表示 2^n MB（8=256MB, 12=4GB）。在 boot.efi 之前生效，首选。
    #   Booter>Quirks>ResizeAppleGpuBars —— 只在 macOS 引导条目里动手（boot.efi 之后），
    #       文档说 macOS 下「唯一支持的值就是硬件最小 BAR，即 0」，其它值会翻车。
    # 真机 BIOS 开了 Re-Size BAR，显存 BAR 是 8 GiB（lspci: Region 1 size=8G），
    # macOS 只认常规的 256 MB，所以这里在 UEFI 层缩下去。
    pl["Booter"]["Quirks"]["ResizeAppleGpuBars"] = a.bars
    pl["Booter"]["Quirks"].pop("ResizeGpuBars", None)      # 这个键属于 UEFI 段，放 Booter 会被 OC 报 no schema
    pl["UEFI"]["Quirks"]["ResizeGpuBars"] = a.gpu_bars

    # 这条是从 VM 配置继承来的，裸机上会害死人：它禁止 macOS/工具写 NVRAM，
    # 于是 NullMoth 的 "Start once without NVIDIA driver" 标志写不进去
    # （工具的报错就是 "the firmware did not keep the change"），
    # 我们之前所有"已禁用驱动"的测试其实都是带驱动跑的。
    pl["Booter"]["Quirks"]["DisableVariableWrite"] = False

    d = pl["Misc"]["Debug"]
    d["AppleDebug"] = True       # 记录 boot.efi 日志（能看到交接到哪一步）
    d["ApplePanic"] = True       # 内核 panic 存成 ESP 上的 panic-*.txt，下次启动时写出
    d["DisableWatchDog"] = True
    d["Target"] = 0x47           # 0x01 日志 + 0x02 屏幕 + 0x04 data hub + 0x40 文件
    # DisplayLevel 同时管文件日志的过滤级别：只给 WARN/ERROR 的话日志里只有告警，
    # 所以这里必须带上 0x40 (DEBUG_INFO)，否则等于没开日志。
    d["DisplayLevel"] = 0x80000042

    # 只保留存在的 Tools 条目
    pl["Misc"]["Tools"] = [t for t in pl["Misc"].get("Tools", [])
                           if os.path.exists(os.path.join(SRC, "OC/Tools", t.get("Path", "")))]

    fs.writebytes("/EFI/OC/config.plist", plistlib.dumps(pl, fmt=plistlib.FMT_XML))
    fs.close()

    print(f"✅ {img}  ({os.path.getsize(img)/2**20:.0f} MiB)")
    print(f"   boot-args: {BOOT_ARGS}")
    print(f"   kexts: {', '.join(KEXTS)}")
    print(f"   BAR: UEFI ResizeGpuBars={a.gpu_bars} (2^{a.gpu_bars} MB)  Booter ResizeAppleGpuBars={a.bars}   cores={a.cores}")
    print("\n写到 p4（需要 root）：")
    print(f"   sudo dd if={img} of=/dev/disk/by-id/nvme-ZHITAI_TiPlus7100_1TB_ZTA71T0AB252817B43-part4 bs=4M conv=fsync")


if __name__ == "__main__":
    main()
