/// End-to-end check of Voges Updater against the app installed on this
/// computer, for CI and test machines. A fake GitHub on 127.0.0.1 serves the
/// new installer, signed with a key made for this run, and the production
/// code finds the installed app, downloads and verifies the update, and
/// installs it:
///
///     dart run tool/e2e.dart macos --old <X.Y.Z> --new <X.Y.Z>
///         --installer <.dmg>
///     dart run tool/e2e.dart windows --old <X.Y.Z> --new <X.Y.Z>
///         --installer <setup .exe> --scope <user|all-users>
///         --app <installed voges_word.exe>
///     dart run tool/e2e.dart linux --old <X.Y.Z> --new <X.Y.Z>
///         --installer <.deb> --old-installer <.deb of --old>
///
/// The app must be installed once, at --old. The run replaces it, opens and
/// closes it, and on Linux runs apt through pkexec. Every check prints PASS
/// or FAIL, and the exit code is 1 when any check failed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:voges_updater/core.dart';

import 'fake_github.dart';
import 'release_signing.dart' show publicKeyOf;

Future<void> main(List<String> arguments) async {
  final EndToEndOptions options;
  try {
    options = EndToEndOptions.parse(arguments);
  } on FormatException catch (error) {
    stderr
      ..writeln(error.message)
      ..writeln(_usage);
    exitCode = 64;
    return;
  }
  final passed = await EndToEnd(
    options,
    SuitePlatform.current(host: vogesWord, relaunch: options.app),
  ).run();
  await stdout.flush();
  // nothing this run left open may keep a CI step waiting
  exit(passed ? 0 : 1);
}

const _usage = '''
Usage:
  dart run tool/e2e.dart macos --old <X.Y.Z> --new <X.Y.Z> --installer <.dmg>
  dart run tool/e2e.dart windows --old <X.Y.Z> --new <X.Y.Z>
      --installer <setup .exe> --scope <user|all-users>
      --app <installed voges_word.exe>
  dart run tool/e2e.dart linux --old <X.Y.Z> --new <X.Y.Z>
      --installer <.deb> --old-installer <.deb of --old>''';

/// The command line of one run.
final class EndToEndOptions {
  const EndToEndOptions({
    required this.system,
    required this.old,
    required this.latest,
    required this.installer,
    this.scope,
    this.app,
    this.oldInstaller,
  });

  /// `macos`, `windows` or `linux`: always the system running the check.
  final String system;

  /// The version installed before the update.
  final ReleaseVersion old;

  /// The version that the fake GitHub publishes.
  final ReleaseVersion latest;

  /// The installer of [latest].
  final File installer;

  /// Windows: the registry hive of the install.
  final InstallScope? scope;

  /// Windows: the installed executable, which the updater opens again.
  final String? app;

  /// Linux: the package of [old], which apt must refuse as a downgrade.
  final File? oldInstaller;

  static const _options = {
    'macos': {'--old', '--new', '--installer'},
    'windows': {'--old', '--new', '--installer', '--scope', '--app'},
    'linux': {'--old', '--new', '--installer', '--old-installer'},
  };

  /// Reads [arguments] strictly; throws a [FormatException] for anything
  /// else than the usage, or for another system than this one.
  static EndToEndOptions parse(List<String> arguments) {
    final system = arguments.firstOrNull;
    final names = _options[system];
    if (system == null || names == null) {
      throw const FormatException('Name the system: macos, windows or linux.');
    }
    if (system != Platform.operatingSystem) {
      throw FormatException(
        'This computer runs ${Platform.operatingSystem}, not $system.',
      );
    }
    final values = <String, String>{};
    for (var i = 1; i < arguments.length; i += 2) {
      final name = arguments[i];
      if (!names.contains(name) ||
          values.containsKey(name) ||
          i + 1 == arguments.length) {
        throw FormatException('Unexpected $name.');
      }
      values[name] = arguments[i + 1];
    }
    final missing = names.where((name) => !values.containsKey(name));
    if (missing.isNotEmpty) {
      throw FormatException('Missing ${missing.join(', ')}.');
    }

    final old = ReleaseVersion.tryParse(values['--old']!);
    final latest = ReleaseVersion.tryParse(values['--new']!);
    if (old == null || latest == null || !latest.isNewerThan(old)) {
      throw const FormatException(
        '--old and --new are X.Y.Z versions, --new the higher one.',
      );
    }
    File existing(String name) {
      final file = File(values[name]!);
      if (!file.existsSync()) {
        throw FormatException('$name: ${file.path} does not exist.');
      }
      return file.absolute;
    }

    final app = values['--app'];
    if (app != null &&
        (!p.windows.isAbsolute(app) || !File(app).existsSync())) {
      throw FormatException('--app: $app is not an installed executable.');
    }
    return EndToEndOptions(
      system: system,
      old: old,
      latest: latest,
      installer: existing('--installer'),
      scope: switch (values['--scope']) {
        null => null,
        'user' => InstallScope.user,
        'all-users' => InstallScope.allUsers,
        final other => throw FormatException(
          '--scope is user or all-users, not $other.',
        ),
      },
      app: app,
      oldInstaller: names.contains('--old-installer')
          ? existing('--old-installer')
          : null,
    );
  }
}

