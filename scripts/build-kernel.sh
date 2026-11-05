#!/bin/bash
# Build a FydeOS v23 (chromeos-6.12.54) kernel with the MateBook E DSI patches.
#
# Usage: ./scripts/build-kernel.sh [--out DIR] [--jobs N] [--localversion SUFFIX]
#
# Requirements (Debian/Ubuntu): build-essential bc bison flex libssl-dev libelf-dev
#                               python3 patch curl xz-utils kmod
# Disk: ~8 GB.  Time: ~40-90 min on 4 cores.

set -euo pipefail

KERNEL_COMMIT="${KERNEL_COMMIT:-b4e10020ba49ded48a0e34144c5eb2fbc813cc2b}"
KERNEL_BRANCH="${KERNEL_BRANCH:-chromeos-6.12}"
SRC_URL="https://chromium.googlesource.com/chromiumos/third_party/kernel/+archive/${KERNEL_COMMIT}.tar.gz"

# Deliberately different from the stock "-01180-gb4e10020ba49-dirty": the
# modules must land in their own /lib/modules directory so a half-finished
# install can never overwrite the stock tree (that is what broke the first two
# install attempts on the target machine).
LOCALVERSION_DEFAULT="-01180-gb4e10020ba49-mbe"

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

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

WORK="$OUT/work"
TARBALL="$OUT/kernel-$KERNEL_COMMIT.tar.gz"
mkdir -p "$WORK"

