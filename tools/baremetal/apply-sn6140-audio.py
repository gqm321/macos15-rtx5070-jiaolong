#!/usr/bin/env python3
"""把 SN6140 定制版 AppleALC 装进一个**已挂载**的 OpenCore ESP，并保持其余配置不动。

    python3 tools/baremetal/apply-sn6140-audio.py --esp /run/media/$USER/EFI --dry-run
    python3 tools/baremetal/apply-sn6140-audio.py --esp /run/media/$USER/EFI
    python3 tools/baremetal/apply-sn6140-audio.py --esp /Volumes/EFI      # 在 macOS 里
    python3 tools/baremetal/apply-sn6140-audio.py --esp /Volumes/EFI --check

做三件事（都可以单独回滚）：
  1. 备份现有的 AppleALC.kext 和 config.plist 到 EFI/OC/backups/sn6140-audio-<时间>/
  2. 用 kexts/applealc-sn6140/AppleALC.kext 替换 EFI/OC/Kexts/AppleALC.kext
  3. boot-args 加 alcid=15 alcdelay=1000；把 HDEF 的 layout-id 属性写成 data 15
     （AppleALC 里 alcid= 优先级最高；属性写成 data 是为了它在 boot-arg 丢失时也生效）

不做的事：不 dd 镜像、不动分区表、不碰 Windows/Linux 的 ESP。目标目录必须已经含有
EFI/OC/config.plist 且其中 AppleALC.kext 条目存在，否则直接拒绝。

回滚：备份目录里有一个 restore.sh，或者把 config.plist 和 AppleALC.kext 拷回去。
"""
import argparse
import base64
import os
import re
import shutil
import sys
import time
import plistlib

W = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_KEXT = os.path.join(W, "kexts", "applealc-sn6140", "AppleALC.kext")
AUDIO_PATH = "PciRoot(0x0)/Pci(0x8,0x1)/Pci(0x0,0x6)"
LAYOUT = 15
EXPECT_TAG = b"DBG-199-2026-10-26"
EXPECT_ID = "as.vit9696.AppleALC"


def die(msg):
    sys.exit(f"✗ {msg}")


def find_esp(arg):
    if arg:
        cands = [arg]
    else:
        cands = []
        for base in (f"/run/media/{os.environ.get('USER', '')}",
                     "/run/media", "/Volumes", "/mnt", "/media"):
            if not os.path.isdir(base):
                continue
            try:
                entries = [os.path.join(base, e) for e in os.listdir(base)]
            except PermissionError:
                continue
            cands += [e for e in entries if os.path.isdir(e)]
            if base == "/run/media":
                cands += [os.path.join(base, u, e)
                          for u in os.listdir(base) if os.path.isdir(os.path.join(base, u))
                          for e in os.listdir(os.path.join(base, u))]
    for c in cands:
        c = os.path.abspath(c)
        for root in (c, os.path.join(c, "EFI"), os.path.dirname(c)):
            if os.path.isfile(os.path.join(root, "EFI/OC/config.plist")):
                return root
    die("没找到含 EFI/OC/config.plist 的 ESP，请用 --esp 指定挂载点")


def kext_identity(kext):
    info_path = os.path.join(kext, "Contents/Info.plist")
    exe_path = os.path.join(kext, "Contents/MacOS/AppleALC")
    if not (os.path.isfile(info_path) and os.path.isfile(exe_path)):
        die(f"{kext} 不是完整的 AppleALC.kext")
    info = plistlib.load(open(info_path, "rb"))
    if info.get("CFBundleIdentifier") != EXPECT_ID:
        die(f"{kext}: CFBundleIdentifier={info.get('CFBundleIdentifier')!r}")
    blob = open(exe_path, "rb").read()
    if EXPECT_TAG not in blob or b"SN6140" not in blob:
        die(f"{kext}: 可执行文件里没有 {EXPECT_TAG.decode()} / SN6140 标记")
    return info.get("CFBundleVersion"), len(blob)


def read_config(path):
    raw = open(path, "rb").read()
    if not raw.lstrip().startswith(b"<?xml"):
        die(f"{path} 不是 XML plist，本脚本不处理二进制 config.plist")
    return raw.decode("utf-8")


