# Xiaomi BE3600 RD16 (xiaomi,rd16): sysupgrade of slot 1 (mtd "rootfs_1", ubi0).
# DRAFT, NOT TESTED ON HARDWARE. Layout is OUR choice, created by install-slot1.sh
# (stock rootfs_1 has kernel 25 / ubi_rootfs 120 / rootfs_data 167 LEBs):
#   ubi0_0 kernel      static   40 LEBs  <- FIT
#   ubi0_1 ubi_rootfs  dynamic 133 LEBs  <- squashfs
#   ubi0_2 rootfs_data dynamic 143 LEBs  <- emptied, config restored
# Volumes are rewritten in place, never removed, recreated or resized.
# The stock slot (mtd "rootfs"), ART, bootloaders and the U-Boot env are never
# written; the boot flags are only read.
#
# rd16_verify_image <img>  read-only preflight (platform_check_image)
# rd16_do_upgrade <img>    stage2 writer (platform_do_upgrade)
#
# The checks are structural, board and FIT hash (integrity) checks, not
# authenticity checks.
# Sourced from /lib/upgrade: defines functions and variables only.

# Adapted from the stock-slot variant of this script; UNTESTED on RD16.
# Write barrier is fixed at build time, never read from the environment.
RD16_UPGRADE_ENABLED=0

RD16_BOARD=xiaomi,rd16
RD16_DIR=sysupgrade-xiaomi_rd16
RD16_FIT_CONFIG=config@mi04.1-c2
RD16_LEB=126976
RD16_KERNEL_LEBS=40
RD16_ROOT_LEBS=133
RD16_DATA_LEBS=143
RD16_MTD_SIZE=02a00000
RD16_MTD_ERASE=00020000

# Overridable for the mock tests only.
RD16_SYS="${RD16_SYS:-/sys/class/ubi}"
RD16_PROC="${RD16_PROC:-/proc}"
RD16_DEV="${RD16_DEV:-/dev}"
RD16_BLOCK_SYS="${RD16_BLOCK_SYS:-/sys/class/block}"
RD16_TMP="${RD16_TMP:-/tmp}"
# Seconds to wait for the kernel to drop ubiblock0_1 after ubiblock -r.
RD16_BLOCK_WAIT=5
RD16_TOKEN="$RD16_TMP/rd16-upgrade.verified"

rd16_fail() { echo "rd16: $*" >&2; return 1; }
rd16_cat() { cat "$1" 2>/dev/null; }

rd16_need() {
	local c
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || { rd16_fail "missing tool: $c"; return 1; }
	done
}

# <file> <offset> <count>: the bytes as lowercase hex
rd16_hex() {
	dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | hexdump -v -e '1/1 "%02x"'
}

# <file> <512-byte block>: one tar block as hex
rd16_blk() {
	dd if="$1" bs=512 skip="$2" count=1 2>/dev/null | hexdump -v -e '1/1 "%02x"'
}

rd16_strhex() { printf '%s' "$1" | hexdump -v -e '1/1 "%02x"'; }

# <hex>: hex of the leading NUL-terminated string, without the NUL
rd16_hcstr() {
	local h="$1" i=0
	while [ "$i" -lt "${#h}" ]; do
		[ "${h:$i:2}" = 00 ] && { echo "${h:0:$i}"; return 0; }
		i=$((i + 2))
	done
	return 1
}

rd16_cstr() {  # <file> <offset> <max>
	local h
	h=$(rd16_hex "$1" "$2" "$3")
	rd16_hcstr "$h"
}

# <hex> <byte offset> <bytes>: little-endian field as big-endian hex
rd16_le() {
	local h="$1" i=$(($2 + $3 - 1)) r=
	while [ "$i" -ge "$2" ]; do
		r="$r${h:$((i * 2)):2}"
		i=$((i - 1))
	done
	echo "$r"
}

# <hex of an ASCII octal tar field>: decimal
rd16_hoct() {
	local h="$1" i=0 c d=
	while [ "$i" -lt "${#h}" ]; do
		c="${h:$i:2}"
		case "$c" in
		3[0-7]) d="$d${c#3}" ;;
		00|20) [ -n "$d" ] && break ;;
		*) return 1 ;;
		esac
		i=$((i + 2))
	done
	[ -n "$d" ] || return 1
	echo $((0$d))
}

rd16_tar_sum() {  # <header hex>: unsigned header checksum
	local h="$1" i=0 s=0
	while [ "$i" -lt 512 ]; do
		if [ "$i" -ge 148 ] && [ "$i" -lt 156 ]; then
			s=$((s + 32))
		else
			s=$((s + 0x${h:$((i * 2)):2}))
		fi
		i=$((i + 1))
	done
	echo "$s"
}

# <name>: "<index> <size> <erasesize>" of the one MTD with exactly that name
rd16_mtd() {
	awk -v n="\"$1\"" '$4 == n { c++; i = $1; s = $2; e = $3 }
		END { if (c != 1) exit 1; sub(/^mtd/, "", i); sub(/:$/, "", i); print i, s, e }' \
		"$RD16_PROC/mtd" 2>/dev/null
}

