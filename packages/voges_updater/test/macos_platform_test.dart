@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voges_updater/core.dart';

import 'support/platforms_fakes.dart';

const _wordId = 'com.omanoloneto.vogesWord';
const _bundleName = 'Voges Word.app';
const _helper =
    'Contents/Helpers/Voges Updater.app/Contents/MacOS/Voges Updater';

void _writeBundle(
  String bundle, {
  String id = _wordId,
  String version = '1.1.0',
}) {
  File(
    p.join(bundle, 'Contents', 'MacOS', 'Voges Word'),
  ).createSync(recursive: true);
  File(p.join(bundle, 'Contents', 'Info.plist')).writeAsStringSync(
    jsonEncode({
      'CFBundleIdentifier': id,
      'CFBundleShortVersionString': version,
      'CFBundleExecutable': 'Voges Word',
    }),
  );
}

String _versionAt(String bundle) =>
    jsonDecode(
          File(p.join(bundle, 'Contents', 'Info.plist')).readAsStringSync(),
        )['CFBundleShortVersionString']
        as String;

void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync()) {
    final target = p.join(to.path, p.basename(entity.path));
    if (entity is Directory) {
      _copyTree(entity, Directory(target));
    } else if (entity is File) {
      entity.copySync(target);
    }
  }
}

/// A Mac in a temp folder. The fake tools act on real files: plutil prints
/// the Info.plist (written as JSON), hdiutil "mounts" a folder holding the
/// new app, and ditto copies it.
final class _Mac {
  _Mac() {
    applications.createSync();
    Directory(p.join(home.path, 'Applications')).createSync(recursive: true);
    temp.createSync();
    runner.onRun = (call) => switch (call.tool) {
      'plutil' => _plutil(call),
      'ps' => processResult(0, stdout: processes),
      'id' => processResult(0, stdout: '501\n'),
      'hdiutil' => hdiutil(call),
      'ditto' => ditto(call),
      'codesign' => codesign(call),
      'xattr' => xattr(call),
      _ => processResult(0),
    };
  }

  final root = platformsTempRoot();
  late final applications = Directory(p.join(root.path, 'Applications'));
  late final home = Directory(p.join(root.path, 'home'));
  late final temp = Directory(p.join(root.path, 'tmp'));
  final runner = FakeProcessRunner();
  var processes = '';
  var dmgId = _wordId;
  var dmgVersion = '1.2.0';
  late ProcessResult Function(RecordedCall call) hdiutil = _hdiutil;
  ProcessResult Function(RecordedCall call) ditto = _ditto;
  ProcessResult Function(RecordedCall call) codesign = (_) => processResult(0);
  ProcessResult Function(RecordedCall call) xattr = (_) =>
      processResult(1, stderr: 'No such xattr: com.apple.quarantine');

  String get target => p.join(applications.path, _bundleName);

  MacosPlatform platform({String? executable}) => MacosPlatform(
    runner: runner,
    executable: executable ?? p.join(root.path, 'Build', _bundleName, _helper),
    ownPid: 100,
    environment: {'HOME': home.path},
    applications: applications.path,
    temp: temp,
  );

  /// The one install of the app in /Applications, ready for [version].
  Future<PendingInstall> pending(MacosPlatform platform, {String? at}) async {
    final copies = await platform.installed(vogesSuite, null);
    final work = await platform.workDirectory();
    return PendingInstall(
      copy: copies.singleWhere((copy) => copy.location == (at ?? target)),
      version: const ReleaseVersion(1, 2, 0),
      asset: verifiedFile(p.join(work.path, 'VogesWord-macos.dmg')),
    );
  }

  List<String> leftovers(String folder) => [
    for (final entity in Directory(folder).listSync())
      if (p.basename(entity.path).startsWith('.voges-update-'))
        p.basename(entity.path),
  ];

  void dispose() {
    Process.runSync('/bin/chmod', ['-R', 'u+w', root.path]);
    root.deleteSync(recursive: true);
  }

  static ProcessResult _plutil(RecordedCall call) {
    final plist = File(call.arguments.last);
    return plist.existsSync()
        ? processResult(0, stdout: plist.readAsStringSync())
        : processResult(1, stderr: 'No such file');
  }

