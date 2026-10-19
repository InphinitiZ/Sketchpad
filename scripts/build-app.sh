#!/bin/sh
# Builds Sketchpad.app with SwiftPM (no Xcode needed) into build/.
# Usage: scripts/build-app.sh [debug|release] [universal]   (default: release, for this Mac only)
set -eu

cd "$(dirname "$0")/.."
. scripts/swiftpm-env.sh

config="${1:-release}"
universal="${2:-}"
set -- -c "$config"
if [ "$universal" = universal ]; then
    # Apple silicon and Intel in one binary, built in its own folder so the everyday build stays.
    set -- "$@" --arch arm64 --arch x86_64 --scratch-path .build/universal
fi
swift build "$@"

app="build/Sketchpad.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build "$@" --show-bin-path)/Sketchpad" "$app/Contents/MacOS/"
cp Support/Info.plist "$app/Contents/"
cp -R Support/*.lproj Support/AppIcon.icns "$app/Contents/Resources/"
codesign --force --sign - "$app" >/dev/null

echo "Built $app"
