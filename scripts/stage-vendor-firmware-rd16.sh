#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# DRAFT, NOT RUN. Adapted from rd15 scripts/stage-vendor-firmware.sh (d9c8a55a1eed).
# Copies the proprietary Wi-Fi pieces for Xiaomi BE3600 RD16 from a Xiaomi firmware
# YOU obtained into the files/ overlay of YOUR local build tree. Nothing is downloaded;
# the output is Xiaomi/Qualcomm property and must not be committed or redistributed.
#
#   stage-vendor-firmware-rd16.sh --firmware miwifi_rd16_firmware_*_1.0.31.bin TREE
#   stage-vendor-firmware-rd16.sh --rootfs   EXTRACTED_STOCK_ROOTFS_DIR      TREE
#
# Differences from RD15: marker RD16, blobs live under lib/firmware/IPQ5332/WIFI_FW/
# and the QCN6432 board file bdwlan.b0060 differs from RD15 (own sha256 below).
# Per-unit calibration is NOT copied: it is read from the device's 0:art at runtime.
# Requires: python3, unsquashfs; with --firmware also ubireader_extract_images.
set -eu

usage() { sed -n '4,15p' "$0" >&2; exit 2; }

mode= src= tree=
while [ $# -gt 0 ]; do
	case "$1" in
	--firmware) mode=firmware; src=$2; shift 2 ;;
	--rootfs) mode=rootfs; src=$2; shift 2 ;;
	-h|--help) usage ;;
	*) [ -z "$tree" ] || usage; tree=$1; shift ;;
	esac
done
[ -n "$mode" ] && [ -n "$tree" ] || usage
[ -f "$tree/target/linux/qualcommbe/dts/ipq5332-xiaomi-rd16.dts" ] ||
	{ echo "RD16 layer not applied to $tree" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

if [ "$mode" = firmware ]; then
	[ -f "$src" ] || { echo "no such file: $src" >&2; exit 1; }
	python3 -I - "$src" "$work/root.ubi" <<'PY'
import struct, sys
src, out = sys.argv[1], sys.argv[2]
d = open(src, 'rb').read()
if d[:4] != b'HDR1':
    sys.exit('not a Xiaomi HDR1 firmware image')
found = {}
for off in struct.unpack_from('<4I', d, 0x10):
    if not off:
        continue
    magic, = struct.unpack_from('<H', d, off)
    size, = struct.unpack_from('<I', d, off + 8)
    name = d[off + 0x10:off + 0x30].split(b'\0')[0].decode()
    if magic != 0xbabe:
        sys.exit('bad segment header at 0x%x' % off)
    found[name] = d[off + 0x30:off + 0x30 + size]
ver = found.get('xiaoqiang_version', b'').decode(errors='replace')
if "option HARDWARE 'RD16'" not in ver:
    sys.exit('firmware is not for hardware RD16')
print('firmware:', [l.strip() for l in ver.splitlines() if 'option ROM' in l])
if 'root.ubi' not in found:
    sys.exit('no root.ubi segment')
open(out, 'wb').write(found['root.ubi'])
PY
	(cd "$work" && ubireader_extract_images -o imgs root.ubi >/dev/null)
	sq=$(find "$work/imgs" -name '*vol-ubi_rootfs*' | head -n 1)
	[ -n "$sq" ] || { echo "no ubi_rootfs volume in the image" >&2; exit 1; }
	unsquashfs -no-xattrs -q -d "$work/rootfs" "$sq" lib/firmware/IPQ5332 >/dev/null
	stock=$work/rootfs
else
	stock=$src
fi

fw=$stock/lib/firmware/IPQ5332/WIFI_FW
[ -f "$fw/q6_fw2.mdt" ] || { echo "not a Xiaomi RD16 rootfs: $stock" >&2; exit 1; }

# SHA-256 of the files in miwifi_rd16_firmware_87da2_1.0.31.bin (image sha256
# 3580ce88f13db80d634a1c650672dbe76fdf5d000c774b10bae75051e35e5987), measured locally.
(cd "$fw" && sha256sum -c --quiet) <<'SUMS' || {
f26f08fa38ce2b055a796d56f009490d25963b1a43e2628a999ff9992af6c608  q6_fw2.mdt
b1e41e0339d92e170fd9a75427e46f85ea767ec3f95d9a29f2c92569438e49d2  q6_fw2.b00
b707241545a346265aab1ffb32ff64b55bf8f8dc1b56a46ef33ce3d15db11d33  q6_fw2.b01
9994d9e49f6c27b0e989dabe9fdddedfbc49b9d7b097b82fad0947d498e3496f  q6_fw2.b02
eb53499fb84ed2dbb06ceacdcc1fa62e81315e5bf1b76dc52e9115aeb023cbe8  qcn6432/iu_fw.mdt
5a176265205a7dfc6050ba8a50a7af20065aa0fff867c0cbb2d60df2edb06025  qcn6432/iu_fw.b00
b707241545a346265aab1ffb32ff64b55bf8f8dc1b56a46ef33ce3d15db11d33  qcn6432/iu_fw.b01
1efba95fcc1d72bc998e31f78e6662c6162e8295dbfe165bf56384235d0f7750  qcn6432/iu_fw.b02
36298afd15b944a3fea0e67133e50ef317e6a16a152c2745cc59051f299e62c3  qcn6432/bdwlan.b0060
314510e0bf0ee2e5341c82e17f8a7e5af7f3948994fbb4ef440de1b0931394de  bdwlan.b13
SUMS
	echo "vendor files differ from the measured RD16 1.0.31 set; refusing" >&2
	exit 1
}

# Destination layout copied from the RD15 script; NOT verified on RD16.
dst=$tree/files/lib/firmware/ath12k
mkdir -p "$dst/QCN6432/hw1.0" "$dst/IPQ5332/hw1.0"
for f in q6_fw2.mdt q6_fw2.b00 q6_fw2.b01 q6_fw2.b02; do
	install -m 0644 "$fw/$f" "$dst/QCN6432/hw1.0/$f"
done
for f in iu_fw.mdt iu_fw.b00 iu_fw.b01 iu_fw.b02; do
	install -m 0644 "$fw/qcn6432/$f" "$dst/QCN6432/hw1.0/$f"
done
install -m 0644 "$fw/qcn6432/bdwlan.b0060" "$dst/QCN6432/hw1.0/board.bin"
install -m 0644 "$fw/bdwlan.b13" "$dst/IPQ5332/hw1.0/board.bin"
rm -f "$dst/QCN6432/hw1.0/board-2.bin"
find "$tree/files" -type d -exec chmod go-w {} +

echo "staged RD16 Wi-Fi files into $dst (do not redistribute the build output)"
