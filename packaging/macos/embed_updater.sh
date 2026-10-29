#!/usr/bin/env bash
set -euo pipefail

helper="${1:?path to Voges Updater.app}"
host="${2:?path to the suite app, such as Voges Word.app}"
entitlements="${3:?the suite app's Release.entitlements}"

id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$helper/Contents/Info.plist")
if [ "$id" != com.omanoloneto.vogesUpdater ]; then
  echo "error: $helper is $id, not Voges Updater" >&2
  exit 1
fi

# the helper runs outside the sandbox: it is signed with no entitlements at
# all, and never with --deep, which would copy the host's sandbox onto it
codesign --force --sign - "$helper"
if codesign -d --entitlements - --xml "$helper" 2>/dev/null | grep -q app-sandbox; then
  echo "error: Voges Updater must not be sandboxed" >&2
  exit 1
fi

target="$host/Contents/Helpers/Voges Updater.app"
rm -rf "$target"
mkdir -p "$host/Contents/Helpers"
ditto "$helper" "$target"

# the host's seal records the helper, so the host is signed last
codesign --force --sign - --entitlements "$entitlements" "$host"
codesign --verify --deep --strict "$host"

codesign -d --entitlements - --xml "$host" 2>/dev/null | grep -q app-sandbox || {
  echo "error: $host lost its sandbox" >&2
  exit 1
}
if codesign -d --entitlements - --xml "$target" 2>/dev/null | grep -q app-sandbox; then
  echo "error: the embedded Voges Updater is sandboxed" >&2
  exit 1
fi
