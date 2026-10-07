#!/bin/bash
# Builds ArchBox.app into ./build and signs it ad hoc with the virtualization entitlement.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
app=build/ArchBox.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/guest"
cp "$(swift build -c release --show-bin-path)/ArchBox" "$app/Contents/MacOS/ArchBox"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/guest/* "$app/Contents/Resources/guest/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$app/Contents/Resources/"
codesign --force --sign - --entitlements Resources/ArchBox.entitlements "$app"
echo "Built $app"
