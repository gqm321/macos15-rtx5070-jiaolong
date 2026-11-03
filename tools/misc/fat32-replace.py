#!/usr/bin/env python3
"""在 FAT16/FAT32 镜像里原地替换一个文件（不重新分配整条链，只追加需要的簇）。

为什么要自己写：宿主机没有 mtools / guestfish，pyfatfs 写这个 ESP 时会在 FAT
链上撞到 FREE_CLUSTER 报错。读取用 pyfatfs 没问题，写入这里自己做，只做最小操作：
沿已有链写满，不够再申请空闲簇，改目录项里的文件大小，最后清掉 dirty 位。

    fat32-replace.py --offset 1048576 image.raw /EFI/OC/config.plist new.plist
"""
import argparse
import struct
import sys


class Fat:
    def __init__(self, path, offset, rw=False):
        self.f = open(path, "r+b" if rw else "rb")
        self.base = offset
        self.f.seek(offset)
        bs = self.f.read(512)
        if bs[510:512] != b"\x55\xaa":
            raise SystemExit("不是 FAT 引导扇区（缺 0x55AA）")
        self.bps = struct.unpack_from("<H", bs, 11)[0]
        self.spc = bs[13]
        self.reserved = struct.unpack_from("<H", bs, 14)[0]
        self.nfats = bs[16]
        self.fatsz = struct.unpack_from("<I", bs, 36)[0]
        self.root = struct.unpack_from("<I", bs, 44)[0]
        self.clus_bytes = self.bps * self.spc
        self.fat_off = self.base + self.reserved * self.bps
        self.data_off = self.base + (self.reserved + self.nfats * self.fatsz) * self.bps
        self.f.seek(self.fat_off)
        self.fat = bytearray(self.f.read(self.fatsz * self.bps))

    # ---- 基本操作 -----------------------------------------------------
    def clus_off(self, c):
        return self.data_off + (c - 2) * self.clus_bytes

    def next_clus(self, c):
        return struct.unpack_from("<I", self.fat, c * 4)[0] & 0x0FFFFFFF

    def read_clus(self, c):
        self.f.seek(self.clus_off(c))
        return self.f.read(self.clus_bytes)

    def write_clus(self, c, data):
        self.f.seek(self.clus_off(c))
        self.f.write(data)

    def chain(self, start, limit=100000):
        out, c = [], start
        while 2 <= c < 0x0FFFFFF8 and len(out) < limit:
            out.append(c)
            c = self.next_clus(c)
        return out

    # ---- 目录 ---------------------------------------------------------
    def find(self, path):
        cur = self.root
        entry = None
        for part in [p for p in path.split("/") if p]:
            entry = None
            for name, e, off in self._list_entries(cur):
                if name.lower() == part.lower():
                    entry = (e, off)
                    break
            if entry is None:
                raise SystemExit(f"找不到 {part} in {path}")
            e = entry[0]
            cur = (struct.unpack_from("<H", e, 20)[0] << 16) | struct.unpack_from("<H", e, 26)[0]
        return entry

    def _list_entries(self, cluster):
        data = self.read_clus(cluster)
        lfn = []
        for i in range(0, len(data), 32):
            e = data[i:i + 32]
            if e[0] == 0x00:
                break
            if e[0] == 0xE5:
                lfn = []
                continue
            if e[11] == 0x0F:
                part = b""
                for a, b in ((1, 11), (14, 26), (28, 32)):
                    part += e[a:b]
                lfn.append(part.decode("utf-16-le", "ignore").split("\x00")[0])
                continue
            name = "".join(lfn[::-1]) if lfn else e[0:11].decode("ibm437").rstrip()
            lfn = []
            yield name, e, self.clus_off(cluster) + i

    # ---- 写 -----------------------------------------------------------
    def replace(self, path, data):
        e, eoff = self.find(path)
        start = (struct.unpack_from("<H", e, 20)[0] << 16) | struct.unpack_from("<H", e, 26)[0]
        need = max(1, (len(data) + self.clus_bytes - 1) // self.clus_bytes)
        ch = self.chain(start)
        if not ch:
            raise SystemExit("文件没有起始簇")
        # 链不够就追加空闲簇
        while len(ch) < need:
            free = None
            for c in range(2, len(self.fat) // 4):
                if struct.unpack_from("<I", self.fat, c * 4)[0] == 0:
                    free = c
                    break
            if free is None:
                raise SystemExit("没有空闲簇")
            struct.pack_into("<I", self.fat, ch[-1] * 4, free)
            struct.pack_into("<I", self.fat, free * 4, 0x0FFFFFFF)
            ch.append(free)
        # 写数据
        for i, c in enumerate(ch):
            blk = data[i * self.clus_bytes:(i + 1) * self.clus_bytes]
            if len(blk) < self.clus_bytes:
                blk = blk + b"\x00" * (self.clus_bytes - len(blk))
            self.write_clus(c, blk)
        # 目录项大小
        self.f.seek(eoff + 28)
        self.f.write(struct.pack("<I", len(data)))
        # dirty 位清掉（FAT[1] bit27 = clean shutdown 标志）
        struct.pack_into("<I", self.fat, 4, struct.unpack_from("<I", self.fat, 4)[0] & ~(1 << 27))
        # 写回所有 FAT 副本
        for n in range(self.nfats):
            self.f.seek(self.fat_off + n * self.fatsz * self.bps)
            self.f.write(self.fat)
        self.f.flush()

    def close(self):
        self.f.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--offset", type=int, required=True)
    ap.add_argument("image")
    ap.add_argument("path")
    ap.add_argument("newfile")
    a = ap.parse_args()
    data = open(a.newfile, "rb").read()
    fs = Fat(a.image, a.offset, rw=True)
    old = fs.find(a.path)
    old_size = struct.unpack_from("<I", old[0], 28)[0]
    fs.replace(a.path, data)
    fs.close()
    print(f"{a.path}: {old_size} B -> {len(data)} B  已写入")


if __name__ == "__main__":
    main()
