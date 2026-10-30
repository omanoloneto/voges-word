import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/editor/status_bar.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/recovery.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';

/// A .docx with [body] at the start and [header] on every page, written as
/// Word writes them.
Uint8List _wordFile(String body, {String? header}) {
  final package = DocxPackage.decode(
    DocxCodec(TableStore()).encode(Delta()..insert('Body\n')),
  );
  final main = package.mainDocumentPath;
  var document = package.text(main)!.replaceFirst('<w:body>', '<w:body>$body');
  if (header != null) {
    package.setText(
      'word/header1.xml',
      '<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/'
          '2006/main" xmlns:v="urn:schemas-microsoft-com:vml">$header</w:hdr>',
    );
    package.addRelationships(main, const [
      Relationship(
        id: 'rIdHeader',
        type: RelationshipTypes.header,
        target: 'header1.xml',
      ),
    ]);
    package.ensureContentTypes(
      overrides: {
        '/word/header1.xml':
            'application/vnd.openxmlformats-officedocument.'
            'wordprocessingml.header+xml',
      },
    );
    document = document.replaceFirst(
      '<w:sectPr>',
      '<w:sectPr><w:headerReference w:type="default" r:id="rIdHeader"/>',
    );
  }
  package.setText(main, document);
  return package.encode();
}

const _equation =
    '<w:p><m:oMathPara><m:oMath><m:r><m:t>E=mc2</m:t></m:r></m:oMath>'
    '</m:oMathPara></w:p>';

const _chart =
    '<w:p><w:r><w:drawing><wp:inline><wp:extent cx="5486400" cy="3200400"/>'
    '<wp:docPr id="1" name="Chart 1"/><a:graphic><a:graphicData '
    'uri="http://schemas.openxmlformats.org/drawingml/2006/chart">'
    '<c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"'
    ' r:id="rId99"/></a:graphicData></a:graphic></wp:inline></w:drawing>'
    '</w:r></w:p>';

const _tableOfContents =
    '<w:sdt><w:sdtPr><w:docPartObj><w:docPartGallery w:val="Table of '
    'Contents"/></w:docPartObj></w:sdtPr><w:sdtContent><w:p><w:r><w:t>'
    'Contents</w:t></w:r></w:p></w:sdtContent></w:sdt>';

const _footnote =
    '<w:p><w:r><w:t>Cited</w:t></w:r><w:r><w:rPr><w:vertAlign '
    'w:val="superscript"/></w:rPr><w:footnoteReference w:id="1"/></w:r>'
    '</w:p>';

const _pageField =
    '<w:p><w:fldSimple w:instr=" PAGE "><w:r><w:t>1</w:t>'
    '</w:r></w:fldSimple></w:p>';

String _inTable(String content) =>
    '<w:tbl><w:tblGrid><w:gridCol w:w="9000"/></w:tblGrid><w:tr><w:tc>'
    '$content</w:tc></w:tr></w:tbl>';

const _wordContentNotes = [
  (
    DocumentFormat.odt,
    'OpenDocument',
    '.odt files don’t keep equations, charts and other Word content as they '
        'are. Use “Save as” to keep them.',
  ),
  (
    DocumentFormat.rtf,
    'RTF',
    '.rtf files don’t keep equations, charts and other Word content as they '
        'are. Use “Save as” to keep them.',
  ),
];

