import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/doc/doc_codec.dart';
import 'package:voges_word/doc/doc_file.dart';
import 'package:voges_word/doc/doc_reader.dart';
import 'package:voges_word/doc/doc_sprms.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/headers_footers.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';

import 'doc_fixtures.dart';

LoadedDocument _decode(Uint8List bytes, [TableStore? tables]) =>
    DocCodec(DocxCodec(tables ?? TableStore())).decode(bytes);

List<Operation> _ops(Delta delta) => delta.toList();

String _text(Delta delta) => [
  for (final operation in _ops(delta))
    if (operation.data is String) operation.data as String,
].join();

Operation _op(Delta delta, String text) => _ops(delta).firstWhere(
  (operation) =>
      operation.data is String && (operation.data as String).contains(text),
);

/// Attributes of the line [text] is on.
Map<String, dynamic>? _line(Delta delta, String text) {
  final operations = _ops(delta);
  final index = operations.indexWhere(
    (operation) =>
        operation.data is String && (operation.data as String).contains(text),
  );
  final first = operations[index].data as String;
  if (first.indexOf('\n', first.indexOf(text)) >= 0) {
    return operations[index].attributes;
  }
  for (var next = index + 1; next < operations.length; next++) {
    final data = operations[next].data;
    if (data is String && data.contains('\n')) {
      return operations[next].attributes;
    }
  }
  return null;
}

Iterable<Map<dynamic, dynamic>> _embeds(Delta delta, String type) => _ops(delta)
    .map((operation) => operation.data)
    .whereType<Map<dynamic, dynamic>>()
    .where((data) => data.containsKey(type));

TableModel _table(Delta delta, TableStore tables, [int index = 0]) =>
    tables[tableIdOf(
      _embeds(delta, EmbedTypes.table).elementAt(index)[EmbedTypes.table],
    )]!;

