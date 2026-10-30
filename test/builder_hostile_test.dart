import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/headers_footers.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:xml/xml.dart';

Matcher _problem(DocumentProblem problem) => throwsA(
  isA<DocumentProblemException>().having(
    (error) => error.problem,
    'problem',
    problem,
  ),
);

bool _invalidInXml(int unit) =>
    (unit < 0x20 && unit != 0x09 && unit != 0x0A && unit != 0x0D) ||
    unit == 0xFFFE ||
    unit == 0xFFFF;

/// Characters XML 1.0 can't hold in [xml], written raw or as references.
List<int> _invalidChars(String xml) => [
  for (final node in XmlDocument.parse(xml).descendants)
    for (final value in [
      if (node is XmlText) node.value,
      if (node is XmlElement) ...node.attributes.map((a) => a.value),
    ])
      ...value.codeUnits.where(_invalidInXml),
];

int _xmlLength(DocxPackage package) => package.parts.keys
    .where((name) => name.endsWith('.xml') || name.endsWith('.rels'))
    .fold(0, (sum, name) => sum + package.text(name)!.length);

String _linkOf(Delta delta, String text) =>
    delta
            .toList()
            .firstWhere((operation) => operation.data == text)
            .attributes?['link']
        as String;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the package has a size limit', () {
    final tabs = [for (var stop = 1; stop <= 64; stop++) TabStop(stop * 6.0)];
    final longFont = 'F' * 100;
    final shapes = <String, DocumentSpec Function()>{
      'empty paragraphs with tab stops': () => DocumentSpec()
        ..body.addAll([
          for (var index = 0; index < 2000; index++)
            ParagraphSpec(const [], format: ParagraphFormat(tabs: tabs)),
        ]),
      'runs with long font names': () => DocumentSpec()
        ..body.add(
          ParagraphSpec([
            for (var index = 0; index < 3000; index++)
              TextSpec('x', RunFormat(font: longFont, bold: index.isEven)),
          ]),
        ),
      'table cells': () => DocumentSpec()
        ..body.add(
          TableSpec([
            for (var row = 0; row < 300; row++)
              RowSpec([
                for (var cell = 0; cell < 20; cell++)
                  const CellSpec([], background: 'FFFF00'),
              ]),
          ]),
        ),
      'notes and links': () => DocumentSpec()
        ..body.add(
          ParagraphSpec([
            for (var index = 0; index < 1500; index++) ...[
              LinkSpec('https://example.com/$index', [TextSpec('$index')]),
              const NoteSpec(NoteKind.endnote, [
                ParagraphSpec([TextSpec('note')]),
              ]),
            ],
          ]),
        ),
      'headers': () => DocumentSpec()
        ..headers[PageVariant.normal] = [
          for (var index = 0; index < 2000; index++)
            ParagraphSpec(const [], format: ParagraphFormat(tabs: tabs)),
        ],
    };

    for (final MapEntry(key: shape, value: build) in shapes.entries) {
      test(shape, () {
        final size = _xmlLength(DocxBuilder(build()).build());
        expect(size, greaterThan(500000));
        expect(
          () => DocxBuilder(build(), maxOutput: size * 9 ~/ 10).build(),
          _problem(DocumentProblem.tooLarge),
        );
        expect(
          () => DocxBuilder(build(), maxOutput: size).build(),
          returnsNormally,
        );
      });
    }

    test('of 256 MB by default', () {
      expect(DocxBuilder(DocumentSpec()).maxOutput, 256 * 1024 * 1024);
    });
  });

  test('font names too long to be real are left out', () {
    final long = 'a' * 10000;
    final kept = 'b' * 100;
    final spec = DocumentSpec(defaultRun: RunFormat(font: long, size: 12));
    final list = spec.addList(
      ListSpec([
        ListLevelSpec(format: NumberFormat.bullet, text: '•', font: long),
      ]),
    );
    spec
      ..styles.add(
        StyleSpec.character('Long', 'Long', run: RunFormat(font: long)),
      )
      ..body.addAll([
        for (var index = 0; index < 50; index++)
          ParagraphSpec(
            [TextSpec('x', RunFormat(font: long))],
            format: ParagraphFormat(list: ListRef(list)),
            mark: RunFormat(font: long),
          ),
        ParagraphSpec([TextSpec('kept', RunFormat(font: kept))]),
      ]);
    final package = DocxBuilder(spec).build();

    for (final part in [
      'word/document.xml',
      'word/styles.xml',
      'word/numbering.xml',
    ]) {
      expect(package.text(part), isNot(contains('a' * 101)), reason: part);
    }
    expect(package.text('word/document.xml'), contains('w:ascii="$kept"'));
    expect(package.text('word/styles.xml'), contains('w:ascii="Arial"'));
    final loaded = DocxCodec(TableStore()).read(package);
    expect(loaded.look.body.fontFamily, 'Arial');
    expect(
      loaded.delta.toList().map((operation) => operation.attributes?['font']),
      isNot(contains(long)),
    );
  });

  test('many links to different addresses build in linear time', () {
    final spec = DocumentSpec()
      ..body.add(
        ParagraphSpec([
          for (var index = 0; index < 40000; index++)
            LinkSpec('https://example.com/$index', [TextSpec('$index ')]),
          const LinkSpec('https://example.com/0', [TextSpec('again')]),
        ]),
      );
    final watch = Stopwatch()..start();
    final package = DocxBuilder(spec).build();
    watch.stop();

    expect(
      package
          .relationships('word/document.xml')
          .where((relationship) => relationship.hasType('hyperlink')),
      hasLength(40000),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('control characters never reach link targets', () {
    final codec = DocxCodec(TableStore());
    final spec = DocumentSpec()
      ..body.add(
        const ParagraphSpec([
          LinkSpec('http://example.com/a\u0001b', [TextSpec('rtf')]),
          LinkSpec('http://example.com/long\u001Fword', [TextSpec('doc')]),
          LinkSpec('#mark\u0001', [TextSpec('anchor')]),
          BookmarkSpec('mark\u0001'),
        ]),
      );
    final package = DocxBuilder(spec).build();
    for (final part in package.parts.keys) {
      if (part.endsWith('.xml') || part.endsWith('.rels')) {
        expect(_invalidChars(package.text(part)!), isEmpty, reason: part);
      }
    }

    final loaded = codec.read(package);
    expect(_linkOf(loaded.delta, 'rtf'), 'http://example.com/ab');
    expect(_linkOf(loaded.delta, 'doc'), 'http://example.com/longword');
    final saved = DocxPackage.decode(
      codec.encode(loaded.delta, source: loaded.source),
    );
    final typed = DocxPackage.decode(
      codec.encode(
        Delta()
          ..insert('typed', {'link': 'https://example.com/\u0001x'})
          ..insert(' and ')
          ..insert('marked', {'link': '#mark\u0001'})
          ..insert('\n'),
      ),
    );
    for (final package in [saved, typed]) {
      for (final part in [
        'word/document.xml',
        'word/_rels/document.xml.rels',
      ]) {
        expect(_invalidChars(package.text(part)!), isEmpty, reason: part);
      }
    }
    expect(safeLinkTarget('java\u0001script:alert(1)'), isNull);
    expect(
      safeLinkTarget('\u0001https://example.com/'),
      'https://example.com/',
    );
  });
}
