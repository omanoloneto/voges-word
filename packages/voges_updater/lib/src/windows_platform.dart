import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'process_runner.dart';
import 'release_version.dart';
import 'suite_platform.dart';
import 'update_failure.dart';

typedef _Task = ({int pid, int session});

/// Windows: Voges Word itself, run by the app from a copy in the temp folder
/// so that the installer can replace every installed file.
final class WindowsPlatform implements SuitePlatform {
  WindowsPlatform({
    this.hostApp,
    this.relaunch,
    this.runner = const SystemProcessRunner(),
    Map<String, String>? environment,
    String? executable,
    int? ownPid,
    Directory? temp,
  }) : system32 = _system32(environment ?? Platform.environment),
       executable = executable ?? Platform.resolvedExecutable,
       ownPid = ownPid ?? pid,
       temp = temp ?? Directory.systemTemp;

  /// The app compiled into this updater.
  final SuiteApp? hostApp;

  /// The installed executable to open again, from `--relaunch`.
  final String? relaunch;

  final ProcessRunner runner;

  /// Where the system tools are: never looked up through PATH.
  final String system32;

  /// This process's executable: the copy in `<temp>\voges-updater-…\app\`.
  final String executable;
  final int ownPid;
  final Directory temp;

  static final _displayVersion = RegExp(
    r'^ {4}DisplayVersion {4}REG_SZ {4}(.+)$',
  );
  static final _taskRow = RegExp(r'^"([^"]+)","(\d+)","[^"]*","(\d+)"');

  int? _session;

  /// The folder of this run: `app\` holds the running copy, next to
  /// `downloads\` and `logs\`.
  late final Directory _root = _findRoot();

  String get _reg => '$system32\\reg.exe';
  String get _tasklist => '$system32\\tasklist.exe';

  @override
  String assetOf(SuiteApp app) => app.windows.asset;

  @override
  Future<UpdaterHost?> host() async {
    final app = hostApp;
    final relaunch = this.relaunch;
    if (app == null || relaunch == null || !p.windows.isAbsolute(relaunch)) {
      return null;
    }
    final name = p.windows.basename(relaunch).toLowerCase();
    final installed =
        name == app.windows.executable.toLowerCase() &&
        _isFile(relaunch) &&
        _isFile(p.join(p.dirname(relaunch), 'unins000.exe'));
    return installed ? UpdaterHost(app: app, reopenPath: relaunch) : null;
  }

  @override
  Future<Directory> workDirectory() =>
      Directory(p.join(_root.path, 'downloads')).create(recursive: true);

  // the app deletes the old temp copies, downloads included, when it starts
  @override
  Future<void> cleanStale(Directory current) async {}

  @override
  Future<List<InstalledCopy>> installed(
    List<SuiteApp> catalog,
    UpdaterHost? host,
  ) async {
    final copies = <InstalledCopy>[];
    for (final app in catalog) {
      for (final scope in InstallScope.values) {
        final version = await _installedVersion(app, scope);
        if (version == null) continue;
        copies.add(
          InstalledCopy(
            app: app,
            version: version,
            location: _uninstallKey(app, scope),
            scope: scope,
            isHost: host?.app.windows.appId == app.windows.appId,
          ),
        );
      }
    }
    return copies;
  }

  @override
  Future<List<RunningApp>> running(List<InstalledCopy> copies) async {
    final session = _session ??= await _ownSession();
    final found = <RunningApp>[];
    for (final app in {for (final copy in copies) copy.app}) {
      final tasks = await _tasks('IMAGENAME eq ${app.windows.executable}');
      for (final task in tasks) {
        if (task.pid != ownPid && task.session == session) {
          found.add(RunningApp(app: app, pid: task.pid));
        }
      }
    }
    return found;
  }

  @override
  Future<List<InstallOutcome>> install(
    List<PendingInstall> items,
    void Function(PendingInstall item, InstallStep step) onStep,
  ) async {
    final outcomes = <PendingInstall, InstallOutcome>{};
    for (final scope in InstallScope.values) {
      for (final item in items.where((item) => item.copy.scope == scope)) {
        onStep(
          item,
          scope == InstallScope.allUsers
              ? InstallStep.waitingForPermission
              : InstallStep.installing,
        );
        outcomes[item] = await _install(item);
      }
    }
    return [for (final item in items) outcomes[item]!];
  }

  @override
  Future<void> openFallback(UpdateFailure failure) async {}

  @override
  void finishSync(UpdaterHost? host) {
    if (host == null) return;
    try {
      // Process.start spawns on the next event loop turn, so the caller
      // yields once before exiting. Starting in the app's own folder keeps
      // this temp folder free to be deleted.
      runner
          .start(
            host.reopenPath,
            const [],
            workingDirectory: p.dirname(host.reopenPath),
            mode: ProcessStartMode.detached,
          )
          .ignore();
    } catch (_) {
      // the update is over either way; the user can open the app
    }
  }

