import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/painting.dart' show Color, EdgeInsets;
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/document_look.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/headers_footers.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/docx/image_formats.dart';
import 'package:voges_word/formats/document_codecs.dart';
import 'package:voges_word/odt/odt_codec.dart';
import 'package:xml/xml.dart';

import 'odt_fixtures.dart';

late TableStore _tables;

LoadedDocument _decode(Uint8List bytes) {
  _tables = TableStore();
  return OdtCodec(DocxCodec(_tables)).decode(bytes);
}

String _plain(Delta delta) => [
  for (final operation in delta.toList())
    if (operation.data is String) operation.data as String,
].join();

/// Text parts by name; pictures are listed without content.
Map<String, String> _parts(Uint8List bytes) => {
  for (final file in ZipDecoder().decodeBytes(bytes).files)
    if (file.isFile)
      file.name: file.name.startsWith('Pictures/')
          ? ''
          : utf8.decode(file.content),
};

HeaderFooterStory _story(Delta delta) =>
    HeaderFooterStory(delta: delta, edited: true);

XmlDocument _xml(Uint8List bytes, String part) =>
    XmlDocument.parse(_parts(bytes)[part]!);

Iterable<XmlElement> _elements(XmlNode root, String name) =>
    root.descendantElements.where((element) => element.name.qualified == name);

/// The paragraph that holds [text], the innermost one when they nest.
XmlElement _paragraphWith(XmlNode root, String text) => root.descendantElements
    .where(
      (element) =>
          (element.name.qualified == 'text:p' ||
              element.name.qualified == 'text:h') &&
          element.innerText.contains(text),
    )
    .last;

/// Properties of the style named [name], as attributes of [kind] (e.g.
/// `style:paragraph-properties`).
Map<String, String> _styleProperties(XmlNode root, String? name, String kind) {
  final style = _elements(
    root,
    'style:style',
  ).firstWhere((element) => element.getAttribute('style:name') == name);
  return {
    for (final attribute
        in style.getElement(kind)?.attributes ?? const <XmlAttribute>[])
      attribute.name.qualified: attribute.value,
  };
}

const _wordNamespaces =
    'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" '
    'xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" '
    'xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" '
    'xmlns:v="urn:schemas-microsoft-com:vml" '
    'xmlns:o="urn:schemas-microsoft-com:office:office"';

const _letterSection =
    '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" '
    'w:right="1440" w:bottom="1440" w:left="1440" w:header="720" '
    'w:footer="720" w:gutter="0"/></w:sectPr>';

/// Relationships as (id, type, target); web addresses are external.
String _wordRelationships(List<(String, String, String)> relationships) {
  final entries = [
    for (final (id, type, target) in relationships)
      '<Relationship Id="$id" Type="http://schemas.openxmlformats.org/'
          'officeDocument/2006/relationships/$type" Target="$target"'
          '${target.startsWith('http') ? ' TargetMode="External"' : ''}/>',
  ];
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '${entries.join()}</Relationships>';
}

/// A .docx whose body is [body] and [section]; [relationships] belong to the
/// main part and [parts] are added as they are.
Uint8List _docxFile(
  String body, {
  String section = _letterSection,
  List<(String, String, String)> relationships = const [],
  Map<String, Object> parts = const {},
}) => zipOf({
  '[Content_Types].xml':
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Default Extension="png" ContentType="image/png"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '</Types>',
  '_rels/.rels': _wordRelationships([
    ('rId1', 'officeDocument', 'word/document.xml'),
  ]),
  'word/document.xml':
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document $_wordNamespaces><w:body>$body$section</w:body></w:document>',
  'word/styles.xml':
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:styles $_wordNamespaces><w:docDefaults><w:rPrDefault><w:rPr>'
      '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/>'
      '<w:lang w:val="pt-BR" w:eastAsia="en-US" w:bidi="ar-SA"/></w:rPr>'
      '</w:rPrDefault></w:docDefaults>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
      '<w:name w:val="Normal"/></w:style></w:styles>',
  'word/_rels/document.xml.rels': _wordRelationships([
    ('rIdStyles', 'styles', 'styles.xml'),
    ...relationships,
  ]),
  ...parts,
});

String _wordParagraph(String content) => '<w:p>$content</w:p>';

String _wordRun(String text, [String properties = '']) =>
    '<w:r>$properties<w:t xml:space="preserve">$text</w:t></w:r>';

/// What the .docx in [bytes] becomes when it is saved as .odt.
Uint8List _docxToOdt(Uint8List bytes) {
  final codec = DocxCodec(TableStore());
  final loaded = codec.decode(bytes);
  return OdtCodec(codec).encode(
    loaded.delta,
    source: loaded.source,
    look: loaded.look,
    headersFooters: loaded.headersFooters,
  );
}

