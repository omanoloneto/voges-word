import 'package:flutter_test/flutter_test.dart';
import 'package:voges_updater/core.dart';

const _exe = r'C:\Program Files\Voges Word\voges_word.exe';

void main() {
  group('isUpdaterLaunch', () {
    test('only on Windows and Linux, with the flag first', () {
      for (final os in ['windows', 'linux']) {
        expect(UpdaterRequest.isUpdaterLaunch(['--voges-updater'], os), isTrue);
        expect(
          UpdaterRequest.isUpdaterLaunch([
            '--voges-updater',
            '--relaunch=$_exe',
          ], os),
          isTrue,
        );
        expect(UpdaterRequest.isUpdaterLaunch(const [], os), isFalse);
        expect(UpdaterRequest.isUpdaterLaunch(['document.docx'], os), isFalse);
        expect(
          UpdaterRequest.isUpdaterLaunch([
            'document.docx',
            '--voges-updater',
          ], os),
          isFalse,
        );
      }
      for (final os in ['macos', 'android', 'ios', 'fuchsia']) {
        expect(
          UpdaterRequest.isUpdaterLaunch(['--voges-updater'], os),
          isFalse,
        );
      }
    });
  });

  group('parse on Linux', () {
    test('takes exactly the flag', () {
      final request = UpdaterRequest.parse(['--voges-updater'], 'linux');
      expect(request, isNotNull);
      expect(request!.relaunch, isNull);
    });

    test('rejects anything more or different', () {
      for (final arguments in [
        const <String>[],
        ['--voges-updater', '--relaunch=/usr/bin/voges-word'],
        ['--voges-updater', 'document.docx'],
        ['--voges-updater', '--voges-updater'],
        ['--VOGES-UPDATER'],
        ['--voges-updater='],
        [' --voges-updater'],
      ]) {
        expect(
          UpdaterRequest.parse(arguments, 'linux'),
          isNull,
          reason: '$arguments',
        );
      }
    });
  });

  group('parse on Windows', () {
    test('takes the flag and an absolute executable to reopen', () {
      for (final path in [_exe, r'D:\Apps\São Paulo\voges_word.exe']) {
        expect(
          UpdaterRequest.parse([
            '--voges-updater',
            '--relaunch=$path',
          ], 'windows')?.relaunch,
          path,
        );
      }
    });

    test('rejects anything else', () {
      for (final arguments in [
        ['--voges-updater'],
        ['--relaunch=$_exe', '--voges-updater'],
        ['--voges-updater', '--relaunch='],
        ['--voges-updater', '--relaunch=voges_word.exe'],
        ['--voges-updater', r'--relaunch=Voges Word\voges_word.exe'],
        ['--voges-updater', r'--relaunch=C:voges_word.exe'],
        ['--voges-updater', r'--relaunch=C:\Voges\..\Other\voges_word.exe'],
        ['--voges-updater', r'--relaunch=C:\Voges\.\voges_word.exe'],
        ['--voges-updater', r'--relaunch=C:/Voges/voges_word.exe'],
        ['--voges-updater', '--relaunch $_exe'],
        ['--voges-updater', '--relaunch=$_exe', 'document.docx'],
        ['--voges-updater', _exe],
      ]) {
        expect(
          UpdaterRequest.parse(arguments, 'windows'),
          isNull,
          reason: '$arguments',
        );
      }
    });
  });

  test('macOS takes no arguments: the helper finds its host itself', () {
    expect(UpdaterRequest.parse(['--voges-updater'], 'macos'), isNull);
    expect(UpdaterRequest.parse(const [], 'macos'), isNull);
  });

  test('the arguments the app sends are the ones the updater accepts', () {
    expect(UpdaterRequest.argumentsFor(), ['--voges-updater']);
    expect(
      UpdaterRequest.parse(UpdaterRequest.argumentsFor(), 'linux'),
      isNotNull,
    );
    expect(
      UpdaterRequest.parse(
        UpdaterRequest.argumentsFor(relaunch: _exe),
        'windows',
      )?.relaunch,
      _exe,
    );
  });
}
