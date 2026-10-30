import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/odt/odt_codec.dart';

import 'odt_fixtures.dart';

LoadedDocument _decode(Uint8List bytes) =>
    OdtCodec(DocxCodec(TableStore())).decode(bytes);

String _plain(Delta delta) => [
  for (final operation in delta.toList())
    if (operation.data is String) operation.data as String,
].join();

Matcher _problem(DocumentProblem problem) => throwsA(
  isA<DocumentProblemException>().having(
    (error) => error.problem,
    'problem',
    problem,
  ),
);

/// Sets the uncompressed size the zip declares for [name].
Uint8List _declareSize(Uint8List zip, String name, int size) {
  final bytes = Uint8List.fromList(zip);
  final data = ByteData.sublistView(bytes);
  final encoded = name.codeUnits;
  for (var offset = 0; offset + 46 < bytes.length; offset++) {
    final signature = data.getUint32(offset, Endian.little);
    final (nameLength, nameStart, sizeAt) = switch (signature) {
      0x04034B50 => (data.getUint16(offset + 26, Endian.little), 30, 22),
      0x02014B50 => (data.getUint16(offset + 28, Endian.little), 46, 24),
      _ => (-1, 0, 0),
    };
    if (nameLength != encoded.length) continue;
    final start = offset + nameStart;
    if (start + nameLength > bytes.length) continue;
    var same = true;
    for (var index = 0; index < nameLength; index++) {
      if (bytes[start + index] != encoded[index]) same = false;
    }
    if (same) data.setUint32(offset + sizeAt, size, Endian.little);
  }
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('files that are not OpenDocument Text are refused', () {
    expect(
      () => _decode(Uint8List.fromList('not a zip'.codeUnits)),
      _problem(DocumentProblem.notWordDocument),
    );
    expect(
      () => _decode(zipOf({'readme.txt': 'hi'})),
      _problem(DocumentProblem.notWordDocument),
    );
    expect(
      () => _decode(
        odtFile(mimetype: 'application/vnd.oasis.opendocument.spreadsheet'),
      ),
      _problem(DocumentProblem.notWordDocument),
    );
    expect(
      () => _decode(
        zipOf({
          'content.xml':
              '<office:document-content $odfNamespaces><office:body>'
              '<office:spreadsheet/></office:body></office:document-content>',
        }),
      ),
      _problem(DocumentProblem.notWordDocument),
    );
  });

  test('encrypted files ask for a password', () {
    expect(
      () => _decode(
        odtFile(
          manifest:
              '<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0">'
              '<manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/>'
              '<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml">'
              '<manifest:encryption-data manifest:checksum-type="SHA1/1K" manifest:checksum="x"/>'
              '</manifest:file-entry></manifest:manifest>',
        ),
      ),
      _problem(DocumentProblem.passwordProtected),
    );
  });

  test('truncated and corrupted files fail as damaged', () {
    final valid = odtFile(body: '<text:p>${'text ' * 200}</text:p>');
    for (final length in [10, 100, valid.length ~/ 2, valid.length - 10]) {
      expect(
        () => _decode(Uint8List.sublistView(valid, 0, length)),
        throwsA(isA<DocumentProblemException>()),
        reason: 'cut at $length',
      );
    }
    expect(
      () => _decode(odtFile(body: '<text:p>unclosed')),
      _problem(DocumentProblem.damaged),
    );
    expect(
      () => _decode(_declareSize(valid, 'content.xml', 20)),
      _problem(DocumentProblem.damaged),
    );
  });

  test('sizes and counts are bounded before anything is decompressed', () {
    expect(
      () => _decode(_declareSize(odtFile(), 'content.xml', 0x7FFFFFFF)),
      _problem(DocumentProblem.tooLarge),
    );
    expect(
      () => _decode(
        zipOf({
          'mimetype': 'application/vnd.oasis.opendocument.text',
          for (var index = 0; index <= 10000; index++) 'f$index': '',
        }),
      ),
      _problem(DocumentProblem.tooLarge),
    );

    // A picture over its limit is left out; the text still opens.
    final picture = _declareSize(
      odtFile(
        body:
            '<text:p>pic<draw:frame><draw:image xlink:href="Pictures/a.png"/></draw:frame></text:p>',
        extra: {'Pictures/a.png': pngPixel},
      ),
      'Pictures/a.png',
      100 * 1024 * 1024,
    );
    final loaded = _decode(picture);
    expect(_plain(loaded.delta), 'pic\n');
    expect(loaded.notices, contains(DocumentNotice.contentNotImported));
  });

  test('deep nesting fails fast instead of overflowing the stack', () {
    final spans = StringBuffer();
    for (var index = 0; index < 100000; index++) {
      spans.write('<text:span>');
    }
    spans.write('x');
    for (var index = 0; index < 100000; index++) {
      spans.write('</text:span>');
    }
    expect(
      () => _decode(odtFile(body: '<text:p>$spans</text:p>')),
      _problem(DocumentProblem.damaged),
    );
    expect(
      () => _decode(
        odtFile(styles: '${'<text:list>' * 300}${'</text:list>' * 300}'),
      ),
      _problem(DocumentProblem.damaged),
    );

    String tables(int depth) => depth == 0
        ? '<text:p>deep</text:p>'
        : '<table:table><table:table-row><table:table-cell>'
              '${tables(depth - 1)}'
              '</table:table-cell></table:table-row></table:table>';
    expect(
      () => _decode(odtFile(body: tables(20))),
      _problem(DocumentProblem.damaged),
    );
    expect(() => _decode(odtFile(body: tables(10))), returnsNormally);

    // Within the limits, nesting still opens.
    final lists = StringBuffer();
    for (var index = 0; index < 40; index++) {
      lists.write('<text:list><text:list-item>');
    }
    lists.write('<text:p>bottom</text:p>');
    for (var index = 0; index < 40; index++) {
      lists.write('</text:list-item></text:list>');
    }
    final nested = _decode(
      odtFile(
        body:
            '$lists<text:p>${'<text:span>' * 150}'
            'inner${'</text:span>' * 150}</text:p>',
      ),
    );
    expect(_plain(nested.delta), contains('bottom\ninner'));
  });

  test('repeat counts can not blow the document up', () {
    final spaces = _decode(
      odtFile(body: '<text:p>a<text:s text:c="999999999"/>b</text:p>'),
    );
    expect(_plain(spaces.delta), 'a${' ' * 1000}b\n');

    // 63 columns by 10000 rows passes the limit on cells.
    expect(
      () => _decode(
        odtFile(
          body:
              '<table:table><table:table-column table:number-columns-repeated="999999999"/>'
              '<table:table-row table:number-rows-repeated="999999999">'
              '<table:table-cell table:number-columns-repeated="999999999"/>'
              '</table:table-row></table:table>',
        ),
      ),
      _problem(DocumentProblem.tooLarge),
    );

    // Repeated rows reuse their content, which still counts every time.
    expect(
      () => _decode(
        odtFile(
          body:
              '<table:table><table:table-row table:number-rows-repeated="5000">'
              '<table:table-cell><text:p>${'x' * 100000}</text:p></table:table-cell>'
              '</table:table-row></table:table>',
        ),
      ),
      _problem(DocumentProblem.tooLarge),
    );

    final lists = StringBuffer();
    for (var index = 0; index < 5001; index++) {
      lists.write(
        '<text:list><text:list-item><text:p/></text:list-item></text:list>',
      );
    }
    expect(
      () => _decode(odtFile(body: '$lists')),
      _problem(DocumentProblem.tooLarge),
    );
  });

  test('empty paragraphs count toward the output limit', () {
    final stops = [
      for (var index = 1; index <= 64; index++)
        '<style:tab-stop style:position="${index * 0.2}cm"/>',
    ].join();
    expect(
      () => _decode(
        odtFile(
          styles:
              '<style:default-style style:family="paragraph"><style:paragraph-properties>'
              '<style:tab-stops>$stops</style:tab-stops></style:paragraph-properties>'
              '</style:default-style>'
              '<style:style style:name="Standard" style:family="paragraph"/>',
          body: '<text:p/>' * 32000,
        ),
      ),
      _problem(DocumentProblem.tooLarge),
    );
  });

  test('reused cells count every cell they hold', () {
    const inner =
        '<table:table><table:table-row table:number-rows-repeated="1000">'
        '<table:table-cell><text:p>x</text:p></table:table-cell>'
        '</table:table-row></table:table>';
    expect(
      () => _decode(
        odtFile(
          body:
              '<table:table><table:table-row table:number-rows-repeated="2">'
              '<table:table-cell table:number-columns-repeated="63">$inner'
              '</table:table-cell></table:table-row></table:table>',
        ),
      ),
      _problem(DocumentProblem.tooLarge),
    );
  });

  test('made-up font names are dropped instead of repeated on every run', () {
    final name = 'a' * 10000;
    final loaded = _decode(
      odtFile(
        fonts:
            '<style:font-face style:name="Long" svg:font-family="$name"/>'
            '<style:font-face style:name="$name"/>',
        automatic:
            '<style:style style:name="P1" style:family="paragraph" style:parent-style-name="Standard">'
            '<style:text-properties style:font-name="Long"/></style:style>'
            '<style:style style:name="T1" style:family="text">'
            '<style:text-properties fo:font-family="$name"/></style:style>'
            '<style:style style:name="T2" style:family="text">'
            '<style:text-properties style:font-name="$name"/></style:style>',
        body:
            '<text:p text:style-name="P1">one <text:span text:style-name="T1">two</text:span> '
                '<text:span text:style-name="T2">three</text:span></text:p>' *
            100,
      ),
    );
    final document = (loaded.source! as DocxPackage).text('word/document.xml')!;
    expect(document, isNot(contains('a' * 101)));
    expect(_plain(loaded.delta), startsWith('one two three\n'));
  });

  test('a cropped picture used many times is cropped once', () {
    final loaded = _decode(
      odtFile(
        automatic:
            '<style:style style:name="fr1" style:family="graphic">'
            '<style:graphic-properties fo:clip="rect(0cm, 0cm, 0cm, 13.2292cm)"/>'
            '</style:style>',
        body:
            '<text:p>${'<draw:frame draw:style-name="fr1" svg:width="1cm" svg:height="2cm">'
                    '<draw:image xlink:href="Pictures/a.png"/></draw:frame>' * 200}</text:p>',
        extra: {'Pictures/a.png': halvesPng(1000, 1000)},
      ),
    );
    final images = embedsOf(loaded.delta, EmbedTypes.image);
    expect(images, hasLength(200));
    expect(images.map((image) => pictureOf(image).width).toSet(), {500});
    expect(loaded.notices, isEmpty);
  });

  test('style loops, absurd lengths and odd values still open', () {
    final loaded = _decode(
      odtFile(
        styles:
            '$libreOfficeStyles'
            '<style:style style:name="A" style:family="paragraph" style:parent-style-name="B">'
            '<style:text-properties fo:font-size="200%"/></style:style>'
            '<style:style style:name="B" style:family="paragraph" style:parent-style-name="A">'
            '<style:text-properties fo:font-size="200%"/></style:style>',
        automatic:
            '<style:style style:name="P1" style:family="paragraph" style:parent-style-name="A">'
            '<style:paragraph-properties fo:margin-left="1e308in" fo:line-height="-5%" '
            'fo:text-indent="NaNcm"/><style:text-properties fo:font-size="99999pt"/></style:style>',
        masterAutomatic:
            '<style:page-layout style:name="pm1"><style:page-layout-properties '
            'fo:page-width="1e30cm" fo:page-height="-4cm" fo:margin-left="900in"/>'
            '</style:page-layout>',
        body:
            '<text:p text:style-name="P1">loop</text:p>'
            '<text:p><draw:frame svg:width="1e308in" svg:height="0cm">'
            '<draw:image xlink:href="Pictures/a.png"/></draw:frame></text:p>',
        extra: {'Pictures/a.png': pngPixel},
      ),
    );
    expect(_plain(loaded.delta), contains('loop'));
    expect(loaded.look.pageWidth, lessThanOrEqualTo(3168));
    expect(loaded.look.pageHeight, greaterThan(0));
    expect(loaded.look.contentWidth, greaterThan(0));
  });

  test('entities are never expanded nor fetched', () {
    final stopwatch = Stopwatch()..start();
    final laughs = _decode(
      zipOf({
        'mimetype': 'application/vnd.oasis.opendocument.text',
        'content.xml':
            '<?xml version="1.0"?><!DOCTYPE office:document-content ['
            '<!ENTITY a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">'
            '<!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">'
            '<!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">'
            '<!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">'
            '<!ENTITY xxe SYSTEM "file:///etc/passwd">]>'
            '<office:document-content $odfNamespaces><office:body><office:text>'
            '<text:p>&d;&d;&d;&d;</text:p><text:p>&xxe;</text:p>'
            '</office:text></office:body></office:document-content>',
      }),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    final text = _plain(laughs.delta);
    expect(text.length, lessThan(1000));
    expect(text, isNot(contains('root:')));
  });
}
