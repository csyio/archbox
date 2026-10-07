#!/bin/bash
# Prints the CHANGELOG.md section for one version, used as the GitHub release body.
# Usage: scripts/release-notes.sh <version>
set -euo pipefail
version="${1:?usage: release-notes.sh <version>}"
# The heading is matched as a literal string, so dots in the version are not wildcards.
notes="$(awk -v heading="## [$version]" '
  index($0, heading) == 1 { found = 1; next }
  found && /^## \[/ { exit }
  found { print }
' "$(dirname "$0")/../CHANGELOG.md" | sed -e '/./,$!d')"
if [[ -z "$notes" ]]; then
  echo "CHANGELOG.md has no section for $version" >&2
  exit 1
fi
printf '%s\n' "$notes"
