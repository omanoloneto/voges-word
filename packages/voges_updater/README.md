# Voges Updater

Finds and installs updates for the apps of the Voges suite.

The suite is Voges Word (this repository), [Voges Pencil](https://github.com/omanoloneto/voges-pencil), [Voges Tables](https://github.com/omanoloneto/voges-tables) and [Voges Slides](https://github.com/omanoloneto/voges-slides), listed in `vogesSuite` in `lib/src/catalog.dart`.

- **Library:** each suite app imports `package:voges_updater/voges_updater.dart` for the update indicator (`UpdateCheck`, `UpdateStatusChip`) and to open the updater.
- **macOS helper app:** `macos/` builds `Voges Updater.app`, which each suite app embeds in `Contents/Helpers/`. The suite apps are sandboxed, and a sandboxed app's child processes inherit its sandbox; the helper is opened through LaunchServices, runs outside the sandbox and can replace the apps.
- **Windows and Linux:** there is no helper. The suite app runs the updater itself when started with `--voges-updater`; on Windows it first copies itself to a temp folder, so the installer can replace every installed file.

`lib/core.dart` has no Flutter imports, so the command-line tools in `tool/` can use it.

## How an update works

1. When the app opens, `UpdateCheck` reads the latest version from the redirect of `https://github.com/<repo>/releases/latest` (not the API, which allows 60 requests per hour per address) and the status bar shows the result.
2. Updating asks about unsaved work, opens the updater and closes the app.
3. The updater takes a lock (one updater at a time), reads the signed suite list from the website (see below), lists the installed suite apps and checks each one. Suite apps that are not installed are offered below the updates, never ticked by default. When an installed app could not be checked and there is no update to offer, the updater says it is offline instead, so the check can be tried again.
4. For the apps the user picks, it downloads `SHA256SUMS.txt`, `SHA256SUMS.txt.sig` and the installer, checks the Ed25519 signature against the keys in `lib/src/release_trust.dart` and the installer's SHA-256 against the signed list.
5. It waits until those apps are closed, installs, checks the installed version and opens the app that started it.

A suite app that is not installed goes where the app that opened the updater is: next to it in `/Applications` or `~/Applications` on macOS (never over something that is already there), in the same registry hive on Windows, and through the same `apt-get` call on Linux. On macOS, when the host is kept anywhere else, new apps are not offered.

## The contract with each app's releases

Only the version comes from the release; the rest is fixed in `lib/src/catalog.dart`:

- release tags `vX.Y.Z`, published as the repository's latest release;
- fixed asset names for the `.dmg`, the Inno Setup installer and the `.deb`, plus `SHA256SUMS.txt` and `SHA256SUMS.txt.sig`;
- the macOS bundle id and bundle name, the Inno Setup AppId and executable, and the Debian package and binary paths.

The signature covers `voges-release v1`, the repository and the tag, followed by the bytes of `SHA256SUMS.txt`, so it can't be moved to another release. `tool/release_signing.dart` creates the key (`init`) and signs and publishes a draft release (`publish`).

## The signed suite list

An installed app only has the `vogesSuite` of its own build. To offer an app that joined the suite later, the updater downloads `https://omanoloneto.pro/voges/suite.json` and `suite.json.sig`, whose source is `suite/` in this package:

```json
{"format": 1, "serial": 2, "apps": [{"name": "Voges Slides", "windowsAppId": "{GUID}"}]}
```

- The signature is made with the release key over `voges-suite v1` followed by the exact bytes of `suite.json`, and is checked before anything in the file is read. Without a valid one the suite is the one of the build, which is also what happens offline.
- The list carries only each app's name and Inno Setup AppId. Everything else (repository, download page, bundle id, asset names, package and paths) comes from the name, in `SuiteApp.conventional`, so the network never chooses a path, a repository or an address.
- Even signed, a list is refused as a whole when it has anything unexpected: other keys, a serial above 1000000, more than 32 apps, a name that is not `Voges` plus one to three capitalised words of at most 21 letters each, a repeated name or AppId, or an entry that disagrees with an app of the build. The apps of the build always come first, as built.
- `serial` grows with every list. The newest list seen is kept with its signature in one file of the Voges cache folder (`suite.signed`), and a downloaded list is used only when its serial is greater than the kept one's, so a list from before an app was removed can't be replayed. That memory is the cache's: a computer that never saw a list, or whose cache was cleared, accepts any signed one.
- The download follows no redirect and takes at most 8 seconds and 64 KiB. When it fails, the updates go on with the kept list, or with the suite of the build.

Installers of an app from the list are verified like any other: signed `SHA256SUMS.txt` of its own repository and tag. macOS and Linux also check that what the installer holds is that app, by its bundle id or package name, before installing it. Windows reads back the version registered under the AppId of the list, so a wrong AppId there makes the install be reported as failed.

## Adding an app to the suite

1. Add a `SuiteApp` to `vogesSuite` in `lib/src/catalog.dart`.
2. Give its release workflow the same shape as Voges Word's: fixed asset names, `SHA256SUMS.txt`, a draft release signed with `tool/release_signing.dart`, and `--dart-define=VOGES_VERSION=<version>` in every build.
3. An app from another repository depends on this package through git (`url: https://github.com/omanoloneto/voges-word.git`, `path: packages/voges_updater`, `ref: <commit>`), commits its `pubspec.lock` and gets its packages with `flutter pub get --enforce-lockfile`, so the release is built with the locked commit. Sign it from this clone with `dart run tool/release_signing.dart publish <owner/repo> <vX.Y.Z> --clone <path to the app's clone>`: the tag must be in that clone and match GitHub, and the `voges_updater` commit that its `pubspec.lock` pins must have the same `lib/src/release_trust.dart` as this checkout (fetch voges-word first when that commit is newer).
4. In the app: call `runUpdater` from `main` when `UpdaterRequest.isUpdaterLaunch` is true, show `UpdateStatusChip`, register `UpdaterLocalizations.delegate`, and add the `voges/updater` channel to the macOS `AppDelegate` (see Voges Word's).
5. On macOS, run `packaging/macos/embed_updater.sh` after the build, before making the `.dmg`.
6. Once the app's first release is published, run `dart run tool/release_signing.dart sign-suite`: it writes `suite/suite.json` with the next serial and `suite/suite.json.sig`, and does nothing when the committed list already has every app of `vogesSuite`. Commit both and publish them, byte for byte, as `/voges/suite.json` and `/voges/suite.json.sig` on the website. Before signing, check that the AppId in `vogesSuite` is the one of the app's Inno Setup script and that the release has the installers of the three systems: the list says nothing about systems, so the app is offered on all of them.

The app must follow the naming convention of `SuiteApp.conventional` (`sign-suite` refuses one that doesn't), since that is all an installed updater knows about it. From then on, every installed suite app whose updater reads the list offers the new one, with no new version of its own.

## Development

```sh
flutter pub get
flutter analyze
flutter test
flutter build macos          # the helper app
```

`tool/fake_github.dart` serves a release on `127.0.0.1` for trying the whole flow with builds made with `--dart-define=VOGES_UPDATE_TEST_ORIGIN=http://127.0.0.1:<port>` and `--dart-define=VOGES_UPDATE_TEST_KEY=<public key>`; `dart run tool/fake_github.dart init-key --key-file <file>` makes a throwaway key.

`tool/e2e.dart` checks a real update without test builds: it serves the new installer from the fake GitHub, signed with a key made for the run, and drives the production code to find the installed app, download, verify and install the update, and to refuse a tampered or unsigned release. `.github/workflows/updater-e2e.yml` runs it on Windows, Linux and macOS, updating an install at 98.0.0 to 99.0.0, both built from the same commit. It replaces the installed app, so it is meant for CI runners and test machines.
