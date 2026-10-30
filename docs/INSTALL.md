# Installing the patched kernel on FydeOS v23

Written for a MateBook E 2022 running FydeOS v23 for PC (the `iris` or `apu` image;
`slim` uses the same 6.12.54 kernel). Read the whole page before starting; the only
step that can brick the installation is writing to the wrong partition.

## 0. Prerequisites

* Developer mode enabled, rootfs verification disabled
  (<https://fydeos.com/question/enable-developer-mode/>,
   <https://fydeos.com/docs/knowledge-base/getting-started/disable-rootfs-verification/>).
  Without this `/` is read-only and the modules will not survive a reboot.
* The artifacts from the *build-fydeos-kernel* run: `vmlinuz-*`,
  `modules-*.tar.gz`, optionally `i915.ko`.
* A note of your current kernel string — `uname -r` — so you can tell the stock directory
  from the new one. On v23 this is `6.12.54-01180-gb4e10020ba49-dirty`. If yours differs,
  rebuild with `--localversion` set to your suffix (or download the workflow run built
  with that input), otherwise modules land in the wrong directory and i915 will not load.

## 1. Know your layout

```bash
sudo -i
lsblk -f
```

The FydeOS install normally has a 12 MiB EFI partition (vfat, mounted read-only at
`/efi` on U-disk installs, at `/tmp/grub_mnt` on some internal-disk layouts). Identify
the one that contains `syslinux/vmlinuz.A`.

```bash
find / -maxdepth 4 -name 'vmlinuz.A' 2>/dev/null
```

## 2. Back up

```bash
mount -o remount,rw /
cp -a /lib/modules/$(uname -r) /tmp/modules.backup

EFI=/tmp/grub_mnt          # or /efi, whichever `find` above returned
cp -a "$EFI/syslinux/vmlinuz.A" /tmp/vmlinuz.A.backup
ls -l /tmp/vmlinuz.A.backup /tmp/modules.backup
```

Copy them somewhere off the machine (USB stick) if you care about the install.

## 3. Install

Way A — full replacement (recommended; this is what the patches were built and tested
against):

```bash
cd /home/chronos/user/Downloads        # where you copied the artifacts
tar -xzf modules-6.12.54-*.tar.gz -C /  # adds /lib/modules/6.12.54-... , leaves the old dir
cp vmlinuz-6.12.54-* "$EFI/syslinux/vmlinuz.A"
sync
```

Way B — module only, if you want to keep the stock `vmlinuz`:

```bash
modinfo /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/i915/i915.ko | grep vermagic
modinfo -F vermagic i915.ko
```

Only continue if both lines are identical:

```bash
cp i915.ko "/lib/modules/$(uname -r)/kernel/drivers/gpu/drm/i915/i915.ko"
depmod -a
```

`vmlinuz.A` is the first boot entry. **Do not touch `vmlinuz.B`** — the GRUB/syslinux
menu lets you pick image B, which is your rollback path.

## 4. Reboot and verify

```bash
uname -r
dmesg | grep -iE "Not touching native DSI|DSB not used for DSI"
```

* No `Not touching native DSI GPIOs` line and the screen still tears →
  the DMI entry did not match. Check `dmidecode -s system-product-name`; if it prints
  something other than `MateBook E...`, either add a match to patch 1 or boot with
  `i915.dsi_native_gpio_bypass=1` on the kernel command line.
* No i915 messages at all → module did not load; check
  `dmesg | grep i915` and that `/lib/modules/$(uname -r)` exists.

## 5. Explicit toggles

Patch 1 exposes a module parameter, useful while testing:

```bash
# /etc/default/grub style: add to the kernel command line
i915.dsi_native_gpio_bypass=0   # never skip (stock behaviour)
i915.dsi_native_gpio_bypass=1   # always skip, even on non-MateBook hardware
i915.dsi_native_gpio_bypass=-1  # default, decide via DMI
```

## 6. Known limitations

* **Suspend/resume**: the patch keeps whatever state the firmware set up. After a
  suspend the panel may stay dark; a full reboot always recovers. If you need reliable
  resume, do not use this kernel.
* **Cold boot from a blanked panel**: the same constraint — when the firmware has *not*
  powered the panel, skipping the GPIO sequence cannot power it on. On this machine the
  firmware does power it, so boot works; if you ever see a black screen after a CMOS
  reset or a BIOS update, boot image B.

## 7. Rollback

```bash
# from GRUB/syslinux select image B, then
sudo -i
mount -o remount,rw /
EFI=/tmp/grub_mnt
cp -a /tmp/vmlinuz.A.backup "$EFI/syslinux/vmlinuz.A"
rm -rf /lib/modules/6.12.54-01180-gb4e10020ba49-dirty
sync && reboot
```

If the machine will not boot at all: boot a FydeOS U-disk, mount the internal EFI
partition and restore `syslinux/vmlinuz.A` from your backup.
