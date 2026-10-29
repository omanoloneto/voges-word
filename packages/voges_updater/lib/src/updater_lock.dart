import 'dart:io';

import 'package:path/path.dart' as p;

/// Keeps a second updater from running at the same time.
final class UpdaterLock {
  UpdaterLock._(this._file);

  final RandomAccessFile _file;

  /// The lock, or null when another updater holds it.
  static Future<UpdaterLock?> tryAcquire({Directory? directory}) async {
    final folder =
        directory ??
        defaultDirectory(Platform.operatingSystem, Platform.environment);
    await folder.create(recursive: true);
    final file = await File(
      p.join(folder.path, 'updater.lock'),
    ).open(mode: FileMode.append);
    try {
      // FileLock.exclusive fails at once instead of waiting for the holder
      await file.lock(FileLock.exclusive);
    } on FileSystemException {
      await file.close();
      return null;
    }
    return UpdaterLock._(file);
  }

  /// The folder of the lock for this user: the Voges cache folder of
  /// [operatingSystem].
  static Directory defaultDirectory(
    String operatingSystem,
    Map<String, String> environment,
  ) {
    String required(String name) {
      final value = environment[name];
      if (value == null || value.isEmpty) throw StateError('$name is not set');
      return value;
    }

    switch (operatingSystem) {
      case 'macos':
        return Directory(
          p.posix.join(required('HOME'), 'Library', 'Caches', 'Voges'),
        );
      case 'windows':
        return Directory(p.windows.join(required('LOCALAPPDATA'), 'Voges'));
      case 'linux':
        // the XDG spec says to ignore a relative XDG_CACHE_HOME
        final cache = environment['XDG_CACHE_HOME'];
        return Directory(
          p.posix.join(
            cache != null && p.posix.isAbsolute(cache)
                ? cache
                : p.posix.join(required('HOME'), '.cache'),
            'voges',
          ),
        );
      default:
        throw UnsupportedError('No updater for $operatingSystem');
    }
  }

  Future<void> release() async {
    await _file.unlock();
    await _file.close();
  }
}
