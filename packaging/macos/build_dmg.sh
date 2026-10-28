#!/usr/bin/env bash
set -euo pipefail

app="${1:?caminho do Voges Word.app}"
output="${2:?arquivo .dmg de saída}"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"

# o hdiutil dos runners do GitHub às vezes falha com "Resource busy"
for attempt in 1 2 3; do
  if hdiutil create -volname "Voges Word" -srcfolder "$staging" -fs HFS+ \
    -format UDZO -ov "$output"; then
    exit 0
  fi
  sleep $((attempt * 5))
done
exit 1