String _cellText(TableCellModel cell) =>
    cell.controller.document.toPlainText().trim();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('text, styles, headings and character formatting', () {
    final doc = DocWriter()
      ..styles[1] = StyleFixture.paragraph(
        'Título 1',
        builtIn: 1,
        base: 0,
        paragraph: sprm(Sprm.pFKeepFollow, [1]),
        character: [...bold, ...fontSize(16), ...font(2)],
      )
      ..styles[11] = StyleFixture.character('Strong Words', character: italic)
      ..line('Title', style: 1)
      ..text('plain ')
      ..text('bold', bold)
      ..text(' ')
      ..text('red', sprm(Sprm.cIco, [6]))
      ..text(' ')
      ..text('teal', sprm(Sprm.cCv, [0x00, 0x80, 0x80, 0x00]))
      ..text(' ')
      ..text('big', [...fontSize(18), ...font(2)])
      ..text('2', sprm(Sprm.cIss, [1]))
      ..text(' ')
      ..text('styled', sprm(Sprm.cIstd, u16(11)))
      ..text(' ')
      ..text('under', sprm(Sprm.cKul, [1]))
      ..text(' ')
      ..text('gone', sprm(Sprm.cFStrike, [1]))
      ..text(' ')
      ..text('marked', sprm(Sprm.cHighlight, [7]))
      ..paragraph(sprms: sprm(Sprm.pJc80, [1]))
      ..line(
        'spaced',
        sprms: [
          ...sprm(Sprm.pDyaBefore, u16(120)),
          ...sprm(Sprm.pDyaAfter, u16(240)),
          ...sprm(Sprm.pDxaLeft, u16(1440)),
          ...sprm(Sprm.pDxaLeft1, u16(-360 & 0xFFFF)),
          ...sprm(Sprm.pDyaLine, [...u16(360), ...u16(1)]),
        ],
      );
    final loaded = _decode(doc.build());
    final delta = loaded.delta;

    expect(_text(delta), startsWith('Title\nplain bold red teal big2 styled'));
    expect(_line(delta, 'Title')?['header'], 1);
    expect(_op(delta, 'bold').attributes, {'bold': true});
    expect(_op(delta, 'red').attributes?['color'], '#FF0000');
    expect(_op(delta, 'teal').attributes?['color'], '#008080');
    expect(_op(delta, 'big').attributes?['size'], '18');
    expect(_op(delta, 'big').attributes?['font'], 'Arial');
    expect(_op(delta, '2').attributes?['script'], 'super');
    expect(_op(delta, 'styled').attributes?['italic'], isTrue);
    expect(_op(delta, 'under').attributes?['underline'], isTrue);
    expect(_op(delta, 'gone').attributes?['strike'], isTrue);
    expect(_op(delta, 'marked').attributes?['background'], '#FFFF00');
    expect(_line(delta, 'plain')?['align'], 'center');
    final spaced = _line(delta, 'spaced')!;
    expect(spaced['indent'], 2);
    expect(spaced['line-height'], 1.5);
    expect(spaced[HiddenAttributes.spaceBefore], 6);
    expect(spaced[HiddenAttributes.spaceAfter], 12);
    expect(spaced[HiddenAttributes.firstLine], -18);
    // Word 97's defaults, not the app's.
    expect(loaded.look.body.fontFamily, 'Times New Roman');
    expect(loaded.look.body.fontSize, 10);
    expect(loaded.look.headings[1]?.fontSize, 16);
    expect(loaded.look.pageWidth, 612);
    expect(loaded.notices, isEmpty);
  });

  test('the document keeps its language and source defaults', () {
    final doc = DocWriter()
      ..styles[0] = StyleFixture.paragraph(
        'Normal',
        builtIn: 0,
        character: [...fontSize(12), ...sprm(Sprm.cRgLid0, u16(0x0416))],
      )
      ..line('Olá');
    final spec = DocReader(DocFile.open(doc.build())).read();
    expect(spec.language, 'pt-BR');
    expect(spec.defaultRun.font, 'Times New Roman');
    expect(spec.defaultRun.size, 10);
    expect(spec.defaultParagraph.spaceAfter, 0);
    expect(spec.defaultTabStop, 36);
    expect(
      spec.styles.firstWhere((style) => style.id == 'Normal').run.size,
      12,
    );
  });

  test('lists keep their kind, level, numbering and bullet font', () {
    final doc = DocWriter();
    final bullets = doc.addList([
      (format: 23, text: '\uF0B7', start: 1, left: 720, hanging: 360, font: 1),
      (format: 23, text: 'o', start: 1, left: 1440, hanging: 360, font: null),
    ]);
    final numbers = doc.addList([
      (format: 0, text: '%1.', start: 3, left: 720, hanging: 360, font: null),
      (
        format: 4,
        text: '%1.%2)',
        start: 1,
        left: 1440,
        hanging: 360,
        font: null,
      ),
    ], startOverride: 5);
    doc
      ..line('dot', sprms: DocWriter.listParagraph(bullets))
      ..line('circle', sprms: DocWriter.listParagraph(bullets, 1))
      ..line('five', sprms: DocWriter.listParagraph(numbers))
      ..line('letter', sprms: DocWriter.listParagraph(numbers, 1));
    final loaded = _decode(doc.build());
    final delta = loaded.delta;

    expect(_line(delta, 'dot')?['list'], 'bullet');
    expect(_line(delta, 'circle')?['list'], 'bullet');
    expect(_line(delta, 'circle')?['indent'], 1);
    expect(_line(delta, 'five')?['list'], 'ordered');
    expect(_line(delta, 'letter')?['indent'], 1);
    final numbering = (loaded.source! as DocxPackage).text(
      'word/numbering.xml',
    )!;
    expect(numbering, contains('w:val="bullet"'));
    expect(numbering, contains('w:ascii="Symbol"'));
    expect(numbering, contains('<w:start w:val="5"/>'));
    expect(numbering, contains('w:val="%1.%2)"'));
    expect(numbering, contains('w:val="lowerLetter"'));
  });

  test('links, bookmarks and fields', () {
    final doc = DocWriter();
    doc
      ..bookmarks.add(('Target', 0, 6))
      ..text('Target ')
      ..text('\x13', special)
      ..text(' HYPERLINK "https://example.com/a?b=1" ')
      ..text('\x14', special)
      ..text('site')
      ..text('\x15', special)
      ..text(' ')
      ..text('\x13', special)
      ..text(r' HYPERLINK \l "Target" ')
      ..text('\x14', special)
      ..text('back')
      ..text('\x15', special)
      ..text(' ')
      ..text('\x13', special)
      ..text(' HYPERLINK "javascript:alert(1)" ')
      ..text('\x14', special)
      ..text('bad')
      ..text('\x15', special)
      ..text(' ')
      ..text('\x13', special)
      ..text(r' INCLUDEPICTURE "http://example.com/x.png" \d ')
      ..text('\x14', special)
      ..text('cached')
      ..text('\x15', special)
      ..text(' ')
      ..text('\x13', special)
      ..text(' MERGEFIELD Name ')
      ..text('\x14', special)
      ..text('«Name»', bold)
      ..text('\x15', special)
      ..text(' ')
      ..text('\x13', special)
      ..text(' NUMPAGES ')
      ..text('\x14', special)
      ..text('9')
      ..text('\x15', special)
      ..paragraph();
    final loaded = _decode(doc.build());
    final delta = loaded.delta;
    final package = loaded.source! as DocxPackage;
    final document = package.text('word/document.xml')!;

    expect(_op(delta, 'site').attributes?['link'], 'https://example.com/a?b=1');
    expect(_op(delta, 'back').attributes?['link'], '#Target');
    expect(_op(delta, 'bad').attributes?['link'], isNull);
    expect(_op(delta, 'cached').attributes, isNull);
    expect(_op(delta, '«Name»').attributes?['bold'], isTrue);
    expect(_line(delta, 'Target')?[HiddenAttributes.bookmarks], '["Target"]');
    expect(document, isNot(contains('INCLUDEPICTURE')));
    expect(document, isNot(contains('MERGEFIELD')));
    expect(document, isNot(contains('javascript')));
    expect(
      _embeds(delta, EmbedTypes.opaqueInline).map(
        (embed) => fieldNameOf(
          OpaqueContent.decode(embed[EmbedTypes.opaqueInline]).xml,
        ),
      ),
      ['NUMPAGES'],
    );
  });

  test('fields nested in fields and spanning paragraphs', () {
    final doc = DocWriter()
      ..text('\x13', special)
      ..text(' TOC ')
      ..text('\x14', special)
      ..text('\x13', special)
      ..text(r' HYPERLINK \l "_Toc1" ')
      ..text('\x14', special)
      ..text('Entry\t')
      ..text('\x13', special)
      ..text(r' PAGEREF _Toc1 \h ')
      ..text('\x14', special)
      ..text('4')
      ..text('\x15', special)
      ..text('\x15', special)
      ..paragraph()
      ..text('\x13', special)
      ..text(' HYPERLINK "https://example.com/" ')
      ..text('\x14', special)
      ..text('two')
      ..paragraph()
      ..text('lines')
      ..text('\x15', special)
      ..text('\x15', special)
      ..paragraph()
      ..bookmarks.add(('_Toc1', 0, 0));
    final delta = _decode(doc.build()).delta;

    expect(_op(delta, 'Entry').attributes?['link'], '#_Toc1');
    expect(_op(delta, 'two').attributes?['link'], 'https://example.com/');
    expect(_op(delta, 'lines').attributes?['link'], 'https://example.com/');
    final pageReference = _embeds(delta, EmbedTypes.opaqueInline).single;
    expect(
      fieldNameOf(
        OpaqueContent.decode(pageReference[EmbedTypes.opaqueInline]).xml,
      ),
      'PAGEREF',
    );
  });

  test('footnotes, endnotes, comments and their notices', () {
    final doc = DocWriter()
      ..text('see')
      ..text('\x02', special)
      ..text(' and ')
      ..text('\x05', special)
      ..text(' end')
      ..text('*')
      ..paragraph();
    doc.mainLength = doc.position;
    doc
      ..footnotes.add((3, 0, 12))
      ..comments.add(9)
      ..text('\x02', special)
      ..text(' The note.')
      ..paragraph();
    doc.footnoteLength = doc.position - doc.mainLength;
    final commentStart = doc.position;
    doc
      ..text('\x05', special)
      ..text(' A comment.')
      ..paragraph();
    doc.commentLength = doc.position - commentStart;
    final endnoteStart = doc.position;
    doc
      ..endnotes.add((14, 0, 11))
      ..text('*')
      ..text(' Closing.')
      ..paragraph();
    doc.endnoteLength = doc.position - endnoteStart;
    final loaded = _decode(doc.build());
    final package = loaded.source! as DocxPackage;

    expect(package.text('word/footnotes.xml'), contains('The note.'));
    expect(package.text('word/footnotes.xml'), isNot(contains(' The note')));
    expect(package.text('word/endnotes.xml'), contains('* Closing.'));
    expect(package.text('word/document.xml'), isNot(contains('A comment')));
    expect(_text(loaded.delta), 'see and  end\n');
    expect(
      _embeds(loaded.delta, EmbedTypes.opaqueInline).map(
        (embed) => OpaqueContent.decode(embed[EmbedTypes.opaqueInline]).label,
      ),
      [OpaqueLabels.note, OpaqueLabels.note],
    );
    expect(loaded.notices, contains(DocumentNotice.commentsHidden));
  });

  test('sections, headers and footers of the last section', () {
    final doc = DocWriter()..line('first');
    final firstSection = doc.position;
    doc.line('second');
    doc.mainLength = doc.position;
    // PlcfHdd bounds: six empty note separators, then each section's even
    // header, odd header, even footer, odd footer, first page header and
    // first page footer.
    final stories = [for (var index = 0; index < 7; index++) 0];
    void story(String? text) {
      if (text != null) {
        doc
          ..text('\x13', special)
          ..text(' PAGE ')
          ..text('\x14', special)
          ..text('1')
          ..text('\x15', special)
          ..text(' $text')
          ..paragraph();
      }
      stories.add(doc.position - doc.mainLength);
    }

    story(null);
    story('odd one');
    story(null);
    story('footer one');
    story('first page');
    story(null);
    story(null);
    story(null);
    story(null);
    story('footer two');
    story(null);
    story(null);
    doc
      ..headerLength = doc.position - doc.mainLength
      ..headerStories = stories
      ..sections.add((firstSection, sprm(Sprm.sBkc, [2])))
      ..sections.add((
        doc.mainLength,
        [
          ...sprm(Sprm.sXaPage, u16(16838)),
          ...sprm(Sprm.sYaPage, u16(11906)),
          ...sprm(Sprm.sDxaLeft, u16(720)),
          ...sprm(Sprm.sDxaRight, u16(720)),
          ...sprm(Sprm.sDyaTop, u16(-1440 & 0xFFFF)),
          ...sprm(Sprm.sFTitlePage, [1]),
          ...sprm(Sprm.sBkc, [0]),
        ],
      ));
    final loaded = _decode(doc.build());
    final headers = loaded.headersFooters;

    expect(loaded.look.pageWidth, closeTo(841.9, 0.1));
    expect(loaded.look.margins.left, 36);
    expect(loaded.look.margins.top, 72);
    expect(_embeds(loaded.delta, EmbedTypes.sectionBreak), hasLength(1));
    expect(headers.differentFirstPage, isTrue);
    String textOf(Map<PageVariant, HeaderFooterStory> stories, PageVariant v) =>
        stories[v]!.delta
            .toList()
            .map((o) => o.data is String ? o.data : '#')
            .join();
    expect(textOf(headers.headers, PageVariant.normal), '# odd one\n');
    expect(textOf(headers.headers, PageVariant.first), '# first page\n');
    expect(textOf(headers.footers, PageVariant.normal), '# footer two\n');
    final field = headers.headers[PageVariant.normal]!.delta.first.data as Map;
    expect(
      fieldNameOf(OpaqueContent.decode(field[EmbedTypes.opaqueInline]).xml),
      'PAGE',
    );
  });

  test('tables keep cells, spans, merges, fills, header rows and nesting', () {
    final row = [
      ...inTable(),
      ...sprm(Sprm.pFTtp, [1]),
    ];
    final doc = DocWriter()
      ..line('before')
      ..text('wide')
      ..paragraph(sprms: inTable(), mark: '\x07')
      // Word 97 keeps the cells merged into another, empty.
      ..paragraph(sprms: inTable(), mark: '\x07')
      ..text('right')
      ..paragraph(sprms: inTable(), mark: '\x07')
      ..paragraph(
        sprms: [
          ...row,
          ...rowDefinition([0, 2000, 4000, 6000], flags: [0x01, 0x02, 0x60]),
          ...sprm(Sprm.tTableHeader, [1]),
          ...sprm(Sprm.tDefTableShd80, [...u16(0), ...u16(0), ...u16(7 << 5)]),
        ],
        mark: '\x07',
      )
      ..text('a')
      ..paragraph(sprms: inTable(), mark: '\x07')
      ..text('inner')
      ..paragraph(
        sprms: [
          ...inTable(2),
          ...sprm(Sprm.pFInnerTableCell, [1]),
        ],
      )
      ..paragraph(
        sprms: [
          ...inTable(2),
          ...sprm(Sprm.pFInnerTtp, [1]),
          ...rowDefinition([0, 1500]),
        ],
      )
      ..paragraph(sprms: inTable(), mark: '\x07')
      ..paragraph(sprms: inTable(), mark: '\x07')
      ..paragraph(
        sprms: [
          ...row,
          ...rowDefinition([0, 2000, 4000, 6000], flags: [0, 0, 0x20]),
        ],
        mark: '\x07',
      )
      ..line('after');
    final tables = TableStore();
    final loaded = _decode(doc.build(), tables);
    final table = _table(loaded.delta, tables);

    expect(_text(loaded.delta), startsWith('before\n'));
    expect(_text(loaded.delta), endsWith('after\n'));
    expect(table.bordered, isTrue);
    expect(table.columnWidths, [2000, 2000, 2000]);
    expect(table.rows, hasLength(2));
    expect(table.rows.first.cells.map(_cellText), ['wide', 'right']);
    expect(table.rows.first.cells.first.gridSpan, 2);
    expect(table.rows.first.cells.last.verticalMerge, VerticalMerge.restart);
    expect(table.rows.first.cells.last.fill?.toARGB32(), 0xFFFFFF00);
    expect(table.rows.first.propertiesXml, contains('tblHeader'));
    expect(
      table.rows.last.cells.last.verticalMerge,
      VerticalMerge.continuation,
    );
    final nested = table.rows.last.cells[1].controller.document.toDelta();
    final inner = _table(nested, tables);
    expect(_cellText(inner.rows.single.cells.single), 'inner');
  });

  test('inline and floating pictures, and the ones left out', () {
    final doc = DocWriter();
    final inline = doc.addPicture(png, width: 2880, height: 1440);
    final linked = doc.addPicture(png, mode: 0x66);
    final pict = doc.addPicture(png, blipType: 0xF01C, instance: 0x542);
    final blip = [
      ...u16(0x6E0 << 4),
      ...u16(0xF01E),
      ...u32(17 + png.length),
      ...List.filled(16, 1),
      0xFF,
      ...png,
    ];
    final blipOffset = doc.addToDocument(blip);
    doc
      ..text('\x01', [...special, ...sprm(Sprm.cPicLocation, u32(inline))])
      ..text('\x01', [...special, ...sprm(Sprm.cPicLocation, u32(linked))])
      ..text('\x01', [...special, ...sprm(Sprm.cPicLocation, u32(pict))])
      ..text('\x08', special)
      ..paragraph()
      ..floatingAnchors.add((3, 1025, 1440, 2880))
      ..drawings = officeArt(
        shapes: {1025: 1},
        store: [(blip.length, blipOffset)],
      );
    final loaded = _decode(doc.build());
    final images = _ops(loaded.delta)
        .where(
          (operation) =>
              operation.data is Map &&
              (operation.data as Map).containsKey(EmbedTypes.image),
        )
        .toList();

    expect(images, hasLength(2));
    expect(images.first.attributes?['width'], '144');
    expect(images.first.attributes?['height'], '72');
    expect(
      (images.first.data as Map)[EmbedTypes.image],
      startsWith('data:image/png;base64,'),
    );
    expect(images.last.attributes?['width'], '72');
    expect(images.last.attributes?['height'], '144');
    expect(loaded.notices, contains(DocumentNotice.contentNotImported));
  });

  test('tracked changes are accepted', () {
    final doc = DocWriter()
      ..text('kept ')
      ..text('removed ', sprm(Sprm.cFRMarkDel, [1]))
      ..text('added', sprm(Sprm.cFRMarkIns, [1]))
      ..text('\r', sprm(Sprm.cFRMarkDel, [1]));
    doc
      ..paragraph(mark: '')
      ..line(' joined');
    final loaded = _decode(doc.build());

    expect(_text(loaded.delta), 'kept added joined\n');
    expect(loaded.notices, contains(DocumentNotice.trackedChangesAccepted));
  });

  test('symbols, breaks and special characters', () {
    final doc = DocWriter()
      ..fonts.add('Wingdings')
      ..text('(', sprm(Sprm.cSymbol, [...u16(1), ...u16(0xF061)]))
      ..text('(', [
        ...special,
        ...sprm(Sprm.cSymbol, [...u16(3), ...u16(0xF0FC)]),
      ])
      ..text('(', [
        ...special,
        ...sprm(Sprm.cSymbol, [...u16(3), ...u16(0xF021)]),
      ])
      ..text('\uF0B7', font(1))
      ..text('a\tb\x0Bc\x1Ed\x1Fe\u00A0f\x0Eg\x0Ch\x07i')
      ..paragraph();
    final delta = _decode(doc.build()).delta;
    final text = _text(delta);

    expect(text, startsWith('α✔\uF021•a\tb\u2028c\u2011d\u00ADe\u00A0f'));
    expect(_op(delta, '\uF021').attributes?['font'], 'Wingdings');
    expect(_op(delta, 'α').attributes?['font'], isNull);
    expect(_embeds(delta, EmbedTypes.pageBreak), hasLength(1));
    expect(text, contains('hi'));
  });

  test('8-bit text uses the Windows code page', () {
    final doc = DocWriter()
      ..compressed = true
      ..line('café \u0093quoted\u0094 \u0080');
    expect(_text(_decode(doc.build()).delta), 'café “quoted” €\n');
  });

  test('a file made by another program opens', () {
    final tables = TableStore();
    final loaded = _decode(
      File('test/fixtures/doc/textutil.doc').readAsBytesSync(),
      tables,
    );
    final delta = loaded.delta;

    expect(_text(delta), contains('Plain bold italic under strike red big'));
    expect(_text(delta), contains('café € “quotes”'));
    expect(_op(delta, 'bold').attributes?['bold'], isTrue);
    expect(_op(delta, 'italic').attributes?['italic'], isTrue);
    expect(_op(delta, 'big').attributes?['font'], 'Georgia');
    expect(_line(delta, 'centered')?['align'], 'center');
    final table = _table(delta, tables);
    expect(table.rows.first.cells.map(_cellText), ['a1', 'b1']);
    expect(table.rows.last.cells.single.gridSpan, 2);
    expect(table.rows.last.cells.single.fill?.toARGB32(), 0xFFFFFF00);
    expect(loaded.look.pageWidth, 612);
  });

  test('saving as .docx keeps what was read', () {
    final doc = DocWriter()
      ..styles[1] = const StyleFixture.paragraph(
        'heading 1',
        builtIn: 1,
        base: 0,
      )
      ..line('Heading', style: 1)
      ..text('bold', bold)
      ..text(' and ')
      ..text('\x13', special)
      ..text(' HYPERLINK "https://example.com/" ')
      ..text('\x14', special)
      ..text('link')
      ..text('\x15', special)
      ..paragraph();
    final bullets = doc.addList([
      (format: 23, text: '•', start: 1, left: 720, hanging: 360, font: null),
    ]);
    doc
      ..line('item', sprms: DocWriter.listParagraph(bullets))
      ..text('\x01', [
        ...special,
        ...sprm(Sprm.cPicLocation, u32(doc.addPicture(png))),
      ])
      ..paragraph()
      ..text('cell')
      ..paragraph(sprms: inTable(), mark: '\x07')
      ..paragraph(
        sprms: [
          ...inTable(),
          ...sprm(Sprm.pFTtp, [1]),
          ...rowDefinition([0, 3000]),
        ],
        mark: '\x07',
      )
      ..line('end');
    doc.mainLength = doc.position;
    doc
      ..text('header')
      ..paragraph();
    doc
      ..headerLength = doc.position - doc.mainLength
      // Empty separators and even header, then the odd header; the other
      // stories are empty.
      ..headerStories = [
        for (var index = 0; index < 8; index++) 0,
        for (var index = 0; index < 6; index++) doc.headerLength,
      ]
      ..sections.add((
        doc.mainLength,
        [...sprm(Sprm.sXaPage, u16(11906)), ...sprm(Sprm.sYaPage, u16(16838))],
      ));

    final tables = TableStore();
    final codec = DocxCodec(tables);
    final loaded = DocCodec(codec).decode(doc.build());
    final saved = codec.encode(
      loaded.delta,
      source: loaded.source,
      look: loaded.look,
      headersFooters: loaded.headersFooters,
    );
    final reopened = codec.decode(saved);
    final delta = reopened.delta;

    expect(_text(delta), _text(loaded.delta));
    expect(_line(delta, 'Heading')?['header'], 1);
    expect(_op(delta, 'bold').attributes?['bold'], isTrue);
    expect(_op(delta, 'link').attributes?['link'], 'https://example.com/');
    expect(_line(delta, 'item')?['list'], 'bullet');
    expect(_embeds(delta, EmbedTypes.image), hasLength(1));
    expect(
      _cellText(_table(delta, tables, 0).rows.single.cells.single),
      'cell',
    );
    expect(reopened.look.pageWidth, closeTo(595.3, 0.1));
    final header = reopened.headersFooters.headers[PageVariant.normal]!;
    expect(header.delta.toList().first.data, 'header\n');
  });

  test('problems are reported, not thrown as crashes', () {
    DocumentProblem? problem(Uint8List bytes) {
      try {
        _decode(bytes);
        return null;
      } on DocumentProblemException catch (error) {
        return error.problem;
      }
    }

    expect(
      problem(Uint8List.fromList('not a document'.codeUnits)),
      DocumentProblem.notWordDocument,
    );
    expect(
      problem(compoundFile({'Workbook': List.filled(5000, 1)})),
      DocumentProblem.notWordDocument,
    );
    expect(
      problem(
        compoundFile({
          'EncryptionInfo': [1, 2, 3],
          'EncryptedPackage': List.filled(100, 0),
        }),
      ),
      DocumentProblem.passwordProtected,
    );
    expect(
      problem(
        (DocWriter()
              ..encrypted = true
              ..line('secret'))
            .build(),
      ),
      DocumentProblem.passwordProtected,
    );
    expect(
      problem(
        (DocWriter()
              ..version = 0x68
              ..line('Word 95'))
            .build(),
      ),
      DocumentProblem.legacyDoc,
    );
    expect(
      problem(
        (DocWriter()
              ..version = 0xC0
              ..line('new'))
            .build(),
      ),
      isNull,
    );
  });

  test('the editor opens .doc to save as .docx, and .dot as a new one', () {
    final tables = TableStore();
    final docx = DocxCodec(tables);
    EditorSession session() => EditorSession(
      docx: docx,
      plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
      files: DocumentFiles(),
      tables: tables,
    );
    final bytes = (DocWriter()..line('Dear')).build();

    final document = session()
      ..open(OpenedFile(name: 'old.doc', bytes: bytes, path: '/t/old.doc'));
    expect(document.format, DocumentFormat.doc);
    expect(document.notices, contains(DocumentNotice.savesAsDocx));
    expect(document.controller.document.toPlainText(), 'Dear\n');

    final template = session()
      ..open(
        OpenedFile(name: 'Letter.dot', bytes: bytes, path: '/t/Letter.dot'),
      );
    expect(template.isUntitled, isTrue);
    expect(template.format, DocumentFormat.docx);
    expect(template.controller.document.toPlainText(), 'Dear\n');
  });

  test('macros are noticed and never kept', () {
    final doc = DocWriter()
      ..streams['Macros'] = List.filled(10, 0)
      ..line('text');
    final loaded = _decode(doc.build());
    final package = loaded.source! as DocxPackage;
    expect(loaded.notices, contains(DocumentNotice.contentNotImported));
    expect(package.parts.keys.where((name) => name.contains('vba')), isEmpty);
  });
}
