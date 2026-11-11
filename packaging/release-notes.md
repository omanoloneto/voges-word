Voges Word: a lightweight document editor with .docx support, for macOS, Windows and Linux.

## What's new

- **Rulers** above and beside the page, as in Word. Drag the gray part of a margin to change the page margins, or the markers to change the first-line, hanging, left and right indents of the paragraph. **View → Ruler** hides them.
- **Save as** is one menu with every format: Word document, PDF, OpenDocument, RTF, web page, Markdown and plain text.
- **Long documents are fast to edit:** in a book of 869 pages, a key press now shows in 20–60 ms instead of over a second, and moving the caret, Enter and Backspace got just as quick. [The numbers](https://github.com/omanoloneto/voges-word/blob/main/docs/performance.md) and how they were taken.
- **Pasting** text from web pages and chat apps, such as ChatGPT, keeps its paragraphs and line breaks.
- Page breaks no longer show a "Page break" label on the pages; the continuous view still marks them.
- The first-line and right indents you set are saved in `.docx` files.
- **Linux:** the window shows the app's icon in Alt+Tab and in window lists.

## Install

Page with the downloads and step-by-step instructions: https://omanoloneto.pro/voges/word/

- **macOS** (10.15 or newer, Apple Silicon and Intel): open `VogesWord-macos.dmg` and drag Voges Word to Applications. The first time, macOS blocks the app because it is not notarized by Apple: go to System Settings → Privacy & Security → Open Anyway.
- **Windows** (10 or 11, 64-bit): run `VogesWord-windows-setup.exe`; it does not need administrator rights. If SmartScreen warns you, click "More info" and then "Run anyway".
- **Linux** (Ubuntu 22.04, Debian 12 or newer and derivatives, 64-bit): `sudo apt install ./voges-word-linux-amd64.deb`

`SHA256SUMS.txt` lists the SHA-256 of each file, so you can verify the download, and `SHA256SUMS.txt.sig` is its signature.

Voges Word 1.2.0 and newer check for updates when they open and install them with Voges Updater. Older versions don't: download the new version from this page once.