log()  { printf '\n=== %s ===\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

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

apply_patch() {
	if ! patch -d "$SRC" -p1 --forward --no-backup-if-mismatch < "$1"; then
		fail "$(basename "$1") failed to apply"
	fi
}

log "openFyde patches"
for p in "$ROOT"/openfyde-patches/*.patch; do
	log "  $(basename "$p")"
	apply_patch "$p"
done

log "FydeOS subsystem + i915 patches"
for p in "$ROOT"/patches/*.patch; do
	log "  $(basename "$p")"
	apply_patch "$p"
done

if [ -n "$(find "$SRC" \( -name '*.rej' -o -name '*.orig' \) -print -quit)" ]; then
	fail "patch left rejects behind:
$(find "$SRC" \( -name '*.rej' -o -name '*.orig' \))"
fi

grep -q dsi_native_gpio_bypass "$SRC/drivers/gpu/drm/i915/display/intel_dsi_vbt.c" \
	|| fail "patch 0001 not applied"
grep -q 'DMI_PRODUCT_NAME, "DRC-WXX"' "$SRC/drivers/gpu/drm/i915/display/intel_dsi_vbt.c" \
	|| fail "patch 0001 DMI table is missing DRC-WXX (MateBook E 2022 product name)"
grep -q 'DSB not used for DSI' "$SRC/drivers/gpu/drm/i915/display/intel_dsb.c" \
	|| fail "patch 0002 not applied"
# The Android container mounts bpffs from inside an unprivileged user namespace;
# with upstream's capable(CAP_SYS_ADMIN) that mount fails with EPERM and run_oci
# aborts (MINIJAIL_ERR_MOUNT, status 251), so ARC never starts.
grep -q 'ns_capable(fc->user_ns, CAP_SYS_ADMIN)' "$SRC/kernel/bpf/inode.c" \
	|| fail "patch 0009 not applied (bpffs mount would fail inside the ARC user namespace)"

# --- config ------------------------------------------------------------------
# The stock FydeOS config is the only trustworthy baseline: the running system's
# userspace (Android container, fsmount, quota2 netfilter rules, esdfs mounts)
# depends on it, and a merged-together approximation loses ~450 symbols.
log "configure from the stock FydeOS config"
"$SRC/scripts/kconfig/merge_config.sh" -m -O "$SRC" \
	"$ROOT/config/fydeos-official-iris.config" \
	"$ROOT/config/overrides.config" >/dev/null

make -C "$SRC" olddefconfig

CFG="$SRC/.config"
cfg_val() { sed -n "s/^$1=//p" "$CFG"; }

log "verify ported subsystems survived olddefconfig"
MISSING=0
for sym in \
	CONFIG_ARCH_HAS_ALT_SYSCALL CONFIG_ALT_SYSCALL CONFIG_ALT_SYSCALL_CHROMIUMOS \
	CONFIG_ASHMEM CONFIG_ESD_FS \
	CONFIG_NETFILTER_XT_MATCH_QUOTA2 CONFIG_NETFILTER_XT_MATCH_QUOTA2_LOG \
	CONFIG_UID_SYS_STATS CONFIG_UID_SYS_STATS_DEBUG
do
	if [ "$(cfg_val "$sym")" != "y" ]; then
		echo "  $sym is not 'y' -> '$(cfg_val "$sym")'" >&2
		MISSING=1
	fi
done
[ "$MISSING" = 0 ] || fail "a ported subsystem was dropped by kconfig; see the patches in patches/"

log "verify settings the running system depends on"
for expect in \
	CONFIG_DRM_I915=m CONFIG_IWLWIFI=m CONFIG_SQUASHFS_XZ=y CONFIG_PKGLIST=y \
	CONFIG_USER_NS=y CONFIG_PROFILING=y CONFIG_TASK_XACCT=y \
	CONFIG_TASK_IO_ACCOUNTING=y CONFIG_IA32_EMULATION=y CONFIG_SMP=y \
	CONFIG_PREEMPT_BUILD=y CONFIG_MODULE_UNLOAD=y CONFIG_MITIGATION_RETPOLINE=y \
	CONFIG_SECURITY_CHROMIUMOS=y CONFIG_IKCONFIG=y CONFIG_IKCONFIG_PROC=y \
	CONFIG_DEBUG_INFO_NONE=y
do
	sym="${expect%%=*}"
	want="${expect#*=}"
	got="$(cfg_val "$sym")"
	[ "$got" = "$want" ] || fail "$sym is '$got', expected '$want'"
done
for sym in CONFIG_MODULE_SIG CONFIG_MODVERSIONS CONFIG_MODULE_COMPRESS \
	   CONFIG_MODULE_DECOMPRESS CONFIG_WERROR CONFIG_LOCALVERSION_AUTO \
	   CONFIG_DEBUG_INFO CONFIG_DEBUG_INFO_DWARF5 CONFIG_DEBUG_INFO_BTF
do
	[ -z "$(cfg_val "$sym")" ] || fail "$sym must stay unset, but is '$(cfg_val "$sym")'"
done

# Everything the stock kernel had built in or as a module should still be built,
# otherwise userspace (which is compiled against the stock kernel) breaks.
# Differences are reported; they come from the CI toolchain differing from
# ChromiumOS clang 21, not from a broken base config.
log "diff against the stock config"
stock_syms() { sed -n 's/^\(CONFIG_[A-Za-z0-9_]*\)=[ym]$/\1/p' "$1" | sort -u; }
cfg_syms()   { sed -n 's/^\(CONFIG_[A-Za-z0-9_]*\)=[ym]$/\1/p' "$1" | sort -u; }

# Exempt groups:
#  * toolchain capability symbols (CC_IS_*, CLANG_VERSION, ...) are re-probed on
#    every build and legitimately differ between ChromiumOS clang 21 and CI's gcc;
#  * DEBUG_INFO and everything under it (`if DEBUG_INFO` in lib/Kconfig.debug),
#    plus GDB_SCRIPTS, disappear with CONFIG_DEBUG_INFO_NONE on purpose;
#  * HAS_LTO_CLANG needs CC_IS_CLANG, and FTRACE_MCOUNT_USE_OBJTOOL yields to
#    FTRACE_MCOUNT_USE_CC when the compiler supports -mrecord-mcount (gcc does).
#    Both are build-mechanism choices with no ABI effect.
#  * KVM_WERROR is selected by WERROR, which we turn off on purpose (see
#    config/overrides.config); it only adds -Werror to arch/x86/kvm.
#  A second group is toolchain-gated in a way the regex cannot see (e.g. a
#  =y dependency on something only clang selects): the build prints what it
#  lost, and BUILD_STRICT=1 turns that warning into a failure.
EXEMPT_RE='^CONFIG_(CC_|GCC_|CLANG_|LD_|AS_|RUSTC_|PAHOLE_|HAVE_|ARCH_HAS_|TOOLS_|CC_VERSION|LD_VERSION|CLANG_VERSION|GCC_VERSION|LOCALVERSION|BUILD_SALT|RUST)'
EXEMPT_RE="$EXEMPT_RE"'|^CONFIG_DEBUG_INFO(_[A-Z0-9_]+)?$|^CONFIG_GDB_SCRIPTS$|^CONFIG_WERROR$'
EXEMPT_RE="$EXEMPT_RE"'|^CONFIG_HAS_LTO_CLANG$|^CONFIG_FTRACE_MCOUNT_USE_OBJTOOL$|^CONFIG_KVM_WERROR$'
LOST="$(comm -23 <(stock_syms "$ROOT/config/fydeos-official-iris.config") <(cfg_syms "$CFG") \
	| grep -Ev "$EXEMPT_RE" || true)"
LOST_COUNT="$(printf '%s\n' "$LOST" | grep -c . || true)"
if [ "${LOST_COUNT:-0}" -gt 0 ]; then
	echo "WARNING: $LOST_COUNT stock symbol(s) are no longer built:" >&2
	printf '%s\n' "$LOST" | head -60 >&2
	if [ "${BUILD_STRICT:-0}" = 1 ]; then
		fail "BUILD_STRICT=1 and $LOST_COUNT stock symbol(s) disappeared"
	fi
	echo "WARNING: continuing; set BUILD_STRICT=1 to make this fatal" >&2
fi

KREL="$(make -s -C "$SRC" kernelrelease)"
log "kernelrelease: $KREL"

# A mismatched UTS_RELEASE silently produces modules that no FydeOS install will
# pick up, so fail here instead of after a 60 minute build.
[ "$KREL" = "$KVER$SUFFIX" ] || fail "kernelrelease '$KREL' != expected '$KVER$SUFFIX'"

log "build ($JOBS jobs)"
make -C "$SRC" -j"$JOBS" bzImage modules

# --- artifacts ---------------------------------------------------------------
log "stage artifacts"
rm -rf "$OUT/artifacts"
mkdir -p "$OUT/artifacts/modules"

cp "$SRC/arch/x86/boot/bzImage" "$OUT/artifacts/vmlinuz-$KREL"
cp "$CFG" "$OUT/artifacts/config-$KREL"

# No INSTALL_MOD_STRIP: the stock modules are not stripped either, and dropping
# .symtab would break anything that walks module symbols.
make -C "$SRC" INSTALL_MOD_PATH="$OUT/artifacts/modules" modules_install

# The top level of the tarball must be lib/modules/<release>, because the
# install instructions untar it at "/".
tar -czf "$OUT/artifacts/modules-$KREL.tar.gz" -C "$OUT/artifacts/modules" lib/modules

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
