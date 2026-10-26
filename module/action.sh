#!/system/bin/sh
# Action button in the Magisk / KernelSU / APatch app: shows the overlay state.
MODPATH=${0%/*}
echo "Overlay status:"
if [ -s "$MODPATH/ovl.status" ]; then
  cat "$MODPATH/ovl.status"
else
  echo "  (no data yet, reboot first)"
fi
echo
echo "dev.mnt.blk properties: $(getprop | grep -c dev.mnt.blk)"
echo
echo "Log:"
cat "$MODPATH/ovl.log" 2>/dev/null
