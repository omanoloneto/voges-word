import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/headers_footers.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_screen.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/editor/embeds/embed_builders.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';
import 'package:voges_word/l10n/l10n.dart';
import 'package:voges_word/print/page_renderer.dart';
import 'package:voges_word/print/pdf_document.dart';

/// Inflated content of each small stream (the text of the pages).
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

Uint8List _png(int width, int height) => img.encodePng(
  img.Image(width: width, height: height)..clear(img.ColorRgb8(40, 90, 200)),
);

ParagraphSpec _picture(int width, int height) => ParagraphSpec([
  ImageSpec(
    _png(width, height),
    'image/png',
    width: width.toDouble(),
    height: height.toDouble(),
  ),
]);

/// Two pages with a header, pictures and a table with a picture in a cell.
DocumentSpec _report() => DocumentSpec()
  ..headers[PageVariant.normal] = [
    const ParagraphSpec([TextSpec('Running head')]),
  ]
  ..body.addAll([
    const ParagraphSpec([TextSpec('Pictures')]),
    _picture(40, 20),
    _picture(30, 30),
    const ParagraphSpec([BreakSpec(BreakKind.page)]),
    TableSpec([
      RowSpec([
        const CellSpec([
          ParagraphSpec([TextSpec('A cell')]),
        ]),
        CellSpec([_picture(20, 40)]),
      ]),
    ]),
    _picture(50, 10),
  ]);

/// A session with [spec] open but not shown, so only the PDF draws it.
EditorSession _openUnshown(DocumentSpec spec) {
  final tables = TableStore();
  final docx = DocxCodec(tables);
  return EditorSession(
    docx: docx,
    plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
    files: DocumentFiles(),
    tables: tables,
  )..open(
    OpenedFile(name: 'report.docx', bytes: DocxBuilder(spec).build().encode()),
  );
}

Future<BuildContext> _blankScreen(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(),
    ),
  );
  return tester.element(find.byType(Scaffold));
}

List<QuillController> _cells(TableStore tables) => [
  for (final table in tables.all)
    for (final row in table.rows)
      for (final cell in row.cells) cell.controller,
];

// ignore: invalid_use_of_protected_member
bool _isListened(QuillController controller) => controller.hasListeners;

/// The widget states, render objects and layers made while [during] runs,
/// and those it left undisposed.
class _Made {
  final all = <Object>[];
  final undisposed = <Object>{};

  void _record(ObjectEvent event) {
    final object = event.object;
    if (object is! State && object is! RenderObject && object is! Layer) {
      return;
    }
    if (event is ObjectCreated) {
      all.add(object);
      undisposed.add(object);
    } else if (event is ObjectDisposed) {
      undisposed.remove(object);
    }
  }

  Future<T> during<T>(Future<T> Function() action) async {
    FlutterMemoryAllocations.instance.addListener(_record);
    try {
      return await action();
    } finally {
      FlutterMemoryAllocations.instance.removeListener(_record);
    }
  }
}

/// Builds the PDF of [_report], which no screen shows, and checks that
/// nothing it drew is left once it ends. Returns the PDF, or the error that
/// stopped it.
Future<Object?> _pdfLeavingNothing(
  WidgetTester tester, {
  ValueChanged<(int, int)>? onProgress,
}) async {
  imageCache
    ..clear()
    ..clearLiveImages();
  final session = _openUnshown(_report());
  final context = await _blankScreen(tester);
  final cells = _cells(session.tables);
  expect(cells.where(_isListened), isEmpty);

  final made = _Made();
  final outcome = await made.during(
    () => tester.runAsync<Object>(() async {
      try {
        return await documentPdf(context, session, onProgress: onProgress);
      } on StateError catch (error) {
        return error;
      }
    }),
  );
  // precacheImage keeps its pictures live until the end of the next frame.
  tester.binding.scheduleFrame();
  await tester.pump();

  // Each picture widget holds its picture in the registry until disposed.
  expect(made.all.whereType<State<EmbeddedImage>>(), hasLength(4));
  expect(made.undisposed, isEmpty);
  expect(imageCache.liveImageCount, 0);
  expect(cells.where(_isListened), isEmpty);
  return outcome;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('builds a PDF with a correct xref and searchable text', () {
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

  testWidgets('the document PDF has the editor pages and the text', (
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
        language: AppLanguage(),
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

  testWidgets(
    'the PDF lets go of the pages it drew: no picture stays live, no table cell keeps its listeners, no widget state, render object or layer is left',
    (tester) async {
      final pdf = await _pdfLeavingNothing(tester);

      expect(latin1.decode(pdf! as Uint8List), contains('/Count 2'));
    },
  );

  testWidgets('the PDF lets go of the pages it drew when it stops partway', (
    tester,
  ) async {
    final error = await _pdfLeavingNothing(
      tester,
      onProgress: (progress) {
        if (progress.$1 == 2) throw StateError('Stopped');
      },
    );

    expect(
      error,
      isA<StateError>().having((error) => error.message, 'message', 'Stopped'),
    );
  });
}
