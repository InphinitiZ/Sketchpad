#!/bin/sh
# Renders the app icon from Artwork/AppIcon/render.swift and packs Support/AppIcon.icns.
# Usage: scripts/make-icon.sh
set -eu

cd "$(dirname "$0")/.."
root="$(pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

(cd "$work" && swift -module-cache-path "$work/cache" "$root/Artwork/AppIcon/render.swift" >/dev/null)
cp "$work/AppIcon-1024.png" Artwork/AppIcon/AppIcon-1024.png

set_dir="$work/AppIcon.iconset"
mkdir "$set_dir"
for size in 16 32 128 256 512; do
    sips -z $size $size "$work/AppIcon-1024.png" --out "$set_dir/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$work/AppIcon-1024.png" --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o Support/AppIcon.icns

echo "Wrote Support/AppIcon.icns"
