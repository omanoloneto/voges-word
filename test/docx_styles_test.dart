import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/docx/docx_styles.dart';
import 'package:voges_word/docx/word_xml.dart';
import 'package:xml/xml.dart';

/// Random styles: chains, loops, styles based on themselves or on missing
/// ones, and properties that override each other along the chain.
String _randomStyles(Random random, int count) {
  String pick(List<String> options) => options[random.nextInt(options.length)];
  String? maybe(String value) => random.nextInt(3) == 0 ? value : null;

  String runProperties() => [
    maybe(
      pick([
        '<w:rFonts w:ascii="Font${random.nextInt(4)}"/>',
        '<w:rFonts w:asciiTheme="majorHAnsi"/>',
        '<w:rFonts w:eastAsia="Other"/>',
      ]),
    ),
    maybe(pick(['<w:b/>', '<w:b w:val="0"/>'])),
    maybe(pick(['<w:i/>', '<w:i w:val="false"/>'])),
    maybe(pick(['<w:strike/>', '<w:strike w:val="0"/>'])),
    maybe('<w:dstrike/>'),
    maybe(pick(['<w:color w:val="FF0000"/>', '<w:color w:val="auto"/>'])),
    maybe('<w:sz w:val="${18 + random.nextInt(20)}"/>'),
    maybe(
      pick(['<w:highlight w:val="yellow"/>', '<w:highlight w:val="none"/>']),
    ),
    maybe(pick(['<w:u w:val="single"/>', '<w:u w:val="none"/>', '<w:u/>'])),
    maybe(pick(['<w:shd w:fill="00FF00"/>', '<w:shd w:fill="auto"/>'])),
    maybe(
      pick([
        '<w:vertAlign w:val="superscript"/>',
        '<w:vertAlign w:val="baseline"/>',
      ]),
    ),
  ].nonNulls.join();

  String paragraphProperties() => [
    maybe(
      '<w:numPr><w:ilvl w:val="${random.nextInt(3)}"/>'
      '<w:numId w:val="${random.nextInt(3)}"/></w:numPr>',
    ),
    maybe(
      pick([
        '<w:spacing w:before="${random.nextInt(400)}"/>',
        '<w:spacing w:after="${random.nextInt(400)}" w:line="360" w:lineRule="auto"/>',
        '<w:spacing w:line="300" w:lineRule="exact"/>',
      ]),
    ),
    maybe(
      pick([
        '<w:ind w:left="${random.nextInt(2000)}"/>',
        '<w:ind w:start="720" w:hanging="360"/>',
        '<w:ind w:right="100" w:firstLine="200"/>',
      ]),
    ),
    maybe(pick(['<w:contextualSpacing/>', '<w:contextualSpacing w:val="0"/>'])),
    maybe(pick(['<w:jc w:val="center"/>', '<w:jc w:val="both"/>'])),
  ].nonNulls.join();

  final out = StringBuffer(
    '<w:styles xmlns:w="${Namespaces.w}"><w:docDefaults>'
    '<w:rPrDefault><w:rPr>${runProperties()}</w:rPr></w:rPrDefault>'
    '<w:pPrDefault><w:pPr>${paragraphProperties()}</w:pPr></w:pPrDefault>'
    '</w:docDefaults>',
  );
  for (var index = 0; index < count; index++) {
    final id = 'S${random.nextInt(count)}';
    final type = pick(['paragraph', 'paragraph', 'character', 'table']);
    final base = random.nextInt(5) == 0
        ? ''
        : '<w:basedOn w:val="S${random.nextInt(count + 3)}"/>';
    final name = pick(['heading 1', 'List Paragraph', 'Style $index']);
    final isDefault = random.nextInt(count) == 0 ? ' w:default="1"' : '';
    final borders = random.nextBool()
        ? '<w:tblPr><w:tblBorders><w:top w:val="${pick(['single', 'nil'])}"/>'
              '</w:tblBorders></w:tblPr>'
        : '';
    out.write(
      '<w:style w:type="$type" w:styleId="$id"$isDefault>'
      '<w:name w:val="$name"/>$base<w:pPr>${paragraphProperties()}</w:pPr>'
      '<w:rPr>${runProperties()}</w:rPr>$borders</w:style>',
    );
  }
  out.write('</w:styles>');
  return out.toString();
}

/// The way styles were resolved before they were cached: the whole chain of
/// each style, walked on every call.
class _Reference {
  _Reference(XmlDocument document) : root = document.rootElement {
    x = WordXml(root);
    for (final element in x.children(root, 'style')) {
      final id = x.attr(element, 'styleId');
      if (id != null) styles[id] = element;
    }
  }

