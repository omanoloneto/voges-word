import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'catalog.dart';
import 'github_releases.dart';
import 'release_downloader.dart';
import 'release_verifier.dart';
import 'suite_platform.dart';
import 'updater_request.dart';
import 'updater_session.dart';
import 'updater_window.dart';

/// Exit code for a command line that the app didn't write (EX_USAGE).
const _invalidArguments = 64;

/// Runs Voges Updater in this process: the macOS helper's `main`, and the
/// app's `main` on Windows and Linux when started with `--voges-updater`.
/// [host] is the app compiled into this process (Windows and Linux), and
/// [locale] the language it uses; null follows the system.
Future<void> runUpdater({
  required List<String> arguments,
  SuiteApp? host,
  Locale? locale,
}) async {
  String? relaunch;
  if (!Platform.isMacOS) {
    final request = trustedUpdaterRequest(
      arguments,
      host,
      operatingSystem: Platform.operatingSystem,
      executable: Platform.resolvedExecutable,
    );
    if (request == null) exit(_invalidArguments);
    relaunch = request.relaunch;
  }

  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'Voges Updater',
      size: Size(560, 520),
      minimumSize: Size(480, 420),
      center: true,
      titleBarStyle: TitleBarStyle.normal,
    ),
    () async {
      await windowManager.setPreventClose(true);
      await windowManager.show();
      await windowManager.focus();
    },
  );

  final releases = GitHubReleases.production();
  final session = UpdaterSession(
    platform: SuitePlatform.current(host: host, relaunch: relaunch),
    feed: releases,
    downloader: ReleaseDownloader(
      releases: releases,
      verifier: ReleaseVerifier(),
    ),
    hostApp: host,
  );
  runApp(UpdaterApp(session: session, locale: locale));
  unawaited(session.start());
}

/// The request in [arguments] when [host], as installed on this computer,
/// wrote it; null otherwise. On Windows the app to reopen must be the
/// installed executable, beside its uninstaller; on Linux this process must
/// be the installed binary.
@visibleForTesting
UpdaterRequest? trustedUpdaterRequest(
  List<String> arguments,
  SuiteApp? host, {
  required String operatingSystem,
  required String executable,
  bool Function(String path) isFile = FileSystemEntity.isFileSync,
}) {
  final request = UpdaterRequest.parse(arguments, operatingSystem);
  if (request == null || host == null) return null;
  final trusted = switch (operatingSystem) {
    'windows' => _isInstalledExecutable(
      request.relaunch!,
      host.windows,
      isFile,
    ),
    'linux' => executable == host.linux.binary,
    _ => false,
  };
  return trusted ? request : null;
}

bool _isInstalledExecutable(
  String path,
  WindowsTarget target,
  bool Function(String path) isFile,
) =>
    p.windows.basename(path).toLowerCase() == target.executable.toLowerCase() &&
    isFile(path) &&
    isFile(p.windows.join(p.windows.dirname(path), 'unins000.exe'));