/// One run of the checks against the installed app, through [platform].
final class EndToEnd {
  EndToEnd(
    this.options,
    this.platform, {
    this.runner = const SystemProcessRunner(),
  });

  final EndToEndOptions options;
  final SuitePlatform platform;

  /// Opens the apps and runs the system tools that the checks use.
  final ProcessRunner runner;

  static const _app = vogesWord;
  static const _liveness = Duration(seconds: 10);
  static const _sandbox = 'com.apple.security.app-sandbox';

  final _checks = _Checks();
  final _seed = _randomSeed();
  late final String _trustedKey;
  late final String _asset = platform.assetOf(_app);

  /// Processes this run started, stopped when it ends.
  final _started = <int>[];

  /// Runs every check of [EndToEndOptions.system]; true when all passed.
  Future<bool> run() async {
    try {
      await _run();
    } on _Stop {
      // its failed check is printed
    } catch (error, stack) {
      _checks.check('runs without unexpected errors', false, '$error\n$stack');
    }
    stdout.writeln('${_checks.passed} passed, ${_checks.failed} failed');
    return _checks.failed == 0;
  }

  Future<void> _run() async {
    final lock = await UpdaterLock.tryAcquire();
    // held like the updater holds it: an updater this run opens stays on
    // "already open" and leaves the downloads of this run alone
    _checks.require('no other Voges Updater is open', lock != null);
    try {
      _trustedKey = await publicKeyOf(_seed);
      final work = await platform.workDirectory();
      final copy = await _installed(options.old);
      switch (options.system) {
        case 'macos':
          await _macos(copy, work);
        case 'windows':
          await _windows(copy, work);
        case 'linux':
          await _linux(copy, work);
      }
    } finally {
      for (final pid in _started) {
        Process.killPid(pid, ProcessSignal.sigkill);
      }
      platform.finishSync(null);
      await lock!.release();
    }
  }

  /// macOS replaces the app only once it is closed: the run opens it to see
  /// the updater find it, then quits it in place of the user.
  Future<void> _macos(InstalledCopy copy, Directory work) async {
    final opened = await runner.run('/usr/bin/open', [copy.location]);
    final open = await _instances(copy, (apps) => apps.isNotEmpty);
    _checks.check(
      'ps lists the open ${_app.name}',
      open.isNotEmpty,
      opened.stderr,
    );
    for (final app in open) {
      Process.killPid(app.pid);
    }
    final left = await _instances(copy, (apps) => apps.isEmpty);
    _checks.require(
      '${_app.name} closes',
      left.isEmpty,
      'still open: ${[for (final app in left) app.pid].join(', ')}',
    );

    await _refusesUnverified(work);
    _noStagingLeft(copy.location);
    final updated = await _update(copy, work);

    final bundle = updated.location;
    final helper = p.join(bundle, 'Contents', 'Helpers', 'Voges Updater.app');
    final codesign = await runner.run('/usr/bin/codesign', [
      '--verify',
      '--deep',
      '--strict',
      bundle,
    ]);
    _checks.check(
      'codesign accepts the updated app',
      codesign.exitCode == 0,
      codesign.stderr,
    );
    final outer = await _entitlements(bundle);
    _checks.check(
      'the updated app is sandboxed',
      outer?.contains(_sandbox) ?? false,
    );
    final inner = await _entitlements(helper);
    _checks.check(
      'its Voges Updater is signed and not sandboxed',
      inner != null && !inner.contains(_sandbox),
    );
    final attributes = await runner.run('/usr/bin/xattr', ['-lr', bundle]);
    _checks.check(
      'nothing in the updated app is quarantined',
      attributes.exitCode == 0 &&
          !'${attributes.stdout}'.contains('com.apple.quarantine'),
      attributes.stderr,
    );
    _noStagingLeft(bundle);
    final images = await runner.run('/usr/bin/hdiutil', ['info']);
    _checks.check(
      'no disk image of the update is still attached',
      images.exitCode == 0 &&
          !'${images.stdout}'.contains(p.basename(work.path)),
    );

    final launched = await runner.run('/usr/bin/open', [helper]);
    await Future<void>.delayed(_liveness);
    final helpers = await _processesOf(
      p.join(helper, 'Contents', 'MacOS', 'Voges Updater'),
    );
    _started.addAll(helpers);
    _checks.check(
      'Voges Updater opens from the updated app and stays open for 10 s',
      launched.exitCode == 0 && helpers.isNotEmpty,
      launched.stderr,
    );
  }