rd16_check_vol() {  # <id> <name> <type> <lebs>
	local d="$RD16_SYS/ubi0_$1"

	[ "$(rd16_cat "$d/name")" = "$2" ] &&
	[ "$(rd16_cat "$d/type")" = "$3" ] &&
	[ "$(rd16_cat "$d/reserved_ebs")" = "$4" ] &&
	[ "$(rd16_cat "$d/usable_eb_size")" = "$RD16_LEB" ] ||
		{ rd16_fail "ubi0_$1 is not $2 ($3, $4 LEBs)"; return 1; }
}

rd16_check_layout() {
	local m root

	m=$(rd16_mtd rootfs_1) || { rd16_fail "no unique MTD named rootfs_1"; return 1; }
	set -- $m
	[ "$2" = "$RD16_MTD_SIZE" ] && [ "$3" = "$RD16_MTD_ERASE" ] ||
		{ rd16_fail "mtd rootfs_1 is $2/$3, expected $RD16_MTD_SIZE/$RD16_MTD_ERASE"; return 1; }
	root="$1"
	m=$(rd16_mtd rootfs) || { rd16_fail "no unique MTD named rootfs (stock slot)"; return 1; }
	set -- $m
	[ "$1" != "$root" ] || { rd16_fail "rootfs and rootfs_1 are the same MTD"; return 1; }
	[ "$(rd16_cat "$RD16_SYS/ubi0/mtd_num")" = "$root" ] ||
		{ rd16_fail "ubi0 is not attached to mtd rootfs_1"; return 1; }
	[ "$(rd16_cat "$RD16_SYS/ubi0/volumes_count")" = 3 ] && [ ! -e "$RD16_SYS/ubi0_3" ] ||
		{ rd16_fail "ubi0 does not have exactly 3 volumes"; return 1; }
	rd16_check_vol 0 kernel static "$RD16_KERNEL_LEBS" &&
	rd16_check_vol 1 ubi_rootfs dynamic "$RD16_ROOT_LEBS" &&
	rd16_check_vol 2 rootfs_data dynamic "$RD16_DATA_LEBS"
}

# Same env config and CRC test as rd16-slot. Only reads the flags: slot 1
# must be the one bootmiwifi boots and must already be marked good.
rd16_check_env() {
	local m kv cfg="$RD16_TMP/rd16-fw_env.config" err="$RD16_TMP/rd16-env.err"

	m=$(rd16_mtd 0:appsblenv) || { rd16_fail "0:appsblenv not found"; return 1; }
	set -- $m
	echo "$RD16_DEV/mtd$1 0x0 0x10000 0x20000" > "$cfg" ||
		{ rd16_fail "cannot write $cfg"; return 1; }
	fw_printenv -c "$cfg" flag_boot_rootfs >/dev/null 2>"$err" ||
		{ rd16_fail "env unreadable"; return 1; }
	grep -qi 'bad crc' "$err" && { rd16_fail "env CRC bad"; return 1; }
	for kv in flag_boot_rootfs=1 flag_boot_success=1 \
		  flag_try_sys1_failed=0 flag_try_sys2_failed=0; do
		[ "$(fw_printenv -c "$cfg" -n "${kv%%=*}" 2>/dev/null)" = "${kv#*=}" ] ||
			{ rd16_fail "slot 1 not marked good ($kv expected, see rd16-slot status)"; return 1; }
	done
}

rd16_check_slot() {
	local cl

	[ "$(rd16_cat "$RD16_TMP/sysinfo/board_name")" = "$RD16_BOARD" ] ||
		{ rd16_fail "not a Xiaomi RD16"; return 1; }
	cl=" $(rd16_cat "$RD16_PROC/cmdline") "
	case "$cl" in
	*" ubi.mtd=rootfs "*) rd16_fail "booted from rootfs (stock slot)"; return 1 ;;
	*" ubi.mtd=rootfs_1 "*) ;;
	*) rd16_fail "not booted from slot 1 (ubi.mtd=rootfs_1)"; return 1 ;;
	esac
	rd16_check_layout && rd16_check_env
}

