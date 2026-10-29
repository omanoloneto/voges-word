import 'dart:async';
import 'dart:io' show SocketException;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart' show TextField;
import 'package:flutter/widgets.dart' show Locale, Scrollable, ScrollableState;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_updater/voges_updater.dart'
    show
        LaunchAvailability,
        LaunchResult,
        ReleaseFeed,
        ReleaseVersion,
        UpdateCheck,
        UpdaterLauncher,
        vogesWord;
import 'package:voges_word/app.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';

FontCatalog _offlineFonts() => FontCatalog(
  listSystemFonts: () async => const [],
  readGoogleCatalog: () async => '',
);

Future<EditorSession> _pumpApp(
  WidgetTester tester, {
  FontCatalog? fonts,
  AppLanguage? language,
  UpdateCheck? updates,
  Size size = const Size(1200, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final tables = TableStore();
  final docx = DocxCodec(tables);
  final files = DocumentFiles();
  final session = EditorSession(
    docx: docx,
    plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
    files: files,
    tables: tables,
  );

  final table = tables.createEmpty(rows: 2, columns: 2, totalWidth: 9000);
  table.rows[0].cells[0].controller.document.insert(0, 'Class');
  final bytes = docx.encode(
    Delta()
      ..insert('Text before the table\n')
      ..insert({EmbedTypes.table: encodeTableId(table.id)})
      ..insert('\nText after\n'),
  );
  session.open(OpenedFile(name: 'test.docx', bytes: bytes));

  await tester.pumpWidget(
    VogesWordApp(
      session: session,
      systemOpen: SystemOpen(files),
      recents: RecentFiles(files),
      fonts: fonts ?? _offlineFonts(),
      launchArguments: const [],
      language: language ?? AppLanguage(),
      updates: updates,
    ),
  );
  await tester.pumpAndSettle();
  return session;
}

final class _Feed implements ReleaseFeed {
  const _Feed(this.version);

  final ReleaseVersion version;

  @override
  Future<ReleaseVersion> latest(String repository) async => version;
}

final class _OfflineFeed implements ReleaseFeed {
  const _OfflineFeed();

  @override
  Future<ReleaseVersion> latest(String repository) async =>
      throw const SocketException('offline');
}

final class _Launcher implements UpdaterLauncher {
  _Launcher(this.result, {this.opening});

  final LaunchResult result;

  /// Holds the launch open until completed, like the Windows copy does.
  final Completer<LaunchResult>? opening;
  var launches = 0;

  @override
  LaunchAvailability get availability => LaunchAvailability.here;

  @override
  Future<LaunchResult> launch() async {
    launches++;
    return opening?.future ?? result;
  }

  @override
  Future<void> cleanUp() async {}
}

UpdateCheck _updates(String latest, _Launcher launcher) => UpdateCheck(
  app: vogesWord,
  current: const ReleaseVersion(1, 2, 0),
  feed: _Feed(ReleaseVersion.tryParse(latest)!),
  launcher: launcher,
);

/// The calls the app makes to the window, such as `destroy`.
List<String> _recordWindowCalls() {
  final calls = <String>[];
  const channel = MethodChannel('window_manager');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call.method);
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return calls;
}

Finder _richText(String text) => find.textContaining(text, findRichText: true);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('clicking a cell edits the cell, not the main text', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    final mainText = session.controller.document.toPlainText();

    await tester.tap(_richText('Class'));
    await tester.pumpAndSettle();

    final cell = session.activeCell.value;
    expect(cell, isNotNull);
    expect(session.activeController.value, same(cell!.cell.controller));

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Class A\n',
        selection: TextSelection.collapsed(offset: 7),
      ),
    );
    await tester.pumpAndSettle();

    expect(cell.cell.controller.document.toPlainText(), 'Class A\n');
    expect(session.controller.document.toPlainText(), mainText);
    expect(session.dirty, isTrue);

    await tester.tap(_richText('Text after'));
    await tester.pumpAndSettle();
    expect(session.activeCell.value, isNull);
    expect(session.activeController.value, same(session.controller));
  });

  testWidgets('bold from the ribbon applies to the selected text', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    await tester.tap(_richText('Text before'));
    await tester.pumpAndSettle();

    session.controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 4),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Bold (Ctrl+B)'));
    await tester.pumpAndSettle();

    final first = session.controller.document.toDelta().toList().first;
    expect(first.data, 'Text');
    expect(first.attributes?['bold'], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Shift+Enter breaks the line without a new paragraph', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    await tester.tap(_richText('Text before'));
    await tester.pumpAndSettle();
    session.controller.updateSelection(
      const TextSelection.collapsed(offset: 4),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pumpAndSettle();

    expect(
      session.controller.document.toPlainText().startsWith('Text\u2028 before'),
      isTrue,
    );
  });

  testWidgets(
    'a click on a paragraph split across pages finds the right word',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final tables = TableStore();
      final docx = DocxCodec(tables);
      final files = DocumentFiles();
      final session = EditorSession(
        docx: docx,
        plainText: PlainTextCodec(
          look: docx.createEmpty().look,
          tables: tables,
        ),
        files: files,
        tables: tables,
      );
      final words = List.generate(900, (i) => 'word$i').join(' ');
      final bytes = docx.encode(Delta()..insert('$words MARKER end\n'));
      session.open(OpenedFile(name: 'long.docx', bytes: bytes));
      await tester.pumpWidget(
        VogesWordApp(
          session: session,
          systemOpen: SystemOpen(files),
          recents: RecentFiles(files),
          fonts: _offlineFonts(),
          launchArguments: const [],
          language: AppLanguage(),
        ),
      );
      await tester.pumpAndSettle();

      final editor = tester
          .state<EditorState>(find.byType(QuillRawEditor))
          .renderEditor;
      expect(editor.pageCount, greaterThan(1));
      final target =
          session.controller.document.toPlainText().indexOf('MARKER') + 3;
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(QuillEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final caret = editor.getLocalRectForCaret(TextPosition(offset: target));
      scroll.position.jumpTo(caret.top - 200);
      await tester.pumpAndSettle();

      final endpoint = editor
          .getEndpointsForSelection(TextSelection.collapsed(offset: target))
          .single
          .point;
      final point = editor.localToGlobal(endpoint - const Offset(0, 6));
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      final got = session.controller.selection.baseOffset;
      expect((got - target).abs(), lessThanOrEqualTo(1));
    },
  );

  testWidgets('the status bar stays above the phone navigation bar', (
    tester,
  ) async {
    await _pumpApp(tester);
    tester.view.padding = const FakeViewPadding(bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    await tester.pumpAndSettle();

    final words = tester.getRect(find.textContaining('words'));
    expect(words.bottom, lessThanOrEqualTo(900 - 48));
  });

  Future<(EditorSession, FontCatalog, List<Uri>)> pumpWithFonts(
    WidgetTester tester,
  ) async {
    final bytes = Uint8List.fromList(List.generate(64, (i) => i));
    final hash = sha256.convert(bytes).toString();
    final requested = <Uri>[];
    final fonts = FontCatalog(
      listSystemFonts: () async => const ['Georgia'],
      readGoogleCatalog: () async =>
          'Lato\t$hash\t1\nRoboto\t$hash\t1\nPacifico\t$hash\t0\n',
      download: (url) async {
        requested.add(url);
        return bytes;
      },
      cacheDirectory: () async => null,
    );
    final session = await _pumpApp(tester, fonts: fonts);
    session.controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 5),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Font'));
    await tester.pumpAndSettle();
    return (session, fonts, requested);
  }

  String? firstFont(EditorSession session) => session.controller.document
      .toDelta()
      .operations
      .first
      .attributes?[Attribute.font.key];

  testWidgets('the font picker finds and applies a Google font', (
    tester,
  ) async {
    final (session, _, requested) = await pumpWithFonts(tester);
    expect(find.text('ON THIS DEVICE'), findsOneWidget);
    expect(find.text('GOOGLE FONTS'), findsOneWidget);
    expect(find.text('Georgia'), findsOneWidget);
    expect(find.text('Pacifico'), findsNothing);

    await tester.enterText(find.byType(TextField), 'la');
    await tester.pumpAndSettle();
    expect(find.text('Georgia'), findsNothing);
    expect(find.text('ADD FROM GOOGLE FONTS'), findsNothing);

    await tester.tap(find.text('Lato'));
    await tester.pumpAndSettle();

    expect(firstFont(session), 'Lato');
    expect(requested.single.host, 'fonts.gstatic.com');
  });

  testWidgets('a Google font outside the list shows up in the search to add', (
    tester,
  ) async {
    final (session, fonts, _) = await pumpWithFonts(tester);

    await tester.enterText(find.byType(TextField), 'paci');
    await tester.pumpAndSettle();
    expect(find.text('ADD FROM GOOGLE FONTS'), findsOneWidget);

    await tester.tap(find.text('Pacifico'));
    await tester.pumpAndSettle();

    expect(firstFont(session), 'Pacifico');
    expect(fonts.googleFamilies, contains('Pacifico'));
  });

  testWidgets('the interface speaks the chosen language', (tester) async {
    final language = AppLanguage(const Locale('pt'));
    final session = await _pumpApp(tester, language: language);
    expect(find.text('Início'), findsOneWidget);
    expect(find.text('Arquivo'), findsOneWidget);
    expect(session.locale.language, 'pt-BR');

    language.select(const Locale('es'));
    await tester.pumpAndSettle();
    expect(find.text('Inicio'), findsOneWidget);
    expect(find.text('Archivo'), findsOneWidget);
    expect(find.byTooltip('Negrita (Ctrl+B)'), findsOneWidget);
    expect(session.locale.language, 'es-ES');
  });

  testWidgets('the File menu switches the language and remembers it', (
    tester,
  ) async {
    final language = AppLanguage();
    await _pumpApp(tester, language: language);
    expect(find.text('Home'), findsOneWidget);

    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Português'));
    await tester.pumpAndSettle();
    expect(language.locale, const Locale('pt'));
    expect(find.text('Idioma'), findsOneWidget);

    final saved = AppLanguage();
    await saved.load();
    expect(saved.locale, const Locale('pt'));

    await tester.tap(find.text('Igual ao sistema'));
    await tester.pumpAndSettle();
    expect(language.locale, isNull);
    expect(find.text('Language'), findsOneWidget);
  });

  group('updates', () {
    testWidgets('the status bar says when the app is up to date', (
      tester,
    ) async {
      await _pumpApp(
        tester,
        updates: _updates('1.2.0', _Launcher(LaunchResult.started)),
      );

      expect(find.text('Up to date'), findsOneWidget);
    });

    testWidgets('a long status fits a narrow window', (tester) async {
      await _pumpApp(
        tester,
        size: const Size(660, 900),
        language: AppLanguage(const Locale('pt')),
        updates: UpdateCheck(
          app: vogesWord,
          current: const ReleaseVersion(1, 2, 0),
          feed: const _OfflineFeed(),
          launcher: _Launcher(LaunchResult.started),
        ),
      );

      expect(
        find.text('Não foi possível procurar atualizações'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('with unsaved work, Cancel keeps the app open', (tester) async {
      final launcher = _Launcher(LaunchResult.started);
      final calls = _recordWindowCalls();
      final session = await _pumpApp(
        tester,
        updates: _updates('9.9.9', launcher),
      );
      session.controller.document.insert(0, 'changed ');
      await tester.pump();

      await tester.tap(find.text('Update to 9.9.9'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(launcher.launches, 0);
      expect(calls, isNot(contains('destroy')));
    });

    testWidgets("Don't save opens the updater and closes the app", (
      tester,
    ) async {
      final launcher = _Launcher(LaunchResult.started);
      final calls = _recordWindowCalls();
      final session = await _pumpApp(
        tester,
        updates: _updates('9.9.9', launcher),
      );
      session.controller.document.insert(0, 'changed ');
      await tester.pump();

      await tester.tap(find.text('Update to 9.9.9'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Don’t save'));
      // the indicator spins until the window is gone
      await tester.pump();
      await tester.pump();

      expect(launcher.launches, 1);
      expect(calls, contains('destroy'));
    });

    testWidgets('work typed while the updater opens is asked about again', (
      tester,
    ) async {
      final opening = Completer<LaunchResult>();
      final launcher = _Launcher(LaunchResult.started, opening: opening);
      final calls = _recordWindowCalls();
      final session = await _pumpApp(
        tester,
        updates: _updates('9.9.9', launcher),
      );
      session.controller.document.insert(0, 'changed ');
      await tester.pump();

      await tester.tap(find.text('Update to 9.9.9'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Don’t save'));
      await tester.pump();
      session.controller.document.insert(0, 'typed meanwhile ');
      opening.complete(LaunchResult.started);
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Don’t save'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(calls, isNot(contains('destroy')));
    });

    testWidgets('when the updater does not open, the app stays open', (
      tester,
    ) async {
      final launcher = _Launcher(LaunchResult.failed);
      final calls = _recordWindowCalls();
      final session = await _pumpApp(
        tester,
        updates: _updates('9.9.9', launcher),
      );
      session.controller.document.insert(0, 'changed ');
      await tester.pump();

      await tester.tap(find.text('Update to 9.9.9'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Don’t save'));
      await tester.pumpAndSettle();

      expect(launcher.launches, 1);
      expect(calls, isNot(contains('destroy')));
      expect(find.text("Couldn't open the updater."), findsOneWidget);
      expect(find.text('Update to 9.9.9'), findsOneWidget);
    });
  });
}
