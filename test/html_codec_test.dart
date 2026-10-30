import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/delta_blocks.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/document_look.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/headers_footers.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/html/html_codec.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);
final _pngUri = 'data:image/png;base64,${base64Encode(_png)}';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

LoadedDocument _read(String html, [TableStore? tables]) =>
    HtmlCodec(DocxCodec(tables ?? TableStore())).decode(_bytes(html));

LoadedDocument _fixture(String name, [TableStore? tables]) => HtmlCodec(
  DocxCodec(tables ?? TableStore()),
).decode(File('test/fixtures/html/$name').readAsBytesSync());

Map<String, dynamic> _visible(Map<String, dynamic>? attributes) => {
  for (final MapEntry(:key, :value) in (attributes ?? const {}).entries)
    if (!key.startsWith('vw-')) key: value,
};

/// Paragraphs as their text and visible line attributes.
List<List<Object>> _lines(Delta delta) => [
  for (final block in documentBlocks(delta))
    if (block is LineBlock) [block.plainText, _visible(block.attributes)],
];

LineBlock _line(Delta delta, String text) => documentBlocks(
  delta,
).whereType<LineBlock>().firstWhere((line) => line.plainText.contains(text));

/// Visible attributes of the text run holding [text].
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

List<TableModel> _tables(Delta delta, TableStore store) => [
  for (final block in documentBlocks(delta))
    if (block case EmbedBlock(type: EmbedTypes.table, :final value))
      store[tableIdOf(value)]!,
];

String _cellText(TableCellModel cell) =>
    cell.controller.document.toPlainText().trim();

List<Map<String, dynamic>> _images(Delta delta) => [
  for (final operation in delta.toList())
    if (operation.data case {EmbedTypes.image: _})
      _visible(operation.attributes),
];

String _plain(Delta delta) => [
  for (final operation in delta.toList())
    if (operation.data is String) operation.data,
].join();

bool _isPageBreak(Object? data) =>
    data is Map && data.containsKey(EmbedTypes.pageBreak);

int _pageBreaks(Delta delta) =>
    delta.toList().where((operation) => _isPageBreak(operation.data)).length;