# Parse the tar headers ourselves: exactly the directory followed by CONTROL,
# kernel and root (any order), each once, plain ustar/gnu headers with a good
# checksum, then the end-of-archive blocks. tar(1) must list the same names.
# Sets RD16_{C,K,R}_{OFF,SIZE} (data offset/size in the image file).
rd16_tar_scan() {
	local f="$1" off=0 n=0 h nm typ sz ck list l
	local hd hc hk hr

	hd=$(rd16_strhex "$RD16_DIR/")
	hc=$(rd16_strhex "$RD16_DIR/CONTROL")
	hk=$(rd16_strhex "$RD16_DIR/kernel")
	hr=$(rd16_strhex "$RD16_DIR/root")
	RD16_C_OFF= RD16_K_OFF= RD16_R_OFF=
	RD16_C_SIZE= RD16_K_SIZE= RD16_R_SIZE=

	while :; do
		h=$(rd16_blk "$f" $((off / 512)))
		[ "${#h}" = 1024 ] || { rd16_fail "tar truncated"; return 1; }
		case "$h" in *[!0]*) ;; *) break ;; esac
		n=$((n + 1))
		[ "$n" -le 4 ] || { rd16_fail "unexpected extra tar member"; return 1; }
		[ "${h:514:10}" = 7573746172 ] || { rd16_fail "not a sysupgrade tar"; return 1; }
		ck=$(rd16_hoct "${h:296:16}") && [ "$ck" = "$(rd16_tar_sum "$h")" ] ||
			{ rd16_fail "tar header checksum"; return 1; }
		nm=$(rd16_hcstr "${h:0:200}") || { rd16_fail "tar member name"; return 1; }
		sz=$(rd16_hoct "${h:248:24}") || { rd16_fail "tar member size"; return 1; }
		typ="${h:312:2}"

		case "$nm" in
		"$hd")
			[ "$n" = 1 ] && [ "$typ" = 35 ] && [ "$sz" = 0 ] ||
				{ rd16_fail "bad $RD16_DIR/ entry"; return 1; }
			list="$RD16_DIR/"
			;;
		"$hc"|"$hk"|"$hr")
			[ "$n" -gt 1 ] && { [ "$typ" = 30 ] || [ "$typ" = 00 ]; } ||
				{ rd16_fail "tar member is not a regular file in $RD16_DIR/"; return 1; }
			[ "$sz" -gt 0 ] || { rd16_fail "empty tar member"; return 1; }
			case "$nm" in
			"$hc")
				[ -z "$RD16_C_OFF" ] || { rd16_fail "duplicate CONTROL"; return 1; }
				RD16_C_OFF=$((off + 512)) RD16_C_SIZE="$sz"
				l=CONTROL
				;;
			"$hk")
				[ -z "$RD16_K_OFF" ] || { rd16_fail "duplicate kernel"; return 1; }
				RD16_K_OFF=$((off + 512)) RD16_K_SIZE="$sz"
				l=kernel
				;;
			*)
				[ -z "$RD16_R_OFF" ] || { rd16_fail "duplicate root"; return 1; }
				RD16_R_OFF=$((off + 512)) RD16_R_SIZE="$sz"
				l=root
				;;
			esac
			list="$list
$RD16_DIR/$l"
			;;
		*)
			rd16_fail "unexpected tar member (not a $RD16_DIR sysupgrade image?)"
			return 1
			;;
		esac
		off=$((off + 512 + (sz + 511) / 512 * 512))
	done

	[ "$n" = 4 ] || { rd16_fail "tar must hold $RD16_DIR/{CONTROL,kernel,root}"; return 1; }
	h=$(rd16_blk "$f" $((off / 512 + 1)))
	[ "${#h}" = 1024 ] || { rd16_fail "tar truncated"; return 1; }
	case "$h" in *[!0]*) rd16_fail "bad end of tar archive"; return 1 ;; esac
	l=$(tar tf "$f" 2>/dev/null) && [ "$l" = "$list" ] ||
		{ rd16_fail "tar listing disagrees with the headers"; return 1; }
}

# CONTROL is "BOARD=<image profile>" (23 bytes "BOARD=glinet_gl-be3600\n"
# measured on the GL image, see platform.sh).
rd16_check_control() {
	local c

	[ "$RD16_C_SIZE" -le 4096 ] || { rd16_fail "CONTROL too big"; return 1; }
	c=$(tar xOf "$1" "$RD16_DIR/CONTROL" 2>/dev/null) || { rd16_fail "cannot read CONTROL"; return 1; }
	[ "$(printf '%s\n' "$c" | grep -c '^BOARD=')" = 1 ] &&
	printf '%s\n' "$c" | grep -qx 'BOARD=xiaomi_rd16' ||
		{ rd16_fail "CONTROL is not for xiaomi_rd16"; return 1; }
}

