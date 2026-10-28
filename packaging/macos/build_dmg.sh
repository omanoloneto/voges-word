#!/usr/bin/env bash
set -euo pipefail

app="${1:?path to Voges Word.app}"
output="${2:?output .dmg file}"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"

# hdiutil on the GitHub runners sometimes fails with "Resource busy"
for attempt in 1 2 3; do
  if hdiutil create -volname "Voges Word" -srcfolder "$staging" -fs HFS+ \
    -format UDZO -ov "$output"; then
    exit 0
  fi
  sleep $((attempt * 5))
done
exit 1
