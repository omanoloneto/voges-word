#!/usr/bin/env bash
set -euo pipefail

version="${1:?version, such as 1.0.0}"
bundle="${2:?build/linux/x64/release/bundle folder}"
output="${3:?output .deb file}"

here="$(cd "$(dirname "$0")" && pwd)"
app_id=com.omanoloneto.voges_word
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
chmod 755 "$root"

mkdir -p "$root/DEBIAN" "$root/usr/lib/voges-word" "$root/usr/bin" \
  "$root/usr/share/applications" "$root/usr/share/icons/hicolor/256x256/apps"
cp -r "$bundle/." "$root/usr/lib/voges-word/"
ln -s ../lib/voges-word/voges_word "$root/usr/bin/voges-word"
install -m 644 "$here/$app_id.desktop" "$root/usr/share/applications/"
convert "$here/../../assets/icon/icon_rounded.png" -resize 256x256 \
  "$root/usr/share/icons/hicolor/256x256/apps/$app_id.png"

# fontconfig lists the fonts, xdg-utils opens the PDF for printing and zenity
# (or kdialog) provides the open and save dialogs for file_picker
cat > "$root/DEBIAN/control" <<CONTROL
Package: voges-word
Version: $version
Section: editors
Priority: optional
Architecture: amd64
Depends: libgtk-3-0t64 | libgtk-3-0, fontconfig, xdg-utils, zenity | kdialog
Maintainer: omanoloneto <mano.afonso93@gmail.com>
Homepage: https://omanoloneto.pro/voges/word/
Description: lightweight document editor with .docx support
 Voges Word opens, edits and saves Word documents (.docx) and plain
 text, with pages like Word's, headers and footers, PDF and printing.
CONTROL

dpkg-deb --build --root-owner-group "$root" "$output"
