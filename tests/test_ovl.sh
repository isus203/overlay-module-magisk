#!/bin/sh
# Host test of module/ovl.sh: a fake device tree under a temp directory and
# stubs for the commands that need root (mount, chcon, losetup, mke2fs,
# mknod). Checks which directories get an overlay, what is refused, file
# modes in the layer and the second-run path. Run: sh tests/test_ovl.sh
set -u

HERE=$(cd "${0%/*}" && pwd)
ENGINE=$HERE/../module/ovl.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
R=$T/root
MOD=$T/modules/test_mod
STUB=$T/stub
CALLS=$T/calls
MOUNTS=$T/mounts
FAILS=0

check() {
  if [ "$2" = "$3" ]; then
    echo "PASS $1"
  else
    echo "FAIL $1"
    echo "  expected: $(echo "$3" | tr '\n' ' ')"
    echo "  got:      $(echo "$2" | tr '\n' ' ')"
    FAILS=$((FAILS + 1))
  fi
}

# Fake device
mkdir -p "$R/system/etc/permissions" "$R/system/priv-app/Settings" \
  "$R/system/app/MusicFX" "$R/system/bin" "$R/vendor/etc" \
  "$R/vendor/lib/soundfx"
echo real > "$R/system/etc/permissions/platform.xml"
echo real > "$R/vendor/etc/x.conf"
chmod 0600 "$R/vendor/etc/x.conf"
ln -s "$R/vendor" "$R/system/vendor"

# Module
mkdir -p "$MOD/ovl/system/etc/permissions" "$MOD/ovl/system/priv-app/MyApp" \
  "$MOD/ovl/vendor/etc/newdir" "$MOD/ovl/system/vendor/lib/soundfx" \
  "$MOD/ovl/system/newtop" "$MOD/ovl/system/bin"
echo new > "$MOD/ovl/system/etc/permissions/my.xml"
echo apk > "$MOD/ovl/system/priv-app/MyApp/MyApp.apk"
echo mod > "$MOD/ovl/vendor/etc/x.conf"
echo y > "$MOD/ovl/vendor/etc/newdir/y"
echo so > "$MOD/ovl/system/vendor/lib/soundfx/libfx.so"
echo top > "$MOD/ovl/system/newtop/file"
echo tool > "$MOD/ovl/system/bin/tool"
chmod 0644 "$MOD/ovl/system/bin/tool"
cat > "$MOD/ovl.conf" <<EOF
OVL_HIDE="/system/app/MusicFX /system/app/NotThere"
OVL_IMG_MB=1
EOF

# Stubs
mkdir -p "$STUB"
cat > "$STUB/mount" <<EOF
#!/bin/sh
echo "mount \$*" >> "$CALLS"
for a; do tgt=\$a; done
case " \$* " in
  *" -t ext4 "*) mkdir -p "\$tgt"; echo "/dev/loop0 \$tgt ext4 rw 0 0" >> "$MOUNTS";;
  *" -t overlay "*) echo "x \$tgt overlay ro 0 0" >> "$MOUNTS";;
esac
exit 0
EOF
for c in chcon losetup mke2fs dmesg; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$c" "$CALLS" > "$STUB/$c"
done
printf '#!/bin/sh\necho "mknod $*" >> "%s"\n: > "$1"\n' "$CALLS" > "$STUB/mknod"
chmod +x "$STUB"/*
echo "nodev overlay" > "$T/filesystems"
: > "$MOUNTS"

run_engine() {
  (PATH=$STUB:$PATH MODPATH=$MOD MODID=test_mod OVL_ROOT=$R \
    OVL_MOUNTS=$MOUNTS OVL_FILESYSTEMS=$T/filesystems . "$ENGINE")
}

# First boot
: > "$CALLS"
run_engine
got=$(grep -o 'lowerdir=[^ ]*' "$CALLS" | sed "s|lowerdir=$R/dev/ovl_test_mod||; s|:.*||" | sort)
check "overlay targets" "$got" "/system/app
/system/bin
/system/etc/permissions
/system/priv-app
/system/vendor/lib/soundfx
/vendor/etc"
check "symlinked target mounts on real path" \
  "$(grep -c "lowerdir=$R/dev/ovl_test_mod/system/vendor/lib/soundfx:$R/vendor/lib/soundfx $R/vendor/lib/soundfx" "$CALLS")" 1
check "partition root refused" "$(grep -c 'refused target /system:' "$MOD/ovl.log")" 1
check "status" "$(sort "$MOD/ovl.status")" "ok /system/app
ok /system/bin
ok /system/etc/permissions
ok /system/priv-app
ok /system/vendor/lib/soundfx
ok /vendor/etc"
check "whiteout only for existing entry" "$(grep mknod "$CALLS" | sed "s|$R||")" \
  "mknod /dev/ovl_test_mod/system/app/MusicFX c 0 0"
L=$R/dev/ovl_test_mod
check "new bin file is executable" "$(stat -c %a "$L/system/bin/tool")" 755
check "replaced file keeps real mode" "$(stat -c %a "$L/vendor/etc/x.conf")" 600
check "layer has file content" "$(cat "$L/system/priv-app/MyApp/MyApp.apk")" apk
check "image remounted ro" "$(grep -c "remount,ro $L" "$CALLS")" 1

# Second run in the same boot: nothing is remounted, status still reported
: > "$CALLS"
run_engine
check "second run mounts nothing" "$(grep -c 'mount' "$CALLS")" 0
check "second run status" "$(grep -c '^ok' "$MOD/ovl.status")" 6

# Kernel without overlayfs
: > "$T/filesystems"
: > "$MOUNTS"
run_engine
check "no overlayfs is logged" "$(grep -c 'no overlayfs' "$MOD/ovl.log")" 1

[ "$FAILS" -eq 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
