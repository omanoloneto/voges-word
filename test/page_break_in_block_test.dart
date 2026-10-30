import 'dart:convert';

import 'package:flutter/rendering.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_screen.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';
import 'package:voges_word/print/page_renderer.dart';

/// 'Introduction', then a paragraph with [attributes] that starts with a
/// page break, as Word saves a break typed at the start of a paragraph.
Delta _chapter(Map<String, Object?>? attributes) => Delta()
  ..insert('Introduction\n')
  ..insert({EmbedTypes.pageBreak: 'page'})
  ..insert('Chapter one')
  ..insert('\n', attributes)
  ..insert('More text\n');

Future<EditorSession> _show(WidgetTester tester, Delta content) async {
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
  session.open(OpenedFile(name: 'chapter.docx', bytes: docx.encode(content)));
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

RenderEditor _editor(WidgetTester tester) =>
    tester.state<EditorState>(find.byType(QuillRawEditor)).renderEditor;

/// Where the line that holds [offset] starts, in the editor.
double _lineTop(RenderEditor editor, int offset) {
  RenderBox box = editor.childAtPosition(TextPosition(offset: offset));
  if (box is RenderEditableContainerBox) {
    final local = offset - box.container.documentOffset;
    box = box.childAtPosition(TextPosition(offset: local));
  }
  return box.localToGlobal(Offset.zero, ancestor: editor).dy;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final blocks = <String, Map<String, Object?>?>{
    'plain': null,
    'centered': {'align': 'center'},
    'list item': {'list': 'bullet'},
    'indented': {'indent': 1},
  };
  for (final MapEntry(key: name, value: attributes) in blocks.entries) {
    testWidgets('a page break at the start of a $name paragraph starts a page '
        'in the editor and in the PDF', (tester) async {
      final session = await _show(tester, _chapter(attributes));
      final document = session.controller.document;
      final text = document.toPlainText();
      final chapter = text.indexOf('Chapter one');
      final line = document.queryChild(chapter).node! as Line;
      expect(line.children.first, isA<Embed>(), reason: 'the break opens it');
      expect(line.parent is Block, attributes != null);

      final editor = _editor(tester);
      final layout = editor.pageLayout!;
      expect(editor.pageCount, 2);
      final introduction = editor.getLocalRectForCaret(
        const TextPosition(offset: 0),
      );
      final caret = editor.getLocalRectForCaret(TextPosition(offset: chapter));
      expect(layout.pageAt(introduction.top), 0);
      expect(layout.pageAt(caret.top), 1);
      expect(_lineTop(editor, chapter), layout.contentTop(1));

      final context = tester.element(find.byType(EditorScreen));
      final pdf = (await tester.runAsync(() => documentPdf(context, session)))!;
      expect(latin1.decode(pdf), contains('/Count 2'));
    });
  }
}
