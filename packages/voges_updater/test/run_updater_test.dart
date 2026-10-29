import 'package:flutter_test/flutter_test.dart';
import 'package:voges_updater/voges_updater.dart';

void main() {
  group('Linux', () {
    UpdaterRequest? request(
      List<String> arguments, {
      String executable = '/usr/lib/voges-word/voges_word',
      SuiteApp? host = vogesWord,
    }) => trustedUpdaterRequest(
      arguments,
      host,
      operatingSystem: 'linux',
      executable: executable,
    );

    test('runs from the installed binary', () {
      expect(request(['--voges-updater']), isNotNull);
    });

    test('refuses any other binary', () {
      expect(
        request(['--voges-updater'], executable: '/home/ana/voges_word'),
        isNull,
      );
      expect(
        request([
          '--voges-updater',
        ], executable: '/usr/lib/voges-word/voges_word (deleted)'),
        isNull,
      );
    });

    test('refuses other arguments and a missing host', () {
      expect(request(['--voges-updater', '--relaunch=/tmp/x']), isNull);
      expect(request(['--voges-updater'], host: null), isNull);
    });
  });

  group('Windows', () {
    const installed = r'C:\Program Files\Voges Word\voges_word.exe';
    const uninstaller = r'C:\Program Files\Voges Word\unins000.exe';

    UpdaterRequest? request(
      String relaunch, {
      Set<String> files = const {installed, uninstaller},
    }) => trustedUpdaterRequest(
      ['--voges-updater', '--relaunch=$relaunch'],
      vogesWord,
      operatingSystem: 'windows',
      executable:
          r'C:\Users\ana\AppData\Local\Temp\voges-updater-1\app\voges_word.exe',
      isFile: files.contains,
    );

    test('reopens the installed executable', () {
      expect(request(installed)?.relaunch, installed);
    });

    test('compares the executable name without case', () {
      const upper = r'C:\Program Files\Voges Word\VOGES_WORD.EXE';
      expect(request(upper, files: {upper, uninstaller}), isNotNull);
    });

    test('refuses another executable', () {
      const other = r'C:\Program Files\Voges Word\other.exe';
      expect(request(other, files: {other, uninstaller}), isNull);
    });

    test('refuses a copy without its uninstaller', () {
      expect(request(installed, files: {installed}), isNull);
    });

    test('refuses an executable that does not exist', () {
      expect(request(installed, files: {uninstaller}), isNull);
    });

    test('refuses a relative path', () {
      expect(request(r'Voges Word\voges_word.exe'), isNull);
    });
  });

  test('macOS takes no request', () {
    expect(
      trustedUpdaterRequest(
        const ['--voges-updater'],
        vogesWord,
        operatingSystem: 'macos',
        executable: '/Applications/Voges Word.app/Contents/MacOS/Voges Word',
      ),
      isNull,
    );
  });
}
