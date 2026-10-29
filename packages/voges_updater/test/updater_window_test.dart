import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_updater/voges_updater.dart';

import 'support/ui_fakes.dart';

Future<void> pumpUpdater(
  WidgetTester tester,
  UiHarness h, {
  Locale locale = const Locale('en'),
  Size size = const Size(560, 520),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(UpdaterApp(session: h.session, locale: locale));
  await tester.pump();
}

/// What window_manager sends when the user clicks the window's close button.
Future<void> requestWindowClose(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'window_manager',
    const StandardMethodCodec().encodeMethodCall(
      const MethodCall('onEvent', {'eventName': 'close'}),
    ),
    (_) {},
  );
  await tester.pump();
}

Finder button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
);

bool isEnabled(WidgetTester tester, String label) =>
    tester.widget<ButtonStyleButton>(button(label)).enabled;

CheckboxListTile tile(WidgetTester tester, String title) =>
    tester.widget(find.widgetWithText(CheckboxListTile, title));

UiHarness twoApps() => UiHarness(
  copies: [
    installedCopy(vogesWord, '1.1.0'),
    installedCopy(vogesSheets, '1.0.0'),
  ],
  latest: {vogesWord: '1.2.0', vogesSheets: '1.0.1'},
);

InstallHandler failAll(UpdateFailure failure) =>
    (items, onStep) async => [
      for (final item in items) NotInstalled(item, failure),
    ];

Future<void> update(WidgetTester tester, String label) async {
  await tester.tap(button(label));
  await tester.pump();
}

