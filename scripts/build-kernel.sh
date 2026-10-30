#!/bin/bash
# Build a FydeOS v23 (chromeos-6.12.54) kernel with the MateBook E DSI patches.
#
# Usage: ./scripts/build-kernel.sh [--out DIR] [--jobs N] [--localversion SUFFIX]
#
# Requirements (Debian/Ubuntu): build-essential bc bison flex libssl-dev libelf-dev
#                               python3 patch curl xz-utils
# Disk: ~12 GB.  Time: ~40-90 min on 4 cores.

set -euo pipefail

KERNEL_COMMIT="${KERNEL_COMMIT:-b4e10020ba49ded48a0e34144c5eb2fbc813cc2b}"
KERNEL_BRANCH="${KERNEL_BRANCH:-chromeos-6.12}"
SRC_URL="https://chromium.googlesource.com/chromiumos/third_party/kernel/+archive/${KERNEL_COMMIT}.tar.gz"
LOCALVERSION_DEFAULT="-01180-gb4e10020ba49-dirty"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/out"
JOBS="$(nproc)"
SUFFIX="$LOCALVERSION_DEFAULT"

# A variable named LOCALVERSION in the environment would be picked up by
# scripts/setlocalversion and appended *in addition* to what we put in the
# localversion-* file, doubling the suffix. Own the name exclusively.
unset LOCALVERSION

while [ $# -gt 0 ]; do
	case "$1" in
	--out)          OUT="$2"; shift 2 ;;
	--jobs)         JOBS="$2"; shift 2 ;;
	--localversion) SUFFIX="$2"; shift 2 ;;
	*) echo "unknown argument: $1" >&2; exit 1 ;;
	esac
done

# Absolute paths: the config merge runs from inside the kernel tree.
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

WORK="$OUT/work"
TARBALL="$OUT/kernel-$KERNEL_COMMIT.tar.gz"
mkdir -p "$WORK"

log() { printf '\n=== %s ===\n' "$*"; }

log "fetch $KERNEL_BRANCH @ $KERNEL_COMMIT"
if [ ! -s "$TARBALL" ]; then
	curl -fL --retry 5 --retry-delay 5 -o "$TARBALL.part" "$SRC_URL"
	mv "$TARBALL.part" "$TARBALL"
fi
ls -l "$TARBALL"

log "unpack"
rm -rf "$WORK/linux"
mkdir -p "$WORK/linux"
tar -xzf "$TARBALL" -C "$WORK/linux"
SRC="$WORK/linux"

KVER="$(make -s -C "$SRC" kernelversion)"
log "source version: $KVER"

# The release suffix goes into a localversion-* file rather than a
# CONFIG_LOCALVERSION fragment: setlocalversion reads CONFIG_LOCALVERSION out of
# include/config/auto.conf with a plain sed and concatenates it verbatim, so the
# value depends on how kconfig re-serialises the string. collect_files() just
# cats the file, which is one moving part fewer.
printf '%s\n' "$SUFFIX" > "$SRC/localversion-fyde"

# --- openFyde kernel patches (the subset that still applies to 6.12) ----------
for p in "$ROOT"/openfyde-patches/*.patch; do
	log "openfyde: $(basename "$p")"
	if ! patch -d "$SRC" -p1 --forward --no-backup-if-mismatch < "$p"; then
		echo "ERROR: $(basename "$p") failed to apply; see openfyde-patches/README.md" >&2
		exit 1
	fi
done

# --- our patches -------------------------------------------------------------
for p in "$ROOT"/patches/*.patch; do
	log "patch: $(basename "$p")"
	patch -d "$SRC" -p1 --forward --no-backup-if-mismatch < "$p"
done

if [ -n "$(find "$SRC" -name '*.rej' -o -name '*.orig' -print -quit)" ]; then
	echo "ERROR: patch left rejects behind:" >&2
	find "$SRC" -name '*.rej' -o -name '*.orig' >&2
	exit 1
fi

# --- config ------------------------------------------------------------------
log "merge config"
CHROMEOS_FRAGMENTS=(
	chromeos/config/chromeos/base.config
	chromeos/config/chromeos/x86_64/common.config
	chromeos/config/chromeos/x86_64/chromiumos-x86_64-generic.flavour.config
)
FRAGDIR="$WORK/fragments"
mkdir -p "$FRAGDIR"
for f in "${CHROMEOS_FRAGMENTS[@]}"; do
	cp "$SRC/$f" "$FRAGDIR/$(basename "$f")"
done

printf '# CONFIG_LOCALVERSION is not set\n# CONFIG_LOCALVERSION_AUTO is not set\n' > "$FRAGDIR/10-localversion.config"

(
	cd "$SRC"
	KCONFIG_CONFIG="$SRC/.config" scripts/kconfig/merge_config.sh -m \
		"$FRAGDIR/base.config" \
		"$FRAGDIR/common.config" \
		"$FRAGDIR/chromiumos-x86_64-generic.flavour.config" \
		"$ROOT/config/openfyde-6.6-def-r2.config" \
		"$FRAGDIR/10-localversion.config" \
		"$ROOT/config/hardening.config"
)
make -C "$SRC" olddefconfig

KREL="$(make -s -C "$SRC" kernelrelease)"
log "kernelrelease: $KREL"

# A mismatched UTS_RELEASE silently produces modules that no FydeOS install will
# pick up, so fail here instead of after a 60 minute build.
if [ "$KREL" != "$KVER$SUFFIX" ]; then
	echo "ERROR: kernelrelease '$KREL' != expected '$KVER$SUFFIX'" >&2
	exit 1
fi

log "build ($JOBS jobs)"
make -C "$SRC" -j"$JOBS" bzImage modules

# --- artifacts ---------------------------------------------------------------
log "stage artifacts"
rm -rf "$OUT/artifacts"
mkdir -p "$OUT/artifacts/modules"

cp "$SRC/arch/x86/boot/bzImage" "$OUT/artifacts/vmlinuz-$KREL"
cp "$SRC/.config" "$OUT/artifacts/config-$KREL"

make -C "$SRC" INSTALL_MOD_PATH="$OUT/artifacts/modules" INSTALL_MOD_STRIP=1 modules_install
( cd "$OUT/artifacts/modules/lib/modules" && tar -czf "$OUT/artifacts/modules-$KREL.tar.gz" "$KREL" )

I915_KO="$(find "$OUT/artifacts/modules/lib/modules/$KREL" -name 'i915.ko*' | head -1)"
if [ -n "$I915_KO" ]; then
	cp "$I915_KO" "$OUT/artifacts/i915.ko"
	if command -v modinfo >/dev/null 2>&1; then
		modinfo -F vermagic "$OUT/artifacts/i915.ko" | tee "$OUT/artifacts/i915.vermagic"
	fi
else
	echo "WARNING: i915.ko not found (CONFIG_DRM_I915 != m?)" >&2
fi

# Only the top-level regular files: artifacts/ also holds the modules/ staging
# tree, which sha256sum refuses to hash. The sums file itself is excluded.
(
	cd "$OUT/artifacts"
	find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\0' \
		| sort -z | xargs -0 sha256sum > SHA256SUMS
)

log "done"
ls -lh "$OUT/artifacts"
