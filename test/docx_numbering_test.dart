import 'dart:convert';

import 'package:archive/archive.dart';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/delta_blocks.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_numbering.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/docx/docx_template.dart';
import 'package:voges_word/docx/word_list_counter.dart';
import 'package:voges_word/docx/word_xml.dart';
import 'package:voges_word/html/html_codec.dart';
import 'package:voges_word/html/markdown_codec.dart';
import 'package:voges_word/odt/odt_codec.dart';
import 'package:voges_word/rtf/rtf_codec.dart';
import 'package:xml/xml.dart';

XmlDocument _numbering(String content) => XmlDocument.parse(
  '<w:numbering xmlns:w="${Namespaces.w}">$content</w:numbering>',
);

String _level(
  int level,
  String format,
  String text, {
  int start = 1,
  String extra = '',
}) =>
    '<w:lvl w:ilvl="$level"><w:start w:val="$start"/>'
    '<w:numFmt w:val="$format"/>$extra<w:lvlText w:val="$text"/></w:lvl>';

String _list(int numId, int abstractId, [String overrides = '']) =>
    '<w:num w:numId="$numId"><w:abstractNumId w:val="$abstractId"/>'
    '$overrides</w:num>';

LineBlock _item(int? numId, {int level = 0, String list = 'ordered'}) =>
    LineBlock(const [], {
      'list': list,
      if (level > 0) 'indent': level,
      HiddenAttributes.numbering: ?numId,
    });

