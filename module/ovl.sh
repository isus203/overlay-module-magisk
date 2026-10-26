#!/system/bin/sh
# Overlay engine of the overlay module template.
#
# Sourced by post-fs-data.sh (Magisk) or post-mount.sh (KernelSU, APatch)
# with MODPATH set. Everything under $MODPATH/ovl/<real path> is merged
# into the system with one read-only overlayfs mount per target directory,
# instead of Magisk Magic Mount, which mounts every sibling file of a new
# entry separately (and init then sets one dev.mnt.blk.* property per mount).
#
# Layer filesystem: overlayfs rejects layers on /data (f2fs with
# encryption/casefold, EINVAL) and on tmpfs without xattr (SELinux label
# lookup fails, EOPNOTSUPP), so the layer is copied into an ext4 image on a
# loop device. See sepolicy.rule for the loop worker permission.
#
# Paths under ovl/ must not contain spaces.
#
# OVL_ROOT, OVL_MOUNTS and OVL_FILESYSTEMS exist only for the host test
# harness; on a device they keep their defaults.

OVL_ID=${MODID:-${MODPATH##*/}}
OVL_SRC=$MODPATH/ovl
OVL_IMG=$MODPATH/ovl.img
OVL_MNT=$OVL_ROOT/dev/ovl_$OVL_ID
OVL_LOG=$MODPATH/ovl.log
OVL_STATUS=$MODPATH/ovl.status
OVL_MOUNTS=${OVL_MOUNTS:-/proc/mounts}
OVL_FILESYSTEMS=${OVL_FILESYSTEMS:-/proc/filesystems}

OVL_TARGETS=
OVL_HIDE=
OVL_LABELS=
OVL_IMG_MB=0
[ -f "$MODPATH/ovl.conf" ] && . "$MODPATH/ovl.conf"

ovl_log() {
  echo "$*" >> "$OVL_LOG"
}

# Deepest existing path on the device for logical path $1 (prints logical path).
ovl_existing() {
  _p=$1
  while [ -n "$_p" ] && [ ! -e "$OVL_ROOT$_p" ]; do
    _p=${_p%/*}
  done
  echo "${_p:-/}"
}

ovl_label() {
  ls -Zd "$1" 2>/dev/null | awk '{print $1}'
}

# Explicit label for logical path $1 from OVL_LABELS ("path=context" lines).
ovl_label_override() {
  echo "$OVL_LABELS" | while IFS='=' read -r _k _v; do
    [ "$_k" = "$1" ] && { echo "$_v"; break; }
  done
}

ovl_mounted() {
  grep -q " $1 $2 " "$OVL_MOUNTS"
}

# Target directories: the parent of every replaced or hidden entry and the
# deepest existing ancestor of every new entry, without nested duplicates.
ovl_find_targets() {
  _list=
  if [ -n "$OVL_TARGETS" ]; then
    _list=$OVL_TARGETS
  else
    for _f in $(cd "$OVL_SRC" && find . -mindepth 1 | sed 's|^\.||'); do
      if [ -d "$OVL_SRC$_f" ] && [ -d "$OVL_ROOT$_f" ]; then
        continue
      fi
      if [ -e "$OVL_ROOT$_f" ]; then
        _list="$_list ${_f%/*}"
      else
        _list="$_list $(ovl_existing "$_f")"
      fi
    done
  fi
  for _h in $OVL_HIDE; do
    [ -e "$OVL_ROOT$_h" ] && _list="$_list ${_h%/*}"
  done
  # A partition root or / would shadow the whole partition: refuse it before
  # the nesting check, or it would swallow every valid target below it. The
  # check uses the real path, so /system/vendor (a symlink) is caught too.
  _ok=
  for _t in $(for _t in $_list; do echo "$_t"; done | sort -u); do
    _r=$(realpath "$OVL_ROOT$_t" 2>/dev/null)
    _r=${_r#"$OVL_ROOT"}
    case ${_r:-/} in
      /|/system|/vendor|/product|/system_ext|/odm|/my_product|/data|/dev)
        ovl_log "refused target $_t: too wide, put the file one level deeper"
        continue;;
    esac
    _ok="$_ok $_t"
  done
  for _t in $_ok; do
    _nested=false
    for _u in $_ok; do
      case $_t in "$_u"/*) _nested=true; break;; esac
    done
    $_nested || echo "$_t"
  done
}

ovl_make_img() {
  rm -f "$OVL_IMG"
  _mb=$OVL_IMG_MB
  case $_mb in
    ''|0) _mb=$(( $(du -sm "$OVL_SRC" | awk '{print $1}') * 2 + 8 ));;
  esac
  ovl_log "creating ovl.img, $_mb MiB"
  dd if=/dev/zero of="$OVL_IMG" bs=1048576 count="$_mb" 2>/dev/null
  /system/bin/mke2fs -t ext4 -F "$OVL_IMG" >/dev/null 2>&1 \
    || mke2fs -F "$OVL_IMG" >/dev/null 2>&1
}

# The loop worker reads and writes the image as u:r:kernel:s0.
ovl_mount_img() {
  chcon u:object_r:adb_data_file:s0 "$OVL_IMG"
  mount -t ext4 -o loop,rw,noatime "$OVL_IMG" "$OVL_MNT" 2>/dev/null && return 0
  _loop=$(losetup -f)
  losetup "$_loop" "$OVL_IMG" || return 1
  mount -t ext4 -o rw,noatime "$_loop" "$OVL_MNT" && return 0
  losetup -d "$_loop"
  return 1
}

# Owner and SELinux label of every layer entry follow the real file it
# replaces, else its nearest existing ancestor, unless OVL_LABELS names one.
# A replaced file keeps its real mode; a new file in a bin/ directory gets
# 0755, any other new file keeps the mode set by customize.sh.
ovl_fix_attrs() {
  for _f in $(cd "$OVL_MNT" && find . -mindepth 1 | sed 's|^\.||'); do
    case $_f in /lost+found|/lost+found/*) continue;; esac
    _ref=$OVL_ROOT$(ovl_existing "$_f")
    _con=$(ovl_label_override "$_f")
    [ -z "$_con" ] && _con=$(ovl_label "$_ref")
    [ -n "$_con" ] && chcon "$_con" "$OVL_MNT$_f" 2>/dev/null
    [ -c "$OVL_MNT$_f" ] && continue
    chown "$(stat -c %u:%g "$_ref")" "$OVL_MNT$_f" 2>/dev/null
    if [ -d "$OVL_MNT$_f" ]; then
      chmod 0755 "$OVL_MNT$_f"
    elif [ "$_ref" = "$OVL_ROOT$_f" ]; then
      chmod "$(stat -c %a "$_ref")" "$OVL_MNT$_f"
    else
      case $_f in */bin/*|*/xbin/*) chmod 0755 "$OVL_MNT$_f";; esac
    fi
  done
}

ovl_run() {
  : > "$OVL_LOG"
  : > "$OVL_STATUS"
  ovl_log "$(date) $OVL_ID"
  [ -d "$OVL_SRC" ] || { ovl_log "no ovl/ directory, nothing to do"; return 0; }
  if ! grep -q overlay "$OVL_FILESYSTEMS"; then
    ovl_log "kernel has no overlayfs, files in ovl/ are not mounted"
    return 1
  fi

  # Already done this boot: a lower layer must not change under a live
  # overlay, so only report the state.
  if grep -q " $OVL_MNT " "$OVL_MOUNTS"; then
    ovl_log "already mounted this boot"
    for _t in $(ovl_find_targets); do
      if ovl_mounted "$(realpath "$OVL_ROOT$_t")" overlay; then
        echo "ok $_t" >> "$OVL_STATUS"
      else
        echo "fail $_t" >> "$OVL_STATUS"
      fi
    done
    return 0
  fi

  mkdir -p "$OVL_MNT"
  _need=$(( $(du -sk "$OVL_SRC" | awk '{print $1}') + 2048 ))
  _have=$(( $(stat -c %s "$OVL_IMG" 2>/dev/null || echo 0) / 1024 ))
  [ "$_have" -lt "$_need" ] && ovl_make_img
  if ! ovl_mount_img; then
    ovl_make_img
    ovl_mount_img || { ovl_log "cannot mount $OVL_IMG"; return 1; }
  fi
  # The layer is rebuilt from ovl/ on every boot, so editing ovl/ and
  # rebooting is enough.
  for _e in "$OVL_MNT"/* "$OVL_MNT"/.[!.]*; do
    [ -e "$_e" ] || continue
    [ "${_e##*/}" = lost+found ] && continue
    rm -rf "$_e"
  done
  cp -af "$OVL_SRC/." "$OVL_MNT/"

  for _h in $OVL_HIDE; do
    [ -e "$OVL_ROOT$_h" ] || continue
    rm -rf "$OVL_MNT$_h"
    mkdir -p "$OVL_MNT${_h%/*}"
    mknod "$OVL_MNT$_h" c 0 0 && ovl_log "hide $_h"
  done

  _targets=$(ovl_find_targets)
  ovl_fix_attrs
  for _t in $_targets; do
    _con=$(ovl_label "$OVL_ROOT$_t")
    [ -n "$_con" ] && chcon "$_con" "$OVL_MNT$_t"
  done
  mount -o remount,ro "$OVL_MNT"

  for _t in $_targets; do
    _real=$(realpath "$OVL_ROOT$_t")
    if ovl_mounted "$_real" overlay; then
      echo "ok $_t" >> "$OVL_STATUS"
      continue
    fi
    if mount -t overlay "$OVL_ID" -o "ro,lowerdir=$OVL_MNT$_t:$_real" "$_real"; then
      echo "ok $_t" >> "$OVL_STATUS"
      ovl_log "mounted $_t"
    else
      echo "fail $_t" >> "$OVL_STATUS"
      ovl_log "FAILED $_t"
      dmesg 2>/dev/null | grep -i overlay | tail -3 >> "$OVL_LOG"
    fi
  done
}

ovl_run
