import 'package:flutter/rendering.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
// ignore: implementation_imports
import 'package:flutter_quill/src/editor/widgets/text/text_line.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_template.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';

/// Opens [delta] in the school work template, whose body paragraphs have a
/// first-line indent.
Future<EditorSession> _open(WidgetTester tester, Delta delta) async {
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
  final school = docx.create(DocumentTemplate.schoolWork);
  session.open(
    OpenedFile(
      name: 'book.docx',
      bytes: docx.encode(delta, source: school.source),
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
    ),
  );
  await tester.pumpAndSettle();
  return session;
}

Delta _paragraphs(int count, {Map<String, dynamic>? attributes}) {
  final delta = Delta();
  for (var i = 0; i < count; i++) {
    delta
      ..insert('Paragraph $i goes on for a while, as body text does.')
      ..insert('\n', attributes);
  }
  return delta;
}

/// Opens twelve paragraphs with [attributes], and checks they are on their
/// own or in one block, as meant.
Future<EditorSession> _openParagraphs(
  WidgetTester tester,
  Map<String, dynamic>? attributes,
) async {
  final session = await _open(tester, _paragraphs(12, attributes: attributes));
  expect(
    session.controller.document.root.children.whereType<Block>(),
    hasLength(attributes == null ? 0 : 1),
  );
  return session;
}

int _startOf(EditorSession session, int index) =>
    session.controller.document.toPlainText().indexOf('Paragraph $index ');

/// The picture each paragraph painted, by its first words. A paragraph that
/// was laid out or painted again has a new one.
Map<String, Layer?> _pictures(WidgetTester tester) => {
  for (final line in tester.renderObjectList<RenderEditableTextLine>(
    find.byType(EditableTextLine),
  ))
    line.line.toPlainText().split(' goes').first.trim():
        line.debugLayer?.firstChild,
};

List<String> _repainted(Map<String, Layer?> before, Map<String, Layer?> after) {
  return [
    for (final entry in after.entries)
      if (!identical(before[entry.key], entry.value)) entry.key,
  ];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (where, attributes) in <(String, Map<String, dynamic>?)>[
    ('', null),
    (' in a justified block', {'align': 'justify'}),
  ]) {
    testWidgets('typing paints only the paragraph typed in$where', (
      tester,
    ) async {
      final session = await _openParagraphs(tester, attributes);
      final controller = session.controller;
      controller.updateSelection(
        const TextSelection.collapsed(offset: 3),
        ChangeSource.local,
      );
      await tester.pump();
      final before = _pictures(tester);
      expect(before, hasLength(12));
      expect(before.values, everyElement(isNotNull));

      controller.replaceText(
        3,
        0,
        'x',
        const TextSelection.collapsed(offset: 4),
      );
      await tester.pump();

      expect(_repainted(before, _pictures(tester)), ['Parxagraph 0']);
    });

    testWidgets('moving the caret paints only the paragraphs it left and '
        'entered$where', (tester) async {
      final session = await _openParagraphs(tester, attributes);
      final controller = session.controller;
      controller.updateSelection(
        TextSelection.collapsed(offset: _startOf(session, 1) + 2),
        ChangeSource.local,
      );
      await tester.pump();
      final before = _pictures(tester);

      controller.updateSelection(
        TextSelection.collapsed(offset: _startOf(session, 4) + 2),
        ChangeSource.local,
      );
      await tester.pump();

      expect(_repainted(before, _pictures(tester)), [
        'Paragraph 1',
        'Paragraph 4',
      ]);
    });

    testWidgets('a new paragraph paints only itself and the one it was cut '
        'from$where', (tester) async {
      final session = await _openParagraphs(tester, attributes);
      final controller = session.controller;
      final split = _startOf(session, 5) + 'Paragraph 5 goes on'.length;
      controller.updateSelection(
        TextSelection.collapsed(offset: split),
        ChangeSource.local,
      );
      await tester.pump();
      final before = _pictures(tester);

      controller.replaceText(
        split,
        0,
        '\n',
        TextSelection.collapsed(offset: split + 1),
      );
      await tester.pump();

      expect(_repainted(before, _pictures(tester)), [
        'Paragraph 5',
        'for a while, as body text does.',
      ]);
    });

    testWidgets('moving the end of a selection paints only the paragraph it '
        'ends in$where', (tester) async {
      final session = await _openParagraphs(tester, attributes);
      final controller = session.controller;
      final end = controller.document.length - 1;
      controller.updateSelection(
        TextSelection(baseOffset: 0, extentOffset: end),
        ChangeSource.local,
      );
      await tester.pump();
      final before = _pictures(tester);

      controller.updateSelection(
        TextSelection(baseOffset: 0, extentOffset: end - 1),
        ChangeSource.local,
      );
      await tester.pump();

      expect(_repainted(before, _pictures(tester)), ['Paragraph 11']);
    });
  }
}
