#!/bin/sh
# Runs the PaintCore tests with SwiftPM.
set -eu

cd "$(dirname "$0")/.."
. scripts/swiftpm-env.sh

# With Command Line Tools only, SwiftPM does not pass the swift-testing macro plugin to the
# compiler ("plugin for module 'TestingMacros' not found"), so pass it explicitly.
testing_plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$testing_plugins" ]; then
    set -- -Xswiftc -plugin-path -Xswiftc "$testing_plugins" "$@"
fi

swift test "$@"