  /// Windows: the app opens the updater from a copy in the temp folder,
  /// which keeps running while the installer replaces the app.
  Future<void> _windows(InstalledCopy copy, Directory work) async {
    final app = options.app!;
    final host = await platform.host();
    _checks.check(
      'the updater accepts $app as the app to open again',
      host?.reopenPath == app,
    );

    final launches = _RecordingRunner(runner);
    final updater = await _launch(
      WindowsUpdaterLauncher(app: _app, executable: app, runner: launches),
      launches,
    );
    final uninstallers = [
      for (final entity in File(updater.executable).parent.listSync())
        if (p.basename(entity.path).toLowerCase().startsWith('unins'))
          p.basename(entity.path),
    ];
    _checks.check(
      'the copy in the temp folder has no uninstaller',
      uninstallers.isEmpty,
      uninstallers.join(', '),
    );
    _checks.check(
      'tasklist lists the updater, still open after 10 s',
      await _isOpen(copy, updater.pid),
    );

    await _refusesUnverified(work);
    await _update(copy, work);
    _checks.check(
      'the updater is still open after the install',
      await _isOpen(copy, updater.pid),
    );
  }

  /// Linux: dpkg replaces the files of a running app, so a window of the app
  /// and the updater keep running through the update.
  Future<void> _linux(InstalledCopy copy, Directory work) async {
    final window = (await runner.start(
      _app.linux.launcher,
      const [],
      mode: ProcessStartMode.detached,
    )).pid;
    _started.add(window);
    final open = await _instances(
      copy,
      (apps) => apps.any((app) => app.pid == window),
    );
    _checks.check(
      '/proc lists the open ${_app.name}',
      open.any((app) => app.pid == window),
    );

    final launches = _RecordingRunner(runner);
    final updater = await _launch(
      LinuxUpdaterLauncher(
        app: _app,
        executable: _app.linux.binary,
        runner: launches,
      ),
      launches,
    );
    _checks.check(
      '/proc lists the updater, still open after 10 s',
      await _isOpen(copy, updater.pid),
    );

    await _refusesUnverified(work);
    final updated = await _update(copy, work);
    for (final (name, pid) in [
      ('the window', window),
      ('the updater', updater.pid),
    ]) {
      final executable = _executableOf(pid);
      _checks.check(
        '$name keeps running on the replaced binary',
        executable == '${_app.linux.binary} (deleted)' &&
            await _isOpen(updated, pid),
        'executable: $executable',
      );
    }

    final package = options.oldInstaller!;
    final digest = await crypto.sha256.bind(package.openRead()).first;
    final downgrade = (await platform.install([
      PendingInstall(
        copy: updated,
        version: options.old,
        asset: VerifiedAsset(file: package, sha256: '$digest'),
      ),
    ], (_, _) {})).single;
    final failure = downgrade is NotInstalled ? downgrade.failure : null;
    _checks.check(
      'apt refuses to go back to ${options.old}',
      failure?.kind == UpdateFailureKind.packageManager && failure?.code == 100,
      failure ?? 'it was installed',
    );
    await _installed(options.latest, after: 'the refused downgrade');
  }

