import 'dart:io';

import 'package:flutter/services.dart';

import 'catalog.dart';
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
  LaunchAvailability get availability => throw UnimplementedError();

  @override
  Future<LaunchResult> launch() => throw UnimplementedError();

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
