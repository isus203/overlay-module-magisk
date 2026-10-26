#!/system/bin/sh
MODPATH=${0%/*}

# KernelSU and APatch mount their modules after this script; there the
# overlay is mounted from post-mount.sh so it ends up on top.
[ "$KSU" = true ] || [ "$APATCH" = true ] && exit 0

. "$MODPATH/ovl.sh"
