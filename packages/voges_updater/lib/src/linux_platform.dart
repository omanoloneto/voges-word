import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'process_runner.dart';
import 'release_version.dart';
import 'suite_platform.dart';
import 'update_failure.dart';

/// Linux: Voges Word itself, run in place from its Debian package. dpkg
/// replaces files by renaming, so running instances survive the upgrade.
final class LinuxPlatform implements SuitePlatform {
  LinuxPlatform({
    this.hostApp,
    this.runner = const SystemProcessRunner(),
    String? executable,
    int? ownPid,
    this.root = '',
  }) : executable = executable ?? Platform.resolvedExecutable,
       ownPid = ownPid ?? pid;

  /// The app compiled into this updater.
  final SuiteApp? hostApp;

  final ProcessRunner runner;

  /// This process's executable, read when the updater started: afterwards
  /// the kernel reports it as deleted once the package is upgraded.
  final String executable;
  final int ownPid;

  /// Prefix of the system paths this uses (`/proc`, `/usr/bin`, `/tmp`), for
  /// tests.
  final String root;

  static const _dpkgQuery = '/usr/bin/dpkg-query';
  static const _dpkgDeb = '/usr/bin/dpkg-deb';
  static const _pkexec = '/usr/bin/pkexec';
  static const _aptGet = '/usr/bin/apt-get';

  // a raw string: dpkg-query expands the \t and \n itself
  static const _showFormat =
      r'--showformat=${Package}\t${db:Status-Status}\t${Version}\n';
  static const _deleted = ' (deleted)';
  static final _processId = RegExp(r'^\d+$');
  static final _staleWork = RegExp(r'^voges-update-[A-Za-z0-9]+$');

  final _work = <Directory>[];

  @override
  String assetOf(SuiteApp app) => app.linux.asset;

  @override
  Future<UpdaterHost?> host() async {
    final app = hostApp;
    if (app == null || executable != app.linux.binary) return null;
    return UpdaterHost(app: app, reopenPath: app.linux.launcher);
  }

  /// In /tmp itself, never $TMPDIR or the cache: /tmp is sticky, so no
  /// other user can rename this folder and swap the package that root
  /// installs. Packages are never run from here, so noexec doesn't matter.
  @override
  Future<Directory> workDirectory() async {
    final work = await Directory('$root/tmp').createTemp('voges-update-');
    _work.add(work);
    // unlike mkdtemp on macOS, Dart creates it with the umask here (0755);
    // /bin/chmod exists with and without the merged /usr
    final private = await runner.run('/bin/chmod', ['700', work.path]);
    if (private.exitCode != 0) {
      throw UpdateFailure(
        UpdateFailureKind.failed,
        detail: 'chmod: ${private.stderr}'.trim(),
      );
    }
    return work;
  }

  @override
  Future<void> cleanStale(Directory current) async {
    // other users' folders fail to delete, which is fine
    for (final entry in _entries('$root/tmp')) {
      if (_staleWork.hasMatch(p.basename(entry)) &&
          !p.equals(entry, current.path)) {
        _deleteTree(entry);
      }
    }
  }

  @override
  Future<List<InstalledCopy>> installed(
    List<SuiteApp> catalog,
    UpdaterHost? host,
  ) async {
    final versions = await _installedVersions(catalog);
    return [
      for (final app in catalog)
        if (versions[app.linux.package] case final version?)
          InstalledCopy(
            app: app,
            version: version,
            location: app.linux.binary,
            isHost: host?.app.linux.package == app.linux.package,
          ),
    ];
  }

  /// Instances found through `/proc/<pid>/exe`, which names the executable
  /// however the app was started. Other users' processes cannot be read and
  /// are skipped: they keep running through an upgrade anyway.
  @override
  Future<List<RunningApp>> running(List<InstalledCopy> copies) async {
    final apps = {for (final copy in copies) copy.app.linux.binary: copy.app};
    final found = <RunningApp>[];
    for (final entry in _entries('$root/proc')) {
      final name = p.basename(entry);
      if (!_processId.hasMatch(name) || int.parse(name) == ownPid) continue;
      final String target;
      try {
        target = Link(p.join(entry, 'exe')).targetSync();
      } on FileSystemException {
        continue;
      }
      final binary = target.endsWith(_deleted)
          ? target.substring(0, target.length - _deleted.length)
          : target;
      final app = apps[binary];
      if (app != null) found.add(RunningApp(app: app, pid: int.parse(name)));
    }
    return found;
  }

  @override
  Future<List<InstallOutcome>> install(
    List<PendingInstall> items,
    void Function(PendingInstall item, InstallStep step) onStep,
  ) async {
    final outcomes = <PendingInstall, InstallOutcome>{};
    final batch = <PendingInstall>[];
    for (final item in items) {
      try {
        await item.asset.recheck();
        await _checkPackage(item);
        batch.add(item);
      } on UpdateFailure catch (failure) {
        outcomes[item] = NotInstalled(item, failure);
      }
    }
    if (batch.isNotEmpty) {
      final failure = await _aptInstall(batch, onStep);
      var versions = const <String, ReleaseVersion>{};
      try {
        versions = await _installedVersions([
          for (final item in batch) item.copy.app,
        ]);
      } on UpdateFailure {
        // reported below as not installed
      }
      for (final item in batch) {
        final version = versions[item.copy.app.linux.package];
        outcomes[item] = version == item.version
            ? Installed(item, item.version)
            : NotInstalled(
                item,
                failure ??
                    UpdateFailure(
                      UpdateFailureKind.failed,
                      detail: 'installed version after install: $version',
                    ),
              );
      }
    }
    return [for (final item in items) outcomes[item]!];
  }

  @override
  Future<void> openFallback(UpdateFailure failure) async {}