# <file> <offset> exact|max <len>: FDT header sanity; sets RD16_FDT_*.
rd16_fdt_header() {
	local h t rsv ver last

	h=$(rd16_hex "$1" "$2" 40)
	[ "${#h}" = 80 ] && [ "${h:0:8}" = d00dfeed ] || return 1
	t=$((0x${h:8:8}))
	RD16_FDT_SOFF=$((0x${h:16:8}))
	RD16_FDT_STROFF=$((0x${h:24:8}))
	rsv=$((0x${h:32:8}))
	ver=$((0x${h:40:8}))
	last=$((0x${h:48:8}))
	RD16_FDT_STRSZ=$((0x${h:64:8}))
	RD16_FDT_SSZ=$((0x${h:72:8}))
	case "$3" in
	exact) [ "$t" = "$4" ] || return 1 ;;
	*) [ "$t" -le "$4" ] || return 1 ;;
	esac
	[ "$ver" = 17 ] && [ "$last" = 16 ] &&
	[ "$rsv" -ge 40 ] && [ $((rsv % 8)) = 0 ] &&
	[ $((RD16_FDT_SOFF % 4)) = 0 ] && [ "$RD16_FDT_SOFF" -ge $((rsv + 16)) ] &&
	[ "$RD16_FDT_SSZ" -ge 8 ] && [ $((RD16_FDT_SOFF + RD16_FDT_SSZ)) -le "$t" ] &&
	[ $((RD16_FDT_STROFF + RD16_FDT_STRSZ)) -le "$t" ]
}

# <file> <fdt offset> <rootonly 0|1>: walk the structure block (bounded,
# with lseek over large values) using RD16_FDT_* and print
#   N <depth> <name hex>               node (root is depth 0)
#   P <owner depth> <name hex> <len> <value offset> <value hex, "-" if >128 B>
#   E <depth>                          end of node
#   END
# rootonly stops after the root node's own properties.
rd16_fdt_walk() {
	local f="$1" base="$2" p e depth=0 n=0 rs= h tok nm len noff v

	p=$((base + RD16_FDT_SOFF))
	e=$((p + RD16_FDT_SSZ))
	while [ "$p" -lt "$e" ]; do
		n=$((n + 1))
		[ "$n" -le 2048 ] || return 1
		h=$(rd16_hex "$f" "$p" 12)
		[ "${#h}" -ge 8 ] || return 1
		tok=$((0x${h:0:8}))
		case "$tok" in
		1)
			[ "$3" = 1 ] && [ "$depth" = 1 ] && { echo END; return 0; }
			nm=$(rd16_cstr "$f" $((p + 4)) 64) || return 1
			if [ "$depth" = 0 ]; then
				[ -z "$rs" ] && [ -z "$nm" ] || return 1
				rs=1
			else
				[ -n "$nm" ] || return 1
			fi
			echo "N $depth $nm"
			depth=$((depth + 1))
			p=$((p + 4 + (${#nm} / 2 + 4) / 4 * 4))
			;;
		2)
			[ "$depth" -gt 0 ] || return 1
			depth=$((depth - 1))
			echo "E $depth"
			[ "$3" = 1 ] && [ "$depth" = 0 ] && { echo END; return 0; }
			p=$((p + 4))
			;;
		3)
			[ "$depth" -gt 0 ] && [ "${#h}" = 24 ] || return 1
			len=$((0x${h:8:8}))
			noff=$((0x${h:16:8}))
			[ "$noff" -lt "$RD16_FDT_STRSZ" ] && [ $((p + 12 + len)) -le "$e" ] || return 1
			nm=$(rd16_cstr "$f" $((base + RD16_FDT_STROFF + noff)) 64) || return 1
			v=-
			[ "$len" -le 128 ] && v=$(rd16_hex "$f" $((p + 12)) "$len")
			echo "P $((depth - 1)) $nm $len $((p + 12)) $v"
			p=$((p + 12 + (len + 3) / 4 * 4))
			;;
		4)
			p=$((p + 4))
			;;
		9)
			[ "$depth" = 0 ] && [ -n "$rs" ] || return 1
			echo END
			return 0
			;;
		*)
			return 1
			;;
		esac
	done
	return 1
}

# <images list> <name hex>: "type comp len off" of the one image of that name
rd16_fit_image() {
	local e r= c=0

	for e in $1; do
		[ "${e%%:*}" = "$2" ] || continue
		c=$((c + 1))
		r="${e#*:}"
	done
	[ "$c" = 1 ] || return 1
	echo "${r//:/ }"
}

# <value hex>: hex of the value as a single NUL-terminated string
rd16_fdt_str() {
	local s
	s=$(rd16_hcstr "$1") && [ -n "$s" ] && [ "${s}00" = "$1" ] && echo "$s"
}

# <image> <data offset> <data len> <hash list> <label>: integrity of one FIT
# image's data (not authenticity). The list is "+algo=value" per hash-* node
# (hex, "-" if absent, "!" if a property is repeated). crc32 and unknown algos
# are ignored; at least one sha1/sha256 is required, each at most once, and
# every one must match the exact data bytes (streamed, never copied whole).
rd16_fit_hash() {
	local f="$1" o="$2" l="$3" hl="$4" e a v n tool s seen=

	for e in ${hl//+/ }; do
		[ "$e" = - ] && continue
		a=$(rd16_fdt_str "${e%%=*}") || { rd16_fail "FIT $5 has a malformed hash node"; return 1; }
		v="${e#*=}"
		case "$a" in  # rd16_fdt_str gives hex: "sha1", "sha256"
		73686131) a=sha1 tool=sha1sum n=40 ;;
		736861323536) a=sha256 tool=sha256sum n=64 ;;
		*) continue ;;
		esac
		case "$seen " in *" $a "*) rd16_fail "FIT $5 has more than one $a hash (ambiguous)"; return 1 ;; esac
		seen="$seen $a"
		[ "${#v}" = "$n" ] || { rd16_fail "FIT $5 $a hash value malformed"; return 1; }
		s=$(tail -c +$((o + 1)) "$f" 2>/dev/null | head -c "$l" | $tool)
		[ "${s%% *}" = "$v" ] || { rd16_fail "FIT $5 $a hash mismatch (data corrupt)"; return 1; }
	done
	[ -n "$seen" ] || { rd16_fail "FIT $5 has no sha1/sha256 hash"; return 1; }
}

