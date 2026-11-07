#!/usr/bin/env bash
# 下载并核验社区的 SN6140 定制版 AppleALC（chenhggu6475/Senary-SN6140-AppleALC-Hackintosh）。
#
#   bash tools/baremetal/fetch-sn6140-applealc.sh
#
# 产物: kexts/applealc-sn6140/AppleALC.kext   （kexts/ 已被 .gitignore 排除，不随仓库分发）
#
# 只取 Release 里编译好的 AppleALC.kext；source-overlay/Resources/PinConfigs.kext
# 只是编译资源，不能单独放进 EFI。
set -euo pipefail

REPO="chenhggu6475/Senary-SN6140-AppleALC-Hackintosh"
TAG="SN6140-Test-v1"
ZIP="AppleALC-SN6140-test-v1-DEBUG.zip"
SUMS="SHA256SUMS.txt"
EXPECT_EXE_SHA="050a86856387f24a51dbb32ef432ad17d29c1c23df9b9474a768552fb8a953b6"
EXPECT_ID="as.vit9696.AppleALC"
EXPECT_VER="1.9.9"
EXPECT_BUILD_TAG="DBG-199-2026-10-26"

W=$(cd "$(dirname "$0")/../.." && pwd)
DEST="$W/kexts/applealc-sn6140"
TMP=$(mktemp -d /tmp/sn6140-applealc.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

echo "→ 下载 $REPO $TAG"
if command -v gh >/dev/null 2>&1; then
  gh release download "$TAG" --repo "$REPO" --dir "$TMP" \
     --pattern "$ZIP" --pattern "$SUMS" --clobber
else
  BASE="https://github.com/$REPO/releases/download/$TAG"
  curl -fL --retry 3 -o "$TMP/$ZIP"  "$BASE/$ZIP"
  curl -fL --retry 3 -o "$TMP/$SUMS" "$BASE/$SUMS"
fi

echo "→ 校验 SHA256"
( cd "$TMP" && grep " $ZIP\$" "$SUMS" | sha256sum -c - )

echo "→ 解包"
mkdir -p "$TMP/x"
unzip -q -o "$TMP/$ZIP" -d "$TMP/x"

echo "→ 核验 kext 身份"
python3 - "$TMP/x/AppleALC.kext" "$EXPECT_ID" "$EXPECT_VER" "$EXPECT_BUILD_TAG" <<'PY'
import plistlib, sys
kext, want_id, want_ver, want_tag = sys.argv[1:5]
info = plistlib.load(open(kext + "/Contents/Info.plist", "rb"))
pairs = [("CFBundleIdentifier", want_id), ("CFBundleVersion", want_ver)]
for k, want in pairs:
    got = info.get(k)
    if got != want:
        sys.exit(f"✗ {k} = {got!r}，期望 {want!r}")
exe = open(kext + "/Contents/MacOS/AppleALC", "rb").read()
for needle in (want_tag.encode(), b"SN6140"):
    if needle not in exe:
        sys.exit(f"✗ 可执行文件里找不到 {needle!r}")
print(f"  {info['CFBundleIdentifier']} {info['CFBundleVersion']} / {want_tag} / SN6140 ✓")
PY
EXE_SHA=$(sha256sum "$TMP/x/AppleALC.kext/Contents/MacOS/AppleALC" | cut -d' ' -f1)
if [ -n "$EXPECT_EXE_SHA" ] && [ "$EXE_SHA" != "$EXPECT_EXE_SHA" ]; then
  echo "✗ 可执行文件 SHA256 与记录不一致：$EXE_SHA"
  echo "  （上游可能重新发布了同 tag 的包——先人工看 CHANGES.md 再决定）"
  exit 1
fi
if ! file -b "$TMP/x/AppleALC.kext/Contents/MacOS/AppleALC" | grep -q 'Mach-O 64-bit x86_64'; then
  echo "✗ 不是 x86_64 Mach-O kext，拒绝安装"
  exit 1
fi

echo "→ 安装到 $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$TMP/x/AppleALC.kext" "$DEST/"

cat <<EOF

✅ $DEST/AppleALC.kext
   版本      : $EXPECT_VER (DEBUG 构建)
   运行标识  : $EXPECT_BUILD_TAG
   可执行文件: $EXE_SHA
   codec     : 14F1:1F87 (SN6140)，layout 15

下一步（二选一）：
  已挂载的 ESP 原地替换:  python3 tools/baremetal/apply-sn6140-audio.py --esp /run/media/\$USER/EFI
  重新构建 ESP 镜像     :  python3 tools/baremetal/build-efi-ref.py --sn6140-audio [其他 flag]
EOF
