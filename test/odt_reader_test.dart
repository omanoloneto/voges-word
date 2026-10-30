import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/delta_blocks.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/headers_footers.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_numbering.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/docx/word_list_counter.dart';
import 'package:voges_word/formats/document_codecs.dart';
import 'package:voges_word/odt/odt_codec.dart';

import 'odt_fixtures.dart';

late TableStore _tables;

LoadedDocument _decode(Uint8List bytes) {
  _tables = TableStore();
  return OdtCodec(DocxCodec(_tables)).decode(bytes);
}

DocxPackage _package(LoadedDocument loaded) => loaded.source! as DocxPackage;

/// Each paragraph's list label as Word counts it, which every writer shows.
Map<String, String?> _labels(LoadedDocument loaded) {
  final counter = WordListCounter(DocxNumbering.of(loaded.source));
  final labels = <String, String?>{};
  for (final line in documentBlocks(loaded.delta).whereType<LineBlock>()) {
    counter.count(line);
    labels[line.plainText] = counter.textOf(line);
  }
  return labels;
}

String _plain(Delta delta) => [
  for (final operation in delta.toList())
    if (operation.data is String) operation.data as String,
].join();

TableModel _table(Delta delta, [int index = 0]) =>
    _tables[tableIdOf(embedsOf(delta, EmbedTypes.table)[index])]!;