  Future<InstallOutcome> _install(PendingInstall item) async {
    final scope = item.copy.scope;
    final log = p.join(
      _root.path,
      'logs',
      '${p.basenameWithoutExtension(item.copy.app.windows.asset)}'
          '-${scope.name}.log',
    );
    final int code;
    try {
      await item.asset.recheck();
      await Directory(p.dirname(log)).create(recursive: true);
      code = await _runInstaller(item, log);
    } on UpdateFailure catch (failure) {
      return NotInstalled(item, failure);
    } on Exception catch (error) {
      final failure = UpdateFailure(UpdateFailureKind.failed, detail: '$error');
      return NotInstalled(item, failure);
    }
    switch (code) {
      case 0:
        final ReleaseVersion? version;
        try {
          version = await _installedVersion(item.copy.app, scope);
        } on UpdateFailure catch (failure) {
          return NotInstalled(item, failure);
        }
        if (version == item.version) return Installed(item, item.version);
        return NotInstalled(
          item,
          UpdateFailure(
            UpdateFailureKind.failed,
            detail: 'DisplayVersion after install: $version',
            logPath: log,
          ),
        );
      case 2:
        return NotInstalled(
          item,
          const UpdateFailure(UpdateFailureKind.declined, code: 2),
        );
      case 5:
        return NotInstalled(
          item,
          const UpdateFailure(UpdateFailureKind.inUse, code: 5),
        );
      default:
        return NotInstalled(
          item,
          UpdateFailure(UpdateFailureKind.failed, code: code, logPath: log),
        );
    }
  }

  /// Runs Inno Setup silently in the scope where the app was found, so it
  /// reuses that install's folder, tasks and language. It never forces apps
  /// to close: with unsaved work it stops with code 5 before changing files.
  Future<int> _runInstaller(PendingInstall item, String log) async {
    final process = await runner.start(item.asset.file.path, [
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/SP-',
      item.copy.scope == InstallScope.allUsers ? '/ALLUSERS' : '/CURRENTUSER',
      '/LOG=$log',
    ], workingDirectory: (await workDirectory()).path);
    try {
      await process.stdin.close();
    } on Exception {
      // the installer already closed its input
    }
    final output = [process.stdout.drain<void>(), process.stderr.drain<void>()];
    final code = await process.exitCode;
    await Future.wait(output);
    return code;
  }

  /// `DisplayVersion` of the app's uninstall key in [scope]'s hive, in the
  /// 64-bit view. It is ASCII, so reg.exe's code page does not matter.
  Future<ReleaseVersion?> _installedVersion(
    SuiteApp app,
    InstallScope scope,
  ) async {
    final result = await _run(_reg, [
      'query',
      _uninstallKey(app, scope),
      '/v',
      'DisplayVersion',
      '/reg:64',
    ]);
    if (result.exitCode == 1) return null;
    if (result.exitCode == 0) {
      for (final line in const LineSplitter().convert('${result.stdout}')) {
        if (_displayVersion.firstMatch(line) case final match?) {
          return ReleaseVersion.tryParse(match[1]!);
        }
      }
    }
    throw UpdateFailure(
      UpdateFailureKind.failed,
      code: result.exitCode,
      detail: 'reg.exe: ${result.stderr}'.trim(),
    );
  }

  static String _uninstallKey(SuiteApp app, InstallScope scope) {
    final hive = scope == InstallScope.allUsers ? 'HKLM' : 'HKCU';
    return '$hive\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\'
        '${app.windows.appId}_is1';
  }

  /// The session of this updater: instances in other sessions belong to
  /// other users, who are the only ones able to close them.
  Future<int> _ownSession() async {
    final tasks = await _tasks('PID eq $ownPid');
    if (tasks.isEmpty) {
      throw const UpdateFailure(
        UpdateFailureKind.failed,
        detail: 'tasklist did not list the updater',
      );
    }
    return tasks.first.session;
  }

  /// Rows of `tasklist` for [filter]. When nothing matches it prints a
  /// localized line instead, which the pattern skips.
  Future<List<_Task>> _tasks(String filter) async {
    final result = await _run(_tasklist, ['/FO', 'CSV', '/NH', '/FI', filter]);
    if (result.exitCode != 0) {
      throw UpdateFailure(
        UpdateFailureKind.failed,
        code: result.exitCode,
        detail: 'tasklist: ${result.stderr}'.trim(),
      );
    }
    return [
      for (final line in const LineSplitter().convert('${result.stdout}'))
        if (_taskRow.firstMatch(line) case final match?)
          (pid: int.parse(match[2]!), session: int.parse(match[3]!)),
    ];
  }

  Future<ProcessResult> _run(String tool, List<String> arguments) async {
    try {
      return await runner.run(tool, arguments);
    } on ProcessException catch (error) {
      throw UpdateFailure(UpdateFailureKind.failed, detail: '$error');
    }
  }

  Directory _findRoot() {
    final app = File(executable).parent;
    final root = app.parent;
    if (p.basename(app.path).toLowerCase() == 'app' &&
        p.basename(root.path).startsWith('voges-updater-')) {
      return root;
    }
    return temp.createTempSync('voges-updater-');
  }

  static String _system32(Map<String, String> environment) =>
      '${environment['SystemRoot'] ?? r'C:\Windows'}\\System32';

  static bool _isFile(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.file;
}
