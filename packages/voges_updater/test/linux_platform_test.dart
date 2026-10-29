@TestOn('!windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voges_updater/core.dart';

import 'support/platforms_fakes.dart';

const _binary = '/usr/lib/voges-word/voges_word';
const _showFormat =
    r'--showformat=${Package}\t${db:Status-Status}\t${Version}\n';

const _vogesSheets = SuiteApp(
  name: 'Voges Sheets',
  repository: 'omanoloneto/voges-sheets',
  downloadPage: 'https://omanoloneto.pro/voges/sheets/',
  macos: MacosTarget(
    bundleId: 'com.omanoloneto.vogesSheets',
    bundleName: 'Voges Sheets.app',
    asset: 'VogesSheets-macos.dmg',
  ),
  windows: WindowsTarget(
    appId: '{00000000-0000-0000-0000-000000000000}',
    executable: 'voges_sheets.exe',
    asset: 'VogesSheets-windows-setup.exe',
  ),
  linux: LinuxTarget(
    package: 'voges-sheets',
    binary: '/usr/lib/voges-sheets/voges_sheets',
    launcher: '/usr/bin/voges-sheets',
    asset: 'voges-sheets-linux-amd64.deb',
  ),
);

void main() {
  late Directory root;
  late FakeProcessRunner runner;

  /// What dpkg-query prints, and its exit code.
  late String packages;
  late int queryCode;

  /// The fields dpkg-deb prints, by package file.
  late Map<String, String> fields;

  setUp(() {
    root = platformsTempRoot();
    Directory(p.join(root.path, 'tmp')).createSync();
    File(p.join(root.path, 'usr', 'bin', 'pkexec')).createSync(recursive: true);
    packages = 'voges-word\tinstalled\t1.1.0\n';
    queryCode = 0;
    fields = {};
    runner = FakeProcessRunner(
      onRun: (call) => switch (call.tool) {
        'dpkg-query' => processResult(queryCode, stdout: packages),
        'dpkg-deb' => processResult(0, stdout: fields[call.arguments[1]]!),
        _ => processResult(0),
      },
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  LinuxPlatform platform({String executable = _binary}) => LinuxPlatform(
    hostApp: vogesWord,
    runner: runner,
    executable: executable,
    ownPid: 4242,
    root: root.path,
  );

  group('finding the apps', () {
    test('reads every package with one dpkg-query call', () async {
      final linux = platform();

      final copies = await linux.installed(vogesSuite, await linux.host());

      expect(runner.argvs, [
        ['/usr/bin/dpkg-query', '-W', _showFormat, 'voges-word'],
      ]);
      final copy = copies.single;
      expect(copy.app, same(vogesWord));
      expect(copy.version, const ReleaseVersion(1, 1, 0));
      expect(copy.location, _binary);
      expect(copy.scope, InstallScope.user);
      expect(copy.isHost, isTrue);
    });

    test('counts only installed packages with strict versions', () async {
      for (final (output, code) in [
        ('voges-word\tconfig-files\t0.9.0\n', 0),
        ('voges-word\tunpacked\t1.2.0\n', 0),
        ('voges-word\tinstalled\t1.2.0-1\n', 0),
        ('', 1),
      ]) {
        packages = output;
        queryCode = code;

        expect(
          await platform().installed(vogesSuite, null),
          isEmpty,
          reason: output,
        );
      }
    });

    test('keeps the packages found when others are missing', () async {
      packages = 'voges-word\tinstalled\t1.1.0\n';
      queryCode = 1;

      final copies = await platform().installed([
        vogesWord,
        _vogesSheets,
      ], null);

      expect(runner.argvs.single.last, 'voges-sheets');
      expect([for (final copy in copies) copy.app], [vogesWord]);
    });

    test('fails on other dpkg-query errors', () async {
      queryCode = 2;

      await expectLater(
        platform().installed(vogesSuite, null),
        throwsA(isA<UpdateFailure>()),
      );
    });
  });

  group('the host', () {
    test('is the app compiled in, running from its package', () async {
      final host = await platform().host();

      expect(host?.app, same(vogesWord));
      expect(host?.reopenPath, '/usr/bin/voges-word');
      expect(
        await platform(executable: '/opt/voges/voges_word').host(),
        isNull,
      );
    });
  });

  group('running apps', () {
    test('finds instances through /proc, even replaced ones', () async {
      final proc = p.join(root.path, 'proc');
      void process(String name, String? executable) {
        Directory(p.join(proc, name)).createSync(recursive: true);
        if (executable != null) {
          Link(p.join(proc, name, 'exe')).createSync(executable);
        }
      }

      process('100', _binary);
      process('101', '$_binary (deleted)');
      process('102', '/usr/bin/bash');
      process('103', null);
      process('4242', _binary);
      Link(p.join(proc, 'self')).createSync(p.join(proc, '100'));
      File(p.join(proc, 'cpuinfo')).createSync();

      final running = await platform().running([
        InstalledCopy(
          app: vogesWord,
          version: const ReleaseVersion(1, 1, 0),
          location: _binary,
        ),
      ]);

      expect([for (final app in running) app.pid]..sort(), [100, 101]);
      expect(running.every((app) => !app.otherAccount), isTrue);
    });
  });

  group('installing', () {
    late LinuxPlatform linux;
    late Directory work;

    setUp(() async {
      linux = platform();
      work = await linux.workDirectory();
      runner.calls.clear();
    });

    PendingInstall pending(SuiteApp app, {String version = '1.2.0'}) {
      final file = p.join(work.path, app.linux.asset);
      fields[file] =
          'Package: ${app.linux.package}\nVersion: $version\n'
          'Architecture: amd64\n';
      return PendingInstall(
        copy: InstalledCopy(
          app: app,
          version: const ReleaseVersion(1, 1, 0),
          location: app.linux.binary,
        ),
        version: const ReleaseVersion(1, 2, 0),
        asset: verifiedFile(file),
      );
    }

    List<String> pkexec(List<String> packages) => [
      '/usr/bin/pkexec',
      '/usr/bin/apt-get',
      'install',
      '-y',
      '--no-remove',
      '-o',
      'DPkg::Lock::Timeout=120',
      '-o',
      'APT::Status-Fd=1',
      '--',
      ...packages,
    ];

    test('installs every package with one password prompt', () async {
      final process = FakeProcess(
        stdout: [
          'pmstatus:voges-word:20:Preparing voges-word',
          'pmstatus:voges-sheets:80:Configuring voges-sheets',
        ],
      );
      runner.onStart = (_) {
        packages =
            'voges-word\tinstalled\t1.2.0\nvoges-sheets\tinstalled\t1.2.0\n';
        return process;
      };
      final word = pending(vogesWord);
      final sheets = pending(_vogesSheets);
      final steps = <(PendingInstall, InstallStep)>[];

      final outcomes = await linux.install([
        word,
        sheets,
      ], (item, step) => steps.add((item, step)));

      expect(outcomes.every((outcome) => outcome is Installed), isTrue);
      expect([for (final outcome in outcomes) outcome.item], [word, sheets]);
      expect(runner.argvs, [
        [
          '/usr/bin/dpkg-deb',
          '--field',
          word.asset.file.path,
          'Package',
          'Version',
          'Architecture',
        ],
        [
          '/usr/bin/dpkg-deb',
          '--field',
          sheets.asset.file.path,
          'Package',
          'Version',
          'Architecture',
        ],
        pkexec([word.asset.file.path, sheets.asset.file.path]),
        [
          '/usr/bin/dpkg-query',
          '-W',
          _showFormat,
          'voges-word',
          'voges-sheets',
        ],
      ]);
      expect(runner.calls[2].mode, ProcessStartMode.normal);
      expect(process.stdinClosed, isTrue);
      expect(steps, [
        (word, InstallStep.waitingForPermission),
        (sheets, InstallStep.waitingForPermission),
        (word, InstallStep.installing),
        (sheets, InstallStep.installing),
      ]);
    });

    test('maps the exit codes of pkexec and apt-get', () async {
      for (final (code, stderr, kind) in [
        (126, '', UpdateFailureKind.declined),
        (
          127,
          'Error creating textual authentication agent: Error opening '
              'current controlling terminal for the process',
          UpdateFailureKind.noPasswordWindow,
        ),
        (
          127,
          'Error executing command as another user: Not authorized',
          UpdateFailureKind.notAuthorized,
        ),
        (
          100,
          'E: Packages were downgraded and -y was used without '
              '--allow-downgrades.',
          UpdateFailureKind.packageManager,
        ),
        (1, '', UpdateFailureKind.failed),
      ]) {
        runner.onStart = (_) => FakeProcess(exitCode: code, stderr: [stderr]);
        final item = pending(vogesWord);

        final outcome = (await linux.install([item], (_, _) {})).single;

        final failure = (outcome as NotInstalled).failure;
        expect(failure.kind, kind, reason: 'exit code $code');
        expect(failure.code, code);
        final offersCommand = {
          UpdateFailureKind.noPasswordWindow,
          UpdateFailureKind.notAuthorized,
          UpdateFailureKind.packageManager,
        }.contains(kind);
        expect(failure.command != null, offersCommand, reason: '$kind');
        if (kind == UpdateFailureKind.packageManager) {
          expect(failure.detail, stderr);
        }
      }
    });

    test('trusts the package database over the exit code', () async {
      runner.onStart = (_) {
        packages = 'voges-word\tinstalled\t1.2.0\n';
        return FakeProcess(exitCode: 1);
      };

      final outcome = (await linux.install([
        pending(vogesWord),
      ], (_, _) {})).single;

      expect(outcome, isA<Installed>());
    });

    test('fails when the version did not change after exit code 0', () async {
      final outcome = (await linux.install([
        pending(vogesWord),
      ], (_, _) {})).single;

      expect((outcome as NotInstalled).failure.kind, UpdateFailureKind.failed);
    });

    test('offers the terminal command when pkexec is missing', () async {
      File(p.join(root.path, 'usr', 'bin', 'pkexec')).deleteSync();
      final quoted = Directory(p.join(work.path, "it's"))..createSync();
      final file = p.join(quoted.path, 'voges-word-linux-amd64.deb');
      fields[file] =
          'Package: voges-word\nVersion: 1.2.0\nArchitecture: amd64\n';
      final item = PendingInstall(
        copy: const InstalledCopy(
          app: vogesWord,
          version: ReleaseVersion(1, 1, 0),
          location: _binary,
        ),
        version: const ReleaseVersion(1, 2, 0),
        asset: verifiedFile(file),
      );
      final steps = <InstallStep>[];

      final outcome = (await linux.install([
        item,
      ], (_, step) => steps.add(step))).single;

      final failure = (outcome as NotInstalled).failure;
      expect(failure.kind, UpdateFailureKind.noPasswordWindow);
      expect(
        failure.command,
        "sudo apt install '${quoted.path.replaceAll("'", r"'\''")}"
        "/voges-word-linux-amd64.deb'",
      );
      expect(runner.calls.where((call) => call.mode != null), isEmpty);
      expect(steps, isEmpty);
    });

    test('refuses a package for another app, version or system', () async {
      for (final wrong in [
        'Package: voges-sheets\nVersion: 1.2.0\nArchitecture: amd64\n',
        'Package: voges-word\nVersion: 1.3.0\nArchitecture: amd64\n',
        'Package: voges-word\nVersion: 1.2.0\nArchitecture: arm64\n',
      ]) {
        final item = pending(vogesWord);
        fields[item.asset.file.path] = wrong;

        final outcome = (await linux.install([item], (_, _) {})).single;

        expect(
          (outcome as NotInstalled).failure.kind,
          UpdateFailureKind.verification,
        );
      }
      expect(runner.calls.where((call) => call.mode != null), isEmpty);
    });

    test('refuses a package that changed after the download', () async {
      final item = pending(vogesWord);
      item.asset.file.writeAsStringSync('tampered');

      final outcome = (await linux.install([item], (_, _) {})).single;

      expect(
        (outcome as NotInstalled).failure.kind,
        UpdateFailureKind.verification,
      );
      expect(runner.calls, isEmpty);
    });
  });

  group('folders', () {
    test('works in a private folder of /tmp', () async {
      final work = await platform().workDirectory();

      expect(p.dirname(work.path), p.join(root.path, 'tmp'));
      expect(p.basename(work.path), startsWith('voges-update-'));
      expect(runner.argvs, [
        ['/bin/chmod', '700', work.path],
      ]);
    });

    test('refuses a work folder it can\'t make private', () async {
      runner.onRun = (call) => processResult(1, stderr: 'not permitted');

      await expectLater(
        platform().workDirectory(),
        throwsA(
          isA<UpdateFailure>().having(
            (failure) => failure.kind,
            'kind',
            UpdateFailureKind.failed,
          ),
        ),
      );
    });

    test('deletes the folders of earlier runs, by exact name', () async {
      final linux = platform();
      final current = await linux.workDirectory();
      final tmp = current.parent;
      final outside = Directory(p.join(root.path, 'outside'))..createSync();
      Directory(
        p.join(tmp.path, 'voges-update-abc123', 'nested'),
      ).createSync(recursive: true);
      Directory(p.join(tmp.path, 'voges-update-x_y')).createSync();
      Directory(p.join(tmp.path, 'other-app')).createSync();
      Link(p.join(tmp.path, 'voges-update-link01')).createSync(outside.path);

      await linux.cleanStale(current);

      expect(
        [for (final entity in tmp.listSync()) p.basename(entity.path)]..sort(),
        [
          p.basename(current.path),
          'other-app',
          'voges-update-link01',
          'voges-update-x_y',
        ]..sort(),
      );
      expect(outside.existsSync(), isTrue);
    });
  });

  group('leaving', () {
    test(
      'reopens the app through its launcher and deletes the files',
      () async {
        final linux = platform();
        final work = await linux.workDirectory();
        runner.calls.clear();

        linux.finishSync(await linux.host());

        final call = runner.calls.single;
        expect(call.argv, ['/usr/bin/voges-word']);
        expect(call.mode, ProcessStartMode.detached);
        expect(work.existsSync(), isFalse);
      },
    );

    test('never throws while finishing', () async {
      runner.onStart = (_) => throw const ProcessException('voges-word', []);

      platform().finishSync(await platform().host());
      await pumpEventQueue();
    });
  });
}