/// Pumps the app with a document whose file is in [format].
Future<void> _pumpWithFormat(
  WidgetTester tester,
  DocumentFormat format, {
  Size size = const Size(1200, 900),
  Locale? locale,
  Uint8List? content,
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
  session.restore(
    RecoverySnapshot(
      name: 'file.${format.extension}',
      format: format,
      content: DocumentFormat.docx,
      bytes: content ?? docx.encode(Delta()..insert('Body\n')),
      savedAt: DateTime(2026, 10, 29),
    ),
    keepPath: false,
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
      language: AppLanguage(locale),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _inStatusBar(Finder finder) =>
    find.descendant(of: find.byType(StatusBar), matching: finder);

const _notes = [
  (
    DocumentFormat.plainText,
    'Plain text',
    '.txt files keep only the text. Use “Save as” to keep the formatting.',
  ),
  (
    DocumentFormat.markdown,
    'Markdown',
    '.md files keep only basic formatting. Use “Save as” to keep all of it.',
  ),
  (
    DocumentFormat.html,
    'Web page',
    'Web pages don’t keep the page setup, headers or footers. '
        'Use “Save as” to keep them.',
  ),
  (
    DocumentFormat.doc,
    'Word 97–2003',
    'Voges Word doesn’t write Word 97–2003 files: saving creates a .docx '
        'copy and leaves the original untouched.',
  ),
  (
    DocumentFormat.docm,
    'Word with macros',
    'Macros are kept when you save, but Voges Word never runs them. '
        '“Save as” creates a .docx without them.',
  ),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (format, label, message) in _notes) {
    testWidgets('a .${format.extension} file shows “$label” and why', (
      tester,
    ) async {
      await _pumpWithFormat(tester, format);

      expect(_inStatusBar(find.text(label)), findsOneWidget);
      expect(_inStatusBar(find.byTooltip(message)), findsOneWidget);
    });
  }

  for (final format in [
    DocumentFormat.docx,
    DocumentFormat.odt,
    DocumentFormat.rtf,
  ]) {
    testWidgets('a .${format.extension} file shows no note', (tester) async {
      await _pumpWithFormat(tester, format);

      expect(_inStatusBar(find.byType(Tooltip)), findsNothing);
    });
  }

  for (final (format, label, message) in _wordContentNotes) {
    for (final (kind, body) in [
      ('an equation', _equation),
      ('a chart', _chart),
      ('a table of contents', _tableOfContents),
      ('an equation in a table', _inTable(_equation)),
    ]) {
      testWidgets('a .${format.extension} file with $kind warns of it', (
        tester,
      ) async {
        await _pumpWithFormat(tester, format, content: _wordFile(body));

        expect(_inStatusBar(find.text(label)), findsOneWidget);
        expect(_inStatusBar(find.byTooltip(message)), findsOneWidget);
        expect(
          _inStatusBar(find.byIcon(Icons.warning_amber_rounded)),
          findsOneWidget,
        );
      });
    }

    testWidgets('notes and page numbers in a .${format.extension} file '
        'show no note', (tester) async {
      await _pumpWithFormat(
        tester,
        format,
        content: _wordFile('$_footnote$_pageField'),
      );

      expect(_inStatusBar(find.byType(Tooltip)), findsNothing);
    });
  }

  testWidgets('a text box in the header of a .odt file warns of it', (
    tester,
  ) async {
    await _pumpWithFormat(
      tester,
      DocumentFormat.odt,
      content: _wordFile(
        '',
        header:
            '<w:p><w:r><w:pict><v:shape><v:textbox><w:txbxContent><w:p><w:r>'
            '<w:t>Draft</w:t></w:r></w:p></w:txbxContent></v:textbox>'
            '</v:shape></w:pict></w:r></w:p>',
      ),
    );

    expect(_inStatusBar(find.text('OpenDocument')), findsOneWidget);
  });

  testWidgets('a .docx keeps equations and charts, so it shows no note', (
    tester,
  ) async {
    await _pumpWithFormat(
      tester,
      DocumentFormat.docx,
      content: _wordFile('$_equation$_chart'),
    );

    expect(_inStatusBar(find.byType(Tooltip)), findsNothing);
  });

  testWidgets('the warning goes with the last equation', (tester) async {
    await _pumpWithFormat(
      tester,
      DocumentFormat.odt,
      content: _wordFile(_equation),
    );
    final session = tester.widget<StatusBar>(find.byType(StatusBar)).session;
    expect(_inStatusBar(find.text('OpenDocument')), findsOneWidget);

    session.controller.replaceText(
      0,
      session.controller.document.length - 1,
      'Text',
      null,
    );
    await tester.pump(const Duration(seconds: 1));

    expect(_inStatusBar(find.text('OpenDocument')), findsNothing);
  });

  testWidgets('losses are warnings; the rest are information', (tester) async {
    await _pumpWithFormat(tester, DocumentFormat.html);
    expect(
      _inStatusBar(find.byIcon(Icons.warning_amber_rounded)),
      findsOneWidget,
    );

    await _pumpWithFormat(tester, DocumentFormat.docm);
    expect(_inStatusBar(find.byIcon(Icons.info_outline)), findsOneWidget);
    expect(
      _inStatusBar(find.byIcon(Icons.warning_amber_rounded)),
      findsNothing,
    );
  });

  testWidgets('on a phone the note is an icon that explains itself on tap', (
    tester,
  ) async {
    await _pumpWithFormat(
      tester,
      DocumentFormat.markdown,
      size: const Size(360, 740),
    );
    expect(_inStatusBar(find.text('Markdown')), findsNothing);

    await tester.tap(_inStatusBar(find.byIcon(Icons.warning_amber_rounded)));
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.text(
        '.md files keep only basic formatting. Use “Save as” to keep all of it.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the longest note fits the narrowest window', (tester) async {
    await _pumpWithFormat(
      tester,
      DocumentFormat.plainText,
      size: const Size(480, 600),
      locale: const Locale('es'),
    );

    expect(_inStatusBar(find.text('Texto sin formato')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
