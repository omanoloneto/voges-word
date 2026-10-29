import 'dart:io';

import 'catalog.dart';
import 'linux_platform.dart';
import 'macos_platform.dart';
import 'process_runner.dart';
import 'release_downloader.dart';
import 'release_version.dart';
import 'update_failure.dart';
import 'windows_platform.dart';

/// Windows registry hive of an install; macOS and Linux always use [user].
enum InstallScope { user, allUsers }

/// A suite app found on this computer.
final class InstalledCopy {
  const InstalledCopy({
    required this.app,
    required this.version,
    required this.location,
    this.scope = InstallScope.user,
    this.isHost = false,
  });

  final SuiteApp app;
  final ReleaseVersion version;

  /// macOS: the .app folder; Windows: the uninstall registry key;
  /// Linux: the installed executable.
  final String location;

  final InstallScope scope;

  /// Whether this is the copy that opened the updater.
  final bool isHost;
}

/// A running instance that must close before its app is replaced.
final class RunningApp {
  const RunningApp({
    required this.app,
    required this.pid,
    this.otherAccount = false,
  });

  final SuiteApp app;
  final int pid;

  /// Open in another user account, so this user cannot close it.
  final bool otherAccount;
}

/// A verified download waiting to replace [copy].
final class PendingInstall {
  const PendingInstall({
    required this.copy,
    required this.version,
    required this.asset,
  });

  final InstalledCopy copy;
  final ReleaseVersion version;
  final VerifiedAsset asset;
}

enum InstallStep { waitingForPermission, installing }

sealed class InstallOutcome {
  const InstallOutcome(this.item);

  final PendingInstall item;
}

final class Installed extends InstallOutcome {
  const Installed(super.item, this.version);

  /// The version read back from the system after installing.
  final ReleaseVersion version;
}

final class NotInstalled extends InstallOutcome {
  const NotInstalled(super.item, this.failure);

  final UpdateFailure failure;
}

/// The app that opened the updater, opened again when the updater closes.
final class UpdaterHost {
  const UpdaterHost({required this.app, required this.reopenPath});

  final SuiteApp app;

  /// macOS: the .app folder; Windows: the installed executable; Linux: the
  /// launcher command.
  final String reopenPath;
}

/// What the updater needs from the operating system.
abstract interface class SuitePlatform {
  /// The OS that runs this process; [host] is the app compiled into the
  /// updater (Windows and Linux) and [relaunch] the executable that Windows
  /// passes on the command line.
  factory SuitePlatform.current({
    SuiteApp? host,
    String? relaunch,
    ProcessRunner runner = const SystemProcessRunner(),
  }) {
    if (Platform.isMacOS) return MacosPlatform(runner: runner);
    if (Platform.isWindows) {
      return WindowsPlatform(hostApp: host, relaunch: relaunch, runner: runner);
    }
    if (Platform.isLinux) return LinuxPlatform(hostApp: host, runner: runner);
    throw UnsupportedError('No updater for ${Platform.operatingSystem}');
  }

  /// The release asset with this system's installer.
  String assetOf(SuiteApp app);

  /// The app that opened the updater; null when it cannot be found.
  Future<UpdaterHost?> host();

  /// A new private folder (0700) for the downloads of this run.
  Future<Directory> workDirectory();

  /// Deletes what earlier runs left behind, except [current]. Only called
  /// while holding the updater lock.
  Future<void> cleanStale(Directory current);

  /// The suite apps installed on this computer.
  Future<List<InstalledCopy>> installed(
    List<SuiteApp> catalog,
    UpdaterHost? host,
  );

  /// Instances of [copies] that are open now.
  Future<List<RunningApp>> running(List<InstalledCopy> copies);

  /// Installs [items], in order, and returns one outcome per item.
  Future<List<InstallOutcome>> install(
    List<PendingInstall> items,
    void Function(PendingInstall item, InstallStep step) onStep,
  );

  /// The manual way out for [failure]: macOS copies the verified .dmg to
  /// Downloads and opens it; the other systems do nothing.
  Future<void> openFallback(UpdateFailure failure);

  /// Opens [host] again and deletes what was kept until the end. Synchronous
  /// because it runs right before the process exits.
  void finishSync(UpdaterHost? host);
}
