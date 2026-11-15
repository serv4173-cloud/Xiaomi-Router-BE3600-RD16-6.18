#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Duplicate one FIT configuration node under a second name, so that a single
# kernel/fdt pair is reachable as both config names (Xiaomi RD16: which of
# config@1 or config@mi04.1-c2 the stock U-Boot asks for is not proven).
#
#   rd16-fit-alt-config.sh ITS_FILE SRC_CONFIG ALT_CONFIG
#
# Run between Build/fit-its and Build/fit-image. The default = property is
# left unchanged. Fails if SRC is missing or ALT already exists.
set -eu
its=${1:?ITS_FILE}
src=${2:?SRC_CONFIG}
alt=${3:?ALT_CONFIG}

[ -f "$its" ] || { echo "rd16-fit-alt: no such file: $its" >&2; exit 1; }
if grep -qF "$alt {" "$its"; then
	echo "rd16-fit-alt: $alt already present" >&2
	exit 1
fi

awk -v src="$src" -v alt="$alt" '
$1 == src && $2 == "{" && !done { inb = 1; buf = $0 "\n"; next }
inb {
	buf = buf $0 "\n"
	if ($0 ~ /^[ \t]*};[ \t]*$/) {
		inb = 0; done = 1
		i = index(buf, src)
		printf "%s", buf
		printf "\n%s%s%s", substr(buf, 1, i - 1), alt, substr(buf, i + length(src))
	}
	next
}
{ print }
END { if (!done) exit 2 }
' "$its" > "$its.alt" || { rm -f "$its.alt"; echo "rd16-fit-alt: config $src not found in $its" >&2; exit 1; }

mv "$its.alt" "$its"
grep -qF "$src {" "$its" && grep -qF "$alt {" "$its" || { echo "rd16-fit-alt: verification failed" >&2; exit 1; }
echo "rd16-fit-alt: $alt added as copy of $src"
