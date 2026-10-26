#!/bin/sh
# Packs module/ into out/<id>-<version>.zip, installable from the Magisk,
# KernelSU or APatch app. Run: sh build.sh
set -eu
cd "$(dirname "$0")"
M=module

prop() { sed -n "s/^$1=//p" "$M/module.prop" | tr -d '\r'; }
ID=$(prop id)
VER=$(prop version)

echo "$ID" | grep -Eq '^[a-zA-Z][a-zA-Z0-9._-]+$' \
  || { echo "module.prop: bad id '$ID' (letters, digits, . _ -; starts with a letter)"; exit 1; }
[ -n "$VER" ] && [ -n "$(prop versionCode)" ] \
  || { echo "module.prop: version and versionCode are required"; exit 1; }

for f in "$M"/*.sh; do
  sh -n "$f" || { echo "syntax error in $f"; exit 1; }
done
if find "$M/ovl" -name '* *' | grep -q .; then
  echo "ovl/: file names with spaces are not supported:"
  find "$M/ovl" -name '* *'
  exit 1
fi
if grep -l "$(printf '\r')" "$M"/*.sh "$M"/*.conf "$M"/*.rule "$M/module.prop" 2>/dev/null; then
  echo "^ these files have Windows line endings (CRLF), convert them to LF"
  exit 1
fi
[ -d "$M/system" ] && echo "note: module/system/ is mounted by Magisk itself;" \
  "keep only replacements of existing files there, new files go to ovl/"

mkdir -p out
ZIP=$PWD/out/$ID-$VER.zip
rm -f "$ZIP"
(cd "$M" && zip -qr9 "$ZIP" . -x '*.img' -x '*.log' -x '*.status')
echo "built $ZIP"
