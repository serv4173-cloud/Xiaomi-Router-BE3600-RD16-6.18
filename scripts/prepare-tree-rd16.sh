#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# DRAFT, not tested on a real build tree.
#
# Apply the RD16 layer on top of a fivefold3 tree that already has the RD15
# patch 0001 applied (it adds xiaomi,rd15 branches that this script extends):
#   prepare-tree-rd16.sh TREE_DIR
# platform.sh only gets REFUSAL branches for xiaomi,rd16: sysupgrade stays disabled.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
dir=${1:?usage: $0 TREE_DIR}
tgt=$dir/target/linux/qualcommbe
img=$tgt/image/ipq53xx.mk
net=$tgt/ipq53xx/base-files/etc/board.d/02_network
cal=$tgt/ipq53xx/base-files/etc/hotplug.d/firmware/12-ath12k-caldata
ov=$here/target/linux/qualcommbe

die() { echo "prepare-tree-rd16: $*" >&2; exit 1; }

for f in "$img" "$net" "$cal" "$ov/image/xiaomi_rd16.mk.part" \
	 "$ov/dts/ipq5332-xiaomi-rd16.dts" "$here/configs/xiaomi_rd16.diffconfig" \
	 "$ov/ipq53xx/base-files/lib/upgrade/rd16-upgrade.sh" \
	 "$ov/ipq53xx/base-files/lib/upgrade/platform.sh.rd16.part" \
	 "$here/scripts/rd16-fit-alt-config.sh"; do
	[ -f "$f" ] || die "missing file: $f"
done
grep -q 'define Device/xiaomi_rd15' "$img" || die "RD15 patch 0001 not applied (ipq53xx.mk)"
grep -q 'xiaomi,rd15)' "$net" || die "RD15 patch 0001 not applied (02_network)"
grep -q 'xiaomi,rd15' "$cal" || die "RD15 patch 0001 not applied (12-ath12k-caldata)"

# 1. image profile
if ! grep -q 'define Device/xiaomi_rd16' "$img"; then
	printf '\n' >> "$img"
	sed -n '/^define Build\/fit-dual/,$p' "$ov/image/xiaomi_rd16.mk.part" >> "$img"
	echo "added Device/xiaomi_rd16 and Build/fit-dual"
fi

# 2. DTS
mkdir -p "$tgt/dts"
cp "$ov/dts/ipq5332-xiaomi-rd16.dts" "$tgt/dts/"
echo "copied ipq5332-xiaomi-rd16.dts"

# 3. FIT dual-config script
mkdir -p "$dir/scripts"
cp "$here/scripts/rd16-fit-alt-config.sh" "$dir/scripts/"
chmod +x "$dir/scripts/rd16-fit-alt-config.sh"
echo "copied rd16-fit-alt-config.sh"

# 4. 02_network: new branch before the GL-BE3600 one
if ! grep -q 'xiaomi,rd16)' "$net"; then
	awk '/^\tgl\.inet,gl-be3600\)$/ && !d {
		print "\txiaomi,rd16)"
		print "\t\t# DSA labels from ipq5332-xiaomi-rd16.dts: wan = switch port 3"
		print "\t\tucidef_set_interfaces_lan_wan \"lan1 lan2 lan3\" \"wan\""
		print "\t\t;;"
		d = 1
	}
	{ print }
	END { if (!d) exit 1 }' "$net" > "$net.new" || { rm -f "$net.new"; die "gl-be3600 anchor not found in 02_network"; }
	mv "$net.new" "$net"
	echo "added xiaomi,rd16 to 02_network"
fi

# 5. 12-ath12k-caldata: join the xiaomi,rd15 branches (two blocks)
if ! grep -q 'xiaomi,rd16' "$cal"; then
	sed 's/^\txiaomi,rd15)$/\txiaomi,rd15|\\\n\txiaomi,rd16)/' "$cal" > "$cal.new"
	[ "$(grep -c 'xiaomi,rd16)' "$cal.new")" = 2 ] || { rm -f "$cal.new"; die "expected 2 xiaomi,rd15 branches in 12-ath12k-caldata"; }
	mv "$cal.new" "$cal"
	echo "added xiaomi,rd16 to 12-ath12k-caldata"
fi

# 6. first-boot files: RD16 safe defaults (RD15 files/ come from the RD15 tree)
mkdir -p "$dir/files"
cp -R "$here/files/." "$dir/files/"
chmod +x "$dir/files/etc/uci-defaults/99-rd16-safe-defaults"
echo "copied files/ (99-rd16-safe-defaults)"

# 6b. upgrade logic (dormant: RD16_UPGRADE_ENABLED=0) and refusal branches in platform.sh
upg=$tgt/ipq53xx/base-files/lib/upgrade
plat=$upg/platform.sh
part=$ov/ipq53xx/base-files/lib/upgrade/platform.sh.rd16.part
[ -f "$plat" ] || die "missing file: $plat"
mkdir -p "$upg"
cp "$ov/ipq53xx/base-files/lib/upgrade/rd16-upgrade.sh" "$upg/"
echo "copied rd16-upgrade.sh"
if ! grep -q 'xiaomi,rd16)' "$plat"; then
	awk -v part="$part" '/^\tgl\.inet,gl-be3600\)$/ { while ((getline l < part) > 0) print l; close(part); n++ }
		{ print }
		END { if (n != 2) exit 1 }' "$plat" > "$plat.new" || { rm -f "$plat.new"; die "expected 2 gl-be3600 branches in platform.sh"; }
	cat "$plat.new" > "$plat"
	rm -f "$plat.new"
	echo "added xiaomi,rd16 refusal branches to platform.sh"
fi

# 7. config
cp "$here/configs/xiaomi_rd16.diffconfig" "$dir/.config"

echo "RD16 layer applied to $dir"
echo "NOTE: platform.sh xiaomi,rd16 branches refuse sysupgrade (RD16_UPGRADE_ENABLED=0, untested)."
