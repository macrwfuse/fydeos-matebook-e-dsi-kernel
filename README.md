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
| `patches/0001-drm-i915-dsi-skip-native-mipi-gpio-on-huawei-matebook-e.patch` | 6.1 … 6.12+ | DMI-matches HUAWEI `DRC-WXX` (the MateBook E 2022 product name — it does **not** contain "MateBook E") and HUAWEI `MateBook E*`, then skips the native MIPI GPIO sequence, keeping the firmware-programmed panel state. Also exposes `i915.dsi_native_gpio_bypass={-1,0,1}` so you can force it on/off or test other machines. |
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
| `patches/0008-netfilter-xt-quota2.patch` | `NETFILTER_XT_MATCH_QUOTA2`, `NETFILTER_XT_MATCH_QUOTA2_LOG` | `xt_quota2` iptables match; the FydeOS netfilter rules reference it by name, and a missing match makes `iptables-restore` fail. Counters are kept per network namespace, as in the stock kernel, otherwise ARC's `globalAlert` counter is invisible and `system_server` restarts in a loop. See §3.5. |
| `patches/0009-bpf-allow-bpffs-mount-in-userns.patch` | none (behavioural) | Lets the Android container mount `bpffs`. See §3.3. |
| `patches/0010-bpf-check-token-capabilities-in-callers-userns.patch` | none (behavioural) | Lets `bpf()` succeed inside the container's user namespace, which `netd`, `gpuservice` and `bpfloader` all need. See §3.4. |

`build-kernel.sh` asserts all nine symbols end up `=y` after `olddefconfig`, and separately
asserts that patches 0003, 0008, 0009 and 0010 landed (`security/chromiumos/android_whitelists.h`,
`net/netfilter/xt_quota2.c`, `kernel/bpf/inode.c`, `kernel/bpf/token.c`); a build that drops
any of them fails instead of shipping.

### 3.3 bpffs in a user namespace (ARC startup)

The upstream 6.12 `bpf_fill_super()` has

```c
if (fc->user_ns != &init_user_ns && !capable(CAP_SYS_ADMIN))
        return -EPERM;
```

`capable()` tests for `CAP_SYS_ADMIN` in the **initial** user namespace. The Android
container's `libminijail` calls `unshare(CLONE_NEWUSER)`, then `unshare(CLONE_NEWNS)`, and
performs every entry of `/opt/google/containers/android/config.json` inside that namespace.
That the container holds `CAP_SYS_ADMIN` in its own namespace is not in question: entries
3, 8, 10, 12, 15, 22 (tmpfs) and 23 (sysfs) come earlier and all carry `FS_USERNS_MOUNT`,
so `mount_capable()` → `ns_capable(fc->user_ns, CAP_SYS_ADMIN)` already passed for them.
The `EPERM` therefore comes from the check inside `bpf_fill_super()`, not from the generic
mount permission test.
Entry 26 is `{"type":"bpf","source":"bpf","destination":"/sys/fs/bpf",
"options":["rw","nosuid","nodev","noexec"]}`, so it hits exactly this check and gets
`EPERM`. `libminijail` then exits with `MINIJAIL_ERR_MOUNT` (251) and `run_oci` reports
`start failed: /run/containers/android-run_oci: Operation not permitted (1)` — ARC never
starts and `arc_manager` answers `ContainerStartupFail`. The reason is visible only in
`/var/log/arc.log` (the `arc-*` tags are routed away from `messages` by
`/etc/rsyslog.d/rsyslog.arc.conf`):

```
libminijail[1]: cannot mount 'bpf' as '/opt/google/containers/android/rootfs/root/sys/fs/bpf' with flags 0xe: Operation not permitted
libminijail[1]: mount_one failed with /dev at '(null)'
libminijail[5806]: child process 6224 exited with status 251
```

