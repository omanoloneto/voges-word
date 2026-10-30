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
      expect(legal.start, 1);
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

    test('Word writes legal numbers in decimals and levels yet to count '
        'one before their start', () {
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

      expect(next(1), '2.1');
      expect(next(0), 'Article III.');
      expect(next(1), '3.1');
      expect(next(2), '(a)');
      expect(next(3), '${'x' * 250}1');
      expect(next(4), isNull);
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
      // counts it, though it shows the editor's box.
      expect(counter.count(box), 1);
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
