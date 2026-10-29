import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'catalog.dart';
import 'github_releases.dart';
import 'release_downloader.dart';
import 'release_version.dart';
import 'suite_platform.dart';
import 'update_failure.dart';
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

enum UpdateRowPhase {
  /// Nothing done yet, or waiting for its turn to download.
  idle,
  downloading,

  /// The download ended and its checksum is being compared.
  verifying,

  /// Downloaded and verified, ready to install.
  downloaded,
  installing,
  updated,
  failed,
}

/// The manual ways out of a failed row, besides trying again.
enum RowAction { openInstaller, showLog, downloadPage, copyCommand }

/// An installed copy of a suite app in the updater's list.
final class UpdateRow {
  UpdateRow._(this.copy, this.latest) : _selected = latest != null;

  final InstalledCopy copy;

  /// The newest version; null when the check of this app failed.
  final ReleaseVersion? latest;

  bool _selected;
  var _phase = UpdateRowPhase.idle;
  double? _progress;
  InstallStep? _step;
  UpdateFailure? _failure;
  ReleaseVersion? _installed;
  VerifiedAsset? _asset;

  SuiteApp get app => copy.app;
  bool get checkFailed => latest == null;
  bool get selectable => latest != null && _phase != UpdateRowPhase.updated;
  bool get selected => _selected;
  UpdateRowPhase get phase => _phase;

  /// Download progress from 0 to 1; null before the download reports any.
  double? get progress => _progress;
  InstallStep? get step => _step;
  UpdateFailure? get failure => _failure;

  /// The version read back from the system after installing.
  ReleaseVersion? get installedVersion => _installed;

  void _fail(UpdateFailure failure) {
    _phase = UpdateRowPhase.failed;
    _failure = failure;
    _progress = null;
    _step = null;
    // the file on disk no longer matches what was verified
    if (failure.kind == UpdateFailureKind.verification) _asset = null;
  }

