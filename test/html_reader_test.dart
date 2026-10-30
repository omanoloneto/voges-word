import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/delta_blocks.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/html/css.dart';
import 'package:voges_word/html/html_codec.dart';
import 'package:voges_word/html/html_reader.dart';

LoadedDocument _decode(Uint8List bytes, [TableStore? tables]) =>
    HtmlCodec(DocxCodec(tables ?? TableStore())).decode(bytes);

LoadedDocument _read(String html, [TableStore? tables]) =>
    _decode(Uint8List.fromList(utf8.encode(html)), tables);

Map<String, dynamic> _visible(Map<String, dynamic>? attributes) => {
  for (final MapEntry(:key, :value) in (attributes ?? const {}).entries)
    if (!key.startsWith('vw-')) key: value,
};

List<List<Object>> _lines(Delta delta) => [
  for (final block in documentBlocks(delta))
    if (block is LineBlock) [block.plainText, _visible(block.attributes)],
];

LineBlock _line(Delta delta, String text) => documentBlocks(
  delta,
).whereType<LineBlock>().firstWhere((line) => line.plainText.contains(text));

Map<String, dynamic> _run(Delta delta, String text) => _visible(
  delta
      .toList()
      .firstWhere(
        (operation) =>
            operation.data is String &&
            (operation.data as String).contains(text),
      )
      .attributes,
);

String _plain(Delta delta) => [
  for (final operation in delta.toList())
    if (operation.data is String) operation.data,
].join();

List<TableModel> _tables(Delta delta, TableStore store) => [
  for (final block in documentBlocks(delta))
    if (block case EmbedBlock(type: EmbedTypes.table, :final value))
      store[tableIdOf(value)]!,
];

String _cellText(TableCellModel cell) =>
    cell.controller.document.toPlainText().trim();

String _numbering(LoadedDocument loaded) =>
    (loaded.source! as DocxPackage).text('word/numbering.xml') ?? '';

String _write(LoadedDocument loaded, TableStore tables) => utf8.decode(
  HtmlCodec(DocxCodec(tables)).encode(
    loaded.delta,
    source: loaded.source,
    look: loaded.look,
    headersFooters: loaded.headersFooters,
  ),
);

/// The runs of the page's paragraphs, as the reader made them.
List<TextSpec> _runs(String html) {
  final runs = <TextSpec>[];
  void add(List<InlineSpec> inlines) {
    for (final inline in inlines) {
      if (inline is TextSpec) runs.add(inline);
      if (inline is LinkSpec) add(inline.children);
    }
  }

  final blocks = [...readHtml(html).spec.body];
  while (blocks.isNotEmpty) {
    switch (blocks.removeAt(0)) {
      case ParagraphSpec(:final inlines):
        add(inlines);
      case TableSpec(:final rows):
        for (final row in rows) {
          for (final cell in row.cells) {
            blocks.addAll(cell.blocks);
          }
        }
      case SectionBreakSpec():
        break;
    }
  }
  return runs;
}

RunFormat _format(String html, String text) =>
    _runs(html).firstWhere((run) => run.text.contains(text)).format;

/// A PNG header of [width] by [height] pixels; only the header is read.
String _pngOf(int width, int height, int seed) {
  final bytes = ByteData(40)
    ..setUint32(0, 0x89504E47)
    ..setUint32(4, 0x0D0A1A0A)
    ..setUint32(8, 13)
    ..setUint32(12, 0x49484452)
    ..setUint32(16, width)
    ..setUint32(20, height)
    ..setUint32(24, 0x01000000)
    ..setUint32(36, seed);
  return 'data:image/png;base64,${base64Encode(bytes.buffer.asUint8List())}';
}