ChromiumOS changed the check to `ns_capable(fc->user_ns, CAP_SYS_ADMIN)` — the namespace
doing the mount only needs `CAP_SYS_ADMIN` **within itself**. This was confirmed by
disassembling the stock FydeOS v23.1 kernel image: `bpf_fill_super` there loads
`fc->user_ns` into a register, compares it against `init_user_ns`, and calls `ns_capable`,
while our tree called `capable`. The delegate-option check further down in
`bpf_parse_param()` stays `capable()` in both, and ARC passes no `delegate_*` option.

Widening this is contained: the flags in `config.json` are exactly what
`chromiumos_security_sb_mount()` demands of an unprivileged user namespace
(`CONFIG_SECURITY_CHROMIUMOS_NO_UNPRIVILEGED_UNSAFE_MOUNTS` requires
`MS_NOSUID|MS_NODEV|MS_NOEXEC`), so the LSM is still the gatekeeper for anything that
tries to mount bpffs with looser flags. No other mount in the container config needs a
change: `proc`, `sysfs`, `devpts`, `tmpfs` and `overlay` all carry `FS_USERNS_MOUNT` and
`mount_capable()` already uses `ns_capable()` for them.

### 3.4 BPF capabilities in a user namespace (Android services)

Fixing the mount is necessary but not sufficient. FydeOS ships
`kernel.unprivileged_bpf_disabled = 1` in `/etc/sysctl.d/00-sysctl.conf`, so from the
first `bpf(BPF_MAP_CREATE)` onwards every call has to pass a capability check. Both trees
check it the same way:

```c
/* kernel/bpf/syscall.c, map_create() */
if (sysctl_unprivileged_bpf_disabled && !bpf_token_capable(token, CAP_BPF))
        goto put_token;          /* err = -EPERM */
```

and nothing in the container has a BPF token, so this always reduces to
`bpf_token_capable(NULL, CAP_BPF)`, which is a capability test on whichever user
namespace the function picks. Upstream picks the initial one:

```c
/* kernel/bpf/token.c — chromeos-6.12 source as published */
userns = token ? token->userns : &init_user_ns;
```

The container root holds `CAP_BPF` and `CAP_SYS_ADMIN` in **its own** user namespace
(`CapEff = 000001ffffffffff`, and entry 1 of `config.json` is `{"type":"user"}`), not in
`init_user_ns`, so `ns_capable(&init_user_ns, CAP_BPF)` is false and the call fails. The
stock FydeOS kernels do not behave that way — both the v23.0 and v23.1 images resolve the
no-token case to the caller's credentials:

```
; v23.0 vmlinuz, bpf_token_capable
0xffffffff812d35e3: test rdi, rdi                  ; token == NULL?
0xffffffff812d35e6: je   0xffffffff812d35ee
0xffffffff812d35e8: lea  rax, [r14 + 0x28]         ; -> token->userns
0xffffffff812d35ec: jmp  0xffffffff812d3603
0xffffffff812d35ee: mov  rcx, qword ptr gs:[0x2dfc0]   ; current
0xffffffff812d35f7: mov  eax, 0x90
0xffffffff812d35fc: add  rax, qword ptr [rcx + 0x850]  ; -> cred->user_ns
0xffffffff812d3603: mov  r15, qword ptr [rax]
0xffffffff812d3606: mov  rdi, r15
0xffffffff812d3609: mov  esi, ebx
0xffffffff812d360b: call 0xffffffff81138f80           ; ns_capable(userns, cap)
```

(In the stock image `current` is at `gs:0x2dfc0`; `cred` is at `task_struct + 0x850` and
`user_ns` at `cred + 0x90`, the same offsets our build uses.) `patches/0010` changes the
source to match:

```c
userns = token ? token->userns : current_user_ns();
```

The earlier release, which had only `patches/0009`, shows exactly what this costs. The
mount succeeds and `/sys/fs/bpf` exists, but the services that use it die:

* `netd` exits with status 1 in a restart loop; logcat shows
  `BpfHandler: Failed to get program from /sys/fs/bpf/netd_shared/...: No such file or
  directory` followed by `NetdUpdatable: BPF handler init failed` — `bpfloader` cannot
  pin anything, so the maps never appear.