void main() {
  group('screens', () {
    testWidgets('checking', (tester) async {
      final h = UiHarness();
      await pumpUpdater(tester, h);

      expect(find.text('Looking for updates…'), findsOneWidget);
      expect(
        find.text(
          'Voges Word was closed to install updates. It opens again when '
          'you\'re done.',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate((w) => w is ButtonStyleButton),
        findsNothing,
      );
    });

    testWidgets('already running closes without reopening the app', (
      tester,
    ) async {
      final h = UiHarness(locked: true);
      await h.session.start();
      await pumpUpdater(tester, h);

      expect(
        find.text('Voges Updater is already open in another window.'),
        findsOneWidget,
      );
      await tester.tap(button('Close'));
      expect(h.exits, [0]);
      expect(h.platform.finished, isEmpty);
    });

    testWidgets('host not found offers the download page', (tester) async {
      final h = UiHarness()..platform.hostResult = null;
      await h.session.start();
      await pumpUpdater(tester, h);

      expect(
        find.text(
          'Voges Updater couldn\'t find where Voges Word is installed. '
          'Download the new version from the website.',
        ),
        findsOneWidget,
      );
      await tester.tap(button('Download page'));
      await tester.pump();
      expect(h.opened, [Uri.parse(vogesWord.downloadPage)]);

      await tester.tap(button('Close'));
      expect(h.exits, [0]);
      expect(h.platform.finished, [null]);
    });

    testWidgets('offline tries again', (tester) async {
      final h = UiHarness(latest: const {});
      await h.session.start();
      await pumpUpdater(tester, h);

      expect(
        find.text(
          'Couldn\'t check for updates. Check your internet connection.',
        ),
        findsOneWidget,
      );
      expect(button('Open Voges Word'), findsOneWidget);

      h.feed.versions[vogesWord.repository] = version('1.2.0');
      await tester.tap(button('Try again'));
      await tester.pump();
      expect(button('Update 1 app'), findsOneWidget);
    });

    testWidgets('up to date opens the app again', (tester) async {
      final h = UiHarness(latest: {vogesWord: '1.1.0'});
      await h.session.start();
      await pumpUpdater(tester, h);

      expect(find.text('All your Voges apps are up to date.'), findsOneWidget);
      await tester.tap(button('Open Voges Word'));
      expect(h.platform.finished, [wordHost]);
      expect(h.exits, [0]);
    });

    testWidgets('choosing lists each update', (tester) async {
      final h = UiHarness();
      await h.session.start();
      await pumpUpdater(tester, h);

      expect(find.text('Updates for your Voges apps'), findsOneWidget);
      expect(
        find.text(
          'Voges Word was closed to install updates. It opens again when '
          'you\'re done.',
        ),
        findsOneWidget,
      );
      expect(tile(tester, 'Voges Word').value, isTrue);
      expect(find.text('1.1.0 → 1.2.0'), findsOneWidget);
      expect(find.text('Select all'), findsNothing);
      expect(button('Not now'), findsOneWidget);
      expect(button('Update 1 app'), findsOneWidget);

      await tester.tap(button('What\'s new'));
      await tester.pump();
      expect(h.opened, [
        Uri.parse(
          'https://github.com/omanoloneto/voges-word/releases/tag/v1.2.0',
        ),
      ]);

      await tester.tap(button('Not now'));
      expect(h.platform.finished, [wordHost]);
      expect(h.exits, [0]);
    });

    testWidgets('choosing shows a failed check without a checkbox', (
      tester,
    ) async {
      final h = UiHarness(
        copies: [
          installedCopy(vogesWord, '1.1.0'),
          installedCopy(vogesSheets, '1.0.0'),
        ],
      );
      await h.session.start();
      await pumpUpdater(tester, h);

      expect(find.text('Voges Sheets'), findsOneWidget);
      expect(find.text('Couldn\'t check for updates'), findsOneWidget);
      expect(find.byType(Checkbox), findsOneWidget);
      expect(find.text('Select all'), findsNothing);
    });

    testWidgets('choosing tells the copies of an app apart', (tester) async {
      final h = UiHarness(
        copies: [
          installedCopy(vogesWord, '1.1.0'),
          installedCopy(vogesWord, '1.1.0', scope: InstallScope.allUsers),
        ],
      );
      await h.session.start();
      await pumpUpdater(tester, h);

      expect(find.textContaining('For this user'), findsOneWidget);
      expect(
        find.textContaining(
          'For all users · asks for administrator permission',
        ),
        findsOneWidget,
      );
    });

    testWidgets('choosing shows the folder of each macOS copy', (tester) async {
      final h = UiHarness(
        copies: [
          installedCopy(vogesWord, '1.1.0'),
          installedCopy(
            vogesWord,
            '1.1.0',
            location: '/Users/ana/Applications/Voges Word.app',
          ),
        ],
      );
      await h.session.start();
      await pumpUpdater(tester, h);

      expect(
        find.textContaining('/Applications/Voges Word.app'),
        findsNWidgets(2),
      );
      expect(
        find.textContaining('/Users/ana/Applications/Voges Word.app'),
        findsOneWidget,
      );
    });

    testWidgets('choosing warns about the administrator prompt', (
      tester,
    ) async {
      final h = UiHarness(
        copies: [
          installedCopy(vogesWord, '1.1.0', scope: InstallScope.allUsers),
        ],
      );
      await h.session.start();
      await pumpUpdater(tester, h);

      expect(
        find.text(
          '1.1.0 → 1.2.0\nFor all users · asks for administrator permission',
        ),
        findsOneWidget,
      );
    });

    testWidgets('downloading shows the progress and cancels', (tester) async {
      final h = UiHarness(manualDownloads: true);
      await h.session.start();
      await pumpUpdater(tester, h);
      await update(tester, 'Update 1 app');

      expect(find.text('Downloading… 0%'), findsOneWidget);
      final call = h.downloader.calls.single;
      call.onProgress!(0.42);
      await tester.pump();
      expect(find.text('Downloading… 42%'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.42,
      );

      call.onProgress!(1);
      await tester.pump();
      expect(find.text('Checking the download…'), findsOneWidget);

      await tester.tap(button('Cancel'));
      await tester.pump();
      expect(button('Update 1 app'), findsOneWidget);
    });

    testWidgets('waiting lists the open apps and continues by itself', (
      tester,
    ) async {
      final h = UiHarness()
        ..platform.runningAnswers = [
          [
            const RunningApp(app: vogesWord, pid: 41),
            const RunningApp(app: vogesWord, pid: 42),
            const RunningApp(app: vogesWord, pid: 43, otherAccount: true),
          ],
          [const RunningApp(app: vogesWord, pid: 41)],
          const [],
        ];
      await h.session.start();
      await pumpUpdater(tester, h);
      await update(tester, 'Update 1 app');

      expect(
        find.text(
          'Save your work and close these apps. The update continues by '
          'itself once they\'re closed.',
        ),
        findsOneWidget,
      );
      expect(find.text('Voges Word · 2 windows'), findsOneWidget);
      expect(
        find.text('Voges Word · open in another user account'),
        findsOneWidget,
      );
      expect(button('Cancel'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Voges Word · 1 window'), findsOneWidget);
      expect(
        find.text('Voges Word · open in another user account'),
        findsNothing,
      );

      await tester.pump(const Duration(seconds: 1));
      expect(h.platform.installs, hasLength(1));
      expect(h.exits, [0]);
    });

    testWidgets('waiting cancels back to the list', (tester) async {
      final h = UiHarness()
        ..platform.runningAnswers = [
          [const RunningApp(app: vogesWord, pid: 41)],
        ];
      await h.session.start();
      await pumpUpdater(tester, h);
      await update(tester, 'Update 1 app');

      await tester.tap(button('Cancel'));
      await tester.pump();
      expect(button('Update 1 app'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(h.platform.runningChecks, 1);
    });

    testWidgets('installing has no buttons and shows the administrator hint', (
      tester,
    ) async {
      final h = UiHarness(
        copies: [
          installedCopy(vogesWord, '1.1.0', scope: InstallScope.allUsers),
        ],
      );
      final install = Completer<List<InstallOutcome>>();
      h.platform.onInstall = (items, onStep) => install.future;
      await h.session.start();
      await pumpUpdater(tester, h);
      await update(tester, 'Update 1 app');

      expect(find.text('Installing…'), findsOneWidget);
      expect(
        find.text(
          'Confirm the administrator prompt. If you don\'t see it, look for '
          'it on the taskbar.',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate((w) => w is ButtonStyleButton),
        findsNothing,
      );
    });

    testWidgets('installing on Linux asks for the password', (tester) async {
      final h = UiHarness(operatingSystem: 'linux');
      final install = Completer<List<InstallOutcome>>();
      h.platform.onInstall = (items, onStep) {
        onStep(items.single, InstallStep.waitingForPermission);
        return install.future;
      };
      await h.session.start();
      await pumpUpdater(tester, h);
      await update(tester, 'Update 1 app');

      expect(
        find.text('Type your password in the window that opened.'),
        findsOneWidget,
      );
    });

    testWidgets('finished shows each result and tries again', (tester) async {
      final h = twoApps()
        ..platform.onInstall = (items, onStep) async => [
          for (final item in items)
            item.copy.app == vogesWord
                ? Installed(item, item.version)
                : NotInstalled(
                    item,
                    const UpdateFailure(UpdateFailureKind.inUse),
                  ),
        ];
      await h.session.start();
      await pumpUpdater(tester, h);
      await update(tester, 'Update 2 apps');

      expect(find.text('Updated to 1.2.0'), findsOneWidget);
      expect(
        find.text(
          'Voges Sheets or one of its files was still in use. Close it and '
          'try again.',
        ),
        findsOneWidget,
      );
      expect(button('Open Voges Word'), findsOneWidget);

      h.platform.onInstall = null;
      await tester.tap(button('Try again'));
      await tester.pump();
      expect(h.platform.installs.last.single.copy.app, vogesSheets);
      expect(h.exits, [0]);
    });
  });

  group('failures', () {
    Future<UiHarness> finishWith(
      WidgetTester tester,
      UpdateFailure failure, {
      String operatingSystem = 'macos',
    }) async {
      final h = UiHarness(operatingSystem: operatingSystem)
        ..platform.onInstall = failAll(failure);
      await h.session.start();
      await pumpUpdater(tester, h);
      await update(tester, 'Update 1 app');
      return h;
    }

    testWidgets('macOS opens the installer', (tester) async {
      const failure = UpdateFailure(
        UpdateFailureKind.permission,
        installer: '/tmp/VogesWord-macos.dmg',
      );
      final h = await finishWith(tester, failure);

      expect(
        find.text(
          'macOS didn\'t allow replacing Voges Word. Install it with the '
          'installer.',
        ),
        findsOneWidget,
      );
      await tester.tap(button('Open the installer'));
      await tester.pump();
      expect(h.platform.fallbacks, [failure]);
    });

    testWidgets('Windows shows the exit code, the log and the download page', (
      tester,
    ) async {
      await finishWith(
        tester,
        const UpdateFailure(
          UpdateFailureKind.failed,
          code: 7,
          logPath: r'C:\Temp\logs\voges-word-user.log',
        ),
        operatingSystem: 'windows',
      );

      expect(find.text('The update failed (code 7).'), findsOneWidget);
      expect(button('Show log'), findsOneWidget);
      expect(button('Download page'), findsOneWidget);
      expect(button('Try again'), findsOneWidget);
    });

    testWidgets('Linux shows the command to run by hand', (tester) async {
      const command = "sudo apt install '/tmp/voges-word-linux-amd64.deb'";
      await finishWith(
        tester,
        const UpdateFailure(
          UpdateFailureKind.noPasswordWindow,
          code: 127,
          command: command,
        ),
        operatingSystem: 'linux',
      );

      expect(
        find.text(
          'This system can\'t show a password window. Install the update '
          'from a terminal:',
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(SelectableText, command), findsOneWidget);
      expect(
        find.text('Keep this window open until the command finishes.'),
        findsOneWidget,
      );
      expect(button('Copy command'), findsOneWidget);
      expect(button('Download page'), findsOneWidget);
    });

    testWidgets('Linux shows what the package manager said', (tester) async {
      await finishWith(
        tester,
        const UpdateFailure(
          UpdateFailureKind.packageManager,
          code: 100,
          detail:
              'E: Unable to correct problems, you have held broken '
              'packages.',
          command: "sudo apt install '/tmp/voges-word-linux-amd64.deb'",
        ),
        operatingSystem: 'linux',
      );

      expect(
        find.text('The package manager couldn\'t install the update:'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(
          SelectableText,
          'E: Unable to correct problems, you have held broken packages.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a failed verification offers no download page', (
      tester,
    ) async {
      final h = UiHarness();
      h.downloader.errors[vogesWord.repository] = const UpdateFailure(
        UpdateFailureKind.verification,
      );
      await h.session.start();
      await pumpUpdater(tester, h);
      await update(tester, 'Update 1 app');

      expect(
        find.text(
          'The download couldn\'t be verified, so nothing was installed. '
          'Try again later.',
        ),
        findsOneWidget,
      );
      expect(button('Download page'), findsNothing);
      expect(button('Try again'), findsOneWidget);
    });

    testWidgets('a failure without an exit code', (tester) async {
      await finishWith(tester, const UpdateFailure(UpdateFailureKind.failed));

      expect(find.text('The update failed.'), findsOneWidget);
    });
  });

  group('select all', () {
    testWidgets('is tri-state with two or more updates', (tester) async {
      final h = twoApps();
      await h.session.start();
      await pumpUpdater(tester, h);

      expect(tile(tester, 'Select all').value, isTrue);
      expect(button('Update 2 apps'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(CheckboxListTile, 'Voges Sheets'),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pump();
      expect(tile(tester, 'Select all').value, isNull);
      expect(tile(tester, 'Voges Sheets').value, isFalse);
      expect(button('Update 1 app'), findsOneWidget);

      await tester.tap(find.text('Select all'));
      await tester.pump();
      expect(tile(tester, 'Select all').value, isTrue);
      expect(tile(tester, 'Voges Sheets').value, isTrue);
      expect(button('Update 2 apps'), findsOneWidget);

      await tester.tap(find.text('Select all'));
      await tester.pump();
      expect(tile(tester, 'Select all').value, isFalse);
      expect(tile(tester, 'Voges Word').value, isFalse);
      expect(isEnabled(tester, 'Update 0 apps'), isFalse);
    });
  });

  group('closing', () {
    testWidgets('is refused while installing', (tester) async {
      final h = UiHarness();
      final install = Completer<List<InstallOutcome>>();
      h.platform.onInstall = (items, onStep) => install.future;
      await h.session.start();
      await pumpUpdater(tester, h);
      await update(tester, 'Update 1 app');

      await requestWindowClose(tester);
      expect(h.exits, isEmpty);
      expect(
        await tester.binding.handleRequestAppExit(),
        AppExitResponse.cancel,
      );
      expect(h.exits, isEmpty);

      final item = h.platform.installs.single.single;
      install.complete([
        NotInstalled(item, const UpdateFailure(UpdateFailureKind.inUse)),
      ]);
      await tester.pump();
      await requestWindowClose(tester);
      expect(h.platform.finished, [wordHost]);
      expect(h.exits, [0]);
    });

    testWidgets('reopens the app from the list', (tester) async {
      final h = UiHarness();
      await h.session.start();
      await pumpUpdater(tester, h);

      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
      expect(h.platform.finished, [wordHost]);
      expect(h.exits, [0]);
    });
  });

  group('keys', () {
    testWidgets('Enter updates and Esc means Not now', (tester) async {
      final h = UiHarness();
      await h.session.start();
      await pumpUpdater(tester, h);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(h.exits, [0]);
      expect(h.platform.installs, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(h.platform.installs, hasLength(1));
    });

    testWidgets('Esc cancels the download', (tester) async {
      final h = UiHarness(manualDownloads: true);
      await h.session.start();
      await pumpUpdater(tester, h);
      await update(tester, 'Update 1 app');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(h.session.stage, UpdaterStage.choosing);
      expect(h.exits, isEmpty);
    });

    testWidgets('Enter on a focused button presses that button', (
      tester,
    ) async {
      final h = UiHarness();
      await h.session.start();
      await pumpUpdater(tester, h);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(tile(tester, 'Voges Word').value, isFalse);
      expect(h.platform.installs, isEmpty);
    });

    testWidgets('keep working after the focused control leaves the screen', (
      tester,
    ) async {
      final h = UiHarness(manualDownloads: true);
      await h.session.start();
      await pumpUpdater(tester, h);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      await update(tester, 'Update 1 app');
      await tester.pump();
      expect(h.session.stage, UpdaterStage.downloading);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(h.session.stage, UpdaterStage.choosing);
    });
  });

  group('languages', () {
    testWidgets('Portuguese', (tester) async {
      final h = twoApps();
      await h.session.start();
      await pumpUpdater(tester, h, locale: const Locale('pt'));

      expect(find.text('Atualizações dos seus apps Voges'), findsOneWidget);
      expect(button('Agora não'), findsOneWidget);
      expect(button('Atualizar 2 apps'), findsOneWidget);
      h.session.select(h.row(vogesSheets), false);
      await tester.pump();
      expect(button('Atualizar 1 app'), findsOneWidget);
    });

    testWidgets('Spanish', (tester) async {
      final h = twoApps();
      await h.session.start();
      await pumpUpdater(tester, h, locale: const Locale('es'));

      expect(find.text('Actualizaciones de tus apps de Voges'), findsOneWidget);
      expect(button('Ahora no'), findsOneWidget);
      expect(button('Actualizar 2 apps'), findsOneWidget);
      h.session.select(h.row(vogesSheets), false);
      await tester.pump();
      expect(button('Actualizar 1 app'), findsOneWidget);
    });

    testWidgets('fits the smallest window', (tester) async {
      for (final locale in UpdaterLocalizations.supportedLocales) {
        final h = twoApps()
          ..platform.onInstall = failAll(
            const UpdateFailure(
              UpdateFailureKind.notAuthorized,
              code: 127,
              command:
                  "sudo apt install '/home/ana/.cache/voges/update-x1y2z3/"
                  "voges-word-linux-amd64.deb' '/home/ana/.cache/voges/"
                  "update-x1y2z3/voges-sheets-linux-amd64.deb'",
            ),
          );
        await h.session.start();
        await pumpUpdater(
          tester,
          h,
          locale: locale,
          size: const Size(480, 420),
        );
        expect(tester.takeException(), isNull);

        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is FilledButton && w.onPressed != null,
          ),
        );
        await tester.pump();
        expect(h.session.stage, UpdaterStage.finished);
        expect(tester.takeException(), isNull);
      }
    });
  });
}
