import 'catalog.dart';
import 'process_runner.dart';

enum LaunchAvailability {
  /// The updater can run from this copy of the app.
  here,

  /// This copy was not installed by the suite's installers: download instead.
  download,

  /// macOS: the app runs from a disk image or a translocated folder.
  moveToApplications,
}

enum LaunchResult { started, failed }

/// Opens the updater from inside an app of the suite.
abstract interface class UpdaterLauncher {
  LaunchAvailability get availability;

  /// Starts the updater; the app closes itself when this returns
  /// [LaunchResult.started].
  Future<LaunchResult> launch();

  /// Deletes what earlier launches left behind (the Windows temp copies).
  Future<void> cleanUp();
}

/// Windows: copies the installed app to a temp folder and starts the copy
/// as the updater, so the installer can replace every installed file.
final class WindowsUpdaterLauncher implements UpdaterLauncher {
  WindowsUpdaterLauncher({
    required this.app,
    required this.executable,
    this.runner = const SystemProcessRunner(),
  });

  final SuiteApp app;

  /// The running executable, captured when the app started.
  final String executable;
  final ProcessRunner runner;

  @override
  LaunchAvailability get availability => throw UnimplementedError();

  @override
  Future<LaunchResult> launch() => throw UnimplementedError();

  @override
  Future<void> cleanUp() => throw UnimplementedError();
}

/// Linux: starts the installed executable as the updater.
final class LinuxUpdaterLauncher implements UpdaterLauncher {
  LinuxUpdaterLauncher({
    required this.app,
    required this.executable,
    this.runner = const SystemProcessRunner(),
  });

  final SuiteApp app;

  /// The running executable, captured when the app started.
  final String executable;
  final ProcessRunner runner;

  @override
  LaunchAvailability get availability => throw UnimplementedError();

  @override
  Future<LaunchResult> launch() => throw UnimplementedError();

  @override
  Future<void> cleanUp() async {}
}
