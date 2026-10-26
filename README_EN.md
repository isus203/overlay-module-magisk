# Magisk module template with overlayfs

[Русский](README.md) · **English**

A clean starter module: put your files into `module/ovl/`, build the zip with
one command, and the files appear in `/system`, `/vendor`, `/product` and so
on. No Magic Mount, no thousands of extra mounts, no bootloop caused by them.

The mechanism comes from the ArkamysAudio module (v2.0-beta.5 … beta.9),
where it was debugged and verified on a real phone: TECNO SPARK 9 Pro,
Android 12, kernel 4.19, MediaTek, Magisk 30.7.

Works with Magisk (v20.4+), KernelSU and APatch.

---

## The problem it solves

### 1. Bootloop from an exhausted system property area

When a module adds a **new** file or directory to an **existing** directory
(for example its own `/vendor/etc/myconfig/` or a new app in
`/system/priv-app/`), Magisk Magic Mount cannot simply "add" the entry: it
puts a tmpfs over that directory and **bind-mounts every sibling file** of
the original directory separately.

For every such mount `init` creates a `dev.mnt.blk.*` system property, and
properties live in an area of fixed size. Real numbers from the TECNO SPARK
9 Pro (ArkamysAudio beta.1):

| What the module added               | Mounts it caused |
|-------------------------------------|-----------------:|
| new directory in `/vendor/etc`      | 649 |
| new directory in `/system/etc`      | 546 |
| new jar in `/system/framework`      | 351 |
| new binary in `/system/bin`         | 221 |
| new app in `/system/priv-app`       | 157 |

About 2000 properties in total. The property area ran out, `system_server`
died in `SystemProperties.set(...)` with `__system_property_add failed`, and
the phone **bootlooped**. The module did nothing wrong; it only added a few
files.

**This template** makes **one** overlayfs mount per affected directory
instead. The same ArkamysAudio files after the switch: 4 overlays + 1 image
instead of ~2000 mounts, zero property failures, the phone boots.

### 2. overlayfs does not "just work" on Android; this template handles it

A hand-made overlay hits three walls in turn (all three were seen on a real
device):

| Attempt                                 | Error                        | Cause |
|-----------------------------------------|------------------------------|-------|
| layer directly in `/data/adb/modules/…` | `Invalid argument` (EINVAL)  | `/data` is f2fs with encryption/casefold, overlayfs rejects it |
| layer in tmpfs (`/dev/…`)               | `Operation not supported`    | tmpfs has no xattr, SELinux cannot read labels |
| layer in an ext4 image on a loop device | `I/O error` on mount         | SELinux denies the loop worker (`kernel` domain) reading a `system_file` file |

