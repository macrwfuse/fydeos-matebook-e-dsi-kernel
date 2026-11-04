# Installing the patched kernel on FydeOS v23

Written for a MateBook E 2022 running FydeOS v23 (the `iris` image; `apu` and `slim` use
the same 6.12.54 kernel). Read the whole page before starting — the only step that can
brick the installation is writing to the wrong partition, and on this machine the obvious
candidate for "the EFI partition" is not the right one.

## 0. What is different about this build

The release string is **`6.12.54-01180-gb4e10020ba49-mbe`**, not the stock
`...-dirty`. This is deliberate:

* the modules install into `/lib/modules/6.12.54-01180-gb4e10020ba49-mbe/`, a directory
  that does not exist on a stock system, so nothing can overwrite the stock tree;
* `vermagic` contains `-mbe`, so **the two kernels and the two module trees cannot be
  mixed.** You must install `vmlinuz` and the modules together. Installing `i915.ko`
  alone on top of the stock kernel will simply fail to load the module.

There is no module-only install path. Either install both artifacts, or stay on stock.

## 1. Know your layout

Prerequisites: developer mode enabled and rootfs verification disabled
(<https://fydeos.com/question/enable-developer-mode/>,
<https://fydeos.com/docs/knowledge-base/getting-started/disable-rootfs-verification/>).
Without that `/` is read-only and nothing you put in `/lib/modules` survives a reboot.

```bash
sudo -i
lsblk -f
df -h /
```

On the MateBook E target the relevant devices are:

| Device | Mounted at | What it is |
|---|---|---|
| `/dev/loop0p3` | `/` | `ROOT-A`, ext2, 2.7 G — **only ~89 MB free** |
| `/dev/loop0p12` | *not mounted* | `EFI-SYSTEM`, vfat, `BFD1-C3FA` — **the actual boot files live here** |
| `/dev/loop0p1` | `/mnt/stateful_partition`, `/home`, `/usr/local` | `H-STATE`, ext4, 84 G, ~77 G free |
| `/dev/nvme0n1p1` | `/tmp/grub_mnt` | the shared physical ESP (also holds `Windows`, `OCS*`, `HUAWEI`, `refind`) |
| `/dev/nvme0n1p4` | *not mounted* | `FYDEOS-DUAL-BOOT`, ext2 — holds `fydeos/fydeos_dual_boot.img` and `boot/dual_boot_ramfs.cpio` |

### How it actually boots

There are two `grub.cfg` files and **only one of them is live**. The one that runs is on
the physical ESP:

```
/tmp/grub_mnt/efi/fydeos/grub.cfg          <- live, this is the menu you see
```

Its `FydeOS multi-boot A` entry matches the running `/proc/cmdline` verbatim
(`boot=local ... cros_efi cros_debug fydeos_dualboot`). The chain is:

```
ESP:/efi/fydeos/grub.cfg
  loopback loopdev (FYDEOS-DUAL-BOOT)/fydeos/fydeos_dual_boot.img
  set root=loopdev,gpt12                     <- a partition INSIDE the image
  linux  /syslinux/vmlinuz.A                 <- the file you replace
  initrd (FYDEOS-DUAL-BOOT)/boot/dual_boot_ramfs.cpio
  -> switch_root into p3 (image A) or p5 (image B), chosen by cgpt priority
```

So the kernel to replace is **`/syslinux/vmlinuz.A` on `/dev/loop0p12`**, and **`vmlinuz.B`
on the same partition is your rollback path.**

### Two traps

* **`/boot/syslinux/` and `/boot/efi/` are inside ROOT-A and are dead.** `/boot` resolves
  to `loop0p3`, the read-only root image, not to a boot partition. It contains
  `root.A.cfg`, `syslinux.cfg`, `usb.A.cfg` (all `root=HDROOTA ... cros_legacy`) and a
  second `grub.cfg` with `root=/dev/$linuxpartA`. **None of those strings appear in the
  running cmdline.** Editing them changes nothing.
* **`/tmp/grub_mnt` is not "the wrong ESP" — it is the right ESP, but the wrong
  subdirectory.** The kernel is *not* there (`/tmp/grub_mnt/syslinux/` does not exist);
  only the boot menu is. Do not copy `vmlinuz.A` onto `nvme0n1p1`.

`EFI-SYSTEM` (`loop0p12`) is normally not mounted, and `/mnt/esp` exists but is empty:

```bash
mkdir -p /mnt/esp
mount /dev/loop0p12 /mnt/esp
ls -l /mnt/esp/syslinux/
sha256sum /mnt/esp/syslinux/vmlinuz.A /mnt/esp/syslinux/vmlinuz.B
```

The stock `vmlinuz.A` and `vmlinuz.B` are byte-identical (11707392 bytes each,
`3f413ae6200deee97910cccc02f0721dcb58c8948a9b4e1ff45dd500268658a3`). If A no longer
matches B, an earlier install already changed A — restore A from B before starting.
The replacement kernel is 11006976 bytes; the size difference is expected (no DWARF debug
info in this build).

## 2. Back up (to H-STATE, not `/tmp`)

`/tmp` is a tmpfs: anything you put there is gone after the reboot, which is exactly when
you need it. Keep the backup on the stateful partition instead.

```bash
mount -o remount,rw /
mkdir -p /mnt/stateful_partition/mbe-backup
cp -a /mnt/esp/syslinux/vmlinuz.A /mnt/esp/syslinux/vmlinuz.B \
      /mnt/esp/syslinux/*.cfg /mnt/stateful_partition/mbe-backup/
cp -a /tmp/grub_mnt/efi/fydeos/grub.cfg /mnt/stateful_partition/mbe-backup/
sha256sum /mnt/esp/syslinux/vmlinuz.A /mnt/esp/syslinux/vmlinuz.B \
          > /mnt/stateful_partition/mbe-backup/stock-sums.txt
```

Back up `vmlinuz.B` as well: it is the stock kernel and, since A and B are normally
identical, it is also a second copy of the rollback image.

Then copy that directory to a USB stick, since a broken boot is the failure mode you are
insuring against. You do **not** need to back up `/lib/modules/$(uname -r)` — the module
tarball has its own `-mbe` release directory and never writes into the stock tree.

## 3. Make room on `/` first — this is the step that failed before

`/` is the 2.7 GB `ROOT-A` ext2 and has **only ~90 MB free**. The module tree unpacks to
**about 132 MB** (1571 entries, 1195 `.ko` files). Extracting without making room first
runs out of space halfway through and leaves a half-populated module directory, which is
worse than not installing at all.

The stock module tree is itself ~134 MB, so the cheapest way to gain the space is to move
it to H-STATE for the duration:

```bash
df -h /
mv /lib/modules/6.12.54-01180-gb4e10020ba49-dirty /mnt/stateful_partition/mbe-backup/
df -h /                 # now ~225 MB free
```

If H-STATE is not mounted under `/mnt/stateful_partition`, check `df -h` for the ext4
partition and use that path; the point is only that the move must land on a *different*
filesystem, so `mv` really frees the blocks on `/`.

Keep the **archive** on H-STATE too (that is where `~/Downloads` lives anyway) — only the
extraction target is `/`:

```bash
tar -xzf /mnt/stateful_partition/mbe/modules-6.12.54-01180-gb4e10020ba49-mbe.tar.gz -C /
echo $?                 # must be 0 — do not continue if it is not
```

The top level of the tarball is `lib/modules/6.12.54-01180-gb4e10020ba49-mbe`, so this
adds one new directory and touches nothing else.

Check it landed where expected before touching the boot loader:

```bash
ls -d /lib/modules/6.12.54-01180-gb4e10020ba49-mbe
find /lib/modules/6.12.54-01180-gb4e10020ba49-mbe -name '*.ko' | wc -l    # expect 1195
du -sh /lib/modules/6.12.54-01180-gb4e10020ba49-mbe                      # expect ~132M
find /lib/modules/6.12.54-01180-gb4e10020ba49-mbe | wc -l                # expect 1571
df -h /
```

Fewer than 1195 `.ko` files means `tar` ran out of space. If it did, remove the partial
directory, free more space, and retry:

```bash
rm -rf /lib/modules/6.12.54-01180-gb4e10020ba49-mbe
```

Once the install is verified you can delete the moved stock tree to keep `/` usable — but
only after a successful boot, and only if you have a copy of it on H-STATE (which you do
after §2).

## 4. Install the kernel

`EFI-SYSTEM` is only a 32 MB vfat and the stock tree leaves it ~75% full. With the stock
`vmlinuz.A` in place `df -h /mnt/esp` reports **8.7 MB free**, which is *less* than the
10.5 MB replacement kernel — a plain `cp` over it fails with `No space left on device`.
Delete the old file first; that frees its whole 11.7 MB, so afterwards there is ~10 MB to
spare:

```bash
cd /mnt/stateful_partition/mbe          # wherever you put the artifacts
sha256sum -c SHA256SUMS                 # all must say OK

df -h /mnt/esp                          # stock state: ~8.7 MB free
rm /mnt/esp/syslinux/vmlinuz.A          # safe: identical copy already in mbe-backup (§2)
df -h /mnt/esp                          # now ~20 MB free
cp vmlinuz-6.12.54-01180-gb4e10020ba49-mbe /mnt/esp/syslinux/vmlinuz.A
sync
ls -l /mnt/esp/syslinux/vmlinuz.A       # expect 11006976
sha256sum /mnt/esp/syslinux/vmlinuz.A /mnt/esp/syslinux/vmlinuz.B   # must now differ
df -h /mnt/esp                          # ~10 MB free again
```

**Do not touch `vmlinuz.B`.** It is the stock image and the rollback path. Nothing under
`/boot/syslinux/` or `/boot/efi/` needs to change, and nothing on `/tmp/grub_mnt` needs to
change — leave `root.A.cfg`, `default.cfg`, `ldlinux.sys` and the two `grub.cfg` files
alone.

## 5. Reboot and verify

The two patch markers are `drm_dbg_kms()` messages and do not print by default. Add
`drm.debug=0x4` to the kernel command line before rebooting if you want them at boot;
otherwise "the screen does not tear" is the evidence.

```bash
uname -r
# 6.12.54-01180-gb4e10020ba49-mbe

dmesg | grep -iE "Not touching native DSI|DSB not used for DSI"
```

* `Not touching native DSI GPIOs, keeping firmware state` ⇒ patch 1 is live

  This is the line that matters — it is the one that removes the tearing, confirmed on the
  target machine. It only appears when the DMI match succeeds; the MateBook E 2022 reports
  `DRC-WXX`, which kernels built before 2025-11 did not match. If it is absent, boot with
  `i915.dsi_native_gpio_bypass=1` (see §6).

* `[CRTC:..] DSB not used for DSI output, falling back to MMIO` ⇒ patch 2 is live. It is
  not required on this panel (`i915.enable_dsb=0` changes nothing, §6).

To check without rebooting (only covers activity after the command — trigger a modeset
afterwards by switching VT or replugging an external display):

```bash
echo 0x4 > /sys/module/drm/parameters/debug
```

`drm.debug=0x4` is extremely verbose; drop it again once you have the lines.

Diagnostics:

* `uname -r` still shows `-dirty` → GRUB loaded a different file. Check that
  `loop0p12:/syslinux/vmlinuz.A` is the one you wrote (`sha256sum` it after remounting),
  and that the menu entry you picked was `FydeOS multi-boot A` and not `B`.
* `uname -r` shows `-mbe` but the boot stops early → the modules are missing. Boot menu B,
  then see §8.
* `uname -r` shows `-mbe` but `lsmod` has no `i915`, or `dmesg` says
  `module verification failed` / `version magic ... should be ...` → the modules did not
  install where the kernel looks. Check
  `ls /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/i915/` and redo §3.
* No `Not touching native DSI GPIOs` line and the screen still tears → the DMI entry did
  not match. The MateBook E 2022 reports `dmidecode -s system-product-name` = **`DRC-WXX`**
  (not "MateBook E"), and builds before 2025-11 only matched `MateBook E*`. Check
  `cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name` and boot once with
  `i915.dsi_native_gpio_bypass=1` appended to the kernel command line.

## 6. Explicit toggles

Patch 1 exposes a module parameter, useful while testing:

```bash
i915.dsi_native_gpio_bypass=-1   # default: decide via DMI
i915.dsi_native_gpio_bypass=1    # always skip the native GPIO sequence
i915.dsi_native_gpio_bypass=0    # never skip (stock behaviour)
```

On the target machine `=1` is what removes the tearing, because its DMI product name is
`DRC-WXX` and kernels built before 2025-11 only matched `MateBook E*`. Kernels built
after that match `DRC-WXX` directly and need no parameter.

### 6.1 Making `=1` survive a reboot (interim, for the old build)

The `e`-at-the-menu edit is one-shot. To keep it, edit the **live** menu — the one on
`nvme0n1p1`, not any `grub.cfg` inside ROOT-A:

```bash
sudo -i
grep -n 'linux /syslinux/vmlinuz.A' /tmp/grub_mnt/efi/fydeos/grub.cfg
# append the parameter to the END of that line, then:
sync
```

The line should end with ` i915.dsi_native_gpio_bypass=1`. Check it took effect after the
next boot:

```bash
cat /proc/cmdline | tr ' ' '\n' | grep dsi_native_gpio_bypass
dmesg | grep -c 'Not touching native DSI GPIOs'     # expect >0
```

Back the file up first (`/mnt/stateful_partition/mbe-backup/grub.cfg`) and revert by
restoring it. Once a kernel with the fixed DMI table is installed, remove the parameter
again — leaving it set is harmless but hides whether the DMI match actually works.

Patch 2 is unconditional and has no toggle. The **stock** kernel already accepts
`i915.enable_dsb=0`, which disables the DSB path globally
(`intel_display_params.c:57`), and this test has already been run **on the target
machine**: with the stock kernel — nothing written to disk — the tearing was unchanged.

Conclusion: **patch 2 is not required for this panel.** The corruption comes from the
native MIPI GPIO sequence that patch 1 skips. Patch 2 stays in the build as a safeguard
for 6.13+ trees and other panels, and is harmless here. There is no reason to persist
`i915.enable_dsb=0` anywhere.

For the record, the one-off test is a GRUB edit that writes nothing:

1. Reboot. The GRUB menu has `set timeout=1`; **hold Down** to stop the countdown.
2. Highlight `FydeOS multi-boot A`, press **`e`**.
3. Move to the `linux /syslinux/vmlinuz.A ...` line, press **End**, append a space and
   `i915.enable_dsb=0`.
4. Press **Ctrl-X** to boot.

A normal reboot restores the previous behaviour. Do **not** edit
`/boot/efi/boot/grub.cfg` — it is a copy inside ROOT-A that never runs.

## 7. Known limitations

* **Suspend/resume**: patch 1 keeps whatever panel state the firmware set up. After a
  suspend the panel may stay dark; a full reboot always recovers. If you need reliable
  resume, do not use this kernel.
* **Cold boot from a blanked panel**: same constraint — when the firmware has *not*
  powered the panel, skipping the GPIO sequence cannot power it on. On this machine the
  firmware does power it, so boot works; if you ever get a black screen after a CMOS
  reset or a BIOS update, boot image B.
* **The Android container**: this build re-implements the ChromiumOS subsystems the
  stock config enables (alt-syscall, esdfs, ashmem, uid_sys_stats, xt_quota2, `syscfs`
  accounting) so ARC keeps working. Those subsystems are 5.4-era code forward-ported to
  6.12 — they compile and are config-asserted, but they are the least tested part of the
  build. If the desktop works and the Android container does not, that is where to look.

## 8. Rollback

Kernel and modules must be restored **together** — restoring only one leaves a vermagic
mismatch and the machine will not boot either.

```bash
sudo -i
mount -o remount,rw /
mountpoint -q /mnt/esp || mount /dev/loop0p12 /mnt/esp
rm -rf /lib/modules/6.12.54-01180-gb4e10020ba49-mbe
mv /mnt/stateful_partition/mbe-backup/6.12.54-01180-gb4e10020ba49-dirty /lib/modules/

# Same space constraint as §4: remove before copying.
rm /mnt/esp/syslinux/vmlinuz.A
cp /mnt/stateful_partition/mbe-backup/vmlinuz.A /mnt/esp/syslinux/vmlinuz.A
sha256sum /mnt/esp/syslinux/vmlinuz.A       # 3f413ae6...268658a3, identical to .B
sync && reboot
```

Removing `-mbe` is all that is needed on the module side — the stock
`6.12.54-01180-gb4e10020ba49-dirty` tree was only *moved* (if you followed §3), never
modified. If you freed space some other way and left it in place, skip the `mv`.

Selecting image **B** in GRUB boots `vmlinuz.B` (the untouched stock kernel), which needs
the stock `/lib/modules` tree — so if you followed §3 you must `mv` it back from H-STATE
before B will boot usefully.

If the machine will not boot at all: boot a FydeOS U-disk, mount the internal
`EFI-SYSTEM` (`/dev/loop0p12`, vfat, label `BFD1-C3FA`), and restore `syslinux/vmlinuz.A`
from your backup. `/tmp/grub_mnt` (`nvme0n1p1`) holds the boot menu but **no kernel** —
there is no `syslinux/` directory there, so it is not involved in the recovery.
