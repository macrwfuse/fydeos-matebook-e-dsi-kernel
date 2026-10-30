# openFyde kernel patches that still apply to chromeos-6.12

Copied from <https://github.com/openFyde/project-openfyde-patches>
(`sys-kernel/chromeos-kernel-6_6/files/`, r144-dev) — the last public revision that
contains them. They were applied with `patch -p1 --forward` against
`chromiumos/third_party/kernel` @ `b4e10020ba49` and all 15 still apply cleanly
(verified 2026-10-30 with `patch --dry-run`).

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
| `030-fix-amd-suspend-issue.patch` | `drivers/pci/pci.c` hunk no longer applies (upstream rewrote `pci_bridge_d3_possible()`); AMD-only. |
| `063-altcall.patch` | Two stale hunks (`init/init_task.c`, `include/net/netns/core.h`); `CONFIG_ALT_SYSCALL` is off in the openFyde config, so it is dead code anyway. |
| `065-add-esdfs.patch` | `fs/read_write.c` hunk no longer applies; `# CONFIG_ESD_FS is not set` in the openFyde config. |

If you need one of those three, port the hunk forward and add it back — they are not
needed for the display fix.

## Note on config

`config/openfyde-6.6-def-r2.config` is the config from
`overlay-amd64-openfyde_iris` r144-dev. openFyde has no public 6.12 kconfig; FydeOS v23
runs 6.12.54, so the build merges the `chromeos-6.12` fragment set with this config and
then `config/hardening.config`. Expect `make olddefconfig` to adjust a handful of symbols
that did not exist in 6.6 (or vice versa); check `out/build.log` for the overrides if a
driver seems missing.
