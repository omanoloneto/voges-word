import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voges_updater/core.dart';

import 'support/core_support.dart';

/// A second process with its own lock attempt: POSIX record locks belong to
/// the process, so locking twice in this one would always succeed.
final class _Holder {
  _Holder._(this._process, this._lines);

  static Future<_Holder> start(Directory folder) async {
    final process = await Process.start(dartExecutable(), [
      'run',
      'test/fixtures/core_lock_holder.dart',
      folder.path,
    ]);
    unawaited(process.stderr.drain<void>());
    return _Holder._(
      process,
      StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
    );
  }

  final Process _process;
  final StreamIterator<String> _lines;

  Future<String?> get answer async =>
      await _lines.moveNext() ? _lines.current : null;

  /// Lets a holder release the lock and end; a busy one has ended already.
  Future<int> stop() async {
    await _process.stdin.close();
    return _process.exitCode;
  }

  Future<int> get exitCode => _process.exitCode;

  Future<int> kill() async {
    _process.kill(ProcessSignal.sigkill);
    return _process.exitCode;
  }
}

const _slow = Timeout(Duration(minutes: 2));

void main() {
  late Directory folder;

  setUp(() => folder = temporaryFolder());

  test('another updater holding the lock keeps this one out', () async {
    final holder = await _Holder.start(folder);
    expect(await holder.answer, 'held');
    expect(await UpdaterLock.tryAcquire(directory: folder), isNull);
    expect(await holder.stop(), 0);

    final lock = await UpdaterLock.tryAcquire(directory: folder);
    expect(lock, isNotNull);
    await lock!.release();
  }, timeout: _slow);

  test('this updater holding the lock keeps another out', () async {
    final lock = await UpdaterLock.tryAcquire(directory: folder);
    expect(lock, isNotNull);
    final blocked = await _Holder.start(folder);
    expect(await blocked.answer, 'busy');
    expect(await blocked.exitCode, 0);

    await lock!.release();
    final next = await _Holder.start(folder);
    expect(await next.answer, 'held');
    expect(await next.stop(), 0);
  }, timeout: _slow);

  test('a crashed updater does not leave the lock behind', () async {
    final holder = await _Holder.start(folder);
    expect(await holder.answer, 'held');
    await holder.kill();

    final lock = await UpdaterLock.tryAcquire(directory: folder);
    expect(lock, isNotNull);
    await lock!.release();
  }, timeout: _slow);

  test('creates its folder', () async {
    final nested = Directory(p.join(folder.path, 'a', 'b'));
    final lock = await UpdaterLock.tryAcquire(directory: nested);
    expect(lock, isNotNull);
    expect(File(p.join(nested.path, 'updater.lock')).existsSync(), isTrue);
    await lock!.release();
  });

  group('default folder', () {
    String folderOf(String os, Map<String, String> environment) =>
        UpdaterLock.defaultDirectory(os, environment).path;

    test('macOS: the Voges folder in the user caches', () {
      expect(
        folderOf('macos', {'HOME': '/Users/ana'}),
        '/Users/ana/Library/Caches/Voges',
      );
    });

    test('Windows: the Voges folder in the local app data', () {
      expect(
        folderOf('windows', {'LOCALAPPDATA': r'C:\Users\Ana\AppData\Local'}),
        r'C:\Users\Ana\AppData\Local\Voges',
      );
    });

    test('Linux: XDG_CACHE_HOME, or ~/.cache when unset or invalid', () {
      expect(
        folderOf('linux', {'HOME': '/home/ana', 'XDG_CACHE_HOME': '/cache'}),
        '/cache/voges',
      );
      for (final cache in [null, '', 'relative/cache']) {
        expect(
          folderOf('linux', {'HOME': '/home/ana', 'XDG_CACHE_HOME': ?cache}),
          '/home/ana/.cache/voges',
          reason: '$cache',
        );
      }
    });

    test('needs the variables of the system', () {
      expect(() => folderOf('macos', const {}), throwsStateError);
      expect(() => folderOf('windows', {'HOME': '/x'}), throwsStateError);
      expect(() => folderOf('linux', {'HOME': ''}), throwsStateError);
      expect(() => folderOf('android', {'HOME': '/x'}), throwsUnsupportedError);
    });
  });
}
