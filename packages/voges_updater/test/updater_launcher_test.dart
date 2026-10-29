import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voges_updater/core.dart';
import 'package:voges_updater/src/macos_updater_launcher.dart';

import 'support/platforms_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late FakeProcessRunner runner;

  setUp(() {
    root = platformsTempRoot();
    runner = FakeProcessRunner();
  });
  tearDown(() => root.deleteSync(recursive: true));

  void createFile(String path, [String content = '']) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  group('Windows', () {
    late Directory temp;
    late String executable;

    setUp(() {
      temp = Directory(p.join(root.path, 'temp'))..createSync();
      final install = p.join(root.path, 'Program Files', 'Voges Word');
      executable = p.join(install, 'voges_word.exe');
      createFile(executable, 'exe');
      createFile(p.join(install, 'flutter_windows.dll'), 'dll');
      createFile(p.join(install, 'data', 'app.so'), 'app');
      createFile(p.join(install, 'data', 'unins-notes.txt'), 'notes');
      createFile(p.join(install, 'unins000.exe'), 'uninstaller');
      createFile(p.join(install, 'unins000.dat'), 'uninstall log');
    });

    WindowsUpdaterLauncher launcher({
      Future<void> Function(Future<void> Function() action)? withLock,
      Duration age = Duration.zero,
    }) => WindowsUpdaterLauncher(
      app: vogesWord,
      executable: executable,
      runner: runner,
      temp: temp,
      withUpdaterLock: withLock ?? (action) => action(),
      now: () => DateTime.now().add(age),
    );

    List<String> copies() => [
      for (final entity in temp.listSync()) p.basename(entity.path),
    ];

    test('offers the update only in an Inno Setup install', () {
      expect(launcher().availability, LaunchAvailability.here);

      File(p.join(p.dirname(executable), 'unins000.exe')).deleteSync();

      expect(launcher().availability, LaunchAvailability.download);
    });

    test('starts a copy of the app without the uninstaller', () async {
      final result = await launcher().launch();

      expect(result, LaunchResult.started);
      final copy = temp.listSync().single.path;
      expect(p.basename(copy), startsWith('voges-updater-'));
      final app = p.join(copy, 'app');
      expect(
        [
          for (final entity in Directory(app).listSync(recursive: true))
            if (entity is File) p.relative(entity.path, from: app),
        ]..sort(),
        [
          p.join('data', 'app.so'),
          p.join('data', 'unins-notes.txt'),
          'flutter_windows.dll',
          'voges_word.exe',
        ],
      );
      final call = runner.calls.single;
      expect(call.argv, [
        p.join(app, 'voges_word.exe'),
        '--voges-updater',
        '--relaunch=$executable',
      ]);
      expect(call.workingDirectory, copy);
      expect(call.mode, ProcessStartMode.detached);
    });

    test('deletes the copy when it cannot start', () async {
      runner.onStart = (_) => throw const ProcessException('app', []);

      expect(await launcher().launch(), LaunchResult.failed);
      expect(copies(), isEmpty);
    });

    test('does not start outside an install', () async {
      File(p.join(p.dirname(executable), 'unins000.exe')).deleteSync();

      expect(await launcher().launch(), LaunchResult.failed);
      expect(runner.calls, isEmpty);
      expect(copies(), isEmpty);
    });

    test('deletes copies older than an hour while holding the lock', () async {
      for (final name in [
        'voges-updater-abc123',
        'voges-updater-0f8fad5b-d9cb-469f-a165-70867728950e',
        'other-folder',
      ]) {
        createFile(p.join(temp.path, name, 'app', 'voges_word.exe'));
      }
      createFile(p.join(temp.path, 'voges-updater-file01'));
      var locked = false;

      await launcher(
        age: const Duration(hours: 2),
        withLock: (action) async {
          locked = true;
          await action();
          locked = false;
        },
      ).cleanUp();

      expect(copies()..sort(), ['other-folder', 'voges-updater-file01']);
      expect(locked, isFalse);
    });

    test('keeps copies younger than an hour', () async {
      createFile(p.join(temp.path, 'voges-updater-abc123', 'app', 'x'));

      await launcher().cleanUp();

      expect(copies(), ['voges-updater-abc123']);
    });

    test('keeps everything while an updater is open', () async {
      createFile(p.join(temp.path, 'voges-updater-abc123', 'app', 'x'));

      await launcher(
        age: const Duration(hours: 2),
        withLock: (_) async {},
      ).cleanUp();

      expect(copies(), ['voges-updater-abc123']);
    });

    test('never deletes through a link', () async {
      final outside = Directory(p.join(root.path, 'outside'))..createSync();
      createFile(p.join(outside.path, 'keep'));
      Link(p.join(temp.path, 'voges-updater-link01')).createSync(outside.path);

      await launcher(age: const Duration(hours: 2)).cleanUp();

      expect(copies(), ['voges-updater-link01']);
      expect(File(p.join(outside.path, 'keep')).existsSync(), isTrue);
    }, testOn: '!windows');
  });

  group('Linux', () {
    const binary = '/usr/lib/voges-word/voges_word';

    setUp(() => createFile(p.join(root.path, 'usr', 'bin', 'dpkg-query')));

    LinuxUpdaterLauncher launcher({String executable = binary}) =>
        LinuxUpdaterLauncher(
          app: vogesWord,
          executable: executable,
          runner: runner,
          root: root.path,
        );

    test('offers the update only from the Debian package', () {
      expect(launcher().availability, LaunchAvailability.here);
      expect(
        launcher(executable: '/home/ana/voges/voges_word').availability,
        LaunchAvailability.download,
      );

      File(p.join(root.path, 'usr', 'bin', 'dpkg-query')).deleteSync();

      expect(launcher().availability, LaunchAvailability.download);
    });

    test('starts the installed executable as the updater', () async {
      expect(await launcher().launch(), LaunchResult.started);

      final call = runner.calls.single;
      expect(call.argv, [binary, '--voges-updater']);
      expect(call.mode, ProcessStartMode.detached);
      expect(call.workingDirectory, isNull);
    });

    test('fails when the updater cannot start', () async {
      runner.onStart = (_) => throw const ProcessException(binary, []);

      expect(await launcher().launch(), LaunchResult.failed);
    });

    test('does not start a copy outside the package', () async {
      final result = await launcher(executable: '/tmp/voges_word').launch();

      expect(result, LaunchResult.failed);
      expect(runner.calls, isEmpty);
    });
  });

  group('macOS', () {
    const channel = MethodChannel('voges/updater');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    String bundle(String folder, {bool helper = true}) {
      final app = p.join(root.path, folder, 'Voges Word.app');
      createFile(p.join(app, 'Contents', 'MacOS', 'Voges Word'));
      if (helper) {
        Directory(
          p.join(app, 'Contents', 'Helpers', 'Voges Updater.app'),
        ).createSync(recursive: true);
      }
      return p.join(app, 'Contents', 'MacOS', 'Voges Word');
    }

    MacosUpdaterLauncher launcher(String executable) =>
        MacosUpdaterLauncher(app: vogesWord, executable: executable);

    test('is available only with the helper, outside temporary places', () {
      expect(
        launcher(bundle('Applications')).availability,
        LaunchAvailability.here,
      );
      expect(
        launcher(bundle('Build', helper: false)).availability,
        LaunchAvailability.download,
      );
      expect(
        launcher(bundle(p.join('AppTranslocation', '0A1B', 'd'))).availability,
        LaunchAvailability.moveToApplications,
      );
      expect(
        launcher(p.join(root.path, 'voges_word')).availability,
        LaunchAvailability.download,
      );
    });

    test('asks the native side to launch the helper', () async {
      final executable = bundle('Applications');
      for (final (reply, result) in [
        ('started', LaunchResult.started),
        ('failed', LaunchResult.failed),
        ('missing', LaunchResult.failed),
      ]) {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return reply;
        });

        expect(await launcher(executable).launch(), result, reason: reply);
        expect(calls.single.method, 'launch');
        expect(calls.single.arguments, isNull);
      }
    });

    test('fails when the native side errs or is absent', () async {
      final executable = bundle('Applications');
      messenger.setMockMethodCallHandler(
        channel,
        (_) => throw PlatformException(code: 'error'),
      );
      expect(await launcher(executable).launch(), LaunchResult.failed);

      messenger.setMockMethodCallHandler(channel, null);
      expect(await launcher(executable).launch(), LaunchResult.failed);
    });

    test('does not ask without the helper', () async {
      var asked = false;
      messenger.setMockMethodCallHandler(channel, (_) async {
        asked = true;
        return 'started';
      });

      final result = await launcher(bundle('Build', helper: false)).launch();

      expect(result, LaunchResult.failed);
      expect(asked, isFalse);
    });
  }, skip: Platform.isWindows);
}