# The kernel member is a FIT with embedded data (totalsize == member size)
# whose /configurations/config@mi04.1-c2 points at an lzma "kernel" image and
# a "flat_dt" image; that DTB's first compatible must be xiaomi,rd16. The data
# of both images must match their hash-* nodes (rd16_fit_hash).
rd16_check_fit() {  # <image> <member offset> <member size>
	local f="$1" o="$2" sz="$3" w="$RD16_TMP/rd16-fit.walk"
	local t d nm ln vo vh n1= n2= ityp= icomp= ilen= ioff= imgs= kref= fref= cfg=0
	local ihash= inh= halgo= hval= ha= hv= hd=
	local H_IMAGES H_CONFS H_CFG H_TYPE H_COMP H_DATA H_KERNEL H_FDT
	local H_HASH H_ALGO H_VALUE
	local kname fname klen koff khash doff dlen dhash compat

	[ "$sz" -ge 40 ] && rd16_fdt_header "$f" "$o" exact "$sz" ||
		{ rd16_fail "kernel is not a well-formed FIT (header/totalsize)"; return 1; }
	rd16_fdt_walk "$f" "$o" 0 > "$w" && [ "$(tail -n 1 "$w" 2>/dev/null)" = END ] ||
		{ rm -f "$w"; rd16_fail "FIT structure block invalid"; return 1; }

	H_IMAGES=$(rd16_strhex images)
	H_CONFS=$(rd16_strhex configurations)
	H_CFG=$(rd16_strhex "$RD16_FIT_CONFIG")
	H_TYPE=$(rd16_strhex type)
	H_COMP=$(rd16_strhex compression)
	H_DATA=$(rd16_strhex data)
	H_KERNEL=$(rd16_strhex kernel)
	H_FDT=$(rd16_strhex fdt)
	H_HASH=$(rd16_strhex hash)
	H_ALGO=$(rd16_strhex algo)
	H_VALUE=$(rd16_strhex value)

	while read -r t d nm ln vo vh; do
		case "$t" in
		N)
			[ "$d" = 1 ] && n1="$nm"
			if [ "$d" = 2 ]; then
				n2="$nm" ityp= icomp= ilen= ioff= ihash= inh=
				[ "$n1" = "$H_CONFS" ] && [ "$nm" = "$H_CFG" ] && cfg=$((cfg + 1))
			fi
			if [ "$d" = 3 ] && [ "$n1" = "$H_IMAGES" ]; then
				# same prefix test as U-Boot: hash-1, hash@1, ...
				case "$nm" in
				"$H_HASH"*) inh=1 halgo= hval= ha= hv= hd= ;;
				*) inh= ;;
				esac
			fi
			;;
		P)
			if [ "$d" = 3 ] && [ -n "$inh" ]; then
				case "$nm" in
				"$H_ALGO") [ -n "$ha" ] && hd=1; ha=1 halgo="$vh" ;;
				"$H_VALUE") [ -n "$hv" ] && hd=1; hv=1 hval="$vh" ;;
				esac
				continue
			fi
			[ "$d" = 2 ] || continue
			if [ "$n1" = "$H_IMAGES" ]; then
				case "$nm" in
				"$H_TYPE") ityp="$vh" ;;
				"$H_COMP") icomp="$vh" ;;
				"$H_DATA") [ -z "$ilen" ] && ilen="$ln" ioff="$vo" || ilen=-1 ;;  # repeated: refused
				esac
			elif [ "$n1" = "$H_CONFS" ] && [ "$n2" = "$H_CFG" ]; then
				case "$nm" in
				"$H_KERNEL") kref="$vh" ;;
				"$H_FDT") fref="$vh" ;;
				esac
			fi
			;;
		E)
			if [ "$d" = 3 ] && [ -n "$inh" ]; then
				[ -n "$hd" ] && halgo=!
				ihash="$ihash+${halgo:--}=${hval:--}"
				inh=
			fi
			[ "$d" = 2 ] && [ "$n1" = "$H_IMAGES" ] &&
				imgs="$imgs $n2:${ityp:--}:${icomp:--}:${ilen:-0}:${ioff:-0}:${ihash:--}"
			;;
		esac
	done < "$w"
	rm -f "$w"

	[ "$cfg" = 1 ] || { rd16_fail "FIT has no single /configurations/$RD16_FIT_CONFIG"; return 1; }
	kname=$(rd16_fdt_str "$kref") && fname=$(rd16_fdt_str "$fref") ||
		{ rd16_fail "$RD16_FIT_CONFIG lacks kernel/fdt"; return 1; }

	set -- $(rd16_fit_image "$imgs" "$kname")
	[ "$1" = "${H_KERNEL}00" ] && [ "$2" = "$(rd16_strhex lzma)00" ] && [ "${3:-0}" -gt 0 ] ||
		{ rd16_fail "FIT kernel image missing, not type kernel or not lzma"; return 1; }
	klen="$3" koff="$4" khash="$5"

	set -- $(rd16_fit_image "$imgs" "$fname")
	[ "$1" = "$(rd16_strhex flat_dt)00" ] && [ "$2" = "$(rd16_strhex none)00" ] &&
	[ "${3:-0}" -ge 40 ] ||
		{ rd16_fail "FIT fdt image missing, not flat_dt or compressed"; return 1; }
	dlen="$3" doff="$4" dhash="$5"

	rd16_fdt_header "$f" "$doff" max "$dlen" ||
		{ rd16_fail "FIT fdt is not a well-formed DTB"; return 1; }
	rd16_fdt_walk "$f" "$doff" 1 > "$w" && [ "$(tail -n 1 "$w" 2>/dev/null)" = END ] ||
		{ rm -f "$w"; rd16_fail "DTB structure block invalid"; return 1; }
	compat=$(awk -v c="$(rd16_strhex compatible)" '$1 == "P" && $2 == 0 && $3 == c { print $6 }' "$w")
	rm -f "$w"
	case "$compat" in
	"$(rd16_strhex "$RD16_BOARD")00"*) ;;
	*) rd16_fail "DTB in $RD16_FIT_CONFIG is not compatible $RD16_BOARD"; return 1 ;;
	esac
	rd16_fit_hash "$f" "$koff" "$klen" "$khash" kernel &&
	rd16_fit_hash "$f" "$doff" "$dlen" "$dhash" fdt
}

