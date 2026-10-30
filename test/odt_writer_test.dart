import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/painting.dart' show Color, EdgeInsets;
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
