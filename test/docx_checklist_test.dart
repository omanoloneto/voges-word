import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/delta_blocks.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/headers_footers.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/html/html_codec.dart';
import 'package:voges_word/html/markdown_codec.dart';
import 'package:xml/xml.dart';

late DocxCodec _docx;

Map<String, dynamic> _visible(Map<String, dynamic> attributes) => {
  for (final MapEntry(:key, :value) in attributes.entries)
    if (!key.startsWith('vw-')) key: value,
};

/// Paragraphs as their text and visible line attributes.
List<List<Object>> _lines(Delta delta) => [
  for (final block in documentBlocks(delta))
    if (block is LineBlock) [block.plainText, _visible(block.attributes)],
];

LineBlock _line(Delta delta, String text) => documentBlocks(
  delta,
).whereType<LineBlock>().firstWhere((line) => line.plainText == text);

int? _numId(Delta delta, String text) =>
    (_line(delta, text).attributes[HiddenAttributes.numbering] as num?)
        ?.toInt();

typedef _Level = ({String? text, String? font, String? left, String? hanging});

/// The levels of each list definition of a saved package, by its first
/// level's text.
Map<String, List<_Level>> _definitions(Uint8List bytes) {
  final numbering = XmlDocument.parse(
    DocxPackage.decode(bytes).text('word/numbering.xml')!,
  );
  return {
    for (final abstract in numbering.findAllElements('w:abstractNum'))
      abstract
          .findElements('w:lvl')
          .first
          .getElement('w:lvlText')!
          .getAttribute('w:val')!: [
        for (final level in abstract.findElements('w:lvl'))
          (
            text: level.getElement('w:lvlText')?.getAttribute('w:val'),
            font: level
                .getElement('w:rPr')
                ?.getElement('w:rFonts')
                ?.getAttribute('w:ascii'),
            left: level
                .getElement('w:pPr')
                ?.getElement('w:ind')
                ?.getAttribute('w:left'),
            hanging: level
                .getElement('w:pPr')
                ?.getElement('w:ind')
                ?.getAttribute('w:hanging'),
          ),
      ],
  };
}

Delta _reflag(Delta delta, String text, String list) {
  final out = Delta();
  final operations = delta.toList();
  for (var index = 0; index < operations.length; index++) {
    final operation = operations[index];
    final previous = index > 0 ? operations[index - 1].data : null;
    if (operation.data == '\n' && previous == text) {
      out.insert('\n', {...?operation.attributes, 'list': list});
    } else {
      out.push(operation);
    }
  }
  return out;
}