  /// Releases that must never be installed: each one fails verification,
  /// keeps no file, and leaves the installed app as it was.
  Future<void> _refusesUnverified(Directory work) async {
    final releases = {
      'a tampered installer': (tamper: true, unsigned: false, seed: _seed),
      'a release without its signature': (
        tamper: false,
        unsigned: true,
        seed: _seed,
      ),
      'a release signed by another key': (
        tamper: false,
        unsigned: false,
        seed: _randomSeed(),
      ),
    };
    for (final MapEntry(key: name, value: release) in releases.entries) {
      final fake = await FakeGitHub.start(
        repository: _app.repository,
        version: options.latest,
        assets: {_asset: options.installer},
        seed: release.seed,
        tamper: release.tamper,
        unsigned: release.unsigned,
      );
      final github = _releasesAt(fake);
      Object outcome;
      try {
        outcome = await _downloader(
          github,
        ).fetch(_app, options.latest, _asset, work);
      } on UpdateFailure catch (failure) {
        outcome = failure;
      } finally {
        github.close();
        await fake.close();
      }
      _checks.check(
        'refuses $name as unverified',
        outcome is UpdateFailure &&
            outcome.kind == UpdateFailureKind.verification,
        outcome is VerifiedAsset ? 'it was accepted' : outcome,
      );
      _checks.check(
        'keeps no file of $name',
        !File(p.join(work.path, _asset)).existsSync(),
      );
      await _installed(options.old, after: name);
    }
  }

  /// The update, as the updater runs it: the latest version, its verified
  /// download, the install, and the version the system reports after it.
  Future<InstalledCopy> _update(InstalledCopy copy, Directory work) async {
    final fake = await FakeGitHub.start(
      repository: _app.repository,
      version: options.latest,
      assets: {_asset: options.installer},
      seed: _seed,
    );
    final github = _releasesAt(fake);
    final VerifiedAsset asset;
    try {
      final latest = await _step(
        'reads the latest release',
        () => github.latest(_app.repository),
      );
      _checks.require(
        'the latest release is ${options.latest}',
        latest == options.latest,
        'found $latest',
      );
      asset = await _step(
        'downloads $_asset and verifies it',
        () => _downloader(github).fetch(_app, latest, _asset, work),
      );
    } finally {
      github.close();
      await fake.close();
    }

    final outcome = (await platform.install([
      PendingInstall(copy: copy, version: options.latest, asset: asset),
    ], (_, step) => stdout.writeln('      ${step.name}'))).single;
    final failure = outcome is NotInstalled ? outcome.failure : null;
    if (failure?.logPath case final log?) _printLog(log);
    _checks.require('installs ${options.latest}', failure == null, failure);
    final updated = await _installed(options.latest);
    _checks.check(
      'replaces the copy in place',
      updated.location == copy.location,
      'now at ${updated.location}',
    );
    return updated;
  }

  /// The one installed copy of the app, which must be at [version].
  Future<InstalledCopy> _installed(
    ReleaseVersion version, {
    String? after,
  }) async {
    final copies = [
      for (final copy in await platform.installed(vogesSuite, null))
        if (copy.app.repository == _app.repository) copy,
    ];
    final copy = copies.length == 1 ? copies.single : null;
    final scope = options.scope;
    final where = switch (scope) {
      null => '',
      InstallScope.user => ' for this user',
      InstallScope.allUsers => ' for all users',
    };
    final found = [
      for (final copy in copies)
        '${copy.version} at ${copy.location} (${copy.scope.name})',
    ];
    _checks.require(
      '${_app.name} $version is installed$where'
          '${after == null ? '' : ' after $after'}',
      copy != null &&
          copy.version == version &&
          (scope == null || copy.scope == scope),
      'found: ${found.isEmpty ? 'none' : found.join('; ')}',
    );
    return copy!;
  }

  /// Opens the updater the way the app does, then gives it the time to fail
  /// on arguments it does not trust or on a window it cannot show.
  Future<({String executable, int pid})> _launch(
    UpdaterLauncher launcher,
    _RecordingRunner launches,
  ) async {
    _checks.require(
      'the installed app can open the updater',
      launcher.availability == LaunchAvailability.here,
      launcher.availability.name,
    );
    _checks.require(
      'the updater starts',
      await launcher.launch() == LaunchResult.started &&
          launches.started.isNotEmpty,
    );
    final updater = launches.started.last;
    _started.add(updater.pid);
    await Future<void>.delayed(_liveness);
    return updater;
  }

  Future<bool> _isOpen(InstalledCopy copy, int pid) async =>
      (await platform.running([copy])).any((app) => app.pid == pid);

