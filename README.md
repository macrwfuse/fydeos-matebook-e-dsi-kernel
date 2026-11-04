# fydeos-matebook-e-dsi-kernel

Patch set and GitHub Actions build for a **FydeOS v23 (chromeos-6.12.54)** kernel that
fixes the torn / horizontally split screen on the **HUAWEI MateBook E 2022 / MateBook E Go**
(Tiger Lake, dual-link DSI panel).

Everything here is built by CI — no local toolchain required.

---

## 1. Symptom

On FydeOS (or any Linux with i915 >= 6.1.5) the built-in display shows the desktop
**split into two halves that are horizontally offset**, or flickers/tears. External
monitors are fine, `nomodeset` avoids it (but leaves you at ~1 FPS without i915), and
`i915.enable_psr/fbc/dc=0` does **not** help.

## 2. Root cause

Upstream i915 issue: <https://gitlab.freedesktop.org/drm/i915/kernel/-/issues/8992>

Two independent commits break this machine:

| Introduced in | Commit | Effect on this panel |
|---|---|---|
| 6.1.5 | `f087cfe6fcff` / ChromeOS `c7229577d93d` — *drm/i915/dsi: add support for ICL+ native MIPI GPIO sequence* | Torn / split image |
| 6.13 | `45c548642b56` — *drm/i915/dsb: Use DSB for plane/color management updates* | Display stops working entirely |

The panel's VBT packs `DEASSERT_RESET + INIT_OTP + DISPLAY_ON` into a single `INIT_OTP`
sequence (Ville Syrjälä called it "half nonsense"). Before `f087cfe6fcff` i915 never
touched the DSI GPIOs and relied on the state the firmware left behind — which happens to
work. Since then the native GPIO sequence runs on ICL+ and flips HPD / PP_CONTROL behind
the firmware's back, desynchronising the panel from its pipe.

All ChromeOS kernel branches FydeOS could pick (`chromeos-5.15`, `6.1`, `6.6`, `6.12`)
contain that code, and the issue has no assignee upstream. Patching is the only option.

## 3. The patches

### 3.1 The display fix

| File | Applies to | What it does |
|---|---|---|
| `patches/0001-drm-i915-dsi-skip-native-mipi-gpio-on-huawei-matebook-e.patch` | 6.1 … 6.12+ | DMI-matches HUAWEI `MateBook E*` and skips the native MIPI GPIO sequence, keeping the firmware-programmed panel state. Also exposes `i915.dsi_native_gpio_bypass={-1,0,1}` so you can force it on/off or test other machines. |
| `patches/0002-drm-i915-dsb-do-not-use-dsb-for-dsi-outputs.patch` | 6.12+ only | Makes `intel_dsb_prepare()` bail out for CRTCs driven by a DSI output, so plane/color updates fall back to MMIO. No effect on 6.1/6.6 builds, where the DSB path does not exist. |

**Measured on the target machine: patch 2 is not required.** Booting the *stock* kernel
with `i915.enable_dsb=0` (no disk writes) leaves the tearing exactly as it was, so on this
6.12.54 tree the DSB path does not take part in the corruption — only the native MIPI GPIO
sequence does. Patch 2 is kept as a safeguard for 6.13+ trees (where plane updates moved
into DSB and the display goes fully black) and for other panels; on this one it is a
harmless no-op.

Known trade-offs (documented upstream by Jani Nikula and Amer):

* Skipping the GPIOs relies on the firmware having powered the panel. **Waking from
  suspend may leave the screen dark.** If that is unacceptable, do not use this kernel.
* Disabling DSB for DSI costs a little CPU in the commit path. Nothing else.

### 3.2 ChromiumOS subsystems the FydeOS userspace needs

The stock FydeOS v23 config enables nine symbols that have no Kconfig entry in the
chromeos-6.12 source tree. They come from the ChromiumOS 5.4 / 6.6 trees and are what
the FydeOS userspace was compiled against, so a kernel built from a plain 6.12 tree
boots but loses Android containers, ARC mounts and the quota2 firewall rules. They are
re-implemented here rather than dropped:

