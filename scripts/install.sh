#!/bin/zsh
# Builds the X-2026 (optimised) and puts it in /Applications.
#
#   ./scripts/install.sh
#
# This is the build to test with. Xcode's own Run, the unit tests and the
# previews keep using DerivedData; they need a debug build.

set -euo pipefail

ROOT="${0:A:h:h}"
APP="X2026.app"
BUNDLE_ID="se.mickekring.X2026"
DESTINATION="/Applications/$APP"
BUILD="$ROOT/build"
PRODUCT="$BUILD/Build/Products/Release/$APP"

# Never replace an app that is running, or one that is not ours.
if pgrep -qf "$DESTINATION/Contents/MacOS/"; then
    echo "The X-2026 in /Applications is running. Quit it and run this again." >&2
    exit 1
fi
if [[ -e "$DESTINATION" ]]; then
    existing=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$existing" != "$BUNDLE_ID" ]]; then
        echo "$DESTINATION exists and is not the X-2026 (it says '$existing'). Leaving it alone." >&2
        exit 1
    fi
fi

echo "Building…"
log=$(mktemp)
if ! xcodebuild -project "$ROOT/X2026/X2026.xcodeproj" -scheme X2026 -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$BUILD" build >"$log" 2>&1; then
    grep -E "error" "$log" | head -40 >&2
    echo "Build failed. Full log: $log" >&2
    exit 1
fi
rm -f "$log"

rm -rf "$DESTINATION"
ditto "$PRODUCT" "$DESTINATION"
codesign --verify --strict "$DESTINATION"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DESTINATION/Contents/Info.plist")
echo "Installed X-2026 $version in $DESTINATION"
