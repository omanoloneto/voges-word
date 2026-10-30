import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/html/html_codec.dart';
import 'package:voges_word/html/html_reader.dart';
import 'package:xml/xml.dart';

// Each test compares work done in the same run, so loaded machines pass;
// the absolute bound is several times what a laptop takes in debug mode.
const _timeout = Timeout(Duration(minutes: 4));

/// The shortest of a few runs, which load on the machine only lengthens.
Duration _fastest(void Function() work, {int runs = 2}) {
  var best = const Duration(days: 1);
  for (var run = 0; run < runs; run++) {
    final watch = Stopwatch()..start();
    work();
    if (watch.elapsed < best) best = watch.elapsed;
  }
  return best;
}

/// A page like the HTML LibreOffice exports of a long specification: a
/// style sheet of hundreds of classes, headings with anchors, paragraphs of
/// spans and links, bullet lists and tables.
String _specificationPage(int sections) {
  final page = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8"?><html lang="en-US"><head><style>'
    'table { border-collapse:collapse; } td, th { vertical-align:top; '
    'font-size:12pt; } li { list-style: none; margin:0; padding:0; } '
    '* { margin:0; }',
  );
  for (var index = 0; index < 300; index++) {
    page.write(
      '.P$index { font-size:10pt; font-family:Arial; '
      'margin-top:0.${index % 9}in; margin-bottom:0.0835in; '
      'line-height:115%; text-align:left ! important; } '
      '.T$index { font-family:\'Courier New\'; font-size:10pt; '
      'font-weight:normal; font-style:normal; text-decoration:none; } ',
    );
  }
  page.write(
    '.Heading { font-size:14pt; font-weight:bold; color:#2248e5; } '
    '.Link { color:#55308d; font-family:\'Liberation Sans\'; '
    'text-decoration:none ! important; }</style></head><body>',
  );
  for (var section = 0; section < sections; section++) {
    page.write(
      '<h2 class="Heading P${section % 300}"><a id="s$section"/>'
      '<span class="T1">19.$section</span> Element '
      '&lt;text:item-$section&gt;</h2>',
    );
    for (var paragraph = 0; paragraph < 4; paragraph++) {
      page.write('<p class="P${(section + paragraph) % 300}">');
      for (var span = 0; span < 4; span++) {
        page.write(
          '<span class="T${(section * 7 + span) % 300}">attribute '
          'value $section.$paragraph.$span</span> with text and a '
          '<a href="#s${(section + span) % sections}" class="Link">link '
          'to ${(section + span) % sections}</a>; ',
        );
      }
      page.write('</p>');
    }
    page.write('<ul>');
    for (var item = 0; item < 3; item++) {
      page.write(
        '<li><p class="P${item * 11}"><span class="T5">item $item</span>'
        ' of <a href="https://example.com/$section/$item">'
        'section $section</a></p></li>',
      );
    }
    page.write('</ul>');
    if (section % 50 == 0) {
      page.write(
        '<table border="1"><colgroup><col width="200"/>'
        '<col width="400"/></colgroup>',
      );
      for (var row = 0; row < 10; row++) {
        page.write(
          '<tr><td><p class="P3">Row $row</p></td>'
          '<td><p class="P4"><span class="T6">value $row</span></p></td></tr>',
        );
      }
      page.write('</table>');
    }
  }
  page.write('</body></html>');
  return page.toString();
}