  void _reset() {
    _phase = _asset == null ? UpdateRowPhase.idle : UpdateRowPhase.downloaded;
    _failure = null;
    _progress = null;
    _step = null;
  }
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
    SuiteApp? hostApp,
    String? operatingSystem,
    Future<Object?> Function()? acquireLock,
    Future<bool> Function(Uri url)? openUrl,
    void Function(int code) exit = io.exit,
  }) : _hostApp = hostApp,
       _linux = (operatingSystem ?? io.Platform.operatingSystem) == 'linux',
       _acquireLock = acquireLock ?? UpdaterLock.tryAcquire,
       _openUrl = openUrl ?? launchUrl,
       _exit = exit;

  final SuitePlatform platform;
  final ReleaseFeed feed;
  final UpdateDownloader downloader;
  final List<SuiteApp> catalog;
  final Duration pollInterval;

  /// The app compiled into this process (Windows and Linux), named before
  /// the host is found.
  final SuiteApp? _hostApp;

  /// Linux installs every app in one batch behind one password window, so
  /// dismissing it changes nothing and the list comes back.
  final bool _linux;

  /// Returns what holds the lock until the process exits, or null when
  /// another updater holds it.
  final Future<Object?> Function() _acquireLock;
  final Future<bool> Function(Uri url) _openUrl;
  final void Function(int code) _exit;

  var _stage = UpdaterStage.starting;
  var _rows = const <UpdateRow>[];
  var _blockers = const <RunningApp>[];

  /// Kept for the life of the process, whose exit releases the lock.
  Object? _lock;
  UpdaterHost? _host;
  io.Directory? _work;

  /// Changes on every update and cancel, so stale work stops quietly.
  var _run = 0;
  Future<void> _downloads = Future.value();

  UpdaterStage get stage => _stage;
  List<UpdateRow> get rows => _rows;

  /// Open instances that must close before installing.
  List<RunningApp> get blockers => _blockers;

  bool get canClose => _stage != UpdaterStage.installing;

  /// The app that opened the updater.
  SuiteApp get hostApp => _host?.app ?? _hostApp ?? catalog.first;

  /// Whether leaving opens [hostApp] again.
  bool get reopensHost =>
      _host != null && _stage != UpdaterStage.alreadyRunning;

  int get selectedCount =>
      _rows.where((row) => row.selectable && row._selected).length;

  /// The "select all" box: true when every update is selected, false when
  /// none is, null when some are.
  bool? get allSelected {
    final selectable = _rows.where((row) => row.selectable);
    if (selectable.every((row) => row._selected)) return true;
    if (selectable.every((row) => !row._selected)) return false;
    return null;
  }

  Future<void> start() async {
    if (_stage != UpdaterStage.starting) return;
    try {
      _lock = await _acquireLock();
    } catch (_) {
      _lock = null;
    }
    if (_lock == null) {
      _enter(UpdaterStage.alreadyRunning);
      return;
    }
    _enter(UpdaterStage.checking);
    try {
      _host = await platform.host();
    } catch (_) {
      _host = null;
    }
    if (_host == null) {
      _enter(UpdaterStage.hostNotFound);
      return;
    }
    try {
      final work = await platform.workDirectory();
      _work = work;
      await platform.cleanStale(work);
    } catch (_) {
      // leftovers wait for the next run; update() asks for the folder again
    }
    await _check();
  }

  Future<void> _check() async {
    _enter(UpdaterStage.checking);
    final host = _host!;
    final List<InstalledCopy> copies;
    try {
      copies = await platform.installed(catalog, host);
    } catch (_) {
      _enter(UpdaterStage.hostNotFound);
      return;
    }
    if (!copies.any((copy) => copy.app.repository == host.app.repository)) {
      _enter(UpdaterStage.hostNotFound);
      return;
    }

    final apps = {for (final copy in copies) copy.app.repository: copy.app};
    final latest = <String, ReleaseVersion?>{};
    await Future.wait([
      for (final app in apps.values)
        _latest(app).then((version) => latest[app.repository] = version),
    ]);

    final rows = <UpdateRow>[];
    for (final copy in copies) {
      final version = latest[copy.app.repository];
      if (version == null || version.isNewerThan(copy.version)) {
        rows.add(UpdateRow._(copy, version));
      }
    }
    _rows = List.unmodifiable(rows);
    if (_rows.any((row) => row.selectable)) {
      _enter(UpdaterStage.choosing);
    } else if (latest.values.contains(null)) {
      _enter(UpdaterStage.offline);
    } else {
      _enter(UpdaterStage.upToDate);
    }
  }

  Future<ReleaseVersion?> _latest(SuiteApp app) async {
    try {
      return await feed.latest(app.repository);
    } catch (_) {
      return null;
    }
  }

  void select(UpdateRow row, bool on) {
    if (_stage != UpdaterStage.choosing || !row.selectable) return;
    row._selected = on;
    notifyListeners();
  }

  void selectAll(bool on) {
    if (_stage != UpdaterStage.choosing) return;
    for (final row in _rows) {
      if (row.selectable) row._selected = on;
    }
    notifyListeners();
  }

  /// Downloads and verifies the selected updates, waits for their apps to
  /// close and installs them.
  Future<void> update() async {
    if (_stage != UpdaterStage.choosing) return;
    final rows = [
      for (final row in _rows)
        if (row.selectable && row._selected) row,
    ];
    if (rows.isEmpty) return;
    final run = ++_run;
    for (final row in rows) {
      row._reset();
    }
    _enter(UpdaterStage.downloading);

    // a cancelled download may still be writing to the same folder
    await _downloads;
    if (run != _run) return;
    final downloads = _download(rows, run);
    _downloads = downloads;
    await downloads;
    if (run != _run) return;

    final ready = [
      for (final row in rows)
        if (row._phase == UpdateRowPhase.downloaded) row,
    ];
    if (ready.isNotEmpty) {
      if (!await _waitForApps(ready, run)) return;
      await _install(ready);
    }
    await _finish(rows);
  }

  /// Copies of the same app share one download.
  Future<void> _download(List<UpdateRow> rows, int run) async {
    final apps = <String, List<UpdateRow>>{};
    for (final row in rows) {
      (apps[row.app.repository] ??= []).add(row);
    }
    for (final group in apps.values) {
      if (run != _run) return;
      final verified = group.map((row) => row._asset).nonNulls.firstOrNull;
      if (verified != null) {
        for (final row in group) {
          row._asset = verified;
          row._phase = UpdateRowPhase.downloaded;
        }
        notifyListeners();
        continue;
      }

      for (final row in group) {
        row._phase = UpdateRowPhase.downloading;
      }
      notifyListeners();
      final first = group.first;
      try {
        final work = _work ??= await platform.workDirectory();
        final asset = await downloader.fetch(
          first.app,
          first.latest!,
          platform.assetOf(first.app),
          work,
          onProgress: (progress) => _onProgress(group, progress, run),
          isCancelled: () => run != _run,
        );
        // kept even when cancelled meanwhile: it is verified
        for (final row in group) {
          row._asset = asset;
          if (run == _run) row._phase = UpdateRowPhase.downloaded;
        }
      } catch (error) {
        if (run != _run) return;
        for (final row in group) {
          row._fail(_failureOf(error));
        }
      }
      if (run == _run) notifyListeners();
    }
  }

  void _onProgress(List<UpdateRow> rows, double progress, int run) {
    if (run != _run) return;
    final value = clampDouble(progress, 0, 1);
    for (final row in rows) {
      row._progress = value;
      row._phase = value < 1
          ? UpdateRowPhase.downloading
          : UpdateRowPhase.verifying;
    }
    notifyListeners();
  }

  /// Polls until no instance of [rows] is open; false when cancelled.
  Future<bool> _waitForApps(List<UpdateRow> rows, int run) async {
    final copies = [for (final row in rows) row.copy];
    while (true) {
      List<RunningApp> running;
      try {
        running = await platform.running(copies);
      } catch (_) {
        // the installers check again before replacing anything
        running = const [];
      }
      if (run != _run) return false;
      if (running.isEmpty) break;
      _blockers = List.unmodifiable(running);
      _enter(UpdaterStage.waitingForApps);
      await Future<void>.delayed(pollInterval);
      if (run != _run) return false;
    }
    _blockers = const [];
    return true;
  }

  Future<void> _install(List<UpdateRow> rows) async {
    final items = {
      for (final row in rows)
        PendingInstall(
          copy: row.copy,
          version: row.latest!,
          asset: row._asset!,
        ): row,
    };
    for (final row in rows) {
      row._phase = UpdateRowPhase.installing;
    }
    _enter(UpdaterStage.installing);

    List<InstallOutcome> outcomes;
    try {
      outcomes = await platform.install(items.keys.toList(), (item, step) {
        items[item]?._step = step;
        notifyListeners();
      });
    } catch (error) {
      outcomes = [
        for (final item in items.keys) NotInstalled(item, _failureOf(error)),
      ];
    }
    for (final outcome in outcomes) {
      final row = items[outcome.item];
      if (row == null) continue;
      switch (outcome) {
        case Installed(:final version):
          row._phase = UpdateRowPhase.updated;
          row._installed = version;
          row._selected = false;
          row._step = null;
        case NotInstalled(:final failure):
          row._fail(failure);
      }
    }
    for (final row in rows) {
      if (row._phase == UpdateRowPhase.installing) {
        row._fail(const UpdateFailure(UpdateFailureKind.failed));
      }
    }
  }

  Future<void> _finish(List<UpdateRow> rows) async {
    final failures = [for (final row in rows) ?row._failure];
    final declined =
        failures.length == rows.length &&
        failures.every((f) => f.kind == UpdateFailureKind.declined);
    if (_linux && declined) {
      for (final row in rows) {
        row._reset();
      }
      _enter(UpdaterStage.choosing);
      return;
    }
    _enter(UpdaterStage.finished);
    if (!_rows.any((row) => row._phase == UpdateRowPhase.failed)) {
      await _finishAndExit();
    }
  }

  /// Stops the download or the wait and goes back to the list, keeping the
  /// verified downloads.
  void cancel() {
    if (_stage != UpdaterStage.downloading &&
        _stage != UpdaterStage.waitingForApps) {
      return;
    }
    _run++;
    _blockers = const [];
    for (final row in _rows) {
      if (row._phase != UpdateRowPhase.updated) row._reset();
    }
    _enter(UpdaterStage.choosing);
  }

  /// Checks again after [UpdaterStage.offline]; updates the failed rows
  /// again after [UpdaterStage.finished].
  Future<void> retry() async {
    switch (_stage) {
      case UpdaterStage.offline:
        await _check();
      case UpdaterStage.finished:
        for (final row in _rows) {
          final failed = row._phase == UpdateRowPhase.failed;
          if (failed) row._reset();
          row._selected = failed;
        }
        _enter(UpdaterStage.choosing);
        await update();
      default:
        return;
    }
  }

  /// Closes the updater and opens the host again, except when another
  /// updater is running.
  Future<void> leave() async {
    if (!canClose) return;
    if (_stage == UpdaterStage.alreadyRunning) {
      _exit(0);
      return;
    }
    await _finishAndExit();
  }

  // On macOS the old bundle that holds this process may be deleted here, so
  // only one event-loop turn runs before the exit: Dart starts the detached
  // reopen of Windows and Linux on the next turn, and without it the app
  // would never open again.
  Future<void> _finishAndExit() async {
    try {
      platform.finishSync(_host);
    } catch (_) {
      // the process ends anyway
    }
    await Future<void>.delayed(Duration.zero);
    _exit(0);
  }

  /// What the user can do about a failed row, besides trying again. A failed
  /// verification never offers the download page: the website links the
  /// same release.
  List<RowAction> actionsOf(UpdateRow row) {
    final failure = row._failure;
    if (failure == null) return const [];
    return switch (failure.kind) {
      UpdateFailureKind.permission => [
        if (failure.installer != null)
          RowAction.openInstaller
        else
          RowAction.downloadPage,
      ],
      UpdateFailureKind.noPasswordWindow ||
      UpdateFailureKind.notAuthorized ||
      UpdateFailureKind.packageManager ||
      UpdateFailureKind.failed => [
        if (failure.command != null) RowAction.copyCommand,
        if (failure.logPath != null) RowAction.showLog,
        RowAction.downloadPage,
      ],
      UpdateFailureKind.network ||
      UpdateFailureKind.verification ||
      UpdateFailureKind.unavailable ||
      UpdateFailureKind.inUse ||
      UpdateFailureKind.declined => const [],
    };
  }

  Future<void> perform(UpdateRow row, RowAction action) async {
    final failure = row._failure;
    if (failure == null || !actionsOf(row).contains(action)) return;
    try {
      switch (action) {
        case RowAction.openInstaller:
          await platform.openFallback(failure);
        case RowAction.showLog:
          await _openUrl(Uri.file(failure.logPath!));
        case RowAction.downloadPage:
          await _openUrl(Uri.parse(row.app.downloadPage));
        case RowAction.copyCommand:
          await Clipboard.setData(ClipboardData(text: failure.command!));
      }
    } catch (_) {
      // nothing else to offer: the row keeps its other ways out
    }
  }

  Future<void> openReleaseNotes(UpdateRow row) async {
    final version = row.latest;
    if (version == null) return;
    await _open(releasePage(row.app.repository, version));
  }

  Future<void> openDownloadPage() => _open(Uri.parse(hostApp.downloadPage));

  Future<void> _open(Uri url) async {
    try {
      await _openUrl(url);
    } catch (_) {
      // no browser configured: nothing else to try
    }
  }

  void _enter(UpdaterStage stage) {
    _stage = stage;
    notifyListeners();
  }

  static UpdateFailure _failureOf(Object error) => error is UpdateFailure
      ? error
      : UpdateFailure(UpdateFailureKind.failed, detail: '$error');
}