The working scheme: at boot the files from `ovl/` are copied into an ext4
image `ovl.img` (like KernelSU's `modules.img`). The image is labelled
`adb_data_file`, and `sepolicy.rule` lets the kernel read it. Every layer
file gets the right owner, mode and SELinux label, then the image is
remounted read-only and the overlays go on top of the real directories.

### 3. Advantages

- **No property bootloop**: one mount point per directory, however many
  files you add.
- **Fewer traces**: fewer mount points, a simpler and faster boot, a clean
  `/proc/mounts`.
- **Correct SELinux labels automatically**: a new file takes the label of the
  file it replaces or of its nearest existing parent. Special cases (a HAL
  binary) take one line in `ovl.conf`.
- **Hide system apps or files** without `REPLACE` (which also inflates the
  mount count in Magisk), using overlayfs whiteouts.
- **Read-only**: the image and the overlays are mounted `ro`, so the system
  cannot write into them by accident.
- **Clean removal**: the module changes nothing on the partitions. Disable or
  remove it in the app and after a reboot everything is as before.
- **Edit without rebuilding**: change a file in `/data/adb/modules/<id>/ovl/`,
  reboot, done (the layer is rebuilt on every boot).
- **One-tap diagnostics**: the "Action" button in the Magisk/KSU app shows
  which directories are mounted, the `dev.mnt.blk` property count and the log.
- **Does not break other modules**: `module/system/` still works for plain
  Magic Mount (see below when that makes sense).

---

## Layout

```
overlay-module-template/
├── build.sh                ← builds out/<id>-<version>.zip
├── tests/test_ovl.sh       ← engine test on a PC (no phone needed)
└── module/                 ← the contents of the zip
    ├── META-INF/...        standard Magisk installer, do not touch
    ├── module.prop         id, name, version: MUST be changed
    ├── customize.sh        runs at install (add your own steps)
    ├── post-fs-data.sh     Magisk: runs ovl.sh at boot
    ├── post-mount.sh       KernelSU/APatch: runs ovl.sh at boot
    ├── ovl.sh              overlay engine, normally left as is
    ├── ovl.conf            engine settings
    ├── sepolicy.rule       SELinux rules for the image and labels
    ├── action.sh           "Action" button: status and log
    └── ovl/                ← YOUR FILES, at their real paths on the phone
        └── system/etc/ovl_template/README.txt   (example, delete it)
```

---

## Building your own module, step by step

### Step 1. Copy the template

```sh
cp -r overlay-module-magisk my-module
cd my-module
```

### Step 2. Fill in `module/module.prop`

```properties
id=my_module
name=My Module
version=v1.0
versionCode=1
author=Your name
description=What the module does
```

`id` must be unique: Latin letters, digits, `.`, `_`, `-`, starting with a
letter. The module lives in `/data/adb/modules/<id>` and the image is
mounted at `/dev/ovl_<id>`. Increase `versionCode` on every update.

### Step 3. Delete the example and put your files into `module/ovl/`

The path inside `ovl/` is the path on the phone.

```sh
rm -r module/ovl/system/etc/ovl_template
```

| Wanted on the phone                            | Put it at                                            |
|------------------------------------------------|------------------------------------------------------|
| `/system/priv-app/MyApp/MyApp.apk`             | `module/ovl/system/priv-app/MyApp/MyApp.apk`         |
| `/system/etc/permissions/privapp-my.app.xml`   | `module/ovl/system/etc/permissions/privapp-my.app.xml` |
| `/vendor/etc/myconfig/settings.xml`            | `module/ovl/vendor/etc/myconfig/settings.xml`        |
| `/vendor/lib64/soundfx/libmyfx.so`             | `module/ovl/vendor/lib64/soundfx/libmyfx.so`         |
| replace `/vendor/etc/audio_effects.xml`        | `module/ovl/vendor/etc/audio_effects.xml`            |
| `/system/bin/mytool`                           | `module/ovl/system/bin/mytool` (becomes 0755 by itself) |
| `/product/overlay/MyRRO.apk`                   | `module/ovl/product/overlay/MyRRO.apk`               |

Prefer `vendor/...` over `system/vendor/...` for clarity. `system/vendor/...`
works too: the engine follows the symlink and mounts on the real directory.

Rules:

- **No spaces** in file or directory names (`build.sh` checks this).
- **No files directly in a partition root** (`ovl/system/myfile`, or
  `ovl/vendor/newdir/...` when `newdir` does not exist). The engine refuses
  to overlay all of `/system` or `/vendor` because that is too risky. Such a
  path is skipped with `refused target` in `ovl.log`; the other files are
  mounted as usual. Go at least one level below an existing directory
  (`/system/etc/...`, `/vendor/etc/...`).
- Scripts with Windows line endings (CRLF) do not run; `build.sh` finds them.

### Step 4. Adjust `module/ovl.conf` if needed

```sh
# Directories to overlay. Empty = detected from ovl/ (recommended).
OVL_TARGETS=""

# Hide existing files/directories (whiteouts), space separated:
OVL_HIDE="/system/app/MusicFX /system/priv-app/AudioFX"

# Custom SELinux labels, one "path=context" per line.
# Needed for example for the executable of a new HAL service:
OVL_LABELS="/vendor/bin/hw/vendor.my.hal-service=u:object_r:hal_my_default_exec:s0"

# Size of ovl.img in MiB. 0 = (size of ovl/ x 2) + 8.
OVL_IMG_MB=0
```

If `OVL_LABELS` uses a label that is not in `sepolicy.rule`, add it to the
`... labeledfs filesystem associate` line there, otherwise `chcon` cannot set
it.

### Step 5. Your own install and boot steps

- Install checks (Android version, architecture, conflicting modules) go at
  the end of `module/customize.sh`. `ui_print`, `abort`, `$API`, `$ARCH`,
  `$MODPATH`, `set_perm` and `set_perm_recursive` are available there.
- Code after boot: create `module/service.sh` (a normal Magisk script that
  runs in the background).
- Extra SELinux rules: append them to `module/sepolicy.rule`.
- System properties: `module/system.prop` (standard Magisk).

**Do not touch** the lines that run `ovl.sh` in `post-fs-data.sh` and
`post-mount.sh`. If you need your own post-fs-data code, put it **after** the
line `. "$MODPATH/ovl.sh"`.

### Step 6. Build

On a Linux/macOS PC, in WSL or in Termux:

```sh
sh build.sh
```

You get `out/<id>-<version>.zip`. The script checks `module.prop`, the
syntax of every `.sh`, spaces in paths and CRLF.

Without `build.sh` (on Windows, for example), zip the **contents** of the
`module/` folder so that `module.prop` and `META-INF/` are at the root of
the archive, not inside a `module/` folder.

If you changed `ovl.sh`, run the engine test:

```sh
sh tests/test_ovl.sh
```

### Step 7. Install and check on the phone

1. Magisk / KernelSU / APatch → Modules → Install from storage → the zip.
2. Reboot.
3. Tap the module's **"Action"** button. You should see something like:
   ```
   Overlay status:
   ok /system/priv-app
   ok /vendor/etc

   dev.mnt.blk properties: <tens, not thousands>
   ```
   On `fail`, read the log below it in the same window and see
   "Troubleshooting".
4. Manual check (in `su` or `adb shell`):
   ```sh
   grep ovl_ /proc/mounts            # the image on a loop device
   grep " overlay " /proc/mounts     # overlays on your directories
   ls -lZ /vendor/etc/myconfig/      # your files and their labels
   cat /data/adb/modules/<id>/ovl.log
   ```

---

## `ovl/` or plain `system/`?

| Case | Where |
|---|---|
| A **new** file or directory in an existing directory | `ovl/`: this is exactly where Magic Mount creates hundreds of mounts |
| Hide an app or file | `OVL_HIDE` in `ovl.conf` (not `REPLACE`) |
| Replace one **existing** file | either works: Magisk uses one bind mount for a replacement. `ovl/` keeps things uniform and labels correctly |
| Kernel without overlayfs | only `system/` (plain Magisk) |

---

## Troubleshooting

| Symptom in `ovl.log` / `dmesg` | Meaning and fix |
|---|---|
| `kernel has no overlayfs` | The kernel lacks overlayfs. The template cannot help; use plain `system/` |
| `cannot mount .../ovl.img`, `dmesg` shows `avc: denied ... scontext=u:r:kernel:s0` | The `sepolicy.rule` rule was not applied. Check the file is in the module and reinstall |
| `FAILED /x/y` + `Invalid argument` | The layer ended up on `/data`. Do not change paths in `ovl.sh`; the layer must be in `ovl.img` |
| `FAILED /x/y` + `Operation not supported` / `no security xattr handler` | The layer ended up in tmpfs. Same: do not change the paths |
| `refused target /system` | A file sits directly in a partition root. Move it deeper |
| The file is visible but a service/app cannot open it, logcat shows `avc: denied` | Wrong label. Set the right one in `OVL_LABELS` and add it to `sepolicy.rule` |
| A `priv-app` app does not start, `pm` does not list it | Missing privileged permission whitelist: put `privapp-permissions-*.xml` into `ovl/system/etc/permissions/` |
| Bootloop | Hold volume down during boot (Magisk safe mode disables all modules) or delete `/data/adb/modules/<id>` from recovery |

---

## Limitations

- The kernel needs overlayfs (present in almost every Android 8+ kernel).
- No spaces in paths.
- No new files directly in a partition root.
- If **another** module adds files to the same directory through plain Magic
  Mount, Magisk's tmpfs goes on top of your overlay. Test such module pairs
  together.
- On KernelSU in overlayfs mode (not magic mount) the original problem does
  not exist; the template works there but gains little. The main benefit is
  for Magisk and for KernelSU/APatch builds that use magic mount.
- `ovl.img` takes space on `/data` (by default twice the size of `ovl/`
  plus 8 MiB).

---

## What has been tested

- The mechanism itself (ext4 image on loop, `adb_data_file` label, the rule
  for `kernel`, overlays on `/vendor/etc`, `/system/etc/permissions`,
  `/system/etc/sysconfig`, `/system/priv-app`, a whiteout for MusicFX) works
  on a device in ArkamysAudio v2.0-beta.5 … beta.9: TECNO SPARK 9 Pro,
  Android 12, kernel 4.19, Magisk 30.7.
- The generic engine of the template (`ovl.sh`: target detection, labels
  from the nearest parent, modes, refusing partition roots, the second run)
  is covered by `tests/test_ovl.sh` on a PC with stubs. **The template itself
  has not been run on a phone yet.** Install the zip as is first and check
  that `/system/etc/ovl_template/README.txt` is readable.
