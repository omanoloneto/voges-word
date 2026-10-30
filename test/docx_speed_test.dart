import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';

// Bounds are several times what a laptop takes in debug mode, so slow
// machines pass; before reading was linear these took minutes.
const _bound = Duration(seconds: 20);
const _timeout = Timeout(Duration(minutes: 4));

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

T _timed<T>(String what, T Function() work) {
  final watch = Stopwatch()..start();
  final result = work();
  expect(watch.elapsed, lessThan(_bound), reason: what);
  return result;
}

DocxCodec _codec() => DocxCodec(TableStore());

void main() {
  test('100k short paragraphs build, open and save quickly', () {
    final spec = DocumentSpec();
    for (var index = 0; index < 100000; index++) {
      spec.body.add(ParagraphSpec([TextSpec('Line $index.')]));
    }
    final codec = _codec();
    final package = _timed('build', () => DocxBuilder(spec).build());
    final loaded = _timed('read', () => codec.read(package));
    expect(loaded.delta.length, 1);
    final text = loaded.delta.first.data! as String;
    expect(text, startsWith('Line 0.\nLine 1.\n'));
    expect(text, endsWith('Line 99999.\n'));

    final bytes = _timed(
      'save',
      () => codec.encode(loaded.delta, source: loaded.source),
    );
    final again = _timed('open', () => codec.decode(bytes));
    expect(again.delta, loaded.delta);
  }, timeout: _timeout);

  test('a paragraph of 100k runs opens quickly', () {
    final spec = DocumentSpec()
      ..body.add(
        ParagraphSpec([
          for (var index = 0; index < 100000; index++)
            TextSpec('word $index ', const RunFormat(bold: true)),
        ]),
      );
    final codec = _codec();
    final loaded = _timed('read', () => codec.read(DocxBuilder(spec).build()));
    final operations = loaded.delta.toList();
    expect(operations, hasLength(2));
    expect(operations.first.attributes, {'bold': true});
    expect(operations.first.data, endsWith('word 99999 '));
    _timed('save', () => codec.encode(loaded.delta, source: loaded.source));
  }, timeout: _timeout);

  test(
    'a mixed document of 20k paragraphs opens and saves quickly',
    () {
      final spec = DocumentSpec();
      spec.styles.add(
        const StyleSpec.character(
          'Strong',
          'Strong',
          run: RunFormat(bold: true),
        ),
      );
      var list = 0;
      for (var index = 0; index < 20000; index++) {
        if (index % 25 == 0) {
          list = spec.addList(
            index.isEven ? ListSpec.bullets() : ListSpec.numbered(),
          );
        }
        spec.body.add(switch (index % 10) {
          0 => TableSpec([
            for (var row = 0; row < 2; row++)
              RowSpec([
                for (var column = 0; column < 2; column++)
                  CellSpec([
                    ParagraphSpec([TextSpec('Cell $index $row $column')]),
                  ]),
              ]),
          ]),
          1 => ParagraphSpec([TextSpec('Heading $index')], heading: 2),
          2 || 3 => ParagraphSpec([
            TextSpec('Item $index'),
          ], format: ParagraphFormat(list: ListRef(list, index % 2))),
          _ => ParagraphSpec([
            BookmarkSpec('mark$index'),
            TextSpec('Text $index ', const RunFormat(styleId: 'Strong')),
            LinkSpec('#mark${index ~/ 2}', [const TextSpec('back')]),
            if (index % 7 == 0)
              NoteSpec(NoteKind.footnote, [
                ParagraphSpec([TextSpec('Note $index')]),
              ]),
          ]),
        });
      }
      final codec = _codec();
      final package = _timed('build', () => DocxBuilder(spec).build());
      final loaded = _timed('read', () => codec.read(package));
      final notes = _timed('notes', () => codec.notes(package, 'footnote'));
      // With the two separators.
      expect(notes, hasLength(1715 + 2));
      final bytes = _timed(
        'save',
        () => codec.encode(loaded.delta, source: loaded.source),
      );
      final again = _timed('open', () => codec.decode(bytes));
      expect(again.delta.length, loaded.delta.length);
    },
    timeout: _timeout,
  );

  test('deep style chains are resolved once per style', () {
    final spec = DocumentSpec();
    for (var index = 0; index < 3000; index++) {
      spec.styles.add(
        StyleSpec.paragraph(
          'S$index',
          'Style $index',
          basedOn: index == 0 ? 'Normal' : 'S${index - 1}',
          run: index == 0
              ? const RunFormat(italic: true, color: 'FF0000')
              : const RunFormat(),
          paragraph: ParagraphFormat(spaceBefore: (index % 5).toDouble()),
        ),
      );
    }
    for (var index = 0; index < 20000; index++) {
      spec.body.add(
        ParagraphSpec([
          TextSpec('Paragraph $index '),
          TextSpec('bold', const RunFormat(bold: true)),
        ], format: ParagraphFormat(styleId: 'S${2999 - index % 1000}')),
      );
    }
    final codec = _codec();
    final loaded = _timed('read', () => codec.read(DocxBuilder(spec).build()));
    // Every style takes the first one's look through the whole chain.
    expect(loaded.delta.first.attributes, {'italic': true, 'color': '#FF0000'});
    _timed('save', () => codec.encode(loaded.delta, source: loaded.source));
  }, timeout: _timeout);

  test('many styles and no default one open and save quickly', () {
    final spec = DocumentSpec();
    for (var index = 0; index < 30000; index++) {
      spec.styles.add(StyleSpec.character('C$index', 'Character $index'));
    }
    for (var index = 0; index < 30000; index++) {
      spec.body.add(
        ParagraphSpec([TextSpec('Line $index')], heading: index % 3 + 1),
      );
    }
    final package = DocxBuilder(spec).build();
    final styles = package.text('word/styles.xml')!;
    package.setText(
      'word/styles.xml',
      styles.replaceFirst(
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">',
        '<w:style w:type="paragraph" w:styleId="Normal">',
      ),
    );
    expect(package.text('word/styles.xml'), isNot(styles));
    final codec = _codec();
    final loaded = _timed('read', () => codec.read(package));
    final headings = loaded.delta.toList().where(
      (operation) => operation.attributes?['header'] != null,
    );
    expect(headings, hasLength(30000));
    _timed('save', () => codec.encode(loaded.delta, source: loaded.source));
  }, timeout: _timeout);

  test('lists that share a long definition open quickly', () {
    final spec = DocumentSpec();
    final list = spec.addList(ListSpec.bullets());
    for (var index = 0; index < 20000; index++) {
      spec.body.add(
        ParagraphSpec([
          TextSpec('Item $index'),
        ], format: ParagraphFormat(list: ListRef(list))),
      );
    }
    final package = DocxBuilder(spec).build();
    const count = 30000;
    final numbering = StringBuffer(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:numbering xmlns:w="http://schemas.openxmlformats.org/'
      'wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0">',
    );
    for (var level = 0; level < count; level++) {
      numbering.write(
        '<w:lvl w:ilvl="$level"><w:numFmt w:val="bullet"/>'
        '<w:lvlText w:val="☐"/></w:lvl>',
      );
    }
    numbering.write('</w:abstractNum>');
    for (var id = 1; id <= count; id++) {
      numbering.write(
        '<w:num w:numId="$id"><w:abstractNumId w:val="0"/></w:num>',
      );
    }
    package.setText('word/numbering.xml', '$numbering</w:numbering>');
    final loaded = _timed('read', () => _codec().read(package));
    expect(loaded.delta.last.attributes?['list'], 'unchecked');
  }, timeout: _timeout);

  test(
    'a document of 100k separate lists builds and opens quickly',
    () {
      final spec = DocumentSpec();
      for (var index = 0; index < 100000; index++) {
        final list = spec.addList(
          ListSpec([
            const ListLevelSpec(format: NumberFormat.decimal, text: '%1.'),
          ]),
        );
        spec.body.add(
          ParagraphSpec([
            TextSpec('Item $index'),
          ], format: ParagraphFormat(list: ListRef(list))),
        );
      }
      final package = _timed('build', () => DocxBuilder(spec).build());
      expect(
        package.text('word/numbering.xml'),
        contains('<w:num w:numId="100000">'),
      );
      final loaded = _timed('read', () => _codec().read(package));
      expect(loaded.delta.last.attributes?['list'], 'ordered');
    },
    timeout: _timeout,
  );

  test('a picture shown many times is encoded once', () {
    final spec = DocumentSpec()
      ..body.add(
        ParagraphSpec([ImageSpec(Uint8List.fromList(_png), 'image/png')]),
      );
    final package = DocxBuilder(spec).build();
    final document = package.text('word/document.xml')!;
    final drawing = RegExp(
      '<w:r><w:drawing>.*?</w:drawing></w:r>',
    ).firstMatch(document)![0]!;
    package.setText(
      'word/document.xml',
      document.replaceFirst(drawing, drawing * 5000),
    );
    final loaded = _timed('read', () => _codec().read(package));
    final pictures = [
      for (final operation in loaded.delta.toList())
        if (operation.data case {EmbedTypes.image: final String uri}) uri,
    ];
    expect(pictures, hasLength(5000));
    expect(pictures.every((uri) => identical(uri, pictures.first)), isTrue);
    expect(pictures.first, 'data:image/png;base64,${base64Encode(_png)}');
  }, timeout: _timeout);

  test('building a Delta the way the reader does keeps Delta.push output', () {
    // Text, embeds and attributes that join or not, as Delta.insert does.
    final codec = _codec();
    final spec = DocumentSpec()
      ..body.addAll([
        ParagraphSpec([
          TextSpec('a'),
          TextSpec('b'),
          TextSpec('c', const RunFormat(italic: true)),
          ImageSpec(Uint8List.fromList(_png), 'image/png'),
          TextSpec('d', const RunFormat(italic: true)),
        ]),
        ParagraphSpec([TextSpec('e')]),
        ParagraphSpec([
          TextSpec('f'),
        ], format: ParagraphFormat(align: ParagraphAlign.center)),
        ParagraphSpec([]),
        ParagraphSpec([TextSpec('g', const RunFormat(bold: true))]),
      ]);
    final loaded = codec.read(DocxBuilder(spec).build());
    final expected = Delta();
    for (final operation in loaded.delta.toList()) {
      expected.push(operation);
    }
    expect(loaded.delta, expected);
    expect(
      [
        for (final operation in loaded.delta.toList())
          operation.data is String ? operation.data : 'image',
      ],
      ['ab', 'c', 'image', 'd', '\ne\nf', '\n', '\n', 'g', '\n'],
    );
  });
}
