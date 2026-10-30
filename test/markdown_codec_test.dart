import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_quill/flutter_quill.dart' show ChangeSource;
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/delta_blocks.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/html/markdown_codec.dart';
import 'package:xml/xml.dart';

final _pngUri =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// A PNG of [size] bytes, as a screenshot pasted into a note: one pixel,
/// then bytes that look as random as compressed pixels do.
String _screenshot(int size, int seed) {
  final png = base64Decode(_pngUri.substring(_pngUri.indexOf(',') + 1));
  final bytes = Uint8List(size)..setAll(0, png);
  var state = seed;
  for (var index = png.length; index < size; index++) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    bytes[index] = state >> 16;
  }
  return 'data:image/png;base64,${base64Encode(bytes)}';
}

LoadedDocument _read(String markdown, [TableStore? tables]) => MarkdownCodec(
  DocxCodec(tables ?? TableStore()),
).decode(Uint8List.fromList(utf8.encode(markdown)));

String _write(Delta delta, [TableStore? tables, Object? source]) => utf8.decode(
  MarkdownCodec(
    DocxCodec(tables ?? TableStore()),
  ).encode(delta, source: source),
);

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

int _pictures(Delta delta) => delta
    .toList()
    .where(
      (operation) =>
          operation.data is Map &&
          (operation.data as Map).containsKey(EmbedTypes.image),
    )
    .length;

/// The symbol and font of the list level of the line holding [text].
(String?, String?) _level(LoadedDocument loaded, String text) {
  final line = _line(loaded.delta, text);
  final numbering = XmlDocument.parse(
    (loaded.source! as DocxPackage).text('word/numbering.xml')!,
  );
  XmlElement find(String name, String attribute, Object? value) => numbering
      .findAllElements('w:$name')
      .firstWhere((element) => element.getAttribute(attribute) == '$value');
  final number = find(
    'num',
    'w:numId',
    line.attributes[HiddenAttributes.numbering],
  );
  final level =
      find(
            'abstractNum',
            'w:abstractNumId',
            number.getElement('w:abstractNumId')!.getAttribute('w:val'),
          )
          .findElements('w:lvl')
          .firstWhere(
            (element) => element.getAttribute('w:ilvl') == '${line.indent}',
          );
  return (
    level.getElement('w:lvlText')?.getAttribute('w:val'),
    level.findAllElements('w:rFonts').firstOrNull?.getAttribute('w:ascii'),
  );
}

TableModel _table(Delta delta, TableStore tables) =>
    tables[tableIdOf(
      documentBlocks(delta)
          .whereType<EmbedBlock>()
          .firstWhere((block) => block.type == EmbedTypes.table)
          .value,
    )]!;

