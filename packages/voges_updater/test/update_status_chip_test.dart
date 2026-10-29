import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_updater/voges_updater.dart';

import 'support/ui_fakes.dart';

/// An update check of Voges Word 1.1.0 over fakes.
class _Subject {
  _Subject({
    String? latest = '1.2.0',
    LaunchAvailability availability = LaunchAvailability.here,
    bool versioned = true,
  }) : feed = FakeFeed({
         if (latest != null) vogesWord.repository: version(latest),
       }),
       launcher = FakeLauncher(availability) {
    check = UpdateCheck(
      app: vogesWord,
      current: versioned ? version('1.1.0') : null,
      feed: feed,
      launcher: launcher,
      openUrl: (url) async {
        opened.add(url);
        return true;
      },
    );
  }

  final FakeFeed feed;
  final FakeLauncher launcher;
  final opened = <Uri>[];
  var updates = 0;
  late final UpdateCheck check;

  Future<void> onUpdate() async => updates++;

  Future<void> pump(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    double width = 1000,
  }) async {
    tester.view.physicalSize = Size(width, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: UpdaterLocalizations.supportedLocales,
        localizationsDelegates: UpdaterLocalizations.localizationsDelegates,
        home: Scaffold(
          body: Center(
            child: UpdateStatusChip(check: check, onUpdate: onUpdate),
          ),
        ),
      ),
    );
  }
}

/// A state of the indicator: how to reach it, and its label and tooltip.
typedef _State = ({
  String name,
  _Subject Function() subject,
  Future<void> Function(UpdateCheck check) reach,
  String label,
  String? tooltip,
});

List<_State> _states(UpdaterLocalizations l10n) => [
  (
    name: 'checking',
    subject: _Subject.new,
    reach: (check) async {},
    label: l10n.updateChecking,
    tooltip: null,
  ),
  (
    name: 'up to date',
    subject: () => _Subject(latest: '1.1.0'),
    reach: (check) => check.check(),
    label: l10n.updateUpToDate,
    tooltip: l10n.updateUpToDateTooltip('Voges Word', '1.1.0'),
  ),
  (
    name: 'available here',
    subject: _Subject.new,
    reach: (check) => check.check(),
    label: l10n.updateAvailable('1.2.0'),
    tooltip: l10n.updateAvailableTooltip('Voges Word', '1.2.0'),
  ),
  (
    name: 'available to download',
    subject: () => _Subject(availability: LaunchAvailability.download),
    reach: (check) => check.check(),
    label: l10n.updateDownloadAvailable('1.2.0'),
    tooltip: l10n.updateDownloadTooltip,
  ),
  (
    name: 'available after moving to Applications',
    subject: () =>
        _Subject(availability: LaunchAvailability.moveToApplications),
    reach: (check) => check.check(),
    label: l10n.updateDownloadAvailable('1.2.0'),
    tooltip: l10n.updateMoveToApplications('Voges Word'),
  ),
  (
    name: 'opening',
    subject: _Subject.new,
    reach: (check) async {
      await check.check();
      check.startUpdater().ignore();
    },
    label: l10n.updateOpening,
    tooltip: null,
  ),
  (
    name: 'check failed',
    subject: () => _Subject(latest: null),
    reach: (check) => check.check(),
    label: l10n.updateCheckFailed,
    tooltip: l10n.updateCheckFailedTooltip,
  ),
];