* `gpuservice` aborts (SIGABRT) every few seconds inside
  `android::bpf::BpfMap<GpuIdUid, UidTrackingInfo>::BpfMap()`.
* `sys.boot_completed` never gets set and `zygote` stays `restarting`.

`bpffs` being mounted and writable is what makes this look like a userspace problem;
it is the `bpf()` syscall that is being refused. That is also why deleting the
`unprivileged_bpf_disabled` line would not be a fix even if it were writable — it is
locked at 1 by the kernel, and reopening it would weaken the whole system to work around
a single missing namespace-aware check.

### 3.5 Network namespaces: xt_quota2 and statx (ARC apps crashing)

Two independent defects in the forward-ported Android bits make every app die once the
container is up. Both were confirmed by disassembling the stock v23.0 kernel.

**a. `xt_quota2` must keep its counters per netns.** Upstream's 2008 code keeps one
`static LIST_HEAD(counter_list)` plus one `proc_xt_quota` created by
`proc_net_mkdir(&init_net, ...)`, i.e. every named counter lives under *init_net*'s
`/proc/net/xt_quota`. ARC starts with `"namespaces": [..., "network", ...]`, so netd
installs its quota2 rules in the container's own netns and then opens
`/proc/net/xt_quota/globalAlert` — a path in that netns' procfs, which is a different
directory tree. Measured on the target machine:

```
container: /proc/self/net/xt_quota/  -> No such file or directory
host:      /proc/net/xt_quota/       -> -rw-r--r-- root root globalAlert
```

The resulting loop, every ~90 s:

```
E BandwidthController: Updating quota globalAlert failed (Status[code: 2,
    msg: "... fopen("/proc/net/xt_quota/globalAlert","we") failed"])
E AndroidRuntime: *** FATAL EXCEPTION IN SYSTEM PROCESS: NetworkStats
    Caused by: ServiceSpecificException: No such file or directory (code 2)
      at INetd$Stub$Proxy.bandwidthSetGlobalAlert
      at NetworkStatsService.registerGlobalAlert
I Process: Sending signal. PID: 9772 SIG: 9
```

Every app dies together with `system_server`, which users see as "the app opens and then
crashes". `patches/0008` therefore mirrors the stock implementation (recovered from
`vmlinux`: a `pernet_operations` with `id`/`size`, `proc_mkdir("xt_quota", net->proc_net)`
in `init`, `remove_proc_subtree()` in `exit`, and `par->net` used for both counter lookup
and teardown) instead of the global singletons.

**b. `statx` must be on the Android alt-syscall whitelist.** Our whitelist had
`renameat2(316)` where the stock table has `statx(332)`. Syscalls absent from the table
return `ENOSYS` under `altSyscall = "android"`:

```
system_server: blocked syscall 332 x9
E OpenGLRenderer: statx failed for /system/fonts/Roboto-Regular.ttf, errno = 38 (ENOSYS)
```

Only `libhwui.so` and `libandroid_runtime.so` in the ARC image import statx. Without it,
fs-verity detection always reports "not verified", so `libhwui`'s `hasVerity` abort path
never fires (this alone does not crash anything), but every font/asset stat fails and the
log fills with errors. Adding `statx` restores stock behaviour; the extra `renameat2`
entry is harmless and is left in place.

Both are asserted at build time: `build-kernel.sh` fails if
`register_pernet_subsys(&quota2_net_ops)`, `proc_mkdir("xt_quota", net->proc_net)` or
`q2_get_counter(par->net` disappears from `xt_quota2.c`, or if the Android whitelist loses
`SYSCALL_ENTRY(statx)`.

Verification on a booted system (no rebuild needed): the container must see its own
counter, i.e. `sudo /usr/sbin/android-sh -c 'ls /proc/net/xt_quota/'` lists `globalAlert`.
Before the fix that directory does not exist inside the container while the host's copy
holds `globalAlert`. Afterwards `logcat -b main -s BandwidthController NetworkStats`
should stay silent; before the fix it repeated every ~90 s.