Matcher _tooLarge() => throwsA(
  isA<DocumentProblemException>().having(
    (error) => error.problem,
    'problem',
    DocumentProblem.tooLarge,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the font shorthand takes numeric weights before the size', () {
    const page = '''
<style>.body { font: 400 16px/1.5 "Open Sans", Arial, sans-serif }</style>
<p class="body">Body text that is the most common text of the page.</p>
<p style="font: 700 24px/32px Georgia, serif">Title</p>
<p style="font: normal 400 13px Verdana">Small print</p>
<p style="font-weight: bold; line-height: 3">Bold <span style="font: 10pt Arial">reset</span></p>''';
    final body = _format(page, 'Body text');
    expect(body.size, 12);
    expect(body.font, 'Open Sans');
    final title = _format(page, 'Title');
    expect((title.size, title.font, title.bold), (18, 'Georgia', true));
    final small = _format(page, 'Small print');
    expect((small.size, small.font, small.bold), (9.75, 'Verdana', false));
    // What the shorthand leaves out goes back to normal, as in browsers.
    expect(_format(page, 'reset').bold, isFalse);

    final look = _read(page).look;
    expect(look.body.fontSize, 12);
    expect(look.body.fontFamily, 'Open Sans');
  });

  test('light text on a background the document leaves out stays readable', () {
    final loaded = _read('''
<style>h1 { background: #5B9BD5; color: white }</style>
<p>Intro text.</p>
<pre style="display: block; background: #272822; color: #f8f8f2">var dark = true;</pre>
<div style="background: #1f3864; color: #fff">A notice box with a long text inside.</div>
<p style="background: black; color: white">Shaded paragraph.</p>
<div style="background: #fffbe6; color: #8a6d3b">Light box.</div>
<div style="background: #000; color: #fff"><span style="background: #333">kept</span></div>
<h1>Heading</h1>''');
    final delta = loaded.delta;
    for (final text in [
      'var dark',
      'A notice box',
      'Shaded paragraph',
      'Intro text',
    ]) {
      expect(_run(delta, text)['color'], isNot('#FFFFFF'), reason: text);
      expect(_run(delta, text)['color'], isNot('#F8F8F2'), reason: text);
    }
    expect(_run(delta, 'Light box')['color'], '#8A6D3B');
    expect(_run(delta, 'kept'), {'color': '#FFFFFF', 'background': '#333333'});
    expect(loaded.look.body.color.toARGB32(), 0xFF000000);
    expect(loaded.look.headings[1]?.color.toARGB32(), isNot(0xFFFFFFFF));

    final dark = _read(
      '<body style="background: #121212; color: #e0e0e0"><p>Dark mode.</p></body>',
    );
    expect(dark.look.body.color.toARGB32(), 0xFF000000);
    expect(_run(dark.delta, 'Dark mode'), isEmpty);
  });

  test('Google Docs lists number their levels as one list', () {
    final tables = TableStore();
    final loaded = _read(
      '''
<style>
.lst-kix_list_31-0>li:before{content:"" counter(lst-ctn-kix_list_31-0,decimal) ". "}
.lst-kix_list_31-1>li:before{content:"(" counter(lst-ctn-kix_list_31-1,lower-latin) ") "}
.lst-kix_list_31-2>li:before{content:"" counter(lst-ctn-kix_list_31-0,decimal) "." counter(lst-ctn-kix_list_31-1,decimal) "." counter(lst-ctn-kix_list_31-2,lower-roman) " "}
</style>
<ol class="lst-kix_list_31-0 start" start="1"><li>Definitions</li><li>Use requirements</li></ol>
<ol class="lst-kix_list_31-1 start" start="1"><li>Noncustodial</li><li>Representations</li></ol>
<ol class="lst-kix_list_31-0" start="3"><li>Fees</li><li>Ownership</li></ol>
<ol class="lst-kix_list_31-1 start" start="1"><li>Ownership of the service</li></ol>
<p>Between the lists.</p>
<ol class="lst-kix_list_31-0 start" start="1"><li>Restarted</li></ol>''',
      tables,
    );
    final delta = loaded.delta;
    int? numId(String text) =>
        (_line(delta, text).attributes[HiddenAttributes.numbering] as num?)
            ?.toInt();

    expect(numId('Noncustodial'), numId('Definitions'));
    expect(numId('Ownership of the service'), numId('Definitions'));
    expect(numId('Restarted'), isNot(numId('Definitions')));
    expect(_line(delta, 'Noncustodial').indent, 1);
    final numbering = _numbering(loaded);
    expect(numbering, contains('<w:numFmt w:val="lowerLetter"/>'));
    expect(numbering, contains('<w:lvlText w:val="(%2)"/>'));
    expect(numbering, contains('<w:lvlText w:val="%1.%2.%3"/>'));
    expect(numbering, contains('<w:numFmt w:val="lowerRoman"/>'));

    // Saved as a page, each sub-list starts at (a) again and the top level
    // goes on.
    final html = _write(loaded, tables);
    expect('<ol type="a">'.allMatches(html), hasLength(2));
    expect(html, isNot(contains('start=')));
    expect(html, contains('</li>\n<li>Fees'));
  });

  test('a page that declares UTF-8 keeps it despite a stray byte', () {
    final loaded = _decode(
      Uint8List.fromList([
        ...utf8.encode('<meta charset="utf-8"><h1>Café São Paulo</h1><p>Chef'),
        0x92,
        ...utf8.encode('s choice</p><p>Preço — obrigado 東京</p>'),
      ]),
    );
    expect(
      _plain(loaded.delta),
      'Café São Paulo\nChef\u{FFFD}s choice\nPreço — obrigado 東京\n',
    );
    final xml = _decode(
      Uint8List.fromList([
        ...utf8.encode('<?xml version="1.0" encoding="UTF-8"?><p>ação '),
        0xE9,
        ...utf8.encode('</p>'),
      ]),
    );
    expect(_plain(xml.delta), 'ação \u{FFFD}\n');

    // Without any UTF-8 in it, the label is wrong and the page Western.
    final mislabeled = _decode(
      Uint8List.fromList([
        ...latin1.encode('<meta charset="utf-8"><p>Caf'),
        0xE9,
        0x20,
        0x93,
        0x61,
        0x94,
        ...latin1.encode('</p>'),
      ]),
    );
    expect(_plain(mislabeled.delta), 'Café “a”\n');
  });

  test('XHTML elements written empty with /> keep what follows', () {
    final title = _read(
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title/></head>'
      '<body><h1>Chapter 1</h1><p>Text.</p></body></html>',
    );
    expect(_lines(title.delta).map((line) => line[0]), ['Chapter 1', 'Text.']);

    final script = _read(
      '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
      '<script type="text/javascript" src="menu.js"/><style/></head><body>'
      '<h1>Meeting notes</h1><p><a name="top"/>First point.</p>'
      '<div class="spacer"/><p>Second <b/>point.</p>'
      '<script>var x = "<p>no</p>";</script><p>Closing remarks.</p>'
      '<iframe src="x.html"/><p>After the frame.</p></body></html>',
    );
    expect(_lines(script.delta).map((line) => line[0]), [
      'Meeting notes',
      'First point.',
      'Second point.',
      'Closing remarks.',
      'After the frame.',
    ]);
    expect(_run(script.delta, 'Second point.'), isEmpty);
    expect(
      _line(script.delta, 'First').attributes[HiddenAttributes.bookmarks],
      '["top"]',
    );

    // Pages read as HTML ignore the `/` as browsers do.
    final html = _read('<p>Plain <b/>bold</p>');
    expect(_run(html.delta, 'bold'), {'bold': true});
  });

  test('text the page leaves unstyled keeps the browser default', () {
    final colors = _read('''
<p>Black introduction.</p>
<blockquote style="color: #808080">A long quote that is much longer than the
introduction and the conclusion together, so its gray is the most common.</blockquote>
<p>Conclusion with a <a href="https://example.com">link</a>.</p>''');
    expect(_run(colors.delta, 'Black introduction')['color'], '#000000');
    expect(_run(colors.delta, 'Conclusion')['color'], '#000000');
    expect(_run(colors.delta, 'A long quote')['color'], isNot('#000000'));
    expect(_run(colors.delta, 'link')['color'], '#0563C1');

    final sizes = _read('''
<p>Read this first.</p>
<p style="font-size: 8pt">Fine print that goes on and on and on, much longer
than the first paragraph of the page.</p>''');
    final first = _run(sizes.delta, 'Read this first');
    expect(first['size'], '12');
    expect(_run(sizes.delta, 'Fine print')['size'], isNot('12'));
  });

  test('Word list levels keep their number text and picture bullets', () {
    final loaded = _read(
      r'''
<style>
@list l0:level1 {mso-level-text:"%1\.";}
@list l0:level2 {mso-level-text:"%1\.%2\.";}
@list l0:level3 {mso-level-number-format:alpha-lower; mso-level-text:"\(%3\)";}
@list l1:level1 {mso-level-number-format:image; mso-level-text:\F0B7; font-family:Symbol;}
</style>
<p style="mso-list:l0 level1 lfo1"><span style="mso-list:Ignore">1.</span>Scope</p>
<p style="mso-list:l0 level2 lfo1"><span style="mso-list:Ignore">1.1.</span>Purpose</p>
<p style="mso-list:l0 level3 lfo1"><span style="mso-list:Ignore">(a)</span>Readers</p>
<p style="mso-list:l1 level1 lfo2"><span style="mso-list:Ignore">x</span>Picture bullet one</p>''',
    );
    final numbering = _numbering(loaded);
    expect(numbering, contains('<w:lvlText w:val="%1.%2."/>'));
    expect(numbering, contains('<w:lvlText w:val="(%3)"/>'));
    expect(_line(loaded.delta, 'Purpose').list, 'ordered');
    expect(_line(loaded.delta, 'Picture bullet one').list, 'bullet');
  });

  test('rem follows the root font size', () {
    final loaded = _read('''
<style>html { font-size: 62.5% } body { font-size: 1.6rem }
h1 { font-size: 3.2rem } .meta { font-size: 1.2rem; margin-left: 2rem }</style>
<h1>Heading</h1><p>Body text that is the most common on the page.</p>
<p class="meta">Meta</p>''');
    expect(loaded.look.body.fontSize, 12);
    expect(loaded.look.headings[1]?.fontSize, 24);
    expect(_run(loaded.delta, 'Meta')['size'], '9');
  });

  test('pages in legacy charsets read as browsers read them', () {
    String text(List<int> bytes) =>
        _plain(_decode(Uint8List.fromList(bytes)).delta);
    List<int> page(String charset, List<int> body) => [
      ...latin1.encode('<meta charset="$charset"><p>'),
      ...body,
      ...latin1.encode('</p>'),
    ];

    expect(
      text(page('iso-8859-15', [...latin1.encode('Prix : 10 '), 0xA4])),
      'Prix : 10 €\n',
    );
    expect(text(page('koi8-r', [0xF3, 0xDF, 0xC5, 0xDB, 0xD8])), 'Съешь\n');
    expect(
      text(page('latin2', latin1.encode('Za\xBF\xF3\xB3\xE6'))),
      'Zażółć\n',
    );
    expect(
      text(
        page('ISO-8859-7', [0xCA, 0xE1, 0xEB, 0xE7, 0xEC, 0xDD, 0xF1, 0xE1]),
      ),
      'Καλημέρα\n',
    );

    final japanese = _decode(
      Uint8List.fromList(
        page('shift_jis', [...latin1.encode('Tokyo '), 0x93, 0x8C, 0x8B, 0x9E]),
      ),
    );
    expect(_plain(japanese.delta), 'Tokyo \u{FFFD}\u{FFFD}\n');
    expect(japanese.notices, contains(DocumentNotice.contentNotImported));
    // An old label on a page now in UTF-8.
    final relabeled = _decode(
      Uint8List.fromList(page('shift_jis', utf8.encode('東京'))),
    );
    expect(_plain(relabeled.delta), '東京\n');
    expect(relabeled.notices, isEmpty);
    final ascii = _decode(
      Uint8List.fromList(page('euc-kr', latin1.encode('a'))),
    );
    expect(ascii.notices, isEmpty);
  });

  test("Word's row that lines up misaligned columns is left out", () {
    final tables = TableStore();
    final loaded = _read('''
<table border=1 cellspacing=0 cellpadding=0>
<tr><td colspan=2 style="border:solid windowtext 1pt">Wide</td></tr>
<tr><td style="border:solid windowtext 1pt">A</td><td style="border:solid windowtext 1pt">B</td></tr>
<![if !supportMisalignedColumns]>
<tr height=0><td width=160 style="border:none"></td><td width=240 style="border:none"></td></tr>
<![endif]>
</table>''', tables);
    final table = _tables(loaded.delta, tables).single;
    expect(table.rows, hasLength(2));
    expect(table.rows.last.cells.map(_cellText), ['A', 'B']);
    expect(table.columnWidths, [2400, 3600]);
  });

  test('a self-closing svg or math element keeps the text after it', () {
    final svg = _read(
      '<p><svg class="icon" width="16" height="16"/> The installer is signed.'
      '</p><p>Release notes follow.</p>',
    );
    expect(
      _plain(svg.delta),
      'The installer is signed.\nRelease notes follow.\n',
    );
    expect(svg.notices, contains(DocumentNotice.contentNotImported));
    final math = _read('<p>Before <math/> after text <i>x</i></p>');
    expect(_plain(math.delta), 'Before after text x\n');
    // An svg with content is still left out whole.
    final whole = _read('<p>a<svg><text>vector</text></svg>b</p>');
    expect(_plain(whole.delta), 'ab\n');
  });

  test('tables in cells take their percentages from the cell', () {
    final tables = TableStore();
    final loaded = _read('''
<table width="100%"><tr><td width="30%">Side</td><td width="70%">
<table width="100%"><tr><td>x</td><td>y</td></tr></table>
<table><tr><td>auto</td><td>widths</td></tr></table>
</td></tr></table>''', tables);
    final outer = _tables(loaded.delta, tables).single;
    final room = outer.columnWidths.last;
    final inner = _tables(
      outer.rows.single.cells.last.controller.document.toDelta(),
      tables,
    );
    expect(inner, hasLength(2));
    for (final table in inner) {
      final width = table.columnWidths.fold<double>(0, (a, b) => a + b);
      expect(width, lessThanOrEqualTo(room));
      expect(width, greaterThan(room * 0.8));
    }
  });

  test('footer rows come last wherever the page has them', () {
    final tables = TableStore();
    final loaded = _read('''
<table border="1"><thead><tr><th>Item</th><th>Price</th></tr></thead>
<tfoot><tr><td>Total</td><td>30</td></tr></tfoot>
<tbody><tr><td>Apples</td><td rowspan="9">10</td></tr><tr><td>Pears</td></tr></tbody>
</table>''', tables);
    final table = _tables(loaded.delta, tables).single;
    expect(table.rows.map((row) => _cellText(row.cells.first)), [
      'Item',
      'Apples',
      'Pears',
      'Total',
    ]);
    // Cells don't span into the rows that moved.
    expect(table.rows.last.cells.map(_cellText), ['Total', '30']);
  });

  test('quotations get their marks and task items their state', () {
    final loaded = _read('''
<p>She said <q>hello <q>there</q></q> and left.</p>
<ul><li class="task-list-item"><input type="checkbox" disabled checked> Done task</li>
<li><input type="checkbox" disabled> Open task</li>
<li>Plain <input type="checkbox"> item</li></ul>''');
    expect(
      _line(loaded.delta, 'She said').plainText,
      'She said “hello ‘there’” and left.',
    );
    final numbering = _numbering(loaded);
    expect(numbering, contains('<w:lvlText w:val="☑"/>'));
    expect(numbering, contains('<w:lvlText w:val="☐"/>'));
    int? numId(String text) =>
        (_line(loaded.delta, text).attributes[HiddenAttributes.numbering]
                as num?)
            ?.toInt();
    expect(numId('Done task'), isNot(numId('Open task')));
    expect(numId('Plain'), isNot(numId('Open task')));
    for (final text in ['Done task', 'Open task', 'Plain']) {
      expect(_line(loaded.delta, text).list, 'bullet');
    }
  });

  group('hostile pages', () {
    test('a Kelvin sign in a tag name nests like any other element', () {
      // `<linK>` with U+212A: an unknown element to the parser, not a link.
      const link = '<lin\u212A>';
      expect(() => _read('<p>${link * 300}x'), throwsA(isA<FormatException>()));
      final watch = Stopwatch()..start();
      expect(
        () => _read('<p>${link * 50000}${'</div>' * 10000}x'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => _read('<p>${'<mark>x</mar\u212A>' * 300}'),
        throwsA(isA<FormatException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('content moved out of tables is budgeted', () {
      final watch = Stopwatch()..start();
      expect(() => _read('<table>${'x<br>' * 20000}</table>'), _tooLarge());
      expect(() => _read('<table>${'x<br>' * 3000}</table>' * 10), _tooLarge());
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      // A few stray elements in a table are fine.
      final loaded = _read(
        '<table><tr><td>a</td></tr>stray<br><tr><td>b</td></tr></table>',
      );
      expect(_plain(loaded.delta), contains('stray'));
    });

    test('long selectors and failed matches are budgeted', () {
      final repeated = StringBuffer();
      for (var key = 0; key < 16; key++) {
        for (var rule = 0; rule < 32; rule++) {
          repeated.write('.c$key${'.c$key' * 2000}.z$rule { color: red }\n');
        }
      }
      final classes = List.generate(16, (index) => 'c$index').join(' ');
      var watch = Stopwatch()..start();
      final loaded = _read(
        '<style>$repeated</style>'
        '<p>${'<span class="$classes">a</span>' * 500}</p>',
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(_run(loaded.delta, 'a'), isEmpty);

      final failing = StringBuffer();
      for (var key = 0; key < 16; key++) {
        for (var rule = 0; rule < 32; rule++) {
          final rest = List.generate(15, (index) => '.d$index').join();
          failing.write('.c$key$rest { color: red }\n');
        }
      }
      final many = [
        ...List.generate(16, (index) => 'c$index'),
        ...List.generate(14, (index) => 'd$index'),
      ].join(' ');
      watch = Stopwatch()..start();
      expect(
        () => _read(
          '<style>$failing</style>'
          '<p>${'<span class="$many">a</span>' * 20000}</p>',
        ),
        _tooLarge(),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));

      expect(CssSelector.parse('p.a.a.b')!.classes, ['a', 'b']);
      final distinct = List.generate(17, (index) => '.k$index').join();
      expect(CssSelector.parse(distinct), isNull);
    });

    test('parse errors and end tags that close nothing are budgeted', () {
      final watch = Stopwatch()..start();
      for (final page in [
        '<p>${'<span>' * 250}${'</div>' * 100000}',
        '<p>${'</div>' * 300000}',
        '<p>${'\u0000' * 1000000}',
        '<p>${'\u0001' * 1000000}',
        '<p>${'<1' * 1000000}',
        '<p>${'x' * (17 * 1024 * 1024)}</p>',
      ]) {
        expect(() => _read(page), _tooLarge());
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      final sloppy = _read('<p>a < b</div></span>\u0001c</p>');
      expect(_plain(sloppy.delta), contains('a < b'));
    });

    test('pictures are budgeted by their pixels', () {
      final loaded = _read(
        '<p>${[for (var index = 0; index < 4; index++) '<img src="${_pngOf(10000, 6000, index)}" alt="big $index">'].join()}'
        '<img src="${_pngOf(0xFFFFFFFF, 0xFFFFFFFF, 9)}" alt="huge"></p>',
      );
      final pictures = loaded.delta.toList().where(
        (operation) =>
            operation.data is Map &&
            (operation.data as Map).containsKey(EmbedTypes.image),
      );
      expect(pictures, hasLength(1));
      expect(_plain(loaded.delta), contains('big 1'));
      expect(_plain(loaded.delta), contains('huge'));
      expect(loaded.notices, contains(DocumentNotice.contentNotImported));
    });

    test('numeric references past the last code point read as U+FFFD', () {
      final loaded = _read(
        '<p>a &#99999999999999999999; b</p>'
        '<p title="&#x10000000000000000;">c &#x10000000000000000 d</p>'
        '<p>&#0000000000000000000000065; &#x00000041;</p>',
      );
      expect(_plain(loaded.delta), 'a \u{FFFD} b\nc \u{FFFD} d\nA A\n');
    });
  });
}
