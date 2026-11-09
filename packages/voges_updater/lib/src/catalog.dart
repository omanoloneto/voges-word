/// The Voges suite as the updater knows it. The network only tells the
/// version of each app and, through the signed suite list, the name and the
/// Windows AppId of an app that came later. Every repository, id, path and
/// file is fixed here or follows from the name by one convention, so a
/// tampered response can never point the updater somewhere else.
library;

final class SuiteApp {
  const SuiteApp({
    required this.name,
    required this.repository,
    required this.downloadPage,
    required this.macos,
    required this.windows,
    required this.linux,
  });

  /// Brand name, shown as is in every language.
  final String name;

  /// GitHub `owner/repo` that publishes the releases.
  final String repository;

  /// Website page with the installers, for when updating here is not possible.
  final String downloadPage;

  final MacosTarget macos;
  final WindowsTarget windows;
  final LinuxTarget linux;

  /// "Voges" and one to three capitalised words, such as `Voges Tables`,
  /// short enough for the file names made from them.
  static final _conventionalName = RegExp(r'^Voges( [A-Z][a-z]{1,20}){1,3}$');

  /// An Inno Setup AppId: an uppercase GUID in braces.
  static final _appId = RegExp(
    r'^\{[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}\}$',
  );

  /// The app called [name] as the suite's naming convention spells every
  /// other field: `Voges Tables` lives in `omanoloneto/voges-tables`, has
  /// the bundle id `com.omanoloneto.vogesTables`, installs
  /// `VogesTables-macos.dmg`, and so on. Only [windowsAppId] cannot follow
  /// from the name. Throws a [FormatException] when either breaks its shape.
  factory SuiteApp.conventional({
    required String name,
    required String windowsAppId,
  }) {
    if (!_conventionalName.hasMatch(name)) {
      throw FormatException('Not a suite app name', name);
    }
    if (!_appId.hasMatch(windowsAppId)) {
      throw FormatException('Not a Windows AppId', windowsAppId);
    }
    final words = [
      for (final word in name.split(' ').skip(1)) word.toLowerCase(),
    ];
    final joined = name.replaceAll(' ', '');
    final snake = 'voges_${words.join('_')}';
    final kebab = 'voges-${words.join('-')}';
    return SuiteApp(
      name: name,
      repository: 'omanoloneto/$kebab',
      downloadPage: 'https://omanoloneto.pro/voges/${words.join('-')}/',
      macos: MacosTarget(
        bundleId: 'com.omanoloneto.v${joined.substring(1)}',
        bundleName: '$name.app',
        asset: '$joined-macos.dmg',
      ),
      windows: WindowsTarget(
        appId: windowsAppId,
        executable: '$snake.exe',
        asset: '$joined-windows-setup.exe',
      ),
      linux: LinuxTarget(
        package: kebab,
        binary: '/usr/lib/$kebab/$snake',
        launcher: '/usr/bin/$kebab',
        asset: '$kebab-linux-amd64.deb',
      ),
    );
  }
}

final class MacosTarget {
  const MacosTarget({
    required this.bundleId,
    required this.bundleName,
    required this.asset,
  });

  final String bundleId;

  /// Folder name of the app, such as `Voges Word.app`.
  final String bundleName;

  /// Release asset with the .dmg.
  final String asset;
}

final class WindowsTarget {
  const WindowsTarget({
    required this.appId,
    required this.executable,
    required this.asset,
  });

  /// Inno Setup AppId, braces included.
  final String appId;

  /// File name of the app's executable.
  final String executable;

  /// Release asset with the Inno Setup installer.
  final String asset;
}

final class LinuxTarget {
  const LinuxTarget({
    required this.package,
    required this.binary,
    required this.launcher,
    required this.asset,
  });

  /// Debian package name.
  final String package;

  /// Absolute path of the installed executable.
  final String binary;

  /// Absolute path of the command that opens the app.
  final String launcher;

  /// Release asset with the .deb.
  final String asset;
}

/// SHA-256 of every asset of a release, in the format of `sha256sum`.
const checksumsAsset = 'SHA256SUMS.txt';

/// Ed25519 signature of [checksumsAsset], see `release_verifier.dart`.
const signatureAsset = 'SHA256SUMS.txt.sig';

const vogesWord = SuiteApp(
  name: 'Voges Word',
  repository: 'omanoloneto/voges-word',
  downloadPage: 'https://omanoloneto.pro/voges/word/',
  macos: MacosTarget(
    bundleId: 'com.omanoloneto.vogesWord',
    bundleName: 'Voges Word.app',
    asset: 'VogesWord-macos.dmg',
  ),
  windows: WindowsTarget(
    appId: '{237302D4-CF82-4A6D-B1A5-F3E8C553542A}',
    executable: 'voges_word.exe',
    asset: 'VogesWord-windows-setup.exe',
  ),
  linux: LinuxTarget(
    package: 'voges-word',
    binary: '/usr/lib/voges-word/voges_word',
    launcher: '/usr/bin/voges-word',
    asset: 'voges-word-linux-amd64.deb',
  ),
);

const vogesPencil = SuiteApp(
  name: 'Voges Pencil',
  repository: 'omanoloneto/voges-pencil',
  downloadPage: 'https://omanoloneto.pro/voges/pencil/',
  macos: MacosTarget(
    bundleId: 'com.omanoloneto.vogesPencil',
    bundleName: 'Voges Pencil.app',
    asset: 'VogesPencil-macos.dmg',
  ),
  windows: WindowsTarget(
    appId: '{8A11B1A4-092A-4361-B2BE-A530D3024AD2}',
    executable: 'voges_pencil.exe',
    asset: 'VogesPencil-windows-setup.exe',
  ),
  linux: LinuxTarget(
    package: 'voges-pencil',
    binary: '/usr/lib/voges-pencil/voges_pencil',
    launcher: '/usr/bin/voges-pencil',
    asset: 'voges-pencil-linux-amd64.deb',
  ),
);

const vogesTables = SuiteApp(
  name: 'Voges Tables',
  repository: 'omanoloneto/voges-tables',
  downloadPage: 'https://omanoloneto.pro/voges/tables/',
  macos: MacosTarget(
    bundleId: 'com.omanoloneto.vogesTables',
    bundleName: 'Voges Tables.app',
    asset: 'VogesTables-macos.dmg',
  ),
  windows: WindowsTarget(
    appId: '{1A75A94C-0C6B-4F0F-8F00-6056405F6F37}',
    executable: 'voges_tables.exe',
    asset: 'VogesTables-windows-setup.exe',
  ),
  linux: LinuxTarget(
    package: 'voges-tables',
    binary: '/usr/lib/voges-tables/voges_tables',
    launcher: '/usr/bin/voges-tables',
    asset: 'voges-tables-linux-amd64.deb',
  ),
);

/// Every app of the suite that this build knows, in the order the updater
/// lists them. The signed suite list can add apps to it, never change one.
const vogesSuite = [vogesWord, vogesPencil, vogesTables];