### 3.6 openFyde patches

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

`config/fydeos-official-iris.config` is the config of the **kernel shipped in the FydeOS
v23.1 image** (`Iris` variant), extracted from the image's `vmlinuz` and cross-checked
symbol by symbol: 6989 `=y`/`=m` symbols, zero differences. That image kernel is the only
trustworthy baseline — the userspace is compiled against it and depends on specific
ABI-visible options. An approximation assembled from the public openFyde config loses
~450 `=y`/`=m` symbols.

Note that the kernel *running on the machine* is a different build: `uname -r` reports
`6.12.54-01180-gb4e10020ba49-dirty`, and its `/proc/config.gz` differs from this file in
657 symbols — it has no `ALT_SYSCALL`, `ASHMEM`, `UID_SYS_STATS`, `NETFILTER_XT_MATCH_QUOTA2`
or `DMABUF_HEAPS*`. Do not use it as the base; that build cannot run the Android container
at all. The remaining differences between this file and our own `config-…-mbe` output are
56 symbols, all of them toolchain probes (clang 21 vs gcc 13.3: `CC_IS_CLANG`, `LD_IS_LLD`,
`CFI_CLANG`, `DEBUG_INFO*`, `LTO_CLANG_*`, `PAHOLE_*`, …), no functional ones.

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
extracting).

To disable rootfs verification (needed so `/lib/modules` survives a reboot; takes effect
after a reboot):

```bash
sudo /usr/sbin/crossystem_mode-switch.sh disable-rootfs-verification
```

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

  On the target this line only appears if the DMI match succeeds. Kernels built before
  2025-11 do not match `DRC-WXX`, so either install the current build or pass
  `i915.dsi_native_gpio_bypass=1`; without it nothing is skipped and the screen still
  tears (seven `GPIO index ... native yes` lines, no `Not touching` line).

* `"[CRTC:..] DSB not used for DSI output, falling back to MMIO"` ⇒ patch 2 is live.
  Patch 2 is not required on this machine — `i915.enable_dsb=0` on the stock kernel
  leaves the tearing unchanged (§3.1).

`drm.debug=0x4` is extremely verbose; drop it again once you have the lines.

## 8. Status / disclaimer

The display fix is **confirmed on the target machine** (2025-11-04): the `-mbe` kernel
booted with `i915.dsi_native_gpio_bypass=1` on the command line reaches the desktop with
**no tearing** — the first build that has actually had its display bug fixed here.

That test also exposed a bug in the original patch: the target's DMI product name is
`DRC-WXX` (with `sys_vendor` = `HUAWEI`), not `MateBook E`, so the built-in DMI table
never matched and the skip never happened — the log showed seven
`GPIO index ... native yes` lines and zero `Not touching native DSI GPIOs` lines. The DMI
table now lists `DRC-WXX` explicitly (plus the marketing name for other SKUs), and
`build-kernel.sh` fails if that entry goes missing again. Release assets built after
2025-11-04 contain the fixed table; without it, pass the parameter on the kernel command
line.

Everything else that can be checked without the hardware has been:

