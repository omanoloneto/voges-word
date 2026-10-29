import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'macos_platform.dart';
import 'updater_launcher.dart';

/// macOS: asks the app's native side to open the Voges Updater embedded in
/// the bundle. The app is sandboxed, so only LaunchServices can start the
/// updater outside the sandbox.
final class MacosUpdaterLauncher implements UpdaterLauncher {
  MacosUpdaterLauncher({
    required this.app,
    required this.executable,
    this.channel = const MethodChannel('voges/updater'),
  });

  final SuiteApp app;

  /// The running executable, captured when the app started.
  final String executable;
  final MethodChannel channel;

  @override
  LaunchAvailability get availability {
    final bundle = _bundle;
    if (bundle == null || !_hasHelper(bundle)) {
      return LaunchAvailability.download;
    }
    return isTranslocatedOrOnVolume(bundle)
        ? LaunchAvailability.moveToApplications
        : LaunchAvailability.here;
  }

  static bool _hasHelper(String bundle) => Directory(
    p.join(bundle, 'Contents', 'Helpers', 'Voges Updater.app'),
  ).existsSync();

  /// The app bundle around [executable], `<bundle>/Contents/MacOS/<name>`.
  String? get _bundle {
    final macos = p.dirname(executable);
    final contents = p.dirname(macos);
    final bundle = p.dirname(contents);
    final valid =
        p.basename(macos) == 'MacOS' &&
        p.basename(contents) == 'Contents' &&
        bundle.endsWith('.app');
    return valid ? bundle : null;
  }

  /// The native side replies `started`, `failed` or `missing` (no helper).
  @override
  Future<LaunchResult> launch() async {
    if (availability != LaunchAvailability.here) return LaunchResult.failed;
    try {
      final reply = await channel.invokeMethod<Object?>('launch');
      return reply == 'started' ? LaunchResult.started : LaunchResult.failed;
    } on PlatformException {
      return LaunchResult.failed;
    } on MissingPluginException {
      return LaunchResult.failed;
    }
  }

  @override
  Future<void> cleanUp() async {}
}

/// The launcher for this system, capturing the executable now: on Linux the
/// path changes once the package manager replaces it.
UpdaterLauncher platformUpdaterLauncher(SuiteApp app) {
  final executable = Platform.resolvedExecutable;
  if (Platform.isMacOS) {
    return MacosUpdaterLauncher(app: app, executable: executable);
  }
  if (Platform.isWindows) {
    return WindowsUpdaterLauncher(app: app, executable: executable);
  }
  return LinuxUpdaterLauncher(app: app, executable: executable);
}