# squashfs 4.0 superblock: sizes and table offsets inside the member.
rd16_check_squashfs() {  # <image> <member offset> <member size>
	local sb bl x used o

	[ "$3" -ge 96 ] && sb=$(rd16_hex "$1" "$2" 96) &&
	[ "${#sb}" = 192 ] && [ "${sb:0:8}" = 68737173 ] ||
		{ rd16_fail "root is not squashfs"; return 1; }
	[ "$(rd16_le "$sb" 28 2)" = 0004 ] && [ "$(rd16_le "$sb" 30 2)" = 0000 ] ||
		{ rd16_fail "root is not squashfs 4.0"; return 1; }
	bl=$((0x$(rd16_le "$sb" 22 2)))
	[ "$bl" -ge 12 ] && [ "$bl" -le 20 ] &&
	[ $((0x$(rd16_le "$sb" 12 4))) = $((1 << bl)) ] ||
		{ rd16_fail "squashfs block size invalid"; return 1; }
	x=$((0x$(rd16_le "$sb" 20 2)))
	[ "$x" -ge 1 ] && [ "$x" -le 6 ] || { rd16_fail "squashfs compression invalid"; return 1; }
	[ $((0x$(rd16_le "$sb" 4 4))) -gt 0 ] || { rd16_fail "squashfs has no inodes"; return 1; }
	x=$(rd16_le "$sb" 40 8)
	case "$x" in [89a-f]*) rd16_fail "squashfs bytes_used invalid"; return 1 ;; esac
	used=$((0x$x))
	[ "$used" -gt 96 ] && [ "$used" -le "$3" ] ||
		{ rd16_fail "squashfs bytes_used $used outside member ($3 B): truncated?"; return 1; }
	for o in 48 64 72; do  # id, inode and directory tables
		x=$(rd16_le "$sb" "$o" 8)
		case "$x" in [89a-f]*) rd16_fail "squashfs table offset invalid"; return 1 ;; esac
		[ $((0x$x)) -ge 96 ] && [ $((0x$x)) -lt "$used" ] ||
			{ rd16_fail "squashfs table offset outside image"; return 1; }
	done
}

