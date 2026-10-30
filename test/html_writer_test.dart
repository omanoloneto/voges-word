import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:voges_word/document/delta_blocks.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/document_look.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/html/css.dart';
import 'package:voges_word/html/html_codec.dart';
import 'package:voges_word/html/markdown_codec.dart';
import 'package:voges_word/odt/odt_codec.dart';
import 'package:xml/xml.dart';

import 'odt_fixtures.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);
final _pngUri = 'data:image/png;base64,${base64Encode(_png)}';

late TableStore _tables;

/// Opens a document built as the other formats' readers build theirs.
LoadedDocument _open(DocumentSpec spec) =>
    DocxCodec(_tables).read(DocxBuilder(spec).build());

LoadedDocument _read(String html) =>
    HtmlCodec(DocxCodec(_tables)).decode(Uint8List.fromList(utf8.encode(html)));

/// Saves as the session does, with the opened package as the source.
String _save(LoadedDocument loaded) => utf8.decode(
  HtmlCodec(DocxCodec(_tables)).encode(
    loaded.delta,
    source: loaded.source,
    look: loaded.look,
    headersFooters: loaded.headersFooters,
  ),
);

String _write(Delta delta, {DocumentLook look = const DocumentLook()}) =>
    utf8.decode(HtmlCodec(DocxCodec(_tables)).encode(delta, look: look));

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

Operation _operation(Delta delta, String text) => delta.toList().firstWhere(
  (operation) =>
      operation.data is String && (operation.data as String).contains(text),
);

String _plain(Delta delta) => [
  for (final operation in delta.toList())
    if (operation.data is String) operation.data,
].join();

TableModel _table(Delta delta) =>
    _tables[tableIdOf(
      documentBlocks(delta)
          .whereType<EmbedBlock>()
          .firstWhere((block) => block.type == EmbedTypes.table)
          .value,
    )]!;

ParagraphSpec _item(String text, int list, [int level = 0]) => ParagraphSpec([
  TextSpec(text),
], format: ParagraphFormat(list: ListRef(list, level)));

