import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/delta_blocks.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/html/markdown_codec.dart';

final _pngUri =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

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
    expect(lines.sublist(3, 10), [
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
        'Done',
        {'list': 'bullet'},
      ],
      [
        'Pending',
        {'list': 'bullet'},
      ],
      [
        'Three',
        {'list': 'ordered'},
      ],
      [
        'Four',
        {'list': 'ordered'},
      ],
    ]);
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
    expect(_plain(delta), isNot(contains('alert')));
    expect(
      delta.toList().where(
        (operation) =>
            operation.data is Map &&
            (operation.data as Map).containsKey(EmbedTypes.pageBreak),
      ),
      isEmpty,
    );
    expect(loaded.notices, isEmpty);
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