  /// The open instances of [copy], asked once a second until [until] accepts
  /// them or a minute passes.
  Future<List<RunningApp>> _instances(
    InstalledCopy copy,
    bool Function(List<RunningApp> apps) until,
  ) async {
    final deadline = DateTime.now().add(const Duration(minutes: 1));
    while (true) {
      final apps = await platform.running([copy]);
      if (until(apps) || DateTime.now().isAfter(deadline)) return apps;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  /// [action] as the check [name]; the run stops when it throws.
  Future<T> _step<T>(String name, Future<T> Function() action) async {
    try {
      final value = await action();
      _checks.check(name, true);
      return value;
    } on Exception catch (error) {
      throw _checks.fail(name, error);
    }
  }

  GitHubReleases _releasesAt(FakeGitHub fake) =>
      GitHubReleases(origin: fake.origin, redirectHosts: const {'127.0.0.1'});

  ReleaseDownloader _downloader(GitHubReleases github) => ReleaseDownloader(
    releases: github,
    verifier: ReleaseVerifier(trustedKeys: [_trustedKey]),
  );

  /// macOS stages the new app in a hidden folder beside the old one; none may
  /// be left behind.
  void _noStagingLeft(String bundle) {
    final folder = p.dirname(bundle);
    final left = [
      for (final entity in Directory(folder).listSync(followLinks: false))
        if (p.basename(entity.path).startsWith('.voges-update-'))
          p.basename(entity.path),
    ];
    _checks.check(
      'leaves no staging folder in $folder',
      left.isEmpty,
      left.join(', '),
    );
  }

  /// The entitlements of [bundle] as XML; null when it is not signed.
  Future<String?> _entitlements(String bundle) async {
    final result = await runner.run('/usr/bin/codesign', [
      '-d',
      '--entitlements',
      '-',
      '--xml',
      bundle,
    ]);
    return result.exitCode == 0 ? '${result.stdout}' : null;
  }

  /// macOS: the processes running [executable].
  Future<List<int>> _processesOf(String executable) async {
    final result = await runner.run('/bin/ps', const ['-axo', 'pid=,comm=']);
    return [
      for (final line in const LineSplitter().convert('${result.stdout}'))
        if (RegExp(r'^\s*(\d+)\s+(.+)$').firstMatch(line) case final match?
            when match[2] == executable)
          int.parse(match[1]!),
    ];
  }

  /// Linux: the executable of process [pid], as the kernel reports it.
  static String? _executableOf(int pid) {
    try {
      return Link('/proc/$pid/exe').targetSync();
    } on FileSystemException {
      return null;
    }
  }

  static void _printLog(String path) {
    try {
      stdout.writeln(
        utf8.decode(File(path).readAsBytesSync(), allowMalformed: true),
      );
    } on FileSystemException {
      // the installer stopped before writing it
    }
  }

  static List<int> _randomSeed() {
    final random = Random.secure();
    return [for (var i = 0; i < 32; i++) random.nextInt(256)];
  }
}

/// [_runner], keeping what it starts, so the run can follow the updater
/// that a launcher opens.
final class _RecordingRunner implements ProcessRunner {
  _RecordingRunner(this._runner);

  final ProcessRunner _runner;
  final started = <({String executable, int pid})>[];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) => _runner.run(executable, arguments, workingDirectory: workingDirectory);

  @override
  ProcessResult runSync(String executable, List<String> arguments) =>
      _runner.runSync(executable, arguments);

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final process = await _runner.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      mode: mode,
    );
    started.add((executable: executable, pid: process.pid));
    return process;
  }
}

final class _Checks {
  var passed = 0;
  var failed = 0;

  /// Prints PASS or FAIL for [name], with [detail] when it failed.
  bool check(String name, bool ok, [Object? detail]) {
    if (ok) {
      passed++;
      stdout.writeln('PASS  $name');
      return true;
    }
    failed++;
    stdout.writeln('FAIL  $name');
    final text = '${detail ?? ''}'.trim();
    if (text.isNotEmpty) {
      stdout.writeln('      ${text.replaceAll('\n', '\n      ')}');
    }
    return false;
  }

  /// Like [check], but stops the run when it fails: what follows needs it.
  void require(String name, bool ok, [Object? detail]) {
    if (!check(name, ok, detail)) throw const _Stop();
  }

  /// Records [name] as failed and returns what stops the run.
  _Stop fail(String name, Object? detail) {
    check(name, false, detail);
    return const _Stop();
  }
}

/// Thrown to stop a run whose next steps depend on a failed check.
final class _Stop {
  const _Stop();
}