void main() {
  setUp(() => _docx = DocxCodec(TableStore()));

  test('an editor checklist keeps its boxes through .docx', () {
    final delta = Delta()
      ..insert('Groceries\n')
      ..insert('Buy milk')
      ..insert('\n', {'list': 'checked'})
      ..insert('Call mom')
      ..insert('\n', {'list': 'unchecked'})
      ..insert('Bread')
      ..insert('\n', {'list': 'unchecked', 'indent': 1})
      ..insert('Rye')
      ..insert('\n', {'list': 'checked', 'indent': 2})
      ..insert('Pay rent')
      ..insert('\n', {'list': 'checked'})
      ..insert('A bullet')
      ..insert('\n', {'list': 'bullet'})
      ..insert('End\n');

    final bytes = _docx.encode(delta);
    final reopened = _docx.decode(bytes);
    expect(_lines(reopened.delta), _lines(delta));
    expect(_numId(reopened.delta, 'Buy milk'), _numId(reopened.delta, 'Rye'));
    expect(_numId(reopened.delta, 'Call mom'), _numId(reopened.delta, 'Bread'));

    // Both boxes in the same font and at the bullets' indents, so a mixed
    // list lines up as one.
    final definitions = _definitions(bytes);
    final bullets = definitions['•']!;
    for (final box in ['☐', '☑']) {
      final levels = definitions[box]!;
      expect(levels, hasLength(9), reason: box);
      for (final (index, level) in levels.indexed) {
        expect(level.text, box);
        expect(level.font, 'Segoe UI Symbol');
        expect(level.left, bullets[index].left);
        expect(level.hanging, bullets[index].hanging);
      }
    }
    final document = XmlDocument.parse(
      DocxPackage.decode(bytes).text('word/document.xml')!,
    );
    final listStyles = {
      for (final paragraph in document.findAllElements('w:p'))
        if (paragraph.getElement('w:pPr')?.getElement('w:numPr') != null)
          paragraph
              .getElement('w:pPr')
              ?.getElement('w:pStyle')
              ?.getAttribute('w:val'),
    };
    expect(listStyles, {'ListParagraph'});
  });

  test('a box ticked or cleared after reopening is saved that way', () {
    final first = _docx.decode(
      _docx.encode(
        Delta()
          ..insert('Todo')
          ..insert('\n', {'list': 'unchecked'})
          ..insert('Done')
          ..insert('\n', {'list': 'checked'})
          ..insert('Nested')
          ..insert('\n', {'list': 'unchecked', 'indent': 1}),
      ),
    );
    var edited = _reflag(first.delta, 'Todo', 'checked');
    edited = _reflag(edited, 'Done', 'unchecked');
    final again = _docx.decode(_docx.encode(edited, source: first.source));
    expect(_lines(again.delta), [
      [
        'Todo',
        {'list': 'checked'},
      ],
      [
        'Done',
        {'list': 'unchecked'},
      ],
      [
        'Nested',
        {'list': 'unchecked', 'indent': 1},
      ],
    ]);
  });

  test("lists added to a header are saved with the body's lists", () {
    final header = Delta()
      ..insert('Todo')
      ..insert('\n', {'list': 'unchecked'})
      ..insert('Step')
      ..insert('\n', {'list': 'ordered'});
    final reopened = _docx.decode(
      _docx.encode(
        Delta()
          ..insert('Body')
          ..insert('\n', {'list': 'bullet'}),
        headersFooters: HeadersFooters(
          headers: {
            PageVariant.normal: HeaderFooterStory(delta: header, edited: true),
          },
        ),
      ),
    );
    expect(_lines(reopened.delta), [
      [
        'Body',
        {'list': 'bullet'},
      ],
    ]);
    expect(_lines(reopened.headersFooters.headers[PageVariant.normal]!.delta), [
      [
        'Todo',
        {'list': 'unchecked'},
      ],
      [
        'Step',
        {'list': 'ordered'},
      ],
    ]);
  });

  test("Word's boxes open as checklists; other bullets stay bullets", () {
    final spec = DocumentSpec();
    int list(String text, [String? font]) => spec.addList(
      ListSpec([
        for (var level = 0; level < 9; level++)
          ListLevelSpec(format: NumberFormat.bullet, text: text, font: font),
      ]),
    );
    final items = [
      ('Unchecked', list('☐', 'Segoe UI Symbol')),
      ('Checked', list('☑')),
      ('Crossed', list('☒', 'MS Gothic')),
      ('Symbol font', list('\uF0A8', 'Wingdings')),
      ('Spaced', list('☐ ')),
      ('Picture', list('☐')),
      ('Redefined', list('☐')),
      ('Numbered', spec.addList(ListSpec.numbered())),
    ];
    for (final (text, numId) in items) {
      spec.body.add(
        ParagraphSpec([
          TextSpec(text),
        ], format: ParagraphFormat(list: ListRef(numId))),
      );
    }
    final package = DocxBuilder(spec).build();
    final numbering = package
        .text('word/numbering.xml')!
        .replaceFirstMapped(
          RegExp('(<w:abstractNum w:abstractNumId="5">.*?<w:lvlText [^>]*>)'),
          (match) => '${match[1]}<w:lvlPicBulletId w:val="0"/>',
        )
        .replaceFirst(
          '<w:num w:numId="7"><w:abstractNumId w:val="6"/></w:num>',
          '<w:num w:numId="7"><w:abstractNumId w:val="6"/>'
              '<w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="0">'
              '<w:start w:val="1"/><w:numFmt w:val="bullet"/>'
              '<w:lvlText w:val="☑"/><w:lvlJc w:val="left"/>'
              '</w:lvl></w:lvlOverride></w:num>',
        );
    expect(numbering, contains('lvlPicBulletId'));
    expect(numbering, contains('lvlOverride'));
    package.setText('word/numbering.xml', numbering);

    expect(_lines(_docx.read(package).delta), [
      [
        'Unchecked',
        {'list': 'unchecked'},
      ],
      [
        'Checked',
        {'list': 'checked'},
      ],
      [
        'Crossed',
        {'list': 'checked'},
      ],
      [
        'Symbol font',
        {'list': 'bullet'},
      ],
      [
        'Spaced',
        {'list': 'bullet'},
      ],
      [
        'Picture',
        {'list': 'bullet'},
      ],
      [
        'Redefined',
        {'list': 'checked'},
      ],
      [
        'Numbered',
        {'list': 'ordered'},
      ],
    ]);
  });

  test('checklists made with a Word list style open as checklists', () {
    final spec = DocumentSpec();
    final numId = spec.addList(
      ListSpec([
        for (var level = 0; level < 9; level++)
          ListLevelSpec(
            format: NumberFormat.bullet,
            text: level == 0 ? '☐' : '☑',
            font: 'Segoe UI Symbol',
          ),
      ]),
    );
    for (final (text, level) in [('Buy milk', 0), ('Call mom', 1)]) {
      spec.body.add(
        ParagraphSpec([
          TextSpec(text),
        ], format: ParagraphFormat(list: ListRef(numId, level))),
      );
    }
    final package = DocxBuilder(spec).build();
    // As Word saves it: the list's abstract list names the list style, whose
    // own abstract list holds the levels.
    final numbering = package.text('word/numbering.xml')!;
    final levels = RegExp(
      '<w:abstractNum w:abstractNumId="0">(.*?)</w:abstractNum>',
    ).firstMatch(numbering)![1]!;
    package
      ..setText(
        'word/numbering.xml',
        numbering
            .replaceFirst(
              levels,
              '<w:multiLevelType w:val="hybridMultilevel"/>'
              '<w:numStyleLink w:val="Checklist"/>',
            )
            .replaceFirst(
              '<w:num ',
              '<w:abstractNum w:abstractNumId="90"><w:styleLink '
                  'w:val="Checklist"/>${levels.replaceFirst(RegExp('<w:multiLevelType [^>]*/>'), '')}'
                  '</w:abstractNum><w:num w:numId="90"><w:abstractNumId '
                  'w:val="90"/></w:num><w:num ',
            ),
      )
      ..setText(
        'word/styles.xml',
        package
            .text('word/styles.xml')!
            .replaceFirst(
              '</w:styles>',
              '<w:style w:type="numbering" w:styleId="Checklist"><w:name '
                  'w:val="Checklist"/><w:pPr><w:numPr><w:numId w:val="90"/>'
                  '</w:numPr></w:pPr></w:style></w:styles>',
            ),
      );
    expect(package.text('word/numbering.xml'), contains('numStyleLink'));

    final loaded = _docx.read(package);
    expect(_lines(loaded.delta), [
      [
        'Buy milk',
        {'list': 'unchecked'},
      ],
      [
        'Call mom',
        {'list': 'checked', 'indent': 1},
      ],
    ]);
    final markdown = utf8.decode(
      MarkdownCodec(
        _docx,
      ).encode(loaded.delta, source: loaded.source, look: loaded.look),
    );
    expect(markdown, contains('- [ ] Buy milk'));
    expect(markdown, contains('- [x] Call mom'));
  });

  test('HTML task items open as checklists and save back as boxes', () {
    final html = HtmlCodec(_docx);
    const page =
        '<ul><li><input type="checkbox" checked> Write</li>'
        '<li><input type="checkbox"> Test<ul>'
        '<li><input type="checkbox" checked> Unit</li>'
        '<li><input type="checkbox"> Widget</li></ul></li>'
        '<li>Plain</li></ul>';
    final loaded = html.decode(Uint8List.fromList(utf8.encode(page)));
    final expected = [
      [
        'Write',
        {'list': 'checked'},
      ],
      [
        'Test',
        {'list': 'unchecked'},
      ],
      [
        'Unit',
        {'list': 'checked', 'indent': 1},
      ],
      [
        'Widget',
        {'list': 'unchecked', 'indent': 1},
      ],
      [
        'Plain',
        {'list': 'bullet'},
      ],
    ];
    expect(_lines(loaded.delta), expected);

    final saved = utf8.decode(
      html.encode(loaded.delta, source: loaded.source, look: loaded.look),
    );
    expect('<input type="checkbox"'.allMatches(saved), hasLength(4));
    expect('checked="checked"'.allMatches(saved), hasLength(2));
    final again = html.decode(Uint8List.fromList(utf8.encode(saved)));
    expect(_lines(again.delta), expected);
  });

  test('Markdown task items open as checklists and save back', () {
    final markdown = MarkdownCodec(_docx);
    LoadedDocument read(String text) =>
        markdown.decode(Uint8List.fromList(utf8.encode(text)));
    String write(LoadedDocument loaded) =>
        utf8.decode(markdown.encode(loaded.delta, source: loaded.source));

    const tasks = '- [x] done\n- [ ] todo\n';
    expect(write(read(tasks)), tasks);

    // Boxes the HTML reader sees as such, as in pages made from Markdown.
    final boxes = read(
      '- <input type="checkbox" checked> done\n'
      '- <input type="checkbox"> todo\n'
      '  - <input type="checkbox" checked> nested\n',
    );
    expect(_lines(boxes.delta), [
      [
        'done',
        {'list': 'checked'},
      ],
      [
        'todo',
        {'list': 'unchecked'},
      ],
      [
        'nested',
        {'list': 'checked', 'indent': 1},
      ],
    ]);
    expect(write(boxes), '- [x] done\n- [ ] todo\n  - [x] nested\n');

    // An editor checklist saved as .docx and reopened is still one.
    final checklist = Delta()
      ..insert('done')
      ..insert('\n', {'list': 'checked'})
      ..insert('todo')
      ..insert('\n', {'list': 'unchecked'});
    expect(write(_docx.decode(_docx.encode(checklist))), tasks);
  });
}
