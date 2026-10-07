#!/bin/bash
# Builds ArchBox.app and signs it with the virtualization entitlement.
# Usage: scripts/build-app.sh [output-dir]   (default: build)
# With SIGN_IDENTITY ("Developer ID Application: Name (TEAMID)") the app is signed for
# distribution (hardened runtime, timestamp); without it, ad hoc for local use.
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:-build}"
swift build -c release --arch arm64
app="$out/ArchBox.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/guest"
cp "$(swift build -c release --arch arm64 --show-bin-path)/ArchBox" "$app/Contents/MacOS/ArchBox"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Resources/guest/ "$app/Contents/Resources/guest/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$app/Contents/Resources/"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  sign=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
else
  sign=(codesign --force --sign -)
fi
"${sign[@]}" --entitlements Resources/ArchBox.entitlements "$app"
codesign --verify --strict "$app"
echo "Built $app"
