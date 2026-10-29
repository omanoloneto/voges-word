import 'dart:io' as io;

import 'package:flutter/foundation.dart';

import 'catalog.dart';
import 'github_releases.dart';
import 'release_downloader.dart';
import 'suite_platform.dart';
import 'updater_lock.dart';

enum UpdaterStage {
  starting,
  alreadyRunning,
  checking,
  offline,
  hostNotFound,
  upToDate,
  choosing,
  downloading,
  waitingForApps,
  installing,
  finished,
}

/// The updater's state machine: check, choose, download and verify, wait for
/// the apps to close, install, reopen the host.
class UpdaterSession extends ChangeNotifier {
  UpdaterSession({
    required this.platform,
    required this.feed,
    required this.downloader,
    this.catalog = vogesSuite,
    this.pollInterval = const Duration(seconds: 1),
    Future<UpdaterLock?> Function()? acquireLock,
    void Function(int code) exit = io.exit,
  }) : _acquireLock = acquireLock ?? UpdaterLock.tryAcquire,
       _exit = exit;

  final SuitePlatform platform;
  final ReleaseFeed feed;
  final UpdateDownloader downloader;
  final List<SuiteApp> catalog;
  final Duration pollInterval;
  final Future<UpdaterLock?> Function() _acquireLock;
  final void Function(int code) _exit;

  UpdaterStage get stage => throw UnimplementedError();

  Future<void> start() => throw UnimplementedError();
}
