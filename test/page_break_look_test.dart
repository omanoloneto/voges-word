import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

/// Opens a document with a page break and a section break in a window of
/// [width]; narrow windows show the document as one sheet.
Future<EditorSession> _open(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 900);
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
      name: 'breaks.docx',
      bytes: docx.encode(
        Delta()
          ..insert('Before\n')
          ..insert({EmbedTypes.pageBreak: 'page'})
          ..insert('\nAfter\n'),
      ),
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

Finder _inDocument(Finder finder) =>
    find.descendant(of: find.byType(QuillEditor), matching: finder);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('on pages, a page break shows as the next page, not as a mark', (
    tester,
  ) async {
    await _open(tester, 1200);

    expect(_inDocument(find.text('Page break')), findsNothing);
    final editor = tester.state<QuillEditorState>(find.byType(QuillEditor));
    expect(editor.editableTextKey.currentState!.renderEditor.pageCount, 2);
  });

  testWidgets('as one sheet, a page break is marked', (tester) async {
    await _open(tester, 500);

    expect(_inDocument(find.text('Page break')), findsOneWidget);
  });
}
