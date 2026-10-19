#!/bin/sh
# Builds Sketchpad.app with SwiftPM (no Xcode needed) into build/.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -eu

cd "$(dirname "$0")/.."
. scripts/swiftpm-env.sh

config="${1:-release}"
swift build -c "$config"

app="build/Sketchpad.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c "$config" --show-bin-path)/Sketchpad" "$app/Contents/MacOS/"
cp Support/Info.plist "$app/Contents/"
codesign --force --sign - "$app" >/dev/null

echo "Built $app"