String _write(LoadedDocument loaded, TableStore tables) => utf8.decode(
  HtmlCodec(DocxCodec(tables)).encode(
    loaded.delta,
    source: loaded.source,
    look: loaded.look,
    headersFooters: loaded.headersFooters,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reading', () {
    test('headings, paragraphs and character formatting', () {
      final delta = _read('''
<h1>Title</h1><h3>Small <em>heading</em></h3>
<p><b>b</b> <strong>strong</strong> <i>i</i> <u>u</u> <ins>ins</ins>
<s>s</s> <del>del</del> x<sup>2</sup> H<sub>2</sub>O <code>code</code>
<mark>mark</mark> <small>small</small>
<font face="Georgia, serif" size="5" color="#00ff00">font</font>
<span style="font: italic bold 14pt/2 'Comic Sans MS', cursive">shorthand</span>
<span style="color: rgb(255, 0, 0); background-color: #FF0">colors</span>
<span style="text-decoration: underline line-through">both</span>
<span style="vertical-align: super">up</span></p>''').delta;

      expect(_lines(delta)[0], [
        'Title',
        {'header': 1},
      ]);
      expect(_lines(delta)[1], [
        'Small heading',
        {'header': 3},
      ]);
      expect(_run(delta, 'heading'), {'italic': true});
      expect(_run(delta, 'strong'), {'bold': true});
      expect(_run(delta, 'ins'), {'underline': true});
      expect(_run(delta, 'del'), {'strike': true});
      expect(_run(delta, '2'), {'script': 'super'});
      expect(_run(delta, 'code'), {'font': 'Courier New'});
      expect(_run(delta, 'mark'), {'background': '#FFFF00'});
      expect(_run(delta, 'small'), {'size': '10'});
      expect(_run(delta, 'font'), {
        'font': 'Georgia',
        'size': '18',
        'color': '#00FF00',
      });
      expect(_run(delta, 'shorthand'), {
        'bold': true,
        'italic': true,
        'size': '14',
        'font': 'Comic Sans MS',
      });
      expect(_run(delta, 'colors'), {
        'color': '#FF0000',
        'background': '#FFFF00',
      });
      expect(_run(delta, 'both'), {'underline': true, 'strike': true});
      expect(_run(delta, 'up'), {'script': 'super'});
    });

    test('whitespace collapses as in browsers and stays in pre', () {
      final delta = _read(
        '<p>  a \n\t b<b> c </b> d  </p><p>e<br>  f<br></p>'
        '<p>&nbsp;</p><pre>\nline 1\n  line\t2\n\nline 4\n</pre>',
      ).delta;

      expect(_lines(delta).map((line) => line[0]), [
        'a b c d',
        'e\u2028f',
        '',
        'line 1',
        '  line\t2',
        '',
        'line 4',
      ]);
      expect(_run(delta, 'line 1'), {'font': 'Courier New'});
      expect(_line(delta, 'line 1').spaceAfter, 0);
    });

    test('style sheet rules apply by specificity, then inline styles', () {
      final delta = _read('''
<style>
p { color: #111111 } .note { color: #222222 } p.note { color: #333333 }
#key { color: #444444 } .strong { font-weight: bold !important }
.big { font-size: 150% } .em { font-size: 2em } .px { font-size: 20px }
.caps { text-transform: uppercase } .lower { text-transform: lowercase }
.spaced { margin: 6pt 0 18pt 72pt; text-indent: -18pt; line-height: 150% }
.right { text-align: right } .hidden { display: none }
</style>
<div>Plain text without any color, long enough to be the most common.</div>
<p>tag</p><p class="note">class</p><p class="note" id="key">id</p>
<p class="note" style="color: #555555">inline</p>
<p><span class="strong" style="font-weight: normal">important</span>
<span class="big">big</span> <span class="em">em</span>
<span class="px">px</span> <span class="lower">LOWER</span></p>
<p class="spaced right">spaced</p><p class="hidden">gone</p>''').delta;

      expect(_run(delta, 'tag')['color'], '#111111');
      expect(_run(delta, 'class')['color'], '#333333');
      expect(_run(delta, 'id')['color'], '#444444');
      expect(_run(delta, 'inline')['color'], '#555555');
      expect(_run(delta, 'important')['bold'], isTrue);
      expect(_run(delta, 'big')['size'], '18');
      expect(_run(delta, 'em')['size'], '24');
      expect(_run(delta, 'px')['size'], '15');
      expect(_plain(delta), contains('lower'));
      final spaced = _line(delta, 'spaced');
      expect(spaced.spaceBefore, 6);
      expect(spaced.spaceAfter, 18);
      expect(spaced.indent, 2);
      expect(spaced.firstLine, -18);
      expect(spaced.lineHeight, 1.5);
      expect(spaced.align, 'right');
      expect(_plain(delta), isNot(contains('gone')));
    });

    test('lists keep levels, start numbers, types and values', () {
      final loaded = _read('''
<ul><li>a<ul><li>a.1<ol type="a"><li>a.1.a</li></ol></li></ul></li>
<li><p>b</p><p>b, second paragraph</p></li></ul>
<ol start="4"><li>four</li><li value="9">nine</li><li>ten</li></ol>
<ul style="list-style-type: none"><li>plain</li></ul>
<li>orphan</li>''');
      final lines = _lines(loaded.delta);

      expect(lines[0], [
        'a',
        {'list': 'bullet'},
      ]);
      expect(lines[1], [
        'a.1',
        {'list': 'bullet', 'indent': 1},
      ]);
      expect(lines[2], [
        'a.1.a',
        {'list': 'ordered', 'indent': 2},
      ]);
      expect(lines[3], [
        'b',
        {'list': 'bullet'},
      ]);
      expect(lines[4], [
        'b, second paragraph',
        {'indent': 1},
      ]);
      expect(lines[5], [
        'four',
        {'list': 'ordered'},
      ]);
      expect(lines[8], [
        'plain',
        {'indent': 1},
      ]);
      expect(lines[9], [
        'orphan',
        {'list': 'bullet'},
      ]);
      final numbering = (loaded.source! as DocxPackage).text(
        'word/numbering.xml',
      )!;
      expect(numbering, contains('<w:start w:val="4"/>'));
      expect(numbering, contains('<w:start w:val="9"/>'));
      expect(numbering, contains('<w:numFmt w:val="lowerLetter"/>'));
    });

    test('tables keep spans, merges, fills, widths, borders and headers', () {
      final tables = TableStore();
      final delta = _read('''
<table border="1" style="width: 300pt">
<colgroup><col style="width: 100pt"><col span="2"></colgroup>
<thead><tr><th colspan="2">head</th><th rowspan="3" bgcolor="#D9E2F3">tall</th></tr></thead>
<tr><td style="background-color: yellow">a</td><td>b</td></tr>
<tr><td>c</td><td><table><tr><td>inner</td></tr></table></td></tr>
</table>
<table><tr><td>plain</td></tr></table>''', tables).delta;
      final [outer, plain] = _tables(delta, tables);

      expect(outer.bordered, isTrue);
      expect(plain.bordered, isFalse);
      expect(outer.columnWidths, [2000, 2000, 2000]);
      expect(outer.rows.first.propertiesXml, contains('tblHeader'));
      expect(outer.rows.first.cells.first.gridSpan, 2);
      final tall = outer.rows.first.cells.last;
      expect(tall.verticalMerge, VerticalMerge.restart);
      expect(tall.fill?.toARGB32(), 0xFFD9E2F3);
      expect(outer.rows.skip(1).map((row) => row.cells.last.verticalMerge), [
        VerticalMerge.continuation,
        VerticalMerge.continuation,
      ]);
      expect(outer.rows[1].cells.first.fill?.toARGB32(), 0xFFFFFF00);
      expect(
        _run(
          outer.rows.first.cells.first.controller.document.toDelta(),
          'head',
        ),
        {'bold': true},
      );
      final nested = outer.rows[2].cells[1].controller.document.toDelta();
      expect(
        _tables(nested, tables).single.rows.single.cells.single,
        isNotNull,
      );
      expect(
        _cellText(_tables(nested, tables).single.rows.single.cells.single),
        'inner',
      );
    });

    test('links go only to the web, e-mail, nearby files and bookmarks', () {
      final delta = _read('''
<h2 id="intro">Intro</h2><a name="old"></a><p>
<a href="https://example.com/a?b=1&amp;c=2">web</a>
<a href="mailto:a@b.c">mail</a> <a href="#intro">back</a>
<a href="javascript:alert(1)">script</a> <a href="file:///etc/passwd">file</a>
<a href="page.html">relative</a> <a href="  HTTP://EXAMPLE.COM  ">upper</a></p>
<p id="unused">no bookmark</p>''').delta;

      expect(_run(delta, 'web')['link'], 'https://example.com/a?b=1&c=2');
      expect(_run(delta, 'mail')['link'], 'mailto:a@b.c');
      expect(_run(delta, 'back')['link'], '#intro');
      for (final text in ['script', 'file']) {
        expect(_run(delta, text)['link'], isNull);
      }
      expect(_run(delta, 'relative')['link'], 'page.html');
      expect(_run(delta, 'upper')['link'], 'HTTP://EXAMPLE.COM');
      expect(
        _line(delta, 'Intro').attributes[HiddenAttributes.bookmarks],
        '["intro"]',
      );
      expect(
        _line(delta, 'web').attributes[HiddenAttributes.bookmarks],
        '["old"]',
      );
      expect(
        _line(delta, 'no bookmark').attributes[HiddenAttributes.bookmarks],
        isNull,
      );
    });

    test('pictures come only from data URIs of types Word opens', () {
      final loaded = _read('''
<p><img src="$_pngUri" style="width: 2in" alt="dot">
<img src="${_pngUri.replaceFirst('png', 'jpeg')}" width="40" height="20">
<img src="https://example.com/a.png" alt="remote">
<img src="file:///Users/a/b.png" alt="local">
<img src="data:image/svg+xml;base64,${base64Encode(utf8.encode('<svg/>'))}" alt="vector">
<img src="data:image/png;base64,AAAA" alt="garbage"></p>''');
      final images = _images(loaded.delta);

      expect(images, hasLength(2));
      expect(images.first['width'], '144');
      expect(images.first['height'], '144');
      expect(images.last['width'], '30');
      expect(images.last['height'], '15');
      expect(_plain(loaded.delta), contains('remote local vector garbage'));
      expect(loaded.notices, contains(DocumentNotice.contentNotImported));
    });

    test('page breaks come from CSS and Word line breaks', () {
      final delta = _read('''
<p>one</p><p style="page-break-before: always">two</p>
<p style="break-after: page">three</p><div style="break-after: page"></div>
<p>four<br style="page-break-before: always">five</p>''').delta;

      expect(_lines(delta).map((line) => line[0]), [
        'one',
        'two',
        'three',
        '',
        'fourfive',
      ]);
      expect(_pageBreaks(delta), 4);
      final ops = delta.toList();
      bool endsWithBreak(String text) {
        final index = ops.indexWhere(
          (op) => op.data is String && (op.data as String).endsWith(text),
        );
        return _isPageBreak(ops[index + 1].data);
      }

      expect(endsWithBreak('one'), isTrue);
      expect(endsWithBreak('three'), isTrue);
    });

    test('page setup, language and the page\'s own defaults', () {
      final loaded = _read('''
<html lang="pt-br"><head><style>
@page { size: A4 landscape; margin: 1in 2cm }
body { font-family: "Times New Roman", serif; font-size: 10.5pt; color: #333333 }
p { margin: 0 0 4pt; line-height: 1.5 }
h1 { font-size: 20pt; color: navy; font-weight: normal; margin-top: 30pt }
</style></head><body><h1>Heading</h1><p>one</p><p>two</p></body></html>''');
      final look = loaded.look;

      expect(look.pageWidth, closeTo(841.9, 0.05));
      expect(look.pageHeight, closeTo(595.3, 0.05));
      expect(look.margins, const EdgeInsets.fromLTRB(56.7, 72, 56.7, 72));
      expect(look.body.fontFamily, 'Times New Roman');
      expect(look.body.fontSize, 10.5);
      expect(look.body.color.toARGB32(), 0xFF333333);
      expect(look.body.spaceAfter, 4);
      expect(look.lineSpacing, 1.5);
      expect(look.headings[1]?.fontSize, 20);
      expect(look.headings[1]?.bold, isFalse);
      expect(look.headings[1]?.color.toARGB32(), 0xFF000080);
      expect(look.headings[1]?.spaceBefore, 30);
      expect(_run(loaded.delta, 'one'), isEmpty);
      expect(
        (loaded.source! as DocxPackage).text('word/styles.xml'),
        contains('w:val="pt-BR"'),
      );
    });

    test('charsets come from the byte order mark or the page', () {
      final cyrillic = Uint8List.fromList([
        ...latin1.encode('<meta charset="windows-1251"><p>'),
        0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, //
        ...latin1.encode('</p>'),
      ]);
      final codec = HtmlCodec(DocxCodec(TableStore()));
      expect(_plain(codec.decode(cyrillic).delta), 'Привет\n');

      final utf16 = Uint8List.fromList([
        0xFF,
        0xFE,
        for (final unit in '<p>façade</p>'.codeUnits) ...[
          unit & 0xFF,
          unit >> 8,
        ],
      ]);
      expect(_plain(codec.decode(utf16).delta), 'façade\n');

      final xml = Uint8List.fromList([
        ...latin1.encode(
          '<?xml version="1.0" encoding="ISO-8859-1"?><html><body><p>',
        ),
        0xE7, 0xE3, //
        ...latin1.encode('</p></body></html>'),
      ]);
      expect(_plain(codec.decode(xml).delta), 'çã\n');
      final windows1252 = Uint8List.fromList([
        0x3C,
        0x70,
        0x3E,
        0x93,
        0x61,
        0x94,
      ]);
      expect(_plain(codec.decode(windows1252).delta), '“a”\n');
    });

    test('scripts, styles, forms and embedded content are left out', () {
      final loaded = _read('''
<html><head><title>Not text</title><script>var a = "<p>no</p>";</script></head>
<body><noscript><p>no script</p></noscript><template><p>template</p></template>
<p>visible <input value="field"><button>Press</button><select><option>x</option></select>
<textarea>typed</textarea></p><iframe src="https://example.com">frame</iframe>
<svg><text>vector</text><foreignObject><p>inside</p></foreignObject></svg>
<object data="a.swf">fallback</object><p>end</p></body></html>''');
      final text = _plain(loaded.delta);

      expect(text, contains('visible'));
      expect(text, contains('end'));
      for (final hidden in [
        'Not text',
        'no',
        'template',
        'field',
        'Press',
        'typed',
        'frame',
        'vector',
        'fallback',
      ]) {
        expect(text, isNot(contains(hidden)), reason: hidden);
      }
      expect(loaded.notices, contains(DocumentNotice.contentNotImported));
    });

    test('Word pages', () {
      final tables = TableStore();
      final loaded = _fixture('word.htm', tables);
      final delta = loaded.delta;
      final lines = _lines(delta);

      expect(lines[0], [
        'Café menu',
        {'header': 1},
      ]);
      expect(_run(delta, 'crème brûlée'), {'italic': true});
      expect(_run(delta, 'color'), {'color': '#C00000'});
      expect(lines[2], ['', <String, dynamic>{}]);
      expect(lines[3], [
        'First item',
        {'list': 'bullet'},
      ]);
      expect(lines[4], [
        'Second item',
        {'list': 'bullet'},
      ]);
      expect(lines[5], [
        'Step three',
        {'list': 'ordered'},
      ]);
      expect(lines[6][0], 'Name\tValue');
      expect(_pageBreaks(delta), 1);
      expect(_plain(delta), contains('commented text.'));
      expect(_plain(delta), isNot(contains('MS1')));
      expect(_plain(delta), isNot(contains('remark')));
      expect(_plain(delta), contains('Logo'));
      expect(loaded.notices, {
        DocumentNotice.commentsHidden,
        DocumentNotice.contentNotImported,
      });
      final table = _tables(delta, tables).single;
      expect(table.bordered, isTrue);
      expect(table.columnWidths, [3000, 3000]);
      expect(table.rows.single.cells.last.fill?.toARGB32(), 0xFFFFFF00);
      expect(
        (loaded.source! as DocxPackage).text('word/numbering.xml'),
        contains('<w:start w:val="3"/>'),
      );
      final look = loaded.look;
      expect(look.pageWidth, 612);
      expect(look.margins, const EdgeInsets.all(72));
      expect(look.body.fontFamily, 'Calibri');
      expect(look.body.fontSize, 11);
      expect(look.body.spaceAfter, 8);
      expect(look.lineSpacing, closeTo(1.07, 0.01));
      expect(look.headings[1]?.fontFamily, 'Calibri Light');
      expect(look.headings[1]?.bold, isFalse);
      expect(look.headings[1]?.color.toARGB32(), 0xFF2F5496);
    });

    test('Google Docs pages', () {
      final tables = TableStore();
      final loaded = _fixture('google-docs.html', tables);
      final delta = loaded.delta;
      final lines = _lines(delta);

      expect(lines[1], [
        'Section',
        {'header': 1},
      ]);
      expect(_run(delta, 'bold'), {'bold': true});
      expect(_run(delta, 'jump')['link'], '#h_abc');
      expect(
        _line(delta, 'Section').attributes[HiddenAttributes.bookmarks],
        '["h_abc"]',
      );
      expect(lines[3][0], '');
      expect(lines[4], [
        'Bullet',
        {'list': 'bullet'},
      ]);
      expect(lines[5], [
        'Nested',
        {'list': 'bullet', 'indent': 1},
      ]);
      expect(lines[6], [
        'One',
        {'list': 'ordered'},
      ]);
      expect(lines[8], [
        'Two',
        {'list': 'ordered'},
      ]);
      expect(
        _line(delta, 'One').attributes[HiddenAttributes.numbering],
        _line(delta, 'Two').attributes[HiddenAttributes.numbering],
      );
      final table = _tables(delta, tables).single;
      expect(table.bordered, isTrue);
      expect(table.rows.single.cells.first.fill?.toARGB32(), 0xFFCFE2F3);
      expect(_pageBreaks(delta), 1);
      expect(loaded.look.body.fontFamily, 'Arial');
      expect(loaded.look.body.fontSize, 11);
      expect(loaded.look.body.spaceAfter, 0);
      expect(loaded.look.headings[1]?.fontSize, 20);
      expect(loaded.notices, {DocumentNotice.contentNotImported});
    });

    test('pages written by textutil', () {
      final tables = TableStore();
      final loaded = _fixture('textutil.html', tables);
      final delta = loaded.delta;

      expect(_lines(delta)[0][0], 'Quarterly report');
      expect(_lines(delta)[0][1], {'header': 1});
      expect(_run(delta, 'underlined'), {'underline': true});
      expect(_run(delta, 'red')['color'], '#B00004');
      expect(_line(delta, 'Centered').align, 'center');
      expect(_line(delta, 'Second point').list, 'bullet');
      expect(_line(delta, 'Step two').list, 'ordered');
      expect(_run(delta, 'the site')['link'], 'https://example.com/report');
      final table = _tables(delta, tables).single;
      expect(table.bordered, isTrue);
      expect(table.rows.map((row) => row.cells.map(_cellText).toList()), [
        ['Region', 'Sales'],
        ['North', '120'],
      ]);
      expect(loaded.look.body.fontFamily, 'Times');
    });
  });

  group('writing', () {
    test('a standalone, escaped HTML5 page without headers and footers', () {
      final tables = TableStore();
      final html = utf8.decode(
        HtmlCodec(DocxCodec(tables)).encode(
          Delta()
            ..insert('A <b> & "c"')
            ..insert('\n', {'header': 2})
            ..insert('tab\there\u2028next\u00A0nbsp')
            ..insert('\n')
            ..insert('bad', {'link': 'javascript:alert(1)'})
            ..insert(' ')
            ..insert('good', {'link': 'https://a.b/?q="x"&y=<z>'})
            ..insert('\n'),
          look: const DocumentLook(pageWidth: 612, pageHeight: 792),
          headersFooters: HeadersFooters(
            headers: {
              PageVariant.normal: HeaderFooterStory(
                delta: Delta()..insert('Header text\n'),
              ),
            },
          ),
        ),
      );

      expect(
        html,
        startsWith('<!DOCTYPE html>\n<html>\n<head>\n<meta charset="utf-8">'),
      );
      expect(html, contains('<title>A &lt;b&gt; &amp; "c"</title>'));
      expect(html, contains('<h2>A &lt;b&gt; &amp; "c"</h2>'));
      expect(html, contains('@page { size: 612pt 792pt;'));
      expect(html, contains('<p>tab\there<br>next&nbsp;nbsp</p>'));
      expect(
        html,
        contains(
          '<p>bad <a href="https://a.b/?q=&quot;x&quot;&amp;y=&lt;z&gt;">good</a></p>',
        ),
      );
      expect(html, isNot(contains('javascript')));
      expect(html, isNot(contains('Header text')));
    });

    test('lists, tables, pictures and page breaks', () {
      final tables = TableStore();
      final table = tables.createEmpty(rows: 2, columns: 2, totalWidth: 4000);
      table.rows.first.cells.first
        ..gridSpan = 2
        ..controller.document.insert(0, 'wide');
      table.rows.first.cells.removeLast();
      table.rows.last.cells.first.controller.document.insert(0, 'x');
      final html = utf8.decode(
        HtmlCodec(DocxCodec(tables)).encode(
          Delta()
            ..insert('one')
            ..insert('\n', {'list': 'ordered'})
            ..insert('one.a')
            ..insert('\n', {'list': 'bullet', 'indent': 1})
            ..insert('two')
            ..insert('\n', {'list': 'ordered'})
            ..insert('deep')
            ..insert('\n', {'list': 'bullet', 'indent': 2})
            ..insert({EmbedTypes.table: encodeTableId(table.id)})
            ..insert('\n')
            ..insert(
              {EmbedTypes.image: _pngUri},
              {'width': '30', 'height': '15'},
            )
            ..insert('\n')
            ..insert({EmbedTypes.pageBreak: 'page'})
            ..insert('\n')
            ..insert('after')
            ..insert('\n'),
        ),
      );

      expect(
        html,
        contains(
          '<ol><li>one<ul><li>one.a</li></ul></li>\n<li>two'
          '<ul style="list-style-type:none"><li><ul><li>deep</li></ul></li></ul>'
          '</li></ol>',
        ),
      );
      expect(html, contains('<td colspan="2"><p>wide</p></td>'));
      expect(html, contains('<col style="width:100pt">'));
      expect(
        html,
        contains('<img src="$_pngUri" alt="" style="width:30pt;height:15pt">'),
      );
      expect(
        html,
        contains(
          '<div style="break-after:page;page-break-after:always"></div>',
        ),
      );
    });

    test('pages open in other programs', () async {
      final textutil = File('/usr/bin/textutil');
      if (!textutil.existsSync()) return;
      final tables = TableStore();
      final loaded = _fixture('word.htm', tables);
      final folder = Directory.systemTemp.createTempSync('html_codec');
      addTearDown(() => folder.deleteSync(recursive: true));
      final file = File('${folder.path}/out.html')
        ..writeAsStringSync(_write(loaded, tables));
      final result = await Process.run(textutil.path, [
        '-convert',
        'txt',
        file.path,
        '-stdout',
      ]);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('Café menu'));
      expect(result.stdout, contains('First item'));
      expect(result.stdout, contains('Name\tValue'));
    });
  });

  test('round trips keep content, formatting, structure and page size', () {
    final tables = TableStore();
    final original = _read('''
<html lang="en"><head><style>
@page { size: 612pt 792pt; margin: 54pt }
body { font-family: Georgia; font-size: 11pt }
h2 { color: #1F4E79 }
</style></head><body>
<h1 id="top">Report</h1><h2>Part</h2>
<p style="text-align: justify; margin-left: 72pt; margin-top: 10pt">Text with
<b>bold</b>, <i>italic</i>, <u>underline</u>, <s>strike</s>,
<span style="font-family: Verdana; font-size: 14pt; color: #C00000; background-color: #FFFF00">styled</span>,
x<sup>2</sup>, <a href="https://example.com/">a link</a> and <a href="#top">top</a>.</p>
<p style="line-height: 2">Line<br>break   and  spaces <span style="white-space: pre">a  \tb</span></p>
<ol start="5"><li>five<ul><li>nested</li></ul></li><li>six</li></ol>
<table border="1"><tr><td colspan="2">wide</td><td rowspan="2" style="background: #D9E2F3">tall</td></tr>
<tr><td>a</td><td>b</td></tr></table>
<p><img src="$_pngUri" style="width: 30pt; height: 20pt"></p>
<p style="break-after: page">before break</p><p>after break</p>
</body></html>''', tables);
    final again = _read(_write(original, tables), tables);

    expect(_lines(again.delta), _lines(original.delta));
    for (final text in [
      'bold',
      'italic',
      'underline',
      'strike',
      'styled',
      '2',
      'a link',
      'top',
    ]) {
      expect(_run(again.delta, text), _run(original.delta, text), reason: text);
    }
    expect(_run(again.delta, 'styled'), {
      'size': '14',
      'font': 'Verdana',
      'color': '#C00000',
      'background': '#FFFF00',
    });
    expect(_line(again.delta, 'Text with').spaceBefore, 10);
    expect(
      _line(again.delta, 'Line').plainText,
      'Line\u2028break and spaces a  \tb',
    );
    expect(_images(again.delta), _images(original.delta));
    expect(_pageBreaks(again.delta), 1);
    final [before, after] = [
      original,
      again,
    ].map((loaded) => _tables(loaded.delta, tables).single).toList();
    expect(after.bordered, before.bordered);
    expect(after.columnWidths, before.columnWidths);
    for (var row = 0; row < 2; row++) {
      expect(
        after.rows[row].cells.map(
          (cell) =>
              (cell.gridSpan, cell.verticalMerge, cell.fill, _cellText(cell)),
        ),
        before.rows[row].cells.map(
          (cell) =>
              (cell.gridSpan, cell.verticalMerge, cell.fill, _cellText(cell)),
        ),
      );
    }
    expect(
      (again.source! as DocxPackage).text('word/numbering.xml'),
      contains('<w:start w:val="5"/>'),
    );
    final look = again.look;
    expect(look.pageWidth, 612);
    expect(look.pageHeight, 792);
    expect(look.margins, const EdgeInsets.all(54));
    expect(look.body.fontFamily, 'Georgia');
    expect(look.body.fontSize, 11);
    expect(look.headings[2]?.color.toARGB32(), 0xFF1F4E79);
    expect(look.headings[1]?.fontSize, original.look.headings[1]?.fontSize);
  });

  group('hostile pages', () {
    Matcher fails() => throwsA(isA<FormatException>());

    test('deep nesting is rejected fast', () {
      for (final page in [
        '<div>' * 100000,
        '<span>' * 100000,
        '<ul><li>' * 50000,
        '<table><tr><td>' * 30000,
        '<b><i>' * 50000,
        '<p>${List.generate(2000, (i) => '<b id=$i>').join()}',
        '<svg><style>${'<div>' * 1000}</style></svg>',
        '<form><div></form>' * 1000,
      ]) {
        final watch = Stopwatch()..start();
        expect(() => _read(page), fails());
        expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
      }
    });

    test('unclosed formatting is not copied into every paragraph', () {
      final watch = Stopwatch()..start();
      final page =
          '<p>${List.generate(200, (i) => '<b id=$i>').join()}x</p>'
          '${'<p>x</p>' * 20000}';
      final loaded = _read(page);
      expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
      expect(_lines(loaded.delta), hasLength(20001));
      expect(_run(loaded.delta, 'x')['bold'], isTrue);
      expect(_visible(loaded.delta.toList().last.attributes), isEmpty);
      expect(
        loaded.delta.toList().where(
          (operation) => operation.attributes?['bold'] == true,
        ),
        hasLength(1),
      );
    });

    test('too many elements, cells or bytes are refused', () {
      Matcher tooLarge() => throwsA(
        isA<DocumentProblemException>().having(
          (error) => error.problem,
          'problem',
          DocumentProblem.tooLarge,
        ),
      );
      expect(() => _read('<p>x</p>' * 250000), tooLarge());
      expect(
        () => _read(
          '<table><tr>${'<td rowspan="65534">x</td>' * 63}</tr>'
          '${'<tr></tr>' * 10000}</table>',
        ),
        tooLarge(),
      );
      expect(
        () => HtmlCodec(
          DocxCodec(TableStore()),
        ).decode(Uint8List(HtmlCodec.maxBytes + 1)),
        tooLarge(),
      );
    });

    test('style sheets that repeat rules stay fast', () {
      final watch = Stopwatch()..start();
      final loaded = _read(
        '<style>${'.x { color: red; font-weight: bold } ' * 20000}</style>'
        '<p>${'<span class="x y z">a</span> ' * 100000}</p>',
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
      expect(_run(loaded.delta, 'a'), {'bold': true});
    });

    test('tables nested deeper than Word allows are flattened', () {
      final tables = TableStore();
      final loaded = _read(
        '${'<table><tr><td>' * 40}core${'</td></tr></table>' * 40}',
        tables,
      );
      var depth = 0;
      var delta = loaded.delta;
      while (_tables(delta, tables).isNotEmpty) {
        depth++;
        delta = _tables(
          delta,
          tables,
        ).single.rows.single.cells.single.controller.document.toDelta();
      }
      expect(depth, lessThanOrEqualTo(8));
      expect(_plain(delta), contains('core'));
    });

    test('broken markup and hostile styles never crash', () {
      final word = File('test/fixtures/html/word.htm').readAsBytesSync();
      for (var end = 0; end < word.length; end += 97) {
        expect(
          () => HtmlCodec(
            DocxCodec(TableStore()),
          ).decode(Uint8List.sublistView(word, 0, end)),
          returnsNormally,
        );
      }
      for (final page in [
        '<',
        '</',
        '<!--',
        '<p a="',
        '<p a=\'',
        '<![CDATA[ <p>',
        '<style>',
        '<style>p { color: red',
        '<style>${'{' * 10000}</style>',
        '<style>@media { ${'a { b: c } ' * 1000}</style><p>x</p>',
        '<p style="${'margin: 1e309pt 9999999in -1px; ' * 100}">x</p>',
        '<p style="font-size: 1e400px; line-height: -5; width: NaNpx">x</p>',
        '<img src="data:image/png;base64,${'A' * 1000}=">',
        '<td colspan="99999999999999999999" rowspan="-5">x</td>',
        '<ol start="99999999999999"><li value="-99999999999">x</li></ol>',
        '<math><mi><mglyph><malignmark></malignmark></mglyph></mi></math>x',
        '<select><noscript></select>${'<div>' * 100}x</noscript>',
        '<div><table></div>' * 20000,
        '\u0000\uFFFF\uD800<p>\u0001x</p>',
      ]) {
        expect(
          () => _read(page),
          anyOf(returnsNormally, throwsA(isA<FormatException>())),
          reason: page,
        );
      }
    });
  });
}
