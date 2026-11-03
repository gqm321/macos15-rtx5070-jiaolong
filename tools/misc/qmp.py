#!/usr/bin/env python3
"""在正在跑的 VM 上执行一条 QMP 命令（热插拔、查设备等）。

    qmp.py query-block
    qmp.py device_del '{"id":"usbpass0"}'
    qmp.py device_add '{"driver":"usb-storage","bus":"xhci.0","id":"t0","drive":"t"}'

输出：命令的 return（JSON），失败时打印 error 并以 1 退出。
"""
import json
import socket
import sys

QMP = "/home/guqiaomu/vm-macos-qemu/dump/mac-qmp.sock"


def call(cmd, args=None, path=QMP):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(15)
    s.connect(path)
    s.recv(65536)  # greeting
    for req in ({"execute": "qmp_capabilities"},
                {"execute": cmd, "arguments": args or {}}):
        s.sendall(json.dumps(req).encode())
        while True:
            buf = b""
            while b"\n" not in buf:
                chunk = s.recv(65536)
                if not chunk:
                    raise RuntimeError("QMP 连接断了")
                buf += chunk
            line, rest = buf.split(b"\n", 1)
            msg = json.loads(line)
            if "event" in msg:      # 跳过异步事件
                continue
            break
        if "error" in msg:
            raise RuntimeError(json.dumps(msg["error"], ensure_ascii=False))
    s.close()
    return msg.get("return")


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else None
    try:
        r = call(cmd, args)
    except Exception as e:  # noqa: BLE001
        print(f"error: {e}", file=sys.stderr)
        return 1
    if r is not None:
        print(json.dumps(r, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
