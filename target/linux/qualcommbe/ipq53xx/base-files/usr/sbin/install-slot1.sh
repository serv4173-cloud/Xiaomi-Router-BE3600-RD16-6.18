#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Install OpenWrt into slot 1 (mtd "rootfs_1") of a Xiaomi BE3600 RD16.
# Runs ON THE ROUTER, as root, from the OpenWrt initramfs booted in RAM
# (stock U-Boot passes ubi.mtd=rootfs_1 when flag_boot_rootfs=1, so slot 1 is
# attached as ubi0):
#
#   sh install-slot1.sh FIT SHA256_FIT SQUASHFS SHA256_SQUASHFS
#
# FIT      = build_dir/.../xiaomi_rd16-uImage.itb   (kernel FIT, no initramfs)
# SQUASHFS = build_dir/.../root.squashfs
#
# Resulting volumes in slot 1 (stock names kept so bootmiwifi finds them):
#   ubi0_0 kernel       <- OpenWrt FIT
#   ubi0_1 ubi_rootfs   <- OpenWrt SquashFS, resized to 16 MiB
#   ubi0_2 rootfs_data  <- (re)created with all free LEBs; OpenWrt formats it
#
# BACK UP ALL MTD PARTITIONS AND THE SLOT 1 VOLUMES FIRST (docs/installing.md).
# Never touches slot 0 (mtd "rootfs", stock firmware), ART, bootloaders or partition tables.
set -u
fit=${1:?FIT} fit_sum=${2:?SHA256_FIT} sq=${3:?SQUASHFS} sq_sum=${4:?SHA256_SQUASHFS}
die() { echo "INSTALL_FAILED: $*"; exit 1; }

[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,rd16 ] || die "board"
case " $(cat /proc/cmdline) " in *" ubi.mtd=rootfs_1 "*) ;; *) die "not attached to slot rootfs_1" ;; esac
[ "$(cat /sys/class/ubi/ubi0/mtd_num)" = 20 ] || die "ubi0 is not mtd20"
grep -q '^mtd20: 02a00000 00020000 "rootfs_1"$' /proc/mtd || die "mtd20 layout"
[ "$(cat /sys/class/ubi/ubi0_0/name)" = kernel ] || die "vol0 name"
[ "$(cat /sys/class/ubi/ubi0_1/name)" = ubi_rootfs ] || die "vol1 name"
# Stock Xiaomi has only volumes 0 and 1. A previous install of this port
# leaves rootfs_data as volume 2; any other volume 2 is unexpected.
have_vol2=0
if [ -e /sys/class/ubi/ubi0_2 ]; then
	[ "$(cat /sys/class/ubi/ubi0_2/name)" = rootfs_data ] || die "unexpected vol2"
	have_vol2=1
fi
[ ! -e /sys/class/ubi/ubi0_3 ] || die "unexpected vol3"
[ "$(sha256sum "$fit" | cut -d' ' -f1)" = "$fit_sum" ] || die "FIT hash"
[ "$(sha256sum "$sq" | cut -d' ' -f1)" = "$sq_sum" ] || die "squashfs hash"
fit_size=$(wc -c < "$fit"); sq_size=$(wc -c < "$sq")
# Our own layout choice, not a stock number: kernel volume is resized to K_LEBS below.
K_LEBS=40
[ "$fit_size" -le $((K_LEBS * 126976)) ] || die "FIT too big for kernel volume of $K_LEBS LEBs"
[ "$sq_size" -le 16777216 ] || die "squashfs bigger than 16 MiB"
echo "guards ok: ubi0=mtd20 vol2=$have_vol2 fit=$fit_size squashfs=$sq_size"

[ -e /dev/ubiblock0_1 ] && { ubiblock -r /dev/ubi0_1 || die "ubiblock busy"; }
# Layout is set before any data is written: free the old rootfs_data first,
# then size ubi_rootfs and kernel.
if [ "$have_vol2" = 1 ]; then
	ubirmvol /dev/ubi0 -n 2 || die "remove vol2"
	have_vol2=0
fi
ubirsvol /dev/ubi0 -n 1 -s 16MiB || die "resize ubi_rootfs"
ubirsvol /dev/ubi0 -n 0 -s $((K_LEBS * 126976)) || die "resize kernel"
ubiupdatevol /dev/ubi0_0 "$fit" || die "write kernel"
ubiupdatevol /dev/ubi0_1 "$sq" || die "write rootfs"
[ "$(head -c "$fit_size" /dev/ubi0_0 | sha256sum | cut -d' ' -f1)" = "$fit_sum" ] || die "kernel readback"
[ "$(head -c "$sq_size" /dev/ubi0_1 | sha256sum | cut -d' ' -f1)" = "$sq_sum" ] || die "rootfs readback"
echo "readback ok"
# ubi_rootfs keeps 16 MiB (stock: ~24 MiB, mostly unused by OpenWrt) and
# rootfs_data takes every free LEB (layout already set above).
ubimkvol /dev/ubi0 -n 2 -N rootfs_data -m || die "create rootfs_data"
ubinfo -d 0 | grep -E 'available|Volumes count'
sync
echo INSTALL_OK
