import 'dart:convert';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/docx/word_xml.dart';
import 'package:voges_word/html/html_reader.dart';
import 'package:voges_word/odt/odt_codec.dart';

import 'odt_fixtures.dart';

Delta _read(DocxPackage package) => DocxCodec(TableStore()).read(package).delta;

/// A package whose body is [body].
DocxPackage _packageWith(String body) {
  final package = DocxBuilder(
    DocumentSpec()..body.add(const ParagraphSpec([TextSpec('x')])),
  ).build();
  final document = package.text('word/document.xml')!;
  package.setText(
    'word/document.xml',
    document.replaceRange(
      document.indexOf('<w:body>') + '<w:body>'.length,
      document.indexOf('<w:sectPr>'),
      body,
    ),
  );
  return package;
}

Map<String, dynamic>? _attributesOf(Delta delta, String text) =>
    textOperation(delta, text).attributes;

String _document(DocumentSpec spec) =>
    utf8.decode(DocxBuilder(spec).build().parts['word/document.xml']!);

List<ParagraphSpec> _paragraphs(List<BlockSpec> blocks) => [
  for (final block in blocks)
    ...switch (block) {
      ParagraphSpec() => [block],
      TableSpec(:final rows) => [
        for (final row in rows)
          for (final cell in row.cells) ..._paragraphs(cell.blocks),
      ],
      _ => const <ParagraphSpec>[],
    },
];