/// [loaded] saved as a page after giving the list item with [text] other
/// [attributes], as the editor's list buttons do.
String _saveChanged(
  LoadedDocument loaded,
  String text,
  Map<String, dynamic> attributes,
) {
  final delta = Delta();
  var found = false;
  for (final operation in loaded.delta.toList()) {
    final data = operation.data;
    if (data is String && data.contains(text)) found = true;
    if (found && data == '\n') {
      delta.insert('\n', {...?operation.attributes, ...attributes});
      found = false;
    } else {
      delta.push(operation);
    }
  }
  return utf8.decode(
    HtmlCodec(
      DocxCodec(_tables),
    ).encode(delta, source: loaded.source, look: loaded.look),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => _tables = TableStore());

  group('lists', () {
    test('nested items have no line breaks between them that would show', () {
      final delta = Delta()
        ..insert('one')
        ..insert('\n', {'list': 'ordered'})
        ..insert('one.a')
        ..insert('\n', {'list': 'ordered', 'indent': 1})
        ..insert('one.b')
        ..insert('\n', {'list': 'ordered', 'indent': 1})
        ..insert('two')
        ..insert('\n', {'list': 'ordered'});
      final html = _write(delta);

      expect(html, contains('<li>one.a</li><li>one.b</li>'));
      expect(_lines(_read(html).delta), _lines(delta));
    });

    test('numbered headings stay headings and name the page', () {
      final spec = DocumentSpec();
      final chapters = spec.addList(ListSpec.numbered());
      spec.body.addAll([
        ParagraphSpec(
          [const TextSpec('Introduction')],
          heading: 1,
          format: ParagraphFormat(list: ListRef(chapters)),
        ),
        ParagraphSpec(
          [const TextSpec('Background')],
          heading: 2,
          format: ParagraphFormat(list: ListRef(chapters, 1)),
        ),
        const ParagraphSpec([TextSpec('Text.')]),
      ]);
      final html = _save(_open(spec));

      expect(html, contains('<title>Introduction</title>'));
      expect(
        html,
        contains(
          '<ol><li><h1>Introduction</h1><ol type="a"><li><h2>Background</h2>'
          '</li></ol></li></ol>',
        ),
      );

      final page = _read(
        '<ol><li><h2>Scope</h2></li><li><h2>Terms</h2></li></ol>',
      );
      expect(_lines(_read(_save(page)).delta), [
        [
          'Scope',
          {'header': 2, 'list': 'ordered'},
        ],
        [
          'Terms',
          {'header': 2, 'list': 'ordered'},
        ],
      ]);
    });

    test('nested numbered lists made in the editor count 1., a. and i.', () {
      final html = _write(
        Delta()
          ..insert('one')
          ..insert('\n', {'list': 'ordered'})
          ..insert('one.a')
          ..insert('\n', {'list': 'ordered', 'indent': 1})
          ..insert('one.a.i')
          ..insert('\n', {'list': 'ordered', 'indent': 2})
          ..insert('again')
          ..insert('\n', {'list': 'ordered', 'indent': 3}),
      );

      expect(
        html,
        contains(
          '<ol><li>one<ol type="a"><li>one.a<ol type="i"><li>one.a.i'
          '<ol><li>again</li></ol>',
        ),
      );
    });

    test('numbered levels restart after a bullet of their Word list', () {
      final spec = DocumentSpec();
      final list = spec.addList(
        ListSpec([
          const ListLevelSpec(format: NumberFormat.bullet, text: '•'),
          for (var level = 1; level < 9; level++)
            ListLevelSpec(format: NumberFormat.decimal, text: '%${level + 1}.'),
        ]),
      );
      spec.body.addAll([
        _item('Bullet A', list),
        _item('A1', list, 1),
        _item('A2', list, 1),
        _item('Bullet B', list),
        _item('B1', list, 1),
      ]);
      final html = _save(_open(spec));

      expect(html, contains('<li>Bullet A<ol><li>A1</li><li>A2</li></ol>'));
      expect(html, contains('<li>Bullet B<ol><li>B1</li></ol>'));
    });

    test('items switched to another kind leave their Word list, as in '
        '.docx', () {
      final spec = DocumentSpec();
      final numbered = spec.addList(ListSpec.numbered());
      final bullets = spec.addList(ListSpec.bullets());
      spec.body.addAll([
        _item('Apples', numbered),
        _item('A1', numbered, 1),
        _item('Bananas', numbered),
        _item('A2', numbered, 1),
        _item('Cherries', numbered),
        const ParagraphSpec([TextSpec('Between')]),
        _item('Milk', bullets),
        _item('Eggs', bullets),
        _item('Bread', bullets),
      ]);
      final loaded = _open(spec);

      final bullet = _saveChanged(loaded, 'Bananas', {'list': 'bullet'});
      expect(bullet, contains('<ul><li>Bananas<ol start="2" type="a">'));
      expect(bullet, contains('<ol start="2"><li>Cherries</li></ol>'));
      final task = _saveChanged(loaded, 'Bananas', {'list': 'unchecked'});
      expect(task, contains('<ol start="2" type="a"><li>A2</li></ol>'));
      expect(task, contains('<ol start="2"><li>Cherries</li></ol>'));
      expect(
        _saveChanged(loaded, 'Eggs', {'list': 'ordered'}),
        contains('<ol><li>Eggs</li></ol>'),
      );

      // The .docx writer starts a new list of its own after a number of a
      // Word list.
      final numId = _line(
        loaded.delta,
        'Apples',
      ).attributes[HiddenAttributes.numbering];
      final html = utf8.decode(
        HtmlCodec(DocxCodec(_tables)).encode(
          Delta()
            ..insert('Mine')
            ..insert('\n', {'list': 'ordered'})
            ..insert('Word')
            ..insert('\n', {
              'list': 'ordered',
              HiddenAttributes.numbering: numId,
            })
            ..insert('Mine again')
            ..insert('\n', {'list': 'ordered'}),
          source: loaded.source,
        ),
      );
      expect(html, contains('<ol><li>Mine again</li></ol>'));
    });

    test('checklists show only their boxes and open without a space', () {
      final html = _write(
        Delta()
          ..insert('buy milk')
          ..insert('\n', {'list': 'checked'})
          ..insert('call mom')
          ..insert('\n', {'list': 'unchecked'}),
      );

      expect(
        html,
        contains(
          '<li style="list-style-type:none"><input type="checkbox" '
          'disabled="disabled" checked="checked" style="margin-right:0.4em"/>'
          'buy milk</li>',
        ),
      );
      expect(_lines(_read(html).delta), [
        [
          'buy milk',
          {'list': 'bullet'},
        ],
        [
          'call mom',
          {'list': 'bullet'},
        ],
      ]);
    });
  });

  test('footnotes and endnotes keep their text at the end of the page', () {
    final spec = DocumentSpec()
      ..body.add(
        const ParagraphSpec([
          TextSpec('As Smith showed'),
          NoteSpec(NoteKind.footnote, [
            ParagraphSpec([TextSpec('SMITH, J. The source. p. 42.')]),
          ]),
          TextSpec(', the claim holds.'),
          NoteSpec(NoteKind.endnote, [
            ParagraphSpec([TextSpec('An endnote.')]),
            TableSpec([
              RowSpec([
                CellSpec([
                  ParagraphSpec([TextSpec('in a note')]),
                ]),
              ]),
            ]),
          ]),
        ]),
      );
    final loaded = _open(spec);
    final tables = _tables.all.length;
    final html = _save(loaded);

    expect(
      html,
      contains(
        '<p>As Smith showed<sup><a href="#fn-1" id="fnref-1">1</a></sup>, '
        'the claim holds.<sup><a href="#en-1" id="enref-1">i</a></sup></p>',
      ),
    );
    final footnotes = html.indexOf('<section class="footnotes">');
    final endnotes = html.indexOf('<section class="endnotes">');
    expect(footnotes, greaterThan(html.indexOf('the claim holds')));
    expect(endnotes, greaterThan(footnotes));
    expect(
      html.substring(footnotes, endnotes),
      allOf(
        contains('<div id="fn-1"><p'),
        contains('<a href="#fnref-1"><sup>1</sup></a> '),
        contains('SMITH, J. The source. p. 42.'),
      ),
    );
    expect(
      html.substring(endnotes),
      allOf(
        contains('<div id="en-1"><p'),
        contains('<a href="#enref-1"><sup>i</sup></a> '),
        contains('An endnote.'),
        contains('<td><p>in a note</p></td>'),
      ),
    );
    expect(_tables.all.length, tables);

    final again = _read(html).delta;
    expect(_plain(again), contains('SMITH, J. The source. p. 42.'));
    expect(_operation(again, 'SMITH').attributes?['size'], '10');
    final mark = _operation(again, '1').attributes!;
    expect(mark['script'], 'super');
    expect(mark['link'], startsWith('#'));

    final withoutSource = utf8.decode(
      HtmlCodec(DocxCodec(_tables)).encode(loaded.delta),
    );
    expect(withoutSource, contains('As Smith showed<sup>1</sup>, the claim'));
    expect(withoutSource, isNot(contains('<section')));
  });

  test('an OpenDocument file keeps its notes and chapter bookmarks', () {
    final loaded = OdtCodec(DocxCodec(_tables)).decode(
      odtFile(
        automatic:
            '<style:style style:name="P1" style:family="paragraph" '
            'style:parent-style-name="Standard"><style:paragraph-properties '
            'fo:break-before="page"/></style:style>',
        body:
            '<text:p><text:a xlink:type="simple" xlink:href="#ch2">'
            'See chapter 2</text:a></text:p>'
            '<text:p>As Smith showed<text:note text:id="ftn1" '
            'text:note-class="footnote"><text:note-citation>1'
            '</text:note-citation><text:note-body><text:p>SMITH, J. '
            'The source.</text:p></text:note-body></text:note>, the claim '
            'holds.</text:p>'
            '<text:h text:style-name="P1" text:outline-level="1">'
            '<text:bookmark text:name="ch2"/>Chapter 2</text:h>',
      ),
    );
    final html = _save(loaded);

    expect(html, contains('<a href="#ch2">See chapter 2</a>'));
    expect(
      html,
      contains(
        '<div style="break-after:page;page-break-after:always"></div>\n'
        '<h1 id="ch2">',
      ),
    );
    expect(
      html,
      contains('As Smith showed<sup><a href="#fn-1" id="fnref-1">1</a></sup>'),
    );
    expect(html, contains('SMITH, J. The source.'));
  });

  test('a note marked many times is written once', () {
    final text = 'long note ' * 1000;
    final spec = DocumentSpec()
      ..body.add(
        ParagraphSpec([
          const TextSpec('Text'),
          NoteSpec(NoteKind.footnote, [
            ParagraphSpec([TextSpec(text)]),
          ]),
        ]),
      );
    final package = DocxBuilder(spec).build();
    const reference =
        '<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr>'
        '<w:footnoteReference w:id="1"/></w:r>';
    final document = package.text('word/document.xml')!;
    expect(document, contains(reference));
    package.setText(
      'word/document.xml',
      document.replaceFirst(reference, reference * 500),
    );
    final html = _save(DocxCodec(_tables).read(package));

    expect(text.allMatches(html), hasLength(1));
    expect(
      html,
      contains(
        'Text<sup><a href="#fn-1" id="fnref-1">1</a></sup>'
        '<sup><a href="#fn-1">1</a></sup><sup><a href="#fn-1">1</a></sup>',
      ),
    );
    expect(html.length, lessThan(text.length + 50000));
  });

  test('pages are well-formed XML, so .xhtml files stay XHTML', () {
    void expectXhtml(String page) {
      final root = XmlDocument.parse(page).rootElement;
      expect(root.name.local, 'html');
      expect(root.getAttribute('xmlns'), 'http://www.w3.org/1999/xhtml');
    }

    final chapter = _read('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head>
<meta charset="utf-8"/><title>Chapter</title></head>
<body><h1>Chapter&#160;one</h1><p>Line<br/>break &amp; more</p>
<p><img src="$_pngUri" alt="A dot" style="width: 30pt; height: 20pt"/></p>
<table border="1"><colgroup><col style="width: 100pt"/></colgroup>
<tbody><tr><td>cell</td></tr></tbody></table>
<ul><li>item</li></ul></body></html>''');
    final saved = _save(chapter);
    expectXhtml(saved);
    expect(_lines(_read(saved).delta), _lines(chapter.delta));

    final page = _write(
      Delta()
        ..insert('Fish & Chips\u00A0Co\u2028next', {'font': 'Fish & Chips'})
        ..insert('\n')
        ..insert('done')
        ..insert('\n', {'list': 'checked'})
        ..insert('to do')
        ..insert('\n', {'list': 'unchecked'})
        ..insert({EmbedTypes.pageBreak: 'page'})
        ..insert('\n'),
      look: const DocumentLook(
        body: TextLook(fontSize: 12, fontFamily: 'Fish & Chips'),
      ),
    );
    expectXhtml(page);
    expect(
      XmlDocument.parse(page).findAllElements('style').single.innerText,
      contains('body { font-family: "Fish & Chips";'),
    );
    expect(
      html_parser.parse(page).querySelector('style')!.text,
      contains('body { font-family: "Fish & Chips";'),
    );

    final notes = DocumentSpec()
      ..body.add(
        const ParagraphSpec([
          TextSpec('Text'),
          NoteSpec(NoteKind.footnote, [
            ParagraphSpec([TextSpec('Note')]),
          ]),
        ]),
      );
    expectXhtml(_save(_open(notes)));
  });

  test('font names can\'t add declarations of their own', () {
    const name = 'X&#34&#59background:url(https://e.example/t)&#59x:&#34';
    final page = _write(
      Delta()
        ..insert('Hello', {'font': name})
        ..insert('\n'),
    );
    final style = html_parser
        .parse(page)
        .querySelector('span')!
        .attributes['style']!;

    expect(
      parseDeclarations(style).map((declaration) => declaration.property),
      ['font-family'],
    );
    expect(parseDeclarations(style).single.value, '"$name"');
    expect(
      XmlDocument.parse(
        page,
      ).findAllElements('span').single.getAttribute('style'),
      style,
    );

    final opened = _read(
      '<p>Plain text, long enough to give the page its usual font.</p>'
      '<p><span style="font-family: \'X&amp;#34&amp;#59color:red&amp;#59'
      'x:&amp;#34\'">Hello</span></p>',
    );
    expect(
      _visible(_operation(_read(_save(opened)).delta, 'Hello').attributes),
      {'font': 'X&#34&#59color:red&#59x:&#34'},
    );

    // Markdown writes the tables it can't hold through the same code.
    final table = TableModel(
      id: _tables.nextId(),
      rows: [
        TableRowModel(
          cells: [
            TableCellModel(
              controller: _tables.newCellController(
                Delta()
                  ..insert('Hello', {'font': name})
                  ..insert('\n'),
              ),
              gridSpan: 2,
            ),
          ],
        ),
      ],
      columnWidths: [2000, 2000],
      bordered: true,
    );
    _tables.add(table);
    final markdown = utf8.decode(
      MarkdownCodec(DocxCodec(_tables)).encode(
        Delta()
          ..insert({EmbedTypes.table: encodeTableId(table.id)})
          ..insert('\n'),
      ),
    );
    expect(
      parseDeclarations(
        html_parser
            .parseFragment(markdown)
            .querySelector('span')!
            .attributes['style']!,
      ).map((declaration) => declaration.property),
      ['font-family'],
    );
  });

  test('cells keep their vertical alignment and rows their height', () {
    final opened = _read(
      '<table><tr style="height: 60pt"><td valign="middle">mid</td>'
      '<td style="vertical-align: bottom">bottom</td>'
      '<td>a<br>b<br>c<br>d</td></tr></table>',
    );
    final html = _save(opened);

    expect(html, contains('<tr style="height:60pt">'));
    expect(html, contains('<td style="vertical-align:middle"><p>mid</p></td>'));
    expect(
      html,
      contains('<td style="vertical-align:bottom"><p>bottom</p></td>'),
    );
    final row = _table(_read(html).delta).rows.single;
    expect(row.propertiesXml, contains('trHeight w:val="1200"'));
    expect(row.cells[0].propertiesXml, contains('<w:vAlign w:val="center"/>'));
    expect(row.cells[1].propertiesXml, contains('<w:vAlign w:val="bottom"/>'));

    final textutil = HtmlCodec(
      DocxCodec(_tables),
    ).decode(File('test/fixtures/html/textutil.html').readAsBytesSync());
    expect(
      _table(textutil.delta).rows.first.cells.first.propertiesXml,
      contains('<w:vAlign w:val="center"/>'),
    );
    expect(
      _table(_read(_save(textutil)).delta).rows.first.cells.first.propertiesXml,
      contains('<w:vAlign w:val="center"/>'),
    );
  });

  test('right-to-left paragraphs, headings and items keep their direction', () {
    final opened = _read(
      '<p dir="rtl">مرحبا بالعالم!</p><h2 dir="rtl">עולם</h2>'
      '<ul><li dir="rtl">שלום (בדיקה).</li></ul><p>left</p>',
    );
    final html = _save(opened);

    expect(html, contains('<p dir="rtl">مرحبا بالعالم!</p>'));
    expect(html, contains('<h2 dir="rtl">עולם</h2>'));
    expect(html, contains('<li dir="rtl">שלום (בדיקה).</li>'));
    expect(html, contains('<p>left</p>'));
    final again = _read(html).delta;
    for (final text in ['مرحبا', 'עולם', 'שלום']) {
      expect(
        _line(again, text).attributes[HiddenAttributes.paragraphProperties],
        contains('<w:bidi/>'),
        reason: text,
      );
    }
  });

  test('right-to-left numbered headings have their number beside them', () {
    final spec = DocumentSpec(language: 'ar-SA');
    final chapters = spec.addList(ListSpec.numbered());
    final items = spec.addList(ListSpec.numbered());
    ParagraphSpec rightToLeft(String text, int list, {int? heading}) =>
        ParagraphSpec(
          [TextSpec(text)],
          heading: heading,
          format: ParagraphFormat(list: ListRef(list), rightToLeft: true),
        );
    spec.body.addAll([
      rightToLeft('مقدمة البحث', chapters, heading: 1),
      rightToLeft('المنهجية', chapters, heading: 1),
      rightToLeft('البند الأول', items),
    ]);
    final html = _save(_open(spec));

    expect(
      html,
      contains(
        '<ol><li dir="rtl"><h1 dir="rtl">مقدمة البحث</h1></li>\n'
        '<li dir="rtl"><h1 dir="rtl">المنهجية</h1></li></ol>',
      ),
    );
    expect(html, contains('<li dir="rtl">البند الأول</li>'));
    final again = _read(html).delta;
    expect(_visible(_line(again, 'المنهجية').attributes), {
      'header': 1,
      'list': 'ordered',
    });
    expect(
      _line(again, 'المنهجية').attributes[HiddenAttributes.paragraphProperties],
      contains('<w:bidi/>'),
    );
  });

  test('sections that start a page break it', () {
    final odt = OdtCodec(DocxCodec(_tables)).decode(
      odtFile(
        automatic:
            '<style:style style:name="P1" style:family="paragraph" '
            'style:master-page-name="Standard"><style:paragraph-properties '
            'style:page-number="1"/></style:style>',
        body:
            '<text:p>Front matter</text:p>'
            '<text:p text:style-name="P1">Chapter one starts on page 1'
            '</text:p>',
      ),
    );
    expect(
      _save(odt),
      contains(
        '<p>Front matter</p>\n'
        '<div style="break-after:page;page-break-after:always"></div>\n'
        '<p>Chapter one starts on page 1</p>',
      ),
    );

    final spec = DocumentSpec()
      ..body.addAll(const [
        ParagraphSpec([TextSpec('Portrait')]),
        SectionBreakSpec(PageSpec()),
        ParagraphSpec([TextSpec('Two columns')]),
        SectionBreakSpec(PageSpec(), kind: SectionKind.continuous),
        ParagraphSpec([TextSpec('Same page')]),
      ]);
    final html = _save(_open(spec));
    expect(
      html,
      contains(
        '<p>Portrait</p>\n'
        '<div style="break-after:page;page-break-after:always"></div>\n'
        '<p>Two columns</p>\n<p>Same page</p>',
      ),
    );
    expect(_lines(_read(html).delta).map((line) => line.first), [
      'Portrait',
      '',
      'Two columns',
      'Same page',
    ]);
  });

  group('Word lists show their own numbers', () {
    DocumentSpec articles({String levelOne = '%1.%2.', int start = 1}) {
      final spec = DocumentSpec();
      final list = spec.addList(
        ListSpec([
          ListLevelSpec(
            format: NumberFormat.upperRoman,
            text: 'Article %1.',
            start: start,
          ),
          ListLevelSpec(format: NumberFormat.decimal, text: levelOne),
          const ListLevelSpec(format: NumberFormat.lowerLetter, text: '(%3)'),
          const ListLevelSpec(format: NumberFormat.decimalZero, text: '%4.'),
          for (var level = 4; level < 9; level++)
            ListLevelSpec(format: NumberFormat.decimal, text: '%${level + 1}.'),
        ]),
      );
      return spec
        ..body.addAll([
          ParagraphSpec(
            [const TextSpec('Scope')],
            heading: 1,
            format: ParagraphFormat(list: ListRef(list)),
          ),
          _item('Terms', list, 1),
          _item('Deep', list, 2),
          _item('Deeper', list, 2),
          _item('Zero', list, 3),
          _item('More terms', list, 1),
          ParagraphSpec(
            [const TextSpec('Method')],
            heading: 1,
            format: ParagraphFormat(list: ListRef(list)),
          ),
          _item('Sub', list, 1),
          const ParagraphSpec([TextSpec('Text.')]),
          _item('Back in the list', list, 2),
        ]);
    }

    test('levels that show other levels or more text', () {
      final loaded = _open(articles());
      final html = _save(loaded);

      expect(
        html,
        contains('li[data-marker]::marker { content: attr(data-marker) " "; }'),
      );
      expect(
        html,
        contains(
          '<ol type="I"><li data-marker="Article I."><h1>Scope</h1>'
          '<ol><li data-marker="I.1.">Terms<ol type="a">'
          '<li data-marker="(a)">Deep</li><li data-marker="(b)">Deeper'
          '<ol><li data-marker="01.">Zero</li></ol></li></ol></li>'
          '<li data-marker="I.2.">More terms</li></ol></li>\n'
          '<li data-marker="Article II."><h1>Method</h1>'
          '<ol><li data-marker="II.1.">Sub</li></ol></li></ol>',
        ),
      );
      expect(html, contains('<li data-marker="(a)">Back in the list</li>'));
      expect(() => XmlDocument.parse(html), returnsNormally);
      expect(_lines(_read(html).delta), _lines(loaded.delta));
    });

    test('legal numbering, letters past z and long texts', () {
      final package = DocxBuilder(articles(start: 27)).build();
      final numbering = package.text('word/numbering.xml')!;
      final legal = numbering.replaceFirst(
        '<w:lvl w:ilvl="1">',
        '<w:lvl w:ilvl="1"><w:isLgl/>',
      );
      expect(legal, isNot(numbering));
      package.setText('word/numbering.xml', legal);
      expect(
        _save(DocxCodec(_tables).read(package)),
        allOf(
          contains('<li data-marker="Article XXVII."><h1>Scope</h1>'),
          contains('<li data-marker="27.1.">Terms'),
        ),
      );

      final spec = DocumentSpec();
      final list = spec.addList(
        ListSpec([
          for (var level = 0; level < 9; level++)
            ListLevelSpec(
              format: NumberFormat.lowerLetter,
              text: '%${level + 1})',
              start: 26,
            ),
        ]),
      );
      spec.body.addAll([
        _item('z', list),
        _item('aa', list),
        _item('bb', list),
      ]);
      expect(
        _save(_open(spec)),
        contains(
          '<li data-marker="z)">z</li>\n<li data-marker="aa)">aa</li>\n'
          '<li data-marker="bb)">bb</li>',
        ),
      );

      final long = _save(_open(articles(levelOne: '${'x' * 70}%2')));
      expect(long, contains('<li>Terms'));
      expect(long, contains('<li data-marker="Article I.">'));

      final hostile = DocxBuilder(articles(levelOne: '%1' * 32)).build();
      final definitions = hostile.text('word/numbering.xml')!;
      hostile.setText(
        'word/numbering.xml',
        definitions.replaceFirst(
          '<w:start w:val="1"/>',
          '<w:start w:val="4611686018427387904"/>',
        ),
      );
      final huge = _save(DocxCodec(_tables).read(hostile));
      expect(huge, contains('<li data-marker="Article 4611686018427387904.">'));
      expect(huge, contains('<li>Terms'));
    });

    test('plain levels are left to the browser', () {
      final spec = DocumentSpec();
      final list = spec.addList(ListSpec.numbered());
      spec.body.addAll([_item('One', list), _item('One.a', list, 1)]);
      final html = _save(_open(spec));

      expect(html, contains('<ol><li>One<ol type="a"><li>One.a</li>'));
      expect(html, isNot(contains('marker')));
    });

    test('tables Markdown writes as HTML, without a style sheet, leave them '
        'out', () {
      final spec = DocumentSpec();
      final list = spec.addList(
        ListSpec([
          for (var level = 0; level < 9; level++)
            ListLevelSpec(format: NumberFormat.upperRoman, text: 'Part %1'),
        ]),
      );
      spec.body.add(
        TableSpec([
          RowSpec([
            CellSpec([_item('First', list), _item('Second', list)]),
          ]),
        ]),
      );
      final loaded = _open(spec);
      final markdown = utf8.decode(
        MarkdownCodec(
          DocxCodec(_tables),
        ).encode(loaded.delta, source: loaded.source),
      );

      expect(markdown, contains('<ol type="I"><li>First</li>'));
      expect(markdown, isNot(contains('marker')));
    });
  });

  test('bookmarks of a line that starts with a page break are kept', () {
    final spec = DocumentSpec()
      ..body.addAll(const [
        ParagraphSpec([
          LinkSpec('#ch2', [TextSpec('See chapter 2')]),
          TextSpec(' and '),
          LinkSpec('#_Toc12', [TextSpec('the method')]),
        ]),
        ParagraphSpec([
          BreakSpec(BreakKind.page),
          BookmarkSpec('ch2'),
          TextSpec('Chapter 2'),
        ], heading: 1),
        ParagraphSpec([
          BreakSpec(BreakKind.page),
          BookmarkSpec('_Toc12'),
          TextSpec('Method'),
        ], heading: 1),
        ParagraphSpec([BookmarkSpec('end'), BreakSpec(BreakKind.page)]),
      ]);
    final html = _save(_open(spec));

    expect(
      html,
      contains(
        '<div style="break-after:page;page-break-after:always"></div>\n'
        '<h1 id="ch2">Chapter 2</h1>',
      ),
    );
    expect(html, contains('<h1 id="_Toc12">Method</h1>'));
    expect(
      html,
      contains(
        '<div id="end" style="break-after:page;page-break-after:always"></div>',
      ),
    );
  });

  test('page breaks before, all caps and small caps are kept', () {
    final spec = DocumentSpec()
      ..body.addAll(const [
        ParagraphSpec([TextSpec('Before')]),
        ParagraphSpec([
          TextSpec('Chapter'),
        ], format: ParagraphFormat(pageBreakBefore: true)),
        ParagraphSpec([TextSpec('All caps', RunFormat(allCaps: true))]),
        ParagraphSpec([TextSpec('Small caps', RunFormat(smallCaps: true))]),
      ]);
    final html = _save(_open(spec));

    expect(
      html,
      contains('<p style="break-before:page;page-break-before:always">'),
    );
    expect(
      html,
      contains('<span style="text-transform:uppercase">All caps</span>'),
    );
    expect(
      html,
      contains('<span style="font-variant:small-caps">Small caps</span>'),
    );

    final page = _read(
      '<h2 style="text-transform: uppercase">Introdução</h2>'
      '<p><span style="font-variant: small-caps">Small caps text</span></p>',
    );
    final again = _read(_save(page)).delta;
    expect(
      _operation(
        again,
        'Introdução',
      ).attributes?[HiddenAttributes.runProperties],
      contains('<w:caps/>'),
    );
    expect(
      _operation(
        again,
        'Small caps text',
      ).attributes?[HiddenAttributes.runProperties],
      contains('<w:smallCaps/>'),
    );
  });

  test('pictures keep their alternative text', () {
    final spec = DocumentSpec()
      ..body.add(
        ParagraphSpec([
          ImageSpec(
            _png,
            'image/png',
            width: 30,
            height: 20,
            description: 'Sales by region, 2026',
          ),
        ]),
      );
    expect(_save(_open(spec)), contains('alt="Sales by region, 2026"'));

    final page = _read(
      '<p><img src="$_pngUri" alt="Tom &amp; &quot;Jerry&quot;" '
      'style="width: 30pt; height: 20pt"></p>',
    );
    expect(_save(page), contains('alt="Tom &amp; &quot;Jerry&quot;"'));
  });

  test('the page keeps the document\'s language and title', () {
    final page = _read(
      '<html lang="pt-BR"><head><title>Relatório</title></head>'
      '<body><h2>Introdução</h2><p>Texto.</p></body></html>',
    );
    final html = _save(page);

    expect(html, contains(' lang="pt-BR" xml:lang="pt-BR">'));
    expect(
      (_read(html).source! as DocxPackage).text('word/styles.xml'),
      contains('w:val="pt-BR"'),
    );

    final spec = DocumentSpec()
      ..body.addAll(const [
        ParagraphSpec([TextSpec('Introdução')], heading: 1),
      ]);
    final package = DocxBuilder(spec).build()
      ..setText(
        'docProps/core.xml',
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/'
            'package/2006/metadata/core-properties" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<dc:title>Relatório anual &amp; contas</dc:title>'
            '</cp:coreProperties>',
      )
      ..addRelationships('', const [
        Relationship(
          id: 'rId9',
          type:
              'http://schemas.openxmlformats.org/package/2006/relationships/'
              'metadata/core-properties',
          target: 'docProps/core.xml',
        ),
      ]);
    expect(
      _save(DocxCodec(_tables).read(package)),
      contains('<title>Relatório anual &amp; contas</title>'),
    );
  });

  test('a cell merged down from a header row stays in the header', () {
    final spec = DocumentSpec()
      ..body.add(
        const TableSpec([
          RowSpec([
            CellSpec([
              ParagraphSpec([TextSpec('Name')]),
            ], merge: CellMerge.restart),
            CellSpec([
              ParagraphSpec([TextSpec('Score')]),
            ], span: 2),
          ], header: true),
          RowSpec([
            CellSpec([], merge: CellMerge.continuation),
            CellSpec([
              ParagraphSpec([TextSpec('Math')]),
            ]),
            CellSpec([
              ParagraphSpec([TextSpec('Physics')]),
            ]),
          ]),
          RowSpec([
            CellSpec([
              ParagraphSpec([TextSpec('Ann')]),
            ]),
            CellSpec([
              ParagraphSpec([TextSpec('9')]),
            ]),
            CellSpec([
              ParagraphSpec([TextSpec('8')]),
            ]),
          ]),
        ]),
      );

    expect(
      _save(_open(spec)),
      contains(
        '<thead><tr><td rowspan="2"><p>Name</p></td><td colspan="2"><p>Score'
        '</p></td></tr><tr><td><p>Math</p></td><td><p>Physics</p></td></tr>'
        '</thead><tbody><tr><td><p>Ann</p></td>',
      ),
    );
  });
}
