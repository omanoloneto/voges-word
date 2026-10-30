Voges Word: a lightweight document editor with .docx support, for macOS, Windows and Linux.

## What's new

- Opens and saves OpenDocument Text (`.odt`), Rich Text Format (`.rtf`), web pages (`.html`, `.htm`, `.xhtml`), Markdown (`.md`) and Word documents with macros (`.docm`), besides `.docx` and `.txt`. Macros are kept, but never run.
- Opens Word 97–2003 documents (`.doc`). Saving one creates a `.docx` copy and leaves the original untouched.
- Templates (`.dotx`, `.dotm`, `.dot` and `.ott`) open as new, untitled documents.
- **Save as** still creates a `.docx`; the new **Other formats**, next to it in the File menu, saves as `.odt`, `.rtf`, `.html`, `.md` or `.txt`. The status bar says when the document's format keeps less than a `.docx` or saves differently.
- A file opens by its content, so one with the wrong extension still opens.
- Share can also send the document in the format of its file.
- Voges Word shows up in "Open with" for all these formats, without becoming the default app.

## Install

Page with the downloads and step-by-step instructions: https://omanoloneto.pro/voges/word/

- **macOS** (10.15 or newer, Apple Silicon and Intel): open `VogesWord-macos.dmg` and drag Voges Word to Applications. The first time, macOS blocks the app because it is not notarized by Apple: go to System Settings → Privacy & Security → Open Anyway.
- **Windows** (10 or 11, 64-bit): run `VogesWord-windows-setup.exe`; it does not need administrator rights. If SmartScreen warns you, click "More info" and then "Run anyway".
- **Linux** (Ubuntu 22.04, Debian 12 or newer and derivatives, 64-bit): `sudo apt install ./voges-word-linux-amd64.deb`

`SHA256SUMS.txt` lists the SHA-256 of each file, so you can verify the download, and `SHA256SUMS.txt.sig` is its signature.

Voges Word 1.2.0 and newer check for updates when they open and install them with Voges Updater. Older versions don't: download the new version from this page once.