* CI run [42014698997](https://github.com/macrwfuse/fydeos-matebook-e-dsi-kernel/actions/runs/42014698997)
  (`e9019b9f`) adds `patches/0010` and is green. Only `vmlinuz` and `modules-*.tar.gz`
  changed; `config`, `i915.ko` and `vermagic` did not — every one of the 1208 files in the
  module tree is byte-identical, so the whole difference is in `vmlinuz`. Extracting
  `vmlinux` and disassembling `bpf_token_capable` shows the no-token branch now loads the
  caller's `user_ns` (§3.4):

  ```
  0xffffffff8125d70d: test rdi, rdi                    ; token == NULL?
  0xffffffff8125d710: je   0xffffffff8125d718
  0xffffffff8125d712: mov  r13, qword ptr [rdi + 0x28] ; -> token->userns
  0xffffffff8125d718: mov  rax, qword ptr gs:[rip+0x7edd0d20]  ; current (gs:0x2e440)
  0xffffffff8125d720: mov  rax, qword ptr [rax + 0x850]        ; -> cred
  0xffffffff8125d727: mov  r13, qword ptr [rax + 0x90]         ; -> cred->user_ns
  0xffffffff8125d734: call 0xffffffff81105dc8                  ; ns_capable
  ```

  The previous build (`20e6e6b4`, run 41982604787) had `mov r13, &init_user_ns` there
  instead. `bpf_fill_super()` still calls `ns_capable(fc->user_ns, …)`, unchanged by this
  patch.
* CI run [41982604787](https://github.com/macrwfuse/fydeos-matebook-e-dsi-kernel/actions/runs/41982604787)
  (`20e6e6b4`) added `patches/0009` and was green: extracting `vmlinux` from its `vmlinuz`
  showed `cmp fc->user_ns, init_user_ns` → `mov esi, 0x15` → `call ns_capable`, matching
  the official v23.1 image (§3.3). It is superseded by `e9019b9f`, since the container
  still could not start without `0010`.
* CI run [41845841949](https://github.com/macrwfuse/fydeos-matebook-e-dsi-kernel/actions/runs/41845841949)
  (`cd8023e1`) rebuilt the kernel with the `DRC-WXX` entry and is green, but predates
  `patches/0009` — the Android container does not start on it.


* CI run [41773578775](https://github.com/macrwfuse/fydeos-matebook-e-dsi-kernel/actions/runs/41773578775)
  (`312b8705`) is a **full successful compile**: 9010 objects, 13218 log lines, zero
  warnings about a stock symbol disappearing. Every ported subsystem links:
  `fs/esdfs/*.o`, `ashmem.o`, `xt_quota2.o`, `uid_sys_stats.o`, `pkglist.o`,
  `kernel/alt-syscall.o`, `kernel/profile.o`.
* All 10 patches were replayed onto a pristine 6.12.54 tree with `patch -p1` and the result
  is byte-identical to the build tree — the tarball is reproducible from the repo.
* All five artifacts were re-hashed locally after download.
* `i915.enable_dsb=0` on the stock kernel changes nothing, so patch 2 is not what fixes
  this panel (§3.1).

The two earlier install attempts failed, and this revision is the response:

| What went wrong before | What changed |
|---|---|
| The build used the public openFyde 6.6 config as its base, which dropped ~450 `=y`/`=m` symbols relative to the stock config (including `SQUASHFS_XZ=y` and the six ported ChromiumOS subsystems). The resulting kernel could not mount its own root filesystem. | Base config is now the config of the kernel inside the official v23.1 `iris` image (6989 `=y`/`=m` symbols, zero diff against the image's `vmlinuz`); `build-kernel.sh` fails the build if any of those symbols disappears after `olddefconfig`. §4 |
| The release string was `...-dirty`, identical to the stock kernel. Extracting the module tarball at `/` overwrote the stock `/lib/modules` tree, so a failed install left a system that could not load any module. | Release is now `...-mbe`, a separate `/lib/modules` directory. §4 |
| `/` has only ~90 MB free and the module tree is ~132 MB, so the extract runs out of space partway. | Move the stock module tree to H-STATE first (§6); verify 1195 `.ko` files before rebooting. |
| The kernel installed and booted, but the screen still tore: patch 1 was present yet inactive, because the DMI table matched only `MateBook E*` while the machine reports `DRC-WXX`. The log showed seven `GPIO index ... native yes` and no `Not touching native DSI GPIOs`. | `DRC-WXX` added to the DMI table; `build-kernel.sh` now asserts the entry exists. |

Keep a rollback path (syslinux image B) ready — `docs/INSTALL.md` §8.

A second experiment has also been run on the target machine: the **stock** kernel with
`i915.enable_dsb=0` on the command line (no disk writes) still tears identically, so the
DSB half of the fix (patch 2) is **not** what matters on this panel — patch 1 is. See §3.1.

Patches are GPL-2.0, same as the kernel.