def set_boot_args(text, extra):
    m = re.search(r"(<key>boot-args</key>\s*<string>)(.*?)(</string>)", text, re.S)
    if not m:
        die("config.plist 里找不到 boot-args")
    tokens = m.group(2).split()
    for item in extra:
        key = item.split("=", 1)[0] + "="
        tokens = [t for t in tokens if not t.startswith(key)]
        tokens.append(item)
    new = m.group(1) + " ".join(tokens) + m.group(3)
    return text[:m.start()] + new + text[m.end():]


def set_layout_property(text, value):
    """把 <key>layout-id</key> 后面的标量改成 4 字节小端 data。"""
    pat = re.compile(r"(<key>layout-id</key>\s*)(<[^>]+>[^<]*</[^>]+>|<[^>]+/>)")
    hits = pat.findall(text)
    if not hits:
        return text, False
    if len(hits) != 1:
        die(f"config.plist 里有 {len(hits)} 个 layout-id，无法安全判断改哪一个")
    data = base64.b64encode(value.to_bytes(4, "little")).decode()
    new = pat.sub(lambda m: m.group(1) + f"<data>{data}</data>", text, count=1)
    return new, True


def validate(text, kext_ver):
    pl = plistlib.loads(text.encode("utf-8"))
    nv = pl["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]
    args = nv["boot-args"].split()
    for need in ("alcid=%d" % LAYOUT, "alcdelay=1000"):
        if need not in args:
            die(f"写回校验失败：boot-args 缺 {need}")
    add = pl["Kernel"]["Add"]
    names = [k["BundlePath"] for k in add]
    if "AppleALC.kext" not in names:
        die("Kernel>Add 里没有 AppleALC.kext")
    alc = next(k for k in add if k["BundlePath"] == "AppleALC.kext")
    if not alc["Enabled"]:
        die("Kernel>Add 里 AppleALC.kext 是 Enabled=false")
    if "Lilu.kext" in names and names.index("AppleALC.kext") < names.index("Lilu.kext"):
        die("AppleALC 排在 Lilu 之前，需要调整 Kernel>Add 顺序")
    enabled = [k["BundlePath"] for k in add if k["Enabled"]]
    if any("VoodooHDA" in n for n in enabled):
        die("VoodooHDA 还开着：它和 AppleALC 会抢同一个 HDA 控制器，必须先关掉")
    dp = pl.get("DeviceProperties", {}).get("Add", {})
    for path, props in dp.items():
        if "layout-id" in props:
            v = props["layout-id"]
            ok = isinstance(v, bytes) and int.from_bytes(v, "little") == LAYOUT
            print(f"  DeviceProperties {path} layout-id = "
                  f"{'data ' + v.hex() if isinstance(v, bytes) else repr(v)} "
                  f"{'✓' if ok else '（未生效的类型；alcid= 仍会覆盖）'}")
    print(f"  kernel kext: AppleALC {kext_ver} enabled, index "
          f"{names.index('AppleALC.kext')} (Lilu {names.index('Lilu.kext')})")


def main():
    global LAYOUT
    ap = argparse.ArgumentParser()
    ap.add_argument("--esp", help="已挂载的 ESP 根目录（含 EFI/OC/config.plist）")
    ap.add_argument("--kext", default=DEFAULT_KEXT, help="SN6140 AppleALC.kext 路径")
    ap.add_argument("--layout", type=int, default=LAYOUT)
    ap.add_argument("--no-layout-property", action="store_true",
                    help="只加 alcid=，不改 HDEF 的 layout-id 属性")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--check", action="store_true", help="只报告当前状态，不写任何东西")
    a = ap.parse_args()

    LAYOUT = a.layout
    if not os.path.isdir(a.kext):
        die(f"缺 {a.kext}；先运行 tools/baremetal/fetch-sn6140-applealc.sh")
    ver, exe_len = kext_identity(a.kext)

    esp = find_esp(a.esp)
    oc = os.path.join(esp, "EFI/OC")
    cfg = os.path.join(oc, "config.plist")
    dst = os.path.join(oc, "Kexts/AppleALC.kext")
    print(f"ESP: {esp}")
    print(f"源 : {a.kext} (AppleALC {ver}, {exe_len} B)")

    text = read_config(cfg)

    if a.check:
        cur = dst + "/Contents/MacOS/AppleALC"
        if os.path.isfile(cur):
            blob = open(cur, "rb").read()
            tag = next((t.decode() for t in (b"DBG-199-2026-10-26", b"REL-199-2026-09-27")
                        if t in blob), "?")
            print(f"当前 ESP 里的 AppleALC 标识: {tag}  ({len(blob)} B)")
        else:
            print("当前 ESP 里没有 AppleALC.kext")
        pl = plistlib.loads(text.encode("utf-8"))
        nv = pl["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["boot-args"]
        print("boot-args:", nv)
        print("boot-args 已有 alcid=", f"alcid={LAYOUT}" in nv.split())
        return

    if not os.path.isdir(a.kext):
        die("源 kext 不存在")

    new_text = set_boot_args(text, [f"alcid={LAYOUT}", "alcdelay=1000"])
    changed_layout = False
    if not a.no_layout_property:
        new_text, changed_layout = set_layout_property(new_text, LAYOUT)
        if not changed_layout:
            print("  提示: config.plist 没有 layout-id 属性，仅靠 alcid= 生效")

    # 先只验证，再落盘
    tmp_cfg = cfg + ".sn6140-new"
    validate(new_text, ver)
    if a.dry_run:
        print("\n[dry-run] 将写入：")
        print("  " + re.search(r"<key>boot-args</key>\s*<string>(.*?)</string>",
                                new_text, re.S).group(1))
        print(f"  layout-id 属性改为 data {LAYOUT}：{changed_layout}")
        print(f"  替换 {dst}")
        return

    stamp = time.strftime("%Y%m%d-%H%M%S")
    bak = os.path.join(oc, "backups", f"sn6140-audio-{stamp}")
    os.makedirs(bak)
    shutil.copy2(cfg, os.path.join(bak, "config.plist"))
    if os.path.isdir(dst):
        shutil.copytree(dst, os.path.join(bak, "AppleALC.kext"), symlinks=True)
    with open(os.path.join(bak, "restore.sh"), "w") as f:
        f.write("#!/bin/sh\n# 用备份恢复（ESP 需已挂载）\n")
        f.write('set -e\nESP="${1:?用法: sh restore.sh /Volumes/EFI}"\n')
        f.write(f'cp "$(dirname "$0")/config.plist" "$ESP/EFI/OC/config.plist"\n')
        f.write(f'rm -rf "$ESP/EFI/OC/Kexts/AppleALC.kext"\n')
        f.write(f'cp -R "$(dirname "$0")/AppleALC.kext" "$ESP/EFI/OC/Kexts/"\n')
    print(f"备份: {bak}")

    # kext：先写临时目录再换名，避免中途断电留下半个 kext
    tmp_kext = dst + ".new"
    prev_kext = dst + ".prev"
    shutil.rmtree(tmp_kext, ignore_errors=True)
    shutil.rmtree(prev_kext, ignore_errors=True)
    shutil.copytree(a.kext, tmp_kext, symlinks=True)
    if os.path.isdir(dst):
        os.rename(dst, prev_kext)
    os.rename(tmp_kext, dst)
    shutil.rmtree(prev_kext, ignore_errors=True)

    # config：写临时文件、回读校验、再覆盖
    with open(tmp_cfg, "w") as f:
        f.write(new_text)
    validate(open(tmp_cfg).read(), ver)
    shutil.copy2(tmp_cfg, cfg)
    os.remove(tmp_cfg)
    os.sync()

    blob = open(dst + "/Contents/MacOS/AppleALC", "rb").read()
    if EXPECT_TAG not in blob:
        die("写入后校验失败：kext 内容不对")

    print(f"""
✅ 完成
   AppleALC : {ver} / {EXPECT_TAG.decode()}  ({len(blob)} B)
   boot-args: alcid={LAYOUT} alcdelay=1000
   layout-id: {'data %d' % LAYOUT if changed_layout else '未改（alcid= 生效）'}

重启前确认：OpenCore 里仍是这一块 ESP，且 Kernel>Add 的 AppleALC 已启用。
进 macOS 后：
   ioreg -r -n AppleALC -l -w0 | grep VersionInfo     # 期望 DBG-199-2026-10-26
   system_profiler SPAudioDataType                    # 期望出现 内置扬声器 / 耳机
先调低音量再播声音；有刺耳噪声立刻静音。

回滚：sh {bak}/restore.sh <挂载的ESP>
""")


if __name__ == "__main__":
    main()