  ProcessResult _hdiutil(RecordedCall call) {
    if (call.arguments.first == 'attach') {
      final mount = call.arguments[call.arguments.indexOf('-mountpoint') + 1];
      _writeBundle(p.join(mount, _bundleName), id: dmgId, version: dmgVersion);
    } else {
      for (final entity in Directory(call.arguments.last).listSync()) {
        entity.deleteSync(recursive: true);
      }
    }
    return processResult(0);
  }

  static ProcessResult _ditto(RecordedCall call) {
    _copyTree(Directory(call.arguments.first), Directory(call.arguments.last));
    return processResult(0);
  }
}

void main() {
  late _Mac mac;

  setUp(() => mac = _Mac());
  tearDown(() => mac.dispose());

  group('finding the apps', () {
    test('finds the host from its own path and reads plutil JSON', () async {
      _writeBundle(mac.target);
      final platform = mac.platform(executable: p.join(mac.target, _helper));

      final host = await platform.host();

      expect(host?.app, same(vogesWord));
      expect(host?.reopenPath, mac.target);
      expect(mac.runner.argvs, [
        [
          '/usr/bin/plutil',
          '-convert',
          'json',
          '-o',
          '-',
          p.join(mac.target, 'Contents', 'Info.plist'),
        ],
      ]);
    });

    test('finds no host outside a suite app', () async {
      _writeBundle(mac.target, id: 'com.example.other');

      expect(await mac.platform(executable: '/usr/bin/true').host(), isNull);
      expect(
        await mac.platform(executable: p.join(mac.target, _helper)).host(),
        isNull,
      );
    });

    test('lists the host first and each real bundle once', () async {
      final user = p.join(mac.home.path, 'Applications', _bundleName);
      _writeBundle(mac.target);
      _writeBundle(user, version: '1.0.0');
      final platform = mac.platform(executable: p.join(mac.target, _helper));

      final copies = await platform.installed(
        vogesSuite,
        await platform.host(),
      );

      expect([for (final copy in copies) copy.location], [mac.target, user]);
      expect(
        [for (final copy in copies) '${copy.version}'],
        ['1.1.0', '1.0.0'],
      );
      expect([for (final copy in copies) copy.isHost], [true, false]);
      expect(copies.every((copy) => copy.scope == InstallScope.user), isTrue);
    });

    test('rejects links, translocated copies and other apps', () async {
      final elsewhere = p.join(mac.root.path, 'Elsewhere', _bundleName);
      _writeBundle(elsewhere);
      Link(
        p.join(mac.home.path, 'Applications', _bundleName),
      ).createSync(elsewhere);
      _writeBundle(mac.target, id: 'com.example.other');
      final translocated = p.join(
        mac.root.path,
        'AppTranslocation',
        'C0FFEE',
        'd',
        _bundleName,
      );
      _writeBundle(translocated);
      final platform = mac.platform(executable: p.join(translocated, _helper));

      final host = await platform.host();
      final copies = await platform.installed(vogesSuite, host);

      expect(host?.reopenPath, translocated);
      expect(copies, isEmpty);
    });

    test('accepts only strict versions', () async {
      for (final version in ['1.2', '1.2.0-beta', '01.2.0']) {
        _writeBundle(mac.target, version: version);
        expect(await mac.platform().installed(vogesSuite, null), isEmpty);
      }
      File(
        p.join(mac.target, 'Contents', 'Info.plist'),
      ).writeAsStringSync('not json');
      expect(await mac.platform().installed(vogesSuite, null), isEmpty);
    });

    test('treats disk images and translocation as temporary places', () {
      expect(
        isTranslocatedOrOnVolume('/Volumes/Voges Word/$_bundleName'),
        isTrue,
      );
      expect(
        isTranslocatedOrOnVolume(
          '/private/var/folders/ab/T/AppTranslocation/0A1B/d/$_bundleName',
        ),
        isTrue,
      );
      expect(isTranslocatedOrOnVolume('/Applications/$_bundleName'), isFalse);
      expect(
        isTranslocatedOrOnVolume('/Users/ana/Volumes/$_bundleName'),
        isFalse,
      );
    });
  });

  group('running apps', () {
    test('matches ps paths with spaces, skipping its own pid', () async {
      _writeBundle(mac.target);
      final executable = p.join(mac.target, 'Contents', 'MacOS', 'Voges Word');
      mac.processes = [
        '  100   501 $executable',
        '  200   501 $executable',
        '  300   502 $executable',
        '  400   501 $executable Helper',
        '  500   501 /Applications/Other.app/Contents/MacOS/Voges Word',
        'not a process line',
      ].join('\n');
      final platform = mac.platform();
      final copies = await platform.installed(vogesSuite, null);

      final first = await platform.running(copies);
      await platform.running(copies);

      expect([for (final app in first) app.pid], [200, 300]);
      expect([for (final app in first) app.otherAccount], [false, true]);
      expect(first.every((app) => app.app == vogesWord), isTrue);
      expect(mac.runner.callsTo('ps').map((call) => call.argv), [
        ['/bin/ps', '-axo', 'pid=,uid=,comm='],
        ['/bin/ps', '-axo', 'pid=,uid=,comm='],
      ]);
      expect(mac.runner.callsTo('id').map((call) => call.argv), [
        ['/usr/bin/id', '-u'],
      ]);
    });
  });

  group('installing', () {
    test('stages, checks and swaps the bundle with these tools', () async {
      _writeBundle(mac.target);
      final platform = mac.platform();
      final item = await mac.pending(platform);
      final steps = <InstallStep>[];

      final outcomes = await platform.install([
        item,
      ], (_, step) => steps.add(step));

      final installed = outcomes.single as Installed;
      expect(installed.version, const ReleaseVersion(1, 2, 0));
      expect(_versionAt(mac.target), '1.2.0');
      expect(steps, [InstallStep.installing]);
      final work = p.dirname(item.asset.file.path);
      final mount = p.join(work, 'mnt-1');
      final staged = mac.runner.callsTo('ditto').single.arguments.last;
      expect(
        staged,
        matches(
          RegExp(
            '^${RegExp.escape(mac.applications.path)}'
            r'/\.voges-update-[A-Za-z0-9]+/Voges Word\.app$',
          ),
        ),
      );
      final tools = {'hdiutil', 'ditto', 'codesign', 'xattr'};
      expect(
        [
          for (final call in mac.runner.calls)
            if (tools.contains(call.tool)) call.argv,
        ],
        [
          [
            '/usr/bin/hdiutil',
            'attach',
            '-nobrowse',
            '-readonly',
            '-noautoopen',
            '-mountpoint',
            mount,
            item.asset.file.path,
          ],
          ['/usr/bin/ditto', p.join(mount, _bundleName), staged],
          ['/usr/bin/hdiutil', 'detach', mount],
          ['/usr/bin/codesign', '--verify', '--deep', '--strict', staged],
          ['/usr/bin/xattr', '-p', 'com.apple.quarantine', staged],
        ],
      );
      expect(mac.leftovers(mac.applications.path), isEmpty);
    });

    test('detaches by force when the disk image is busy', () async {
      _writeBundle(mac.target);
      mac.hdiutil = (call) {
        if (call.arguments.first == 'attach') {
          final mount =
              call.arguments[call.arguments.indexOf('-mountpoint') + 1];
          _writeBundle(p.join(mount, _bundleName), version: '1.2.0');
          return processResult(0);
        }
        return processResult(call.arguments.contains('-force') ? 0 : 16);
      };
      final platform = mac.platform();
      final item = await mac.pending(platform);

      await platform.install([item], (_, _) {});

      final mount = p.join(p.dirname(item.asset.file.path), 'mnt-1');
      expect(mac.runner.callsTo('hdiutil').skip(1).map((call) => call.argv), [
        ['/usr/bin/hdiutil', 'detach', mount],
        ['/usr/bin/hdiutil', 'detach', '-force', mount],
      ]);
    });

    for (final (name, change) in <(String, void Function(_Mac mac))>[
      ('a quarantined app', (mac) => mac.xattr = (_) => processResult(0)),
      ('an invalid signature', (mac) => mac.codesign = (_) => processResult(1)),
      ('another app', (mac) => mac.dmgId = 'com.example.other'),
      ('another version', (mac) => mac.dmgVersion = '1.3.0'),
    ]) {
      test('refuses $name and leaves the app as it was', () async {
        _writeBundle(mac.target);
        change(mac);
        final platform = mac.platform();
        final item = await mac.pending(platform);

        final outcome = (await platform.install([item], (_, _) {})).single;

        expect(
          (outcome as NotInstalled).failure.kind,
          UpdateFailureKind.verification,
        );
        expect(_versionAt(mac.target), '1.1.0');
        expect(mac.leftovers(mac.applications.path), isEmpty);
      });
    }

    test('refuses a disk image whose app is a link', () async {
      _writeBundle(mac.target);
      mac.hdiutil = (call) {
        if (call.arguments.first == 'attach') {
          final mount =
              call.arguments[call.arguments.indexOf('-mountpoint') + 1];
          Link(p.join(mount, _bundleName)).createSync(mac.target);
        }
        return processResult(0);
      };
      final platform = mac.platform();
      final item = await mac.pending(platform);

      final outcome = (await platform.install([item], (_, _) {})).single;

      expect(
        (outcome as NotInstalled).failure.kind,
        UpdateFailureKind.verification,
      );
      expect(mac.runner.callsTo('ditto'), isEmpty);
    });

    test('refuses an installer that changed after the download', () async {
      _writeBundle(mac.target);
      final platform = mac.platform();
      final item = await mac.pending(platform);
      item.asset.file.writeAsStringSync('tampered');

      final outcome = (await platform.install([item], (_, _) {})).single;

      expect(
        (outcome as NotInstalled).failure.kind,
        UpdateFailureKind.verification,
      );
      expect(mac.runner.callsTo('hdiutil'), isEmpty);
    });

    test('fails as in use when the app opened again', () async {
      _writeBundle(mac.target);
      final platform = mac.platform();
      final item = await mac.pending(platform);
      mac.processes =
          '  200   501 ${p.join(mac.target, 'Contents', 'MacOS', 'Voges Word')}';

      final outcome = (await platform.install([item], (_, _) {})).single;

      expect((outcome as NotInstalled).failure.kind, UpdateFailureKind.inUse);
      expect(_versionAt(mac.target), '1.1.0');
      expect(mac.leftovers(mac.applications.path), isEmpty);
    });

    test(
      'maps EACCES on the folder to permission, before any change',
      () async {
        _writeBundle(mac.target);
        final platform = mac.platform();
        final item = await mac.pending(platform);
        Process.runSync('/bin/chmod', ['555', mac.applications.path]);

        final outcome = (await platform.install([item], (_, _) {})).single;

        final failure = (outcome as NotInstalled).failure;
        expect(failure.kind, UpdateFailureKind.permission);
        expect(failure.installer, item.asset.file.path);
        expect(mac.runner.callsTo('hdiutil'), isEmpty);
        expect(_versionAt(mac.target), '1.1.0');
      },
    );

    test('rolls back when the new bundle cannot be moved in', () async {
      _writeBundle(mac.target);
      mac.ditto = (call) {
        final result = _Mac._ditto(call);
        // the staging folder turns read-only, so its app cannot move out
        Process.runSync('/bin/chmod', ['555', p.dirname(call.arguments.last)]);
        return result;
      };
      final platform = mac.platform();
      final item = await mac.pending(platform);

      final outcome = (await platform.install([item], (_, _) {})).single;

      final failure = (outcome as NotInstalled).failure;
      expect(failure.kind, UpdateFailureKind.permission);
      expect(_versionAt(mac.target), '1.1.0');
      expect(
        mac
            .leftovers(mac.applications.path)
            .where((name) => name.endsWith('.old')),
        isEmpty,
      );
    });

    test('deletes the old bundle at once when it is not the host', () async {
      _writeBundle(mac.target);
      final platform = mac.platform();

      await platform.install([await mac.pending(platform)], (_, _) {});

      expect(mac.leftovers(mac.applications.path), isEmpty);
    });

    test('keeps the host until the end, reopens it, then deletes', () async {
      _writeBundle(mac.target);
      final platform = mac.platform(executable: p.join(mac.target, _helper));
      final host = await platform.host();
      final item = await mac.pending(platform);

      await platform.install([item], (_, _) {});

      final old = mac
          .leftovers(mac.applications.path)
          .singleWhere((name) => name.endsWith('.old'));
      final oldPath = p.join(mac.applications.path, old);
      expect(_versionAt(oldPath), '1.1.0');
      expect(_versionAt(mac.target), '1.2.0');

      var oldExistedWhenOpening = false;
      final tools = mac.runner.onRun!;
      mac.runner.onRun = (call) {
        if (call.tool == 'open') {
          oldExistedWhenOpening = Directory(oldPath).existsSync();
        }
        return tools(call);
      };
      platform.finishSync(host);

      final open = mac.runner.callsTo('open').single;
      expect(open.argv, ['/usr/bin/open', mac.target]);
      expect(open.sync, isTrue);
      expect(oldExistedWhenOpening, isTrue);
      expect(mac.leftovers(mac.applications.path), isEmpty);
      expect(mac.temp.listSync(), isEmpty);
    });
  });

  group('cleaning up', () {
    test('deletes leftovers by exact name, never links or busy ones', () async {
      final apps = mac.applications.path;
      final userApps = p.join(mac.home.path, 'Applications');
      final outside = Directory(p.join(mac.root.path, 'Outside'))..createSync();
      File(p.join(outside.path, 'keep')).createSync();
      for (final name in [
        '.voges-update-abc123',
        '.voges-update-def456.old',
        '.voges-update-x_y',
      ]) {
        Directory(p.join(apps, name, 'Contents')).createSync(recursive: true);
      }
      Directory(p.join(userApps, '.voges-update-ghi789.old')).createSync();
      Link(p.join(apps, '.voges-update-link01')).createSync(outside.path);
      File(p.join(apps, '.voges-update-file01')).createSync();
      mac.processes =
          '  300   501 $apps/.voges-update-def456.old/Contents/MacOS/Voges Word';
      final platform = mac.platform();
      final current = await platform.workDirectory();
      Directory(p.join(mac.temp.path, 'voges-update-AAAA11')).createSync();
      Directory(p.join(mac.temp.path, 'voges-updates-BBBB22')).createSync();
      Link(
        p.join(mac.temp.path, 'voges-update-link02'),
      ).createSync(outside.path);

      await platform.cleanStale(current);

      expect(mac.leftovers(apps)..sort(), [
        '.voges-update-def456.old',
        '.voges-update-file01',
        '.voges-update-link01',
        '.voges-update-x_y',
      ]);
      expect(Directory(userApps).listSync(), isEmpty);
      expect(
        [for (final entity in mac.temp.listSync()) p.basename(entity.path)]
          ..sort(),
        [
          p.basename(current.path),
          'voges-update-link02',
          'voges-updates-BBBB22',
        ],
      );
      expect(File(p.join(outside.path, 'keep')).existsSync(), isTrue);
    });

    test(
      'gives each run a private work folder',
      () async {
        final work = await mac.platform().workDirectory();

        expect(p.basename(work.path), startsWith('voges-update-'));
        expect(work.statSync().modeString(), 'rwx------');
      },
      // the mode comes from mkdtemp, which Dart uses only on macOS
      testOn: 'mac-os',
    );
  });

  group('leaving', () {
    test('copies the installer to Downloads under a free name', () async {
      final downloads = Directory(p.join(mac.home.path, 'Downloads'))
        ..createSync();
      File(p.join(downloads.path, 'VogesWord-macos.dmg')).createSync();
      final installer = verifiedFile(
        p.join(mac.temp.path, 'work', 'VogesWord-macos.dmg'),
        'disk image',
      );

      await mac.platform().openFallback(
        UpdateFailure(
          UpdateFailureKind.permission,
          installer: installer.file.path,
        ),
      );

      final copy = p.join(downloads.path, 'VogesWord-macos (2).dmg');
      expect(File(copy).readAsStringSync(), 'disk image');
      expect(mac.runner.argvs, [
        ['/usr/bin/open', copy],
      ]);
    });

    test('has no installer to open for other failures', () async {
      await mac.platform().openFallback(
        const UpdateFailure(UpdateFailureKind.network),
      );

      expect(mac.runner.calls, isEmpty);
    });

    test('never throws while finishing', () {
      mac.runner.onRun = (_) => throw const ProcessException('open', []);

      mac.platform().finishSync(
        const UpdaterHost(app: vogesWord, reopenPath: '/Applications/X.app'),
      );
    });
  });
}
