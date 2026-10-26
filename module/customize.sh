# Installer hook (Magisk, KernelSU, APatch).

ui_print "- $MODID: files in ovl/ are added with overlayfs"
if ! grep -q overlay /proc/filesystems; then
  ui_print "! This kernel has no overlayfs."
  ui_print "! The module installs, but files in ovl/ will not appear."
fi
if [ "$KSU" = true ] || [ "$APATCH" = true ]; then
  ui_print "- KernelSU/APatch: the overlay is mounted from post-mount.sh"
fi

# A stale image from a previous version is rebuilt on the next boot.
rm -f "$MODPATH/ovl.img" "$MODPATH/ovl.log" "$MODPATH/ovl.status"
set_perm_recursive "$MODPATH/ovl" 0 0 0755 0644
for d in $(find "$MODPATH/ovl" -type d -name bin -o -type d -name xbin); do
  set_perm_recursive "$d" 0 2000 0755 0755
done

# Your own install steps go below.
