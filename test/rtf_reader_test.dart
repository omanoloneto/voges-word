import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voges_word/document/delta_blocks.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/headers_footers.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/document/text_encodings.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_numbering.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/docx/word_list_counter.dart';
import 'package:voges_word/editor/page_numbers.dart';
import 'package:voges_word/rtf/rtf_codec.dart';

late TableStore _tables;

LoadedDocument _open(String name) => RtfCodec(
  DocxCodec(_tables),
).decode(File('test/fixtures/rtf/$name').readAsBytesSync());

LoadedDocument _read(String rtf) =>
    RtfCodec(DocxCodec(_tables)).decode(Uint8List.fromList(latin1.encode(rtf)));

List<Operation> _ops(Delta delta) => delta.toList();

Operation _op(Delta delta, String text) => _ops(delta).firstWhere(
  (operation) =>
      operation.data is String && (operation.data as String).contains(text),
);

Map<String, dynamic> _line(Delta delta, String text) {
  final operations = _ops(delta);
  final start = operations.indexWhere(
    (operation) =>
        operation.data is String && (operation.data as String).contains(text),
  );
  expect(start, isNot(-1), reason: text);
  for (var index = start; index < operations.length; index++) {
    final data = operations[index].data;
    if (data is! String) continue;
    final from = index == start ? data.indexOf(text) + text.length : 0;
    if (data.contains('\n', from)) return operations[index].attributes ?? {};
  }
  return const {};
}

String _text(Delta delta) => _ops(
  delta,
).map((operation) => operation.data is String ? operation.data : '').join();

List<T> _embeds<T>(Delta delta, String type) => [
  for (final operation in _ops(delta))
    if (operation.data case final Map<dynamic, dynamic> data
        when data.containsKey(type))
      data[type] as T,
];

TableModel _table(Delta delta) =>
    _tables[tableIdOf(_embeds<Object?>(delta, EmbedTypes.table).first)]!;

String _cellText(TableCellModel cell) => cell.controller.document.toPlainText();

DocxPackage _package(LoadedDocument document) =>
    document.source! as DocxPackage;