String _cellText(TableCellModel cell) =>
    _plain(cell.controller.document.toDelta()).trim();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a LibreOffice document keeps its styles, headings and formatting', () {
    final loaded = _decode(
      odtFile(
        automatic: '''
<style:style style:name="P1" style:family="paragraph" style:parent-style-name="Text_20_body"><style:paragraph-properties fo:text-align="center"/></style:style>
<style:style style:name="P2" style:family="paragraph" style:parent-style-name="Heading_20_2"><style:text-properties fo:color="#2e74b5"/></style:style>
<style:style style:name="T1" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style>
<style:style style:name="T2" style:family="text"><style:text-properties fo:font-style="italic"/></style:style>
<style:style style:name="T3" style:family="text"><style:text-properties style:text-underline-style="solid" style:text-underline-width="auto"/></style:style>
<style:style style:name="T4" style:family="text"><style:text-properties style:text-line-through-style="solid"/></style:style>
<style:style style:name="T5" style:family="text"><style:text-properties fo:font-size="18pt" style:font-name="Liberation Sans" fo:color="#c00000" fo:background-color="#ffff00"/></style:style>
<style:style style:name="T6" style:family="text"><style:text-properties style:text-position="super 58%"/></style:style>
<style:style style:name="T7" style:family="text"><style:text-properties style:text-position="-33% 58%"/></style:style>
<style:style style:name="T8" style:family="text"><style:text-properties fo:font-size="50%"/></style:style>
''',
        body:
            '<text:h text:style-name="Heading_20_1" text:outline-level="1">Title</text:h>'
            '<text:p text:style-name="Text_20_body">plain '
            '<text:span text:style-name="T1">bold</text:span> '
            '<text:span text:style-name="T2">italic</text:span> '
            '<text:span text:style-name="T3">under</text:span> '
            '<text:span text:style-name="T4">struck</text:span> '
            '<text:span text:style-name="T5">styled</text:span> '
            'x<text:span text:style-name="T6">sup</text:span> '
            'H<text:span text:style-name="T7">sub</text:span>O '
            '<text:span text:style-name="T8">half</text:span></text:p>'
            '<text:p text:style-name="P1">centered</text:p>'
            '<text:h text:style-name="P2" text:outline-level="2">Second</text:h>'
            '<text:p text:style-name="Quotations">quote '
            '<text:span text:style-name="Strong_20_Emphasis">strong</text:span></text:p>',
      ),
    );
    final delta = loaded.delta;

    expect(lineOf(delta, 'Title')?['header'], 1);
    expect(textOperation(delta, 'bold').attributes?['bold'], isTrue);
    expect(textOperation(delta, 'italic').attributes?['italic'], isTrue);
    expect(textOperation(delta, 'under').attributes?['underline'], isTrue);
    expect(textOperation(delta, 'struck').attributes?['strike'], isTrue);
    expect(textOperation(delta, 'styled').attributes, {
      'size': '18',
      'font': 'Liberation Sans',
      'color': '#C00000',
      'background': '#FFFF00',
    });
    expect(textOperation(delta, 'sup').attributes?['script'], 'super');
    expect(textOperation(delta, 'sub').attributes?['script'], 'sub');
    expect(textOperation(delta, 'half').attributes?['size'], '6');
    expect(lineOf(delta, 'plain')?['line-height'], 1.15);
    expect(lineOf(delta, 'plain')?[HiddenAttributes.spaceAfter], 7);
    expect(lineOf(delta, 'centered')?['align'], 'center');
    expect(lineOf(delta, 'Second')?['header'], 2);
    expect(textOperation(delta, 'Second').attributes?['color'], '#2E74B5');
    expect(lineOf(delta, 'quote')?['indent'], 1);
    expect(textOperation(delta, 'strong').attributes?['bold'], isTrue);

    final look = loaded.look;
    expect(look.body.fontFamily, 'Liberation Serif');
    expect(look.body.fontSize, 12);
    expect(look.lineSpacing, 1);
    // 130% and 115% of 14pt, in Word's half points.
    expect(look.headings[1]?.fontSize, 18);
    expect(look.headings[1]?.fontFamily, 'Liberation Sans');
    expect(look.headings[1]?.bold, isTrue);
    expect(look.headings[2]?.fontSize, 16);
    expect(look.pageWidth, closeTo(595.3, 0.1));
    expect(look.margins.left, closeTo(56.7, 0.05));

    final styles = _package(loaded).text('word/styles.xml')!;
    expect(styles, contains('w:lang w:val="pt-BR"'));
    for (final name in ['Text body', 'Quotations', 'Strong Emphasis']) {
      expect(styles, contains('w:val="$name"'));
    }
    expect(loaded.notices, isEmpty);
  });

  test('lists keep their kinds, levels, numbering and continuations', () {
    const alignment =
        '<style:list-level-properties text:list-level-position-and-space-mode="label-alignment">'
        '<style:list-level-label-alignment text:label-followed-by="listtab" '
        'fo:text-indent="-0.635cm" fo:margin-left="1.27cm"/></style:list-level-properties>';
    final loaded = _decode(
      odtFile(
        automatic:
            '<text:list-style style:name="L1">'
            '<text:list-level-style-bullet text:level="1" text:bullet-char="●">$alignment</text:list-level-style-bullet>'
            '<text:list-level-style-bullet text:level="2" text:bullet-char="○">$alignment</text:list-level-style-bullet>'
            '</text:list-style>'
            '<text:list-style style:name="L2">'
            '<text:list-level-style-number text:level="1" style:num-suffix="." style:num-format="1">$alignment</text:list-level-style-number>'
            '<text:list-level-style-number text:level="2" style:num-suffix=")" style:num-format="a" text:display-levels="2">$alignment</text:list-level-style-number>'
            '</text:list-style>'
            '<text:list-style style:name="L3">'
            '<text:list-level-style-number text:level="1" style:num-format="I"/>'
            '</text:list-style>',
        body:
            '<text:list xml:id="list1" text:style-name="L1">'
            '<text:list-item><text:p>dot one</text:p>'
            '<text:list><text:list-item><text:p>dot nested</text:p></text:list-item></text:list>'
            '</text:list-item>'
            '<text:list-item><text:p>dot two</text:p><text:p>dot more</text:p></text:list-item>'
            '</text:list>'
            '<text:list text:style-name="L2">'
            '<text:list-item><text:p>first</text:p>'
            '<text:list><text:list-item><text:p>sub a</text:p></text:list-item></text:list>'
            '</text:list-item>'
            '<text:list-header><text:p>no number</text:p></text:list-header>'
            '</text:list>'
            '<text:p>between</text:p>'
            '<text:list text:style-name="L2" text:continue-numbering="true">'
            '<text:list-item><text:p>second</text:p></text:list-item></text:list>'
            '<text:list text:style-name="L2">'
            '<text:list-item><text:p>restart</text:p></text:list-item></text:list>'
            '<text:list text:continue-list="list1">'
            '<text:list-item><text:p>dot again</text:p></text:list-item></text:list>'
            '<text:list text:style-name="L3">'
            '<text:list-item text:start-value="5"><text:p>roman</text:p></text:list-item></text:list>',
      ),
    );
    final delta = loaded.delta;
    Object? number(String text) =>
        lineOf(delta, text)?[HiddenAttributes.numbering];

    expect(lineOf(delta, 'dot one')?['list'], 'bullet');
    expect(lineOf(delta, 'dot nested')?['list'], 'bullet');
    expect(lineOf(delta, 'dot nested')?['indent'], 1);
    expect(number('dot nested'), number('dot one'));
    expect(number('dot two'), number('dot one'));
    expect(lineOf(delta, 'dot more')?['list'], isNull);
    expect(lineOf(delta, 'dot more')?['indent'], 1);
    expect(lineOf(delta, 'first')?['list'], 'ordered');
    expect(lineOf(delta, 'sub a')?['list'], 'ordered');
    expect(lineOf(delta, 'sub a')?['indent'], 1);
    expect(lineOf(delta, 'no number')?['list'], isNull);
    expect(lineOf(delta, 'between')?['list'], isNull);
    expect(number('second'), number('first'));
    expect(number('restart'), isNot(number('first')));
    expect(number('dot again'), number('dot one'));
    expect(lineOf(delta, 'roman')?['list'], 'ordered');

    final numbering = _package(loaded).text('word/numbering.xml')!;
    expect(numbering, contains('w:lvlText w:val="●"'));
    expect(numbering, contains('w:lvlText w:val="%1.%2)"'));
    expect(numbering, contains('w:numFmt w:val="upperRoman"'));
    expect(numbering, contains('w:start w:val="5"'));
  });

  test('tables keep widths, spans, merges, header rows, fills and nesting', () {
    final loaded = _decode(
      odtFile(
        automatic:
            '<style:style style:name="Table1" style:family="table"><style:table-properties style:width="12cm" table:align="left"/></style:style>'
            '<style:style style:name="Table1.A" style:family="table-column"><style:table-column-properties style:column-width="4cm"/></style:style>'
            '<style:style style:name="Table1.A1" style:family="table-cell"><style:table-cell-properties fo:padding="0.1cm" fo:border="0.5pt solid #000000" fo:background-color="#d9e2f3"/></style:style>'
            '<style:style style:name="Table1.B2" style:family="table-cell"><style:table-cell-properties fo:border="none" style:vertical-align="middle"/></style:style>',
        body:
            '<table:table table:name="Table1" table:style-name="Table1">'
            '<table:table-column table:style-name="Table1.A" table:number-columns-repeated="3"/>'
            '<table:table-header-rows><table:table-row>'
            '<table:table-cell table:style-name="Table1.A1" table:number-columns-spanned="2" office:value-type="string"><text:p>wide</text:p></table:table-cell>'
            '<table:covered-table-cell/>'
            '<table:table-cell table:number-rows-spanned="2"><text:p>tall</text:p></table:table-cell>'
            '</table:table-row></table:table-header-rows>'
            '<table:table-row>'
            '<table:table-cell><text:p>a</text:p></table:table-cell>'
            '<table:table-cell table:style-name="Table1.B2"><table:table>'
            '<table:table-column/><table:table-row><table:table-cell><text:p>inner</text:p></table:table-cell></table:table-row>'
            '</table:table></table:table-cell>'
            '<table:covered-table-cell/>'
            '</table:table-row>'
            '<table:table-row table:number-rows-repeated="2">'
            '<table:table-cell table:number-columns-repeated="3"><text:p>r</text:p></table:table-cell>'
            '</table:table-row>'
            '</table:table>',
      ),
    );
    final table = _table(loaded.delta);

    expect(table.columnWidths, [2268, 2268, 2268]);
    expect(table.bordered, isTrue);
    expect(table.rows, hasLength(4));
    final header = table.rows.first;
    expect(header.propertiesXml, contains('tblHeader'));
    expect(header.cells.first.gridSpan, 2);
    expect(header.cells.first.fill?.toARGB32(), 0xFFD9E2F3);
    expect(_cellText(header.cells.first), 'wide');
    expect(header.cells.last.verticalMerge, VerticalMerge.restart);
    final second = table.rows[1];
    expect(second.cells, hasLength(3));
    expect(second.cells.last.verticalMerge, VerticalMerge.continuation);
    final nested = second.cells[1].controller.document.toDelta();
    expect(embedsOf(nested, EmbedTypes.table), hasLength(1));
    for (final row in table.rows.skip(2)) {
      expect(row.cells.map(_cellText), ['r', 'r', 'r']);
    }
  });

  test('notes, fields, links, bookmarks, breaks and spaces', () {
    final loaded = _decode(
      odtFile(
        automatic:
            '<style:style style:name="P1" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:break-before="page"/></style:style>'
            '<style:style style:name="P2" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:break-after="page"/></style:style>',
        body:
            '<text:p><text:bookmark text:name="start"/>see'
            '<text:note text:id="ftn1" text:note-class="footnote"><text:note-citation>1</text:note-citation>'
            '<text:note-body><text:p>the note</text:p></text:note-body></text:note> and'
            '<text:note text:id="edn1" text:note-class="endnote"><text:note-citation>i</text:note-citation>'
            '<text:note-body><text:p>the end</text:p></text:note-body></text:note></text:p>'
            '<text:p><text:a xlink:type="simple" xlink:href="https://example.com/?a=1&amp;b=2">site</text:a> '
            '<text:a xlink:href="javascript:alert(1)">bad</text:a> '
            '<text:a xlink:href="#start">back</text:a> '
            '<text:a xlink:href="file:///etc/passwd">local</text:a></text:p>'
            '<text:p>  lead<text:s text:c="3"/>gap  collapsed<text:tab/>tab'
            '<text:line-break/>next<text:soft-page-break/> end <text:bookmark text:name="b"/> mark</text:p>'
            '<text:p><text:date>29/10/2026</text:date> <text:page-number>4</text:page-number>/'
            '<text:page-count>9</text:page-count></text:p>'
            '<text:p text:style-name="P2">before break</text:p>'
            '<text:p>after break</text:p>'
            '<text:p text:style-name="P1">new page</text:p>',
      ),
    );
    final delta = loaded.delta;

    final notes = opaqueOf(
      delta,
    ).where((content) => content.label == OpaqueLabels.note);
    expect(notes, hasLength(2));
    expect(_package(loaded).text('word/footnotes.xml'), contains('the note'));
    expect(_package(loaded).text('word/endnotes.xml'), contains('the end'));
    expect(
      lineOf(delta, 'see')?[HiddenAttributes.bookmarks],
      contains('start'),
    );

    expect(
      textOperation(delta, 'site').attributes?['link'],
      'https://example.com/?a=1&b=2',
    );
    expect(textOperation(delta, 'bad').attributes?['link'], isNull);
    expect(textOperation(delta, 'back').attributes?['link'], '#start');
    expect(textOperation(delta, 'local').attributes?['link'], isNull);

    expect(_plain(delta), contains('lead   gap collapsed\ttab next end mark'));
    expect(_plain(delta), contains('29/10/2026'));
    final fields = {
      for (final content in opaqueOf(delta))
        ?fieldNameOf(content.xml): content.text,
    };
    expect(fields, {'PAGE': '4', 'NUMPAGES': '9'});

    final operations = operationsOf(delta);
    bool afterBreak(String text) {
      final index = operations.indexWhere(
        (operation) =>
            operation.data is String &&
            (operation.data as String).startsWith(text),
      );
      final previous = operations[index - 1].data;
      return previous is Map && previous.containsKey(EmbedTypes.pageBreak);
    }

    expect(afterBreak('after break'), isTrue);
    expect(afterBreak('new page'), isTrue);
    expect(embedsOf(delta, EmbedTypes.pageBreak), hasLength(2));
  });

  test('pictures come only from inside the file', () {
    final loaded = _decode(
      odtFile(
        body:
            '<text:p>pic <draw:frame draw:name="a" text:anchor-type="as-char" svg:width="2cm" svg:height="1cm">'
            '<draw:image xlink:href="Pictures/pixel.png" xlink:type="simple"/><svg:desc>a pixel</svg:desc></draw:frame></text:p>'
            '<text:p><draw:frame svg:width="1in" svg:height="1in"><draw:image>'
            '<office:binary-data>${base64Encode(pngPixel)}</office:binary-data></draw:image></draw:frame></text:p>'
            '<text:p>remote <draw:frame svg:width="1in" svg:height="1in">'
            '<draw:image xlink:href="http://example.com/x.png"/></draw:frame></text:p>'
            '<text:p>escape <draw:frame><draw:image xlink:href="Pictures/../outside.png"/></draw:frame></text:p>'
            '<text:p>vector <draw:frame><draw:image xlink:href="Pictures/drawing.svg"/></draw:frame></text:p>'
            '<text:p>anchor<draw:frame text:anchor-type="paragraph"><draw:text-box>'
            '<text:p>caption <draw:frame svg:width="1cm" svg:height="1cm">'
            '<draw:image xlink:href="./Pictures/pixel.png"/></draw:frame></text:p>'
            '</draw:text-box></draw:frame></text:p>'
            '<text:p>shape<draw:custom-shape><text:p>shape text</text:p></draw:custom-shape></text:p>',
        extra: {
          'Pictures/pixel.png': pngPixel,
          'outside.png': pngPixel,
          'Pictures/drawing.svg': '<svg xmlns="http://www.w3.org/2000/svg"/>',
        },
      ),
    );
    final delta = loaded.delta;
    final images = [
      for (final operation in operationsOf(delta))
        if (operation.data case {EmbedTypes.image: final String _}) operation,
    ];

    expect(images, hasLength(3));
    expect(images.first.attributes?['width'], '56.69');
    expect(images.first.attributes?['height'], '28.35');
    expect(
      _package(loaded).text('word/document.xml'),
      contains('descr="a pixel"'),
    );
    final text = _plain(delta);
    expect(text.indexOf('caption'), greaterThan(text.indexOf('anchor')));
    expect(text, isNot(contains('shape text')));
    expect(loaded.notices, contains(DocumentNotice.contentNotImported));
  });

  test('page setup, headers and footers come from the page style', () {
    final loaded = _decode(
      odtFile(
        masterAutomatic:
            '<style:page-layout style:name="pm1"><style:page-layout-properties '
            'fo:page-width="11in" fo:page-height="8.5in" style:print-orientation="landscape" '
            'fo:margin-top="0.5in" fo:margin-bottom="0.5in" fo:margin-left="1in" fo:margin-right="1in"/>'
            '<style:header-style><style:header-footer-properties fo:min-height="0.3in" fo:margin-bottom="0.2in"/></style:header-style>'
            '<style:footer-style><style:header-footer-properties fo:min-height="0.3in" fo:margin-top="0.2in"/></style:footer-style>'
            '</style:page-layout>'
            '<style:style style:name="MP1" style:family="paragraph" style:parent-style-name="Standard">'
            '<style:paragraph-properties fo:text-align="end"/></style:style>',
        masters:
            '<style:master-page style:name="Standard" style:page-layout-name="pm1">'
            '<style:header><text:p>Header text</text:p></style:header>'
            '<style:header-left><text:p>Even header</text:p></style:header-left>'
            '<style:header-first><text:p>First header</text:p></style:header-first>'
            '<style:footer><text:p text:style-name="MP1">Page '
            '<text:page-number text:select-page="current">1</text:page-number></text:p></style:footer>'
            '</style:master-page>',
      ),
    );
    final look = loaded.look;
    expect(look.pageWidth, 792);
    expect(look.pageHeight, 612);
    expect(look.margins.left, 72);
    expect(look.margins.top, closeTo(72, 0.05));
    expect(look.margins.bottom, closeTo(72, 0.05));

    final stories = loaded.headersFooters;
    String text(HeaderFooterStory? story) => _plain(story!.delta).trim();
    expect(stories.headerDistance, 36);
    expect(stories.footerDistance, 36);
    expect(stories.differentFirstPage, isTrue);
    expect(stories.differentOddEven, isTrue);
    expect(text(stories.headers[PageVariant.normal]), 'Header text');
    expect(text(stories.headers[PageVariant.even]), 'Even header');
    expect(text(stories.headers[PageVariant.first]), 'First header');
    final footer = stories.footers[PageVariant.normal]!.delta;
    expect(lineOf(footer, 'Page')?['align'], 'right');
    expect(opaqueOf(footer).map((content) => fieldNameOf(content.xml)), [
      'PAGE',
    ]);
    expect(text(stories.footers[PageVariant.first]), startsWith('Page'));
  });

  test('page styles: a first page style and a change of page size', () {
    const layouts =
        '$a4Layout<style:page-layout style:name="pm2"><style:page-layout-properties '
        'fo:page-width="29.7cm" fo:page-height="21cm" style:print-orientation="landscape" '
        'fo:margin-top="2cm" fo:margin-bottom="2cm" fo:margin-left="2cm" fo:margin-right="2cm"/>'
        '</style:page-layout>';
    const masters =
        '<style:master-page style:name="First_20_Page" style:display-name="First Page" '
        'style:page-layout-name="pm1" style:next-style-name="Standard">'
        '<style:header><text:p>Cover</text:p></style:header></style:master-page>'
        '<style:master-page style:name="Standard" style:page-layout-name="pm1">'
        '<style:header><text:p>Running</text:p></style:header></style:master-page>'
        '<style:master-page style:name="Landscape" style:page-layout-name="pm2"/>';
    const automatic =
        '<style:style style:name="P1" style:family="paragraph" style:parent-style-name="Standard" style:master-page-name="First_20_Page"/>'
        '<style:style style:name="P2" style:family="paragraph" style:parent-style-name="Standard" style:master-page-name="Landscape"/>';

    final cover = _decode(
      odtFile(
        masterAutomatic: layouts,
        masters: masters,
        automatic: automatic,
        body:
            '<text:p text:style-name="P1">cover</text:p><text:p>body</text:p>',
      ),
    );
    expect(embedsOf(cover.delta, EmbedTypes.sectionBreak), isEmpty);
    final stories = cover.headersFooters;
    expect(stories.differentFirstPage, isTrue);
    expect(_plain(stories.headers[PageVariant.first]!.delta).trim(), 'Cover');
    expect(
      _plain(stories.headers[PageVariant.normal]!.delta).trim(),
      'Running',
    );

    final sections = _decode(
      odtFile(
        masterAutomatic: layouts,
        masters: masters,
        automatic: automatic,
        body:
            '<text:p>portrait</text:p><text:p text:style-name="P2">landscape</text:p>',
      ),
    );
    final breaks = embedsOf(sections.delta, EmbedTypes.sectionBreak);
    expect(breaks, hasLength(1));
    expect(sectionXmlOf(breaks.single), contains('w:w="11906"'));
    expect(sections.look.pageWidth, closeTo(841.9, 0.1));
    expect(sections.look.isLandscape, isTrue);
  });

  test('tracked changes are accepted and comments hidden', () {
    final loaded = _decode(
      odtFile(
        body:
            '<text:tracked-changes><text:changed-region text:id="ct1"><text:deletion>'
            '<office:change-info><dc:creator xmlns:dc="http://purl.org/dc/elements/1.1/">A</dc:creator></office:change-info>'
            '<text:p>deleted words</text:p></text:deletion></text:changed-region>'
            '<text:changed-region text:id="ct2"><text:insertion><office:change-info/></text:insertion>'
            '</text:changed-region></text:tracked-changes>'
            '<text:p>kept <text:change text:change-id="ct1"/>text '
            '<text:change-start text:change-id="ct2"/>inserted<text:change-end text:change-id="ct2"/>'
            '<office:annotation><text:p>a comment</text:p></office:annotation> end'
            '<office:annotation-end/></text:p>',
      ),
    );
    final text = _plain(loaded.delta);
    expect(text, contains('kept text inserted end'));
    expect(text, isNot(contains('deleted words')));
    expect(text, isNot(contains('a comment')));
    expect(
      loaded.notices,
      containsAll([
        DocumentNotice.trackedChangesAccepted,
        DocumentNotice.commentsHidden,
      ]),
    );
  });

  test('indexes and sections keep their text', () {
    final loaded = _decode(
      odtFile(
        body:
            '<text:table-of-content text:name="TOC"><text:table-of-content-source/>'
            '<text:index-body><text:index-title><text:p>Contents</text:p></text:index-title>'
            '<text:p>Intro<text:tab/>1</text:p></text:index-body></text:table-of-content>'
            '<text:section text:name="S1"><text:p>in section</text:p>'
            '<text:section text:name="S2"><text:p>nested section</text:p></text:section></text:section>',
      ),
    );
    final text = _plain(loaded.delta);
    expect(text, contains('Contents\nIntro\t1\nin section\nnested section'));
  });

  test('templates, other producers and Word files named .odt open', () {
    final template = odtFile(
      mimetype: 'application/vnd.oasis.opendocument.text-template',
      body: '<text:p>Dear</text:p>',
    );
    expect(detectFormat('Letter.ott', template), (
      format: DocumentFormat.odt,
      template: true,
    ));
    expect(_plain(_decode(template).delta), 'Dear\n');

    // Written by macOS's TextEdit: ODF 1.0, inches and older list indents.
    final textEdit = _decode(
      File('test/fixtures/odt/textutil.odt').readAsBytesSync(),
    );
    final delta = textEdit.delta;
    expect(textOperation(delta, 'negrito').attributes?['bold'], isTrue);
    expect(lineOf(delta, 'Centralizado')?['align'], 'center');
    expect(
      textOperation(delta, 'um link').attributes?['link'],
      'https://example.com/?a=1&b=2',
    );
    expect(lineOf(delta, 'Item um')?['list'], 'bullet');
    expect(lineOf(delta, 'Sub item')?['indent'], 1);
    expect(lineOf(delta, 'Primeiro')?['list'], 'ordered');
    expect(embedsOf(delta, EmbedTypes.table), hasLength(1));
    expect(textEdit.look.pageWidth, 612);
    expect(textEdit.look.body.fontFamily, 'Times');

    final word = DocxCodec(TableStore()).encode(Delta()..insert('From Word\n'));
    expect(detectFormat('renamed.odt', word)?.format, DocumentFormat.odt);
    expect(_plain(_decode(word).delta), 'From Word\n');
  });

  test('headings outside lists take the numbers of the outline style', () {
    const heading1 = 'text:style-name="Heading_20_1" text:outline-level="1"';
    const heading2 = 'text:style-name="Heading_20_2" text:outline-level="2"';
    final loaded = _decode(
      odtFile(
        styles:
            '$libreOfficeStyles<text:outline-style style:name="Outline">'
            '<text:outline-level-style text:level="1" style:num-format="1"/>'
            '<text:outline-level-style text:level="2" style:num-format="1" text:display-levels="2"/>'
            '<text:outline-level-style text:level="3" style:num-format=""/>'
            '</text:outline-style>',
        automatic:
            '<style:style style:name="P1" style:family="paragraph" '
            'style:parent-style-name="Heading_20_1" style:list-style-name=""/>',
        body:
            '<text:h $heading1>Introduction</text:h><text:p>para</text:p>'
            '<text:h $heading2>Scope</text:h>'
            '<text:h $heading1 text:is-list-header="true">Unnumbered</text:h>'
            '<text:h text:style-name="P1" text:outline-level="1">No list</text:h>'
            '<text:h $heading1>Methods</text:h>'
            '<text:h $heading2 text:restart-numbering="true" text:start-value="5">Fifth</text:h>'
            '<text:h $heading2>Sixth</text:h>'
            '<text:h $heading1>Results</text:h>',
      ),
    );
    final delta = loaded.delta;
    Object? number(String text) =>
        lineOf(delta, text)?[HiddenAttributes.numbering];

    expect(lineOf(delta, 'Introduction')?['header'], 1);
    expect(lineOf(delta, 'Introduction')?['list'], 'ordered');
    expect(lineOf(delta, 'Scope')?['header'], 2);
    expect(lineOf(delta, 'Scope')?['list'], 'ordered');
    expect(number('Scope'), number('Introduction'));
    expect(number('Methods'), number('Introduction'));
    expect(lineOf(delta, 'para')?['list'], isNull);
    expect(lineOf(delta, 'Unnumbered')?['list'], isNull);
    expect(lineOf(delta, 'No list')?['list'], isNull);
    // Word shows 2.5 and 2.6, then 3, from lists that start there.
    expect(number('Fifth'), isNot(number('Methods')));
    expect(number('Sixth'), number('Fifth'));
    expect(number('Results'), isNot(number('Fifth')));
    final numbering = _package(loaded).text('word/numbering.xml')!;
    expect(numbering, contains('<w:lvlText w:val="%1"/>'));
    expect(numbering, contains('<w:lvlText w:val="%1.%2"/>'));
    expect(
      numbering,
      contains(
        '<w:lvl w:ilvl="0"><w:start w:val="2"/><w:numFmt w:val="decimal"/>',
      ),
    );
    expect(
      numbering,
      contains(
        '<w:lvl w:ilvl="1"><w:start w:val="5"/><w:numFmt w:val="decimal"/>',
      ),
    );
    expect(
      numbering,
      contains(
        '<w:lvl w:ilvl="0"><w:start w:val="3"/><w:numFmt w:val="decimal"/>',
      ),
    );

    // LibreOffice's default outline style numbers nothing.
    final plain = _decode(
      odtFile(
        styles:
            '$libreOfficeStyles<text:outline-style style:name="Outline">'
            '<text:outline-level-style text:level="1" style:num-format=""/>'
            '</text:outline-style>',
        body: '<text:h $heading1>Introduction</text:h>',
      ),
    );
    expect(lineOf(plain.delta, 'Introduction'), {'header': 1});
    expect(_package(plain).text('word/numbering.xml'), isNull);
  });

  test('headers and footers of an earlier page style are kept', () {
    const layouts =
        '$a4Layout<style:page-layout style:name="pm2"><style:page-layout-properties '
        'fo:page-width="29.7cm" fo:page-height="21cm" style:print-orientation="landscape" '
        'fo:margin-top="2cm" fo:margin-bottom="2cm" fo:margin-left="2cm" fo:margin-right="2cm"/>'
        '</style:page-layout>';
    const standard =
        '<style:master-page style:name="Standard" style:page-layout-name="pm1">'
        '<style:header><text:p>Company report</text:p></style:header>'
        '<style:footer><text:p>Page <text:page-number text:select-page="current">1</text:page-number></text:p></style:footer>'
        '</style:master-page>';
    const automatic =
        '<style:style style:name="P2" style:family="paragraph" '
        'style:parent-style-name="Standard" style:master-page-name="Landscape"/>';
    const body =
        '<text:p>first</text:p><text:p>second</text:p>'
        '<text:p text:style-name="P2">appendix</text:p>';

    final loaded = _decode(
      odtFile(
        masterAutomatic: layouts,
        masters:
            '$standard<style:master-page style:name="Landscape" style:page-layout-name="pm2"/>',
        automatic: automatic,
        body: body,
      ),
    );
    final stories = loaded.headersFooters;
    expect(
      _plain(stories.headers[PageVariant.normal]!.delta).trim(),
      'Company report',
    );
    expect(
      opaqueOf(
        stories.footers[PageVariant.normal]!.delta,
      ).map((content) => fieldNameOf(content.xml)),
      ['PAGE'],
    );
    final document = _package(loaded).text('word/document.xml')!;
    expect('<w:headerReference'.allMatches(document), hasLength(2));
    expect(loaded.notices, isEmpty);
    final saved = OdtCodec(DocxCodec(_tables)).encode(
      loaded.delta,
      source: loaded.source,
      look: loaded.look,
      headersFooters: stories,
    );
    expect(
      utf8.decode(ZipDecoder().decodeBytes(saved).find('styles.xml')!.content),
      contains('Company report'),
    );

    // Only one set can be kept: the last page style's.
    final other = _decode(
      odtFile(
        masterAutomatic: layouts,
        masters:
            '$standard<style:master-page style:name="Landscape" style:page-layout-name="pm2">'
            '<style:header><text:p>Appendix header</text:p></style:header>'
            '</style:master-page>',
        automatic: automatic,
        body: body,
      ),
    );
    expect(
      _plain(other.headersFooters.headers[PageVariant.normal]!.delta).trim(),
      'Appendix header',
    );
    expect(
      _plain(other.headersFooters.footers[PageVariant.normal]!.delta).trim(),
      startsWith('Page'),
    );
    expect(other.notices, [DocumentNotice.contentNotImported]);
  });

  test('cropped pictures show only what the crop keeps', () {
    Map<String, dynamic>? attributesOf(LoadedDocument loaded, int index) => [
      for (final operation in operationsOf(loaded.delta))
        if (operation.data case {EmbedTypes.image: final String _})
          operation.attributes,
    ][index];

    final loaded = _decode(
      odtFile(
        automatic:
            '<style:style style:name="fr1" style:family="graphic">'
            '<style:graphic-properties fo:clip="rect(0cm, 2.6458cm, 0cm, 0cm)"/></style:style>'
            '<style:style style:name="fr2" style:family="graphic">'
            '<style:graphic-properties fo:clip="rect(0in 0in 0in 0.5208in)"/></style:style>',
        body:
            '<text:p><draw:frame draw:style-name="fr1" svg:width="2.6458cm" svg:height="2.6458cm">'
            '<draw:image xlink:href="Pictures/a.png"/></draw:frame>'
            '<draw:frame draw:style-name="fr2" svg:width="1in" svg:height="1in">'
            '<draw:image xlink:href="Pictures/b.png"/></draw:frame></text:p>',
        extra: {
          'Pictures/a.png': halvesPng(200, 100),
          // 192 dpi: 200 dots are 75pt wide.
          'Pictures/b.png': halvesPng(200, 100, dpi: 192),
        },
      ),
    );
    final images = embedsOf(loaded.delta, EmbedTypes.image);
    expect(pictureOf(images[0]), (width: 100, height: 100, red: 255, blue: 0));
    expect(pictureOf(images[1]), (width: 100, height: 100, red: 0, blue: 255));
    expect(attributesOf(loaded, 0)?['width'], '75');
    expect(attributesOf(loaded, 0)?['height'], '75');
    expect(loaded.notices, isEmpty);

    // Nothing would be left, or a metafile can't be cut: the whole picture
    // fits the frame unstretched.
    final metafile = ByteData(108)
      ..setUint32(0, 1, Endian.little)
      ..setUint32(4, 108, Endian.little)
      ..setInt32(32, 2000, Endian.little)
      ..setInt32(36, 1000, Endian.little)
      ..setUint32(40, 0x464D4520, Endian.little);
    final whole = _decode(
      odtFile(
        automatic:
            '<style:style style:name="fr1" style:family="graphic">'
            '<style:graphic-properties fo:clip="rect(0cm, 3cm, 0cm, 3cm)"/></style:style>',
        body:
            '<text:p><draw:frame draw:style-name="fr1" svg:width="2cm" svg:height="2cm">'
            '<draw:image xlink:href="Pictures/a.png"/></draw:frame>'
            '<draw:frame draw:style-name="fr1" svg:width="2cm" svg:height="2cm">'
            '<draw:image xlink:href="Pictures/b.emf"/></draw:frame></text:p>',
        extra: {
          'Pictures/a.png': halvesPng(200, 100),
          'Pictures/b.emf': metafile.buffer.asUint8List(),
        },
      ),
    );
    expect(pictureOf(embedsOf(whole.delta, EmbedTypes.image).first).width, 200);
    for (final index in [0, 1]) {
      expect(attributesOf(whole, index)?['width'], '56.69');
      expect(attributesOf(whole, index)?['height'], '28.35');
    }
    expect(whole.notices, [DocumentNotice.contentNotImported]);
  });

  test('a start value restarts the numbering at its item', () {
    final loaded = _decode(
      odtFile(
        automatic:
            '<text:list-style style:name="L1">'
            '<text:list-level-style-number text:level="1" style:num-suffix="." style:num-format="1"/>'
            '<text:list-level-style-number text:level="2" style:num-suffix=")" style:num-format="a"/>'
            '</text:list-style>',
        body:
            '<text:list xml:id="list1" text:style-name="L1">'
            '<text:list-item><text:p>one</text:p></text:list-item>'
            '<text:list-item><text:p>two</text:p>'
            '<text:list><text:list-item text:start-value="3"><text:p>sub c</text:p></text:list-item>'
            '<text:list-item><text:p>sub d</text:p></text:list-item></text:list>'
            '</text:list-item>'
            '<text:list-item><text:p>three</text:p></text:list-item>'
            '<text:list-item text:start-value="10"><text:p>ten</text:p></text:list-item>'
            '<text:list-item><text:p>eleven</text:p></text:list-item>'
            '</text:list>'
            '<text:p>between</text:p>'
            '<text:list text:continue-list="list1">'
            '<text:list-item><text:p>twelve</text:p></text:list-item></text:list>',
      ),
    );
    final delta = loaded.delta;
    Object? number(String text) =>
        lineOf(delta, text)?[HiddenAttributes.numbering];

    expect(number('two'), number('one'));
    expect(number('three'), number('one'));
    expect(number('sub c'), isNot(number('one')));
    expect(number('sub d'), number('sub c'));
    expect(number('ten'), isNot(number('one')));
    expect(number('eleven'), number('ten'));
    expect(number('twelve'), number('ten'));
    final numbering = _package(loaded).text('word/numbering.xml')!;
    expect(numbering, contains('<w:lvl w:ilvl="1"><w:start w:val="3"/>'));
    expect(numbering, contains('<w:lvl w:ilvl="0"><w:start w:val="10"/>'));
  });

  test("a list header that holds items counts at its level's start", () {
    final loaded = _decode(
      odtFile(
        automatic:
            '<text:list-style style:name="L1">'
            '<text:list-level-style-number text:level="1" style:num-suffix="." style:num-format="1"/>'
            '<text:list-level-style-number text:level="2" style:num-suffix=")" style:num-format="a" text:display-levels="2"/>'
            '<text:list-level-style-number text:level="3" style:num-suffix=")" style:num-format="i"/>'
            '</text:list-style>',
        body:
            '<text:list text:style-name="L1">'
            '<text:list-header><text:p>heading</text:p></text:list-header>'
            '<text:list-item><text:p>one</text:p>'
            '<text:list><text:list-header><text:p>header</text:p>'
            '<text:list><text:list-item><text:p>below</text:p></text:list-item></text:list>'
            '</text:list-header>'
            '<text:list-item><text:p>after</text:p></text:list-item></text:list>'
            '</text:list-item>'
            '<text:list-item><text:p>two</text:p></text:list-item>'
            '</text:list>'
            '<text:list text:style-name="L1">'
            '<text:list-header><text:p>holder</text:p>'
            '<text:list><text:list-item><text:p>held</text:p></text:list-item></text:list>'
            '</text:list-header>'
            '<text:list-item text:start-value="5"><text:p>five</text:p></text:list-item>'
            '<text:list-item><text:p>six</text:p></text:list-item>'
            '</text:list>',
      ),
    );

    // LibreOffice counts "header" and "holder" as 1, so "after" shows b) and
    // "five" keeps its 5.
    expect(_labels(loaded), {
      'heading': null,
      'one': '1.',
      'header': null,
      'below': 'i)',
      'after': '1.b)',
      'two': '2.',
      'holder': null,
      'held': '1.a)',
      'five': '5.',
      'six': '6.',
    });
  });

  test('list levels keep what follows their number', () {
    String alignment(String followedBy) =>
        '<style:list-level-properties text:list-level-position-and-space-mode="label-alignment">'
        '<style:list-level-label-alignment text:label-followed-by="$followedBy" '
        'fo:text-indent="-0.635cm" fo:margin-left="1.27cm"/></style:list-level-properties>';
    final loaded = _decode(
      odtFile(
        styles:
            '$libreOfficeStyles<text:outline-style style:name="Outline">'
            '<text:outline-level-style text:level="1" style:num-format="1">${alignment('space')}</text:outline-level-style>'
            '</text:outline-style>',
        automatic:
            '<text:list-style style:name="L1">'
            '<text:list-level-style-number text:level="1" style:num-suffix="." style:num-format="1">${alignment('space')}</text:list-level-style-number>'
            '<text:list-level-style-bullet text:level="2" text:bullet-char="•">${alignment('nothing')}</text:list-level-style-bullet>'
            '<text:list-level-style-number text:level="3" style:num-format="i">${alignment('listtab')}</text:list-level-style-number>'
            '</text:list-style>',
        body:
            '<text:h text:style-name="Heading_20_1" text:outline-level="1">Introduction</text:h>'
            '<text:list text:style-name="L1">'
            '<text:list-item text:start-value="4"><text:p>four</text:p>'
            '<text:list><text:list-item><text:p>dot</text:p>'
            '<text:list><text:list-item><text:p>roman</text:p></text:list-item></text:list>'
            '</text:list-item></text:list>'
            '</text:list-item></text:list>',
      ),
    );
    final numbering = _package(loaded).text('word/numbering.xml')!;

    expect(lineOf(loaded.delta, 'Introduction')?['list'], 'ordered');
    expect(
      numbering,
      contains(
        '<w:numFmt w:val="decimal"/><w:suff w:val="space"/>'
        '<w:lvlText w:val="%1"/>',
      ),
    );
    expect(
      numbering,
      contains(
        '<w:start w:val="4"/><w:numFmt w:val="decimal"/>'
        '<w:suff w:val="space"/><w:lvlText w:val="%1."/>',
      ),
    );
    expect(
      numbering,
      contains(
        '<w:numFmt w:val="bullet"/><w:suff w:val="nothing"/>'
        '<w:lvlText w:val="•"/>',
      ),
    );
    expect(
      numbering,
      contains('<w:numFmt w:val="lowerRoman"/><w:lvlText w:val="%3"/>'),
    );
  });

  test('list levels keep how their number lines up', () {
    String properties(String align) =>
        '<style:list-level-properties fo:text-align="$align" '
        'text:list-level-position-and-space-mode="label-alignment">'
        '<style:list-level-label-alignment text:label-followed-by="listtab" '
        'fo:text-indent="-0.635cm" fo:margin-left="1.27cm"/>'
        '</style:list-level-properties>';
    final loaded = _decode(
      odtFile(
        automatic:
            '<text:list-style style:name="L1">'
            '<text:list-level-style-number text:level="1" style:num-suffix="." style:num-format="I">${properties('end')}</text:list-level-style-number>'
            '<text:list-level-style-number text:level="2" style:num-suffix="." style:num-format="1">${properties('center')}</text:list-level-style-number>'
            '<text:list-level-style-bullet text:level="3" text:bullet-char="•">${properties('right')}</text:list-level-style-bullet>'
            '<text:list-level-style-number text:level="4" style:num-format="a">${properties('start')}</text:list-level-style-number>'
            '</text:list-style>',
        body:
            '<text:list text:style-name="L1"><text:list-item><text:p>one</text:p>'
            '<text:list><text:list-item text:start-value="2"><text:p>two</text:p>'
            '</text:list-item></text:list></text:list-item></text:list>',
      ),
    );
    final numbering = _package(loaded).text('word/numbering.xml')!;
    List<String> levels(int index) => [
      for (final match in RegExp(
        '<w:lvl w:ilvl="$index">(.*?)</w:lvl>',
      ).allMatches(numbering))
        match[1]!,
    ];

    // The item that starts again at 2 makes a second list of the levels.
    expect(levels(1), hasLength(2));
    expect(levels(0), everyElement(contains('<w:lvlJc w:val="right"/>')));
    expect(levels(1), everyElement(contains('<w:lvlJc w:val="center"/>')));
    expect(levels(2), everyElement(contains('<w:lvlJc w:val="right"/>')));
    expect(levels(3), everyElement(contains('<w:lvlJc w:val="left"/>')));
  });

  test('a level shows no dot for levels above without a number, and bullets '
      'keep their font', () {
    final loaded = _decode(
      odtFile(
        fonts:
            '<style:font-face style:name="Segoe UI Symbol" '
            'svg:font-family="&apos;Segoe UI Symbol&apos;"/>',
        automatic:
            '<text:list-style style:name="L1">'
            '<text:list-level-style-number text:level="1" style:num-format=""/>'
            '<text:list-level-style-number text:level="2" style:num-suffix="." '
            'style:num-format="a" text:display-levels="2"/>'
            '<text:list-level-style-number text:level="3" style:num-format="i" '
            'text:display-levels="3"/></text:list-style>'
            '<text:list-style style:name="L2">'
            '<text:list-level-style-bullet text:level="1" text:bullet-char="☑">'
            '<style:text-properties style:font-name="Segoe UI Symbol"/>'
            '</text:list-level-style-bullet>'
            '<text:list-level-style-bullet text:level="2" text:bullet-char="\uF0A7">'
            '<style:text-properties style:font-name="Segoe UI Symbol"/>'
            '</text:list-level-style-bullet>'
            '<text:list-level-style-bullet text:level="3" text:bullet-char="\u{1F642}"/>'
            '</text:list-style>',
        body:
            '<text:list text:style-name="L1"><text:list-item><text:list>'
            '<text:list-item><text:p>letter</text:p></text:list-item>'
            '</text:list></text:list-item></text:list>'
            '<text:list text:style-name="L2"><text:list-item><text:p>done</text:p>'
            '</text:list-item></text:list>',
      ),
    );
    final numbering = _package(loaded).text('word/numbering.xml')!;

    // LibreOffice shows "a." and "a.i", not ".a." and ".a.i".
    expect(numbering, contains('<w:lvlText w:val="%2."/>'));
    expect(numbering, contains('<w:lvlText w:val="%2.%3"/>'));
    expect(
      numbering,
      contains(
        '<w:lvlText w:val="☑"/><w:lvlJc w:val="left"/>'
        '<w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>'
        '<w:rPr><w:rFonts w:ascii="Segoe UI Symbol" w:hAnsi="Segoe UI Symbol" '
        'w:hint="default"/></w:rPr>',
      ),
    );
    expect(numbering, contains('<w:lvlText w:val="\u{1F642}"/>'));
    // A symbol of the font's own takes a bullet of every font instead.
    expect(
      numbering,
      contains(
        '<w:lvlText w:val="•"/><w:lvlJc w:val="left"/>'
        '<w:pPr><w:ind w:left="1440" w:hanging="360"/></w:pPr></w:lvl>',
      ),
    );
  });

  test('a page break before a table starts no new section', () {
    final loaded = _decode(
      odtFile(
        masters:
            '<style:master-page style:name="Standard" style:page-layout-name="pm1">'
            '<style:header><text:p>Running header</text:p></style:header>'
            '<style:header-first><text:p>Cover header</text:p></style:header-first>'
            '</style:master-page>',
        automatic:
            '<style:style style:name="Table1" style:family="table">'
            '<style:table-properties fo:break-before="page"/></style:style>',
        body:
            '<text:p>cover page</text:p>'
            '<table:table table:style-name="Table1"><table:table-row>'
            '<table:table-cell><text:p>cell</text:p></table:table-cell>'
            '</table:table-row></table:table>',
      ),
    );
    final delta = loaded.delta;
    expect(embedsOf(delta, EmbedTypes.sectionBreak), isEmpty);
    expect(embedsOf(delta, EmbedTypes.pageBreak), hasLength(1));
    final operations = operationsOf(delta);
    final table = operations.indexWhere(
      (operation) =>
          operation.data is Map &&
          (operation.data as Map).containsKey(EmbedTypes.table),
    );
    expect(
      operations.sublist(0, table).where((operation) => operation.data is Map),
      [
        isA<Operation>().having(
          (operation) => operation.data,
          'data',
          contains(EmbedTypes.pageBreak),
        ),
      ],
    );
    final document = _package(loaded).text('word/document.xml')!;
    expect('<w:sectPr>'.allMatches(document), hasLength(1));
  });

  test('hidden sections and paragraphs stay hidden', () {
    final loaded = _decode(
      odtFile(
        body:
            '<text:p>before</text:p>'
            '<text:section text:name="Answers" text:display="none"><text:p>secret answer</text:p></text:section>'
            '<text:section text:name="Cond" text:display="condition" text:condition="ooow:1" text:is-hidden="true">'
            '<text:p>conditional</text:p></text:section>'
            '<text:section text:name="Shown" text:display="condition" text:condition="ooow:0">'
            '<text:p>shown section</text:p></text:section>'
            '<text:p><text:hidden-paragraph text:condition="ooow:1" text:is-hidden="true"/>hidden paragraph</text:p>'
            '<text:p><text:span><text:hidden-paragraph text:condition="ooow:1" text:is-hidden="true"/></text:span>hidden too</text:p>'
            '<text:p><text:hidden-paragraph text:condition="ooow:0" text:is-hidden="false"/>visible paragraph</text:p>'
            '<text:p>after</text:p>',
      ),
    );
    expect(
      _plain(loaded.delta),
      'before\nshown section\nvisible paragraph\nafter\n',
    );
    expect(loaded.notices, [DocumentNotice.contentNotImported]);
  });

  test('hidden text fields show their text unless it is hidden', () {
    final shown = _decode(
      odtFile(
        body:
            '<text:p>a <text:hidden-text text:condition="ooow:1==2" text:string-value="shown text" '
            'text:is-hidden="false">shown text</text:hidden-text> b</text:p>',
      ),
    );
    expect(_plain(shown.delta), 'a shown text b\n');
    expect(shown.notices, isEmpty);

    final hidden = _decode(
      odtFile(
        body:
            '<text:p>a<text:hidden-text text:condition="ooow:1" text:string-value="gone" '
            'text:is-hidden="true">gone</text:hidden-text> b</text:p>',
      ),
    );
    expect(_plain(hidden.delta), 'a b\n');
    expect(hidden.notices, [DocumentNotice.contentNotImported]);
  });

  test('the page style numbers its pages in its own format', () {
    const roman =
        '<style:page-layout style:name="pm2"><style:page-layout-properties '
        'fo:page-width="21cm" fo:page-height="29.7cm" style:num-format="i" '
        'fo:margin-top="2cm" fo:margin-bottom="2cm" fo:margin-left="2cm" '
        'fo:margin-right="2cm"/></style:page-layout>';
    final loaded = _decode(
      odtFile(
        masterAutomatic: roman,
        masters:
            '<style:master-page style:name="Standard" style:page-layout-name="pm2">'
            '<style:footer><text:p><text:page-number text:select-page="current">i</text:page-number>'
            ' of <text:page-count>iii</text:page-count></text:p></style:footer>'
            '</style:master-page>',
      ),
    );
    final document = _package(loaded).text('word/document.xml')!;
    expect(document, contains('<w:pgNumType w:fmt="lowerRoman"/>'));
    final saved = DocxPackage.decode(
      DocxCodec(_tables).encode(loaded.delta, source: loaded.source),
    );
    expect(
      saved.text('word/document.xml'),
      contains('<w:pgNumType w:fmt="lowerRoman"/>'),
    );
    final footer = loaded.headersFooters.footers[PageVariant.normal]!.delta;
    final instructions = [
      for (final content in opaqueOf(footer))
        RegExp(
          r'<w:instrText[^>]*>([^<]*)<',
        ).firstMatch(content.xml)!.group(1)!.trim(),
    ];
    expect(instructions, ['PAGE', r'NUMPAGES \* roman']);

    // Front matter in roman numerals, then arabic ones: two sections.
    final front = _decode(
      odtFile(
        masterAutomatic: '$a4Layout$roman',
        masters:
            '<style:master-page style:name="Front" style:page-layout-name="pm2"/>'
            '<style:master-page style:name="Standard" style:page-layout-name="pm1"/>',
        automatic:
            '<style:style style:name="P1" style:family="paragraph" style:parent-style-name="Standard" style:master-page-name="Front"/>'
            '<style:style style:name="P2" style:family="paragraph" style:parent-style-name="Standard" style:master-page-name="Standard"/>',
        body:
            '<text:p text:style-name="P1">preface</text:p>'
            '<text:p text:style-name="P2">chapter</text:p>',
      ),
    );
    final sections = embedsOf(front.delta, EmbedTypes.sectionBreak);
    expect(sections, hasLength(1));
    expect(sectionXmlOf(sections.single), contains('w:fmt="lowerRoman"'));
    final body = _package(front).text('word/document.xml')!;
    expect('lowerRoman'.allMatches(body), hasLength(1));
  });

  test('the page style a paragraph or table starts can restart the numbers', () {
    const roman =
        '<style:page-layout style:name="pm2"><style:page-layout-properties '
        'fo:page-width="21cm" fo:page-height="29.7cm" style:num-format="i" '
        'fo:margin-top="2cm" fo:margin-bottom="2cm" fo:margin-left="2cm" '
        'fo:margin-right="2cm"/></style:page-layout>';
    String paragraphStyle(String name, String master, String number) =>
        '<style:style style:name="$name" style:family="paragraph" '
        'style:parent-style-name="Standard" style:master-page-name="$master">'
        '<style:paragraph-properties style:page-number="$number"/></style:style>';
    final loaded = _decode(
      odtFile(
        masterAutomatic: '$a4Layout$roman',
        masters:
            '<style:master-page style:name="Front" style:page-layout-name="pm2"/>'
            '<style:master-page style:name="Standard" style:page-layout-name="pm1"/>',
        automatic:
            '${paragraphStyle('P1', 'Front', '3')}'
            '${paragraphStyle('P2', 'Standard', '1')}'
            '${paragraphStyle('P3', 'Standard', 'auto')}'
            '<style:style style:name="Table1" style:family="table" '
            'style:master-page-name="Standard"><style:table-properties '
            'style:width="17cm" style:page-number="20"/></style:style>',
        body:
            '<text:p text:style-name="P1">preface</text:p>'
            '<text:p text:style-name="P2">chapter one</text:p>'
            '<text:p text:style-name="P3">chapter two</text:p>'
            '<table:table table:style-name="Table1"><table:table-column/>'
            '<table:table-row><table:table-cell><text:p>annex</text:p>'
            '</table:table-cell></table:table-row></table:table>',
      ),
    );
    final sections = [
      for (final section in embedsOf(loaded.delta, EmbedTypes.sectionBreak))
        sectionXmlOf(section),
    ];

    expect(sections, hasLength(2));
    expect(
      sections[0],
      contains('<w:pgNumType w:fmt="lowerRoman" w:start="3"/>'),
    );
    expect(sections[1], contains('<w:pgNumType w:start="1"/>'));
    // The same page style without a new number is a page break.
    expect(embedsOf(loaded.delta, EmbedTypes.pageBreak), hasLength(1));
    expect(
      _package(loaded).text('word/document.xml'),
      contains('<w:pgNumType w:start="20"/>'),
    );

    final again = _decode(
      OdtCodec(DocxCodec(_tables)).encode(
        loaded.delta,
        source: loaded.source,
        look: loaded.look,
        headersFooters: loaded.headersFooters,
      ),
    );
    final savedSections = [
      for (final section in embedsOf(again.delta, EmbedTypes.sectionBreak))
        sectionXmlOf(section),
    ];
    expect(savedSections, hasLength(2));
    expect(
      savedSections[0],
      contains('<w:pgNumType w:fmt="lowerRoman" w:start="3"/>'),
    );
    expect(savedSections[1], contains('<w:pgNumType w:start="1"/>'));
    expect(
      _package(again).text('word/document.xml'),
      contains('<w:pgNumType w:start="20"/>'),
    );
  });

  test('a table page number of 0 goes on counting, as OpenOffice.org wrote '
      'it for "auto"', () {
    String table(String style, String text) =>
        '<table:table table:style-name="$style"><table:table-column/>'
        '<table:table-row><table:table-cell><text:p>$text</text:p>'
        '</table:table-cell></table:table-row></table:table>';
    String tableStyle(String name, String master) =>
        '<style:style style:name="$name" style:family="table" '
        'style:master-page-name="$master"><style:table-properties '
        'style:width="17cm" style:page-number="0"/></style:style>';
    final loaded = _decode(
      odtFile(
        masters:
            '<style:master-page style:name="Standard" style:page-layout-name="pm1"/>'
            '<style:master-page style:name="Left_20_Page" style:display-name="Left Page" style:page-layout-name="pm1"/>',
        automatic:
            '${tableStyle('Table1', 'Standard')}'
            '${tableStyle('Table2', 'Left_20_Page')}'
            '<style:style style:name="P1" style:family="paragraph" '
            'style:parent-style-name="Standard" style:master-page-name="Standard">'
            '<style:paragraph-properties style:page-number="0"/></style:style>',
        body:
            '${table('Table1', 'first')}<text:p>text</text:p>'
            '${table('Table2', 'second')}'
            '<text:p text:style-name="P1">zero</text:p>',
      ),
    );
    final sections = [
      for (final section in embedsOf(loaded.delta, EmbedTypes.sectionBreak))
        sectionXmlOf(section),
    ];

    // Only the paragraph starts its pages at 0, as in LibreOffice.
    expect(sections, hasLength(1));
    expect(sections.single, isNot(contains('pgNumType')));
    expect(embedsOf(loaded.delta, EmbedTypes.pageBreak), hasLength(1));
    expect(
      _package(loaded).text('word/document.xml'),
      contains('<w:pgNumType w:start="0"/>'),
    );
  });

  test('LibreOffice 4.3 to 6.4 contextual spacing is read', () {
    final loaded = _decode(
      odtFile(
        automatic:
            '<style:style style:name="P1" style:family="paragraph" style:parent-style-name="Standard">'
            '<style:paragraph-properties fo:margin-bottom="0.3cm" loext:contextual-spacing="true"/></style:style>',
        body:
            '<text:p text:style-name="P1">loext one</text:p>'
            '<text:p text:style-name="P1">loext two</text:p>',
      ),
    );
    expect(
      lineOf(loaded.delta, 'loext one')?[HiddenAttributes.contextualGroup],
      isNotNull,
    );
  });

  test('ruby text follows its base', () {
    final loaded = _decode(
      odtFile(
        body:
            '<text:p><text:ruby><text:ruby-base>漢字</text:ruby-base>'
            '<text:ruby-text>かんじ</text:ruby-text></text:ruby></text:p>',
      ),
    );
    expect(_plain(loaded.delta), '漢字(かんじ)\n');
    expect(loaded.notices, [DocumentNotice.contentNotImported]);
  });

  test('a note mark of its own is reported as lost', () {
    String note(String citation) =>
        '<text:p>see<text:note text:note-class="footnote">$citation'
        '<text:note-body><text:p>the note</text:p></text:note-body></text:note></text:p>';
    final numbered = _decode(
      odtFile(body: note('<text:note-citation>1</text:note-citation>')),
    );
    expect(numbered.notices, isEmpty);
    final marked = _decode(
      odtFile(
        body: note('<text:note-citation text:label="*">*</text:note-citation>'),
      ),
    );
    expect(_package(marked).text('word/footnotes.xml'), contains('the note'));
    expect(marked.notices, [DocumentNotice.contentNotImported]);
  });

  test('lowercase and capitalized text show in that case', () {
    final loaded = _decode(
      odtFile(
        automatic:
            '<style:style style:name="P1" style:family="paragraph" style:parent-style-name="Standard">'
            '<style:text-properties fo:text-transform="capitalize"/></style:style>'
            '<style:style style:name="T1" style:family="text"><style:text-properties fo:text-transform="lowercase"/></style:style>'
            '<style:style style:name="T2" style:family="text"><style:text-properties fo:text-transform="capitalize"/></style:style>'
            '<style:style style:name="T3" style:family="text"><style:text-properties fo:text-transform="none"/></style:style>',
        body:
            '<text:p><text:span text:style-name="T1">LOWER</text:span> '
            '<text:span text:style-name="T2">capital words</text:span> '
            'mid<text:span text:style-name="T2">dle</text:span></text:p>'
            '<text:p text:style-name="P1">o’neil and rock-solid '
            '<text:span text:style-name="T3">as written</text:span></text:p>',
      ),
    );
    expect(
      _plain(loaded.delta),
      'lower Capital Words middle\nO’neil And Rock-Solid as written\n',
    );
    expect(loaded.notices, isEmpty);
  });
}
