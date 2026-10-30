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

| File | Applies to | What it does |
|---|---|---|
| `patches/0001-drm-i915-dsi-skip-native-mipi-gpio-on-huawei-matebook-e.patch` | 6.1 … 6.12+ | DMI-matches HUAWEI `MateBook E*` and skips the native MIPI GPIO sequence, keeping the firmware-programmed panel state. Also exposes `i915.dsi_native_gpio_bypass={-1,0,1}` so you can force it on/off or test other machines. |
| `patches/0002-drm-i915-dsb-do-not-use-dsb-for-dsi-outputs.patch` | 6.12+ only | Makes `intel_dsb_prepare()` bail out for CRTCs driven by a DSI output, so plane/color updates fall back to MMIO. No effect on 6.1/6.6 builds, where the DSB path does not exist. |

Known trade-offs (documented upstream by Jani Nikula and Amer):

* Skipping the GPIOs relies on the firmware having powered the panel. **Waking from
  suspend may leave the screen dark.** If that is unacceptable, do not use this kernel.
* Disabling DSB for DSI costs a little CPU in the commit path. Nothing else.

`openfyde-patches/` carries the 15 openFyde kernel patches that still apply cleanly to
6.12 (HID sensor compat, overlayfs for the ChromiumOS LSM, iwlwifi firmware loader,
AHCI suspend quirk, …). Three patches from the openFyde r144 tree are **not** included
because they do not apply to 6.12 *and* the option they serve is disabled in the
openFyde config anyway:

| openFyde patch | Why it is skipped |
|---|---|
| `030-fix-amd-suspend-issue.patch` | Hunk in `drivers/pci/pci.c` no longer applies (upstream rewrote `pci_bridge_d3_possible()`). AMD-only fix. |
| `063-altcall.patch` | `init_task.c` / `netns/core.h` hunks are stale; `CONFIG_ALT_SYSCALL` is not enabled in the openFyde config. |
| `065-add-esdfs.patch` | `fs/read_write.c` hunk is stale; `# CONFIG_ESD_FS is not set` in the openFyde config. |

## 4. Config

`config/openfyde-6.6-def-r2.config` is the config openFyde ships for
`overlay-amd64-openfyde_iris` (the closest public equivalent of FydeOS' own build).
It is combined at build time with the `chromeos-6.12` fragment set
(`chromeos/config/chromeos/{base.config,x86_64/common.config,x86_64/chromiumos-x86_64-generic.flavour.config}`)
and then with `config/hardening.config`, which pins the things that matter:

* `CONFIG_DRM_I915=m` — same as stock, so a standalone `i915.ko` artifact is usable.
* `CONFIG_MODVERSIONS` off, `CONFIG_MODULE_SIG` off — stock modules are not versioned.
* `CONFIG_MODULE_COMPRESS_ALL` off — plain `.ko` files.
* `CONFIG_DEBUG_INFO_NONE=y` — keeps the CI build inside the runner's disk quota.
  Debug info has no effect on module compatibility.
* Release string `6.12.54-01180-gb4e10020ba49-dirty` — reproduces FydeOS v23's exact
  `uname -r`, so `vermagic` lines up and the modules land in
  `/lib/modules/6.12.54-01180-gb4e10020ba49-dirty`, the same directory the stock kernel
  uses. It comes from a `localversion-fyde` file that `build-kernel.sh` writes into the
  source tree, not from `CONFIG_LOCALVERSION`: `scripts/setlocalversion` reads that
  symbol out of `include/config/auto.conf` as a raw string, and a stray quote there
  ends up inside `UTS_RELEASE`. `build-kernel.sh` asserts the resulting
  `make kernelrelease` before starting the build.

Kernel source: `chromiumos/third_party/kernel` @ `b4e10020ba49ded48a0e34144c5eb2fbc813cc2b`
(`chromeos-6.12`, VERSION 6.12.54).

## 5. Build

CI (recommended):

* push to `main`, or run *Actions → build-fydeos-kernel → Run workflow*.
* Optional input `localversion` overrides the release suffix if your FydeOS build reports
  a different `uname -r`.
* Artifacts:
  * `vmlinuz-6.12.54-...` — the `bzImage` for `/efi/syslinux/vmlinuz.A`
  * `modules-6.12.54-...tar.gz` — full `/lib/modules/<release>` tree
  * `i915.ko` — just the patched module
  * `config-...`, `build.log`, `SHA256SUMS`

Locally on any Debian/Ubuntu box with `bc bison flex libssl-dev libelf-dev`:

```bash
./scripts/build-kernel.sh          # ~40-90 min on 4 cores, needs ~12 GB disk
```

## 6. Install

See [`docs/INSTALL.md`](docs/INSTALL.md). Short version, from a developer-mode FydeOS
shell with rootfs verification disabled:

```bash
sudo -i
mount -o remount,rw /
# full replacement (safest)
tar -xzf modules-6.12.54-*.tar.gz -C /
cp vmlinuz-6.12.54-* /efi/syslinux/vmlinuz.A     # keep .B untouched for rollback
reboot
```

Or, if `modinfo` shows the stock vermagic matches our `i915.ko`:

```bash
cp i915.ko /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/i915/i915.ko
depmod -a && reboot
```

## 7. Verify

```bash
uname -r
dmesg | grep -i "DSI GPIO\|Not touching native"
# "Not touching native DSI GPIOs, keeping firmware state" => patch 1 is live
dmesg | grep -i "DSB not used for DSI"          # => patch 2 is live (6.12+)
```

## 8. Status / disclaimer

Built and packaged here, **not yet validated on hardware by the author** — the display
fix itself has been confirmed by other MateBook E owners running patched mainline kernels
(see issue 8992), but this specific FydeOS 6.12 build has not been booted on a MateBook E
yet. Treat the first boot as an experiment and keep a rollback path (GRUB image B) ready.

Patches are GPL-2.0, same as the kernel.