void main() {
  testWidgets('is hidden without a version', (tester) async {
    final subject = _Subject(versioned: false);
    await subject.check.check();
    await subject.pump(tester);

    expect(subject.check.status, isA<UpdateHidden>());
    expect(tester.getSize(find.byType(UpdateStatusChip)), Size.zero);
  });

  for (final locale in UpdaterLocalizations.supportedLocales) {
    final l10n = lookupUpdaterLocalizations(locale);
    group('in ${locale.languageCode}', () {
      for (final state in _states(l10n)) {
        testWidgets('${state.name} shows its text and fits the status bar', (
          tester,
        ) async {
          final subject = state.subject();
          await state.reach(subject.check);
          await subject.pump(tester, locale: locale);

          expect(find.text(state.label), findsOneWidget);
          if (state.tooltip case final tooltip?) {
            expect(find.byTooltip(tooltip), findsOneWidget);
          }
          expect(
            tester.getSize(find.byType(UpdateStatusChip)).height,
            lessThanOrEqualTo(32),
          );
        });

        testWidgets('${state.name} shows only its icon below 640 px', (
          tester,
        ) async {
          final subject = state.subject();
          await state.reach(subject.check);
          await subject.pump(tester, locale: locale, width: 639);

          expect(find.text(state.label), findsNothing);
          final tooltip = state.tooltip;
          expect(
            find.byTooltip(
              tooltip == null ? state.label : '${state.label}\n$tooltip',
            ),
            findsOneWidget,
          );
          expect(
            tester.getSize(find.byType(UpdateStatusChip)).height,
            lessThanOrEqualTo(32),
          );
        });
      }
    });
  }

  testWidgets('speaks the language of the app', (tester) async {
    for (final (language, text) in [
      ('en', 'Update to 1.2.0'),
      ('pt', 'Atualizar para 1.2.0'),
      ('es', 'Actualizar a 1.2.0'),
    ]) {
      final subject = _Subject();
      await subject.check.check();
      await subject.pump(tester, locale: Locale(language));
      expect(find.text(text), findsOneWidget, reason: language);
    }
  });

  testWidgets('shows the full text from 640 px', (tester) async {
    final subject = _Subject();
    await subject.check.check();
    await subject.pump(tester, width: 640);

    expect(find.text('Update to 1.2.0'), findsOneWidget);
  });

  group('click', () {
    testWidgets('on an update closes the app through the callback', (
      tester,
    ) async {
      final subject = _Subject();
      await subject.check.check();
      await subject.pump(tester);
      await tester.tap(find.text('Update to 1.2.0'));
      await tester.pump();

      expect(subject.updates, 1);
      expect(subject.launcher.launches, isEmpty);
    });

    testWidgets('on the icon below 640 px does the same', (tester) async {
      final subject = _Subject();
      await subject.check.check();
      await subject.pump(tester, width: 600);
      await tester.tap(find.byIcon(Icons.system_update_alt));
      await tester.pump();

      expect(subject.updates, 1);
    });

    for (final availability in [
      LaunchAvailability.download,
      LaunchAvailability.moveToApplications,
    ]) {
      testWidgets('on a ${availability.name} update opens the download page', (
        tester,
      ) async {
        final subject = _Subject(availability: availability);
        await subject.check.check();
        await subject.pump(tester);
        await tester.tap(find.text('Version 1.2.0 available'));
        await tester.pump();

        expect(subject.opened, [Uri.parse(vogesWord.downloadPage)]);
        expect(subject.updates, 0);
      });
    }

    testWidgets('on "up to date" checks again', (tester) async {
      final subject = _Subject(latest: '1.1.0');
      await subject.check.check();
      await subject.pump(tester);
      await tester.tap(find.text('Up to date'));
      await tester.pump();

      expect(subject.feed.checks, hasLength(2));
    });

    testWidgets('on a failed check checks again', (tester) async {
      final subject = _Subject(latest: null);
      await subject.check.check();
      await subject.pump(tester);
      subject.feed.versions[vogesWord.repository] = version('1.2.0');
      await tester.tap(find.text('Couldn\'t check for updates'));
      await tester.pump();

      expect(subject.feed.checks, hasLength(2));
      expect(find.text('Update to 1.2.0'), findsOneWidget);
    });

    testWidgets('does nothing while checking or opening', (tester) async {
      final subject = _Subject();
      await subject.pump(tester);
      expect(
        find.byWidgetPredicate((w) => w is ButtonStyleButton),
        findsNothing,
      );

      await subject.check.check();
      subject.check.startUpdater().ignore();
      await tester.pump();
      expect(find.text('Opening the updater…'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is ButtonStyleButton),
        findsNothing,
      );
    });
  });
}
