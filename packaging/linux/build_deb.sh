#!/usr/bin/env bash
set -euo pipefail

version="${1:?versão, como 1.0.0}"
bundle="${2:?pasta build/linux/x64/release/bundle}"
output="${3:?arquivo .deb de saída}"

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

# fontconfig lista as fontes, xdg-utils abre o PDF para imprimir e o zenity
# (ou kdialog) é a janela de abrir e salvar do file_picker
cat > "$root/DEBIAN/control" <<CONTROL
Package: voges-word
Version: $version
Section: editors
Priority: optional
Architecture: amd64
Depends: libgtk-3-0t64 | libgtk-3-0, fontconfig, xdg-utils, zenity | kdialog
Maintainer: omanoloneto <mano.afonso93@gmail.com>
Homepage: https://omanoloneto.pro/voges/word/
Description: editor de documentos leve, com .docx
 O Voges Word abre, edita e salva documentos do Word (.docx) e texto
 simples, com páginas como as do Word, cabeçalho e rodapé, PDF e
 impressão.
CONTROL

dpkg-deb --build --root-owner-group "$root" "$output"
