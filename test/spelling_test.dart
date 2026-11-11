import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';
import 'package:voges_word/spell/spell_checker.dart';
import 'package:voges_word/spell/spelling_editor.dart';

/// Flags every "hause" as a mistake and suggests "house".
class _FakeBackend implements SpellBackend {
  var calls = 0;

  @override
  Future<List<List<Misspelling>>> check(
    List<String> texts,
    String language,
  ) async {
    calls++;
    return [
      for (final text in texts)
        [
          for (final match in RegExp('hause').allMatches(text))
            Misspelling(match.start, match.end, const ['house', 'horse']),
        ],
    ];
  }
}

/// Flags every "hause" without suggestions, and suggests "house" and
/// "horse" when asked, as the system's checker on macOS.
class _AskedBackend implements SpellBackend, SpellSuggester {
  final asked = <String>[];

  @override
  Future<List<List<Misspelling>>> check(
    List<String> texts,
    String language,
  ) async => [
    for (final text in texts)
      [
        for (final match in RegExp('hause').allMatches(text))
          Misspelling(match.start, match.end, const []),
      ],
  ];

  @override
  Future<List<String>> suggest(String word, String language) async {
    asked.add(word);
    return const ['house', 'horse'];
  }
}

Future<EditorSession> _show(WidgetTester tester, SpellChecker checker) async {
  tester.view.physicalSize = const Size(1200, 900);
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
  session.open(
    OpenedFile(
      name: 'text.docx',
      bytes: docx.encode(Delta()..insert('My hause is blue\n')),
    ),
  );
  await tester.pumpWidget(
    VogesWordApp(
      session: session,
      systemOpen: SystemOpen(files),
      recents: RecentFiles(files),
      fonts: FontCatalog(
        listSystemFonts: () async => const [],
        readGoogleCatalog: () async => '',
      ),
      launchArguments: const [],
      language: AppLanguage(),
      spelling: checker,
    ),
  );
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
  return session;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('checks in the background, ignores and turns off', () async {
    final checker = SpellChecker(_FakeBackend());
    addTearDown(checker.dispose);
    const text = 'My hause is blue';

    expect(checker.misspellingsOf(text), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(checker.misspellingsOf(text)!.single.start, 3);

    checker.ignore('Hause');
    expect(checker.misspellingsOf(text), isEmpty);

    checker.enabled = false;
    expect(checker.misspellingsOf('another hause'), isNull);
  });

  testWidgets('underlines the word and a suggestion replaces it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
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
    session.open(
      OpenedFile(
        name: 'text.docx',
        bytes: docx.encode(Delta()..insert('My hause is blue\n')),
      ),
    );
    final checker = SpellChecker(_FakeBackend());
    addTearDown(checker.dispose);
    await tester.pumpWidget(
      VogesWordApp(
        session: session,
        systemOpen: SystemOpen(files),
        recents: RecentFiles(files),
        fonts: FontCatalog(
          listSystemFonts: () async => const [],
          readGoogleCatalog: () async => '',
        ),
        launchArguments: const [],
        language: AppLanguage(),
        spelling: checker,
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    final spans = <TextSpan>[];
    for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
      text.text.visitChildren((span) {
        if (span is TextSpan) spans.add(span);
        return true;
      });
    }
    final marked = spans.where(
      (span) => span.style?.decorationStyle == TextDecorationStyle.wavy,
    );
    expect(marked.map((span) => span.text), ['hause']);

    session.controller.updateSelection(
      const TextSelection.collapsed(offset: 5),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();
    final state = tester.state<QuillRawEditorState>(
      find.byType(QuillRawEditor),
    );
    final menu =
        spellingContextMenu(checker)(state.context, state)
            as TextFieldTapRegion;
    final toolbar = menu.child! as AdaptiveTextSelectionToolbar;
    final labels = toolbar.buttonItems!.map((item) => item.label).toList();
    expect(labels.take(3), ['house', 'horse', 'Ignore “hause”']);

    toolbar.buttonItems!.first.onPressed!();
    await tester.pumpAndSettle();
    expect(session.controller.document.toPlainText(), 'My house is blue\n');
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('the menu of a word asks for its suggestions when it opens', (
    tester,
  ) async {
    final backend = _AskedBackend();
    final checker = SpellChecker(backend);
    addTearDown(checker.dispose);
    final session = await _show(tester, checker);
    expect(backend.asked, isEmpty, reason: 'checking finds no suggestions');

    session.controller.updateSelection(
      const TextSelection.collapsed(offset: 5),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();
    final state = tester.state<QuillRawEditorState>(
      find.byType(QuillRawEditor),
    );
    final entry = OverlayEntry(
      builder: (context) => spellingContextMenu(checker)(context, state),
    );
    Overlay.of(state.context).insert(entry);
    addTearDown(
      () => entry
        ..remove()
        ..dispose(),
    );
    await tester.pumpAndSettle();

    expect(backend.asked, ['hause']);
    await tester.tap(find.text('house'));
    await tester.pumpAndSettle();
    expect(session.controller.document.toPlainText(), 'My house is blue\n');
    await tester.pump(const Duration(milliseconds: 500));
  });
}
