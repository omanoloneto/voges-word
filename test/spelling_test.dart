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
import 'package:voges_word/spell/spell_checker.dart';
import 'package:voges_word/spell/spelling_editor.dart';

/// Marca como erro toda ocorrência de "caza" e sugere "casa".
class _FakeBackend implements SpellBackend {
  var calls = 0;

  @override
  Future<List<List<Misspelling>>> check(List<String> texts) async {
    calls++;
    return [
      for (final text in texts)
        [
          for (final match in RegExp('caza').allMatches(text))
            Misspelling(match.start, match.end, const ['casa', 'caça']),
        ],
    ];
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('verifica em segundo plano, ignora e desliga', () async {
    final checker = SpellChecker(_FakeBackend());
    addTearDown(checker.dispose);
    const text = 'Minha caza é azul';

    expect(checker.misspellingsOf(text), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(checker.misspellingsOf(text)!.single.start, 6);

    checker.ignore('Caza');
    expect(checker.misspellingsOf(text), isEmpty);

    checker.enabled = false;
    expect(checker.misspellingsOf('outra caza'), isNull);
  });

  testWidgets('sublinha a palavra e a sugestão troca o texto', (tester) async {
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
        name: 'texto.docx',
        bytes: docx.encode(Delta()..insert('Minha caza é azul\n')),
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
    expect(marked.map((span) => span.text), ['caza']);

    session.controller.updateSelection(
      const TextSelection.collapsed(offset: 8),
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
    expect(labels.take(3), ['casa', 'caça', 'Ignorar "caza"']);

    toolbar.buttonItems!.first.onPressed!();
    await tester.pumpAndSettle();
    expect(session.controller.document.toPlainText(), 'Minha casa é azul\n');
    await tester.pump(const Duration(milliseconds: 500));
  });
}