ParagraphSpec _paragraphOf(List<BlockSpec> blocks, String text) =>
    _paragraphs(blocks).firstWhere(
      (paragraph) => paragraph.inlines.any(
        (inline) => inline is TextSpec && inline.text.contains(text),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the .docx reader works out each format once', () {
    test('runs formatted alike in paragraphs of different styles', () {
      final spec = DocumentSpec()
        ..styles.add(
          const StyleSpec.paragraph(
            'Quote',
            'Quote',
            basedOn: 'Normal',
            run: RunFormat(italic: true),
          ),
        )
        ..body.addAll(const [
          ParagraphSpec([
            TextSpec('quoted', RunFormat(bold: true)),
          ], format: ParagraphFormat(styleId: 'Quote')),
          ParagraphSpec([TextSpec('plain', RunFormat(bold: true))]),
          ParagraphSpec([
            TextSpec('again', RunFormat(bold: true)),
          ], format: ParagraphFormat(styleId: 'Quote')),
        ]);
      final delta = _read(DocxBuilder(spec).build());
      expect(_attributesOf(delta, 'quoted'), {'bold': true, 'italic': true});
      expect(_attributesOf(delta, 'plain'), {'bold': true});
      expect(_attributesOf(delta, 'again'), {'bold': true, 'italic': true});
    });

    test('markup alike whose prefix names another namespace', () {
      final delta = _read(
        _packageWith(
          '<w:p xmlns:v="${Namespaces.w}"><w:r><w:rPr><v:b/></w:rPr>'
          '<w:t>word</w:t></w:r></w:p>'
          '<w:p xmlns:v="urn:example:other"><w:r><w:rPr><v:b/></w:rPr>'
          '<w:t>other</w:t></w:r></w:p>'
          '<w:p xmlns:v="${Namespaces.w}"><w:r><w:rPr><v:b/></w:rPr>'
          '<w:t>again</w:t></w:r></w:p>',
        ),
      );
      expect(_attributesOf(delta, 'word'), {'bold': true});
      expect(_attributesOf(delta, 'other'), isNull);
      expect(_attributesOf(delta, 'again'), {'bold': true});
    });

    test('markup alike but for its quotes or empty elements', () {
      final delta = _read(
        _packageWith(
          '<w:p><w:r><w:rPr><w:lang w:val="fr-FR"/></w:rPr>'
          '<w:t>double</w:t></w:r></w:p>'
          "<w:p><w:r><w:rPr><w:lang w:val='fr-FR'/></w:rPr>"
          '<w:t>single</w:t></w:r></w:p>'
          '<w:p><w:r><w:rPr><w:emboss/></w:rPr><w:t>closed</w:t></w:r></w:p>'
          '<w:p><w:r><w:rPr><w:emboss></w:emboss></w:rPr>'
          '<w:t>open</w:t></w:r></w:p>',
        ),
      );
      String? kept(String text) =>
          _attributesOf(delta, text)?[HiddenAttributes.runProperties];
      expect(kept('double'), '<w:rPr><w:lang w:val="fr-FR"/></w:rPr>');
      expect(kept('single'), "<w:rPr><w:lang w:val='fr-FR'/></w:rPr>");
      expect(kept('closed'), '<w:rPr><w:emboss/></w:rPr>');
      expect(kept('open'), '<w:rPr><w:emboss></w:emboss></w:rPr>');
    });

    test('paragraphs formatted alike keep their own properties', () {
      final delta = _read(
        _packageWith(
          '<w:p><w:pPr><w:keepNext/><w:spacing w:before="120"/></w:pPr>'
          '<w:r><w:t>first</w:t></w:r></w:p>'
          '<w:p><w:pPr><w:keepNext/><w:spacing w:before="240"/></w:pPr>'
          '<w:r><w:t>second</w:t></w:r></w:p>'
          '<w:p><w:pPr><w:keepNext/><w:spacing w:before="120"/></w:pPr>'
          '<w:r><w:t>third</w:t></w:r></w:p>',
        ),
      );
      final lines = [
        for (final operation in delta.toList())
          if (operation.data == '\n') operation.attributes,
      ];
      expect(lines.map((line) => line?[HiddenAttributes.spaceBefore]), [
        6,
        12,
        6,
      ]);
      expect(lines.map((line) => line?[HiddenAttributes.paragraphProperties]), [
        '<w:pPr><w:keepNext/><w:spacing w:before="120"/></w:pPr>',
        '<w:pPr><w:keepNext/><w:spacing w:before="240"/></w:pPr>',
        '<w:pPr><w:keepNext/><w:spacing w:before="120"/></w:pPr>',
      ]);
    });

    test('more formats than are kept at once', () {
      String color(int index) =>
          (index * 3).toRadixString(16).padLeft(6, '0').toUpperCase();
      final spec = DocumentSpec()
        ..body.add(
          ParagraphSpec([
            for (var index = 0; index < 5000; index++)
              TextSpec('$index ', RunFormat(color: color(index))),
          ]),
        );
      final delta = _read(DocxBuilder(spec).build());
      for (final index in [1, 4095, 4096, 4097, 4999]) {
        expect(_attributesOf(delta, '$index '), {'color': '#${color(index)}'});
      }
    });
  });

  group('the builder', () {
    test('writes special characters as Word elements or leaves them out', () {
      const text =
          'a&b<c>d\te\nf\vg\fh\u001Ei\u001Fj­k‑l '
          'm\u0001n￾o\uD800p\uDC00q\u{1F600}r';
      String t(String text) => '<w:t xml:space="preserve">$text</w:t>';
      expect(
        _document(
          DocumentSpec()..body.add(const ParagraphSpec([TextSpec(text)])),
        ),
        contains(
          '<w:r>${t('a&amp;b&lt;c&gt;d')}<w:tab/>${t('e')}<w:br/>${t('f')}'
          '<w:br/>${t('g')}<w:br w:type="page"/>${t('h')}<w:noBreakHyphen/>'
          '${t('i')}<w:softHyphen/>${t('j')}<w:softHyphen/>${t('k')}'
          '<w:noBreakHyphen/>${t('l')}<w:br/>${t('mnopq\u{1F600}r')}</w:r>',
        ),
      );
    });

    test('names a style on runs once the style exists', () {
      const styled = RunFormat(styleId: 'Hyperlink', bold: true);
      final xml = _document(
        DocumentSpec()
          ..body.add(
            const ParagraphSpec([
              TextSpec('a', styled),
              LinkSpec('https://example.com', [TextSpec('b')]),
              TextSpec('c', styled),
            ]),
          ),
      );
      expect(
        xml,
        contains(
          '<w:r><w:rPr><w:b/><w:bCs/></w:rPr>'
          '<w:t xml:space="preserve">a</w:t></w:r>',
        ),
      );
      expect(
        xml,
        contains(
          '<w:r><w:rPr><w:rStyle w:val="Hyperlink"/><w:b/><w:bCs/></w:rPr>'
          '<w:t xml:space="preserve">c</w:t></w:r>',
        ),
      );
    });
  });

  group('the HTML reader works out each value once', () {
    test('lengths follow the font size and width they refer to', () {
      final blocks = readHtml(
        '<style>.x { margin-left: 2em } .w { margin-left: 10% }</style>'
        '<div style="font-size:10pt"><p class="x">small</p></div>'
        '<div style="font-size:20pt"><p class="x">large</p></div>'
        '<p class="w">page</p>'
        '<table><tr><td style="width:50%"><p class="w">cell</p></td>'
        '<td>other</td></tr></table>'
        '<div style="font-size:10pt"><p class="x">small again</p></div>',
      ).spec.body;
      double? indent(String text) =>
          _paragraphOf(blocks, text).format.indentLeft;
      expect(indent('small'), 20);
      expect(indent('large'), 40);
      expect(indent('small again'), 20);
      final page = const PageSpec().textWidth;
      expect(indent('page'), closeTo(page / 10, 1e-9));
      expect(indent('cell'), closeTo((page / 2 - 10.8) / 10, 1e-9));
    });

    test('more values than are kept at once', () {
      final page = StringBuffer();
      for (var index = 0; index < 5000; index++) {
        page.write(
          '<p style="margin-left: ${index % 700}pt" class="c$index">'
          'line $index</p>',
        );
      }
      final blocks = readHtml(page.toString()).spec.body;
      for (final index in [1, 4095, 4096, 4097, 4999]) {
        final left = (index % 700).toDouble();
        expect(
          _paragraphOf(blocks, 'line $index').format.indentLeft,
          left == 0 ? null : left,
        );
      }
    });
  });

  test('the ODT reader works out relative sizes for each paragraph', () {
    final loaded = OdtCodec(DocxCodec(TableStore())).decode(
      odtFile(
        automatic:
            '<style:style style:name="P1" style:family="paragraph">'
            '<style:text-properties fo:font-size="10pt"/></style:style>'
            '<style:style style:name="P2" style:family="paragraph">'
            '<style:text-properties fo:font-size="20pt"/></style:style>'
            '<style:style style:name="T1" style:family="text">'
            '<style:text-properties fo:font-size="50%"/></style:style>',
        body:
            '<text:p text:style-name="P1">a <text:span text:style-name="T1">'
            'small</text:span></text:p>'
            '<text:p text:style-name="P2">b <text:span text:style-name="T1">'
            'large</text:span></text:p>'
            '<text:p text:style-name="P1">c <text:span text:style-name="T1">'
            'small again</text:span></text:p>',
      ),
    );
    expect(textOperation(loaded.delta, 'small').attributes?['size'], '5');
    expect(textOperation(loaded.delta, 'large').attributes?['size'], '10');
    expect(textOperation(loaded.delta, 'small again').attributes?['size'], '5');
  });
}
