# Voges Updater

Finds and installs updates for the apps of the Voges suite.

- **Library:** each suite app imports `package:voges_updater/voges_updater.dart` for the update indicator and to open the updater.
- **macOS helper app:** `macos/` builds `Voges Updater.app`, which each suite app embeds in `Contents/Helpers/`. The suite apps are sandboxed; the helper is not, so it can replace them.
- **Windows and Linux:** there is no helper. The suite app runs the updater itself when started with `--voges-updater`.

`lib/core.dart` has no Flutter imports, so the command-line tools in `tool/` can use it.