# Read-only checks shared by preflight and stage2.
rd16_verify_common() {  # <image>
	local img="$1" n

	[ -f "$img" ] || { rd16_fail "image not found"; return 1; }
	case "$(rd16_hex "$img" 0 4)" in
	d00dfeed) rd16_fail "FIT (factory?) image: use the sysupgrade tar"; return 1 ;;
	55424923) rd16_fail "UBI image: use the sysupgrade tar"; return 1 ;;
	1f8b*) rd16_fail "compressed image: use the sysupgrade tar"; return 1 ;;
	esac
	rd16_check_slot || return 1
	rd16_tar_scan "$img" || return 1
	rd16_check_control "$img" || return 1
	[ "$RD16_K_SIZE" -le $((RD16_KERNEL_LEBS * RD16_LEB)) ] ||
		{ rd16_fail "kernel $RD16_K_SIZE B > $RD16_KERNEL_LEBS LEBs"; return 1; }
	[ "$RD16_R_SIZE" -le $((RD16_ROOT_LEBS * RD16_LEB)) ] ||
		{ rd16_fail "root $RD16_R_SIZE B > $RD16_ROOT_LEBS LEBs"; return 1; }
	rd16_check_fit "$img" "$RD16_K_OFF" "$RD16_K_SIZE" || return 1
	rd16_check_squashfs "$img" "$RD16_R_OFF" "$RD16_R_SIZE" || return 1
	# The writer streams through tar: it must yield the same lengths.
	n=$(tar xOf "$img" "$RD16_DIR/kernel" 2>/dev/null | wc -c)
	[ "$((n))" = "$RD16_K_SIZE" ] || { rd16_fail "kernel unreadable through tar"; return 1; }
	n=$(tar xOf "$img" "$RD16_DIR/root" 2>/dev/null | wc -c)
	[ "$((n))" = "$RD16_R_SIZE" ] || { rd16_fail "root unreadable through tar"; return 1; }
}

rd16_image_id() {  # <image>: "<sha256> <size>"
	local s n

	s=$(sha256sum < "$1" 2>/dev/null) || return 1
	s="${s%% *}"
	n=$(wc -c < "$1") || return 1
	[ "${#s}" = 64 ] || return 1
	echo "$s $((n))"
}

rd16_member_sum() {  # <image> <member>
	local s

	s=$(tar xOf "$1" "$RD16_DIR/$2" 2>/dev/null | sha256sum)
	s="${s%% *}"
	[ "${#s}" = 64 ] && echo "$s"
}

# Preflight (platform_check_image). Read-only for flash and env. On success
# it records the image hash; stage2 refuses any image without that record,
# so "sysupgrade -F" / LuCI "Force" cannot skip these checks.
rd16_verify_image() {  # <image>
	local img="$1" id

	rm -f "$RD16_TOKEN"
	[ "$#" = 1 ] || return 1
	rd16_need tar dd hexdump tail head wc awk grep sha1sum sha256sum fw_printenv || return 1
	type fwtool_check_image >/dev/null 2>&1 ||
		{ rd16_fail "fwtool_check_image unavailable"; return 1; }
	fwtool_check_image "$img" ||
		{ rd16_fail "image metadata missing or not for $RD16_BOARD"; return 1; }
	rd16_verify_common "$img" || return 1
	id=$(rd16_image_id "$img") || { rd16_fail "cannot hash image"; return 1; }
	echo "$RD16_BOARD $id" > "$RD16_TOKEN.new" && mv "$RD16_TOKEN.new" "$RD16_TOKEN" ||
		{ rm -f "$RD16_TOKEN.new"; rd16_fail "cannot record verification"; return 1; }
	echo "rd16: image passed structure/board/FIT hash checks (integrity, not authenticity)"
}

rd16_check_unmounted() {
	local dev mp fs rest

	[ -r "$RD16_PROC/mounts" ] || { rd16_fail "cannot read mounts"; return 1; }
	while read -r dev mp fs rest; do
		case "$dev" in
		/dev/ubi0|/dev/ubi0_*|/dev/ubiblock0_*|ubi0:*|ubi0_*)
			rd16_fail "$dev still mounted on $mp"; return 1 ;;
		esac
		case "$mp" in
		/overlay|/rom)
			rd16_fail "$mp still mounted"; return 1 ;;
		/)
			case "$fs" in
			squashfs|overlay|ubifs) rd16_fail "root filesystem still on flash ($fs)"; return 1 ;;
			esac
			;;
		esac
	done < "$RD16_PROC/mounts"
}

rd16_block_present() {
	[ -e "$RD16_BLOCK_SYS/ubiblock0_1" ] || [ -L "$RD16_BLOCK_SYS/ubiblock0_1" ]
}

# Remove ubiblock0_1 on ubi0_1. The kernel (sysfs) decides: in stage2 udev and
# hotplug are gone, so /dev/ubiblock0_1 can stay behind as a stale node after
# a successful ubiblock -r (seen on hardware). A stale node is not refused; a
# sysfs entry still there after RD16_BLOCK_WAIT seconds is.
rd16_release_block() {
	local i=0 rc=0

	[ -d "$RD16_BLOCK_SYS" ] && [ -r "$RD16_BLOCK_SYS" ] && [ -x "$RD16_BLOCK_SYS" ] ||
		{ rd16_fail "block sysfs directory unavailable: $RD16_BLOCK_SYS"; return 1; }

	if [ -e "$RD16_DEV/ubiblock0_1" ] || rd16_block_present; then
		ubiblock -r "$RD16_DEV/ubi0_1" || rc=$?
	fi
	while rd16_block_present; do
		[ "$i" -lt "$RD16_BLOCK_WAIT" ] ||
			{ rd16_fail "ubiblock0_1 still in $RD16_BLOCK_SYS after ubiblock -r (rc $rc)"; return 1; }
		sleep 1
		i=$((i + 1))
	done
	[ "$rc" = 0 ] || echo "rd16: ubiblock -r returned $rc, but ubiblock0_1 is gone from $RD16_BLOCK_SYS"
	[ ! -e "$RD16_DEV/ubiblock0_1" ] ||
		echo "rd16: stale $RD16_DEV/ubiblock0_1 node left (no udev in stage2), kernel device is gone"
	rd16_check_unmounted
}