List<List<String>> _cells(TableModel table) => [
  for (final row in table.rows)
    [
      for (final cell in row.cells)
        cell.controller.document.toPlainText().trim(),
    ],
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reads GitHub flavored Markdown', () {
    final tables = TableStore();
    final loaded = MarkdownCodec(
      DocxCodec(tables),
    ).decode(File('test/fixtures/markdown/sample.md').readAsBytesSync());
    final delta = loaded.delta;
    final lines = _lines(delta);

    expect(lines[0], [
      'Release notes',
      {'header': 1},
    ]);
    expect(_run(delta, 'Markdown'), {'bold': true});
    expect(_run(delta, 'with'), {'italic': true});
    expect(_run(delta, 'some'), {'strike': true});
    expect(_run(delta, 'inline code'), {'font': 'Courier New'});
    expect(_run(delta, 'links')['link'], 'https://example.com/notes?a=1&b=2');
    expect(lines[2], [
      'Lists',
      {'header': 2},
    ]);
    expect(
      [...lines.sublist(3, 6), ...lines.sublist(8, 10)],
      [
        [
          'First',
          {'list': 'bullet'},
        ],
        [
          'Second',
          {'list': 'bullet'},
        ],
        [
          'Nested',
          {'list': 'bullet', 'indent': 1},
        ],
        [
          'Three',
          {'list': 'ordered'},
        ],
        [
          'Four',
          {'list': 'ordered'},
        ],
      ],
    );
    expect(
      [for (final line in lines.sublist(6, 8)) line.first],
      ['Done', 'Pending'],
    );
    expect(_level(loaded, 'Done'), ('☑', 'Segoe UI Symbol'));
    expect(_level(loaded, 'Pending'), ('☐', 'Segoe UI Symbol'));
    expect(
      (loaded.source! as DocxPackage).text('word/numbering.xml'),
      contains('<w:start w:val="3"/>'),
    );
    expect(lines[10], [
      'Quoted text that continues.',
      {'indent': 1},
    ]);
    final table = _table(delta, tables);
    expect(table.bordered, isTrue);
    expect(_cells(table), [
      ['Feature', 'Status'],
      ['Tables', 'Yes'],
      ['Pipes', 'a | b'],
    ]);
    expect(table.rows.first.propertiesXml, contains('tblHeader'));
    expect(
      documentBlocks(
        table.rows[1].cells.last.controller.document.toDelta(),
      ).whereType<LineBlock>().first.align,
      'right',
    );
    expect(
      [
        for (final text in ['void main() {', "  print('hi');", '}'])
          (_line(delta, text).plainText, _run(delta, text)['font']),
      ],
      [
        ('void main() {', 'Courier New'),
        ("  print('hi');", 'Courier New'),
        ('}', 'Courier New'),
      ],
    );
    expect(_line(delta, 'Line one').plainText, 'Line one\u2028line two.');
    expect(_run(delta, '1'), {
      'underline': true,
      'color': '#0563C1',
      'script': 'super',
      'link': '#fn_1',
    });
    expect(
      _line(delta, 'The note').attributes[HiddenAttributes.bookmarks],
      '["fn_1"]',
    );
    expect(
      delta.toList().where(
        (operation) =>
            operation.data is Map &&
            (operation.data as Map).containsKey(EmbedTypes.image),
      ),
      hasLength(1),
    );
    expect(_run(delta, 'Inline HTML'), {'color': '#FF0000'});
    // GitHub shows a script as text; it never runs.
    expect(_plain(delta), contains('<script>alert(1)</script> stay safe.'));
    expect(
      delta.toList().where(
        (operation) =>
            operation.data is Map &&
            (operation.data as Map).containsKey(EmbedTypes.pageBreak),
      ),
      isEmpty,
    );
    // The thematic break.
    expect(loaded.notices, [DocumentNotice.contentNotImported]);
  });

  group('reading', () {
    test('raw tags GitHub shows as text keep the rest of the file', () {
      for (final tag in [
        'title',
        'textarea',
        'style',
        'script',
        'iframe',
        'noembed',
        'noframes',
        'xmp',
        'plaintext',
        'button',
        'select',
        'template',
        'noscript',
        'object',
        'applet',
        'option',
      ]) {
        final loaded = _read(
          'Use the <$tag> element here.\n\n## Next section\n\nImportant '
          'text.\n',
        );
        expect(_lines(loaded.delta), [
          ['Use the <$tag> element here.', <String, dynamic>{}],
          [
            'Next section',
            {'header': 2},
          ],
          ['Important text.', <String, dynamic>{}],
        ], reason: tag);
        expect(loaded.notices, isEmpty, reason: tag);
        expect(
          _write(loaded.delta, null, loaded.source),
          'Use the \\<$tag> element here.\n\n## Next section\n\nImportant '
          'text.\n',
          reason: tag,
        );
      }
    });

    test('task items are ☑ and ☐ list levels', () {
      for (final markdown in [
        '- [x] Write the parser\n- [ ] Write the tests\n\n1. [x] Ordered\n',
        // Items of a loose list hold their box in a paragraph.
        '- [x] Write the parser\n\n- [ ] Write the tests\n\n1. [x] Ordered\n',
        '<ul><li><input type="checkbox" checked> Write the parser</li>'
            '<li><input type="checkbox"> Write the tests</li></ul>\n\n'
            '1. [x] Ordered\n',
      ]) {
        final loaded = _read(markdown);
        expect(
          _plain(loaded.delta),
          'Write the parser\nWrite the tests\nOrdered\n',
          reason: markdown,
        );
        for (final (text, box) in [
          ('parser', '☑'),
          ('tests', '☐'),
          ('Ordered', '☑'),
        ]) {
          expect(_level(loaded, text), (
            box,
            'Segoe UI Symbol',
          ), reason: markdown);
        }
      }

      final checklist = _write(
        Delta()
          ..insert('done')
          ..insert('\n', {'list': 'checked'})
          ..insert('todo')
          ..insert('\n', {'list': 'unchecked'})
          ..insert('☑ typed')
          ..insert('\n', {'list': 'bullet'}),
      );
      expect(checklist, '- [x] done\n- [ ] todo\n- [x] typed\n');
      final again = _read(checklist);
      expect(_level(again, 'done'), ('☑', 'Segoe UI Symbol'));
      expect(_level(again, 'todo'), ('☐', 'Segoe UI Symbol'));
    });

    test('fences in list items leave what follows them out of the code', () {
      final install = _read(
        '- Install:\n  ```bash\n  pip install x\n    ```\n## Usage\n'
        'Run `x --help`.\n',
      );
      expect(_lines(install.delta), [
        [
          'Install:',
          {'list': 'bullet'},
        ],
        [
          'pip install x',
          {'indent': 1},
        ],
        [
          'Usage',
          {'header': 2},
        ],
        ['Run x --help.', <String, dynamic>{}],
      ]);
      expect(_run(install.delta, 'pip install x'), {'font': 'Courier New'});
      expect(_run(install.delta, 'x --help'), {'font': 'Courier New'});

      final steps = _read(
        '1. Install:\n\n   ```bash\n   pip install x\n    ```\n\n'
        '   Then **run** it:\n\n   ```bash\n   x --help\n   ```\n',
      );
      expect(_lines(steps.delta), [
        [
          'Install:',
          {'list': 'ordered'},
        ],
        [
          'pip install x',
          {'indent': 1},
        ],
        [
          'Then run it:',
          {'indent': 1},
        ],
        [
          'x --help',
          {'indent': 1},
        ],
      ]);
      expect(_run(steps.delta, 'run'), {'bold': true});
      expect(_run(steps.delta, 'x --help'), {'font': 'Courier New'});
    });

    test('pictures inside data URIs open in every form notes write', () {
      final shot = _screenshot(480000, 1);
      for (final markdown in [
        'Text\n\n![Screenshot]($shot)\n',
        'Text\n\n![Screenshot]($shot "Screenshot")\n',
        'Text\n\n![screen\\_shot]($shot)\n',
        'The screenshot:\n<img src="$shot" width="300">\n',
        'Text\n\n![Shot][s0]\n\n[s0]: $shot\n',
      ]) {
        final loaded = _read(markdown);
        expect(_pictures(loaded.delta), 1, reason: markdown.substring(0, 20));
        expect(loaded.notices, isEmpty, reason: markdown.substring(0, 20));
      }
      // More than the text Markdown may have, all of it in pictures.
      final shots = [for (var i = 0; i < 3; i++) _screenshot(1050000, i)];
      for (final markdown in [
        [for (final shot in shots) '![Shot]($shot "Shot")'].join('\n\n'),
        [for (final shot in shots) '![a\\_b]($shot)'].join('\n\n'),
        [
          for (final shot in shots) 'Shot:\n<img src="$shot" width="300">',
        ].join('\n\n'),
        '${[for (var i = 0; i < 3; i++) '![Shot][s$i]'].join('\n\n')}\n\n'
            '${[for (var i = 0; i < 3; i++) '[s$i]: ${shots[i]}'].join('\n')}\n',
      ]) {
        expect(markdown.length, greaterThan(4 * 1024 * 1024));
        expect(
          _pictures(_read(markdown).delta),
          3,
          reason: markdown.substring(0, 20),
        );
      }
    });

    test('links read back as they were written', () {
      const markdown =
          '[sheet](https://fonts.googleapis.com/css?family=Roboto|Open+Sans), '
          '[escaped](https://example.com/a%7Cb), [page](docs/ação.md) and '
          '[query](https://example.com/?a=1&copy)\n';
      final loaded = _read(markdown);
      expect(
        [
          for (final operation in loaded.delta.toList())
            if (operation.attributes?['link'] case final String link) link,
        ],
        [
          'https://fonts.googleapis.com/css?family=Roboto|Open+Sans',
          'https://example.com/a%7Cb',
          'docs/ação.md',
          'https://example.com/?a=1&copy',
        ],
      );
      expect(_write(loaded.delta, null, loaded.source), markdown);

      final references = _read(
        'See [the guide][guide], [Docs][] and [docs].\n\n'
        '[guide]: https://example.com/guide|1\n[docs]: docs/a.md\n',
      ).delta;
      expect(
        _run(references, 'the guide')['link'],
        'https://example.com/guide|1',
      );
      expect(_run(references, 'Docs')['link'], 'docs/a.md');
      expect(_run(references, 'docs')['link'], 'docs/a.md');
    });

    test('links to other files stay; links the editor drops are told', () {
      const kept =
          'Read the [guide](CONTRIBUTING.md) and the '
          '[docs](docs/guide.md#setup).\n';
      final relative = _read(kept);
      expect(relative.notices, isEmpty);
      expect(_write(relative.delta, null, relative.source), kept);

      final dropped = _read('See [root](/docs/x.md) and [here](//e.com/x).\n');
      expect(_plain(dropped.delta), 'See root and here.\n');
      expect(dropped.notices, [DocumentNotice.contentNotImported]);
    });

    test('front matter is kept as it was', () {
      for (final front in [
        '---\nlayout: post\ntitle: "Hello world"\ntags: [news, release]\n---',
        '---\naliases:\n  - Note A\ntags:\n  - project\n...',
        '+++\ntitle = "Hello"\n\ndraft = false\n+++',
      ]) {
        final markdown = '$front\n\nPart one.\n';
        final loaded = _read(markdown);
        expect(
          [for (final line in _lines(loaded.delta)) line.first],
          [...front.split('\n'), 'Part one.'],
          reason: front,
        );
        expect(_run(loaded.delta, front.split('\n')[1]), {
          'font': 'Courier New',
        });
        expect(loaded.notices, isEmpty, reason: front);
        expect(_write(loaded.delta, null, loaded.source), markdown);
      }
      // A rule at the top is no front matter.
      final rule = _read('---\n\nText\n\n---\n\nMore\n');
      expect(_plain(rule.delta), 'Text\nMore\n');
    });

    test('thematic breaks the editor cannot hold are told', () {
      final loaded = _read('Part one.\n\n***\n\nPart two.\n\n___\n');
      expect(_plain(loaded.delta), 'Part one.\nPart two.\n');
      expect(loaded.notices, [DocumentNotice.contentNotImported]);
    });

    test('versions after an @ are not e-mail addresses', () {
      final loaded = _read(
        'Upgrade to react@18.3 and lodash@4.17.21 first; mail '
        'team@example.com.\n',
      );
      expect(_run(loaded.delta, 'react@18.3')['link'], isNull);
      expect(
        _run(loaded.delta, 'team@example.com')['link'],
        'mailto:team@example.com',
      );
      expect(
        _write(loaded.delta, null, loaded.source),
        isNot(contains('mailto:react')),
      );
    });

    test('fenced code comes back exactly, inside lists too', () {
      const markdown =
          'Text\n\n```html\n<b>x</b> & **y** <script>\n  [a]: b\n```\n\n'
          '- item\n\n  ```\n  a < b\n  ```\n';
      final loaded = _read(markdown);
      expect(_lines(loaded.delta), [
        ['Text', <String, dynamic>{}],
        ['<b>x</b> & **y** <script>', <String, dynamic>{}],
        ['  [a]: b', <String, dynamic>{}],
        [
          'item',
          {'list': 'bullet'},
        ],
        [
          'a < b',
          {'indent': 1},
        ],
      ]);
      expect(_run(loaded.delta, '[a]: b'), {'font': 'Courier New'});
      // A fence package:markdown reads as part of an HTML block stays HTML.
      expect(
        _plain(_read('<div>\n```\n**x**\n```\n</div>\n').delta),
        '``` **x** ```\n',
      );
    });
  });

  group('writing', () {
    test('blocks, lists and inline formatting', () {
      final tables = TableStore();
      final table = tables.createEmpty(rows: 2, columns: 2, totalWidth: 4000);
      table.rows.first.cells.first.controller.document.insert(0, 'a|b');
      table.rows.last.cells.last.controller.document.insert(0, 'c');
      final markdown = _write(
        Delta()
          ..insert('Title')
          ..insert('\n', {'header': 1})
          ..insert('Plain ')
          ..insert('bold', {'bold': true})
          ..insert(' ')
          ..insert('both', {'bold': true, 'italic': true})
          ..insert(' ')
          ..insert('gone', {'strike': true})
          ..insert(' ')
          ..insert('under', {'underline': true, 'color': '#FF0000'})
          ..insert(' ')
          ..insert('code', {'font': 'Courier New'})
          ..insert(' x')
          ..insert('2', {'script': 'super'})
          ..insert(' ')
          ..insert('link (1)', {'link': 'https://e.com/a_(b)?q=1 2'})
          ..insert(' ')
          ..insert('bad', {'link': 'javascript:alert(1)'})
          ..insert('\u2028second line')
          ..insert('\n')
          ..insert('one')
          ..insert('\n', {'list': 'ordered'})
          ..insert('inner')
          ..insert('\n', {'list': 'bullet', 'indent': 1})
          ..insert('two')
          ..insert('\n', {'list': 'ordered'})
          ..insert('done')
          ..insert('\n', {'list': 'checked'})
          ..insert('quoted')
          ..insert('\n', {'indent': 2})
          ..insert({EmbedTypes.table: encodeTableId(table.id)})
          ..insert('\n')
          ..insert('let x = 1;', {'font': 'Consolas'})
          ..insert('\n')
          ..insert('\n')
          ..insert('x++;', {'font': 'Consolas'})
          ..insert('\n')
          ..insert({EmbedTypes.image: _pngUri}, {'width': '1', 'height': '1'})
          ..insert({EmbedTypes.pageBreak: 'page'})
          ..insert('\n')
          ..insert('end')
          ..insert('\n'),
        tables,
      );

      expect(
        markdown,
        '# Title\n'
        '\n'
        'Plain **bold** ***both*** ~~gone~~ under `code` x<sup>2</sup> '
        r'[link (1)](https://e.com/a_\(b\)?q=1%202) bad\'
        '\nsecond line\n'
        '\n'
        '1. one\n'
        '   - inner\n'
        '2. two\n'
        '\n'
        '- [x] done\n'
        '\n'
        '> > quoted\n'
        '\n'
        '| a\\|b |  |\n'
        '| --- | --- |\n'
        '|  | c |\n'
        '\n'
        '```\n'
        'let x = 1;\n'
        '\n'
        'x++;\n'
        '```\n'
        '\n'
        '![]($_pngUri)\n'
        '\n'
        '---\n'
        '\n'
        'end\n',
      );
    });

    test('text keeps its characters through Markdown', () {
      const texts = [
        r'1. not a list',
        r'- not a bullet',
        r'# not a heading',
        r'> not a quote',
        r'+ plus',
        r'= equals',
        r'2) paren',
        r'*stars* and _underscores_ and `ticks` and ~tilde~',
        r'[brackets](not a link) and <b>not bold</b> and \backslash\',
        r'&amp; &#169; &copy and a | pipe',
        r'https://example.com/plain',
        'trailing hash #',
      ];
      for (final text in texts) {
        final delta = Delta()
          ..insert(text)
          ..insert('\n');
        final markdown = _write(delta);
        expect(_plain(_read(markdown).delta), '$text\n', reason: markdown);
      }
      final heading = _read(
        _write(
          Delta()
            ..insert('C# ##')
            ..insert('\n', {'header': 2}),
        ),
      ).delta;
      expect(_lines(heading), [
        [
          'C# ##',
          {'header': 2},
        ],
      ]);
    });

    test('formatting that delimiters cannot hold falls back to HTML', () {
      final delta = Delta()
        ..insert('a')
        ..insert('(b)', {'bold': true})
        ..insert('c ')
        ..insert('x', {'bold': true})
        ..insert('y', {'italic': true})
        ..insert(' ')
        ..insert('one', {'strike': true, 'bold': true})
        ..insert('two', {'bold': true})
        ..insert('\n');
      final markdown = _write(delta);
      final again = _read(markdown).delta;

      expect(markdown, contains('<strong>'));
      expect(_plain(again), 'a(b)c xy onetwo\n');
      expect(_run(again, '(b)'), {'bold': true});
      expect(_run(again, 'x'), {'bold': true});
      expect(_run(again, 'y'), {'italic': true});
      expect(_run(again, 'one'), {'bold': true, 'strike': true});
      expect(_run(again, 'two'), {'bold': true});
    });

    test('an empty item under a list item keeps the text above it', () {
      final bullets = _write(
        Delta()
          ..insert('Shopping')
          ..insert('\n', {'list': 'bullet'})
          ..insert('\n', {'list': 'bullet', 'indent': 1})
          ..insert('Work')
          ..insert('\n', {'list': 'bullet'}),
      );
      expect(bullets, '- Shopping\n\n  -\n- Work\n');
      expect(_lines(_read(bullets).delta), [
        [
          'Shopping',
          {'list': 'bullet'},
        ],
        [
          '',
          {'list': 'bullet', 'indent': 1},
        ],
        [
          'Work',
          {'list': 'bullet'},
        ],
      ]);
      final numbers = _write(
        Delta()
          ..insert('a')
          ..insert('\n', {'list': 'ordered'})
          ..insert('\n', {'list': 'ordered', 'indent': 1})
          ..insert('b')
          ..insert('\n', {'list': 'ordered'}),
      );
      expect(numbers, '1. a\n\n   1.\n2. b\n');
      expect(_plain(_read(numbers).delta), 'a\n\nb\n');
    });

    test('a numbered list under a bullet that does not start at 1', () {
      final markdown = _write(
        Delta()
          ..insert('Topic A')
          ..insert('\n', {'list': 'bullet'})
          ..insert('point')
          ..insert('\n', {'list': 'ordered', 'indent': 1})
          ..insert('Topic B')
          ..insert('\n', {'list': 'bullet'})
          ..insert('point')
          ..insert('\n', {'list': 'ordered', 'indent': 1}),
      );
      // Without the empty line, Markdown reads `2. point` as text of Topic B.
      expect(markdown, '- Topic A\n  1. point\n- Topic B\n\n  2. point\n');
      expect(_lines(_read(markdown).delta), [
        [
          'Topic A',
          {'list': 'bullet'},
        ],
        [
          'point',
          {'list': 'ordered', 'indent': 1},
        ],
        [
          'Topic B',
          {'list': 'bullet'},
        ],
        [
          'point',
          {'list': 'ordered', 'indent': 1},
        ],
      ]);
    });

    test('paragraphs and code inside list items stay inside them', () {
      final readme = _read(
        '1. Install the tool.\n\n   It needs Python 3.\n\n   ```sh\n'
        '   pip install tool\n   ```\n\n2. Run it.\n',
      );
      const saved =
          '1. Install the tool.\n\n   It needs Python 3.\n\n   ```\n'
          '   pip install tool\n   ```\n\n2. Run it.\n';
      expect(_write(readme.delta, null, readme.source), saved);
      expect(_lines(_read(saved).delta), _lines(readme.delta));

      // A quote right after a list stays a quote.
      const quoted = '- One\n- Two\n\n> A note.\n';
      final quote = _read(quoted);
      expect(_write(quote.delta, null, quote.source), quoted);

      // So does an indented paragraph that follows no list.
      expect(
        _write(
          Delta()
            ..insert('Text')
            ..insert('\n')
            ..insert('Aside')
            ..insert('\n', {'indent': 1}),
        ),
        'Text\n\n> Aside\n',
      );
    });

    test('a line break at the end of a block is left out', () {
      final markdown = _write(
        Delta()
          ..insert('Signed,\u2028')
          ..insert('\n')
          ..insert('item\u2028 ')
          ..insert('\n', {'list': 'bullet'})
          ..insert('\u2028')
          ..insert('\n')
          ..insert('quote\u2028')
          ..insert('\n', {'indent': 1})
          ..insert('Line one\u2028line two')
          ..insert('\n'),
      );
      expect(
        markdown,
        'Signed,\n\n- item\n\n> quote\n\nLine one\\\nline two\n',
      );
      expect(
        _plain(_read(markdown).delta),
        'Signed,\nitem\nquote\nLine one\u2028line two\n',
      );
    });

    test('addresses in plain text stay plain text', () {
      const text =
          'See https://en.wikipedia.org/wiki/Hello_World, '
          'https://example.edu/~john/, www.example.com/a*b and '
          'john_doe@example.com.';
      final markdown = _write(
        Delta()
          ..insert(text)
          ..insert('\n'),
      );
      final again = _read(markdown).delta;
      expect(_plain(again), '$text\n');
      expect(
        again.toList().where(
          (operation) => operation.attributes?['link'] != null,
        ),
        isEmpty,
      );

      final linked = _read(
        _write(
          Delta()
            ..insert('https://example.com/a_b', {
              'link': 'https://example.com/a_b',
            })
            ..insert('\n'),
        ),
      ).delta;
      expect(_plain(linked), 'https://example.com/a_b\n');
      expect(_run(linked, 'https')['link'], 'https://example.com/a_b');
    });

    test('neighboring monospace text makes one code span', () {
      expect(
        _write(
          Delta()
            ..insert('Call ')
            ..insert('print', {'font': 'Courier New', 'color': '#0000FF'})
            ..insert('(x)', {'font': 'Courier New'})
            ..insert(' now.\n'),
        ),
        'Call `print(x)` now.\n',
      );
      final markdown = _write(
        Delta()
          ..insert('Run ')
          ..insert('npm', {'font': 'Consolas', 'bold': true})
          ..insert(' install', {'font': 'Courier New', 'bold': true})
          ..insert(' first.\n'),
      );
      expect(markdown, 'Run **`npm install`** first.\n');
      expect(_run(_read(markdown).delta, 'npm install'), {
        'font': 'Courier New',
        'bold': true,
      });
    });

    test('strikethrough opens inside bold and italic', () {
      final markdown = _write(
        Delta()
          ..insert('Price: ')
          ..insert(r'$10', {'bold': true, 'strike': true})
          ..insert(' now ')
          ..insert(r'$8', {'bold': true})
          ..insert(' or ')
          ..insert('(a)', {'italic': true, 'strike': true})
          ..insert(' and ')
          ..insert('b', {'italic': true})
          ..insert('\n'),
      );
      expect(
        markdown,
        r'Price: **~~$10~~** now **$8** or *~~(a)~~* and *b*'
        '\n',
      );
      final again = _read(markdown).delta;
      expect(_run(again, r'$10'), {'bold': true, 'strike': true});
      expect(_run(again, r'$8'), {'bold': true});
      expect(_run(again, '(a)'), {'italic': true, 'strike': true});
      expect(_run(again, 'b'), {'italic': true});
    });

    test('formatting next to symbols falls back to HTML', () {
      final markdown = _write(
        Delta()
          ..insert('Price:', {'bold': true})
          ..insert('€10 and ')
          ..insert('Done!', {'italic': true})
          ..insert('✓')
          ..insert('\n'),
      );
      expect(markdown, '<strong>Price:</strong>€10 and <em>Done!</em>✓\n');
      final again = _read(markdown).delta;
      expect(_run(again, 'Price:'), {'bold': true});
      expect(_run(again, 'Done!'), {'italic': true});

      // CommonMark 0.31 counts symbols as punctuation and GitHub doesn't:
      // only delimiters both read as formatting are written.
      final symbols = _write(
        Delta()
          ..insert('€', {'italic': true})
          ..insert('charlie. Cost ')
          ..insert('10 €', {'bold': true})
          ..insert('x\n'),
      );
      expect(symbols, '<em>€</em>charlie. Cost <strong>10 €</strong>x\n');
      final read = _read(symbols).delta;
      expect(_run(read, '€'), {'italic': true});
      expect(_run(read, '10 €'), {'bold': true});
    });

    test('only lines that look like metadata are written as front matter', () {
      Delta monospace(List<String> lines) {
        final delta = Delta();
        for (final line in lines) {
          delta
            ..insert(line, {'font': 'Courier New'})
            ..insert('\n');
        }
        return delta..insert('Text\n');
      }

      // A <pre> at the top of a page or a Courier paragraph can hold these.
      for (final lines in [
        ['---', '<img src=x onerror=alert(1)>', '---'],
        ['---', 'title: <img src=x onerror=alert(1)>', '---'],
        ['+++', 'Just some text', '+++'],
      ]) {
        expect(
          _write(monospace(lines)),
          '```\n${lines.join('\n')}\n```\n\nText\n',
          reason: lines[1],
        );
      }
      const front = [
        '---',
        'title: "Hello, world"',
        'tags:',
        '  - news',
        'description: >',
        '  A longer text.',
        '# draft: true',
        '...',
      ];
      expect(_write(monospace(front)), '${front.join('\n')}\n\nText\n');
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
      ParagraphSpec item(String text, [int level = 0]) => ParagraphSpec([
        TextSpec(text),
      ], format: ParagraphFormat(list: ListRef(list, level)));
      spec.body.addAll([
        item('Bullet A'),
        item('A1', 1),
        item('A2', 1),
        item('Bullet B'),
        item('B1', 1),
      ]);
      final tables = TableStore();
      final loaded = DocxCodec(tables).read(DocxBuilder(spec).build());

      expect(
        _write(loaded.delta, tables, loaded.source),
        '- Bullet A\n  1. A1\n  2. A2\n- Bullet B\n  1. B1\n',
      );
    });

    test('a link with a pipe stays in its table cell and reads back', () {
      final tables = TableStore();
      final table = tables.createEmpty(rows: 2, columns: 2, totalWidth: 4000);
      table.rows.first.cells.first.controller.document.insert(0, 'Font');
      table.rows.last.cells.first.controller.document.insert(0, 'Roboto');
      table.rows.last.cells.last.controller.document.compose(
        Delta()..insert('sheet', {
          'link': 'https://fonts.googleapis.com/css?family=Roboto|Open+Sans',
        }),
        ChangeSource.local,
      );
      final markdown = _write(
        Delta()
          ..insert({EmbedTypes.table: encodeTableId(table.id)})
          ..insert('\n'),
        tables,
      );
      expect(
        markdown,
        contains(
          r'[sheet](https://fonts.googleapis.com/css?family=Roboto\|Open+Sans)',
        ),
      );
      final again = TableStore();
      final read = _table(_read(markdown, again).delta, again);
      expect(_cells(read).last, ['Roboto', 'sheet']);
      expect(
        _run(
          read.rows.last.cells.last.controller.document.toDelta(),
          'sheet',
        )['link'],
        'https://fonts.googleapis.com/css?family=Roboto|Open+Sans',
      );
    });

    test('saving code around many empty lines takes linear time', () {
      final watch = Stopwatch()..start();
      final markdown = _write(
        Delta()
          ..insert('code one', {'font': 'Courier New'})
          ..insert('\n' * 40001)
          ..insert('code two', {'font': 'Courier New'})
          ..insert('\n'),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(markdown, '```\ncode one${'\n' * 40001}code two\n```\n');
    });

    test('tables Markdown cannot hold are written as HTML', () {
      final tables = TableStore();
      final table = tables.createEmpty(rows: 2, columns: 2, totalWidth: 4000);
      table.rows.first.cells.first
        ..gridSpan = 2
        ..controller.document.insert(0, 'wide');
      table.rows.first.cells.removeLast();
      final markdown = _write(
        Delta()
          ..insert({EmbedTypes.table: encodeTableId(table.id)})
          ..insert('\n'),
        tables,
      );
      expect(markdown, startsWith('<table border="1"'));
      expect(markdown, contains('<td colspan="2"'));
      expect(markdown.trim(), isNot(contains('\n\n')));
      final again = TableStore();
      expect(
        _table(
          _read(markdown, again).delta,
          again,
        ).rows.first.cells.first.gridSpan,
        2,
      );
    });
  });

  test('round trips keep text, formatting, lists, tables and pictures', () {
    final tables = TableStore();
    final original = MarkdownCodec(
      DocxCodec(tables),
    ).decode(File('test/fixtures/markdown/sample.md').readAsBytesSync());
    final markdown = _write(original.delta, tables, original.source);
    final again = _read(markdown, tables);

    expect(_lines(again.delta), _lines(original.delta));
    for (final text in [
      'Markdown',
      'with',
      'some',
      'inline code',
      'links',
      '1',
    ]) {
      expect(_run(again.delta, text), _run(original.delta, text), reason: text);
    }
    expect(
      _cells(_table(again.delta, tables)),
      _cells(_table(original.delta, tables)),
    );
    expect(
      (again.source! as DocxPackage).text('word/numbering.xml'),
      contains('<w:start w:val="3"/>'),
    );
    expect(markdown, contains('![](data:image/png;base64,'));
    expect(_write(again.delta, tables, again.source), markdown);
  });

  group('hostile files', () {
    Matcher fails() => throwsA(isA<FormatException>());

    test('deep nesting is rejected before parsing', () {
      for (final markdown in [
        '${'> ' * 20000}x',
        '${'- ' * 20000}x',
        '${'1. ' * 20000}x',
        [for (var i = 0; i < 2000; i++) '${'  ' * i}- x'].join('\n'),
        '${'<div>' * 1000}x',
        '${'*a ' * 2000}b${' c*' * 2000}',
        // A fence package:markdown reads as HTML hides nothing from the
        // checks.
        '<div>\n```\n</div>\n\n${'> ' * 20000}x',
        '<div>\n```\n</div>\n\n${List.filled(20000, '[r]: /x').join('\n')}',
      ]) {
        final watch = Stopwatch()..start();
        expect(() => _read(markdown), fails());
        expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
      }
    });

    test('shapes that take package:markdown quadratic time are refused', () {
      for (final markdown in [
        '*a* ' * 40000,
        'a* ' * 40000,
        List.generate(20000, (i) => 'line $i  ').join('\n'),
        List.generate(20000, (i) => '[r$i]: http://x/$i').join('\n'),
        '${List.generate(20000, (i) => 'x[^$i]').join(' ')}\n\n'
            '${List.generate(20000, (i) => '[^$i]: n').join('\n')}',
      ]) {
        final watch = Stopwatch()..start();
        expect(() => _read(markdown), fails());
        expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
      }
    });

    Matcher tooLarge() => throwsA(
      isA<DocumentProblemException>().having(
        (error) => error.problem,
        'problem',
        DocumentProblem.tooLarge,
      ),
    );

    test('a small file with a huge table is refused before parsing', () {
      final watch = Stopwatch()..start();
      expect(
        () => _read(
          '|${'a|' * 3000}\n|${'-|' * 3000}\n'
          '${List.filled(3000, 'x').join('\n')}',
        ),
        tooLarge(),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a line that only starts like a table delimiter is refused', () {
      final watch = Stopwatch()..start();
      expect(() => _read('a\n${'|  -  ' * 30}x'), fails());
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      final tables = TableStore();
      final wide = _read(
        '|${' a |' * 30}\n|${'  -  |' * 30}\n|${' b |' * 30}\n',
        tables,
      );
      expect(_cells(_table(wide.delta, tables)).last, List.filled(30, 'b'));
    });

    test('long runs without spaces are refused before parsing', () {
      for (final markdown in [
        'a' * 100000,
        'The hash is ${'0123456789abcdef' * 4000}',
        'x${'www.a.co/x' * 20000}',
        'a${' ' * 200000}b',
      ]) {
        final watch = Stopwatch()..start();
        expect(() => _read(markdown), fails());
        expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
      }
      // Only pictures count apart from the text.
      expect(() => _read('data:a;base64,${'A' * 50} ' * 100000), tooLarge());
    });

    test('brackets and tags that never close are refused in time', () {
      for (final markdown in [
        'x ${('<?${'/' * 300}') * 12000}',
        'x ${('<!A${'/' * 600}') * 6000}',
        'x ${('[a](${'/' * 900}') * 1000}',
        ('<ab:${'/' * 300}') * 3000,
        [for (var i = 1; i <= 150; i++) '`' * i].join('/' * 10000),
      ]) {
        final watch = Stopwatch()..start();
        expect(() => _read(markdown), fails());
        expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
      }
    });

    test('long and nested link labels open at once', () {
      for (final markdown in [
        'Intro\n\n[${'Ä' * 100000}]\n',
        'Intro\n\n[${'A,' * 100000}]\n',
        '${'[' * 2000}${'a ' * 100000}${']' * 2000}',
        'Intro\n\n[${'Ä' * 100000}](x y\n',
        'Intro\n\n[a][${'Ä' * 100000}]\n\n[a]: https://example.com\n',
      ]) {
        final watch = Stopwatch()..start();
        final loaded = _read(markdown);
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        expect(_plain(loaded.delta).length, greaterThan(100000));
      }
    });

    test('lookups that would take long are refused in time', () {
      for (final markdown in [
        // Every bracket is compared with every footnote.
        '${List.generate(20000, (i) => 'x [a$i] y').join('\n\n')}\n\n'
            '${List.generate(20000, (i) => '[^n$i]: note').join('\n\n')}\n',
        // Every label is copied once per capital letter.
        '[${'Ä' * 999}]\n\n' * 4000,
        // The alt text of a picture is read as any other text.
        '![${'a' * 100000}]($_pngUri)\n',
      ]) {
        final watch = Stopwatch()..start();
        expect(() => _read(markdown), fails());
        expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
      }
    });

    test('paragraphs with many links and tags open', () {
      for (final markdown in [
        [
          for (var i = 0; i < 1000; i++)
            '[Article $i: how to write a good title for a post]'
                '(https://blog.example.com/2024/01/how-to-write-article-$i)',
        ].join('\n'),
        [
          for (var i = 0; i < 500; i++)
            '<a href="https://github.com/contributor$i"><img '
                'src="https://avatars.githubusercontent.com/u/$i?v=4" '
                'alt="Contributor $i" width="50" /></a>',
        ].join('\n'),
        [
          for (var i = 0; i < 2000; i++)
            'Line $i of the long poem goes on and on<br>',
        ].join('\n'),
      ]) {
        expect(
          () => _read(markdown),
          returnsNormally,
          reason: markdown.substring(0, 30),
        );
      }
    });

    test('long changelogs with their link definitions open', () {
      final changelog = StringBuffer('# Changelog\n');
      for (var i = 1000; i > 0; i--) {
        changelog.write(
          '\n## [1.0.$i] - 2024-01-01\n\n### Fixed\n\n- Bug $i\n',
        );
      }
      changelog.write('\n');
      for (var i = 1000; i > 0; i--) {
        changelog.write(
          '[1.0.$i]: https://github.com/owner/project/compare/'
          'v1.0.${i - 1}...v1.0.$i\n',
        );
      }
      final loaded = _read(changelog.toString());
      expect(
        _run(loaded.delta, '1.0.1000')['link'],
        'https://github.com/owner/project/compare/v1.0.999...v1.0.1000',
      );
    });

    test('code and rules that only look nested or like definitions open', () {
      final log = [
        for (var i = 0; i < 3000; i++)
          '[12:00:${(i % 60).toString().padLeft(2, '0')} INFO]: Worker $i done',
      ].join('\n');
      final report = _read('# Crash report\n\nServer log:\n\n```\n$log\n```\n');
      expect(_lines(report.delta), hasLength(3002));
      for (final markdown in [
        'Intro\n\n${'* ' * 101}\n\nOutro',
        '```\n${'- ' * 101}\n```',
        '```\n${'>' * 101}\n```',
        '```\n${' ' * 210}- x\n```',
      ]) {
        expect(() => _read(markdown), returnsNormally, reason: markdown);
      }
    });

    test('large documents that are not hostile still open', () {
      final watch = Stopwatch()..start();
      final loaded = _read(
        [
          for (var i = 0; i < 1000; i++)
            '## Part $i\n\nSome **bold** and *italic* text with a '
                '[link](https://example.com/$i) and `code`.\n\n- item\n- item',
        ].join('\n\n'),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 60)));
      expect(_lines(loaded.delta), hasLength(4000));
      final picture = _read('![a](data:image/png;base64,${'A' * (6 << 20)})');
      expect(picture.notices, contains(DocumentNotice.contentNotImported));
    });

    test('too much text and binary garbage', () {
      expect(
        () => _read('x' * (4 * 1024 * 1024 + 1)),
        throwsA(
          isA<DocumentProblemException>().having(
            (error) => error.problem,
            'problem',
            DocumentProblem.tooLarge,
          ),
        ),
      );
      final garbage = Uint8List.fromList(
        List.generate(50000, (index) => (index * 7919 + 13) % 256),
      );
      expect(
        () => MarkdownCodec(DocxCodec(TableStore())).decode(garbage),
        anyOf(returnsNormally, throwsA(isA<FormatException>())),
      );
    });
  });
}