| File | Symbols it provides | What the running system uses it for |
|---|---|---|
| `patches/0003-chromeos-alt-syscall.patch` | `ARCH_HAS_ALT_SYSCALL`, `ALT_SYSCALL`, `ALT_SYSCALL_CHROMIUMOS` | Alternate syscall table selected per process via `prctl()`; the Android container and Chrome's sandbox set it up. Also restores the enlarged `thread_info` (`sys_call_table` / `ia32_sys_call_table` pointers) that makes `task_struct` match the stock ABI. |
| `patches/0004-task-io-accounting-syscfs.patch` | (adds `u64 syscfs` to `task_io_accounting`) | `vfs_fsync` accounting exposed through `/proc/<pid>/io`. |
| `patches/0005-profile-events-and-uid-sys-stats.patch` | `UID_SYS_STATS`, `UID_SYS_STATS_DEBUG`, plus the `profile_event_register()` API it needs | `/proc/uid_sys_stats` and `/proc/uid_cputime/*`, polled by the Android container for per-uid CPU and I/O accounting. |
| `patches/0006-staging-ashmem.patch` | `ASHMEM` | `/dev/ashmem`, used by ARC and by some Android apps for shared memory. |
| `patches/0007-fs-esdfs.patch` | `ESD_FS` | `esdfs` filesystem used for the Android `/data` and media mounts. |
| `patches/0008-netfilter-xt-quota2.patch` | `NETFILTER_XT_MATCH_QUOTA2`, `NETFILTER_XT_MATCH_QUOTA2_LOG` | `xt_quota2` iptables match; the FydeOS netfilter rules reference it by name, and a missing match makes `iptables-restore` fail. |

`build-kernel.sh` asserts all nine symbols end up `=y` after `olddefconfig`; a build that
drops one fails instead of shipping.

## 3.3 openFyde patches

`openfyde-patches/` carries the openFyde kernel patches that still apply cleanly to 6.12
(HID sensor compat, overlayfs for the ChromiumOS LSM, iwlwifi firmware loader, AHCI
suspend quirk, …); see its `README.md` for the list. One openFyde patch is not included:
`030-fix-amd-suspend-issue.patch` (the `drivers/pci/pci.c` hunk no longer applies, and it
is AMD-only).

openFyde's `063-altcall.patch` and `065-add-esdfs.patch` were **not** skipped — they were
forward-ported into `patches/0003` and `patches/0007` above, because the stock FydeOS
config enables both. Using the openFyde config as the baseline, as earlier revisions of
this repo did, silently dropped 450 symbols (including `SQUASHFS_XZ=y`, which the root
filesystem image needs); see §4.

## 4. Config

`config/fydeos-official-iris.config` is a **byte-identical copy of the stock FydeOS v23
kernel's `/proc/config.gz`** (exported with `modprobe configs`; `cmp`-verified). It is the
only trustworthy baseline: the userspace is compiled against the stock kernel and depends
on specific ABI-visible options. An approximation assembled from the public openFyde
config loses ~450 `=y`/`=m` symbols.

`config/overrides.config` is merged on top (`scripts/kconfig/merge_config.sh -m`) and only
touches build output:

* `CONFIG_DEBUG_INFO_NONE=y` — the stock config has `DEBUG_INFO=y` + DWARF5, which makes
  the build ~20 GB and does not fit on a GitHub runner. Debug info affects neither
  `vermagic` nor any struct layout.
* `CONFIG_IKCONFIG=y` + `CONFIG_IKCONFIG_PROC=y` — keeps `/proc/config.gz` available
  without `modprobe configs` (stock has `IKCONFIG=m`); costs ~50 kB.
* `# CONFIG_WERROR is not set` — the ported 5.4-era subsystems compile on 6.12 but not
  warning-free under every toolchain revision; a stray warning must not kill a 60-minute
  build.
* `CONFIG_DRM_I915=m`, `# CONFIG_MODULE_SIG`, `# CONFIG_MODVERSIONS`,
  `# CONFIG_MODULE_COMPRESS` — restated so a future base-config edit cannot silently
  change them. Plain, unsigned, unversioned modules; i915 stays a module so it can also
  be shipped standalone.

The build then runs `make olddefconfig` and **diffs the result against the stock config**:
every symbol that was `=y`/`=m` in the stock config must still be `=y`/`=m`
(toolchain-capability symbols excepted), otherwise the build fails. This is what catches a
kconfig dependency breaking a ported subsystem.

### Release string

The release is `6.12.54-01180-gb4e10020ba49-mbe`, **not** the stock
`6.12.54-01180-gb4e10020ba49-dirty`. `build-kernel.sh` writes the suffix into a
`localversion-fyde` file in the tree and asserts `make kernelrelease` before starting the
build. Consequences:

* modules land in `/lib/modules/6.12.54-01180-gb4e10020ba49-mbe/`, so a half-finished
  install can never overwrite the stock tree — the failure mode that broke the first two
  install attempts on the target machine;
* `vermagic` differs from the stock modules by design: **the two module trees cannot be
  mixed.** Running the new `vmlinuz` requires the new modules; the stock `vmlinuz` cannot
  load the new `i915.ko`.

The suffix is not set via `CONFIG_LOCALVERSION`: `scripts/setlocalversion` reads that
symbol out of `include/config/auto.conf` as a raw string, so a stray quote ends up inside
`UTS_RELEASE`.

Kernel source: `chromiumos/third_party/kernel` @ `b4e10020ba49ded48a0e34144c5eb2fbc813cc2b`
(`chromeos-6.12`, VERSION 6.12.54).

## 5. Build

Prebuilt binaries are attached to the
[latest release](https://github.com/macrwfuse/fydeos-matebook-e-dsi-kernel/releases)
(`vmlinuz`, `modules-*.tar.gz`, `i915.ko`, `config-*`, `SHA256SUMS`, plus a Chinese
install/write-up in `RELEASE_NOTES.md`). Build them yourself if you want a different
release suffix or kernel commit.

CI (recommended):

* push to `main`, or run *Actions → build-fydeos-kernel → Run workflow*.
* Optional input `localversion` overrides the release suffix if your FydeOS build reports
  a different `uname -r`.
* Artifacts:
  * `vmlinuz-6.12.54-...-mbe` — the `bzImage` for `syslinux/vmlinuz.A`
  * `modules-6.12.54-...-mbe.tar.gz` — full `/lib/modules/<release>` tree (top level
    `lib/modules/...`)
  * `i915.ko` — just the patched module (for inspection; vermagic is `-mbe`, so it only
    loads under this kernel)
  * `config-...`, `build.log`, `SHA256SUMS`

Locally on any Debian/Ubuntu box with `bc bison flex libssl-dev libelf-dev`:

```bash
./scripts/build-kernel.sh          # ~40-90 min on 4 cores, needs ~12 GB disk
```

## 6. Install

See [`docs/INSTALL.md`](docs/INSTALL.md) for the real layout of a FydeOS dual-boot
install. Short version, from a developer-mode FydeOS shell with rootfs verification
disabled (`/` is the 2.7 GB `ROOT-A` and has **~89 MB free** — check `df -h /` before
extracting):

The kernel lives on `loop0p12` (`EFI-SYSTEM`, vfat, `BFD1-C3FA`), which is normally
**not mounted**. It is *not* on `/tmp/grub_mnt` (`nvme0n1p1`, the shared physical ESP) —
that partition only holds the live boot menu, `/efi/fydeos/grub.cfg`. And it is not
under `/boot/syslinux/` either: those `.cfg` files are inside ROOT-A and never run.

```bash
sudo -i
mount -o remount,rw /
mkdir -p /mnt/esp && mount /dev/loop0p12 /mnt/esp
df -h / /mnt/esp

mkdir -p /mnt/stateful_partition/mbe-backup
cp -a /mnt/esp/syslinux/vmlinuz.A /mnt/esp/syslinux/vmlinuz.B \
      /mnt/esp/syslinux/*.cfg /mnt/stateful_partition/mbe-backup/   # /tmp is tmpfs
cp -a /tmp/grub_mnt/efi/fydeos/grub.cfg /mnt/stateful_partition/mbe-backup/

# the module tree unpacks to ~132 MB while / has ~89 MB free: move the stock tree out first,
# otherwise tar dies halfway and leaves a partial /lib/modules
mv /lib/modules/6.12.54-01180-gb4e10020ba49-dirty /mnt/stateful_partition/mbe-backup/
tar -xzf modules-6.12.54-*-mbe.tar.gz -C /   # top level is lib/, nothing else touched
find /lib/modules/6.12.54-01180-gb4e10020ba49-mbe -name '*.ko' | wc -l   # expect 1195

# the ESP has less free space than the new kernel needs: delete before copying
rm /mnt/esp/syslinux/vmlinuz.A                         # leave .B untouched
cp vmlinuz-6.12.54-*-mbe /mnt/esp/syslinux/vmlinuz.A
sha256sum /mnt/esp/syslinux/vmlinuz.A /mnt/esp/syslinux/vmlinuz.B   # must now differ
sync && reboot
```

`/mnt/esp` is a 32 MB vfat and already ~75% full: with the stock kernel in place it has
**8.7 MB free**, less than the 10.5 MB replacement. `rm` the old `vmlinuz.A` first (an
identical copy is already in `mbe-backup`) — that frees 11.7 MB, so the copy then has
~10 MB of headroom. A plain `cp` over the existing file fails with `No space left on
device`.

The module tarball's top level is `lib/modules/6.12.54-...-mbe`, so extracting it at `/`
never writes into the stock module directory. Do **not** copy `i915.ko` alone: its
`vermagic` carries `-mbe`, so the stock `vmlinuz` rejects it. There is no module-only
install path.

A failed extract is the expensive failure: a partially populated `-mbe` directory looks
installed but is missing modules. `scripts`-side nothing checks this, so verify the `.ko`
count (1195) and `du -sh` (~132 MB) before rebooting.

## 7. Verify

Both markers are `drm_dbg_kms()` messages, so they are **not printed by default**
(`__drm_debug_syslog` starts at 0 and `CONFIG_DRM_USE_DYNAMIC_DEBUG` is off).
Enable the KMS bit (`0x4`) first:

```bash
uname -r

# runtime: takes effect immediately, but only for output after this point,
# and only once that code path runs again (switch VT / replug an output)
echo 0x4 > /sys/module/drm/parameters/debug
dmesg | grep -iE "Not touching native DSI|DSB not used for DSI"

# to cover boot itself (the modeset that decides whether the screen tears),
# add drm.debug=0x4 to the kernel command line and reboot instead.
```

* `"Not touching native DSI GPIOs, keeping firmware state"` ⇒ patch 1 is live
* `"[CRTC:..] DSB not used for DSI output, falling back to MMIO"` ⇒ patch 2 is live

`drm.debug=0x4` is extremely verbose; drop it again once you have the lines.

## 8. Status / disclaimer

The display fix itself has been confirmed by other MateBook E owners running patched
mainline kernels (see issue 8992). This FydeOS 6.12 build has **not** booted on the target
machine yet. Everything that can be checked without the hardware has been:

* CI run [41773578775](https://github.com/macrwfuse/fydeos-matebook-e-dsi-kernel/actions/runs/41773578775)
  (`312b8705`) is a **full successful compile**: 9010 objects, 13218 log lines, zero
  warnings about a stock symbol disappearing. Every ported subsystem links:
  `fs/esdfs/*.o`, `ashmem.o`, `xt_quota2.o`, `uid_sys_stats.o`, `pkglist.o`,
  `kernel/alt-syscall.o`, `kernel/profile.o`.
* The 8 patches were replayed onto a pristine 6.12.54 tree with `patch -p1` and the result
  is byte-identical to the build tree — the tarball is reproducible from the repo.
* All five artifacts were re-hashed locally after download.

The two earlier install attempts failed, and this revision is the response:

| What went wrong before | What changed |
|---|---|
| The build used the public openFyde 6.6 config as its base, which dropped ~450 `=y`/`=m` symbols relative to the stock config (including `SQUASHFS_XZ=y` and the six ported ChromiumOS subsystems). The resulting kernel could not mount its own root filesystem. | Base config is now a byte-identical copy of the stock `/proc/config.gz`; `build-kernel.sh` fails the build if any stock symbol disappears after `olddefconfig`. §4 |
| The release string was `...-dirty`, identical to the stock kernel. Extracting the module tarball at `/` overwrote the stock `/lib/modules` tree, so a failed install left a system that could not load any module. | Release is now `...-mbe`, a separate `/lib/modules` directory. §4 |
| `/` has only ~90 MB free and the module tree is ~132 MB, so the extract runs out of space partway. | Move the stock module tree to H-STATE first (§6); verify 1195 `.ko` files before rebooting. |

Treat the first boot as an experiment and keep a rollback path (syslinux image B) ready —
`docs/INSTALL.md` §8.

That experiment has already been run on the target machine: the **stock** kernel with
`i915.enable_dsb=0` on the command line (no disk writes) still tears identically, so the
DSB half of the fix (patch 2) is **not** what matters on this panel — patch 1 is. See §3.1.

Patches are GPL-2.0, same as the kernel.
