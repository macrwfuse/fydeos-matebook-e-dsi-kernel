# openFyde kernel patches that still apply to chromeos-6.12

Copied from <https://github.com/openFyde/project-openfyde-patches>
(`sys-kernel/chromeos-kernel-6_6/files/`, r144-dev) — the last public revision that
contains them. They were applied with `patch -p1 --forward` against
`chromiumos/third_party/kernel` @ `b4e10020ba49` and all 15 still apply cleanly
(verified 2026-10-30 with `patch --dry-run`).

`001-hid-sensor-cros-compat.patch` needed two forward-ports to compile on 6.12:
`strtobool()` is gone since 5.19 (now `kstrtobool()`, which returns 0 on success), and
`platform_driver.remove()` has returned `void` since 6.11. Both were hard errors, not
warnings, so `drivers/iio` failed to build. The rest are unmodified.

| Patch | Purpose |
|---|---|
| `001-hid-sensor-cros-compat.patch` | HID sensor hub compatibility layer (ChromiumOS sensors on generic hardware) |
| `003-add-marvell-bluetooth.patch` | btusb IDs for Marvell controllers |
| `0034-set-overlayfs-mounts-enable.patch` | Allow non-system overlayfs mounts in the ChromiumOS LSM |
| `006-intel-hid-tablet-mode.patch` | Force tablet mode on some Intel HID devices |
| `007-add-lenovo-keyboard.patch` | PS/2 quirk |
| `008-overlayfs.patch` | SELinux overlayfs labelling |
| `009-knote5-touchscrean.patch` | Touchscreen DMI quirk |
| `010-fix-ideapad-i2c-touchpad.patch` | I2C touchpad IRQ quirk |
| `011-for-old-intel-graphic.patch` | i915 framebuffer minimum size for older iGPUs |
| `027-set-split-lock-detct-off.patch` | Disable Intel split-lock detection (would otherwise SIGKILL Chrome) |
| `028-fix-localverion.patch` | `setlocalversion` no longer appends `+` for dirty trees |
| `029-fix-iwlwifi-firmware-loader.patch` | iwl7000 firmware path |
| `033-disable-ahci-suspend.patch` | AHCI suspend workaround |
| `062-fix-report-issue.patch` | ChromiumOS LSM build fix |
| `064-fix-initramfs-init-failed.patch` | `chromiumos.allow_exec_ramfs` |

## Deliberately excluded

| Patch | Reason |
|---|---|
| `030-fix-amd-suspend-issue.patch` | `drivers/pci/pci.c` hunk no longer applies (upstream rewrote `pci_bridge_d3_possible()`); AMD-only, irrelevant to a Tiger Lake machine. |

## `063-altcall` and `065-esdfs` live in `patches/`, not here

An earlier revision of this repo skipped both, on the assumption that the openFyde
config disabled the options they implement. That assumption is **wrong for FydeOS v23**:
the stock `/proc/config.gz` has `CONFIG_ALT_SYSCALL=y`, `CONFIG_ALT_SYSCALL_CHROMIUMOS=y`
and `CONFIG_ESD_FS=y`. They are not optional features of the FydeOS userspace — the
Android container and the session manager call the alt-syscall interface, and the
ARC/SquashFS mounts go through esdfs. Dropping them would change `task_struct` and
remove a filesystem the running system mounts.

Both were forward-ported instead:

| openFyde patch | Where it went |
|---|---|
| `063-altcall.patch` | `patches/0003-chromeos-alt-syscall.patch` (rebased on 6.12's `entry/` split, `syscall_32.c`, `do_fsync` plumbing) |
| `065-add-esdfs.patch` | `patches/0007-fs-esdfs.patch` (rebased on 6.12's `read_write.c`, `user_namespace.c`, `security.c` exports) |

`patches/0004`–`0006` and `0008` add the other four subsystems the stock config expects
but 6.12 does not have: `syscfs` accounting in `task_io_accounting`, the
`profile_event_register` API used by `uid_sys_stats`, ashmem, and `xt_quota2`.

## Note on config

The build does **not** use any openFyde config file. `config/fydeos-official-iris.config`
is a byte-identical copy of the stock FydeOS v23 kernel's `/proc/config.gz`, and
`config/overrides.config` only changes build-output settings (no debug info, `IKCONFIG`
built in, `WERROR` off) plus a release-string isolation that is actually handled by a
`localversion-fyde` file. Everything else is left exactly as FydeOS ships it — see
`README.md` §4.
