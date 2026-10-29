import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voges_updater/core.dart';

import 'support/platforms_fakes.dart';

const _reg = r'C:\Windows\System32\reg.exe';
const _tasklist = r'C:\Windows\System32\tasklist.exe';
const _userKey =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    r'\{237302D4-CF82-4A6D-B1A5-F3E8C553542A}_is1';
const _machineKey =
    r'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    r'\{237302D4-CF82-4A6D-B1A5-F3E8C553542A}_is1';

List<String> _query(String key) => [
  _reg,
  'query',
  key,
  '/v',
  'DisplayVersion',
  '/reg:64',
];

/// reg.exe's output for a found value: CRLF lines, 4-space separators.
ProcessResult _found(String key, String version) => processResult(
  0,
  stdout:
      '\r\n${key.replaceFirst('HKCU', 'HKEY_CURRENT_USER').replaceFirst('HKLM', 'HKEY_LOCAL_MACHINE')}'
      '\r\n    DisplayVersion    REG_SZ    $version\r\n\r\n',
);

final _notFound = processResult(
  1,
  stderr: 'ERRO: o sistema não conseguiu localizar a chave ou o valor.',
);

void main() {
  late Directory root;
  late FakeProcessRunner runner;

  /// The registry as reg.exe answers it, by key.
  late Map<String, ProcessResult> registry;

  setUp(() {
    root = platformsTempRoot();
    registry = {};
    runner = FakeProcessRunner(
      onRun: (call) => call.tool == 'reg.exe'
          ? registry[call.arguments[1]] ?? _notFound
          : processResult(0),
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  WindowsPlatform platform({
    String? relaunch,
    String? executable,
    Map<String, String> environment = const {},
  }) => WindowsPlatform(
    hostApp: vogesWord,
    relaunch: relaunch,
    runner: runner,
    environment: environment,
    executable:
        executable ??
        p.join(root.path, 'voges-updater-abc123', 'app', 'voges_word.exe'),
    ownPid: 4242,
    temp: Directory(p.join(root.path, 'temp'))..createSync(),
  );

  String install(String folder, {String exe = 'voges_word.exe'}) {
    final executable = p.join(root.path, folder, exe);
    File(executable).createSync(recursive: true);
    File(p.join(root.path, folder, 'unins000.exe')).createSync();
    return executable;
  }

  group('finding the apps', () {
    test('reads DisplayVersion of each hive with reg.exe', () async {
      registry[_userKey] = _found(_userKey, '1.1.0');
      const host = UpdaterHost(app: vogesWord, reopenPath: r'C:\x.exe');

      final copies = await platform().installed(vogesSuite, host);

      expect(runner.argvs, [_query(_userKey), _query(_machineKey)]);
      final copy = copies.single;
      expect(copy.app, same(vogesWord));
      expect(copy.version, const ReleaseVersion(1, 1, 0));
      expect(copy.scope, InstallScope.user);
      expect(copy.location, _userKey);
      expect(copy.isHost, isTrue);
    });

    test('lists an install in each hive', () async {
      registry[_userKey] = _found(_userKey, '1.0.0');
      registry[_machineKey] = _found(_machineKey, '1.1.0');

      final copies = await platform().installed(vogesSuite, null);

      expect(
        [for (final copy in copies) copy.scope],
        [InstallScope.user, InstallScope.allUsers],
      );
      expect(
        [for (final copy in copies) '${copy.version}'],
        ['1.0.0', '1.1.0'],
      );
      expect(copies.every((copy) => !copy.isHost), isTrue);
    });

    test('skips versions that are not strict', () async {
      registry[_userKey] = _found(_userKey, '1.1.0.0');

      expect(await platform().installed(vogesSuite, null), isEmpty);
    });

    test('fails on any other answer of reg.exe', () async {
      registry[_userKey] = processResult(5, stderr: 'ERROR: Access denied');
      await expectLater(
        platform().installed(vogesSuite, null),
        throwsA(isA<UpdateFailure>()),
      );

      registry[_userKey] = processResult(0, stdout: '\r\n$_userKey\r\n');
      await expectLater(
        platform().installed(vogesSuite, null),
        throwsA(isA<UpdateFailure>()),
      );
    });

    test('calls the tools in SystemRoot', () async {
      await platform(
        environment: {'SystemRoot': r'D:\Windows'},
      ).installed(vogesSuite, null);

      expect(runner.calls.first.executable, r'D:\Windows\System32\reg.exe');
    });
  });

  group('the host', () {
    test('is the installed executable passed with --relaunch', () async {
      final relaunch = install('Voges Word');

      final host = await platform(relaunch: relaunch).host();

      expect(host?.app, same(vogesWord));
      expect(host?.reopenPath, relaunch);
    });

    test('compares the executable name without case', () async {
      final relaunch = install('Upper', exe: 'VOGES_WORD.EXE');

      expect(await platform(relaunch: relaunch).host(), isNotNull);
    });

    test('must be an Inno Setup install of the app', () async {
      final noUninstaller = p.join(root.path, 'Portable', 'voges_word.exe');
      File(noUninstaller).createSync(recursive: true);
      final other = install('Other', exe: 'other.exe');

      for (final relaunch in [
        noUninstaller,
        other,
        p.join(root.path, 'Missing', 'voges_word.exe'),
        'voges_word.exe',
      ]) {
        expect(await platform(relaunch: relaunch).host(), isNull);
      }
      expect(await platform().host(), isNull);
    });
  });

  group('running apps', () {
    test('reads its own session once and lists the others in it', () async {
      runner.onRun = (call) => processResult(
        0,
        stdout: call.arguments.last == 'PID eq 4242'
            ? '"voges_word.exe","4242","Console","1","142,356 K"\r\n'
            : '"voges_word.exe","4242","Console","1","142,356 K"\r\n'
                  '"voges_word.exe","5000","Console","1","90,120 K"\r\n'
                  '"voges_word.exe","6000","RDP-Tcp#0","2","88,004 K"\r\n',
      );
      final windows = platform();
      final copies = [
        InstalledCopy(
          app: vogesWord,
          version: const ReleaseVersion(1, 1, 0),
          location: _userKey,
        ),
      ];

      final first = await windows.running(copies);
      await windows.running(copies);

      expect([for (final app in first) app.pid], [5000]);
      expect(runner.argvs, [
        [_tasklist, '/FO', 'CSV', '/NH', '/FI', 'PID eq 4242'],
        [_tasklist, '/FO', 'CSV', '/NH', '/FI', 'IMAGENAME eq voges_word.exe'],
        [_tasklist, '/FO', 'CSV', '/NH', '/FI', 'IMAGENAME eq voges_word.exe'],
      ]);
    });

    test('reads the translated no-match line as no instances', () async {
      runner.onRun = (call) => processResult(
        0,
        stdout: call.arguments.last == 'PID eq 4242'
            ? '"voges_word.exe","4242","Console","1","142,356 K"\r\n'
            : 'INFORMAÇÕES: nenhuma tarefa em execução corresponde aos '
                  'critérios especificados.\r\n',
      );

      final running = await platform().running([
        InstalledCopy(
          app: vogesWord,
          version: const ReleaseVersion(1, 1, 0),
          location: _userKey,
        ),
      ]);

      expect(running, isEmpty);
    });
  });

  group('installing', () {
    late WindowsPlatform windows;
    late Directory downloads;

    setUp(() async {
      windows = platform();
      downloads = await windows.workDirectory();
    });

    PendingInstall pending(InstallScope scope) => PendingInstall(
      copy: InstalledCopy(
        app: vogesWord,
        version: const ReleaseVersion(1, 1, 0),
        location: scope == InstallScope.user ? _userKey : _machineKey,
        scope: scope,
      ),
      version: const ReleaseVersion(1, 2, 0),
      asset: verifiedFile(
        p.join(downloads.path, 'VogesWord-windows-setup.exe'),
      ),
    );

    List<String> setup(String installer, String scope, String log) => [
      installer,
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/SP-',
      scope,
      '/LOG=${p.join(root.path, 'voges-updater-abc123', 'logs', log)}',
    ];

    test('runs Inno Setup per scope, per-user installs first', () async {
      final processes = <FakeProcess>[];
      runner.onStart = (_) {
        registry[_userKey] = _found(_userKey, '1.2.0');
        registry[_machineKey] = _found(_machineKey, '1.2.0');
        final process = FakeProcess();
        processes.add(process);
        return process;
      };
      final machine = pending(InstallScope.allUsers);
      final user = pending(InstallScope.user);
      final steps = <(PendingInstall, InstallStep)>[];

      final outcomes = await windows.install([
        machine,
        user,
      ], (item, step) => steps.add((item, step)));

      final installer = user.asset.file.path;
      expect(
        runner.calls.where((call) => call.mode != null).map((c) => c.argv),
        [
          setup(installer, '/CURRENTUSER', 'VogesWord-windows-setup-user.log'),
          setup(installer, '/ALLUSERS', 'VogesWord-windows-setup-allUsers.log'),
        ],
      );
      for (final call in runner.calls.where((call) => call.mode != null)) {
        expect(call.workingDirectory, downloads.path);
        expect(call.mode, ProcessStartMode.normal);
        expect(
          call.arguments.where(
            (argument) => RegExp(
              r'^/(DIR|TASKS|NOCLOSEAPPLICATIONS|FORCECLOSEAPPLICATIONS)',
              caseSensitive: false,
            ).hasMatch(argument),
          ),
          isEmpty,
        );
      }
      expect(processes.every((process) => process.stdinClosed), isTrue);
      expect(steps, [
        (user, InstallStep.installing),
        (machine, InstallStep.waitingForPermission),
      ]);
      expect([for (final outcome in outcomes) outcome.item], [machine, user]);
      expect(outcomes.every((outcome) => outcome is Installed), isTrue);
      expect(runner.argvs.where((argv) => argv.first == _reg), [
        _query(_userKey),
        _query(_machineKey),
      ]);
    });

    test('maps the exit codes of Inno Setup', () async {
      for (final (code, kind) in [
        (2, UpdateFailureKind.declined),
        (5, UpdateFailureKind.inUse),
        (1, UpdateFailureKind.failed),
        (7, UpdateFailureKind.failed),
      ]) {
        runner.onStart = (_) => FakeProcess(exitCode: code);

        final outcome = (await windows.install([
          pending(InstallScope.user),
        ], (_, _) {})).single;

        final failure = (outcome as NotInstalled).failure;
        expect(failure.kind, kind, reason: 'exit code $code');
        expect(failure.code, code);
        expect(failure.logPath != null, kind == UpdateFailureKind.failed);
      }
    });

    test('checks the version in the registry after a success', () async {
      registry[_userKey] = _found(_userKey, '1.1.0');

      final outcome = (await windows.install([
        pending(InstallScope.user),
      ], (_, _) {})).single;

      final failure = (outcome as NotInstalled).failure;
      expect(failure.kind, UpdateFailureKind.failed);
      expect(failure.logPath, isNotNull);
    });

    test('refuses an installer that changed after the download', () async {
      final item = pending(InstallScope.user);
      item.asset.file.writeAsStringSync('tampered');

      final outcome = (await windows.install([item], (_, _) {})).single;

      expect(
        (outcome as NotInstalled).failure.kind,
        UpdateFailureKind.verification,
      );
      expect(runner.calls.where((call) => call.mode != null), isEmpty);
    });
  });

  group('folders', () {
    test('keeps the downloads next to the running copy', () async {
      final work = await platform().workDirectory();

      expect(work.path, p.join(root.path, 'voges-updater-abc123', 'downloads'));
      expect(work.existsSync(), isTrue);
    });

    test('uses a new temp folder when not run from a copy', () async {
      final work = await platform(
        executable: p.join(root.path, 'Voges Word', 'voges_word.exe'),
      ).workDirectory();

      expect(p.basename(work.path), 'downloads');
      expect(p.dirname(p.dirname(work.path)), p.join(root.path, 'temp'));
      expect(p.basename(p.dirname(work.path)), startsWith('voges-updater-'));
    });
  });

  group('leaving', () {
    test('reopens the installed app, detached, from its folder', () {
      final relaunch = install('Voges Word');

      platform(
        relaunch: relaunch,
      ).finishSync(UpdaterHost(app: vogesWord, reopenPath: relaunch));

      final call = runner.calls.single;
      expect(call.argv, [relaunch]);
      expect(call.mode, ProcessStartMode.detached);
      expect(call.workingDirectory, p.dirname(relaunch));
    });

    test('never throws while finishing', () async {
      runner.onStart = (_) => throw const ProcessException('voges_word', []);

      platform().finishSync(
        const UpdaterHost(app: vogesWord, reopenPath: r'C:\Voges\x.exe'),
      );
      platform().finishSync(null);
      await pumpEventQueue();

      expect(runner.calls, hasLength(1));
    });
  });
}
