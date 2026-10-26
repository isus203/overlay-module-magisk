#!/system/bin/sh
MODPATH=${0%/*}

# KernelSU / APatch only: runs after their module mounts, before zygote.
# Magisk does not run this file; it uses post-fs-data.sh.
[ "$KSU" = true ] || [ "$APATCH" = true ] || exit 0

. "$MODPATH/ovl.sh"
