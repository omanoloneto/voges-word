import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_updater/voges_updater.dart';

import 'support/ui_fakes.dart';

void sessionTest(String description, void Function(FakeAsync async) body) =>
    test(description, () => fakeAsync(body));

UiHarness twoApps({
  String operatingSystem = 'macos',
  bool manualDownloads = false,
}) => UiHarness(
  copies: [
    installedCopy(vogesWord, '1.1.0'),
    installedCopy(vogesSheets, '1.0.0'),
  ],
  latest: {vogesWord: '1.2.0', vogesSheets: '1.0.1'},
  operatingSystem: operatingSystem,
  manualDownloads: manualDownloads,
);

/// Installs [app] and fails every other app with [failure].
InstallHandler failOthers(SuiteApp app, UpdateFailure failure) =>
    (items, onStep) async => [
      for (final item in items)
        item.copy.app == app
            ? Installed(item, item.version)
            : NotInstalled(item, failure),
    ];

InstallHandler failAll(UpdateFailure failure) =>
    (items, onStep) async => [
      for (final item in items) NotInstalled(item, failure),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('start', () {
    sessionTest('selects every update and counts the selection', (async) {
      final h = twoApps();
      h.session.start();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.choosing);
      expect(h.session.selectedCount, 2);
      expect(h.session.allSelected, isTrue);

      h.session.select(h.row(vogesSheets), false);
      expect(h.session.selectedCount, 1);
      expect(h.session.allSelected, isNull);

      h.session.selectAll(false);
      expect(h.session.selectedCount, 0);
      expect(h.session.allSelected, isFalse);

      h.session.selectAll(true);
      expect(h.session.selectedCount, 2);
    });

    sessionTest('cleans earlier runs while holding the lock', (async) {
      final h = UiHarness();
      h.session.start();
      async.flushMicrotasks();

      expect(h.platform.cleaned, [h.platform.work]);
    });

    sessionTest('checks each app once, even with a copy in each scope', (
      async,
    ) {
      final h = UiHarness(
        copies: [
          installedCopy(vogesWord, '1.1.0'),
          installedCopy(vogesWord, '1.1.0', scope: InstallScope.allUsers),
        ],
      );
      h.session.start();
      async.flushMicrotasks();

      expect(h.feed.checks, [vogesWord.repository]);
      expect(h.session.rows, hasLength(2));

      h.session.update();
      async.flushMicrotasks();

      expect(h.downloader.calls, hasLength(1));
      final items = h.platform.installs.single;
      expect(items, hasLength(2));
      expect(items.first.asset, same(items.last.asset));
    });

    sessionTest('lists a failed check without a checkbox', (async) {
      final h = UiHarness(
        copies: [
          installedCopy(vogesWord, '1.1.0'),
          installedCopy(vogesSheets, '1.0.0'),
        ],
      );
      h.session.start();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.choosing);
      final failed = h.row(vogesSheets);
      expect(failed.checkFailed, isTrue);
      expect(failed.selectable, isFalse);
      expect(failed.selected, isFalse);

      h.session.select(failed, true);
      expect(h.session.selectedCount, 1);
    });

    sessionTest('leaves up-to-date copies out of the list', (async) {
      final h = UiHarness(
        copies: [
          installedCopy(vogesWord, '1.1.0'),
          installedCopy(vogesSheets, '1.0.1'),
        ],
        latest: {vogesWord: '1.2.0', vogesSheets: '1.0.1'},
      );
      h.session.start();
      async.flushMicrotasks();

      expect(h.session.rows.map((row) => row.app), [vogesWord]);
    });

    sessionTest('is up to date when no app has a newer version', (async) {
      final h = UiHarness(latest: {vogesWord: '1.1.0'});
      h.session.start();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.upToDate);
      expect(h.session.rows, isEmpty);
    });

    sessionTest('is offline when every check fails, and checks again', (async) {
      final h = UiHarness(latest: const {});
      h.session.start();
      async.flushMicrotasks();
      expect(h.session.stage, UpdaterStage.offline);

      h.feed.versions[vogesWord.repository] = version('1.2.0');
      h.session.retry();
      async.flushMicrotasks();

      expect(h.feed.checks, hasLength(2));
      expect(h.session.stage, UpdaterStage.choosing);
    });

    sessionTest('a held lock means another updater runs; leaving reopens '
        'nothing', (async) {
      final h = UiHarness(locked: true);
      h.session.start();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.alreadyRunning);
      expect(h.platform.hostChecks, 0);
      expect(h.platform.cleaned, isEmpty);
      expect(h.session.reopensHost, isFalse);

      h.session.leave();
      async.elapse(Duration.zero);
      expect(h.exits, [0]);
      expect(h.platform.finished, isEmpty);
    });

    sessionTest('a lock that fails updates nothing but reopens the host', (
      async,
    ) {
      final h = UiHarness(lockFails: true);
      h.session.start();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.startFailed);
      expect(h.session.reopensHost, isTrue);
      expect(h.platform.cleaned, isEmpty);
      expect(h.feed.checks, isEmpty);

      h.session.leave();
      async.elapse(Duration.zero);
      expect(h.platform.finished, [wordHost]);
      expect(h.exits, [0]);
    });

    sessionTest('the host is not found when the system has none', (async) {
      final h = UiHarness()..platform.hostResult = null;
      h.session.start();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.hostNotFound);
      expect(h.session.hostApp, vogesWord);
      expect(h.session.reopensHost, isFalse);

      h.session.leave();
      expect(h.platform.finished, [null]);
      async.elapse(Duration.zero);
      expect(h.exits, [0]);
    });

    sessionTest('the host is not found when it is not installed', (async) {
      final h = UiHarness(
        copies: [installedCopy(vogesSheets, '1.0.0')],
        latest: {vogesSheets: '1.0.1'},
      );
      h.session.start();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.hostNotFound);
      expect(h.feed.checks, isEmpty);

      h.session.openDownloadPage();
      async.flushMicrotasks();
      expect(h.opened, [Uri.parse(vogesWord.downloadPage)]);
    });

    sessionTest('the host is not found when the installed apps can\'t be '
        'listed', (async) {
      final h = UiHarness()..platform.installedError = Exception('reg.exe');
      h.session.start();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.hostNotFound);
    });
  });

  group('update', () {
    sessionTest('installs, then reopens the host and exits', (async) {
      final h = UiHarness();
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();

      final item = h.platform.installs.single.single;
      expect(item.copy.app, vogesWord);
      expect(item.version, version('1.2.0'));
      expect(item.asset, same(h.downloader.calls.single.asset));
      expect(h.row(vogesWord).phase, UpdateRowPhase.updated);
      expect(h.row(vogesWord).installedVersion, version('1.2.0'));
      expect(h.platform.finished, [wordHost]);
      async.elapse(Duration.zero);
      expect(h.exits, [0]);
    });

    sessionTest('installs only the selected apps', (async) {
      final h = twoApps();
      h.session.start();
      async.flushMicrotasks();
      h.session.select(h.row(vogesWord), false);
      h.session.update();
      async.flushMicrotasks();

      expect(h.downloader.calls.map((call) => call.app), [vogesSheets]);
      expect(h.platform.installs.single.map((item) => item.copy.app), [
        vogesSheets,
      ]);
      async.elapse(Duration.zero);
      expect(h.exits, [0]);
    });

    sessionTest('does nothing with no update selected', (async) {
      final h = UiHarness();
      h.session.start();
      async.flushMicrotasks();
      h.session.selectAll(false);
      h.session.update();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.choosing);
      expect(h.downloader.calls, isEmpty);
    });

    sessionTest('shows the download progress, then the verification', (async) {
      final h = UiHarness(manualDownloads: true);
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.downloading);
      final row = h.row(vogesWord);
      expect(row.phase, UpdateRowPhase.downloading);
      expect(row.progress, isNull);

      final call = h.downloader.calls.single;
      call.onProgress!(0.25);
      expect(row.progress, 0.25);
      call.onProgress!(1);
      expect(row.phase, UpdateRowPhase.verifying);

      call.succeed();
      async.flushMicrotasks();
      expect(h.platform.installs, hasLength(1));
    });

    sessionTest('cancel while downloading goes back to the list', (async) {
      final h = UiHarness(manualDownloads: true);
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();

      h.session.cancel();
      expect(h.session.stage, UpdaterStage.choosing);
      final call = h.downloader.calls.single;
      expect(call.isCancelled!(), isTrue);

      call.fail(const UpdateFailure(UpdateFailureKind.network));
      async.flushMicrotasks();
      expect(h.session.stage, UpdaterStage.choosing);
      expect(h.row(vogesWord).failure, isNull);
      expect(h.row(vogesWord).phase, UpdateRowPhase.idle);
      expect(h.platform.installs, isEmpty);
      expect(h.exits, isEmpty);

      h.session.update();
      async.flushMicrotasks();
      expect(h.downloader.calls, hasLength(2));
    });

    sessionTest('keeps the verified downloads after cancel', (async) {
      final h = twoApps(manualDownloads: true);
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();

      final word = h.downloader.calls.single;
      word.succeed();
      async.flushMicrotasks();
      expect(h.downloader.calls.last.app, vogesSheets);

      h.session.cancel();
      h.downloader.calls.last.fail(Exception('cancelled'));
      async.flushMicrotasks();
      expect(h.row(vogesWord).phase, UpdateRowPhase.downloaded);
      expect(h.row(vogesSheets).phase, UpdateRowPhase.idle);

      h.session.update();
      async.flushMicrotasks();
      expect(h.downloader.calls.map((call) => call.app), [
        vogesWord,
        vogesSheets,
        vogesSheets,
      ]);

      h.downloader.calls.last.succeed();
      async.flushMicrotasks();
      final items = h.platform.installs.single;
      expect(
        items.singleWhere((item) => item.copy.app == vogesWord).asset,
        same(word.asset),
      );
      async.elapse(Duration.zero);
      expect(h.exits, [0]);
    });

    sessionTest('waits for the open apps and continues by itself', (async) {
      final h = UiHarness()
        ..platform.runningAnswers = [
          [const RunningApp(app: vogesWord, pid: 41)],
          [
            const RunningApp(app: vogesWord, pid: 41),
            const RunningApp(app: vogesWord, pid: 42, otherAccount: true),
          ],
          const [],
        ];
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.waitingForApps);
      expect(h.session.blockers, hasLength(1));
      expect(h.platform.runningChecks, 1);

      async.elapse(const Duration(milliseconds: 999));
      expect(h.platform.runningChecks, 1);
      async.elapse(const Duration(milliseconds: 1));
      expect(h.platform.runningChecks, 2);
      expect(h.session.blockers, hasLength(2));
      expect(h.platform.installs, isEmpty);

      async.elapse(const Duration(seconds: 1));
      expect(h.platform.runningChecks, 3);
      expect(h.session.blockers, isEmpty);
      expect(h.platform.installs, hasLength(1));
      async.elapse(Duration.zero);
      expect(h.exits, [0]);
    });

    sessionTest('cancel while waiting stops polling and keeps the download', (
      async,
    ) {
      final h = UiHarness()
        ..platform.runningAnswers = [
          [const RunningApp(app: vogesWord, pid: 41)],
        ];
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();
      expect(h.session.stage, UpdaterStage.waitingForApps);

      h.session.cancel();
      expect(h.session.stage, UpdaterStage.choosing);
      expect(h.session.blockers, isEmpty);
      async.elapse(const Duration(seconds: 5));
      expect(h.platform.runningChecks, 1);
      expect(h.row(vogesWord).phase, UpdateRowPhase.downloaded);

      h.platform.runningAnswers = [const []];
      h.session.update();
      async.flushMicrotasks();
      expect(h.downloader.calls, hasLength(1));
      expect(h.platform.installs, hasLength(1));
    });

    sessionTest('can\'t close while installing', (async) {
      final h = UiHarness();
      final install = Completer<List<InstallOutcome>>();
      h.platform.onInstall = (items, onStep) => install.future;
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.installing);
      expect(h.session.canClose, isFalse);
      h.session.leave();
      expect(h.exits, isEmpty);

      final item = h.platform.installs.single.single;
      install.complete([Installed(item, item.version)]);
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      expect(h.exits, [0]);
    });

    sessionTest('shows each result after a partial failure and tries the '
        'failed app again', (async) {
      final h = twoApps();
      h.platform.onInstall = failOthers(
        vogesWord,
        const UpdateFailure(UpdateFailureKind.inUse),
      );
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.finished);
      expect(h.exits, isEmpty);
      expect(h.row(vogesWord).phase, UpdateRowPhase.updated);
      final sheets = h.row(vogesSheets);
      expect(sheets.phase, UpdateRowPhase.failed);
      expect(sheets.failure?.kind, UpdateFailureKind.inUse);

      h.platform.onInstall = null;
      h.session.retry();
      async.flushMicrotasks();

      expect(h.platform.installs.last.map((item) => item.copy.app), [
        vogesSheets,
      ]);
      expect(h.downloader.calls, hasLength(2));
      expect(h.platform.finished, [wordHost]);
      async.elapse(Duration.zero);
      expect(h.exits, [0]);
    });

    sessionTest('a failed download doesn\'t stop the other apps', (async) {
      final h = twoApps();
      h.downloader.errors[vogesSheets.repository] = const UpdateFailure(
        UpdateFailureKind.network,
      );
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();

      expect(h.platform.installs.single.map((item) => item.copy.app), [
        vogesWord,
      ]);
      expect(h.session.stage, UpdaterStage.finished);
      expect(h.row(vogesSheets).failure?.kind, UpdateFailureKind.network);
      expect(h.exits, isEmpty);
    });

    sessionTest('an install that throws fails its apps', (async) {
      final h = UiHarness();
      h.platform.onInstall = (items, onStep) async => throw Exception('boom');
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.finished);
      expect(h.row(vogesWord).failure?.kind, UpdateFailureKind.failed);
    });

    sessionTest('Linux goes back to the list when the password window is '
        'dismissed', (async) {
      final h = UiHarness(operatingSystem: 'linux');
      h.platform.onInstall = failAll(
        const UpdateFailure(UpdateFailureKind.declined, code: 126),
      );
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.choosing);
      expect(h.row(vogesWord).failure, isNull);
      expect(h.row(vogesWord).phase, UpdateRowPhase.downloaded);
      expect(h.exits, isEmpty);

      h.platform.onInstall = null;
      h.session.update();
      async.flushMicrotasks();
      expect(h.downloader.calls, hasLength(1));
      async.elapse(Duration.zero);
      expect(h.exits, [0]);
    });

    sessionTest('Windows shows a dismissed administrator prompt as a failure', (
      async,
    ) {
      final h = UiHarness(operatingSystem: 'windows');
      h.platform.onInstall = failAll(
        const UpdateFailure(UpdateFailureKind.declined, code: 2),
      );
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();

      expect(h.session.stage, UpdaterStage.finished);
      expect(h.row(vogesWord).failure?.kind, UpdateFailureKind.declined);
    });

    sessionTest('reports the install steps of each app', (async) {
      final h = UiHarness(operatingSystem: 'linux');
      final install = Completer<List<InstallOutcome>>();
      h.platform.onInstall = (items, onStep) {
        onStep(items.single, InstallStep.waitingForPermission);
        return install.future;
      };
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();

      expect(h.row(vogesWord).phase, UpdateRowPhase.installing);
      expect(h.row(vogesWord).step, InstallStep.waitingForPermission);
    });
  });

  group('leaving', () {
    final ways = <String, void Function(UiHarness h, FakeAsync async)>{
      'Not now': (h, async) {},
      'while downloading': (h, async) {
        h.session.update();
        async.flushMicrotasks();
      },
      'while waiting for the apps': (h, async) {
        h.platform.runningAnswers = [
          [const RunningApp(app: vogesWord, pid: 41)],
        ];
        h.session.update();
        async.flushMicrotasks();
      },
      'after a failure': (h, async) {
        h.platform.onInstall = failAll(
          const UpdateFailure(UpdateFailureKind.failed, code: 7),
        );
        h.session.update();
        async.flushMicrotasks();
      },
    };
    for (final MapEntry(key: way, value: prepare) in ways.entries) {
      sessionTest('reopens the host: $way', (async) {
        final h = UiHarness(manualDownloads: way.contains('downloading'));
        h.session.start();
        async.flushMicrotasks();
        prepare(h, async);

        expect(h.session.reopensHost, isTrue);
        h.session.leave();
        expect(h.platform.finished, [wordHost]);
        async.elapse(Duration.zero);
        expect(h.exits, [0]);
      });
    }

    sessionTest('reopens the host when up to date or offline', (async) {
      for (final latest in [
        {vogesWord: '1.1.0'},
        <SuiteApp, String>{},
      ]) {
        final h = UiHarness(latest: latest);
        h.session.start();
        async.flushMicrotasks();
        h.session.leave();
        expect(h.platform.finished, [wordHost]);
        async.elapse(Duration.zero);
        expect(h.exits, [0]);
      }
    });
  });

  group('ways out of a failure', () {
    List<RowAction> actionsFor(FakeAsync async, UpdateFailure failure) {
      final h = UiHarness()..platform.onInstall = failAll(failure);
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();
      return h.session.actionsOf(h.row(vogesWord));
    }

    sessionTest('a failed verification never offers the download page', (
      async,
    ) {
      final h = UiHarness();
      h.downloader.errors[vogesWord.repository] = const UpdateFailure(
        UpdateFailureKind.verification,
      );
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();

      final row = h.row(vogesWord);
      expect(row.failure?.kind, UpdateFailureKind.verification);
      expect(h.session.actionsOf(row), isEmpty);
      h.session.perform(row, RowAction.downloadPage);
      async.flushMicrotasks();
      expect(h.opened, isEmpty);

      h.downloader.errors.clear();
      h.session.retry();
      async.flushMicrotasks();
      expect(h.downloader.calls, hasLength(2));
    });

    sessionTest('an installer that changed on disk is downloaded again', (
      async,
    ) {
      final h = UiHarness()
        ..platform.onInstall = failAll(
          const UpdateFailure(UpdateFailureKind.verification),
        );
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();
      expect(h.session.actionsOf(h.row(vogesWord)), isEmpty);

      h.platform.onInstall = null;
      h.session.retry();
      async.flushMicrotasks();
      expect(h.downloader.calls, hasLength(2));
    });

    sessionTest('only retrying helps some failures', (async) {
      for (final kind in [
        UpdateFailureKind.network,
        UpdateFailureKind.unavailable,
        UpdateFailureKind.inUse,
        UpdateFailureKind.declined,
      ]) {
        expect(
          actionsFor(async, UpdateFailure(kind)),
          isEmpty,
          reason: '$kind',
        );
      }
    });

    sessionTest('macOS opens the verified installer', (async) {
      const failure = UpdateFailure(
        UpdateFailureKind.permission,
        installer: '/tmp/VogesWord-macos.dmg',
      );
      expect(actionsFor(async, failure), [RowAction.openInstaller]);
      expect(
        actionsFor(async, const UpdateFailure(UpdateFailureKind.permission)),
        [RowAction.downloadPage],
      );

      final h = UiHarness()..platform.onInstall = failAll(failure);
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();
      h.session.perform(h.row(vogesWord), RowAction.openInstaller);
      async.flushMicrotasks();
      expect(h.platform.fallbacks, [failure]);
    });

    sessionTest('Windows shows the log and the download page', (async) {
      const failure = UpdateFailure(
        UpdateFailureKind.failed,
        code: 7,
        logPath: '/tmp/logs/voges-word-user.log',
      );
      expect(actionsFor(async, failure), [
        RowAction.showLog,
        RowAction.downloadPage,
      ]);

      final h = UiHarness()..platform.onInstall = failAll(failure);
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();
      h.session.perform(h.row(vogesWord), RowAction.showLog);
      h.session.perform(h.row(vogesWord), RowAction.downloadPage);
      async.flushMicrotasks();
      expect(h.opened, [
        Uri.file('/tmp/logs/voges-word-user.log'),
        Uri.parse(vogesWord.downloadPage),
      ]);
    });

    sessionTest('Linux copies the command to install by hand', (async) {
      const command = "sudo apt install '/tmp/voges-word-linux-amd64.deb'";
      for (final kind in [
        UpdateFailureKind.noPasswordWindow,
        UpdateFailureKind.notAuthorized,
        UpdateFailureKind.packageManager,
      ]) {
        expect(actionsFor(async, UpdateFailure(kind, command: command)), [
          RowAction.copyCommand,
          RowAction.downloadPage,
        ], reason: '$kind');
      }

      final copied = <Object?>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add(call.arguments);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final h = UiHarness(operatingSystem: 'linux')
        ..platform.onInstall = failAll(
          const UpdateFailure(
            UpdateFailureKind.noPasswordWindow,
            code: 127,
            command: command,
          ),
        );
      h.session.start();
      async.flushMicrotasks();
      h.session.update();
      async.flushMicrotasks();
      h.session.perform(h.row(vogesWord), RowAction.copyCommand);
      async.flushMicrotasks();
      expect(copied, [
        {'text': command},
      ]);
    });
  });

  sessionTest('opens the release notes of the new version', (async) {
    final h = UiHarness();
    h.session.start();
    async.flushMicrotasks();
    h.session.openReleaseNotes(h.row(vogesWord));
    async.flushMicrotasks();

    expect(h.opened, [
      Uri.parse(
        'https://github.com/omanoloneto/voges-word/releases/tag/v1.2.0',
      ),
    ]);
  });
}
