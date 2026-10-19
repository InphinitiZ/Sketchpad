# Sourced by the other scripts.
#
# Some Command Line Tools installs keep a stale PackageDescription *.private.swiftinterface
# next to a newer libPackageDescription.dylib, so every manifest fails to link
# ("Undefined symbols … Package.__allocating_init"). When that is detected, point SwiftPM
# at a copy of the manifest API without the stale files.

manifest_api="$(xcode-select -p)/usr/lib/swift/pm/ManifestAPI"
if ls "$manifest_api"/PackageDescription.swiftmodule/*.private.swiftinterface >/dev/null 2>&1 \
    && [ "$manifest_api/libPackageDescription.dylib" -nt \
         "$(ls "$manifest_api"/PackageDescription.swiftmodule/*.private.swiftinterface | head -1)" ]; then
    clean_libs="$(cd "$(dirname "$0")/.." && pwd)/.build/clean-manifest-libs"
    if [ ! -d "$clean_libs/ManifestAPI" ]; then
        mkdir -p "$clean_libs"
        cp -R "$manifest_api" "$clean_libs/"
        rm -f "$clean_libs"/ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface
    fi
    export SWIFTPM_CUSTOM_LIBS_DIR="$clean_libs"
fi
