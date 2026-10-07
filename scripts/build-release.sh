#!/bin/bash
# Builds ArchBox.app and packages it for a GitHub release.
# Usage: scripts/build-release.sh <version>   e.g. scripts/build-release.sh 0.1.0
set -euo pipefail
version="${1:?usage: build-release.sh <version>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

declared="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if [[ "$declared" != "$version" ]]; then
  echo "Version mismatch: tag is $version, Resources/Info.plist says $declared" >&2
  exit 1
fi

dist="$root/dist"
rm -rf "$dist" && mkdir -p "$dist"
"$root/scripts/build-app.sh" "$dist" > /dev/null
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  "$root/scripts/notarize.sh" "$dist/ArchBox.app"
fi

# ditto keeps the bundle's signature and metadata intact.
ditto -c -k --keepParent "$dist/ArchBox.app" "$dist/ArchBox-$version.zip"
rm -rf "$dist/ArchBox.app"
(cd "$dist" && shasum -a 256 "ArchBox-$version.zip" > "ArchBox-$version.zip.sha256")
ls -1 "$dist"
