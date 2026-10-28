import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_screen.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/print/page_renderer.dart';
import 'package:voges_word/print/pdf_document.dart';

/// Conteúdo descomprimido de cada stream pequeno (texto das páginas).
List<String> _contentStreams(Uint8List pdf) {
  final text = latin1.decode(pdf);
  final streams = <String>[];
  for (final match in RegExp(r'/Length (\d+) >>\nstream\n').allMatches(text)) {
    final length = int.parse(match[1]!);
    final start = match.end;
    final bytes = pdf.sublist(start, start + length);
    final inflated = const ZLibDecoder().decodeBytes(bytes);
    if (inflated.length < 100000) streams.add(latin1.decode(inflated));
  }
  return streams;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('monta PDF com xref certo e texto pesquisável', () {
    final builder = PdfBuilder();
    for (final text in ['Olá (mundo)', 'Ação — fim']) {
      builder.addPage(
        PdfPageContent(
          size: const Size(595.3, 841.9),
          imageWidth: 2,
          imageHeight: 2,
          rgb: Uint8List.fromList(List.filled(12, 255)),
          lines: [(const Rect.fromLTWH(85, 71, 200, 14), text)],
        ),
      );
    }
    final pdf = builder.build(title: 'Relatório');
    final text = latin1.decode(pdf);

    expect(text, startsWith('%PDF-1.4'));
    expect(text, contains('/Count 2'));
    expect(text.trimRight(), endsWith('%%EOF'));
    final xref = int.parse(RegExp(r'startxref\n(\d+)').firstMatch(text)![1]!);
    final offsets = RegExp(
      r'(\d{10}) 00000 n',
    ).allMatches(text.substring(xref)).map((m) => int.parse(m[1]!)).toList();
    for (var id = 1; id <= offsets.length; id++) {
      expect(text.substring(offsets[id - 1]), startsWith('$id 0 obj'));
    }

    final streams = _contentStreams(pdf).join('\n');
    expect(streams, contains('(Olá \\(mundo\\)) Tj'));
    expect(streams, contains('(Ação \u0097 fim) Tj'));
  });

  testWidgets('PDF do documento tem as páginas do editor e o texto', (
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
    final words = List.generate(700, (i) => 'palavra$i').join(' ');
    session.open(
      OpenedFile(
        name: 'longo.docx',
        bytes: docx.encode(Delta()..insert('Começo $words FIM\n')),
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
      ),
    );
    await tester.pumpAndSettle();
    final pages = tester
        .state<EditorState>(find.byType(QuillRawEditor))
        .renderEditor
        .pageCount;
    expect(pages, greaterThan(1));

    final context = tester.element(find.byType(EditorScreen));
    final pdf = (await tester.runAsync(() => documentPdf(context, session)))!;
    final text = latin1.decode(pdf);

    expect(text, contains('/Count $pages'));
    final streams = _contentStreams(pdf).join('\n');
    expect(streams, contains('Começo palavra0'));
    expect(streams, contains('FIM'));
  });
}
