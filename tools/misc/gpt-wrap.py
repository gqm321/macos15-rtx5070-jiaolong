#!/usr/bin/env python3
"""Write a GPT into a qcow2 (or raw) image without root and without copying it.

The macOS installer ISOs handed around are Apple Partition Map images: UEFI
(OVMF/OpenCore) and macOS's own disk arbitration both ignore APM, so the HFS+
volume inside never shows up.  This tool lays a protective MBR + GPT over the
existing data: the partition is declared at the offset where the HFS+ volume
already lives, so no gigabyte of media has to be rewritten.

    tools/gpt-wrap.py --img mac15-installer.qcow2 --start 262208 --count 34676672 \
        --grow 1M [--name "Install macOS Sequoia"] [--dry-run]

`--grow` expands the virtual disk (qcow2 must have a backing file, or be
sparse) so the backup GPT can sit after the media; it is applied with
`qemu-img resize` before the tables are written.

Writes go through `qemu-io`, which accepts a pattern *file*, so binary blobs
are no problem.
"""
import argparse
import json
import os
import struct
import subprocess
import sys
import uuid
import zlib

SECTOR = 512
HFS_TYPE = uuid.UUID("48465300-0000-11AA-AA11-00306543ECAC")


def crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def protective_mbr(total_sectors):
    mbr = bytearray(SECTOR)
    # One 0xEE entry covering the disk, CHS fields are the spec's placeholder.
    struct.pack_into("<B3sB3sII", mbr, 446, 0x00, b"\x00\x02\x00", 0xEE,
                     b"\xff\xff\xff", 1, min(total_sectors - 1, 0xFFFFFFFF))
    struct.pack_into("<H", mbr, 510, 0xAA55)
    return bytes(mbr)


def entry_array(part_first, part_last, disk_guid, name):
    ents = bytearray(128 * 128)
    name_utf16 = name.encode("utf-16-le")[:72]
    struct.pack_into("<16s16sQQQ72s", ents, 0,
                     HFS_TYPE.bytes_le, disk_guid.bytes_le,
                     part_first, part_last, 0, name_utf16)
    return bytes(ents)


def gpt_header(my_lba, alt_lba, first_usable, last_usable, disk_guid,
               entries_lba, entries_crc):
    hdr = bytearray(92)
    struct.pack_into("<8sIIIIQQQQ16sQIII", hdr, 0,
                     b"EFI PART", 0x00010000, 92, 0, 0,
                     my_lba, alt_lba, first_usable, last_usable,
                     disk_guid.bytes_le, entries_lba, 128, 128, entries_crc)
    struct.pack_into("<I", hdr, 16, crc32(bytes(hdr)))
    return bytes(hdr)


def write_at(img, fmt, path, offset):
    subprocess.run(["qemu-io", "-f", fmt, "-c",
                    f"write -s {path} {offset} {os.path.getsize(path)}", img],
                   check=True, stdout=subprocess.DEVNULL)
    print(f"  wrote {os.path.getsize(path)} bytes at {offset}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--img", required=True)
    ap.add_argument("--fmt", default="qcow2")
    ap.add_argument("--start", type=int, required=True, help="first LBA of the existing filesystem")
    ap.add_argument("--count", type=int, required=True, help="sector count of the filesystem")
    ap.add_argument("--grow", default=None, help="resize the virtual disk first, e.g. 1M")
    ap.add_argument("--name", default="Install macOS")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if a.grow:
        if a.dry_run:
            print(f"would run: qemu-img resize {a.img} +{a.grow}")
        else:
            subprocess.run(["qemu-img", "resize", a.img, "+" + a.grow], check=True)

    size = json.loads(subprocess.run(["qemu-img", "info", "--output=json", a.img],
                                     check=True, capture_output=True, text=True).stdout)["virtual-size"]
    total = size // SECTOR
    if total * SECTOR != size:
        sys.exit(f"virtual size {size} is not sector aligned")

    first_usable, last_usable = 34, total - 34
    part_first, part_last = a.start, a.start + a.count - 1
    if not (first_usable == part_first or first_usable < part_first):
        sys.exit("partition starts inside the GPT header area")
    if part_last > last_usable:
        sys.exit("partition runs past the last usable LBA; pass --grow")

    disk_guid = uuid.uuid4()
    ents = entry_array(part_first, part_last, disk_guid, a.name)
    ents_crc = crc32(ents)
    hdr = gpt_header(1, total - 1, first_usable, last_usable, disk_guid, 2, ents_crc)
    hdr_bak = gpt_header(total - 1, 1, first_usable, last_usable, disk_guid,
                         total - 33, ents_crc)
    mbr = protective_mbr(total)

    print(f"disk: {total} sectors ({size} B), partition LBA {part_first}..{part_last} "
          f"({a.count} sectors, {a.count * SECTOR} B), name={a.name!r}")
    if a.dry_run:
        return

    tmp = "/tmp/opencode/gpt"
    os.makedirs(tmp, exist_ok=True)
    # primary: MBR + header + entries (34 sectors)
    with open(f"{tmp}/primary.bin", "wb") as f:
        f.write(mbr)
        f.write(hdr)
        f.write(ents)
        f.write(b"\x00" * (34 * SECTOR - len(mbr) - len(hdr) - len(ents)))
    with open(f"{tmp}/backup.bin", "wb") as f:
        f.write(ents)
        f.write(hdr_bak)
    write_at(a.img, a.fmt, f"{tmp}/primary.bin", 0)
    write_at(a.img, a.fmt, f"{tmp}/backup.bin", (total - 33) * SECTOR)
    print("done")


if __name__ == "__main__":
    main()