/// A package whose paragraphs hold runs in a few formats, each with many
/// properties, most of which the editor keeps for saving.
({DocxPackage package, String xml}) _wordRuns(int paragraphs) {
  final package = DocxBuilder(
    DocumentSpec()..body.add(const ParagraphSpec([TextSpec('x')])),
  ).build();
  final kept = [for (var index = 0; index < 30; index++) '<w:x$index/>'];
  final body = StringBuffer();
  for (var paragraph = 0; paragraph < paragraphs; paragraph++) {
    body.write(
      '<w:p><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/>'
      '<w:rPr><w:lang w:val="en-US"/></w:rPr></w:pPr>',
    );
    for (var run = 0; run < 8; run++) {
      body.write(
        '<w:r><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/>'
        '${run.isEven ? '<w:b/>' : ''}<w:sz w:val="${20 + run % 3}"/>'
        '${kept.join()}</w:rPr><w:t>w </w:t></w:r>',
      );
    }
    body.write('</w:p>');
  }
  final document = package.text('word/document.xml')!;
  package.setText(
    'word/document.xml',
    document.replaceRange(
      document.indexOf('<w:body>') + '<w:body>'.length,
      document.indexOf('<w:sectPr>'),
      body.toString(),
    ),
  );
  return (package: package, xml: package.text('word/document.xml')!);
}

/// Spans in paragraphs that all take the rule of class `x`.
String _ruledPage(String declarations) {
  final page = StringBuffer('<style>.x { $declarations }</style><body><p>');
  for (var index = 0; index < 20000; index++) {
    page.write('<span class="x">w$index</span> ');
    if (index % 20 == 19) page.write('</p><p>');
  }
  return '$page</p></body>';
}

void main() {
  test(
    'a page shaped like a long specification opens in linear time',
    () {
      final codec = HtmlCodec(DocxCodec(TableStore()));
      late LoadedDocument loaded;
      Duration open(int sections) {
        final bytes = utf8.encode(_specificationPage(sections));
        return _fastest(() => loaded = codec.decode(bytes));
      }

      final half = open(750);
      final whole = open(1500);
      expect(whole, lessThan(half * 3.5));
      expect(whole, lessThan(const Duration(seconds: 40)));
      final operations = loaded.delta.toList();
      expect(
        operations.where((operation) => operation.attributes?['header'] == 2),
        hasLength(1500),
      );
      expect(
        operations.where(
          (operation) =>
              operation.data is Map &&
              (operation.data as Map).containsKey(EmbedTypes.table),
        ),
        hasLength(30),
      );
    },
    timeout: _timeout,
  );

  test(
    'runs that share their formatting add little to parsing them',
    () {
      final (:package, :xml) = _wordRuns(3000);
      final parse = _fastest(() => XmlDocument.parse(xml), runs: 4);
      final read = _fastest(
        () => DocxCodec(TableStore()).read(package),
        runs: 4,
      );
      // Working out each run's formatting again took longer than parsing it.
      expect(read, lessThan(parse * 1.7));
    },
    timeout: _timeout,
  );

  test('elements that share a long rule are styled quickly', () {
    final light = _ruledPage('margin: 0');
    final heavy = _ruledPage(
      List.filled(
        32,
        'margin: 1px 2px 3pt 0.5em; padding: 0 1em 2px; '
        'border-left: 1px solid #333; '
        'font-family: "Courier New", Courier, monospace',
      ).join('; '),
    );
    final lightRead = _fastest(() => readHtml(light));
    final heavyRead = _fastest(() => readHtml(heavy));
    // Parsing the rule's 128 values again for every span took 14 times as
    // long as the page without them.
    expect(heavyRead, lessThan(lightRead * 8));
    final first = readHtml(heavy).spec.body.first as ParagraphSpec;
    expect((first.inlines.first as TextSpec).format.font, 'Courier New');
  }, timeout: _timeout);

  test('long text is written quickly', () {
    final text =
        'Lorem ipsum dolor sit amet, <consectetur> & adipiscing. ' * 1000;
    final spec = DocumentSpec();
    for (var paragraph = 0; paragraph < 400; paragraph++) {
      spec.body.add(ParagraphSpec([TextSpec(text)]));
    }
    final build = _fastest(() => DocxBuilder(spec).build(), runs: 4);
    final encode = _fastest(() {
      for (var paragraph = 0; paragraph < 400; paragraph++) {
        utf8.encode(text);
      }
    }, runs: 4);
    // Writing it a character at a time took nine times as long here, and
    // more on CI machines, where the fixed builder takes about six times.
    expect(build, lessThan(encode * 8));
  }, timeout: _timeout);
}
