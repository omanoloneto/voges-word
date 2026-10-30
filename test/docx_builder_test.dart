import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/headers_footers.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:xml/xml.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

List<Operation> _ops(Delta delta) => delta.toList();

Map<String, dynamic>? _lineAttributes(Delta delta, String text) {
  final operations = _ops(delta);
  for (var index = 0; index < operations.length; index++) {
    if (operations[index].data == text) {
      for (var next = index + 1; next < operations.length; next++) {
        final data = operations[next].data;
        if (data is String && data.startsWith('\n')) {
          return operations[next].attributes;
        }
      }
    }
  }
  return null;
}

Operation _op(Delta delta, String text) => _ops(delta).firstWhere(
  (operation) =>
      operation.data is String && (operation.data as String).contains(text),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'every part is well-formed and the package survives a zip round trip',
    () {
      final spec = DocumentSpec()
        ..body.add(const ParagraphSpec([TextSpec('a & <b> "c"\u0001\uFFFF')]));
      final package = DocxPackage.decode(DocxBuilder(spec).build().encode());
      for (final MapEntry(key: name, value: bytes) in package.parts.entries) {
        if (name.endsWith('.xml') || name.endsWith('.rels')) {
          expect(() => XmlDocument.parse(utf8.decode(bytes)), returnsNormally);
        }
      }
      final loaded = DocxCodec(TableStore()).read(package);
      expect(_ops(loaded.delta).first.data, 'a & <b> "c"\n');
    },
  );

  test('paragraph and character formatting come back as editor attributes', () {
    final spec = DocumentSpec(defaultParagraph: const ParagraphFormat())
      ..body.addAll([
        const ParagraphSpec([TextSpec('Title')], heading: 1),
        const ParagraphSpec([
          TextSpec('plain '),
          TextSpec(
            'styled',
            RunFormat(
              bold: true,
              italic: true,
              underline: true,
              strike: true,
              size: 18,
              font: 'Georgia',
              color: '#C00000',
              background: 'FFFF00',
            ),
          ),
          TextSpec('2', RunFormat(position: VerticalPosition.superscript)),
        ], format: ParagraphFormat(align: ParagraphAlign.center)),
        const ParagraphSpec(
          [TextSpec('spaced')],
          format: ParagraphFormat(
            lineSpacing: LineSpacing.multiple(1.5),
            spaceBefore: 6,
            spaceAfter: 12,
            indentLeft: 72,
            firstLine: -18,
          ),
        ),
      ]);
    final loaded = DocxCodec(TableStore()).read(DocxBuilder(spec).build());
    final delta = loaded.delta;

    expect(_lineAttributes(delta, 'Title')?['header'], 1);
    expect(_op(delta, 'styled').attributes, {
      'bold': true,
      'italic': true,
      'underline': true,
      'strike': true,
      'size': '18',
      'font': 'Georgia',
      'color': '#C00000',
      'background': '#FFFF00',
    });
    expect(_op(delta, '2').attributes?['script'], 'super');
    expect(_lineAttributes(delta, '2')?['align'], 'center');
    final spaced = _lineAttributes(delta, 'spaced')!;
    expect(spaced['line-height'], 1.5);
    expect(spaced['indent'], 2);
    expect(spaced[HiddenAttributes.spaceBefore], 6);
    expect(spaced[HiddenAttributes.spaceAfter], 12);
    expect(spaced[HiddenAttributes.firstLine], -18);
    expect(loaded.look.body.fontFamily, 'Arial');
    expect(loaded.look.body.fontSize, 12);
  });

  test('lists, links, bookmarks, breaks and pictures', () {
    final spec = DocumentSpec();
    final bullets = spec.addList(ListSpec.bullets());
    final numbers = spec.addList(ListSpec.numbered(start: 3));
    spec.body.addAll([
      ParagraphSpec(const [
        TextSpec('dot'),
      ], format: ParagraphFormat(list: ListRef(bullets))),
      ParagraphSpec(const [
        TextSpec('three'),
      ], format: ParagraphFormat(list: ListRef(numbers, 1))),
      const ParagraphSpec([
        BookmarkSpec('intro-1'),
        LinkSpec('https://example.com/?a=1&b=2', [TextSpec('site')]),
        TextSpec(' '),
        LinkSpec('javascript:alert(1)', [TextSpec('bad')]),
        TextSpec(' '),
        LinkSpec('#intro-1', [TextSpec('back')]),
        TextSpec('a\tb\nc'),
        BreakSpec(BreakKind.page),
      ]),
      ParagraphSpec([
        ImageSpec(_png, 'image/png', width: 30),
        ImageSpec(Uint8List.fromList([1, 2, 3]), 'image/svg+xml'),
      ]),
    ]);
    final loaded = DocxCodec(TableStore()).read(DocxBuilder(spec).build());
    final delta = loaded.delta;

    expect(_lineAttributes(delta, 'dot')?['list'], 'bullet');
    expect(_lineAttributes(delta, 'three')?['list'], 'ordered');
    expect(_lineAttributes(delta, 'three')?['indent'], 1);
    expect(
      _op(delta, 'site').attributes?['link'],
      'https://example.com/?a=1&b=2',
    );
    expect(_op(delta, 'bad').attributes?['link'], isNull);
    expect(_op(delta, 'back').attributes?['link'], '#intro_1');
    expect(
      _lineAttributes(delta, 'back')?[HiddenAttributes.bookmarks],
      jsonEncode(['intro_1']),
    );
    expect(_op(delta, 'a\tb\u2028c').attributes, isNull);
    expect(
      _ops(delta).any(
        (operation) =>
            operation.data is Map &&
            (operation.data as Map).containsKey(EmbedTypes.pageBreak),
      ),
      isTrue,
    );
    final images = _ops(delta)
        .where(
          (operation) =>
              operation.data is Map &&
              (operation.data as Map).containsKey(EmbedTypes.image),
        )
        .toList();
    expect(images, hasLength(1));
    expect(images.single.attributes?['width'], '30');
    expect(images.single.attributes?['height'], '30');
  });

  test('tables keep spans, merges, fills and nested content', () {
    final tables = TableStore();
    final spec = DocumentSpec()
      ..body.add(
        TableSpec(
          [
            RowSpec([
              CellSpec(const [
                ParagraphSpec([TextSpec('wide')]),
              ], span: 2),
              CellSpec(
                const [
                  ParagraphSpec([TextSpec('tall')]),
                ],
                merge: CellMerge.restart,
                background: 'D9E2F3',
              ),
            ], header: true),
            const RowSpec([
              CellSpec([
                ParagraphSpec([TextSpec('a')]),
              ]),
              CellSpec([
                TableSpec([
                  RowSpec([
                    CellSpec([
                      ParagraphSpec([TextSpec('inner')]),
                    ]),
                  ]),
                ]),
              ]),
              CellSpec([], merge: CellMerge.continuation),
            ]),
          ],
          columnWidths: const [100, 100, 200],
          bordered: false,
        ),
      );
    final loaded = DocxCodec(tables).read(DocxBuilder(spec).build());
    final table =
        tables[tableIdOf(
          (_ops(loaded.delta).first.data as Map)[EmbedTypes.table],
        )]!;

    expect(table.columnWidths, [2000, 2000, 4000]);
    expect(table.bordered, isFalse);
    expect(table.rows.first.cells.first.gridSpan, 2);
    expect(table.rows.first.cells.last.verticalMerge, VerticalMerge.restart);
    expect(table.rows.first.cells.last.fill?.toARGB32(), 0xFFD9E2F3);
    expect(
      table.rows.last.cells.last.verticalMerge,
      VerticalMerge.continuation,
    );
    final nested = table.rows.last.cells[1].controller.document.toDelta();
    expect((nested.first.data as Map).containsKey(EmbedTypes.table), isTrue);
  });

  test('notes, fields, headers and sections', () {
    final spec =
        DocumentSpec(
            page: const PageSpec(
              width: 841.9,
              height: 595.3,
              margins: EdgeInsets.all(36),
            ),
          )
          ..differentFirstPage = true
          ..headers[PageVariant.normal] = const [
            ParagraphSpec([FieldSpec('PAGE', result: '1')]),
          ]
          ..body.addAll([
            const ParagraphSpec([
              TextSpec('see'),
              NoteSpec(NoteKind.footnote, [
                ParagraphSpec([TextSpec('the note')]),
              ]),
              FieldSpec('INCLUDEPICTURE "http://x/y.png"', result: 'kept'),
              FieldSpec('DDEAUTO c:\\\\windows\\\\cmd.exe', result: ''),
            ]),
            const SectionBreakSpec(PageSpec()),
            const ParagraphSpec([TextSpec('landscape')]),
          ]);
    final package = DocxBuilder(spec).build();
    final loaded = DocxCodec(TableStore()).read(package);
    final document = package.text('word/document.xml')!;

    expect(document, isNot(contains('INCLUDEPICTURE')));
    expect(document, isNot(contains('DDEAUTO')));
    expect(package.text('word/footnotes.xml'), contains('the note'));
    expect(
      _ops(loaded.delta).any(
        (operation) =>
            operation.data is Map &&
            (operation.data as Map).containsKey(EmbedTypes.opaqueInline) &&
            OpaqueContent.decode(
                  (operation.data as Map)[EmbedTypes.opaqueInline],
                ).label ==
                OpaqueLabels.note,
      ),
      isTrue,
    );
    expect(_op(loaded.delta, 'kept'), isNotNull);
    expect(
      _ops(loaded.delta).any(
        (operation) =>
            operation.data is Map &&
            (operation.data as Map).containsKey(EmbedTypes.sectionBreak),
      ),
      isTrue,
    );
    expect(loaded.look.pageWidth, closeTo(841.9, 0.05));
    expect(loaded.look.margins.left, 36);
    expect(loaded.headersFooters.differentFirstPage, isTrue);
    final header = loaded.headersFooters.headers[PageVariant.normal]!;
    final field = header.delta.toList().firstWhere(
      (operation) => operation.data is Map,
    );
    expect(
      fieldNameOf(
        OpaqueContent.decode((field.data as Map)[EmbedTypes.opaqueInline]).xml,
      ),
      'PAGE',
    );
  });

  test('styles from the source keep their names and heading levels', () {
    final spec = DocumentSpec()
      ..styles.addAll(const [
        StyleSpec.paragraph(
          'Normal',
          'Normal',
          run: RunFormat(font: 'Times New Roman', size: 11),
        ),
        StyleSpec.paragraph(
          'Titulo1',
          'Título 1',
          basedOn: 'Normal',
          headingLevel: 1,
          run: RunFormat(size: 20, bold: true),
        ),
        StyleSpec.paragraph(
          'Citacao',
          'Citação',
          basedOn: 'Normal',
          run: RunFormat(italic: true),
        ),
      ])
      ..body.addAll(const [
        ParagraphSpec([
          TextSpec('Chapter'),
        ], format: ParagraphFormat(styleId: 'Titulo1')),
        ParagraphSpec([
          TextSpec('quote'),
        ], format: ParagraphFormat(styleId: 'Citacao')),
      ]);
    final loaded = DocxCodec(TableStore()).read(DocxBuilder(spec).build());

    expect(_lineAttributes(loaded.delta, 'Chapter')?['header'], 1);
    expect(loaded.look.headings[1]?.fontSize, 20);
    expect(loaded.look.body.fontFamily, 'Times New Roman');
    expect(_op(loaded.delta, 'quote').attributes?['italic'], isTrue);
    expect(
      _lineAttributes(
        loaded.delta,
        'quote',
      )?[HiddenAttributes.paragraphProperties],
      contains('Citacao'),
    );
  });

  test('saving the built package as .docx keeps its parts', () {
    final tables = TableStore();
    final codec = DocxCodec(tables);
    final spec = DocumentSpec()
      ..body.add(
        const ParagraphSpec([
          TextSpec('see'),
          NoteSpec(NoteKind.endnote, [
            ParagraphSpec([TextSpec('end')]),
          ]),
        ]),
      );
    final loaded = codec.read(DocxBuilder(spec).build());
    final saved = DocxPackage.decode(
      codec.encode(loaded.delta, source: loaded.source),
    );
    expect(saved.text('word/endnotes.xml'), contains('end'));
    expect(saved.text('word/document.xml'), contains('w:endnoteReference'));
  });

  test('notes are read with their formatting and without the mark', () {
    final spec = DocumentSpec()
      ..body.add(
        const ParagraphSpec([
          TextSpec('see'),
          NoteSpec(NoteKind.footnote, [
            ParagraphSpec([
              TextSpec('Bold', RunFormat(bold: true)),
              TextSpec(' and '),
              LinkSpec('https://example.com/', [TextSpec('a link')]),
            ]),
            ParagraphSpec([TextSpec('second')]),
          ]),
        ]),
      );
    final package = DocxBuilder(spec).build();
    final notes = DocxCodec(TableStore()).notes(package, 'footnote');
    final id = RegExp(
      r'w:footnoteReference w:id="(\d+)"',
    ).firstMatch(package.text('word/document.xml')!)![1]!;
    final note = notes[id]!;

    expect(note.toList().first.data, 'Bold');
    expect(note.toList().first.attributes?['bold'], isTrue);
    expect(_op(note, 'a link').attributes?['link'], 'https://example.com/');
    expect(
      note
          .toList()
          .map((operation) => operation.data)
          .whereType<String>()
          .join(),
      'Bold and a link\nsecond\n',
    );
  });

  test('sections can number their pages their own way', () {
    final spec = DocumentSpec(page: const PageSpec(firstNumber: 1))
      ..body.addAll([
        const ParagraphSpec([TextSpec('front matter')]),
        const SectionBreakSpec(PageSpec(numberFormat: NumberFormat.lowerRoman)),
        const ParagraphSpec([TextSpec('chapter one')]),
      ]);
    final document = DocxBuilder(spec).build().text('word/document.xml')!;

    expect(document, contains('<w:pgNumType w:fmt="lowerRoman"/><w:cols'));
    expect(document, contains('<w:pgNumType w:start="1"/><w:cols'));
    expect(XmlDocument.parse(document), isNotNull);
  });

  test('a paragraph can drop the list and tab stops its style gives', () {
    final spec = DocumentSpec();
    final list = spec.addList(ListSpec.numbered());
    spec
      ..styles.add(
        StyleSpec.paragraph(
          'Steps',
          'Steps',
          paragraph: ParagraphFormat(
            list: ListRef(list),
            tabs: const [TabStop(72)],
          ),
        ),
      )
      ..body.addAll(const [
        ParagraphSpec([
          TextSpec('numbered'),
        ], format: ParagraphFormat(styleId: 'Steps')),
        ParagraphSpec(
          [TextSpec('plain')],
          format: ParagraphFormat(
            styleId: 'Steps',
            list: ListRef.none,
            tabs: [TabStop(72, align: TabAlign.clear)],
          ),
        ),
      ]);
    final package = DocxBuilder(spec).build();
    final loaded = DocxCodec(TableStore()).read(package);

    expect(package.text('word/document.xml'), contains('w:val="clear"'));
    expect(_lineAttributes(loaded.delta, 'numbered')?['list'], 'ordered');
    expect(_lineAttributes(loaded.delta, 'plain')?['list'], isNull);
  });
}
