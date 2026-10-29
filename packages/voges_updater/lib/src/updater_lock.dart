import 'dart:io';

/// Keeps a second updater from running at the same time.
final class UpdaterLock {
  UpdaterLock._(this._file);

  final RandomAccessFile _file;

  /// The lock, or null when another updater holds it.
  static Future<UpdaterLock?> tryAcquire({Directory? directory}) {
    throw UnimplementedError();
  }

  Future<void> release() async {
    await _file.unlock();
    await _file.close();
  }
}
