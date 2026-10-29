# Voges Word

A lightweight document editor in the spirit of Word, without a million options. It opens and saves real `.docx` files and runs on macOS, Windows, Linux, Android, iOS and the web (Flutter).

## Install

The installers are in the [latest release](https://github.com/omanoloneto/voges-word/releases/latest) and on the [omanoloneto.pro/voges/word](https://omanoloneto.pro/voges/word/) page.

- **macOS** 10.15 or newer, Apple Silicon and Intel: open `VogesWord-macos.dmg` and drag Voges Word to Applications. The app is not notarized by Apple; the first time, allow it in System Settings → Privacy & Security → Open Anyway.
- **Windows** 10 or 11, 64-bit: `VogesWord-windows-setup.exe`. It installs without administrator rights and shows up in "Open with" for `.docx` and `.txt`. If SmartScreen warns you, click "More info" and then "Run anyway".
- **Linux** (Ubuntu 22.04, Debian 12 or newer and derivatives, 64-bit): `sudo apt install ./voges-word-linux-amd64.deb`.

### Updates

From version 1.2.0 on, Voges Word checks for a new version every time it opens and says in the status bar whether it is up to date. When there is an update, clicking it asks about unsaved work, closes the app and opens **Voges Updater**, which lists every installed app of the Voges suite that has an update; update all of them or only some. When it finishes, Voges Word opens again. Earlier versions don't have the updater: install 1.2.0 by hand once.

- The check reads the number of the latest release from github.com; nothing about you or your documents is sent.
- Every update is verified before it is installed: its files must match the `SHA256SUMS.txt` of the release, and that file must carry the Ed25519 signature of the project's key, which is built into the app. A download that doesn't match is never installed.
- **macOS:** the updater replaces the app in its folder; if your account can't write to it, it puts the verified `.dmg` in Downloads for you to install. Voges Word stays sandboxed: the updater is a separate app inside it (`Contents/Helpers/Voges Updater.app`).
- **Windows:** the installer runs silently; installs for all users ask for administrator permission.
- **Linux:** the update is installed with `apt`, after the system asks for your password (polkit). Without a password window, the updater shows the command to run in a terminal.

## What it does

- Opens `.docx` and `.txt`; saves as `.docx` (default) or `.txt`.
- Paged document, like Word: text flows to the next page on its own, paragraphs split across pages (no single line left alone at the bottom or top), headings are not left stranded at the end of a page and tables break by row. There is also a continuous mode and zoom from 50% to 200%. On narrow screens the text fits the width.
- Tabbed ribbon (Home, Insert, Layout, View and Table, which appears while editing a cell), with a style gallery and quick colors.
- On desktop, the window buttons sit inside the blue ribbon: on the left on the Mac, on the right on Windows and, on Linux, on the side set in the system (the right if nothing is set). Undo, redo, copy, cut and paste always sit on the opposite side.
- Fonts with search: the ones installed on the computer and 630 from Google Fonts, the most popular third of those that support Portuguese. Other Google fonts show up when you search for them; once you pick one, it joins your list.
- A Google font is downloaded the first time you pick it or open a document that uses it. The file is verified by its hash and kept on the device.
- Calibri, Cambria, Arial, Times New Roman, Courier New, Georgia and Helvetica, when not installed, are shown with their metric-compatible equivalents from Google Fonts (Carlito, Caladea, Arimo, Tinos, Cousine and Gelasio). That way the text breaks on the same lines as in Word.
- Page layout: margins (Normal, ABNT, Narrow, Moderate, Wide), portrait or landscape, and size (A4, Letter, Legal, A5), saved in the .docx. ABNT is the Brazilian standard for school and academic papers.
- File menu with new documents from templates (blank, single spacing, school paper following ABNT, résumé) and recently opened files.
- Everyday formatting: style (Normal, Heading 1–3), font, size, bold, italic, underline, strikethrough, font color, highlight, alignment, bullets, numbering, indent and line spacing.
- Insert link, image, table (with new rows and columns) and page break.
- Header, footer and page number (Insert tab), with a different first page for a cover. Logos and page fields that come from Word show up on every page.
- First-line indent, indents and spacing of each paragraph show on screen as in the file; the school paper template already comes with the 1.25 cm ABNT indent.
- PDF, printing and sharing from the File menu. The PDF looks just like the screen, with searchable text.
- Spell checker in the interface language, with suggestions on right-click (or long press), on Mac, Android and iPhone.
- Recovery: while there are unsaved changes, a copy is kept; if the app closes without saving, it offers to recover it the next time it opens.
- Tables editable cell by cell, including merged cells.
- Find and replace, word count, undo/redo.
- Warns before closing or opening another file with unsaved changes.
- The system's "Open with" on macOS, Android and, through the installers, Windows and Linux. A file path can also be passed on the command line.
- Interface in English, Portuguese and Spanish. It follows the system language, and you can pick another one in the File menu.
- Updates itself on macOS, Windows and Linux: the status bar shows when a new version exists (see [Updates](#updates)).

What already exists and what is missing compared to Word's most used features is in [docs/word-feature-checklist.md](docs/word-feature-checklist.md).

## Fidelity when opening and saving

Voges Word rewrites only the document body. Headers, footers, styles, theme, numbering, footnotes, images and page settings stay in the file as they came. What the editor shows but does not edit (table of contents, fields such as page numbers, equations, charts, text boxes, notes) is protected and goes back into the file exactly as it was.

Known limitations:

- Pagination uses the fonts that are available. If the file uses a font that is not installed and has no equivalent in Google Fonts (such as Aptos), a page may end a line or two earlier or later than in Word.
- On Android, iOS and the web the list has only Google fonts: Android does not allow using the device's fonts by name.
- To download fonts, the app accesses Google's fonts.gstatic.com. Without internet, another font stands in until the font can be downloaded.
- In documents with several sections, every page shows the header and footer of the last section; tables inside the header do not show up on the pages.
- The PDF stores each page as a 200 dpi image, with invisible text on top for searching and copying; that is why it is larger than a PDF exported by Word.
- On Windows and Linux, Print opens the PDF in the system viewer, where you print it. Linux cannot share files.
- There is no spell checker on Windows, Linux or the web yet.
- Comments are not shown; tracked changes are accepted on open.
- Hanging indent (the opposite of a first-line indent) is kept in the file, but the screen shows the paragraph without it.
- Old `.doc` files (Word 97–2003) are not supported.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| New / Open / Save | Ctrl+N / Ctrl+O / Ctrl+S |
| Save as | Ctrl+Shift+S |
| Bold / Italic / Underline | Ctrl+B / Ctrl+I / Ctrl+U |
| Align left / center / right / justify | Ctrl+L / Ctrl+E / Ctrl+R / Ctrl+J |
| Link / Image | Ctrl+K / Ctrl+G |
| Find / Replace | Ctrl+F / Ctrl+H |
| Print | Ctrl+P |
| Line break within the same paragraph | Shift+Enter |
| Page break | Ctrl+Enter |
| Zoom | Ctrl+= / Ctrl+- / Ctrl+0 |

On macOS, use ⌘ instead of Ctrl.

## Development

Requires Flutter 3.41 or newer.

```sh
flutter pub get
flutter run -d macos      # or windows, linux, chrome, android
flutter test
```

To test with real documents without adding them to the repository:

```sh
VW_SAMPLES=/folder/with/docx flutter test test/docx_roundtrip_test.dart
```

To render screenshots and check the look (system fonts, without opening the app):

```sh
VW_SCREENSHOTS=output-folder VW_SAMPLES=/folder/with/docx flutter test test/screenshots_test.dart
```

The Google Fonts list (`assets/fonts/google_fonts.txt`) comes from the code of the [google_fonts](https://pub.dev/packages/google_fonts) package (BSD license), with up to four files per family (regular, bold, italic and bold italic). Which ones go into the default list comes from the popularity published on fonts.google.com. To update it:

```sh
dart run tool/google_fonts_catalog.dart ~/.pub-cache/hosted/pub.dev/google_fonts-<version>/lib/src/google_fonts_parts
```

### Translations

The interface texts live in `lib/l10n/app_en.arb` (the template), `app_pt.arb` and `app_es.arb`. Edit them and run `flutter gen-l10n` (it also runs on `flutter pub get` and on every build). `test/l10n_test.dart` fails when a language misses a message or a placeholder. To add a language, create `app_<code>.arb` and add it to `appLanguages` in `lib/l10n/app_language.dart`.

### Publishing a release

1. Update `version` in `pubspec.yaml` and create the matching tag, such as `v1.2.3`.
2. The `Release` workflow runs the tests, builds the `.dmg` (with Voges Updater embedded), the Windows installer (Inno Setup) and the `.deb`, and creates a **draft** release with `SHA256SUMS.txt`. On pull requests it only builds the installers. The file names are fixed because the website page and the updater rely on them.
3. On the owner's Mac, sign and publish the draft:

   ```sh
   cd packages/voges_updater
   dart run tool/release_signing.dart publish omanoloneto/voges-word v1.2.3
   ```

   The tool checks that the draft has exactly the expected files, signs `SHA256SUMS.txt` with the key kept in the login Keychain, uploads `SHA256SUMS.txt.sig` and publishes the release. Never publish a draft by hand: the apps refuse a release without a valid signature, so nobody gets the update.

The signing key is created once with `dart run tool/release_signing.dart init`, which stores it in the login Keychain and prints its public key; that public key goes into `releaseSigningKeys` in `packages/voges_updater/lib/src/release_trust.dart` (`dart run tool/release_signing.dart public-key` prints it again). Keep a backup of the key (Keychain Access → `voges-release-signing` → Show password, into a password manager): without it, the installed apps can't verify new releases and must be updated by hand once. To replace the key, add the new public key to the list, release, and only then remove the old one.

The update check can be tried locally against a fake GitHub (`packages/voges_updater/tool/fake_github.dart`) with builds made with `--dart-define=VOGES_UPDATE_TEST_ORIGIN=http://127.0.0.1:<port>` and `--dart-define=VOGES_UPDATE_TEST_KEY=<public key>`. The release workflow never passes these.

The text editor is [flutter_quill](https://pub.dev/packages/flutter_quill) 11.5.0, copied into `third_party/flutter_quill` (MIT license) with pagination added; the changes are marked with `Voges Word:`.

## Structure

- `lib/docx/` — reading and writing `.docx` (zip package, styles, numbering, conversion to the editor's model and back).
- `lib/document/` — document model: formats, page appearance, tables and protected content.
- `lib/editor/` — screen, pages, ribbon, File menu, tables, search and session (open, save, changes).
- `lib/files/` — file dialogs, files opened by the system, and recent files.
- `lib/l10n/` — interface texts in English (`app_en.arb`, the template), Portuguese and Spanish, and the language picker.
- `lib/fonts/` — installed fonts, catalog and Google Fonts download.
- `lib/print/` — pages drawn off-screen, PDF assembly and printing through the system.
- `lib/spell/` — system spell checker and underlining in the editor.
- `tool/` — Google Fonts list generator.
- `packages/voges_updater/` — Voges Updater: the update check, the updater window and the per-system installers, shared by the apps of the Voges suite; its `macos/` folder builds the helper app embedded in the `.app`.
- `packaging/` — installers (`.dmg`, Inno Setup and `.deb`) used by the release workflow, and the script that embeds Voges Updater in the `.app`.
- `third_party/flutter_quill/` — text editor with pagination.