rd16_write() {  # <image> <vol id> <member> <size> <sha256>
	local dev="$RD16_DEV/ubi0_$2" d="$RD16_SYS/ubi0_$2" s

	tar xOf "$1" "$RD16_DIR/$3" | ubiupdatevol "$dev" -s "$4" - ||
		{ rd16_fail "writing $3 to ubi0_$2 failed"; return 1; }
	[ "$(rd16_cat "$d/upd_marker")" = 0 ] ||
		{ rd16_fail "ubi0_$2 update marker still set"; return 1; }
	if [ "$(rd16_cat "$d/type")" = static ]; then
		[ "$(rd16_cat "$d/data_bytes")" = "$4" ] && [ "$(rd16_cat "$d/corrupted")" = 0 ] ||
			{ rd16_fail "ubi0_$2 static volume size/CRC wrong after write"; return 1; }
	fi
	s=$(head -c "$4" "$dev" | sha256sum)
	[ "${s%% *}" = "$5" ] || { rd16_fail "ubi0_$2 readback mismatch"; return 1; }
}

# Stage2 (platform_do_upgrade), running from the ramfs. Repeats every
# read-only check, then writes root, kernel, empties rootfs_data and puts the
# saved config back through the existing NAND path (nand_restore_config).
rd16_do_upgrade() {  # <image>
	local img="$1" ksum rsum n

	rd16_need tar dd hexdump tail wc awk grep sha1sum sha256sum head gzip fw_printenv \
		ubiupdatevol ubiblock sleep || return 1
	rd16_verify_common "$img" || return 1
	[ "$(rd16_cat "$RD16_TOKEN")" = "$RD16_BOARD $(rd16_image_id "$img")" ] ||
		{ rd16_fail "image not accepted by rd16_verify_image (forced?), refusing"; return 1; }
	if [ -n "$UPGRADE_BACKUP" ]; then
		[ -s "$UPGRADE_BACKUP" ] && gzip -t "$UPGRADE_BACKUP" 2>/dev/null ||
			{ rd16_fail "config backup $UPGRADE_BACKUP missing or corrupt"; return 1; }
		n=$(wc -c < "$UPGRADE_BACKUP")
		[ "$((n))" -le $((RD16_DATA_LEBS * RD16_LEB / 2)) ] ||
			{ rd16_fail "config backup too big for rootfs_data"; return 1; }
		type nand_restore_config >/dev/null 2>&1 &&
		grep -qw ubifs "$RD16_PROC/filesystems" 2>/dev/null ||
			{ rd16_fail "config backup cannot be restored (no ubifs/nand_restore_config)"; return 1; }
	fi
	rd16_check_unmounted || return 1

	[ "$RD16_UPGRADE_ENABLED" = 1 ] ||
		{ rd16_fail "flash writing disabled in this build (RD16_UPGRADE_ENABLED=0), nothing written"; return 1; }

	ksum=$(rd16_member_sum "$img" kernel) && rsum=$(rd16_member_sum "$img" root) ||
		{ rd16_fail "cannot hash image members"; return 1; }
	rd16_release_block || { rd16_fail "ubiblock0_1 not released, nothing written"; return 1; }

	# ---- flash writes start here ----
	rd16_write "$img" 1 root "$RD16_R_SIZE" "$rsum" ||
		{ rd16_fail "SLOT 1 ROOT MAY BE DAMAGED"; return 1; }
	rd16_write "$img" 0 kernel "$RD16_K_SIZE" "$ksum" ||
		{ rd16_fail "SLOT 1 INCONSISTENT: new root, kernel write failed"; return 1; }
	ubiupdatevol -t "$RD16_DEV/ubi0_2" ||
		{ rd16_fail "firmware written but old rootfs_data not cleared"; return 1; }
	rd16_check_layout || { rd16_fail "UBI layout changed during upgrade"; return 1; }
	if [ -n "$UPGRADE_BACKUP" ]; then
		CI_UBIPART=rootfs_1
		nand_restore_config "$UPGRADE_BACKUP" ||
			{ rd16_fail "firmware written, config NOT restored (defaults will boot)"; return 1; }
	fi
	sync
	echo "rd16: slot 1 written and read back"
}
