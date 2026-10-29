import 'dart:io';

import 'package:voges_updater/src/updater_lock.dart';

/// Takes the updater lock in the folder given as the only argument, as a
/// second updater would, and prints `held` (keeping it until stdin closes)
/// or `busy`.
Future<void> main(List<String> arguments) async {
  final lock = await UpdaterLock.tryAcquire(
    directory: Directory(arguments.single),
  );
  if (lock == null) {
    stdout.writeln('busy');
    return;
  }
  stdout.writeln('held');
  await stdin.drain<void>();
  await lock.release();
}
