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

Delta _paragraphs(int count) {
  final delta = Delta();
  for (var i = 0; i < count; i++) {
    delta.insert('Paragraph $i goes on for a while, as body text does.\n');
  }
  return delta;
}

/// The picture each paragraph painted, by its first words. A paragraph that
/// was laid out or painted again has a new one.
Map<String, Layer?> _pictures(WidgetTester tester) => {
  for (final line in tester.renderObjectList<RenderEditableTextLine>(
    find.byType(EditableTextLine),
  ))
    line.line.toPlainText().split(' goes').first: line.debugLayer?.firstChild,
};

List<String> _repainted(Map<String, Layer?> before, Map<String, Layer?> after) {
  return [
    for (final entry in after.entries)
      if (!identical(before[entry.key], entry.value)) entry.key,
  ];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('typing paints only the paragraph typed in', (tester) async {
    final session = await _open(tester, _paragraphs(12));
    final controller = session.controller;
    controller.updateSelection(
      const TextSelection.collapsed(offset: 3),
      ChangeSource.local,
    );
    await tester.pump();
    final before = _pictures(tester);
    expect(before, hasLength(12));
    expect(before.values, everyElement(isNotNull));

    controller.replaceText(3, 0, 'x', const TextSelection.collapsed(offset: 4));
    await tester.pump();

    expect(_repainted(before, _pictures(tester)), ['Parxagraph 0']);
  });

  testWidgets('moving the caret paints only the paragraphs it left and '
      'entered', (tester) async {
    final session = await _open(tester, _paragraphs(12));
    final controller = session.controller;
    final second = controller.document.root.children.elementAt(1);
    final fifth = controller.document.root.children.elementAt(4);
    controller.updateSelection(
      TextSelection.collapsed(offset: second.documentOffset + 2),
      ChangeSource.local,
    );
    await tester.pump();
    final before = _pictures(tester);

    controller.updateSelection(
      TextSelection.collapsed(offset: fifth.documentOffset + 2),
      ChangeSource.local,
    );
    await tester.pump();

    expect(_repainted(before, _pictures(tester)), [
      'Paragraph 1',
      'Paragraph 4',
    ]);
  });
}