  final XmlElement root;
  late final WordXml x;
  final styles = <String, XmlElement>{};
  final theme = const ThemeFonts(major: 'Major', minor: 'Minor');

  String? get defaultParagraph {
    for (final MapEntry(key: id, value: style) in styles.entries) {
      if ((x.attr(style, 'type') ?? 'paragraph') == 'paragraph' &&
          const {'1', 'true', 'on'}.contains(x.attr(style, 'default'))) {
        return id;
      }
    }
    return null;
  }

  Iterable<XmlElement> chain(String? id) {
    final chain = <XmlElement>[];
    final seen = <String>{};
    var current = id == null ? null : styles[id];
    while (current != null && seen.add(x.attr(current, 'styleId')!)) {
      chain.add(current);
      final base = x.childVal(current, 'basedOn');
      current = base == null ? null : styles[base];
    }
    return chain.reversed;
  }

  XmlElement? defaults(String kind) =>
      x.child(x.child(x.child(root, 'docDefaults'), '${kind}Default'), kind);

  RunProps run(String? paragraph, String? character) {
    var props = const RunProps().merge(defaults('rPr'), x, theme);
    for (final style in [
      ...chain(paragraph ?? defaultParagraph),
      ...chain(character),
    ]) {
      props = props.merge(x.child(style, 'rPr'), x, theme);
    }
    return props;
  }

  ParagraphProps paragraph(String? id) {
    var props = const ParagraphProps().merge(defaults('pPr'), x);
    for (final style in chain(id ?? defaultParagraph)) {
      props = props.merge(x.child(style, 'pPr'), x);
    }
    return props;
  }
}

Object _runKey(RunProps p) => (
  p.bold,
  p.italic,
  p.underline,
  p.strike,
  p.size,
  p.font,
  p.color,
  p.background,
  p.script,
);

Object _paragraphKey(ParagraphProps p) => (
  p.align,
  p.lineSpacing,
  p.exactLineSpacing,
  p.spaceBefore,
  p.spaceAfter,
  p.indentLeft,
  p.indentRight,
  p.firstLine,
  p.contextualSpacing,
  p.numId,
  p.level,
);

void main() {
  test('styles resolve as walking their whole chain each time does', () {
    for (var seed = 0; seed < 300; seed++) {
      final random = Random(seed);
      final count = 1 + random.nextInt(12);
      final xml = _randomStyles(random, count);
      final document = XmlDocument.parse(xml);
      final theme = XmlDocument.parse(
        '<a:theme xmlns:a="a"><a:majorFont><a:latin typeface="Major"/>'
        '</a:majorFont><a:minorFont><a:latin typeface="Minor"/>'
        '</a:minorFont></a:theme>',
      );
      final styles = DocxStyles.parse(document, theme);
      final reference = _Reference(document);
      final ids = [
        null,
        for (var index = 0; index < count + 3; index++) 'S$index',
      ];
      // Random order, twice: answers can't depend on what was asked before.
      for (var round = 0; round < 2; round++) {
        for (final id in [...ids]..shuffle(random)) {
          final reason = 'seed $seed, style $id\n$xml';
          expect(
            _paragraphKey(styles.paragraphProps(id)),
            _paragraphKey(reference.paragraph(id)),
            reason: reason,
          );
          expect(
            styles.tableStyleHasBorders(id),
            reference
                .chain(id)
                .any(
                  (style) => styles.hasVisibleBorders(
                    reference.x.child(style, 'tblPr'),
                  ),
                ),
            reason: reason,
          );
          for (final character in [...ids]..shuffle(random)) {
            expect(
              _runKey(styles.runProps(id, character)),
              _runKey(reference.run(id, character)),
              reason: '$reason, character style $character',
            );
          }
        }
      }
      expect(styles.defaultParagraphStyleId, reference.defaultParagraph);
      for (final name in ['heading 1', 'list paragraph', 'Style 0']) {
        String? first;
        for (final MapEntry(key: id, value: style)
            in reference.styles.entries) {
          if ((reference.x.attr(style, 'type') ?? 'paragraph') == 'paragraph' &&
              reference.x.childVal(style, 'name')?.toLowerCase() ==
                  name.toLowerCase()) {
            first = id;
            break;
          }
        }
        expect(styles.idByName(name), first, reason: 'seed $seed, $name');
      }
    }
  });
}
