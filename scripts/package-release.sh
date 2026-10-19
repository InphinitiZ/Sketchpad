#!/bin/sh
# Builds a universal Sketchpad.app and zips it for a GitHub release: build/Sketchpad-<version>.zip.
# The app is signed ad hoc only (no Developer ID), so Gatekeeper asks before the first launch.
set -eu

cd "$(dirname "$0")/.."
scripts/build-app.sh release universal

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Support/Info.plist)"
zip="build/Sketchpad-$version.zip"
rm -f "$zip"
# ditto keeps the bundle's signature and permissions intact, unlike zip.
ditto -c -k --keepParent build/Sketchpad.app "$zip"

echo "Packaged $zip"
