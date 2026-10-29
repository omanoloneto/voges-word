# Voges Updater

Finds and installs updates for the apps of the Voges suite.

- **Library:** each suite app imports `package:voges_updater/voges_updater.dart` for the update indicator (`UpdateCheck`, `UpdateStatusChip`) and to open the updater.
- **macOS helper app:** `macos/` builds `Voges Updater.app`, which each suite app embeds in `Contents/Helpers/`. The suite apps are sandboxed, and a sandboxed app's child processes inherit its sandbox; the helper is opened through LaunchServices, runs outside the sandbox and can replace the apps.
- **Windows and Linux:** there is no helper. The suite app runs the updater itself when started with `--voges-updater`; on Windows it first copies itself to a temp folder, so the installer can replace every installed file.

`lib/core.dart` has no Flutter imports, so the command-line tools in `tool/` can use it.

## How an update works

1. When the app opens, `UpdateCheck` reads the latest version from the redirect of `https://github.com/<repo>/releases/latest` (not the API, which allows 60 requests per hour per address) and the status bar shows the result.
2. Updating asks about unsaved work, opens the updater and closes the app.
3. The updater takes a lock (one updater at a time), lists the installed suite apps and checks each one.
4. For the apps the user picks, it downloads `SHA256SUMS.txt`, `SHA256SUMS.txt.sig` and the installer, checks the Ed25519 signature against the keys in `lib/src/release_trust.dart` and the installer's SHA-256 against the signed list.
5. It waits until those apps are closed, installs, checks the installed version and opens the app that started it.

## The contract with each app's releases

Only the version comes from the network; the rest is fixed in `lib/src/catalog.dart`:

- release tags `vX.Y.Z`, published as the repository's latest release;
- fixed asset names for the `.dmg`, the Inno Setup installer and the `.deb`, plus `SHA256SUMS.txt` and `SHA256SUMS.txt.sig`;
- the macOS bundle id and bundle name, the Inno Setup AppId and executable, and the Debian package and binary paths.

The signature covers `voges-release v1`, the repository and the tag, followed by the bytes of `SHA256SUMS.txt`, so it can't be moved to another release. `tool/release_signing.dart` creates the key (`init`) and signs and publishes a draft release (`publish`).

## Adding an app to the suite

1. Add a `SuiteApp` to `vogesSuite` in `lib/src/catalog.dart`.
2. Give its release workflow the same shape as Voges Word's: fixed asset names, `SHA256SUMS.txt`, a draft release signed with `tool/release_signing.dart`, and `--dart-define=VOGES_VERSION=<version>` in every build.
3. In the app: call `runUpdater` from `main` when `UpdaterRequest.isUpdaterLaunch` is true, show `UpdateStatusChip`, register `UpdaterLocalizations.delegate`, and add the `voges/updater` channel to the macOS `AppDelegate` (see Voges Word's).
4. On macOS, run `packaging/macos/embed_updater.sh` after the build, before making the `.dmg`.

An app learns about a new suite app only once its own embedded updater is that new.

## Development

```sh
flutter pub get
flutter analyze
flutter test
flutter build macos          # the helper app
```

`tool/fake_github.dart` serves a release on `127.0.0.1` for trying the whole flow with builds made with `--dart-define=VOGES_UPDATE_TEST_ORIGIN=http://127.0.0.1:<port>` and `--dart-define=VOGES_UPDATE_TEST_KEY=<public key>`; `dart run tool/fake_github.dart init-key --key-file <file>` makes a throwaway key.

`tool/e2e.dart` checks a real update without test builds: it serves the new installer from the fake GitHub, signed with a key made for the run, and drives the production code to find the installed app, download, verify and install the update, and to refuse a tampered or unsigned release. `.github/workflows/updater-e2e.yml` runs it on Windows, Linux and macOS, updating an install at 98.0.0 to 99.0.0, both built from the same commit. It replaces the installed app, so it is meant for CI runners and test machines.