TableCellModel _cell(
  TableStore tables,
  String text, {
  int span = 1,
  VerticalMerge merge = VerticalMerge.none,
  Color? fill,
  Delta? content,
}) => TableCellModel(
  controller: tables.newCellController(content ?? (Delta()..insert('$text\n'))),
  gridSpan: span,
  verticalMerge: merge,
  fill: fill,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the package: mimetype first and stored, every part listed', () {
    final tables = TableStore();
    final bytes = OdtCodec(DocxCodec(tables)).encode(
      Delta()
        ..insert('Hi ')
        ..insert({EmbedTypes.image: dataUriFromMime(pngPixel, 'image/png')})
        ..insert('\n'),
    );

    final header = ByteData.sublistView(bytes);
    expect(header.getUint32(0, Endian.little), 0x04034B50);
    expect(header.getUint16(8, Endian.little), 0, reason: 'stored');
    expect(header.getUint16(26, Endian.little), 8);
    expect(header.getUint16(28, Endian.little), 0, reason: 'no extra field');
    expect(
      latin1.decode(bytes.sublist(30, 38 + 39)),
      'mimetypeapplication/vnd.oasis.opendocument.text',
    );
    expect(detectFormat('x.odt', bytes)?.format, DocumentFormat.odt);
    expect(detectFormat('x.docx', bytes)?.format, DocumentFormat.odt);

    final parts = _parts(bytes);
    expect(parts.keys, [
      'mimetype',
      'content.xml',
      'styles.xml',
      'meta.xml',
      'META-INF/manifest.xml',
      'Pictures/image1.png',
    ]);
    for (final name in ['content.xml', 'styles.xml', 'meta.xml']) {
      final root = XmlDocument.parse(parts[name]!).rootElement;
      expect(root.getAttribute('office:version'), '1.3', reason: name);
    }
    final manifest = XmlDocument.parse(parts['META-INF/manifest.xml']!);
    final entries = {
      for (final entry in manifest.rootElement.childElements)
        entry.getAttribute('manifest:full-path'): entry.getAttribute(
          'manifest:media-type',
        ),
    };
    expect(entries, {
      '/': 'application/vnd.oasis.opendocument.text',
      'content.xml': 'text/xml',
      'styles.xml': 'text/xml',
      'meta.xml': 'text/xml',
      'Pictures/image1.png': 'image/png',
    });
    final styles = parts['styles.xml']!;
    for (var level = 1; level <= 6; level++) {
      expect(
        styles,
        contains(
          'style:name="Heading_20_$level" style:display-name="Heading $level"',
        ),
      );
    }
  });

  test('a round trip keeps text, formatting, lists, links, tables, pictures, '
      'headers and page setup', () {
    final tables = TableStore();
    final inner = TableModel(
      id: tables.nextId(),
      bordered: false,
      columnWidths: [1500],
      rows: [
        TableRowModel(cells: [_cell(tables, 'inner')]),
      ],
    );
    tables.add(inner);
    final table = TableModel(
      id: tables.nextId(),
      bordered: true,
      columnWidths: [2000, 2000, 4000],
      rows: [
        TableRowModel(
          propertiesXml: '<w:trPr><w:tblHeader/></w:trPr>',
          cells: [
            _cell(tables, 'wide', span: 2, fill: const Color(0xFFD9E2F3)),
            _cell(tables, 'tall', merge: VerticalMerge.restart),
          ],
        ),
        TableRowModel(
          cells: [
            _cell(tables, 'a'),
            _cell(
              tables,
              '',
              content: Delta()
                ..insert({EmbedTypes.table: encodeTableId(inner.id)})
                ..insert('\n'),
            ),
            _cell(tables, '', merge: VerticalMerge.continuation),
          ],
        ),
      ],
    );
    tables.add(table);
    final delta = Delta()
      ..insert('Title')
      ..insert('\n', {'header': 1})
      ..insert('plain ')
      ..insert('bold', {'bold': true})
      ..insert(' ')
      ..insert('mixed', {
        'italic': true,
        'underline': true,
        'strike': true,
        'size': '18',
        'font': 'Courier New',
        'color': '#C00000',
        'background': '#FFFF00',
      })
      ..insert(' x')
      ..insert('2', {'script': 'super'})
      ..insert('\n', {
        'align': 'center',
        'line-height': 1.5,
        HiddenAttributes.spaceBefore: 6,
        HiddenAttributes.spaceAfter: 12,
      })
      ..insert('dot')
      ..insert('\n', {'list': 'bullet'})
      ..insert('nested')
      ..insert('\n', {'list': 'bullet', 'indent': 1})
      ..insert('one')
      ..insert('\n', {'list': 'ordered'})
      ..insert('two')
      ..insert('\n', {'list': 'ordered'})
      ..insert('site', {'link': 'https://example.com/?a=1&b=2'})
      ..insert(' ')
      ..insert('bad', {'link': 'javascript:alert(1)'})
      ..insert('\n')
      ..insert(
        {EmbedTypes.image: dataUriFromMime(pngPixel, 'image/png')},
        {'width': '30', 'height': '20'},
      )
      ..insert('\n')
      ..insert({EmbedTypes.table: encodeTableId(table.id)})
      ..insert('\n')
      ..insert('indented')
      ..insert('\n', {
        'indent': 2,
        HiddenAttributes.firstLine: -18,
        HiddenAttributes.indentRight: 10,
      })
      ..insert('  two  spaces\tand break ')
      ..insert('\n');
    final stories = HeadersFooters(
      headers: {
        PageVariant.normal: _story(Delta()..insert('Header text\n')),
        PageVariant.first: _story(Delta()..insert('First\n')),
      },
      footers: {
        PageVariant.normal: _story(
          Delta()
            ..insert({EmbedTypes.pageNumber: 'PAGE'})
            ..insert('\n', {'align': 'right'}),
        ),
      },
      differentFirstPage: true,
      headerDistance: 30,
      footerDistance: 25,
    );
    const look = DocumentLook(
      pageWidth: 841.9,
      pageHeight: 595.3,
      margins: EdgeInsets.fromLTRB(50, 60, 40, 70),
      body: TextLook(fontSize: 11, fontFamily: 'Georgia', spaceAfter: 6),
      headings: {
        1: TextLook(
          fontSize: 20,
          fontFamily: 'Arial',
          bold: true,
          spaceBefore: 12,
          spaceAfter: 4,
        ),
      },
      lineSpacing: 1.2,
    );

    final bytes = OdtCodec(
      DocxCodec(tables),
    ).encode(delta, look: look, headersFooters: stories);
    final loaded = _decode(bytes);
    final result = loaded.delta;

    expect(lineOf(result, 'Title')?['header'], 1);
    expect(textOperation(result, 'bold').attributes?['bold'], isTrue);
    expect(textOperation(result, 'mixed').attributes, {
      'italic': true,
      'underline': true,
      'strike': true,
      'size': '18',
      'font': 'Courier New',
      'color': '#C00000',
      'background': '#FFFF00',
    });
    expect(textOperation(result, '2').attributes?['script'], 'super');
    expect(lineOf(result, 'mixed'), {
      'align': 'center',
      'line-height': 1.5,
      HiddenAttributes.spaceBefore: 6,
      HiddenAttributes.spaceAfter: 12,
      HiddenAttributes.paragraphProperties: isA<String>(),
    });
    expect(lineOf(result, 'dot')?['list'], 'bullet');
    expect(lineOf(result, 'nested')?['list'], 'bullet');
    expect(lineOf(result, 'nested')?['indent'], 1);
    expect(lineOf(result, 'one')?['list'], 'ordered');
    expect(
      lineOf(result, 'two')?[HiddenAttributes.numbering],
      lineOf(result, 'one')?[HiddenAttributes.numbering],
    );
    expect(
      textOperation(result, 'site').attributes?['link'],
      'https://example.com/?a=1&b=2',
    );
    expect(textOperation(result, 'bad').attributes?['link'], isNull);
    final image = result.toList().firstWhere(
      (operation) =>
          operation.data is Map &&
          (operation.data as Map).containsKey(EmbedTypes.image),
    );
    expect(image.attributes?['width'], '30');
    expect(image.attributes?['height'], '20');
    expect(lineOf(result, 'indented')?['indent'], 2);
    expect(lineOf(result, 'indented')?[HiddenAttributes.firstLine], -18);
    expect(lineOf(result, 'indented')?[HiddenAttributes.indentRight], 10);
    expect(_plain(result), contains('\n  two  spaces\tand break \n'));

    final written =
        _tables[tableIdOf(embedsOf(result, EmbedTypes.table).single)]!;
    expect(written.columnWidths, [2000, 2000, 4000]);
    expect(written.bordered, isTrue);
    expect(written.rows.first.propertiesXml, contains('tblHeader'));
    final first = written.rows.first.cells;
    expect(first.first.gridSpan, 2);
    expect(first.first.fill?.toARGB32(), 0xFFD9E2F3);
    expect(first.last.verticalMerge, VerticalMerge.restart);
    final second = written.rows.last.cells;
    expect(second.last.verticalMerge, VerticalMerge.continuation);
    expect(
      embedsOf(second[1].controller.document.toDelta(), EmbedTypes.table),
      hasLength(1),
    );

    final headers = loaded.headersFooters;
    expect(headers.differentFirstPage, isTrue);
    expect(_plain(headers.headers[PageVariant.normal]!.delta), 'Header text\n');
    expect(_plain(headers.headers[PageVariant.first]!.delta), 'First\n');
    final footer = headers.footers[PageVariant.normal]!.delta;
    expect(opaqueOf(footer).map((content) => fieldNameOf(content.xml)), [
      'PAGE',
    ]);
    expect(lineOf(footer, '')?['align'], 'right');
    expect(headers.headerDistance, 30);
    expect(headers.footerDistance, 25);

    final result_ = loaded.look;
    expect(result_.pageWidth, closeTo(841.9, 0.05));
    expect(result_.pageHeight, closeTo(595.3, 0.05));
    expect(result_.margins, const EdgeInsets.fromLTRB(50, 60, 40, 70));
    expect(result_.body.fontFamily, 'Georgia');
    expect(result_.body.fontSize, 11);
    expect(result_.body.spaceAfter, 6);
    expect(result_.lineSpacing, 1.2);
    expect(result_.headings[1]?.fontSize, 20);
    expect(result_.headings[1]?.fontFamily, 'Arial');
    expect(result_.headings[1]?.bold, isTrue);
    expect(loaded.notices, isEmpty);
  });

  test('lists of any shape nest correctly', () {
    final delta = Delta();
    for (final (text, kind, level) in [
      ('a', 'ordered', 0),
      ('b', 'bullet', 2),
      ('c', 'ordered', 0),
      ('d', 'checked', 1),
      ('e', 'unchecked', 1),
      ('f', 'bullet', 0),
    ]) {
      delta
        ..insert(text)
        ..insert('\n', {'list': kind, 'indent': ?(level == 0 ? null : level)});
    }
    final bytes = OdtCodec(DocxCodec(TableStore())).encode(delta);
    final content = _parts(bytes)['content.xml']!;
    expect(() => XmlDocument.parse(content), returnsNormally);
    expect(content, contains('text:bullet-char="☑"'));
    expect(content, contains('text:bullet-char="☐"'));

    final result = _decode(bytes).delta;
    expect(lineOf(result, 'a')?['list'], 'ordered');
    expect(lineOf(result, 'b')?['list'], 'bullet');
    expect(lineOf(result, 'b')?['indent'], 2);
    expect(lineOf(result, 'c')?['list'], 'ordered');
    expect(
      lineOf(result, 'c')?[HiddenAttributes.numbering],
      lineOf(result, 'a')?[HiddenAttributes.numbering],
    );
    expect(lineOf(result, 'd')?['indent'], 1);
    expect(lineOf(result, 'f')?['list'], 'bullet');
  });

  test('page and section breaks start new pages', () {
    const portrait =
        '<w:sectPr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1417" w:right="1701" '
        'w:bottom="1417" w:left="1701" w:header="708" w:footer="708" w:gutter="0"/>'
        '</w:sectPr>';
    const continuous =
        '<w:sectPr><w:type w:val="continuous"/><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>';
    final delta = Delta()
      ..insert('first')
      ..insert({EmbedTypes.pageBreak: 'page'})
      ..insert('\n')
      ..insert('second')
      ..insert('\n')
      ..insert({EmbedTypes.sectionBreak: encodeSection(portrait)})
      ..insert('\n')
      ..insert('third')
      ..insert('\n')
      ..insert({EmbedTypes.sectionBreak: encodeSection(continuous)})
      ..insert('\n')
      ..insert('fourth')
      ..insert('\n');
    final bytes = OdtCodec(DocxCodec(TableStore())).encode(
      delta,
      look: const DocumentLook(pageWidth: 841.9, pageHeight: 595.3),
    );
    final content = _parts(bytes)['content.xml']!;
    expect(content, contains('fo:break-before="page"'));
    expect(content, contains('style:master-page-name="Section1"'));
    expect(content, contains('style:master-page-name="Standard"'));

    final loaded = _decode(bytes);
    final operations = loaded.delta.toList();
    final second = operations.indexWhere(
      (operation) =>
          operation.data is String &&
          (operation.data as String).startsWith('second'),
    );
    expect(
      (operations[second - 1].data as Map).containsKey(EmbedTypes.pageBreak),
      isTrue,
    );
    final sections = embedsOf(loaded.delta, EmbedTypes.sectionBreak);
    expect(sections, hasLength(1));
    expect(sectionXmlOf(sections.single), contains('w:w="11906"'));
    expect(loaded.look.isLandscape, isTrue);
    expect(_plain(loaded.delta), contains('third\nfourth'));
  });

  test('notes of the opened file are saved as notes', () {
    final codec = OdtCodec(DocxCodec(TableStore()));
    final loaded = codec.decode(
      odtFile(
        body:
            '<text:p>see<text:note text:note-class="footnote"><text:note-citation>1</text:note-citation>'
            '<text:note-body><text:p>the note</text:p><text:p>second <text:s/>line</text:p>'
            '</text:note-body></text:note></text:p>',
      ),
    );
    final bytes = codec.encode(loaded.delta, source: loaded.source);
    expect(
      _parts(bytes)['content.xml'],
      contains('text:note-class="footnote"'),
    );

    final again = _decode(bytes);
    final footnotes = (again.source! as DocxPackage).text(
      'word/footnotes.xml',
    )!;
    expect(footnotes, contains('the note'));
    expect(footnotes, contains('second  line'));
    final other = OdtCodec(DocxCodec(TableStore())).encode(loaded.delta);
    expect(_parts(other)['content.xml'], isNot(contains('text:note')));
  });

  test('TextEdit opens the written file', () {
    final textutil = File('/usr/bin/textutil');
    if (!Platform.isMacOS || !textutil.existsSync()) {
      markTestSkipped('textutil is only on macOS');
      return;
    }
    final folder = Directory.systemTemp.createTempSync('odt');
    addTearDown(() => folder.deleteSync(recursive: true));
    final file = File('${folder.path}/written.odt')
      ..writeAsBytesSync(
        OdtCodec(DocxCodec(TableStore())).encode(
          Delta()
            ..insert('Heading')
            ..insert('\n', {'header': 1})
            ..insert('Some ')
            ..insert('bold', {'bold': true})
            ..insert(' text & <symbols>')
            ..insert('\n')
            ..insert('item')
            ..insert('\n', {'list': 'bullet'}),
        ),
      );
    final html = Process.runSync(textutil.path, [
      '-convert',
      'html',
      file.path,
      '-stdout',
    ]);
    expect(html.exitCode, 0, reason: '${html.stderr}');
    final output = html.stdout as String;
    expect(output, contains('Heading'));
    expect(output, contains('<b>bold</b>'));
    expect(output, contains('text &amp; &lt;symbols&gt;'));
    expect(output, contains('<li'));
  });

  test('Word charts, equations, objects and link fields stay visible', () {
    const chart =
        '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
        '<wp:extent cx="5486400" cy="3200400"/><wp:docPr id="1" name="Chart 1"/>'
        '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">'
        '<c:chart r:id="rIdChart"/></a:graphicData></a:graphic></wp:inline>'
        '</w:drawing></w:r>';
    const equation =
        '<m:oMath><m:r><m:t>E=m</m:t></m:r><m:sSup><m:e><m:r><m:t>c</m:t>'
        '</m:r></m:e><m:sup><m:r><m:t>2</m:t></m:r></m:sup></m:sSup></m:oMath>';
    const object =
        '<w:r><w:object w:dxaOrig="4320" w:dyaOrig="2160">'
        '<v:shape id="_x0000_i1025" type="#_x0000_t75" '
        'style="width:216pt;height:108pt" o:ole="">'
        '<v:imagedata r:id="rIdPreview" o:title=""/></v:shape>'
        '<o:OLEObject Type="Embed" ProgID="Excel.Sheet.12" '
        'ShapeID="_x0000_i1025" DrawAspect="Content" ObjectID="_1234567890" '
        'r:id="rIdObject"/></w:object></w:r>';
    const link =
        '<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
        '<w:r><w:instrText xml:space="preserve"> HYPERLINK '
        '"https://example.com/report?a=1&amp;b=2" </w:instrText></w:r>'
        '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
        '<w:r><w:t>the report</w:t></w:r>'
        '<w:r><w:fldChar w:fldCharType="end"/></w:r>';
    final bytes = _docxToOdt(
      _docxFile(
        _wordParagraph(_wordRun('Sales chart: ') + chart) +
            _wordParagraph(_wordRun('Formula: ') + equation) +
            _wordParagraph(_wordRun('Budget sheet: ') + object) +
            _wordParagraph(_wordRun('Read ') + link),
        relationships: [
          ('rIdChart', 'chart', 'charts/chart1.xml'),
          ('rIdPreview', 'image', 'media/image1.png'),
          ('rIdObject', 'oleObject', 'embeddings/oleObject1.bin'),
        ],
        parts: {
          'word/charts/chart1.xml':
              '<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"/>',
          'word/media/image1.png': pngPixel,
          'word/embeddings/oleObject1.bin': [0xD0, 0xCF, 0x11, 0xE0],
        },
      ),
    );
    final content = _xml(bytes, 'content.xml');

    final placeholder = _elements(
      _paragraphWith(content, 'Sales chart'),
      'text:placeholder',
    ).single;
    expect(placeholder.getAttribute('text:placeholder-type'), 'object');
    expect(placeholder.innerText, '<chart>');

    final formula = _paragraphWith(content, 'Formula');
    expect(formula.innerText, 'Formula: E=mc2');
    final square = _elements(
      formula,
      'text:span',
    ).firstWhere((span) => span.innerText == '2');
    expect(
      _styleProperties(
        content,
        square.getAttribute('text:style-name'),
        'style:text-properties',
      ),
      containsPair('style:text-position', 'super 58%'),
    );

    final frame = _elements(
      _paragraphWith(content, 'Budget sheet'),
      'draw:frame',
    ).single;
    expect(frame.getAttribute('svg:width'), '216pt');
    expect(frame.getAttribute('svg:height'), '108pt');
    expect(
      _parts(bytes).keys,
      contains(frame.getElement('draw:image')!.getAttribute('xlink:href')),
    );

    final anchor = _elements(_paragraphWith(content, 'Read'), 'text:a').single;
    expect(
      anchor.getAttribute('xlink:href'),
      'https://example.com/report?a=1&b=2',
    );
    expect(anchor.innerText, 'the report');

    // The editor shows nothing for a text watermark in the header, and
    // neither does the file.
    final watermark = OpaqueContent(
      xml:
          '<w:r><w:pict><v:shape style="position:absolute;width:400pt;'
          'height:100pt"><v:textpath string="DRAFT"/></v:shape></w:pict></w:r>',
      text: '',
    );
    final styles = _xml(
      OdtCodec(DocxCodec(TableStore())).encode(
        Delta()..insert('Body\n'),
        headersFooters: HeadersFooters(
          headers: {
            PageVariant.normal: _story(
              Delta()
                ..insert({EmbedTypes.opaqueInline: watermark.encode()})
                ..insert('Header\n'),
            ),
          },
        ),
      ),
      'styles.xml',
    );
    expect(_elements(styles, 'text:placeholder'), isEmpty);
  });

  test('pictures of Word fields and objects are kept, cut as Word crops '
      'them', () {
    const field =
        '<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
        '<w:r><w:instrText xml:space="preserve"> INCLUDEPICTURE '
        '"https://example.com/a.png" \\* MERGEFORMATINET </w:instrText></w:r>'
        '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
        '<w:r><w:drawing><wp:inline><wp:extent cx="914400" cy="457200"/>'
        '<wp:docPr id="5" name="Picture 5"/><a:graphic><a:graphicData '
        'uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic><pic:blipFill><a:blip r:embed="rIdField"/></pic:blipFill>'
        '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>'
        '<w:r><w:fldChar w:fldCharType="end"/></w:r>';
    const object =
        '<w:r><w:object><v:shape style="width:36pt;height:36pt">'
        '<v:imagedata r:id="rIdWide" cropright="0.5"/></v:shape></w:object></w:r>';
    const watermark =
        '<w:r><w:pict><v:shape style="position:absolute;width:400pt;'
        'height:300pt;z-index:-1"><v:imagedata r:id="rIdMark"/></v:shape>'
        '</w:pict></w:r>';
    final bytes = _docxToOdt(
      _docxFile(
        _wordParagraph(_wordRun('Field ') + field) +
            _wordParagraph(_wordRun('Cropped ') + object) +
            _wordParagraph('${_wordRun('Mark')}<w:r><w:footnoteRef/></w:r>'),
        section:
            '<w:sectPr><w:headerReference w:type="default" r:id="rIdHeader"/>'
            '</w:sectPr>',
        relationships: [
          ('rIdField', 'image', 'media/field.png'),
          ('rIdWide', 'image', 'media/wide.png'),
          ('rIdHeader', 'header', 'header1.xml'),
        ],
        parts: {
          'word/media/field.png': pngPixel,
          'word/media/wide.png': img.encodePng(img.Image(width: 4, height: 2)),
          'word/header1.xml':
              '<w:hdr $_wordNamespaces>'
              '${_wordParagraph(watermark + _wordRun('Header'))}</w:hdr>',
          'word/_rels/header1.xml.rels': _wordRelationships([
            ('rIdMark', 'image', 'media/field.png'),
          ]),
        },
      ),
    );
    final content = _xml(bytes, 'content.xml');

    // A floating watermark would push the header's text down.
    final header = _elements(_xml(bytes, 'styles.xml'), 'style:header').single;
    expect(header.innerText, 'Header');
    expect(_elements(header, 'draw:frame'), isEmpty);

    final picture = _elements(
      _paragraphWith(content, 'Field'),
      'draw:frame',
    ).single;
    expect(picture.getAttribute('svg:width'), '72pt');
    expect(picture.getAttribute('svg:height'), '36pt');

    final cropped = _elements(
      _paragraphWith(content, 'Cropped'),
      'draw:frame',
    ).single;
    expect(cropped.getAttribute('svg:width'), '36pt');
    expect(cropped.getAttribute('svg:height'), '36pt');
    final stored = ZipDecoder()
        .decodeBytes(bytes)
        .findFile(
          cropped.getElement('draw:image')!.getAttribute('xlink:href')!,
        )!;
    expect(imagePixelSize(stored.content), (width: 2, height: 2));

    expect(_paragraphWith(content, 'Mark').childElements, isEmpty);
  });

  test('notes keep their formatting and links', () {
    void expectFormattedNote(XmlDocument content) {
      final body = _elements(content, 'text:note-body').single;
      expect(body.innerText, 'See The Book, online.');
      final italic = _elements(
        body,
        'text:span',
      ).firstWhere((span) => span.innerText == 'The Book');
      expect(
        _styleProperties(
          content,
          italic.getAttribute('text:style-name'),
          'style:text-properties',
        ),
        containsPair('fo:font-style', 'italic'),
      );
      final link = _elements(body, 'text:a').single;
      expect(link.getAttribute('xlink:href'), 'https://example.com/source');
      expect(link.innerText, 'online');
    }

    final codec = OdtCodec(DocxCodec(TableStore()));
    final loaded = codec.decode(
      odtFile(
        automatic:
            '<style:style style:name="T1" style:family="text">'
            '<style:text-properties fo:font-style="italic"/></style:style>',
        body:
            '<text:p>Claim<text:note text:note-class="footnote">'
            '<text:note-citation>1</text:note-citation><text:note-body>'
            '<text:p>See <text:span text:style-name="T1">The Book</text:span>, '
            '<text:a xlink:type="simple" xlink:href="https://example.com/source">'
            'online</text:a>.</text:p></text:note-body></text:note> made.</text:p>',
      ),
    );
    expectFormattedNote(
      _xml(codec.encode(loaded.delta, source: loaded.source), 'content.xml'),
    );

    final footnotes =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:footnotes $_wordNamespaces>'
        '<w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/>'
        '</w:r></w:p></w:footnote><w:footnote w:id="1"><w:p><w:r><w:rPr>'
        '<w:vertAlign w:val="superscript"/></w:rPr><w:footnoteRef/></w:r>'
        '${_wordRun(' See ')}${_wordRun('The Book', '<w:rPr><w:i/></w:rPr>')}'
        '${_wordRun(', ')}<w:hyperlink r:id="rIdLink"><w:r><w:t>online</w:t>'
        '</w:r></w:hyperlink>${_wordRun('.')}</w:p></w:footnote></w:footnotes>';
    expectFormattedNote(
      _xml(
        _docxToOdt(
          _docxFile(
            _wordParagraph(
              '${_wordRun('Claim')}<w:r><w:rPr><w:vertAlign w:val="superscript"/>'
              '</w:rPr><w:footnoteReference w:id="1"/></w:r>${_wordRun(' made.')}',
            ),
            relationships: [('rIdNotes', 'footnotes', 'footnotes.xml')],
            parts: {
              'word/footnotes.xml': footnotes,
              'word/_rels/footnotes.xml.rels': _wordRelationships([
                ('rIdLink', 'hyperlink', 'https://example.com/source'),
              ]),
            },
          ),
        ),
        'content.xml',
      ),
    );
  });

  test('Header and Footer styles stop tabs at the center and the right '
      'margin', () {
    final styles = _xml(
      OdtCodec(DocxCodec(TableStore())).encode(
        Delta()..insert('Body\n'),
        look: const DocumentLook(
          pageWidth: 612,
          pageHeight: 792,
          margins: EdgeInsets.fromLTRB(72, 72, 72, 72),
        ),
        headersFooters: HeadersFooters(
          headers: {
            PageVariant.normal: _story(
              Delta()..insert('Left\tCenter\tRight\n'),
            ),
          },
        ),
      ),
      'styles.xml',
    );
    for (final name in ['Header', 'Footer']) {
      final style = _elements(
        styles,
        'style:style',
      ).firstWhere((element) => element.getAttribute('style:name') == name);
      expect(
        [
          for (final stop in _elements(style, 'style:tab-stop'))
            (
              stop.getAttribute('style:type'),
              stop.getAttribute('style:position'),
            ),
        ],
        [('center', '234pt'), ('right', '468pt')],
        reason: name,
      );
    }
  });

  test('a floating header logo keeps its place and leaves the header text '
      'alone', () {
    const anchored =
        '<w:r><w:drawing><wp:anchor distT="0" distB="0" distL="114300" '
        'distR="114300" simplePos="0" relativeHeight="251658240" behindDoc="0" '
        'locked="0" layoutInCell="1" allowOverlap="1"><wp:simplePos x="0" y="0"/>'
        '<wp:positionH relativeFrom="margin"><wp:align>right</wp:align>'
        '</wp:positionH><wp:positionV relativeFrom="page">'
        '<wp:posOffset>228600</wp:posOffset></wp:positionV>'
        '<wp:extent cx="1371600" cy="914400"/><wp:wrapNone/>'
        '<wp:docPr id="7" name="Logo"/><a:graphic><a:graphicData '
        'uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic><pic:blipFill><a:blip r:embed="rIdLogo"/></pic:blipFill>'
        '</pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r>';
    final styles = _xml(
      OdtCodec(DocxCodec(TableStore())).encode(
        Delta()..insert('Dear customer\n'),
        look: const DocumentLook(
          pageWidth: 612,
          pageHeight: 792,
          margins: EdgeInsets.fromLTRB(72, 72, 72, 72),
        ),
        headersFooters: HeadersFooters(
          headers: {
            PageVariant.normal: _story(
              Delta()
                ..insert(
                  {EmbedTypes.image: dataUriFromMime(pngPixel, 'image/png')},
                  {
                    'width': '108',
                    'height': '72',
                    HiddenAttributes.drawing: anchored,
                  },
                )
                ..insert('ACME Corp\n'),
            ),
          },
          headerDistance: 36,
        ),
      ),
      'styles.xml',
    );
    final frame = _elements(
      _elements(styles, 'style:header').single,
      'draw:frame',
    ).single;
    expect(frame.getAttribute('text:anchor-type'), 'paragraph');
    expect(frame.getAttribute('svg:width'), '108pt');
    expect(frame.getAttribute('svg:y'), '18pt');
    expect(
      _styleProperties(
        styles,
        frame.getAttribute('draw:style-name'),
        'style:graphic-properties',
      ),
      allOf(
        containsPair('style:wrap', 'run-through'),
        containsPair('style:horizontal-pos', 'right'),
        containsPair('style:horizontal-rel', 'page-content'),
        containsPair('style:vertical-pos', 'from-top'),
        containsPair('style:vertical-rel', 'page'),
      ),
    );
  });

  test('list items, and paragraphs Word keeps together, add no space '
      'between them', () {
    final delta = Delta()..insert('Shopping:\n');
    for (final item in ['milk', 'bread', 'eggs']) {
      delta
        ..insert(item)
        ..insert('\n', {'list': 'bullet'});
    }
    delta.insert('Done.\n');
    for (final text in ['first', 'second', 'third']) {
      delta
        ..insert(text)
        ..insert('\n', {HiddenAttributes.contextualGroup: 'Compact'});
    }
    delta.insert('after\n');
    final content = _xml(
      OdtCodec(DocxCodec(TableStore())).encode(delta),
      'content.xml',
    );
    Map<String, String> spacing(String text) => _styleProperties(
      content,
      _paragraphWith(content, text).getAttribute('text:style-name'),
      'style:paragraph-properties',
    );

    for (final item in ['milk', 'bread', 'eggs']) {
      expect(spacing(item), containsPair('fo:margin-top', '0pt'));
    }
    expect(spacing('milk'), containsPair('fo:margin-bottom', '0pt'));
    expect(spacing('bread'), containsPair('fo:margin-bottom', '0pt'));
    expect(spacing('eggs'), isNot(contains('fo:margin-bottom')));
    expect(spacing('first'), isNot(contains('fo:margin-top')));
    expect(spacing('first'), containsPair('fo:margin-bottom', '0pt'));
    expect(spacing('second'), containsPair('fo:margin-top', '0pt'));
    expect(spacing('second'), containsPair('fo:margin-bottom', '0pt'));
    expect(spacing('third'), containsPair('fo:margin-top', '0pt'));
    expect(spacing('third'), isNot(contains('fo:margin-bottom')));
  });

  test('a table keeps its column widths when the grid has more columns than '
      'its rows use', () {
    final tables = TableStore();
    final table = TableModel(
      id: tables.nextId(),
      bordered: true,
      columnWidths: [1000, 6000, 2000],
      rows: [
        TableRowModel(
          cells: [_cell(tables, 'No.'), _cell(tables, 'Description')],
        ),
        TableRowModel(cells: [_cell(tables, '1'), _cell(tables, 'First')]),
      ],
    );
    tables.add(table);
    final content = _xml(
      OdtCodec(DocxCodec(tables)).encode(
        Delta()
          ..insert({EmbedTypes.table: encodeTableId(table.id)})
          ..insert('\n'),
      ),
      'content.xml',
    );
    expect(
      [
        for (final column in _elements(content, 'table:table-column'))
          _styleProperties(
            content,
            column.getAttribute('table:style-name'),
            'style:table-column-properties',
          )['style:column-width'],
      ],
      ['50pt', '300pt'],
    );
  });

  test('sections keep their page number format and restart', () {
    String section(String numbers) =>
        '<w:sectPr><w:footerReference w:type="default" r:id="rIdFooter"/>'
        '<w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" '
        'w:right="1440" w:bottom="1440" w:left="1440" w:header="720" '
        'w:footer="720" w:gutter="0"/>$numbers</w:sectPr>';
    const footer =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:ftr $_wordNamespaces><w:p><w:pPr><w:jc w:val="center"/></w:pPr>'
        '<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r>'
        '<w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>'
        '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t>'
        '</w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p></w:ftr>';
    final bytes = _docxToOdt(
      _docxFile(
        '${_wordParagraph(_wordRun('Preface'))}<w:p><w:pPr>'
        '${section('<w:pgNumType w:fmt="lowerRoman" w:start="1"/>')}'
        '</w:pPr></w:p>${_wordParagraph(_wordRun('Chapter one'))}'
        '${_wordParagraph('${_wordRun('Page ')}<w:fldSimple w:instr=" PAGE \\* ROMAN ">${_wordRun('I')}</w:fldSimple>')}',
        section: section('<w:pgNumType w:start="5"/>'),
        relationships: [('rIdFooter', 'footer', 'footer1.xml')],
        parts: {'word/footer1.xml': footer},
      ),
    );
    final content = _xml(bytes, 'content.xml');
    final styles = _xml(bytes, 'styles.xml');

    for (final (text, master, number) in [
      ('Preface', 'Section1', '1'),
      ('Chapter one', 'Standard', '5'),
    ]) {
      final name = _paragraphWith(
        content,
        text,
      ).getAttribute('text:style-name');
      final style = _elements(
        content,
        'style:style',
      ).firstWhere((element) => element.getAttribute('style:name') == name);
      expect(style.getAttribute('style:master-page-name'), master);
      expect(
        _styleProperties(content, name, 'style:paragraph-properties'),
        containsPair('style:page-number', number),
      );
    }
    String? format(String master) {
      final page = _elements(
        styles,
        'style:master-page',
      ).firstWhere((element) => element.getAttribute('style:name') == master);
      return _elements(styles, 'style:page-layout')
          .firstWhere(
            (layout) =>
                layout.getAttribute('style:name') ==
                page.getAttribute('style:page-layout-name'),
          )
          .getElement('style:page-layout-properties')!
          .getAttribute('style:num-format');
    }

    expect(format('Section1'), 'i');
    expect(format('Standard'), isNull);
    final footerNumber = _elements(
      _elements(styles, 'style:footer').first,
      'text:page-number',
    ).single;
    expect(footerNumber.getAttribute('style:num-format'), isNull);
    expect(
      _elements(
        _paragraphWith(content, 'Page'),
        'text:page-number',
      ).single.getAttribute('style:num-format'),
      'I',
    );
  });

  test('the look is bold and italic in every script', () {
    final styles = _xml(
      OdtCodec(DocxCodec(TableStore())).encode(
        Delta()
          ..insert('عنوان')
          ..insert('\n', {'header': 1})
          ..insert('中文\n'),
        look: const DocumentLook(
          body: TextLook(fontSize: 11, fontFamily: 'Georgia', italic: true),
          headings: {
            1: TextLook(fontSize: 20, fontFamily: 'Arial', bold: true),
          },
        ),
      ),
      'styles.xml',
    );
    expect(
      _styleProperties(styles, 'Heading_20_1', 'style:text-properties'),
      allOf(
        containsPair('style:font-weight-asian', 'bold'),
        containsPair('style:font-weight-complex', 'bold'),
        containsPair('style:font-name-asian', 'Arial'),
        containsPair('style:font-name-complex', 'Arial'),
      ),
    );
    expect(
      _styleProperties(styles, 'Standard', 'style:text-properties'),
      allOf(
        containsPair('style:font-style-asian', 'italic'),
        containsPair('style:font-style-complex', 'italic'),
      ),
    );
  });

  test('pictures keep their title and description', () {
    const drawing =
        '<w:r><w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>'
        '<wp:docPr id="3" name="Picture 3" title="Company logo" '
        'descr="Red square logo of ACME &amp; Co"/></wp:inline></w:drawing></w:r>';
    final frame = _elements(
      _xml(
        OdtCodec(DocxCodec(TableStore())).encode(
          Delta()
            ..insert(
              {EmbedTypes.image: dataUriFromMime(pngPixel, 'image/png')},
              {
                'width': '72',
                'height': '72',
                HiddenAttributes.drawing: drawing,
              },
            )
            ..insert('\n'),
        ),
        'content.xml',
      ),
      'draw:frame',
    ).single;
    expect(frame.getElement('svg:title')?.innerText, 'Company logo');
    expect(
      frame.getElement('svg:desc')?.innerText,
      'Red square logo of ACME & Co',
    );

    final codec = OdtCodec(DocxCodec(TableStore()));
    final loaded = codec.decode(
      odtFile(
        body:
            '<text:p><draw:frame svg:width="1cm" svg:height="1cm" '
            'text:anchor-type="as-char"><draw:image xlink:href="Pictures/a.png"/>'
            '<svg:desc>Red square</svg:desc></draw:frame></text:p>',
        extra: {'Pictures/a.png': pngPixel},
      ),
    );
    expect(
      _elements(
        _xml(codec.encode(loaded.delta, source: loaded.source), 'content.xml'),
        'svg:desc',
      ).single.innerText,
      'Red square',
    );
  });

  test('the document language is kept', () {
    XmlElement defaults(Uint8List bytes) => _elements(
      _xml(bytes, 'styles.xml'),
      'style:default-style',
    ).single.getElement('style:text-properties')!;

    final codec = OdtCodec(DocxCodec(TableStore()));
    final loaded = codec.decode(odtFile(body: '<text:p>Olá</text:p>'));
    final odt = defaults(codec.encode(loaded.delta, source: loaded.source));
    expect(odt.getAttribute('fo:language'), 'pt');
    expect(odt.getAttribute('fo:country'), 'BR');

    final word = defaults(
      _docxToOdt(_docxFile(_wordParagraph(_wordRun('Olá')))),
    );
    expect(
      {
        for (final name in [
          'fo:language',
          'fo:country',
          'style:language-asian',
          'style:country-asian',
          'style:language-complex',
          'style:country-complex',
        ])
          name: word.getAttribute(name),
      },
      {
        'fo:language': 'pt',
        'fo:country': 'BR',
        'style:language-asian': 'en',
        'style:country-asian': 'US',
        'style:language-complex': 'ar',
        'style:country-complex': 'SA',
      },
    );
  });

  test('negative page margins are written as the distances OpenDocument '
      'allows', () {
    final styles = _xml(
      OdtCodec(DocxCodec(TableStore())).encode(
        Delta()..insert('Body\n'),
        look: const DocumentLook(
          margins: EdgeInsets.fromLTRB(50, -60, 40, -65),
        ),
        headersFooters: HeadersFooters(
          headers: {PageVariant.normal: _story(Delta()..insert('Header\n'))},
          headerDistance: 30,
        ),
      ),
      'styles.xml',
    );
    final page = _elements(styles, 'style:page-layout-properties').single;
    final header = _elements(styles, 'style:header-footer-properties').single;
    expect(page.getAttribute('fo:margin-top'), '30pt');
    expect(page.getAttribute('fo:margin-bottom'), '65pt');
    expect(header.getAttribute('fo:min-height'), '30pt');
    for (final element in [page, header]) {
      for (final attribute in element.attributes) {
        expect(attribute.value, isNot(startsWith('-')), reason: '$attribute');
      }
    }
  });

  test('numbered headings of an OpenDocument file keep the outline numbering '
      'when saved again', () {
    const heading1 = 'text:style-name="Heading_20_1" text:outline-level="1"';
    const heading2 = 'text:style-name="Heading_20_2" text:outline-level="2"';
    String alignment(String followedBy) =>
        '<style:list-level-properties '
        'text:list-level-position-and-space-mode="label-alignment">'
        '<style:list-level-label-alignment text:label-followed-by="$followedBy"'
        '${followedBy == 'listtab' ? ' text:list-tab-stop-position="0pt"' : ''}'
        ' fo:text-indent="0pt" fo:margin-left="0pt"/>'
        '</style:list-level-properties>';
    final codec = OdtCodec(DocxCodec(TableStore()));
    final opened = codec.decode(
      odtFile(
        styles:
            '$libreOfficeStyles<text:outline-style style:name="Outline">'
            '<text:outline-level-style text:level="1" style:num-prefix="Part " '
            'style:num-suffix="." style:num-format="1">${alignment('space')}'
            '</text:outline-level-style>'
            '<text:outline-level-style text:level="2" style:num-format="1" '
            'text:display-levels="2">${alignment('listtab')}'
            '</text:outline-level-style>'
            '<text:outline-level-style text:level="3" style:num-format=""/>'
            '</text:outline-style>',
        automatic:
            '<style:style style:name="P1" style:family="paragraph" '
            'style:parent-style-name="Heading_20_1" style:list-style-name=""/>',
        body:
            '<text:h $heading1>Introduction</text:h><text:p>para</text:p>'
            '<text:h $heading2>Scope</text:h>'
            '<text:h text:style-name="P1" text:outline-level="1">No list</text:h>'
            '<text:h $heading1>Methods</text:h>'
            '<text:h $heading2 text:restart-numbering="true" '
            'text:start-value="5">Fifth</text:h>'
            '<text:h $heading2>Sixth</text:h>'
            '<text:h $heading1>Results</text:h>',
      ),
    );
    final bytes = codec.encode(
      opened.delta,
      source: opened.source,
      look: opened.look,
    );
    final content = _xml(bytes, 'content.xml');
    final styles = _xml(bytes, 'styles.xml');

    // LibreOffice numbers headings outside lists by the outline style.
    expect(_elements(content, 'text:list'), isEmpty);
    const numbered = [
      'Introduction',
      'Scope',
      'Methods',
      'Fifth',
      'Sixth',
      'Results',
    ];
    for (final text in numbered) {
      final heading = _paragraphWith(content, text);
      expect(heading.parentElement?.name.qualified, 'office:text');
      expect(
        heading.getAttribute('text:restart-numbering'),
        text == 'Fifth' ? 'true' : isNull,
        reason: text,
      );
      expect(
        heading.getAttribute('text:start-value'),
        text == 'Fifth' ? '5' : isNull,
        reason: text,
      );
    }
    String? listStyle(String text) {
      final name = _paragraphWith(
        content,
        text,
      ).getAttribute('text:style-name');
      return _elements(content, 'style:style')
          .where((style) => style.getAttribute('style:name') == name)
          .firstOrNull
          ?.getAttribute('style:list-style-name');
    }

    expect(listStyle('No list'), '');
    expect(listStyle('Introduction'), isNull);

    XmlElement level(int level) => _elements(
      styles,
      'text:outline-level-style',
    ).firstWhere((style) => style.getAttribute('text:level') == '$level');
    expect(level(1).getAttribute('style:num-format'), '1');
    expect(level(1).getAttribute('style:num-prefix'), 'Part ');
    expect(level(1).getAttribute('style:num-suffix'), '.');
    expect(level(1).getAttribute('text:display-levels'), isNull);
    expect(level(2).getAttribute('style:num-format'), '1');
    expect(level(2).getAttribute('text:display-levels'), '2');
    expect(level(3).getAttribute('style:num-format'), '');

    final reopened = codec.decode(bytes);
    for (final text in [...numbered, 'No list', 'para']) {
      expect(
        lineOf(reopened.delta, text),
        lineOf(opened.delta, text),
        reason: text,
      );
    }
    expect(
      (reopened.source! as DocxPackage).text('word/numbering.xml'),
      (opened.source! as DocxPackage).text('word/numbering.xml'),
    );
  });

  test('Word heading numbering is saved as the outline numbering', () {
    const styles =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:styles $_wordNamespaces>'
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
        '<w:name w:val="Normal"/></w:style>'
        '<w:style w:type="paragraph" w:styleId="Heading1">'
        '<w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr>'
        '<w:numPr><w:numId w:val="1"/></w:numPr><w:outlineLvl w:val="0"/>'
        '</w:pPr></w:style>'
        '<w:style w:type="paragraph" w:styleId="Heading2">'
        '<w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr>'
        '<w:numPr><w:ilvl w:val="1"/><w:numId w:val="1"/></w:numPr>'
        '<w:outlineLvl w:val="1"/></w:pPr></w:style></w:styles>';
    const numbering =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:numbering $_wordNamespaces><w:abstractNum w:abstractNumId="10">'
        '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/>'
        '<w:pStyle w:val="Heading1"/><w:suff w:val="space"/>'
        '<w:lvlText w:val="%1."/><w:lvlJc w:val="left"/>'
        '<w:pPr><w:ind w:left="432" w:hanging="432"/></w:pPr></w:lvl>'
        '<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/>'
        '<w:pStyle w:val="Heading2"/><w:lvlText w:val="%1.%2."/>'
        '<w:lvlJc w:val="left"/>'
        '<w:pPr><w:ind w:left="576" w:hanging="576"/></w:pPr></w:lvl>'
        '<w:lvl w:ilvl="2"><w:start w:val="1"/><w:numFmt w:val="upperLetter"/>'
        '<w:lvlText w:val="Annex %3"/><w:lvlJc w:val="left"/></w:lvl>'
        '</w:abstractNum>'
        '<w:num w:numId="1"><w:abstractNumId w:val="10"/></w:num>'
        '<w:num w:numId="2"><w:abstractNumId w:val="10"/>'
        '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="7"/></w:lvlOverride>'
        '</w:num></w:numbering>';
    String heading(int level, String content, [String numbering = '']) =>
        _wordParagraph(
          '<w:pPr><w:pStyle w:val="Heading$level"/>$numbering</w:pPr>$content',
        );

    final bytes = _docxToOdt(
      _docxFile(
        '${heading(1, _wordRun('Scope'))}${heading(2, _wordRun('Terms'))}'
        '${_wordParagraph(_wordRun('Body text'))}'
        '${heading(1, '${_wordRun('Use')}<w:r><w:br w:type="page"/></w:r>${_wordRun('more of use')}')}'
        '${heading(2, _wordRun('Limits'))}'
        '${heading(1, _wordRun('Annex'), '<w:numPr><w:numId w:val="2"/></w:numPr>')}'
        '${heading(1, _wordRun('Appendix'), '<w:numPr><w:numId w:val="0"/></w:numPr>')}',
        relationships: [('rIdNumbering', 'numbering', 'numbering.xml')],
        parts: {'word/styles.xml': styles, 'word/numbering.xml': numbering},
      ),
    );
    final content = _xml(bytes, 'content.xml');
    final outline = _xml(bytes, 'styles.xml');

    expect(_elements(content, 'text:list'), isEmpty);
    String? attribute(String text, String name) =>
        _paragraphWith(content, text).getAttribute(name);
    for (final text in ['Scope', 'Terms', 'Use', 'Limits']) {
      expect(attribute(text, 'text:restart-numbering'), isNull, reason: text);
    }
    // Word starts its second list at 7, where the outline would show 3.
    expect(attribute('Annex', 'text:restart-numbering'), 'true');
    expect(attribute('Annex', 'text:start-value'), '7');
    String? listStyle(String text) => _elements(content, 'style:style')
        .where(
          (style) =>
              style.getAttribute('style:name') ==
              attribute(text, 'text:style-name'),
        )
        .firstOrNull
        ?.getAttribute('style:list-style-name');
    expect(listStyle('Appendix'), '');
    expect(listStyle('more of use'), '', reason: 'numbered once');
    expect(listStyle('Use'), isNull);

    XmlElement level(int level) => _elements(
      outline,
      'text:outline-level-style',
    ).firstWhere((style) => style.getAttribute('text:level') == '$level');
    Map<String, String> attributes(XmlElement element) => {
      for (final attribute in element.attributes)
        attribute.name.qualified: attribute.value,
    };
    Map<String, String> alignment(int number) => attributes(
      _elements(level(number), 'style:list-level-label-alignment').single,
    );

    expect(attributes(level(1)), {
      'text:level': '1',
      'style:num-suffix': '.',
      'style:num-format': '1',
    });
    expect(alignment(1), {
      'text:label-followed-by': 'space',
      'fo:text-indent': '-21.6pt',
      'fo:margin-left': '21.6pt',
    });
    expect(attributes(level(2)), {
      'text:level': '2',
      'style:num-suffix': '.',
      'style:num-format': '1',
      'text:display-levels': '2',
    });
    expect(alignment(2), {
      'text:label-followed-by': 'listtab',
      'text:list-tab-stop-position': '28.8pt',
      'fo:text-indent': '-28.8pt',
      'fo:margin-left': '28.8pt',
    });
    expect(attributes(level(3)), {
      'text:level': '3',
      'style:num-prefix': 'Annex ',
      'style:num-format': 'A',
    });
    expect(level(4).getAttribute('style:num-format'), '');
  });

  test('list numbers and bullets keep what follows them: a tab, a space or '
      'nothing', () {
    String level(int level, String format, String text, [String suffix = '']) =>
        '<w:lvl w:ilvl="$level"><w:start w:val="1"/>'
        '<w:numFmt w:val="$format"/>$suffix<w:lvlText w:val="$text"/>'
        '<w:lvlJc w:val="left"/></w:lvl>';
    final numbering =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:numbering $_wordNamespaces>'
        '<w:abstractNum w:abstractNumId="20">'
        '${level(0, 'decimal', '%1)', '<w:suff w:val="nothing"/>')}'
        '${level(1, 'lowerLetter', '%2.', '<w:suff w:val="space"/>')}'
        '${level(2, 'lowerRoman', '%3.')}</w:abstractNum>'
        '<w:abstractNum w:abstractNumId="21">'
        '${level(0, 'bullet', '•', '<w:suff w:val="space"/>')}'
        '</w:abstractNum>'
        '<w:abstractNum w:abstractNumId="22">'
        '${level(0, 'decimal', '%1.')}</w:abstractNum>'
        '<w:num w:numId="3"><w:abstractNumId w:val="20"/></w:num>'
        '<w:num w:numId="4"><w:abstractNumId w:val="21"/></w:num>'
        '<w:num w:numId="5"><w:abstractNumId w:val="22"/></w:num>'
        '</w:numbering>';
    String item(String text, int numId, [int level = 0]) => _wordParagraph(
      '<w:pPr><w:numPr><w:ilvl w:val="$level"/><w:numId w:val="$numId"/>'
      '</w:numPr></w:pPr>${_wordRun(text)}',
    );

    final content = _xml(
      _docxToOdt(
        _docxFile(
          '${item('First', 3)}${item('Sub', 3, 1)}${item('Dot', 4)}'
          '${item('Plain', 5)}',
          relationships: [('rIdNumbering', 'numbering', 'numbering.xml')],
          parts: {'word/numbering.xml': numbering},
        ),
      ),
      'content.xml',
    );
    List<XmlElement> levels(String text) {
      XmlElement? list = _paragraphWith(content, text);
      while (list != null &&
          (list.name.qualified != 'text:list' ||
              list.getAttribute('text:style-name') == null)) {
        list = list.parentElement;
      }
      final name = list!.getAttribute('text:style-name');
      return [
        for (final level
            in _elements(content, 'text:list-style')
                .firstWhere((style) => style.getAttribute('style:name') == name)
                .childElements)
          _elements(level, 'style:list-level-label-alignment').single,
      ];
    }

    List<String?> followedBy(String text) => [
      for (final level in levels(text))
        level.getAttribute('text:label-followed-by'),
    ];

    expect(followedBy('First'), [
      'nothing',
      'space',
      ...List.filled(8, 'listtab'),
    ]);
    expect(followedBy('Sub'), followedBy('First'));
    expect(
      levels('First').first.getAttribute('text:list-tab-stop-position'),
      isNull,
    );
    expect(followedBy('Dot'), ['space', ...List.filled(9, 'listtab')]);
    expect(followedBy('Plain'), List.filled(10, 'listtab'));
  });

  test('odd Word list definitions still save', () {
    const numbering =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:numbering $_wordNamespaces><w:abstractNum w:abstractNumId="30">'
        '<w:lvl w:ilvl="0"><w:start w:val="-3"/><w:numFmt w:val="ordinal"/>'
        '<w:suff w:val="bogus"/><w:lvlText w:val="%9 &amp; &lt;%1&gt;"/>'
        '<w:pPr><w:ind w:left="abc" w:hanging="1e400"/></w:pPr></w:lvl>'
        '<w:lvl w:ilvl="12"><w:numFmt w:val="decimal"/></w:lvl>'
        '<w:lvl><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>'
        '<w:num w:numId="x"><w:abstractNumId w:val="30"/></w:num>'
        '<w:num w:numId="6"><w:abstractNumId w:val="30"/>'
        '<w:lvlOverride w:ilvl="-1"><w:startOverride w:val="9"/></w:lvlOverride>'
        '</w:num></w:numbering>';
    const styles =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:styles $_wordNamespaces>'
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
        '<w:name w:val="Normal"/></w:style>'
        '<w:style w:type="paragraph" w:styleId="Heading1">'
        '<w:name w:val="heading 1"/></w:style></w:styles>';

    final bytes = _docxToOdt(
      _docxFile(
        _wordParagraph(
          '<w:pPr><w:pStyle w:val="Heading1"/><w:numPr><w:ilvl w:val="0"/>'
          '<w:numId w:val="6"/></w:numPr></w:pPr>${_wordRun('Odd')}',
        ),
        relationships: [('rIdNumbering', 'numbering', 'numbering.xml')],
        parts: {'word/styles.xml': styles, 'word/numbering.xml': numbering},
      ),
    );
    final heading = _paragraphWith(_xml(bytes, 'content.xml'), 'Odd');
    final level = _elements(
      _xml(bytes, 'styles.xml'),
      'text:outline-level-style',
    ).first;

    expect(heading.parentElement?.name.qualified, 'office:text');
    expect(heading.getAttribute('text:start-value'), '0');
    expect(level.getAttribute('style:num-format'), '1');
    expect(level.getAttribute('style:num-suffix'), '>');
    expect(level.getAttribute('text:start-value'), isNull);
    expect(
      _elements(
        level,
        'style:list-level-label-alignment',
      ).single.attributes.map((attribute) => attribute.value),
      ['listtab', '0pt', '0pt', '0pt'],
    );
  });
}