/// The numbers Word shows on the document's list paragraphs.
List<String?> _shownNumbers(LoadedDocument document) {
  final counter = WordListCounter(DocxNumbering.of(document.source));
  final numbers = <String?>[];
  for (final line in documentBlocks(document.delta).whereType<LineBlock>()) {
    if (line.list == null) continue;
    counter.count(line);
    numbers.add(counter.textOf(line));
  }
  return numbers;
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// [text] read in [codePage]: without its table each character is replaced
/// instead of misread.
String _chars(int codePage, String text) =>
    isKnownCodePage(codePage) ? text : '\u{FFFD}' * text.length;

Operation _picture(Delta delta) => _ops(delta).firstWhere(
  (operation) => switch (operation.data) {
    {EmbedTypes.image: String _} => true,
    _ => false,
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => _tables = TableStore());

  group('a file from Word', () {
    late LoadedDocument document;
    late Delta delta;

    setUp(() {
      document = _open('word.rtf');
      delta = document.delta;
    });

    test('keeps headings, character formatting and special characters', () {
      expect(_line(delta, 'Relatório Anual')['header'], 1);
      expect(_op(delta, 'negrito').attributes, {'bold': true});
      expect(_op(delta, 'itálico vermelho').attributes, {
        'italic': true,
        'color': '#FF0000',
      });
      expect(_op(delta, 'sublinhado').attributes, {'underline': true});
      expect(_op(delta, 'riscado').attributes, {'strike': true});
      expect(_op(delta, 'marcado').attributes, {'background': '#FFFF00'});
      expect(_op(delta, 'grande').attributes, {'size': '16'});
      expect(_op(delta, 'mono').attributes, {'font': 'Courier New'});
      expect(
        _ops(delta)
            .where((operation) => operation.data == '2')
            .map((operation) => operation.attributes?['script']),
        ['sub', 'super'],
      );
      expect(
        _text(delta),
        contains('\t\u{2014}\u{A0}\u{20AC} \u{1F600}'),
        reason: 'tab, em dash, no-break space, \\uN with fallbacks, pairs',
      );
      expect(_op(delta, 'Привет').attributes, {'font': 'Times New Roman Cyr'});
      expect(_text(delta), contains('\u{2028}linha'));
      expect(_line(delta, 'negrito')['align'], 'justify');
    });

    test('links and fields are kept only when they are safe', () {
      expect(
        _op(delta, 'site').attributes?['link'],
        'https://example.com/a?b=1&c=2',
      );
      expect(_op(delta, 'voltar').attributes?['link'], '#intro');
      expect(_op(delta, 'perigo').attributes?['link'], isNull);
      expect(_text(delta), contains('imagem'));
      final xml = _package(document).text('word/document.xml')!;
      expect(xml, isNot(contains('INCLUDEPICTURE')));
      expect(xml, isNot(contains('javascript')));
      final fields = _embeds<String>(
        delta,
        EmbedTypes.opaqueInline,
      ).map(OpaqueContent.decode).toList();
      expect(fields.map((field) => fieldNameOf(field.xml)), contains('DATE'));
      expect(
        fields.firstWhere((f) => fieldNameOf(f.xml) == 'DATE').text,
        '29/10/2026',
      );
    });

    test('notes stay, comments go and changes are accepted', () {
      final note = _embeds<String>(delta, EmbedTypes.opaqueInline)
          .map(OpaqueContent.decode)
          .firstWhere((content) => content.label == OpaqueLabels.note);
      expect(note.text, '1');
      expect(
        _package(document).text('word/footnotes.xml'),
        contains('Texto da nota.'),
      );
      final text = _text(delta);
      expect(text, contains('comentado'));
      expect(text, isNot(contains('escondido')));
      expect(text, isNot(contains('apagado')));
      expect(text, contains('inserido'));
      expect(
        document.notices,
        containsAll([
          DocumentNotice.commentsHidden,
          DocumentNotice.trackedChangesAccepted,
          DocumentNotice.contentNotImported,
        ]),
      );
    });

    test('bookmarks, including those written for Unicode readers', () {
      expect(
        _line(delta, 'Relatório')[HiddenAttributes.bookmarks],
        jsonEncode(['intro']),
      );
      expect(
        _line(delta, 'inserido')[HiddenAttributes.bookmarks],
        jsonEncode(['Seção']),
      );
    });

    test('lists keep their kind, level and restarts', () {
      expect(_line(delta, 'Primeiro')['list'], 'bullet');
      expect(_line(delta, 'Dentro')['list'], 'bullet');
      expect(_line(delta, 'Dentro')['indent'], 1);
      final one = _line(delta, 'Um');
      final two = _line(delta, 'Dois');
      final five = _line(delta, 'Cinco');
      expect([one['list'], two['list'], five['list']], everyElement('ordered'));
      expect(two[HiddenAttributes.numbering], one[HiddenAttributes.numbering]);
      expect(
        five[HiddenAttributes.numbering],
        isNot(one[HiddenAttributes.numbering]),
      );
      final numbering = _package(document).text('word/numbering.xml')!;
      expect(numbering, contains('<w:startOverride w:val="5"/>'));
      expect(numbering, contains('<w:numFmt w:val="lowerLetter"/>'));
    });

    test('tables keep widths, header rows, merges and shading', () {
      final table = _table(delta);
      expect(table.columnWidths, [2831, 2831, 2832]);
      expect(table.bordered, isTrue);
      expect(table.rows[0].propertiesXml, contains('tblHeader'));
      expect(_cellText(table.rows[0].cells[0]), 'Nome\n');
      final tall = table.rows[0].cells[2];
      expect(tall.verticalMerge, VerticalMerge.restart);
      expect(tall.fill?.toARGB32(), 0xFFD9E2F3);
      expect(table.rows[1].cells, hasLength(2));
      expect(table.rows[1].cells[0].gridSpan, 2);
      expect(_cellText(table.rows[1].cells[0]), 'Largo\n');
      expect(table.rows[1].cells[1].verticalMerge, VerticalMerge.continuation);
    });

    test('pictures, text boxes and objects', () {
      final pictures = [
        for (final operation in _ops(delta))
          if (operation.data case {EmbedTypes.image: final String _}) operation,
      ];
      expect(pictures, hasLength(2));
      expect(pictures.first.attributes?['width'], '72');
      expect(pictures.first.attributes?['height'], '36');
      expect(pictures.last.attributes?['width'], '36');
      expect(
        (pictures.first.data as Map)[EmbedTypes.image],
        startsWith('data:image/png;base64,iVBOR'),
      );
      expect(_text(delta), contains('[planilha]Fim da seção'));
      expect(_text(delta), contains('Caixa de texto\n'));
    });

    test('sections, page setup, headers and footers', () {
      final section = sectionXmlOf(
        _embeds<String>(delta, EmbedTypes.sectionBreak).single,
      );
      expect(section, contains('w:orient="landscape"'));
      expect(section, contains('w:w="16838"'));
      expect(_text(delta), endsWith('Retrato\n'));

      final look = document.look;
      expect(look.pageWidth, closeTo(595.3, 0.1));
      expect(look.pageHeight, closeTo(841.9, 0.1));
      expect(look.margins.left, closeTo(85.05, 0.01));
      expect(look.margins.top, closeTo(70.85, 0.01));
      expect(look.margins.right, closeTo(56.7, 0.01));
      expect(look.body.fontFamily, 'Calibri');
      expect(look.body.fontSize, 11);
      expect(look.body.spaceAfter, 8);
      expect(look.lineSpacing, closeTo(259 / 240, 0.001));
      expect(look.headings[1]?.fontFamily, 'Calibri Light');
      expect(look.headings[1]?.fontSize, 16);
      expect(
        _package(document).text('word/styles.xml'),
        contains('<w:lang w:val="pt-BR"'),
      );

      final stories = document.headersFooters;
      expect(stories.differentFirstPage, isTrue);
      expect(pageNumberPosition(stories), PageNumberPosition.topCenter);
      expect(
        _text(stories.footers[PageVariant.first]!.delta),
        'Rodapé da capa\n',
      );
    });
  });

  group('a file from TextEdit', () {
    test('formatting, lists, links and PostScript font names', () {
      final document = _open('textedit.rtf');
      final delta = document.delta;
      expect(document.look.body.fontFamily, 'Times');
      expect(_op(delta, 'Heading One').attributes, {
        'bold': true,
        'size': '24',
      });
      expect(_op(delta, 'italic').attributes, {'italic': true});
      expect(_op(delta, 'under').attributes?['underline'], isTrue);
      expect(_op(delta, 'strike').attributes?['strike'], isTrue);
      expect(_op(delta, 'red').attributes?['color'], '#B00004');
      expect(_op(delta, 'hl').attributes?['background'], '#FFFF0B');
      expect(
        _op(delta, ' x').attributes?['background'],
        isNull,
        reason: 'TextEdit paints the background white to turn it off',
      );
      expect(_text(delta), contains('ação \u{20AC}'));
      expect(_line(delta, 'one')['list'], 'bullet');
      expect(_line(delta, 'nested')['indent'], 1);
      expect(_line(delta, 'second')['list'], 'ordered');
      expect(
        _op(delta, 'link').attributes?['link'],
        'https://example.com/?a=1&b=2',
      );
      final table = _table(delta);
      expect(table.rows, hasLength(2));
      expect(table.rows[1].cells.single.gridSpan, 2);
      expect(_line(delta, 'centered')['align'], 'center');
    });

    test('nested tables and vertical merges', () {
      final delta = _open('textedit_tables.rtf').delta;
      final table = _table(delta);
      expect(_cellText(table.rows[0].cells[0]), 'outer a\n');
      final nested = table.rows[0].cells[1].controller.document.toDelta();
      final inner = _table(nested);
      expect(_cellText(inner.rows[0].cells[0]), 'inner 1\n');
      expect(table.rows[1].cells[0].verticalMerge, VerticalMerge.restart);
      expect(table.rows[2].cells[0].verticalMerge, VerticalMerge.continuation);
      expect(table.rows[1].cells[0].fill, isNotNull);
      expect(_text(delta), endsWith('end\n'));
    });
  });

  test('WordPad bullets and numbering from before list tables', () {
    final document = _open('wordpad.rtf');
    final delta = document.delta;
    expect(_line(delta, 'um')['list'], 'bullet');
    expect(
      _line(delta, 'dois')[HiddenAttributes.numbering],
      _line(delta, 'um')[HiddenAttributes.numbering],
    );
    expect(_line(delta, 'primeiro')['list'], 'ordered');
    expect(
      _line(delta, 'segundo')[HiddenAttributes.numbering],
      _line(delta, 'primeiro')[HiddenAttributes.numbering],
    );
    expect(_line(delta, 'meio')['list'], isNull);
    expect(_line(delta, 'letra')['list'], 'ordered');
    expect(
      _line(delta, 'letra')[HiddenAttributes.numbering],
      isNot(_line(delta, 'primeiro')[HiddenAttributes.numbering]),
    );
    expect(_line(delta, 'meio')['line-height'], 1.15);
    expect(_text(delta), isNot(contains('\u{B7}')));
    expect(
      _package(document).text('word/numbering.xml'),
      contains('<w:lvlText w:val="%1)"/>'),
    );
  });

  group('text', () {
    test('code pages come from the document and from each font', () {
      expect(
        _text(_read(r"{\rtf1\ansi\ansicpg1251 \'cf\'f0\'e8\par}").delta),
        'При\n',
      );
      expect(_text(_read(r"{\rtf1\mac \'8e\par}").delta), 'é\n');
      expect(_text(_read(r"{\rtf1\pc \'82\par}").delta), 'é\n');
      expect(
        _text(
          _read(
            r"{\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}{\f1\fcharset161 Greek;}}"
            r"\'e1 {\f1 \'e1}\par}",
          ).delta,
        ),
        'á α\n',
      );
    });

    test('Chinese, Japanese and Korean text in double-byte code pages', () {
      // TextEdit writes each byte as \'hh; Word writes a trail byte that is
      // ASCII as it is.
      final fonts = _read(
        r"{\rtf1\ansi\ansicpg1252{\fonttbl{\f0\fnil\fcharset128 Hiragino;}"
        r"{\f1\fnil\fcharset136 PMingLiU;}}\f0 \'82\'b1\'82\'f1\'82\'c9\'82"
        r"\'bf\'82\'cd \'83A\'b1 {\f1 \'bc\'d0\'c3D}\par}",
      );
      // Raw bytes: the last character's lead byte ends a text token.
      final document = _read(
        r"{\rtf1\ansi\ansicpg932{\fonttbl{\f0 MS Mincho;}}\f0 \'93\'fa\'96"
        r"\'7b"
        '\x82\xb1\x82'
        r"\'f1\par}",
      );
      expect(
        _text(fonts.delta),
        '${_chars(932, 'こんにちは')} ${_chars(932, 'ア')}ｱ '
        '${_chars(950, '標題')}\n',
      );
      expect(_text(document.delta), '${_chars(932, '日本こん')}\n');
      expect(
        [...fonts.notices, ...document.notices],
        isKnownCodePage(932) && isKnownCodePage(950)
            ? isEmpty
            : contains(DocumentNotice.contentNotImported),
      );
      final unicode = _read(
        r"{\rtf1\ansi\ansicpg932{\fonttbl{\f0\fcharset128 MS Mincho;}}\f0"
        r"\uc2 \u"
        r"26085\'93\'fa\u"
        r"26412\'96\'7b\par}",
      );
      expect(_text(unicode.delta), '日本\n');
      expect(unicode.notices, isEmpty);

      // Word on these systems writes font names in their code page, with
      // another name in \falt.
      final names = _read(
        r"{\rtf1\ansi\ansicpg950{\fonttbl{\f0 Times New Roman;}{\f1"
        r"\fcharset136 \'b7\'73\'b2\'d3\'a9\'fa\'c5\'e9{\*\falt PMingLiU};}}"
        r"\f0 x{\f1\uc2 \u"
        r"27161\'bc\'d0}\par}",
      );
      expect(
        _op(names.delta, '標').attributes?['font'],
        isKnownCodePage(950) ? '新細明體' : 'PMingLiU',
      );
      expect(names.notices, isEmpty);
    });

    test('list level text in a double-byte code page', () {
      final document = _read(
        r"{\rtf1\ansi\ansicpg950{\*\listtable{\list\listid1{\listlevel"
        r"\levelnfc0{\leveltext\'02\'00\'a1B;}{\levelnumbers\'01;}}}}"
        r"{\*\listoverridetable{\listoverride\listid1\ls1}}\pard\ls1 one\par}",
      );
      expect(
        _package(document).text('word/numbering.xml'),
        contains('<w:lvlText w:val="%1${_chars(950, '、')}"/>'),
      );

      // Word 2010 in Taiwan: the default font is Western, the level text is
      // still in Big5.
      final heading = _read(
        r"{\rtf1\ansi\ansicpg950\deff0{\fonttbl{\f0\froman\fcharset0 Times "
        r"New Roman;}}{\*\listtable{\list\listid1{\listlevel\levelnfc0"
        r"\levelfollow1{\leveltext"
        "\r\n"
        r"\'05\'b2\'c4 \'00 \'b3\'b9;}{\levelnumbers\'03;}}}}"
        r"{\*\listoverridetable{\listoverride\listid1\ls1}}\pard\ls1 Test\par}",
      );
      expect(
        _package(heading).text('word/numbering.xml'),
        contains(
          '<w:lvlText w:val="${_chars(950, '第')} %1 ${_chars(950, '章')}"/>',
        ),
      );
    });

    test(r'\uc says how many fallback characters follow \u', () {
      expect(
        _text(
          _read(
            r"{\rtf1\uc2 \u233\'65\'66x{\uc0\u233 y}\u233 abz"
            r"{\u-3913 ?}\u"
            r"20320\'3f\'3f\par}",
          ).delta,
        ),
        'éxéyéz\u{F0B7}你\n',
      );
    });

    test('special characters and breaks', () {
      final delta = _read(
        r'{\rtf1 a\~b\-c\_d\emdash\endash\bullet\lquote\rquote\ldblquote'
        r'\rdblquote \{\}\\ e\line f\page g\tab h\par}',
      ).delta;
      expect(
        _text(delta),
        'a\u{A0}b\u{AD}c\u{2011}d\u{2014}\u{2013}\u{2022}\u{2018}\u{2019}'
        '\u{201C}\u{201D}{}\\ e\u{2028}fg\th\n',
      );
      expect(_embeds<Object?>(delta, EmbedTypes.pageBreak), hasLength(1));
    });

    test(r'\plain, \pard and groups restore the formatting', () {
      final delta = _read(
        r'{\rtf1 {\b bold \i both}\b\fs32 big \plain normal\par'
        r'\qc centered\par\pard left\par}',
      ).delta;
      expect(_op(delta, 'bold').attributes, {'bold': true});
      expect(_op(delta, 'both').attributes, {'bold': true, 'italic': true});
      expect(_op(delta, 'big').attributes, {'bold': true, 'size': '16'});
      expect(_op(delta, 'normal').attributes, isNull);
      expect(_line(delta, 'centered')['align'], 'center');
      expect(_line(delta, 'left')['align'], isNull);
    });

    test('hidden text, capitals, underlines and strikes', () {
      final delta = _read(
        r'{\rtf1 a{\v secret}b {\caps up}{\ulth thick}{\striked1 two}'
        r'{\ul x\ulnone y}\par}',
      ).delta;
      final hidden = _embeds<String>(
        delta,
        EmbedTypes.opaqueInline,
      ).map(OpaqueContent.decode).single;
      expect(hidden.hidden, isTrue);
      expect(
        _op(delta, 'up').attributes?[HiddenAttributes.runProperties],
        contains('<w:caps/>'),
      );
      expect(_op(delta, 'thick').attributes?['underline'], isTrue);
      expect(_op(delta, 'two').attributes?['strike'], isTrue);
      expect(_op(delta, 'x').attributes?['underline'], isTrue);
      expect(_op(delta, 'y').attributes?['underline'], isNull);
    });

    test('unknown control words are ignored; unknown destinations hidden', () {
      expect(
        _text(
          _read(r'{\rtf1 a\foo b{\*\bar hidden}c{\info{\title t}}\par}').delta,
        ),
        'abc\n',
      );
    });

    test('a deleted paragraph mark joins the paragraphs', () {
      final document = _read(r'{\rtf1 one{\deleted\par}two\par}');
      expect(_text(document.delta), 'onetwo\n');
      expect(document.notices, [DocumentNotice.trackedChangesAccepted]);
    });
  });

  group('paragraphs', () {
    test('spacing, indents, line spacing, tabs and keeps', () {
      final delta = _read(
        r'{\rtf1 \pard\li1440\ri720\fi-360\sb120\sa240\sl480\slmult1'
        r'\keepn\tqr\tldot\tx9000 double\par'
        r'\pard\sl-360\slmult0 exact\par}',
      ).delta;
      final double = _line(delta, 'double');
      expect(double['indent'], 2);
      expect(double['line-height'], 2);
      expect(double[HiddenAttributes.spaceBefore], 6);
      expect(double[HiddenAttributes.spaceAfter], 12);
      expect(double[HiddenAttributes.indentRight], 36);
      expect(double[HiddenAttributes.firstLine], -18);
      final properties = double[HiddenAttributes.paragraphProperties] as String;
      expect(properties, contains('<w:keepNext/>'));
      expect(properties, contains('w:val="right" w:leader="dot" w:pos="9000"'));
      expect(
        _line(delta, 'exact')[HiddenAttributes.paragraphProperties],
        contains('w:line="360" w:lineRule="exact"'),
      );
    });

    test('styles: Unicode copies of names, aliases and outline levels', () {
      final document = _read(
        r'{\rtf1{\stylesheet{\fs20 Normal;}'
        r'{\upr{\s1\fs32\b heading 1;}{\*\ud{\s1\fs32\b heading 1,T\u237?tulo;}}}'
        r'{\s2\outlinelevel1\fs28\b \sbasedon0 \u220?berschrift 2;}}'
        r'\pard\s1\fs32\b One\par\pard\s2\fs28\b Two\par\pard\fs20 Body\par}',
      );
      expect(_line(document.delta, 'One')['header'], 1);
      expect(_line(document.delta, 'Two')['header'], 2);
      expect(_op(document.delta, 'One').attributes, isNull);
      expect(document.look.body.fontSize, 10);
      expect(document.look.headings[1]?.fontSize, 16);
      expect(document.look.headings[1]?.bold, isTrue);
      expect(document.look.headings[2]?.fontSize, 14);
    });

    test('an outline level without a heading style makes a heading', () {
      final delta = _read(r'{\rtf1 \pard\outlinelevel1 Two\par}').delta;
      expect(_line(delta, 'Two')['header'], 2);
    });

    test('page size, orientation, margins and language', () {
      final document = _read(
        r'{\rtf1\deflang1036 \paperw12240\paperh15840\landscape'
        r'\margl99999\margr99999 x\par}',
      );
      expect(document.look.pageWidth, 792);
      expect(document.look.pageHeight, 612);
      expect(document.look.margins.left, lessThan(200));
      expect(
        _package(document).text('word/styles.xml'),
        contains('<w:lang w:val="fr-FR"'),
      );
    });

    test('sections start where they say', () {
      final delta = _read(
        r'{\rtf1 \sectd\sbknone one\sect\sectd\sbkodd two\par}',
      ).delta;
      final section = sectionXmlOf(
        _embeds<String>(delta, EmbedTypes.sectionBreak).single,
      );
      expect(section, contains('<w:type w:val="continuous"/>'));
    });

    test('sections number their pages as they say', () {
      final document = _read(
        r'{\rtf1 \sectd\pgnlcrm\pgnstarts5 preface\sect'
        r'\sectd\pgnrestart chapter\sect'
        r'\sectd\pgnrestart\pgnstarts9\pgncont continued\sect'
        r'\sectd\pgnucltr\pgnrestart\pgnstarts3 appendix\par}',
      );
      final sections = [
        for (final section in _embeds<String>(
          document.delta,
          EmbedTypes.sectionBreak,
        ))
          sectionXmlOf(section),
      ];

      expect(sections, hasLength(3));
      expect(sections[0], contains('<w:pgNumType w:fmt="lowerRoman"/>'));
      expect(sections[1], contains('<w:pgNumType w:start="1"/>'));
      expect(sections[2], isNot(contains('pgNumType')));
      expect(
        _package(document).text('word/document.xml'),
        contains('<w:pgNumType w:fmt="upperLetter" w:start="3"/>'),
      );
    });

    test(r'a \sect at the end adds no empty section', () {
      final document = _read(
        r'{\rtf1 \sectd\lndscpsxn\pgwsxn15840\pghsxn12240 Last page text\par'
        r'\sect\sectd}',
      );
      expect(
        _embeds<Object?>(document.delta, EmbedTypes.sectionBreak),
        isEmpty,
      );
      expect(_text(document.delta), 'Last page text\n');
      expect(document.look.pageWidth, 792);
    });

    test('headers and footers of earlier sections', () {
      final changed = _read(
        r'{\rtf1\sectd{\header\pard\plain Chapter One header\par}\pard Chapter'
        r' one text\par\sect\sectd{\header\pard\plain Chapter Two header\par}'
        r'\pard Chapter two text\par}',
      );
      expect(
        _text(changed.headersFooters.headers[PageVariant.normal]!.delta),
        'Chapter Two header\n',
      );
      expect(changed.notices, [DocumentNotice.contentNotImported]);

      final repeated = _read(
        r'{\rtf1\sectd{\header\pard\plain Same\par}{\footer\pard\plain Early'
        r' footer\par}\pard one\par\sect\sectd{\header\pard\plain Same\par}'
        r'\pard two\par}',
      );
      expect(
        _text(repeated.headersFooters.headers[PageVariant.normal]!.delta),
        'Same\n',
      );
      expect(
        _text(repeated.headersFooters.footers[PageVariant.normal]!.delta),
        'Early footer\n',
      );
      expect(repeated.notices, isEmpty);
    });

    test('a drop cap stays the first letter of its paragraph', () {
      final delta = _read(
        r'{\rtf1 {\pard\pvpara\phpg\posx1000\dropcapli3\dropcapt1\fs96 T\par}'
        r'\pard he rest of the paragraph\par}',
      ).delta;
      expect(_text(delta), 'The rest of the paragraph\n');
    });

    test(r'numbering from \pn when \ls names no list', () {
      final delta = _read(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}{\f2 Symbol;}}'
        r'\pard{\pntext\f2 1.\tab}{\*\pn\pnlvlbody\pnstart1\pndec\ls3\ilvl0'
        r'\pnhang{\pntxta .}}\ls3\ilvl0\fi-360\li360 One\par'
        r'{\pntext\f2 2.\tab}Two\par}',
      ).delta;
      expect(_line(delta, 'One')['list'], 'ordered');
      expect(
        _line(delta, 'Two')[HiddenAttributes.numbering],
        _line(delta, 'One')[HiddenAttributes.numbering],
      );
    });

    test(r'\pnlvlcont paragraphs continue the numbering', () {
      final delta = _read(
        r'{\rtf1 \pard{\*\pn\pnlvlbody\pndec{\pntxta .}}one\par'
        r'\pard{\*\pn\pnlvlcont}continued\par'
        r'\pard{\*\pn\pnlvlbody\pndec{\pntxta .}}two\par}',
      ).delta;
      expect(_line(delta, 'continued')['list'], isNull);
      expect(
        _line(delta, 'two')[HiddenAttributes.numbering],
        _line(delta, 'one')[HiddenAttributes.numbering],
      );
    });

    test(r'\levelfollow says what follows the number', () {
      final document = _read(
        r'{\rtf1{\*\listtable{\list\listtemplateid1'
        r"{\listlevel\levelnfc0\levelfollow1{\leveltext\'02\'00.;}"
        r"{\levelnumbers\'01;}\fi-360\li720}"
        r"{\listlevel\levelnfc4\levelfollow2{\leveltext\'02\'01);}"
        r"{\levelnumbers\'01;}\fi-360\li1440}"
        r"{\listlevel\levelnfc2\levelfollow0{\leveltext\'02\'02.;}"
        r"{\levelnumbers\'01;}\fi-360\li2160}"
        r'\listid1}}'
        r'{\*\listoverridetable{\listoverride\listid1\listoverridecount0\ls1}}'
        r'\pard\ls1 one\par\pard\ls1\ilvl1 two\par\pard\ls1\ilvl2 three\par}',
      );
      final numbering = _package(document).text('word/numbering.xml')!;
      String level(int index) => RegExp(
        '<w:lvl w:ilvl="$index">(.*?)</w:lvl>',
      ).firstMatch(numbering)![1]!;

      expect(_line(document.delta, 'two')['list'], 'ordered');
      expect(level(0), contains('<w:suff w:val="space"/>'));
      expect(level(1), contains('<w:suff w:val="nothing"/>'));
      expect(level(2), isNot(contains('<w:suff')));
    });

    test(r'list levels keep \levellegal and \leveljc', () {
      final document = _read(
        r'{\rtf1{\*\listtable{\list\listtemplateid1'
        r'{\listlevel\levelnfc1\leveljc1\leveljcn1\levelstartat1'
        r"{\leveltext\'04CH \'00;}{\levelnumbers\'04;}\fi0\li0}"
        r'{\listlevel\levelnfc22\leveljc0\leveljcn2\levelstartat1\levellegal'
        r"{\leveltext\'08Sect \'00.\'01;}{\levelnumbers\'06\'08;}\fi720\li0}"
        r'{\listlevel\levelnfc4\leveljc2\levelstartat1\levellegal0'
        r"{\leveltext\'02\'02);}{\levelnumbers\'01;}\fi-360\li1440}"
        r'\listid1297755732}}'
        r'{\*\listoverridetable{\listoverride\listid1297755732'
        r'\listoverridecount0\ls1}}'
        r'\pard\ls1 Chapter\par\pard\ls1\ilvl1 Foo\par\pard\ls1\ilvl1 Bar\par'
        r'\pard\ls1\ilvl2 Item\par}',
      );
      final numbering = _package(document).text('word/numbering.xml')!;
      String level(int index) => RegExp(
        '<w:lvl w:ilvl="$index">(.*?)</w:lvl>',
      ).firstMatch(numbering)![1]!;

      expect(level(0), isNot(contains('isLgl')));
      expect(level(0), contains('<w:lvlJc w:val="center"/>'));
      // \leveljcn, which follows the paragraph's direction, wins.
      expect(
        level(1),
        contains(
          '<w:numFmt w:val="decimalZero"/><w:isLgl/>'
          '<w:lvlText w:val="Sect %1.%2"/><w:lvlJc w:val="right"/>',
        ),
      );
      expect(level(2), isNot(contains('isLgl')));
      expect(level(2), contains('<w:lvlJc w:val="right"/>'));
      expect(_shownNumbers(document), ['CH I', 'Sect 1.01', 'Sect 1.02', 'a)']);
    });

    test(r'the \ls of one list count as one list, as in Word', () {
      final document = _read(
        r'{\rtf1{\*\listtable{\list\listtemplateid1{\listlevel\levelnfc0'
        r"\levelstartat1{\leveltext\'02\'00.;}{\levelnumbers\'01;}\fi-360"
        r'\li720}\listid7}}{\*\listoverridetable'
        r'{\listoverride\listid7\listoverridecount0\ls1}'
        r'{\listoverride\listid7\listoverridecount0\ls2}'
        r'{\listoverride\listid7\listoverridecount1{\lfolevel'
        r'\listoverridestartat\levelstartat1}\ls3}}'
        r'\pard\ls1 one\par\pard\ls1 two\par\pard between\par'
        r'\pard\ls2 three\par\pard\ls3 again\par\pard\ls1 on\par}',
      );
      final numbering = _package(document).text('word/numbering.xml')!;

      expect(RegExp('<w:abstractNum ').allMatches(numbering), hasLength(1));
      expect(
        numbering,
        contains(
          '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/>'
          '</w:lvlOverride>',
        ),
      );
      // \ls3 starts again at 1 where it starts; \ls1 then counts on from it.
      expect(_shownNumbers(document), ['1.', '2.', '3.', '1.', '2.']);
    });

    test(r"\ilvl9, Word's body text, and above put a paragraph in no list", () {
      final numbered = [
        for (var level = 0; level < 8; level++)
          r'{\listlevel\levelnfc0\levelstartat1'
              "{\\leveltext\\'02\\'0$level.;}}",
      ].join();
      final document = _read(
        r'{\rtf1{\stylesheet{\s1\ls1 Listed;}}{\*\listtable{\list'
        '$numbered'
        r"{\listlevel\levelnfc255\levelstartat1{\leveltext\'00;}}\listid1}}"
        r'{\*\listoverridetable{\listoverride\listid1\listoverridecount0\ls1}}'
        r'\pard\ls1 one\par\pard\ls1\ilvl9 body\par'
        r'\pard\ls1\ilvl12 skipped\par\pard\ls1\ilvl1 two\par'
        r'\pard\s1\ls1\ilvl9 styled\par\pard\s1 listed\par}',
      );

      for (final text in ['body', 'skipped', 'styled']) {
        final line = _line(document.delta, text);
        expect(line['list'], isNull, reason: text);
        expect(line[HiddenAttributes.numbering], isNull, reason: text);
      }
      // They don't count, so 'two' is the first item of its level.
      expect(_shownNumbers(document), ['1.', '1.', '2.']);
    });

    test('headers for left and right pages', () {
      final document = _read(
        r'{\rtf1\facingp {\headerr odd\par}{\headerl even\par}body\par}',
      );
      final stories = document.headersFooters;
      expect(stories.differentOddEven, isTrue);
      expect(_text(stories.headers[PageVariant.even]!.delta), 'even\n');
      expect(_text(stories.headers[PageVariant.normal]!.delta), 'odd\n');
      expect(_text(document.delta), 'body\n');
    });
  });

  group('fields', () {
    test('a field without a result and old page numbers', () {
      final document = _read(
        r'{\rtf1 {\header \qr\chpgn\par}{\field{\*\fldinst NUMPAGES}} x\par}',
      );
      final names = _embeds<String>(
        document.delta,
        EmbedTypes.opaqueInline,
      ).map((data) => fieldNameOf(OpaqueContent.decode(data).xml));
      expect(names, ['NUMPAGES']);
      expect(
        pageNumberPosition(document.headersFooters),
        PageNumberPosition.topRight,
      );
    });

    test('hyperlink switches', () {
      final delta = _read(
        r'{\rtf1 {\field{\*\fldinst {HYPERLINK "http://x.com/a" \\o "tip"'
        r' \\t "_blank"}}{\fldrslt one}}'
        r'{\field{\*\fldinst HYPERLINK "http://x.com" \\l "part"}'
        r'{\fldrslt two}}{\field{\*\fldinst HYPERLINK "file:///etc/passwd"}'
        r'{\fldrslt three}}\par}',
      ).delta;
      expect(_op(delta, 'one').attributes?['link'], 'http://x.com/a');
      expect(_op(delta, 'two').attributes?['link'], 'http://x.com#part');
      expect(_op(delta, 'three').attributes?['link'], isNull);
    });

    test('contents and cross-references keep the bookmarks they point at', () {
      final document = _read(
        r'{\rtf1 {\field{\*\fldinst TOC \\o "1-3" \\h}{\fldrslt '
        r'{\field{\*\fldinst HYPERLINK \\l "_Toc100"}{\fldrslt Intro}}\par}}'
        r'\pard {\*\bkmkstart _Toc100}Intro{\*\bkmkend _Toc100}\par'
        r'\pard See {\field{\*\fldinst PAGEREF _Toc100 \\h}{\fldrslt 1}} and '
        r'{\field{\*\fldinst REF _Ref200 \\h}{\fldrslt Table 1}}\par'
        r'\pard {\*\bkmkstart _Ref200}Table 1{\*\bkmkend _Ref200}\par}',
      );
      final saved = DocxPackage.decode(
        DocxCodec(_tables).encode(document.delta, source: document.source),
      ).text('word/document.xml')!;
      expect(saved, contains('w:anchor="_Toc100"'));
      expect(saved, contains('PAGEREF _Toc100'));
      expect(saved, contains('REF _Ref200'));
      // Each bookmark covers the text that REF shows.
      for (final (name, text) in [
        ('_Toc100', 'Intro'),
        ('_Ref200', 'Table 1'),
      ]) {
        expect(
          saved,
          matches(
            RegExp(
              'w:name="$name"/><w:r><w:t[^>]*>$text</w:t></w:r>'
              '<w:bookmarkEnd',
            ),
          ),
        );
      }
    });

    test('a result over several paragraphs keeps its paragraphs', () {
      final delta = _read(
        r'{\rtf1 {\field{\*\fldinst TOC \\o "1-3"}{\fldrslt one\par two}}'
        r'\par}',
      ).delta;
      expect(_text(delta), 'one\ntwo\n');
    });
  });

  group('notes and shapes', () {
    test(r'endnotes by \ftnalt or by \fet1', () {
      final alternate = _read(r'{\rtf1 a{\footnote\ftnalt \pard end\par}\par}');
      expect(_package(alternate).text('word/endnotes.xml'), contains('end'));
      final endnotes = _read(r'{\rtf1\fet1 a{\footnote \pard note\par}\par}');
      expect(_package(endnotes).text('word/endnotes.xml'), contains('note'));
    });

    test(r'\ftnalt marks an endnote whatever \fet says', () {
      final package = _package(
        _read(
          r'{\rtf1\ansi\aenddoc\fet1 Body{\super \chftn{\*\footnote\ftnalt '
          r'\chftn\pard\plain Endnote text.}}\par}',
        ),
      );
      expect(package.text('word/endnotes.xml'), contains('Endnote text.'));
      expect(package.text('word/footnotes.xml'), isNull);
    });

    test('pictures inside grouped shapes are kept', () {
      final png = _hex(img.encodePng(img.Image(width: 1, height: 1)));
      // LibreOffice's fdo89496.rtf has GIF data in its \pngblip.
      final gif = _hex(img.encodeGif(img.Image(width: 1, height: 1)));
      final document = _read(
        '{\\rtf1 {\\shpgrp{\\*\\shpinst{\\shp{\\*\\shpinst{\\sp{\\sn shapeType}'
        '{\\sv 75}}{\\sp{\\sn pib}{\\sv {\\pict\\pngblip\\picw1\\pich1 $png}}}}}'
        '{\\shp{\\*\\shpinst{\\sp{\\sn pib}{\\sv {\\pict\\pngblip $gif}}}}}'
        '}}Text\\par}',
      );
      expect(_embeds<Object?>(document.delta, EmbedTypes.image), hasLength(2));
      expect(_text(document.delta), 'Text\n');
      expect(document.notices, isEmpty);
      final nowhere = _read(
        '{\\rtf1 {\\field{\\*\\fldinst {\\pict\\pngblip $png}}{\\fldrslt x}}'
        '\\par}',
      );
      expect(nowhere.notices, [DocumentNotice.contentNotImported]);
    });

    test('text boxes with more than text and drawings are not imported', () {
      final document = _read(
        r'{\rtf1 a{\shp{\*\shpinst{\shptxt \pard\intbl x\cell\row}}}b'
        r'{\*\do\dobxcolumn} c{\shp{\*\shpinst}}\par}',
      );
      expect(_text(document.delta), 'ab c\n');
      expect(document.notices, [DocumentNotice.contentNotImported]);
    });
  });

  group('tables', () {
    test('nested tables written the way Word writes them', () {
      final delta = _read(
        r'{\rtf1 \trowd\cellx3000\cellx6000\pard\intbl a\cell'
        r'\pard\intbl\itap2 in1\nestcell in2\nestcell'
        r'{\*\nesttableprops\trowd\cellx1000\cellx2000\nestrow}'
        r'{\nonesttables\par}\pard\intbl after\cell\row\pard end\par}',
      ).delta;
      final table = _table(delta);
      expect(table.rows.single.cells, hasLength(2));
      final cell = table.rows.single.cells[1].controller.document.toDelta();
      final inner = _table(cell);
      expect(inner.columnWidths, [1000, 1000]);
      expect(_cellText(inner.rows.single.cells[1]), 'in2\n');
      expect(_text(cell), endsWith('after\n'));
      expect(_text(delta), endsWith('end\n'));
    });

    test(r'a paragraph without \intbl in an unfinished row stays in it', () {
      final delta = _read(
        r'{\rtf1 before\par\trowd\cellx3000\cellx6000\cellx9000'
        r'\pard\intbl A1\cell B1\cell\pard C1\par\pard\intbl \cell'
        r'\pard\intbl{\trowd\cellx3000\cellx6000\cellx9000\row}\pard after\par}',
      ).delta;
      expect(_embeds<Object?>(delta, EmbedTypes.table), hasLength(1));
      expect(_table(delta).rows.single.cells.map(_cellText), [
        'A1\n',
        'B1\n',
        'C1\n\n',
      ]);
      expect(_text(delta), 'before\n\nafter\n');
    });

    test(r'cells without a \cellx share the width of the row', () {
      final delta = _read(
        r'{\rtf1 \trowd\cellx9000\pard\intbl A\cell B\cell C\cell D\cell\row'
        r'\pard after\par}',
      ).delta;
      expect(_table(delta).columnWidths, [2250, 2250, 2250, 2250]);
    });

    test(r'cells of rows with their own \trleft line up with the others', () {
      final delta = _read(
        r'{\rtf1 \trowd\trleft0\cellx2000\cellx4000\pard\intbl a\cell b\cell'
        r'\row\trowd\trleft1000\cellx3000\cellx5000\pard\intbl c\cell d\cell'
        r'\row\pard after\par}',
      ).delta;
      final table = _table(delta);
      expect(table.columnWidths, [2000, 1000, 1000, 1000]);
      expect(table.rows[0].cells.map((cell) => cell.gridSpan), [1, 2]);
      expect(table.rows[1].cells.map((cell) => cell.gridSpan), [2, 2]);
    });

    test('rows without cell definitions or with too many of them', () {
      final delta = _read(
        r'{\rtf1 \pard\intbl a\cell b\cell\row'
        r'\trowd\cellx1000\cellx2000\cellx3000 \pard\intbl c\cell\row'
        r'\pard after\par}',
      ).delta;
      final table = _table(delta);
      expect(table.rows, hasLength(2));
      expect(table.rows[0].cells.map(_cellText), ['a\n', 'b\n']);
      expect(_text(delta), endsWith('after\n'));
    });
  });

  group('pictures', () {
    test('binary data, metafiles and bitmaps', () {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      );
      // A metafile that draws in a 200 x 100 window.
      final wmf = Uint8List(44);
      ByteData.sublistView(wmf)
        ..setUint16(0, 1, Endian.little)
        ..setUint16(2, 9, Endian.little)
        ..setUint16(4, 0x300, Endian.little)
        ..setUint32(6, 22, Endian.little)
        ..setUint32(12, 5, Endian.little)
        ..setUint32(18, 5, Endian.little)
        ..setUint16(22, 0x020B, Endian.little)
        ..setUint32(28, 5, Endian.little)
        ..setUint16(32, 0x020C, Endian.little)
        ..setInt16(34, 100, Endian.little)
        ..setInt16(36, 200, Endian.little)
        ..setUint32(38, 3, Endian.little);
      // One red pixel, 24 bits.
      final dib = Uint8List(44);
      ByteData.sublistView(dib)
        ..setUint32(0, 40, Endian.little)
        ..setInt32(4, 1, Endian.little)
        ..setInt32(8, 1, Endian.little)
        ..setUint16(12, 1, Endian.little)
        ..setUint16(14, 24, Endian.little)
        ..setUint32(20, 4, Endian.little)
        ..setUint8(42, 0xFF);
      String hex(Uint8List bytes) =>
          bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      final document = RtfCodec(DocxCodec(_tables)).decode(
        Uint8List.fromList([
          ...latin1.encode(r'{\rtf1 {\pict\pngblip\picwgoal720\pichgoal720'),
          ...latin1.encode('\\bin${png.length} '),
          ...png,
          ...latin1.encode(
            '}{\\pict\\wmetafile8\\picw5080\\pich2540\\picwgoal2880'
            '\\pichgoal1440 ${hex(wmf)}}{\\pict\\dibitmap0\\picw1\\pich1 ${hex(dib)}}'
            r'{\pict\wbitmap0\wbmbitspixel1\wbmplanes1\wbmwidthbytes2'
            r'\picw8\pich1 ff00}\par}',
          ),
        ]),
      );
      final package = _package(document);
      final media = package.parts.keys
          .where((name) => name.startsWith('word/media/'))
          .toList();
      expect(media.map((name) => name.split('.').last), [
        'png',
        'wmf',
        'bmp',
        'bmp',
      ]);
      final placeable = package.parts[media[1]]!;
      expect(placeable.sublist(0, 4), [0xD7, 0xCD, 0xC6, 0x9A]);
      expect(placeable.sublist(10, 14), [200, 0, 100, 0]);
      expect(package.parts[media[2]]!.sublist(0, 2), [0x42, 0x4D]);
      expect(package.parts[media[3]]!.length, 14 + 40 + 8 + 4);
      expect(document.notices, isEmpty);
    });

    test('cropped pictures show only what is left, at its size', () {
      final png = img.encodePng(img.Image(width: 4, height: 4));
      final cropped = _picture(
        _read(
          '{\\rtf1 {\\pict\\pngblip\\picw4\\pich4\\picwgoal1440\\pichgoal1440'
          '\\piccropl720\\piccropb720 ${_hex(png)}}\\par}',
        ).delta,
      );
      expect(cropped.attributes?['width'], '36');
      expect(cropped.attributes?['height'], '36');
      final source = (cropped.data as Map)[EmbedTypes.image] as String;
      final picture = img.decodePng(base64Decode(source.split(',').last))!;
      expect([picture.width, picture.height], [2, 2]);

      // Metafiles can't be cut: the whole picture shows, not stretched.
      final wmf = Uint8List(44);
      ByteData.sublistView(wmf)
        ..setUint16(0, 1, Endian.little)
        ..setUint16(2, 9, Endian.little)
        ..setUint16(4, 0x300, Endian.little)
        ..setUint32(6, 22, Endian.little)
        ..setUint32(18, 3, Endian.little);
      final whole = _package(
        _read(
          '{\\rtf1 {\\pict\\wmetafile8\\picw5080\\pich2540\\picwgoal2880'
          '\\pichgoal1440\\piccropl1440 ${_hex(wmf)}}\\par}',
        ),
      ).text('word/document.xml')!;
      expect(whole, contains('<wp:extent cx="1828800" cy="914400"/>'));
    });

    test('pictures that cannot be shown are reported', () {
      final document = _read(
        r'{\rtf1 {\pict\macpict 0011}{\pict\pngblip 00112233}\par}',
      );
      expect(_embeds<Object?>(document.delta, EmbedTypes.image), isEmpty);
      expect(document.notices, [DocumentNotice.contentNotImported]);
    });
  });
}
