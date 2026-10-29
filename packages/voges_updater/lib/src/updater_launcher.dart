import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'process_runner.dart';
import 'updater_lock.dart';
import 'updater_request.dart';

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

/// Runs [action] while holding the updater lock, and skips it while an
/// updater is open.
Future<void> _withUpdaterLock(Future<void> Function() action) async {
  final lock = await UpdaterLock.tryAcquire();
  if (lock == null) return;
  try {
    await action();
  } finally {
    await lock.release();
  }
}

/// Windows: copies the installed app to a temp folder and starts the copy
/// as the updater, so the installer can replace every installed file.
final class WindowsUpdaterLauncher implements UpdaterLauncher {
  WindowsUpdaterLauncher({
    required this.app,
    required this.executable,
    this.runner = const SystemProcessRunner(),
    Directory? temp,
    this.withUpdaterLock = _withUpdaterLock,
    this.now = DateTime.now,
  }) : temp = temp ?? Directory.systemTemp;

  final SuiteApp app;

  /// The running executable, captured when the app started.
  final String executable;
  final ProcessRunner runner;

  /// Where the copies go: the user's temp folder.
  final Directory temp;

  /// Runs its action while holding the updater lock, or skips it while an
  /// updater is open.
  final Future<void> Function(Future<void> Function() action) withUpdaterLock;
  final DateTime Function() now;

  static final _copyName = RegExp(r'^voges-updater-[A-Za-z0-9-]+$');

  /// Only Inno Setup installs can be updated: they have its uninstaller.
  @override
  LaunchAvailability get availability =>
      FileSystemEntity.typeSync(
            p.join(p.dirname(executable), 'unins000.exe'),
            followLinks: false,
          ) ==
          FileSystemEntityType.file
      ? LaunchAvailability.here
      : LaunchAvailability.download;

  @override
  Future<LaunchResult> launch() async {
    if (availability != LaunchAvailability.here) return LaunchResult.failed;
    Directory? copy;
    try {
      copy = await temp.createTemp('voges-updater-');
      final folder = p.join(copy.path, 'app');
      await _copyFolder(File(executable).parent, Directory(folder), top: true);
      await runner.start(
        p.join(folder, p.basename(executable)),
        UpdaterRequest.argumentsFor(relaunch: executable),
        workingDirectory: copy.path,
        mode: ProcessStartMode.detached,
      );
      return LaunchResult.started;
    } on Exception {
      if (copy != null) await _deleteTree(copy);
      return LaunchResult.failed;
    }
  }

  /// Deletes the copies of updaters that ended more than an hour ago.
  @override
  Future<void> cleanUp() => withUpdaterLock(() async {
    final cutoff = now().subtract(const Duration(hours: 1));
    await for (final entity in temp.list(followLinks: false)) {
      if (entity is! Directory ||
          !_copyName.hasMatch(p.basename(entity.path))) {
        continue;
      }
      try {
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await _deleteTree(entity);
        }
      } on FileSystemException {
        // still in use: the next start tries again
      }
    }
  });

  /// Copies the app without the uninstaller (`unins000.exe` and its data):
  /// the copy is not an install, and the uninstaller is not needed.
  static Future<void> _copyFolder(
    Directory from,
    Directory to, {
    bool top = false,
  }) async {
    await to.create(recursive: true);
    await for (final entity in from.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final target = p.join(to.path, name);
      if (entity is Directory) {
        await _copyFolder(entity, Directory(target));
      } else if (entity is File &&
          !(top && name.toLowerCase().startsWith('unins'))) {
        await entity.copy(target);
      }
    }
  }

  static Future<void> _deleteTree(Directory folder) async {
    try {
      await folder.delete(recursive: true);
    } on FileSystemException {
      // the next start tries again
    }
  }
}

/// Linux: starts the installed executable as the updater.
final class LinuxUpdaterLauncher implements UpdaterLauncher {
  LinuxUpdaterLauncher({
    required this.app,
    required this.executable,
    this.runner = const SystemProcessRunner(),
    this.root = '',
  });

  final SuiteApp app;

  /// The running executable, captured when the app started.
  final String executable;
  final ProcessRunner runner;

  /// Prefix of the system paths this reads (`/usr/bin`), for tests.
  final String root;

  /// Only the Debian package can be updated, and only through dpkg.
  @override
  LaunchAvailability get availability =>
      executable == app.linux.binary &&
          File('$root/usr/bin/dpkg-query').existsSync()
      ? LaunchAvailability.here
      : LaunchAvailability.download;

  @override
  Future<LaunchResult> launch() async {
    if (availability != LaunchAvailability.here) return LaunchResult.failed;
    try {
      await runner.start(
        executable,
        UpdaterRequest.argumentsFor(),
        mode: ProcessStartMode.detached,
      );
      return LaunchResult.started;
    } on ProcessException {
      return LaunchResult.failed;
    }
  }

  @override
  Future<void> cleanUp() async {}
}
