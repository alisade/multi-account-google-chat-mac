#!/bin/sh
# make-icns.sh <source.png> <out.icns>
# Build a square multi-resolution .icns from a PNG via sips + iconutil (both
# ship with macOS). Used by build-combined.sh.

set -eu

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <source.png> <out.icns>" >&2
  exit 2
fi

src="$1"; out="$2"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
set="$tmp/icon.iconset"
mkdir -p "$set"

# Standard iconset: base + @2x for each of 16/32/128/256/512.
for s in 16 32 128 256 512; do
  s2=$((s * 2))
  sips -z "$s"  "$s"  "$src" --out "$set/icon_${s}x${s}.png"    >/dev/null 2>&1
  sips -z "$s2" "$s2" "$src" --out "$set/icon_${s}x${s}@2x.png" >/dev/null 2>&1
done

iconutil -c icns "$set" -o "$out"
