import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_template.dart';
import 'package:voges_word/document/document_look.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/editor/paper_styles.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';

Map<String, Object?> _lineAttributes(Delta delta, String text) {
  final lines = [
    for (final node in Document.fromDelta(delta).root.children)
      if (node is Block) ...node.children.cast<Line>() else node as Line,
  ];
  final line = lines.firstWhere((l) => l.toPlainText() == '$text\n');
  return {
    for (final entry in line.style.attributes.entries)
      entry.key: entry.value.value,
  };
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('reads the indents and spacing of each paragraph', () {
    final codec = DocxCodec(TableStore());
    final school = codec.create(DocumentTemplate.schoolWork);
    expect(school.look.body.firstLine, closeTo(35.45, 0.01));
    expect(school.look.heading(1).firstLine, 0);

    final bytes = codec.encode(
      Delta()
        ..insert('Normal')
        ..insert('\n')
        ..insert('Quote')
        ..insert('\n', {
          'indent': 3,
          HiddenAttributes.paragraphProperties:
              '<w:pPr><w:spacing w:before="240"/>'
              '<w:ind w:left="2160" w:right="567" w:firstLine="0"/></w:pPr>',
        }),
      source: school.source,
    );
    final delta = codec.decode(bytes).delta;

    expect(_lineAttributes(delta, 'Normal'), isNot(contains('vw-fl')));
    final quote = _lineAttributes(delta, 'Quote');
    expect(quote[HiddenAttributes.spaceBefore], 12);
    expect(quote[HiddenAttributes.indentRight], closeTo(28.35, 0.01));
    expect(quote[HiddenAttributes.firstLine], 0);
    expect(quote, isNot(contains(HiddenAttributes.spaceAfter)));
  });

  test('paragraphs of one style with contextual spacing add no space '
      'between them', () {
    final document = Document.fromDelta(
      Delta()
        ..insert('A')
        ..insert('\n', {'vw-ctx': 'Lista', 'vw-sb': 6, 'vw-sa': 6})
        ..insert('B')
        ..insert('\n', {'vw-ctx': 'Lista', 'vw-sb': 6, 'vw-sa': 6})
        ..insert('C\n'),
    );
    final lines = document.root.children.cast<Line>().toList();
    const look = DocumentLook();

    final first = paragraphFormat(lines[0], look)!;
    final second = paragraphFormat(lines[1], look)!;
    final third = paragraphFormat(lines[2], look)!;
    expect((first.spaceBefore, first.spaceAfter), (6, 0));
    expect((second.spaceBefore, second.spaceAfter), (0, 6));
    expect(third.spaceAfter, look.body.spaceAfter);
  });

  testWidgets('the first-line indent shows and the caret moves with it', (
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
    final school = docx.create(DocumentTemplate.schoolWork);
    final bytes = docx.encode(
      Delta()
        ..insert('Com recuo')
        ..insert('\n')
        ..insert('Sem recuo')
        ..insert('\n', {
          HiddenAttributes.paragraphProperties:
              '<w:pPr><w:ind w:firstLine="0"/></w:pPr>',
        }),
      source: school.source,
    );
    session.open(OpenedFile(name: 'abnt.docx', bytes: bytes));
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

    final editor = tester
        .state<EditorState>(find.byType(QuillRawEditor))
        .renderEditor;
    Offset caret(int offset) => editor
        .getEndpointsForSelection(TextSelection.collapsed(offset: offset))
        .single
        .point;
    final indented = caret(0).dx;
    final plain = caret('Com recuo\n'.length).dx;
    expect(indented - plain, closeTo(35.45 * pointsToPixels, 1));

    final selection = editor.getEndpointsForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 3),
    );
    expect(selection.first.point.dx, closeTo(indented, 0.5));

    await tester.tapAt(
      editor.localToGlobal(Offset(plain + 4, caret(0).dy - 6)),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(session.controller.selection.baseOffset, 0);
  });
}