  @override
  void finishSync(UpdaterHost? host) {
    if (host != null) {
      try {
        // Process.start spawns on the next event loop turn, so the caller
        // yields once before exiting
        runner
            .start(host.reopenPath, const [], mode: ProcessStartMode.detached)
            .ignore();
      } catch (_) {
        // the update is over either way; the user can open the app
      }
    }
    for (final work in _work) {
      _deleteTree(work.path);
    }
  }

  /// One password prompt for every package. pkexec checks that its parent is
  /// alive, so it runs attached; its input is closed so that nothing waits
  /// on a prompt.
  Future<UpdateFailure?> _aptInstall(
    List<PendingInstall> batch,
    void Function(PendingInstall item, InstallStep step) onStep,
  ) async {
    final packages = [for (final item in batch) item.asset.file.absolute.path];
    final command = 'sudo apt install ${packages.map(_quote).join(' ')}';
    if (!File('$root$_pkexec').existsSync()) {
      return UpdateFailure(
        UpdateFailureKind.noPasswordWindow,
        command: command,
      );
    }
    for (final item in batch) {
      onStep(item, InstallStep.waitingForPermission);
    }
    final Process process;
    try {
      process = await runner.start(_pkexec, [
        _aptGet,
        'install',
        '-y',
        '--no-remove',
        '-o',
        'DPkg::Lock::Timeout=120',
        '-o',
        'APT::Status-Fd=1',
        '--',
        ...packages,
      ]);
    } on ProcessException catch (error) {
      return UpdateFailure(
        UpdateFailureKind.failed,
        detail: '$error',
        command: command,
      );
    }
    try {
      await process.stdin.close();
    } on Exception {
      // pkexec already closed its input
    }
    var installing = false;
    final output = _lines(process.stdout).forEach((line) {
      // apt-get only runs, and prints, once the password was accepted
      if (installing) return;
      installing = true;
      for (final item in batch) {
        onStep(item, InstallStep.installing);
      }
    });
    final errors = <String>[];
    final errorOutput = _lines(process.stderr).forEach((line) {
      errors.add(line);
      if (errors.length > 20) errors.removeAt(0);
    });
    final code = await process.exitCode;
    await Future.wait([output, errorOutput]);
    final tail = errors.join('\n');
    return switch (code) {
      0 => null,
      126 => const UpdateFailure(UpdateFailureKind.declined, code: 126),
      127 when tail.contains('authentication agent') => UpdateFailure(
        UpdateFailureKind.noPasswordWindow,
        code: code,
        detail: tail,
        command: command,
      ),
      127 => UpdateFailure(
        UpdateFailureKind.notAuthorized,
        code: code,
        detail: tail,
        command: command,
      ),
      100 => UpdateFailure(
        UpdateFailureKind.packageManager,
        code: code,
        detail: tail,
        command: command,
      ),
      _ => UpdateFailure(UpdateFailureKind.failed, code: code, detail: tail),
    };
  }

  /// The package must be this app, for this version and this architecture.
  Future<void> _checkPackage(PendingInstall item) async {
    final ProcessResult result;
    try {
      result = await runner.run(_dpkgDeb, [
        '--field',
        item.asset.file.path,
        'Package',
        'Version',
        'Architecture',
      ]);
    } on ProcessException catch (error) {
      throw UpdateFailure(UpdateFailureKind.failed, detail: '$error');
    }
    final fields = <String, String>{
      for (final line in const LineSplitter().convert('${result.stdout}'))
        if (line.indexOf(': ') case final colon when colon > 0)
          line.substring(0, colon): line.substring(colon + 2),
    };
    if (result.exitCode != 0 ||
        fields['Package'] != item.copy.app.linux.package ||
        fields['Version'] != '${item.version}' ||
        fields['Architecture'] != 'amd64') {
      throw UpdateFailure(
        UpdateFailureKind.verification,
        code: result.exitCode,
        detail: 'package fields: $fields',
      );
    }
  }

  /// Versions of the packages of [apps] that are fully installed.
  Future<Map<String, ReleaseVersion>> _installedVersions(
    List<SuiteApp> apps,
  ) async {
    final ProcessResult result;
    try {
      result = await runner.run(_dpkgQuery, [
        '-W',
        _showFormat,
        for (final app in apps) app.linux.package,
      ]);
    } on ProcessException catch (error) {
      throw UpdateFailure(UpdateFailureKind.failed, detail: '$error');
    }
    // 1 means that some package is not installed; the others are listed
    if (result.exitCode != 0 && result.exitCode != 1) {
      throw UpdateFailure(
        UpdateFailureKind.failed,
        code: result.exitCode,
        detail: 'dpkg-query: ${result.stderr}'.trim(),
      );
    }
    final versions = <String, ReleaseVersion>{};
    for (final line in const LineSplitter().convert('${result.stdout}')) {
      final fields = line.split('\t');
      if (fields.length != 3 || fields[1] != 'installed') continue;
      final version = ReleaseVersion.tryParse(fields[2]);
      if (version != null) versions[fields[0]] = version;
    }
    return versions;
  }

  static Stream<String> _lines(Stream<List<int>> output) => output
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  /// [text] as one argument for a POSIX shell.
  static String _quote(String text) => "'${text.replaceAll("'", r"'\''")}'";

  static List<String> _entries(String folder) {
    try {
      return [
        for (final entity in Directory(folder).listSync(followLinks: false))
          entity.path,
      ];
    } on FileSystemException {
      return const [];
    }
  }

  /// Deletes the folder at [path] and everything in it, never through a link.
  static void _deleteTree(String path) {
    try {
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.directory) {
        Directory(path).deleteSync(recursive: true);
      }
    } on FileSystemException {
      // the next run's cleanup tries again
    }
  }
}
