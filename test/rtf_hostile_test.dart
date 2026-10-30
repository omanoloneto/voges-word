import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/rtf/rtf_codec.dart';
import 'package:voges_word/rtf/rtf_reader.dart';

late TableStore _tables;

/// Reads without the codec's safety net, so any error other than a
/// [DocumentProblemException] fails the test.
LoadedDocument _strict(List<int> bytes) {
  final document = RtfReader(Uint8List.fromList(bytes)).read();
  return DocxCodec(
    _tables,
  ).read(DocxBuilder(document.spec).build()).withNotices(document.notices);
}

LoadedDocument _read(String rtf) => _strict(latin1.encode(rtf));

String _text(Delta delta) => delta
    .toList()
    .map((operation) => operation.data is String ? operation.data : '')
    .join();

Matcher _problem(DocumentProblem problem) => throwsA(
  isA<DocumentProblemException>().having(
    (error) => error.problem,
    'problem',
    problem,
  ),
);

/// Opens [bytes]; only a [DocumentProblemException] may stop it.
void _survives(List<int> bytes) {
  try {
    _strict(bytes);
  } on DocumentProblemException {
    // Refused cleanly.
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => _tables = TableStore());

  test('files that are not RTF', () {
    expect(() => _read(''), _problem(DocumentProblem.notWordDocument));
    expect(() => _read('plain'), _problem(DocumentProblem.notWordDocument));
    expect(() => _read(r'{\rt'), _problem(DocumentProblem.notWordDocument));
    expect(
      () => _read(r'{\rtx1 a}'),
      _problem(DocumentProblem.notWordDocument),
    );
    expect(
      _text(
        _strict([0xEF, 0xBB, 0xBF, ...latin1.encode(' \r\n{\\rtf1 a}')]).delta,
      ),
      'a\n',
    );
    expect(
      () => RtfCodec(DocxCodec(_tables)).decode(Uint8List.fromList([0, 1])),
      _problem(DocumentProblem.notWordDocument),
    );
  });

  test('deep nesting is reported as damage instead of overflowing', () {
    expect(
      () => _read('{\\rtf1 ${'{' * 5000}x${'}' * 5000}}'),
      _problem(DocumentProblem.damaged),
    );
    expect(
      _text(_read('{\\rtf1 ${'{\\b ' * 1000}x${'}' * 1000}\\par}').delta),
      'x\n',
    );
  });

  test('truncated files open with what they have', () {
    expect(_text(_read(r'{\rtf1 {\b bold').delta), 'bold\n');
    expect(_text(_read(r'{\rtf1 abc\').delta), 'abc\n');
    expect(_text(_read(r"{\rtf1 abc\'").delta), 'abc\n');
    expect(_text(_read(r"{\rtf1 abc\'4").delta), 'abc\n');
    expect(
      _read(
        r'{\rtf1 {\field{\*\fldinst HYPERLINK "http://x.com"}{\fldrslt link',
      ).delta.toList().first.attributes?['link'],
      'http://x.com',
    );
    final picture = _read(r'{\rtf1 {\pict\pngblip 89504e47');
    expect(picture.notices, [DocumentNotice.contentNotImported]);
    final table = _read(r'{\rtf1 \trowd\cellx100 \intbl a\cell b');
    expect(table.delta.toList().first.data, isA<Map<dynamic, dynamic>>());
  });

  test('numbers, words and lengths out of range', () {
    expect(
      _text(
        _read(
          r'{\rtf1 \fs99999999999999999999999\li-99999999999 \u-999999 '
          r'\u'
          r'999999 \uc'
          r'99999999 \sl-99999999 \cf99999 \f-1 x\par y\par}',
        ).delta,
      ),
      isNotEmpty,
    );
    expect(
      _text(_read('{\\rtf1 \\${'a' * 100000}1${'9' * 1000} x\\par}').delta),
      'x\n',
    );
    _survives(latin1.encode(r'{\rtf1 {\pict\pngblip\bin999999999999 abc}x}'));
    expect(_text(_read(r'{\rtf1 {\*\bin-5 ab}x\par}').delta), 'x\n');
    _survives(
      latin1.encode(
        r'{\rtf1\paperw-5\paperh0\margl-99\margt99999999 '
        r'{\pict\pngblip\picwgoal-5\picscalex0 00}x\par}',
      ),
    );
  });

  test('tables deeper than Word allows are flattened', () {
    final document = _read(
      r'{\rtf1 \pard\intbl\itap1000 deep\nestcell\nestrow'
      r'\pard\intbl top\cell\row\pard end\par}',
    );
    var depth = 0;
    var delta = document.delta;
    while (true) {
      final embed = delta.toList().firstWhere(
        (operation) => operation.data is Map,
        orElse: () => Operation.insert(''),
      );
      if (embed.data is! Map) break;
      final table = _tables[tableIdOf((embed.data as Map)[EmbedTypes.table])]!;
      depth++;
      delta = table.rows.first.cells.first.controller.document.toDelta();
    }
    expect(depth, 32);
    expect(_text(delta), 'deep\n');
  });

  test('rows and cells stay within what Word can show', () {
    final document = _read(
      '{\\rtf1 \\trowd${'\\cellx100' * 100000}\\pard\\intbl '
      '${'a\\cell ' * 1000}\\row\\pard\\par}',
    );
    final table =
        _tables[tableIdOf(
          (document.delta.toList().first.data as Map)[EmbedTypes.table],
        )]!;
    expect(table.rows.single.cells.length, lessThanOrEqualTo(63));
    expect(table.columnWidths.length, lessThanOrEqualTo(63));
  });

  test('too much content is refused quickly', () {
    final watch = Stopwatch()..start();
    expect(
      () => _read('{\\rtf1 ${'x\\par ' * 260000}}'),
      _problem(DocumentProblem.tooLarge),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
  });

  test('font names are capped however they are written', () {
    final document = _read(
      '{\\rtf1{\\fonttbl{\\f0 Arial;}{\\f1 ${'a' * 10000};}}{\\f1 x}\\par}',
    );
    // The builder leaves out names over 100 characters.
    final font = document.delta.toList().first.attributes?['font'] as String?;
    expect(font, isNull);
  });

  test('formatting repeated on every paragraph counts toward the limit', () {
    final tabs = [for (var tab = 1; tab <= 64; tab++) '\\tx${tab * 100}'];
    final watch = Stopwatch()..start();
    expect(
      () => _read(
        '{\\rtf1{\\fonttbl{\\f0 Arial;}{\\f1 ${'a' * 250};}}'
        '\\pard${tabs.join()}\\f1 ${'\\par ' * 10000}}',
      ),
      _problem(DocumentProblem.tooLarge),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
  });

  test('large tables of fonts, colors, styles and lists are capped', () {
    final rtf = StringBuffer(r'{\rtf1{\fonttbl');
    for (var index = 0; index < 20000; index++) {
      rtf.write('{\\f$index F$index;}');
    }
    rtf.write(r'}{\colortbl;');
    rtf.write(r'\red1\green2\blue3;' * 20000);
    rtf.write(r'}{\stylesheet');
    for (var index = 0; index < 20000; index++) {
      rtf.write('{\\s$index\\outlinelevel${index % 10} S$index;}');
    }
    rtf.write(r'}{\*\listoverridetable');
    for (var index = 1; index < 20000; index++) {
      rtf.write('{\\listoverride\\listid$index\\ls$index}');
    }
    rtf.write('}');
    for (var index = 1; index < 300; index++) {
      rtf.write('\\pard\\ls$index\\s$index\\f$index\\cf$index x\\par ');
    }
    rtf.write('}');
    expect(_text(_read(rtf.toString()).delta), startsWith('x\nx\n'));
  });

  test('damaged and random input never fails another way', () {
    final random = Random(7);
    final word = File('test/fixtures/rtf/word.rtf').readAsBytesSync();
    for (var round = 0; round < 40; round++) {
      final bytes = Uint8List.fromList(word);
      for (var flip = 0; flip < 30; flip++) {
        bytes[random.nextInt(bytes.length)] = random.nextInt(256);
      }
      _survives(
        round.isEven
            ? bytes
            : Uint8List.sublistView(bytes, 0, random.nextInt(bytes.length)),
      );
    }
    const doubleByte = [932, 936, 949, 950, 1361];
    for (var round = 0; round < 10; round++) {
      final codePage = round.isEven ? 1252 : doubleByte[round ~/ 2];
      _survives([
        ...latin1.encode('{\\rtf1\\ansicpg$codePage '),
        for (var index = 0; index < 20000; index++) random.nextInt(256),
      ]);
    }
    const tokens = [
      '{', '}', r'\par ', r'\cell ', r'\row ', r'\nestcell ', r'\nestrow ', //
      r'\intbl ', r'\itap3 ', r'\itap0 ', r'\trowd ', r'\cellx500 ', //
      r'\clvmgf ', r'\clvmrg ', r'\clmrg ', r'\field ', r'{\*\fldinst ', //
      'HYPERLINK "http://a" ', r'{\fldrslt ', r'\pict ', r'\pngblip ', //
      '89504e47 ', r'\bin3 ', r'\footnote ', r'\header ', r'\shp ', //
      r'\shptxt ', r'\sp ', r'\sn ', r'\sv ', 'pib ', r'\upr ', r'\ud ', //
      r'\*', r'\u-5 ', r"\'e9", r'\uc3 ', r'\ls1 ', r'\ilvl9 ', r'\pn ', //
      r'\pnlvlbody ', r'\sect ', r'\sectd ', r'\listtable ', r'\list ', //
      r'\listlevel ', r'\leveltext ', r'\stylesheet ', r'\s1 ', r'\cs2 ', //
      r'\fonttbl ', r'\f1 ', r'\colortbl ', r'\red9 ', ';', 'text ', //
      r'\object ', r'\result ', r'\deleted ', r'\v ', r'\tab ', r'\line ', //
      r'\page ', r'\listoverridetable ', r'\listoverride ', r'\lfolevel ', //
      r'\nesttableprops ', r'\pard ', r'\plain ', r'\wmetafile8 ', //
      r'\dibitmap0 ', r'\wbitmap0 ', '0100090000 ', r'\fet1 ', r'\ftnalt ',
    ];
    for (var round = 0; round < 60; round++) {
      final rtf = StringBuffer(r'{\rtf1 ');
      for (var index = 0; index < 2000; index++) {
        rtf.write(tokens[random.nextInt(tokens.length)]);
      }
      _survives(latin1.encode(rtf.toString()));
    }
  });
}