/// A .docx package whose body is [body] and whose numbering part is
/// [numbering].
DocxPackage _package(String body, String numbering) => newDocumentPackage()
  ..setText(
    'word/document.xml',
    '<w:document xmlns:w="${Namespaces.w}"><w:body>$body'
        '<w:sectPr/></w:body></w:document>',
  )
  ..addRelationships('word/document.xml', const [
    Relationship(
      id: 'rIdNumbering',
      type: RelationshipTypes.numbering,
      target: 'numbering.xml',
    ),
  ])
  ..setText('word/numbering.xml', numbering);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the numbering part', () {
    test('a list keeps what it overrides apart from its abstract list', () {
      final numbering = DocxNumbering.parse(
        _numbering(
          '<w:abstractNum w:abstractNumId="3">${_level(0, 'decimal', '%1.')}'
          '${_level(1, 'lowerLetter', '%2)')}</w:abstractNum>'
          '${_list(1, 3)}${_list(2, 3, '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="5"/></w:lvlOverride>')}'
          '${_list(3, 3, '<w:lvlOverride w:ilvl="1">${_level(1, 'upperRoman', '(%2)', start: 4)}</w:lvlOverride>')}'
          '${_list(4, 3, '<w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="0"><w:start w:val="7"/></w:lvl></w:lvlOverride>')}'
          '${_list(5, 3)}',
        ),
      );

      expect(numbering.level(1, 0)!.start, 1);
      expect(numbering.level(2, 0)!.start, 5);
      expect(numbering.level(2, 1)!.text, '%2)');
      expect(numbering.level(3, 1)!.format, 'upperRoman');
      expect(numbering.level(3, 1)!.start, 4);
      expect(numbering.level(3, 0)!.text, '%1.');
      expect(numbering.level(1, 2), isNull);
      // Word takes a redefined level whole, not over the abstract one.
      expect(numbering.level(4, 0)!.text, '');
      expect(numbering.level(4, 0)!.start, 7);
      expect(numbering.restarts(2, 0), isTrue);
      expect(numbering.restarts(2, 1), isFalse);
      expect(numbering.restarts(1, 0), isFalse);
      expect(numbering.groupOf(2), numbering.groupOf(1));
      expect(numbering.groupOf(3), numbering.groupOf(1));
      expect(numbering.sameNumbering(5), numbering.sameNumbering(1));
      expect(numbering.sameNumbering(2), isNot(numbering.sameNumbering(1)));
      expect(numbering.sameNumbering(3), isNot(numbering.sameNumbering(1)));
      expect(numbering.maxAbstractId, 3);
      expect(numbering.maxNumId, 5);
    });

    test('levels keep what Word shows of them', () {
      final numbering = DocxNumbering.parse(
        _numbering(
          '<w:abstractNum w:abstractNumId="0">'
          '<w:lvl w:ilvl="0"><w:start w:val="3"/><w:numFmt w:val="upperRoman"/>'
          '<w:suff w:val="space"/><w:lvlText w:val="Article %1."/>'
          '<w:lvlJc w:val="center"/><w:pPr><w:ind w:left="1080" '
          'w:hanging="720"/></w:pPr></w:lvl>'
          '<w:lvl w:ilvl="1"><w:numFmt w:val="decimal"/><w:isLgl/>'
          '<w:suff w:val="nothing"/><w:lvlText w:val="%1.%2"/><w:pPr><w:ind '
          'w:start="1440" w:firstLine="-360"/></w:pPr><w:rPr><w:rFonts '
          'w:hAnsi="Courier New"/></w:rPr></w:lvl>'
          '<w:lvl w:ilvl="2"><w:numFmt w:val="bullet"/><w:lvlText '
          'w:val=""/><w:rPr><w:rFonts w:ascii="Symbol" '
          'w:hAnsi="Arial"/></w:rPr></w:lvl>'
          '<w:lvl w:ilvl="3"><w:numFmt w:val="bullet"/><w:lvlText w:val="☐"/>'
          '</w:lvl><w:lvl w:ilvl="4"><w:numFmt w:val="bullet"/>'
          '<w:lvlPicBulletId w:val="0"/><w:lvlText w:val="☑"/></w:lvl>'
          '<w:lvl w:ilvl="5"><w:numFmt w:val="none"/><w:lvlText '
          'w:val="Annex"/></w:lvl></w:abstractNum>${_list(1, 0)}',
        ),
      );
      final article = numbering.level(1, 0)!;
      expect(article.start, 3);
      expect(article.format, 'upperRoman');
      expect(article.text, 'Article %1.');
      expect(article.suffix, ListSuffix.space);
      expect(article.justification, 'center');
      expect(article.left, 54);
      expect(article.hanging, 36);
      expect(article.legal, isFalse);
      expect(article.kind, ListKind.ordered);

      final legal = numbering.level(1, 1)!;
      expect(legal.start, 0, reason: 'it has no w:start');
      expect(legal.legal, isTrue);
      expect(legal.suffix, ListSuffix.nothing);
      expect(legal.left, 72);
      expect(legal.hanging, 18);
      expect(legal.font, 'Courier New');
      expect(legal.justification, isNull);

      final symbol = numbering.level(1, 2)!;
      expect(symbol.font, 'Symbol');
      expect(symbol.suffix, ListSuffix.tab);
      expect(symbol.left, isNull);
      expect(symbol.kind, ListKind.bullet);
      expect(numbering.level(1, 3)!.kind, ListKind.unchecked);
      expect(numbering.level(1, 4)!.picture, isTrue);
      expect(numbering.level(1, 4)!.kind, ListKind.bullet);
      expect(numbering.level(1, 5)!.kind, isNull);
      expect(numbering.level(1, 5)!.numbered, isFalse);
    });

    test('only levels 0 to 8 count, and odd values do no harm', () {
      final numbering = DocxNumbering.parse(
        _numbering(
          '<w:abstractNum w:abstractNumId="0">${_level(0, 'bullet', '•')}'
          '${_level(9, 'decimal', '%10.')}${_level(-1, 'decimal', '%1.')}'
          '<w:lvl w:ilvl="x"><w:numFmt w:val="decimal"/></w:lvl>'
          '<w:lvl><w:numFmt w:val="decimal"/></w:lvl>'
          '<w:lvl w:ilvl="1"><w:start w:val="abc"/><w:pPr><w:ind '
          'w:left="1e400" w:hanging="abc"/></w:pPr></w:lvl>'
          '${_level(2, 'decimal', '%3', start: 9223372036854775807)}'
          '</w:abstractNum><w:abstractNum w:abstractNumId="x"/>'
          '${_list(1, 0)}${_list(2, 99)}<w:num w:numId="3"/>'
          '<w:num w:numId="y"><w:abstractNumId w:val="0"/></w:num>'
          '${_list(4, 0, '<w:lvlOverride w:ilvl="12"><w:startOverride w:val="3"/></w:lvlOverride><w:lvlOverride><w:startOverride w:val="4"/></w:lvlOverride>')}',
        ),
      );
      expect(numbering.level(1, 0)!.kind, ListKind.bullet);
      expect(numbering.level(1, 9), isNull);
      expect(numbering.level(1, -1), isNull);
      expect(numbering.kind(1, 12), ListKind.bullet);
      final odd = numbering.level(1, 1)!;
      expect(odd.start, 1);
      expect(odd.format, 'decimal');
      expect(odd.left, isNull);
      expect(odd.hanging, isNull);
      expect(numbering.level(1, 2)!.start, 9223372036854775807);
      expect(numbering.level(2, 0), isNull);
      expect(numbering.kind(2, 0), isNull);
      expect(numbering.level(3, 0), isNull);
      expect(numbering.groupOf(3), isNot(numbering.groupOf(1)));
      expect(numbering.level(4, 0)!.start, 1);
      expect(numbering.restarts(4, 0), isFalse);
      expect(numbering.level(7, 0), isNull);
      expect(numbering.groupOf(7), isNull);
    });

    test("lists made with a Word list style take the style's levels", () {
      final numbering = DocxNumbering.parse(
        _numbering(
          '<w:abstractNum w:abstractNumId="0"><w:multiLevelType '
          'w:val="hybridMultilevel"/><w:numStyleLink w:val="Numbered"/>'
          '</w:abstractNum>'
          '<w:abstractNum w:abstractNumId="1"><w:styleLink w:val="Numbered"/>'
          '${_level(0, 'decimal', '%1.')}${_level(1, 'bullet', '☐')}'
          '</w:abstractNum>'
          '<w:abstractNum w:abstractNumId="2"><w:numStyleLink '
          'w:val="Missing"/></w:abstractNum>'
          '${_list(1, 1)}${_list(2, 0)}'
          '${_list(3, 0, '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="4"/></w:lvlOverride>')}'
          '${_list(4, 0, '<w:lvlOverride w:ilvl="1">${_level(1, 'lowerLetter', '%2)')}</w:lvlOverride>')}'
          '${_list(5, 2)}',
        ),
      );

      expect(numbering.level(2, 0)!.text, '%1.');
      expect(numbering.level(2, 0)!.kind, ListKind.ordered);
      expect(numbering.level(2, 1)!.kind, ListKind.unchecked);
      expect(numbering.level(3, 0)!.start, 4);
      expect(numbering.restarts(3, 0), isTrue);
      expect(numbering.level(4, 1)!.text, '%2)');
      expect(numbering.level(4, 0)!.text, '%1.');
      // Word counts every list of a list style as one.
      expect(numbering.groupOf(2), numbering.groupOf(1));
      expect(numbering.groupOf(3), numbering.groupOf(1));
      expect(numbering.sameNumbering(2), numbering.sameNumbering(1));
      expect(numbering.level(5, 0), isNull);
      expect(numbering.maxAbstractId, 2);
    });

    test('a level without w:start counts from 0, as in Word', () {
      final numbering = DocxNumbering.parse(
        _numbering(
          '<w:abstractNum w:abstractNumId="0">${_level(0, 'decimal', '%1')}'
          '<w:lvl w:ilvl="1"><w:numFmt w:val="decimal"/><w:lvlText w:val=""/>'
          '</w:lvl>${_level(2, 'decimal', '%1.%2.%3')}</w:abstractNum>'
          '${_list(1, 0)}',
        ),
      );
      final counter = WordListCounter(numbering);
      final texts = <String?>[];
      for (final level in [0, 1, 1, 1, 2, 0, 2]) {
        final line = _item(1, level: level);
        counter.count(line);
        texts.add(counter.textOf(line));
      }

      expect(numbering.level(1, 1)!.start, 0);
      // A level yet to count shows one before its start, but never less
      // than 0.
      expect(texts, ['1', '', '', '', '1.2.1', '2', '2.0.1']);
    });

    test('the numbering of an opened document comes from its package', () {
      final loaded = DocxCodec(TableStore()).read(
        _package(
          '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/>'
          '</w:numPr></w:pPr><w:r><w:t>One</w:t></w:r></w:p>',
          _numbering(
            '<w:abstractNum w:abstractNumId="0">${_level(0, 'lowerRoman', '%1)')}'
            '</w:abstractNum>${_list(1, 0)}',
          ).toXmlString(),
        ),
      );
      expect(DocxNumbering.of(loaded.source).level(1, 0)!.text, '%1)');
      expect(DocxNumbering.of(null).level(1, 0), isNull);
      expect(DocxNumbering.of(Delta()).level(1, 0), isNull);
      expect(
        DocxNumbering.of(_package('', '<w:numbering')).level(1, 0),
        isNull,
      );
    });
  });

  group('the counter', () {
    final shared = DocxNumbering.parse(
      _numbering(
        '<w:abstractNum w:abstractNumId="0">${_level(0, 'decimal', '%1.')}'
        '${_level(1, 'decimal', '%1.%2.')}</w:abstractNum>'
        '${_list(1, 0)}${_list(2, 0)}'
        '${_list(3, 0, '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride>')}'
        '${_list(4, 0, '<w:lvlOverride w:ilvl="1"><w:startOverride w:val="5"/></w:lvlOverride>')}',
      ),
    );

    test('the lists of one abstract list count together, as in Word', () {
      final counter = WordListCounter(shared);
      final lines = [
        _item(1),
        _item(1),
        _item(2),
        _item(1, level: 1),
        _item(3),
        _item(3),
        _item(1),
        _item(4, level: 1),
        _item(4, level: 1),
        _item(4),
        _item(4, level: 1),
      ];
      final numbers = <int?>[];
      final texts = <String?>[];
      for (final line in lines) {
        numbers.add(counter.count(line));
        texts.add(counter.textOf(line));
      }
      // A w:startOverride restarts its level at the list's first paragraph
      // there only; after that the list goes on with the others.
      expect(numbers, [1, 2, 3, 1, 1, 2, 3, 5, 6, 4, 5]);
      expect(texts, [
        '1.',
        '2.',
        '3.',
        '3.1.',
        '1.',
        '2.',
        '3.',
        '3.5.',
        '3.6.',
        '4.',
        '4.5.',
      ]);
    });

    test('Word writes legal numbers in decimals, and levels above yet to '
        'count at their start', () {
      final numbering = DocxNumbering.parse(
        _numbering(
          '<w:abstractNum w:abstractNumId="0">'
          '${_level(0, 'upperRoman', 'Article %1.', start: 3)}'
          '${_level(1, 'lowerLetter', '%1.%2', extra: '<w:isLgl/>')}'
          '${_level(2, 'lowerLetter', '(%3)')}'
          '${_level(3, 'decimal', '${'x' * 250}%4')}'
          '${_level(4, 'decimal', '${'x' * 260}%5')}</w:abstractNum>'
          '${_list(1, 0)}',
        ),
      );
      final counter = WordListCounter(numbering);
      String? next(int level) {
        final line = _item(1, level: level);
        counter.count(line);
        return counter.textOf(line);
      }

      // Word counts the article it shows, so the next one is IV.
      expect(next(1), '3.1');
      expect(next(0), 'Article IV.');
      expect(next(1), '4.1');
      expect(next(2), '(a)');
      expect(next(3), '${'x' * 250}1');
      expect(next(4), isNull);
    });

    test('legal numbers keep zero-padded decimals, and levels without a '
        'number stay empty', () {
      final numbering = DocxNumbering.parse(
        _numbering(
          '<w:abstractNum w:abstractNumId="0">'
          '${_level(0, 'upperRoman', 'Article %1.')}'
          '${_level(1, 'decimalZero', 'Section %1.%2', extra: '<w:isLgl/>')}'
          '${_level(2, 'none', '')}'
          '${_level(3, 'lowerLetter', '%1.%3%4', extra: '<w:isLgl/>')}'
          '</w:abstractNum>${_list(1, 0)}',
        ),
      );
      final counter = WordListCounter(numbering);
      String? next(int level) {
        final line = _item(1, level: level);
        counter.count(line);
        return counter.textOf(line);
      }

      expect(next(0), 'Article I.');
      expect(next(1), 'Section 1.01');
      expect(next(1), 'Section 1.02');
      expect(next(0), 'Article II.');
      expect(next(1), 'Section 2.01');
      expect(next(3), '2.1', reason: 'the level without a number shows none');
    });

    test('the editor\'s items count in runs; items of another kind than '
        'their level leave the Word list', () {
      final numbering = DocxNumbering.parse(
        _numbering(
          '<w:abstractNum w:abstractNumId="0">${_level(0, 'bullet', '☐')}'
          '${_level(1, 'decimal', '%2.')}</w:abstractNum>${_list(1, 0)}',
        ),
      );
      final counter = WordListCounter(numbering);
      expect(counter.count(_item(null)), 1);
      expect(counter.count(_item(null, level: 1)), 1);
      expect(counter.count(_item(null)), 2);
      expect(counter.count(_item(null, list: 'bullet')), isNull);
      expect(counter.count(_item(null)), 3);
      counter.breakRun();
      expect(counter.count(_item(null)), 1);

      final box = _item(1, list: 'unchecked');
      expect(counter.wordList(box), isNull);
      expect(counter.count(_item(1, level: 1)), 1);
      expect(counter.count(_item(1, level: 1)), 2);
      // A checklist item of the list restarts the levels below it, as Word
      // counts it, though it shows the editor's box; the items under it
      // counted its level once already.
      expect(counter.count(box), 2);
      expect(counter.count(_item(1, level: 1)), 1);
      expect(
        counter.count(_item(null)),
        1,
        reason: 'a number of a Word list ends the run',
      );

      final switched = _item(1, list: 'bullet', level: 1);
      expect(counter.wordList(switched), isNull);
      expect(counter.count(switched), isNull);
      final unchecked = _item(1, list: 'checked');
      expect(counter.count(unchecked), isNull, reason: 'its box is ☐');
      expect(counter.count(_item(1, level: 1)), 2);
    });

    test('levels above a paragraph that have not counted show their start '
        'and count there, as in Word', () {
      // LibreOffice's tdf116883.docx and tdf75748_inheritChapterNumberingC
      // tests, with the labels Word shows.
      final numbering = DocxNumbering.parse(
        _numbering(
          '<w:abstractNum w:abstractNumId="0">'
          '${_level(0, 'decimal', '%1>')}${_level(1, 'decimal', '%1>%2>')}'
          '${_level(2, 'decimal', '%1>%2>%3>')}'
          '${_level(3, 'decimal', '%1>%2>%3>%4>')}</w:abstractNum>'
          '<w:abstractNum w:abstractNumId="1">'
          '${_level(0, 'upperRoman', '%1.')}'
          '${_level(1, 'upperLetter', '%1.%2.')}'
          '${_level(2, 'decimal', '%1.%2.%3.')}</w:abstractNum>'
          '${_list(1, 0)}${_list(2, 1)}',
        ),
      );
      List<String?> texts(int numId, List<int> levels) {
        final counter = WordListCounter(numbering);
        return [
          for (final level in levels)
            () {
              final line = _item(numId, level: level);
              counter.count(line);
              return counter.textOf(line);
            }(),
        ];
      }

      expect(texts(1, [1, 1, 3, 2, 2]), [
        '1>1>',
        '1>2>',
        '1>2>1>1>',
        '1>2>2>',
        '1>2>3>',
      ]);
      expect(texts(2, [2, 0, 1, 1, 2]), [
        'I.A.1.',
        'II.',
        'II.A.',
        'II.B.',
        'II.B.1.',
      ]);
    });

    test('a level text that names a level below its own shows nothing, as '
        'in Word', () {
      final numbering = DocxNumbering.parse(
        _numbering(
          '<w:abstractNum w:abstractNumId="0">${_level(0, 'decimal', '%1.%2')}'
          '${_level(1, 'decimal', '%1.%2')}</w:abstractNum>${_list(1, 0)}',
        ),
      );
      final counter = WordListCounter(numbering);
      final top = _item(1);
      final below = _item(1, level: 1);
      counter
        ..count(top)
        ..count(below);
      expect(counter.textOf(below), '1.1');
      counter.count(top);
      expect(counter.textOf(top), '');
    });

    test('paragraphs at a level without numbers count and show the level '
        'text, so the levels below them restart', () {
      final numbering = DocxNumbering.parse(
        _numbering(
          '<w:abstractNum w:abstractNumId="0">${_level(0, 'none', 'Part')}'
          '${_level(1, 'decimal', '%2.')}${_level(2, 'none', 'Schedule%3')}'
          '${_level(3, 'lowerLetter', '%2.%3%4)')}</w:abstractNum>'
          '${_list(1, 0)}',
        ),
      );
      LineBlock unnumbered(int level) => LineBlock(const [], {
        HiddenAttributes.numbering: 1,
        HiddenAttributes.unnumberedLevel: level,
      });
      final counter = WordListCounter(numbering);
      final labels = <String?>[];
      final numbers = <int?>[];
      for (final line in [
        unnumbered(0),
        _item(1, level: 1),
        _item(1, level: 1),
        unnumbered(0),
        _item(1, level: 1),
        unnumbered(2),
        _item(1, level: 3),
      ]) {
        numbers.add(counter.count(line));
        labels.add(counter.textOf(line));
      }

      expect(numbers, [1, 1, 2, 2, 1, 1, 1]);
      expect(labels, ['Part', '1.', '2.', 'Part', '1.', 'Schedule', '1.a)']);
      expect(counter.unnumberedList(unnumbered(0)), 1);
      expect(counter.wordList(unnumbered(0)), isNull);
      expect(WordListCounter.levelOf(unnumbered(2)), 2);
      // Without its level, or at a level with numbers, a paragraph the editor
      // shows without a list is no list paragraph.
      expect(
        counter.count(LineBlock(const [], {HiddenAttributes.numbering: 1})),
        isNull,
      );
      expect(counter.unnumberedList(unnumbered(1)), isNull);
      expect(counter.count(unnumbered(1)), isNull);
    });
  });

  test('paragraphs at a level without numbers stay in their list, which '
      'every format shows', () {
    String paragraph(String text, int level) =>
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="$level"/><w:numId w:val="1"/>'
        '</w:numPr></w:pPr><w:r><w:t>$text</w:t></w:r></w:p>';
    final docx = DocxCodec(TableStore());
    final loaded = docx.read(
      _package(
        [
          paragraph('A', 0),
          paragraph('x', 1),
          paragraph('y', 1),
          paragraph('B', 0),
          paragraph('z', 1),
        ].join(),
        _numbering(
          '<w:abstractNum w:abstractNumId="0">'
          '${_level(0, 'none', 'Part', extra: '<w:suff w:val="space"/>')}'
          '${_level(1, 'decimal', '%2.')}</w:abstractNum>${_list(1, 0)}',
        ).toXmlString(),
      ),
    );
    final lines = documentBlocks(loaded.delta).whereType<LineBlock>().toList();
    LineBlock line(String text) =>
        lines.firstWhere((line) => line.plainText == text);

    // The editor shows the parts as paragraphs.
    expect(line('A').list, isNull);
    expect(line('A').attributes[HiddenAttributes.numbering], 1);
    expect(line('A').attributes[HiddenAttributes.unnumberedLevel], 0);
    expect(line('z').list, 'ordered');

    String saved(DocumentCodec codec, [Encoding encoding = utf8]) =>
        encoding.decode(
          codec.encode(loaded.delta, source: loaded.source, look: loaded.look),
        );
    final html = saved(HtmlCodec(docx));
    expect(html, contains('<p>Part A</p>'));
    expect(html, contains('<p>Part B</p>'));
    expect(html, isNot(contains('start="3"')));
    expect(
      saved(MarkdownCodec(docx)),
      'Part A\n\n1. x\n2. y\n\nPart B\n\n1. z\n',
    );
    final rtf = saved(RtfCodec(docx), latin1);
    expect(rtf, contains(r'\ls1\ilvl0'));
    expect(rtf, contains(r'{\listtext\f0 Part }A\par'));
    expect(rtf, contains(r'{\listtext\f0 1.\tab}z\par'));

    // OpenDocument keeps the parts in the list, whose first level shows
    // "Part" and no number.
    final odt = OdtCodec(
      docx,
    ).encode(loaded.delta, source: loaded.source, look: loaded.look);
    final content = XmlDocument.parse(
      utf8.decode(
        ZipDecoder().decodeBytes(odt).findFile('content.xml')!.content,
      ),
    );
    XmlElement paragraphOf(String text) =>
        content.descendantElements.firstWhere(
          (element) => element.innerText == text && element.name.local == 'p',
        );
    expect(paragraphOf('A').parentElement!.name.local, 'list-item');
    expect(
      paragraphOf('z').parentElement!.getAttribute('text:start-value'),
      isNull,
    );
    final level = content.descendantElements.firstWhere(
      (element) =>
          element.name.local == 'list-level-style-number' &&
          element.getAttribute('text:level') == '1',
    );
    expect(level.getAttribute('style:num-prefix'), 'Part');
    expect(level.getAttribute('style:num-format'), '');

    // Saved as .docx and opened again, they are still in the list.
    final again = docx.decode(docx.encode(loaded.delta, source: loaded.source));
    final reopened = documentBlocks(again.delta).whereType<LineBlock>();
    expect(
      reopened
          .firstWhere((line) => line.plainText == 'B')
          .attributes[HiddenAttributes.unnumberedLevel],
      0,
    );
  });

  test('lists added in the editor take free ids in Word\'s range', () {
    const huge = 9223372036854775807;
    final xml = _numbering(
      '<w:abstractNum w:abstractNumId="$huge">${_level(0, 'decimal', '%1.')}'
      '</w:abstractNum><w:abstractNum w:abstractNumId="1">'
      '${_level(0, 'decimal', '%1.')}</w:abstractNum>'
      '${_list(huge, huge)}${_list(1, 1)}${_list(2, 1)}',
    ).toXmlString();
    final plan = NumberingPlan(DocxNumbering.parse(XmlDocument.parse(xml)));
    final ordered = plan.newOrderedList();
    final bullets = plan.sharedList(ListKind.bullet);
    final saved = DocxNumbering.parse(XmlDocument.parse(plan.apply(xml)));

    // The lowest ids from 1 that the part leaves free.
    expect([ordered, bullets], [3, 4]);
    expect([saved.groupOf(ordered), saved.groupOf(bullets)], [2, 3]);
    expect(saved.level(ordered, 0)!.format, 'decimal');
    expect(saved.level(bullets, 0)!.format, 'bullet');
    expect(saved.groupOf(1), 1);
    expect(saved.groupOf(huge), huge);

    final normal = NumberingPlan(
      DocxNumbering.parse(
        _numbering(
          '<w:abstractNum w:abstractNumId="4">${_level(0, 'decimal', '%1.')}'
          '</w:abstractNum>${_list(7, 4)}',
        ),
      ),
    );
    expect(normal.newOrderedList(), 8, reason: 'after the highest');
  });

  test('lists made with a Word list style open as lists and save with '
      "Word's numbers", () {
    String paragraph(String text, [int? numId]) =>
        '<w:p><w:pPr>${numId == null ? '' : '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="$numId"/></w:numPr>'}'
        '</w:pPr><w:r><w:t>$text</w:t></w:r></w:p>';
    final docx = DocxCodec(TableStore());
    final loaded = docx.read(
      _package(
        [
          paragraph('first', 2),
          paragraph('second', 2),
          paragraph('third', 2),
          paragraph(''),
          paragraph('again', 3),
          paragraph('then', 2),
          paragraph('on', 2),
        ].join(),
        _numbering(
          '<w:abstractNum w:abstractNumId="0"><w:numStyleLink '
          'w:val="Numbered"/></w:abstractNum>'
          '<w:abstractNum w:abstractNumId="1"><w:styleLink w:val="Numbered"/>'
          '${_level(0, 'decimal', '%1.')}</w:abstractNum>'
          '${_list(1, 1)}${_list(2, 0)}'
          '${_list(3, 0, '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride>')}',
        ).toXmlString(),
      ),
    );
    List<LineBlock> items(Delta delta) => [
      for (final line in documentBlocks(delta).whereType<LineBlock>())
        if (line.plainText.isNotEmpty) line,
    ];

    expect(
      [for (final line in items(loaded.delta)) line.list],
      [for (var index = 0; index < 6; index++) 'ordered'],
    );
    final counter = WordListCounter(DocxNumbering.of(loaded.source));
    expect(
      [for (final line in items(loaded.delta)) counter.count(line)],
      [1, 2, 3, 1, 2, 3],
    );
    final markdown = utf8.decode(
      MarkdownCodec(
        docx,
      ).encode(loaded.delta, source: loaded.source, look: loaded.look),
    );
    expect(markdown, matches(RegExp(r'^3[.)] third$', multiLine: true)));
    expect(markdown, matches(RegExp(r'^3[.)] on$', multiLine: true)));

    final saved = docx.decode(docx.encode(loaded.delta, source: loaded.source));
    expect(
      [
        for (final line in items(saved.delta))
          line.attributes[HiddenAttributes.numbering],
      ],
      [2, 2, 2, 3, 2, 2],
    );
  });

  test('a paragraph at a level its Word list leaves out leaves the list in '
      '.docx too, as in the other formats', () {
    final docx = DocxCodec(TableStore());
    final loaded = docx.read(
      _package(
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/>'
        '</w:numPr></w:pPr><w:r><w:t>one</w:t></w:r></w:p>'
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="1"/>'
        '</w:numPr></w:pPr><w:r><w:t>deeper</w:t></w:r></w:p>',
        _numbering(
          '<w:abstractNum w:abstractNumId="0">${_level(0, 'decimal', '%1.')}'
          '</w:abstractNum>${_list(1, 0)}',
        ).toXmlString(),
      ),
    );
    LineBlock line(Delta delta, String text) => documentBlocks(
      delta,
    ).whereType<LineBlock>().firstWhere((line) => line.plainText == text);
    final deeper = line(loaded.delta, 'deeper');
    expect(deeper.list, 'ordered');
    expect(
      WordListCounter(DocxNumbering.of(loaded.source)).wordList(deeper),
      isNull,
    );

    final saved = docx.decode(docx.encode(loaded.delta, source: loaded.source));
    expect(line(saved.delta, 'one').attributes[HiddenAttributes.numbering], 1);
    expect(
      line(saved.delta, 'deeper').attributes[HiddenAttributes.numbering],
      isNot(1),
    );
    expect(line(saved.delta, 'deeper').list, 'ordered');
  });

  test('a numbering part of 20k lists sharing an abstract list of 20k levels '
      'saves quickly in every format', () {
    const count = 20000;
    final numbering = StringBuffer(
      '<w:numbering xmlns:w="${Namespaces.w}"><w:abstractNum '
      'w:abstractNumId="0">',
    );
    for (var level = 0; level < count; level++) {
      numbering.write(_level(level, 'decimal', '%${level % 9 + 1}.'));
    }
    numbering.write('</w:abstractNum>');
    for (var numId = 1; numId <= count; numId++) {
      numbering.write(_list(numId, 0));
    }
    numbering.write('</w:numbering>');
    final body = StringBuffer();
    for (var index = 0; index < 500; index++) {
      body.write(
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="${index % 9}"/><w:numId '
        'w:val="${index * 37 % count + 1}"/></w:numPr></w:pPr><w:r><w:t>'
        'Item $index</w:t></w:r></w:p>',
      );
    }
    final tables = TableStore();
    final docx = DocxCodec(tables);
    final loaded = docx.read(_package('$body', '$numbering'));
    expect(
      documentBlocks(
        loaded.delta,
      ).whereType<LineBlock>().where((line) => line.isOrdered),
      hasLength(500),
    );
    for (final codec in <DocumentCodec>[
      HtmlCodec(docx),
      MarkdownCodec(docx),
      RtfCodec(docx),
      OdtCodec(docx),
    ]) {
      final watch = Stopwatch()..start();
      codec.encode(loaded.delta, source: loaded.source, look: loaded.look);
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 20)),
        reason: '${codec.runtimeType}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
