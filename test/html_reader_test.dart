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

    // Heading styles of a dark page too.
    final headings = _read(
      '<style>body { background: #121212; color: #e0e0e0 } '
      'h1, h2 { color: #ffffff } h3 { color: #c00000 }</style>'
      '<h1>Release notes</h1><p>This version fixes several bugs.</p>'
      '<h2>Changes</h2><h3>Fixes</h3>',
    );
    for (final level in [1, 2]) {
      expect(
        headings.look.headings[level]?.color.toARGB32(),
        isNot(0xFFFFFFFF),
        reason: 'h$level',
      );
    }
    expect(headings.look.headings[3]?.color.toARGB32(), 0xFFC00000);
  });

  test('transparent colors are no colors, and translucent ones blend in', () {
    expect(cssColor('#0000'), isNull);
    expect(cssColor('#00000000'), isNull);
    expect(cssColor('rgba(0, 0, 0, 0)'), isNull);
    expect(cssColor('rgb(0 0 0 / 0%)'), isNull);
    expect(cssColor('rgba(0, 0, 0, 0.5)'), '808080');
    expect(cssColor('#ff000080'), 'FF7F7F');
    expect(cssColor('rgba(255, 0, 0, 1)'), 'FF0000');
    expect(cssColor('rgb(100%, 50%, 0%)'), 'FF8000');
    expect(attributeColor('#00000000'), '000000');

    final tables = TableStore();
    for (final fill in ['#0000', 'rgba(0, 0, 0, 0)']) {
      final loaded = _read(
        '<table border="1" style="background-color: $fill">'
        '<tr><td>Name</td></tr></table>',
        tables,
      );
      final table = _tables(loaded.delta, tables).single;
      expect(table.rows.single.cells.single.fill, isNull, reason: fill);
    }
    final byline = _read(
      '<div style="background-color: rgba(0,0,0,0); color: #999999">'
      'Posted on 3 May by Ana</div>'
      '<p>The article itself, which is much longer than its byline.</p>',
    );
    expect(_run(byline.delta, 'Posted')['color'], '#999999');
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

    // Western letters before quotes or a no-break space can make a valid
    // character by chance; the bytes that aren't UTF-8 still tell.
    List<int> western(String text) => [
      for (final char in text.runes)
        switch (char) {
          0x201E => 0x84,
          0x201C => 0x93,
          _ => char,
        },
    ];
    for (final text in [
      'Viel „Spaß“ beim Lesen. Grüße aus München.',
      'CAFÉ\u00A0! Le café est délicieux, à bientôt.',
    ]) {
      final page = _decode(
        Uint8List.fromList([
          ...latin1.encode('<meta charset="utf-8"><p>'),
          ...western(text),
          ...latin1.encode('</p>'),
        ]),
      );
      expect(_plain(page.delta), '$text\n');
    }
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

  test('blank rows of Google Docs tables are kept', () {
    // Google Docs gives rows of automatic height no height at all, and
    // blank cells an empty paragraph.
    final tables = TableStore();
    const blank =
        '<tr class="c3"><td class="c5"><p class="c2 c6"><span class="c1"></span></p></td>'
        '<td class="c5"><p class="c2 c6"><span class="c1"></span></p></td></tr>';
    final loaded = _read('''
<style>.c3{height:0pt}.c5{border:1pt solid #000000}.c2{padding-top:0pt}.c6{margin:0}</style>
<table><tr class="c3"><td class="c5"><p class="c2 c6"><span class="c1">Name</span></p></td>
<td class="c5"><p class="c2 c6"><span class="c1">Phone</span></p></td></tr>
$blank$blank</table>''', tables);
    final table = _tables(loaded.delta, tables).single;
    expect(table.rows, hasLength(3));
    expect(table.rows.first.cells.map(_cellText), ['Name', 'Phone']);
    expect(table.rows.last.cells.map(_cellText), ['', '']);
  });

  test('Google Docs list markers leave room for the rules of the text', () {
    // Each list writes its levels' rules before the classes of the text.
    final rules = StringBuffer();
    final lists = StringBuffer();
    for (var list = 0; list < 1200; list++) {
      for (var level = 0; level < 9; level++) {
        rules.write(
          'ul.lst-kix_l$list-$level{list-style-type:none}'
          '.lst-kix_l$list-$level>li:before{content:"\\0025cf   "}\n',
        );
      }
      lists.write(
        '<ul class="lst-kix_l$list-0 start"><li>Item $list</li></ul>',
      );
    }
    final page =
        '<style>$rules.c1{font-weight:700;color:#cc0000;font-family:"Georgia"}'
        '</style>$lists<p><span class="c1">Important</span></p>';
    final important = _format(page, 'Important');
    expect(
      (important.bold, important.color, important.font),
      (true, 'CC0000', 'Georgia'),
    );
  });

  test('links left out for safety and rules are reported', () {
    for (final link in [
      '<a href="/docs/install">Install guide</a>',
      '<a href="//cdn.example.com/x">Mirror</a>',
      '<a href="javascript:alert(1)">Click</a>',
    ]) {
      final loaded = _read('<p>See the $link.</p>');
      expect(loaded.notices, contains(DocumentNotice.contentNotImported));
      expect(_plain(loaded.delta), contains(RegExp(r'^See the \w')));
    }
    for (final link in [
      '<a href="#">Top</a>',
      '<a href="">Empty</a>',
      '<a href=" ">Blank</a>',
      '<a href="/home"></a>',
      '<a href="/home"> </a>',
      '<a href="#install">Install</a>',
      '<a href="https://example.com/x">Web</a>',
      '<a href="docs/guide.md">Guide</a>',
    ]) {
      expect(_read('<p>See $link.</p>').notices, isEmpty, reason: link);
    }

    final rule = _read('<p>Before</p><hr><p>After</p>');
    expect(rule.notices, contains(DocumentNotice.contentNotImported));
    expect(_plain(rule.delta), 'Before\nAfter\n');
    // Google Docs writes its page breaks as hidden rules.
    final pageBreak = _read(
      '<p>Before</p><hr style="page-break-before:always;display:none;">'
      '<p>After</p>',
    );
    expect(pageBreak.notices, isEmpty);
    expect(
      pageBreak.delta.toList().any(
        (operation) =>
            operation.data is Map &&
            (operation.data as Map).containsKey(EmbedTypes.pageBreak),
      ),
      isTrue,
    );
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

    test('a column group does not hide content moved out of its table', () {
      final watch = Stopwatch()..start();
      expect(
        () => _read('<table><colgroup>${'x<br>' * 20000}</table>'),
        _tooLarge(),
      );
      expect(
        () => _read('<table><colgroup> <col>${'<b>x</b>' * 20000}</table>'),
        _tooLarge(),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));

      final tables = TableStore();
      final loaded = _read('''
<table><colgroup><col width="100"> <col width="200"></colgroup>
<tr><td>a</td><td>b</td></tr></table>''', tables);
      final table = _tables(loaded.delta, tables).single;
      expect(table.rows.single.cells.map(_cellText), ['a', 'b']);
      expect(table.columnWidths, [1500, 3000]);
    });

    test('hidden inputs and stray text in tables are not moved content', () {
      // The parser leaves hidden inputs where they are and joins the text
      // it moves in front of a table.
      final inputs = StringBuffer();
      final spaces = StringBuffer();
      for (var row = 0; row < 12000; row++) {
        inputs.write(
          '<tr><input type="hidden" name="id" value="$row">'
          '<td>Row $row</td><td>Value</td></tr>',
        );
        spaces.write('<tr><td>Row $row</td>&nbsp;<td>Value</td></tr>');
      }
      for (final page in ['<table>$inputs</table>', '<table>$spaces</table>']) {
        final table = readHtml(page).spec.body.whereType<TableSpec>().single;
        expect(table.rows, hasLength(12000));
      }
      // Other inputs and elements still are.
      expect(
        () => readHtml(
          '<table>${'<tr><input type="text"><td>a</td></tr>' * 12000}</table>',
        ),
        _tooLarge(),
      );
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

    test('parse errors in tags and character references are budgeted', () {
      final watch = Stopwatch()..start();
      for (final page in [
        // Repeated attributes, in start and end tags.
        '<p${' a' * 300000}>x',
        '<p>x</p${' a' * 300000}>',
        // References the parser reports, in text and in values.
        '<p>${'&#1' * 300000}',
        '<p>${'&#;' * 300000}',
        '<p>${'&x' * 300000}',
        '<p>${'&a;' * 300000}',
        '<p>${'&lt' * 300000}',
        '<p title="${'&#1' * 300000}">x',
        '<p title="${'&lt' * 300000}">x',
        '<p title=${'&#x0;' * 300000}>x',
        // Start tags the parser ignores.
        '<p>${'<body>' * 300000}',
        '<p>${'<html>' * 300000}',
        '<p>${'<td>' * 300000}',
        // Characters out of place in tags.
        '<p ${'"' * 300000}>x',
        '<p ${'/ ' * 300000}>x',
        '<p a=x${'`' * 300000}>x',
        '<p ${'a="x"' * 300000}>x',
        // Attributes and references in all.
        '<p ${List.generate(1100000, (index) => 'a$index').join(' ')}>x',
        '<p title="${'&amp;' * 4100000}">x',
      ]) {
        expect(
          () => readHtml(page),
          _tooLarge(),
          reason: page.substring(0, 12),
        );
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));

      // References written right cost nothing, and sloppy ones read as in
      // browsers.
      final references = _read(
        '<p>${'&amp;' * 300000}</p>'
        '<p title="&notit; &amp;">AT&T &copy; R&D &#8217;s &nbsp;x &#65 &lt</p>'
        '<p><a href="?a=1&b=2&amp;c=3&copy=4">link</a></p>',
      );
      expect(
        _plain(references.delta),
        '${'&' * 300000}\nAT&T © R&D ’s \u00A0x A <\nlink\n',
      );
      final link = references.delta.toList().firstWhere(
        (operation) => operation.data == 'link',
      );
      expect(link.attributes?['link'], '?a=1&b=2&c=3&copy=4');
    });

    test('pictures are budgeted by their pixels', () {
      final loaded = _read(
        '<p>${[for (var index = 0; index < 10; index++) '<img src="${_pngOf(10000, 6000, index)}" alt="big $index">'].join()}'
        '<img src="${_pngOf(0xFFFFFFFF, 0xFFFFFFFF, 99)}" alt="huge"></p>',
      );
      final pictures = loaded.delta.toList().where(
        (operation) =>
            operation.data is Map &&
            (operation.data as Map).containsKey(EmbedTypes.image),
      );
      expect(pictures, hasLength(8));
      expect(_plain(loaded.delta), contains('big 8'));
      expect(_plain(loaded.delta), contains('huge'));
      expect(loaded.notices, contains(DocumentNotice.contentNotImported));

      // Photos of a self-contained page stay well within it.
      final photos = _read(
        '<p>${[for (var index = 1; index <= 10; index++) '<img src="${_pngOf(4032, 3024, index)}" alt="Photo $index">'].join()}</p>',
      );
      expect(
        photos.delta.toList().where(
          (operation) =>
              operation.data is Map &&
              (operation.data as Map).containsKey(EmbedTypes.image),
        ),
        hasLength(10),
      );
      expect(photos.notices, isEmpty);
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
