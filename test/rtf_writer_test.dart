import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show Color, EdgeInsets;
import 'package:flutter_quill/flutter_quill.dart' show ChangeSource, Document;
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voges_word/document/delta_blocks.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/document_look.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/headers_footers.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/docx/docx_template.dart';
import 'package:voges_word/docx/image_formats.dart';
import 'package:voges_word/docx/word_xml.dart';
import 'package:voges_word/editor/page_numbers.dart';
import 'package:voges_word/html/writing.dart';
import 'package:voges_word/rtf/rtf_codec.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

late TableStore _tables;
late DocxCodec _docx;
late RtfCodec _codec;

/// What the editor shows: hidden attributes, picture sizes and the look of
/// links are left out.
List<Map<String, dynamic>> _visible(Delta delta) => [
  for (final operation in Document.fromDelta(delta).toDelta().toList())
    {
      'insert': operation.data,
      if (operation.attributes != null)
        'attributes':
            {
              for (final entry in operation.attributes!.entries)
                if (!entry.key.startsWith('vw-')) entry.key: entry.value,
            }..removeWhere(
              (key, value) =>
                  key == 'width' ||
                  key == 'height' ||
                  (operation.attributes!.containsKey('link') &&
                      (key == 'color' || key == 'underline')),
            ),
    }..removeWhere((key, value) => value is Map && value.isEmpty),
];

String _plain(Delta delta) => PlainTextCodec(
  look: const DocumentLook(),
  tables: _tables,
).plainTextOf(delta);

/// Saves as the session does, with the opened package as the source.
String _save(LoadedDocument document) => latin1.decode(
  _codec.encode(
    document.delta,
    source: document.source,
    look: document.look,
    headersFooters: document.headersFooters,
  ),
);

LoadedDocument _again(LoadedDocument document) =>
    _codec.decode(Uint8List.fromList(latin1.encode(_save(document))));

LoadedDocument _openRtf(String rtf) =>
    _codec.decode(Uint8List.fromList(latin1.encode(rtf)));

/// A .docx whose body is [body] and whose last section has [section]'s
/// properties; [media] go in word/media, related from the body as rIdM1,
/// rIdM2..., and [numbering] is its numbering part.
LoadedDocument _openDocx(
  String body, {
  Map<String, Uint8List> media = const {},
  String section = '',
  String? numbering,
}) {
  final package = newDocumentPackage();
  final namespaces = {
    ...Namespaces.known,
    'cx': 'http://schemas.microsoft.com/office/drawing/2014/chartex',
  }.entries.map((entry) => 'xmlns:${entry.key}="${entry.value}"').join(' ');
  package
    ..setText(
      'word/document.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<w:document $namespaces><w:body>$body'
          '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>$section</w:sectPr>'
          '</w:body></w:document>',
    )
    ..addRelationships('word/document.xml', [
      for (final (index, name) in media.keys.indexed)
        Relationship(
          id: 'rIdM${index + 1}',
          type: RelationshipTypes.image,
          target: 'media/$name',
        ),
      if (numbering != null)
        const Relationship(
          id: 'rIdNumbering',
          type: RelationshipTypes.numbering,
          target: 'numbering.xml',
        ),
    ]);
  media.forEach((name, bytes) => package.parts['word/media/$name'] = bytes);
  if (numbering != null) package.setText('word/numbering.xml', numbering);
  return _docx.read(package);
}

/// The text and marks of each paragraph of [rtf] that holds [text].
String _line(String rtf, String text) =>
    rtf.split('\r\n').firstWhere((line) => line.contains(text));

/// Lines of the editor's content, with block embeds by their type.
String _shape(Delta delta) => [
  for (final operation in delta.toList())
    operation.data is String
        ? operation.data as String
        : '[${(operation.data as Map).keys.first}]',
].join();

/// The pictures of the editor's content as data URIs.
List<String> _pictures(Delta delta) => [
  for (final operation in delta.toList())
    if (operation.data case {EmbedTypes.image: final String data}) data,
];

/// Text of the footnotes or endnotes of an opened document; Word's
/// separators (ids -1 and 0) are left out.
List<String> _noteTexts(LoadedDocument document, String kind) => [
  for (final MapEntry(key: id, value: note)
      in _docx.notes(document.source! as DocxPackage, kind).entries)
    if ((int.tryParse(id) ?? 0) > 0)
      Document.fromDelta(note).toPlainText().trim(),
];

/// The attributes of the line that holds [text].
Map<String, dynamic>? _lineAttributes(Delta delta, String text) {
  final operations = delta.toList();
  final index = operations.indexWhere(
    (operation) =>
        operation.data is String && (operation.data as String).contains(text),
  );
  if (index < 0) return null;
  for (var next = index; next < operations.length; next++) {
    final data = operations[next].data;
    if (data is String && data.contains('\n')) {
      return operations[next].attributes;
    }
  }
  return null;
}

TableModel _tableOf(Object? embed) => _tables[tableIdOf(embed)]!;

int _tableIndex(List<Map<String, dynamic>> operations) => operations.indexWhere(
  (operation) =>
      operation['insert'] is Map &&
      (operation['insert'] as Map).containsKey(EmbedTypes.table),
);

void _fill(TableCellModel cell, Delta content) =>
    cell.controller.document.compose(content, ChangeSource.local);

/// Group depth stays positive and ends at zero.
void _expectBalanced(String rtf) {
  var depth = 0;
  for (var index = 0; index < rtf.length; index++) {
    switch (rtf[index]) {
      case r'\':
        index++;
      case '{':
        depth++;
      case '}':
        depth--;
        expect(depth, greaterThanOrEqualTo(0));
    }
  }
  expect(depth, 0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _tables = TableStore();
    _docx = DocxCodec(_tables);
    _codec = RtfCodec(_docx);
  });

  test('formatting survives saving as RTF and opening again', () {
    final table = _tables.createEmpty(rows: 2, columns: 3, totalWidth: 9000);
    _fill(table.rows[0].cells[0], Delta()..insert('Nome', {'bold': true}));
    table.rows[0].cells[1]
      ..gridSpan = 2
      ..fill = const Color(0xFFD9E2F3);
    table.rows[0].cells.removeLast();
    _fill(table.rows[0].cells[1], Delta()..insert('Largo'));
    table.rows[1].cells[2].verticalMerge = VerticalMerge.restart;
    final inner = _tables.createEmpty(rows: 1, columns: 2, totalWidth: 2000);
    _fill(inner.rows[0].cells[1], Delta()..insert('dentro'));
    _fill(
      table.rows[1].cells[1],
      Delta()
        ..insert('antes\n')
        ..insert({EmbedTypes.table: encodeTableId(inner.id)})
        ..insert('\ndepois'),
    );
    final image = 'data:image/png;base64,${base64Encode(_png)}';

    final delta = Delta()
      ..insert('Título do trabalho')
      ..insert('\n', {'header': 1})
      ..insert('Seção')
      ..insert('\n', {'header': 2})
      ..insert('Texto ')
      ..insert('negrito', {'bold': true})
      ..insert(' e ')
      ..insert('itálico vermelho', {'italic': true, 'color': '#FF0000'})
      ..insert(' grande', {'size': '18'})
      ..insert(' marcado', {'background': '#FFFF00'})
      ..insert(' sombreado', {'background': '#D9E2F3'})
      ..insert(' em Georgia', {'font': 'Georgia'})
      ..insert(' sublinhado', {'underline': true})
      ..insert(' riscado', {'strike': true})
      ..insert(' x')
      ..insert('2', {'script': 'super'})
      ..insert(' H')
      ..insert('2', {'script': 'sub'})
      ..insert('O')
      ..insert('\n', {'align': 'justify', 'line-height': 1.5})
      ..insert('linha 1\u{2028}linha 2\tcom tab {chaves} \\ barra')
      ..insert('\n', {'align': 'center'})
      ..insert('ação € 😀 \u{A0}fim\u{AD}\u{2011} 你好 Привет')
      ..insert('\n', {'align': 'right'})
      ..insert('Primeiro')
      ..insert('\n', {'list': 'bullet'})
      ..insert('Dentro')
      ..insert('\n', {'list': 'bullet', 'indent': 1})
      ..insert('Um')
      ..insert('\n', {'list': 'ordered'})
      ..insert('Dois')
      ..insert('\n', {'list': 'ordered'})
      ..insert('Separador')
      ..insert('\n', {
        HiddenAttributes.bookmarks: jsonEncode(['marca']),
      })
      ..insert('Recomeça')
      ..insert('\n', {'list': 'ordered'})
      ..insert('Feito')
      ..insert('\n', {'list': 'checked'})
      ..insert('site', {'link': 'https://omanoloneto.pro/?a=1&b=2'})
      ..insert(' ')
      ..insert('voltar', {'link': '#marca'})
      ..insert(' ')
      ..insert({EmbedTypes.image: image}, {'width': '30', 'height': '30'})
      ..insert({EmbedTypes.pageBreak: 'page'})
      ..insert('\n')
      ..insert({EmbedTypes.table: encodeTableId(table.id)})
      ..insert('\n')
      ..insert('Recuado')
      ..insert('\n', {'indent': 2})
      ..insert('Espaçado')
      ..insert('\n', {
        HiddenAttributes.spaceBefore: 12.0,
        HiddenAttributes.spaceAfter: 18.0,
        HiddenAttributes.firstLine: 36.0,
        HiddenAttributes.indentRight: 72.0,
      })
      ..insert('Fim\n');

    final look = _docx.createEmpty().look;
    final bytes = _codec.encode(delta, look: look);
    final rtf = latin1.decode(bytes);
    expect(bytes.every((byte) => byte < 0x80), isTrue);
    _expectBalanced(rtf);

    final reopened = _codec.decode(bytes);
    final visible = _visible(reopened.delta);
    final expected = _visible(delta);
    final index = _tableIndex(expected);
    expect(_tableIndex(visible), index);
    expected[index] = visible[index];
    final checked = expected.indexWhere(
      (operation) => (operation['attributes'] as Map?)?['list'] == 'checked',
    );
    // Boxes come back as bullets until the .docx reader makes their levels
    // checklists again.
    final box = (visible[checked]['attributes'] as Map?)?['list'];
    expect(box, anyOf('checked', 'bullet'));
    (expected[checked]['attributes'] as Map)['list'] = box;
    expect(visible, expected);

    final spaced = reopened.delta.toList().firstWhere(
      (operation) =>
          operation.attributes?[HiddenAttributes.spaceBefore] != null,
    );
    expect(spaced.attributes?[HiddenAttributes.spaceBefore], 12);
    expect(spaced.attributes?[HiddenAttributes.spaceAfter], 18);
    expect(spaced.attributes?[HiddenAttributes.firstLine], 36);
    expect(spaced.attributes?[HiddenAttributes.indentRight], 72);

    final copy = _tableOf((visible[index]['insert'] as Map)[EmbedTypes.table]);
    expect(copy.columnWidths, [3000, 3000, 3000]);
    expect(copy.bordered, isTrue);
    expect(copy.rows[0].cells, hasLength(2));
    expect(copy.rows[0].cells[1].gridSpan, 2);
    expect(copy.rows[0].cells[1].fill?.toARGB32(), 0xFFD9E2F3);
    expect(copy.rows[1].cells[2].verticalMerge, VerticalMerge.restart);
    expect(_visible(copy.rows[0].cells[0].controller.document.toDelta()), [
      {
        'insert': 'Nome',
        'attributes': {'bold': true},
      },
      {'insert': '\n'},
    ]);
    final cell = copy.rows[1].cells[1].controller.document.toDelta();
    expect(_plain(cell), 'antes\n\tdentro\ndepois\n');

    final numbers = [
      for (final operation in reopened.delta.toList())
        if (operation.attributes?['list'] == 'ordered')
          operation.attributes?[HiddenAttributes.numbering],
    ];
    expect(numbers[0], numbers[1]);
    expect(numbers[2], isNot(numbers[0]), reason: 'a new list starts at 1');
  });

  test('headers, footers and page numbers', () {
    final stories =
        withPageNumber(
          const HeadersFooters(),
          PageNumberPosition.bottomCenter,
        ).copyWith(
          headers: {
            PageVariant.normal: HeaderFooterStory(
              delta: Delta()
                ..insert('Relatório')
                ..insert('\n', {'align': 'right'}),
            ),
            PageVariant.first: HeaderFooterStory(
              delta: Delta()..insert('Capa\n'),
            ),
          },
          differentFirstPage: true,
        );
    final reopened = _codec.decode(
      _codec.encode(Delta()..insert('Texto\n'), headersFooters: stories),
    );
    final again = reopened.headersFooters;
    expect(pageNumberPosition(again), PageNumberPosition.bottomCenter);
    expect(again.differentFirstPage, isTrue);
    expect(
      Document.fromDelta(again.headers[PageVariant.first]!.delta).toPlainText(),
      'Capa\n',
    );
    expect(
      Document.fromDelta(
        again.headers[PageVariant.normal]!.delta,
      ).toPlainText(),
      'Relatório\n',
    );
    expect(Document.fromDelta(reopened.delta).toPlainText(), 'Texto\n');
  });

  test('page size, orientation and margins', () {
    final look = _docx.createEmpty().look.copyWith(
      pageWidth: 841.9,
      pageHeight: 595.3,
      margins: const EdgeInsets.fromLTRB(85.05, 85.05, 56.7, 56.7),
    );
    final bytes = _codec.encode(Delta()..insert('x\n'), look: look);
    expect(latin1.decode(bytes), contains(r'\landscape'));
    final reopened = _codec.decode(bytes).look;
    expect(reopened.pageWidth, closeTo(841.9, 0.1));
    expect(reopened.pageHeight, closeTo(595.3, 0.1));
    expect(reopened.margins.left, closeTo(85.05, 0.1));
    expect(reopened.margins.bottom, closeTo(56.7, 0.1));
    expect(reopened.body.fontFamily, look.body.fontFamily);
    expect(reopened.body.fontSize, look.body.fontSize);
    expect(reopened.lineSpacing, closeTo(look.lineSpacing, 0.01));
  });

  test('links that could do harm are written as text', () {
    final rtf = latin1.decode(
      _codec.encode(
        Delta()
          ..insert('a', {'link': 'javascript:alert(1)'})
          ..insert('b', {'link': r'file:///C:\x'})
          ..insert('c', {'link': 'https://a.example/"x"\\y'})
          ..insert('\n'),
      ),
    );
    expect(rtf, isNot(contains('javascript')));
    expect(rtf, isNot(contains('file:')));
    expect(rtf, contains(r'HYPERLINK "https://a.example/\\"x\\"\\\\y"'));
    final reopened = _codec.decode(Uint8List.fromList(latin1.encode(rtf)));
    expect(
      reopened.delta.toList().last.attributes?['link'] ??
          reopened.delta
              .toList()
              .firstWhere((operation) => operation.data == 'c')
              .attributes?['link'],
      r'https://a.example/"x"\y',
    );
  });

  test('fields of .docx headers stay fields', () {
    final blank = _docx.createEmpty();
    final docx = _docx.decode(
      _docx.encode(
        Delta()..insert('Texto\n'),
        source: blank.source,
        headersFooters: withPageNumber(
          blank.headersFooters,
          PageNumberPosition.topRight,
        ),
      ),
    );
    final rtf = latin1.decode(
      _codec.encode(
        docx.delta,
        look: docx.look,
        headersFooters: docx.headersFooters,
      ),
    );
    expect(rtf, contains(r'{\field{\*\fldinst{ PAGE }}'));
    expect(
      pageNumberPosition(
        _codec.decode(Uint8List.fromList(latin1.encode(rtf))).headersFooters,
      ),
      PageNumberPosition.topRight,
    );
  });

  test('pictures are told by their bytes; GIF and TIFF go as PNG', () {
    final bitmap = Uint8List(14 + 40 + 4);
    ByteData.sublistView(bitmap)
      ..setUint8(0, 0x42)
      ..setUint8(1, 0x4D)
      ..setUint32(2, bitmap.length, Endian.little)
      ..setUint32(10, 54, Endian.little)
      ..setUint32(14, 40, Endian.little)
      ..setInt32(18, 1, Endian.little)
      ..setInt32(22, 1, Endian.little)
      ..setUint16(26, 1, Endian.little)
      ..setUint16(28, 24, Endian.little)
      ..setUint32(34, 4, Endian.little)
      ..setUint8(56, 0xFF);
    final metafile = Uint8List(22 + 18 + 6);
    ByteData.sublistView(metafile)
      ..setUint32(0, 0x9AC6CDD7, Endian.little)
      ..setInt16(10, 1000, Endian.little)
      ..setInt16(12, 1000, Endian.little)
      ..setUint16(14, 1440, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint16(24, 9, Endian.little)
      ..setUint16(26, 0x300, Endian.little)
      ..setUint32(28, 12, Endian.little)
      ..setUint32(40, 3, Endian.little);
    final gif = img.encodeGif(img.Image(width: 2, height: 1));
    final tiff = img.encodeTiff(img.Image(width: 3, height: 2));
    final jpeg = img.encodeJpg(img.Image(width: 4, height: 4));
    String uri(String mime, List<int> bytes) =>
        'data:$mime;base64,${base64Encode(bytes)}';
    final rtf = latin1.decode(
      _codec.encode(
        Delta()
          ..insert({EmbedTypes.image: uri('image/bmp', bitmap)})
          ..insert(
            {EmbedTypes.image: uri('image/x-wmf', metafile)},
            {'width': '50', 'height': '50'},
          )
          ..insert({EmbedTypes.image: uri('image/gif', gif)})
          ..insert({EmbedTypes.image: uri('image/tiff', tiff)})
          // Named photo.png, but a JPEG.
          ..insert({EmbedTypes.image: uri('image/png', jpeg)})
          ..insert({EmbedTypes.image: uri('image/jpeg', _png)})
          ..insert('\n'),
      ),
    );
    expect(rtf, contains(r'\dibitmap0'));
    expect(rtf, contains(r'\wmetafile8'));
    expect(RegExp(r'\\pngblip').allMatches(rtf), hasLength(3));
    expect(RegExp(r'\\jpegblip').allMatches(rtf), hasLength(1));
    expect(rtf, contains(r'\pngblip\picw2\pich1\picwgoal30\pichgoal15'));
    expect(rtf, contains(r'\pngblip\picw3\pich2\picwgoal45\pichgoal30'));

    final pictures = _pictures(
      _codec.decode(Uint8List.fromList(latin1.encode(rtf))).delta,
    );
    expect(pictures, hasLength(6));
    expect(pictures[0], uri('image/bmp', bitmap));
    expect(pictures[1], startsWith('data:image/x-wmf;base64,183GmgAA'));
    for (final (index, size) in [(2, (2, 1)), (3, (3, 2))]) {
      expect(pictures[index], startsWith('data:image/png;'));
      final picture = img.decodePng(decodeDataUri(pictures[index])!.bytes)!;
      expect((picture.width, picture.height), size);
    }
    expect(pictures[4], uri('image/jpeg', jpeg));
    expect(pictures[5], uri('image/png', _png));
  });

  test('tables deeper than RTF readers go are kept as text', () {
    var innermost = _tables.createEmpty(rows: 1, columns: 1, totalWidth: 900);
    _fill(innermost.rows[0].cells[0], Delta()..insert('fundo'));
    for (var level = 0; level < 40; level++) {
      final outer = _tables.createEmpty(rows: 1, columns: 1, totalWidth: 900);
      _fill(
        outer.rows[0].cells[0],
        Delta()..insert({EmbedTypes.table: encodeTableId(innermost.id)}),
      );
      innermost = outer;
    }
    final bytes = _codec.encode(
      Delta()
        ..insert({EmbedTypes.table: encodeTableId(innermost.id)})
        ..insert('\n'),
    );
    _expectBalanced(latin1.decode(bytes));
    expect(_plain(_codec.decode(bytes).delta), contains('fundo'));
  });

  for (final name in [
    'word.rtf',
    'textedit.rtf',
    'textedit_tables.rtf',
    'wordpad.rtf',
  ]) {
    test('$name keeps its content when saved again', () {
      final opened = _codec.decode(
        File('test/fixtures/rtf/$name').readAsBytesSync(),
      );
      final again = _again(opened);
      expect(_plain(again.delta), _plain(opened.delta));
      expect(_visible(again.delta).length, _visible(opened.delta).length);
      expect(again.look.pageWidth, closeTo(opened.look.pageWidth, 0.1));
      expect(again.look.body.fontFamily, opened.look.body.fontFamily);
      final sections = [
        for (final operation in again.delta.toList())
          if (operation.data case {EmbedTypes.sectionBreak: final String xml})
            sectionXmlOf(xml),
      ];
      if (name == 'word.rtf') {
        expect(sections.single, contains('w:orient="landscape"'));
        expect(again.headersFooters.differentFirstPage, isTrue);
        expect(
          pageNumberPosition(again.headersFooters),
          PageNumberPosition.topCenter,
        );
        expect(_noteTexts(again, 'footnote'), ['Texto da nota.']);
      }
    });
  }

  test('the session saves .rtf through the format registry', () {
    final saved = _codec.encode(Delta()..insert('Olá\n'));
    expect(latin1.decode(saved), startsWith(r'{\rtf1\ansi'));
    expect(
      Document.fromDelta(_codec.decode(saved).delta).toPlainText(),
      'Olá\n',
    );
  });

  test('footnotes and endnotes of an .rtf keep their text', () {
    final opened = _openRtf(
      r'{\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}'
      r'\pard Texto{\super\chftn{\footnote\pard\plain{\super\chftn} '
      r'Fonte: {\b IBGE}, 2020.}} e{\super\chftn{\footnote\ftnalt\pard\plain'
      r'{\super\chftn} Ver anexo B.}} fim.\par}',
    );
    expect(opened.notices, isEmpty);

    final saved = _save(opened);
    _expectBalanced(saved);
    expect(saved, contains(r'\fet2'));
    expect(
      saved,
      contains(
        r'Texto{\super\chftn{\footnote\pard\plain\ql\li0\fi0\ri0\sb0\sa0\f0\fs24 '
        r'{\super\chftn} {\fs20 Fonte: }{\b\fs20 IBGE}{\fs20 , 2020.}'
        '\r\n}} e',
      ),
    );
    expect(
      saved,
      contains(
        r'e{\super\chftn{\footnote\ftnalt\pard\plain\ql\li0\fi0\ri0\sb0\sa0'
        r'\f0\fs24 {\super\chftn} {\fs20 Ver anexo B.}'
        '\r\n}} fim.',
      ),
    );
    final again = _openRtf(saved);
    expect(_noteTexts(again, 'footnote'), ['Fonte: IBGE, 2020.']);
    expect(_noteTexts(again, 'endnote'), ['Ver anexo B.']);
    expect(_plain(again.delta), _plain(opened.delta));

    // A note the package doesn't have keeps its number.
    final bare = latin1.decode(_codec.encode(opened.delta, look: opened.look));
    expect(bare, isNot(contains('IBGE')));
    expect(bare, contains(r'Texto{\super 1} e{\super 2} fim.'));
  });

  test('notes of a .docx keep their paragraphs and formatting', () {
    final spec = DocumentSpec()
      ..body.addAll([
        const ParagraphSpec([
          TextSpec('Corpo'),
          NoteSpec(NoteKind.footnote, [
            ParagraphSpec([
              TextSpec('Primeira '),
              TextSpec('nota', RunFormat(italic: true)),
            ]),
            ParagraphSpec([TextSpec('Segundo parágrafo')]),
          ]),
        ]),
        const TableSpec([
          RowSpec([
            CellSpec([
              ParagraphSpec([
                TextSpec('Célula'),
                NoteSpec(NoteKind.endnote, [
                  ParagraphSpec([TextSpec('Nota da célula')]),
                ]),
              ]),
            ]),
          ]),
        ]),
      ]);
    final saved = _save(_docx.read(DocxBuilder(spec).build()));
    _expectBalanced(saved);
    expect(
      saved,
      contains(r'{\super\chftn} {\fs20 Primeira }{\i\fs20 nota}\par'),
    );
    expect(
      saved,
      contains(
        r'C\u233?lula{\super\chftn{\footnote\ftnalt\pard\plain'
        r'\ql\li0\fi0\ri0\sb0\sa0\sl240\slmult1\f0\fs24 {\super\chftn} '
        r'{\fs20 Nota da c\u233?lula}'
        '\r\n}}\\cell',
      ),
    );
    final again = _openRtf(saved);
    expect(_noteTexts(again, 'footnote'), ['Primeira nota\nSegundo parágrafo']);
    expect(_noteTexts(again, 'endnote'), ['Nota da célula']);
  });

  test('single spacing is written when the document has another', () {
    final look = _docx.createEmpty().look;
    expect(look.lineSpacing, isNot(closeTo(1, 0.01)));
    final bytes = _codec.encode(
      Delta()
        ..insert('Corpo em 1,5')
        ..insert('\n', {'line-height': 1.5})
        ..insert('Citação longa')
        ..insert('\n', {'line-height': 1.0})
        ..insert('Normal\n'),
      look: look,
    );
    expect(_line(latin1.decode(bytes), 'Cita'), contains(r'\sl240\slmult1'));
    final reopened = _codec.decode(bytes).delta;
    expect(_lineAttributes(reopened, 'Corpo')?['line-height'], 1.5);
    expect(_lineAttributes(reopened, 'Citação')?['line-height'], 1.0);
    expect(_lineAttributes(reopened, 'Normal')?['line-height'], isNull);
  });

  test('numbered lists in table cells each start at 1', () {
    Delta steps() => Delta()
      ..insert('Passo')
      ..insert('\n', {'list': 'ordered'})
      ..insert('Outro passo')
      ..insert('\n', {'list': 'ordered'});
    final table = TableModel(
      id: _tables.nextId(),
      bordered: true,
      columnWidths: [4000, 4000],
      rows: [
        TableRowModel(
          cells: [
            TableCellModel(controller: _tables.newCellController(steps())),
            TableCellModel(controller: _tables.newCellController(steps())),
          ],
        ),
      ],
    );
    _tables.add(table);
    final rtf = latin1.decode(
      _codec.encode(
        Delta()
          ..insert('Antes')
          ..insert('\n', {'list': 'ordered'})
          ..insert({EmbedTypes.table: encodeTableId(table.id)})
          ..insert('\n')
          ..insert('Depois')
          ..insert('\n', {'list': 'ordered'}),
      ),
    );
    final items = [
      for (final match in RegExp(
        r'\\ls(\d+)\\ilvl0.*?\{\\listtext\\f0 ([^\\]*)\\tab\}(\w+)',
      ).allMatches(rtf))
        '${match[1]} ${match[2]} ${match[3]}',
    ];
    expect(items, [
      '1 1. Antes',
      '2 1. Passo',
      '2 2. Outro',
      '3 1. Passo',
      '3 2. Outro',
      '4 1. Depois',
    ]);
  });

  test('hidden text stays hidden instead of being deleted', () {
    final opened = _openRtf(
      r'{\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}'
      r'\pard Visivel {\v\b gabarito: B} fim.\par}',
    );
    expect(opened.notices, isEmpty);
    final saved = _save(opened);
    expect(
      _line(saved, 'Visivel'),
      contains(r'Visivel {\b\v gabarito: B} fim.'),
    );
    final again = _openRtf(saved);
    final document = DocxPackage.decode(
      _docx.encode(again.delta, source: again.source),
    ).text('word/document.xml')!;
    expect(document, contains('<w:vanish/>'));
    expect(document, contains('gabarito: B'));
  });

  test('objects, VML pictures and drawing fallbacks keep their picture', () {
    final picture = img.encodePng(img.Image(width: 4, height: 2));
    final opened = _openDocx(
      '<w:p><w:r><w:t xml:space="preserve">Antes </w:t></w:r>'
      '<w:r><w:pict><v:shape style="width:30pt;height:15pt">'
      '<v:imagedata r:id="rIdM1"/></v:shape></w:pict></w:r>'
      '<w:r><w:t xml:space="preserve"> depois</w:t></w:r></w:p>'
      '<w:p><w:r><w:t xml:space="preserve">Objeto </w:t></w:r>'
      '<w:r><w:object w:dxaOrig="900" w:dyaOrig="450">'
      '<v:shape style="width:45pt;height:22.5pt">'
      '<v:imagedata r:id="rIdM1" o:title=""/></v:shape>'
      '<o:OLEObject Type="Embed" ProgID="Excel.Sheet.12" r:id="rIdX"/>'
      '</w:object></w:r></w:p>'
      '<w:p><w:r><w:t xml:space="preserve">Gráfico </w:t></w:r>'
      '<w:r><mc:AlternateContent><mc:Choice Requires="cx1"><w:drawing>'
      '<wp:inline><wp:extent cx="762000" cy="381000"/><a:graphic>'
      '<a:graphicData uri="http://schemas.microsoft.com/office/drawing/2014/chartex">'
      '<cx:chart r:id="rIdX"/></a:graphicData></a:graphic></wp:inline>'
      '</w:drawing></mc:Choice><mc:Fallback><w:drawing><wp:inline>'
      '<wp:extent cx="762000" cy="381000"/><a:graphic><a:graphicData '
      'uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
      '<pic:pic><pic:blipFill><a:blip r:embed="rIdM1"/></pic:blipFill>'
      '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>'
      '</mc:Fallback></mc:AlternateContent></w:r></w:p>',
      media: {'image1.png': picture},
    );
    expect(_pictures(opened.delta), isEmpty, reason: 'protected content');

    final saved = _save(opened);
    expect(
      _line(saved, 'Antes'),
      endsWith(r'Antes {\pict\pngblip\picw4\pich2\picwgoal600\pichgoal300'),
    );
    expect(
      _line(saved, 'Objeto'),
      endsWith(r'Objeto {\pict\pngblip\picw4\pich2\picwgoal900\pichgoal450'),
    );
    expect(_line(saved, 'Gr'), endsWith(r'\picwgoal1200\pichgoal600'));
    expect(
      _pictures(_openRtf(saved).delta),
      List.filled(3, 'data:image/png;base64,${base64Encode(picture)}'),
    );
  });

  test('link addresses beyond ASCII are percent-encoded', () {
    final rtf = latin1.decode(
      _codec.encode(
        Delta()
          ..insert('São Paulo', {
            'link': 'https://pt.wikipedia.org/wiki/São_Paulo',
          })
          ..insert(' ')
          ..insert('voltar', {'link': '#Seção'})
          ..insert('\n', {
            HiddenAttributes.bookmarks: jsonEncode(['Seção']),
          }),
      ),
    );
    expect(
      rtf,
      contains(
        r'HYPERLINK "https://pt.wikipedia.org/wiki/S%C3%A3o_Paulo"}}'
        r'{\fldrslt{{\ul\cf1 S\u227?o Paulo}}}',
      ),
    );
    expect(rtf, contains(r'HYPERLINK \\l "Se\u231?\u227?o"'));
    final reopened = _openRtf(rtf).delta.toList();
    expect(
      reopened.firstWhere((op) => op.data == 'São Paulo').attributes?['link'],
      'https://pt.wikipedia.org/wiki/S%C3%A3o_Paulo',
    );
  });

  test('list items and paragraph groups add no space between them', () {
    final look = _docx.createEmpty().look;
    final rtf = latin1.decode(
      _codec.encode(
        Delta()
          ..insert('Um')
          ..insert('\n', {'list': 'bullet'})
          ..insert('Dois')
          ..insert('\n', {'list': 'bullet'})
          ..insert('Junto um')
          ..insert('\n', {
            HiddenAttributes.contextualGroup: 'Normal',
            HiddenAttributes.spaceAfter: 12.0,
          })
          ..insert('Junto dois')
          ..insert('\n', {
            HiddenAttributes.contextualGroup: 'Normal',
            HiddenAttributes.spaceAfter: 12.0,
          })
          ..insert('Citação um')
          ..insert('\n', {HiddenAttributes.contextualGroup: 'Citacao'})
          ..insert('Citação dois')
          ..insert('\n', {HiddenAttributes.contextualGroup: 'Citacao'})
          ..insert('Fim\n'),
        look: look,
      ),
    );
    expect(rtf, contains(r'\contextualspace \f0\fs24 \sbasedon0\snext7 List'));
    expect(
      rtf,
      contains(r'\contextualspace \f0\fs24 \sbasedon0\snext8 Citacao'),
    );
    expect(_line(rtf, 'Dois'), startsWith(r'\pard\plain\s7\ql\ls1'));
    expect(_line(rtf, 'Dois'), contains(r'\contextualspace'));
    expect(_line(rtf, 'Junto dois'), startsWith(r'\pard\plain\ql'));
    expect(_line(rtf, 'Junto dois'), contains(r'\sa240'));
    expect(_line(rtf, 'Junto dois'), contains(r'\contextualspace'));
    expect(
      _line(rtf, r'Cita\u231?\u227?o dois'),
      startsWith(r'\pard\plain\s8'),
    );
    expect(_line(rtf, 'Fim'), isNot(contains(r'\contextualspace')));

    final reopened = _openRtf(rtf).delta;
    expect(_lineAttributes(reopened, 'Dois')?['list'], 'bullet');
    final groups = [
      for (final text in [
        'Junto um',
        'Junto dois',
        'Citação um',
        'Citação dois',
        'Fim',
      ])
        _lineAttributes(reopened, text)?[HiddenAttributes.contextualGroup],
    ];
    expect(groups[0], isNotNull);
    expect(groups[1], groups[0]);
    expect(groups[2], isNotNull);
    expect(groups[3], groups[2]);
    expect(groups[2], isNot(groups[0]));
    expect(groups[4], isNull);
  });

  test('bookmarks span their paragraph and REF fields name them alike', () {
    String field(String instruction, String result) => OpaqueContent(
      xml:
          '<w:fldSimple w:instr="$instruction"><w:r><w:t>$result</w:t></w:r>'
          '</w:fldSimple>',
      text: result,
    ).encode();
    final rtf = latin1.decode(
      _codec.encode(
        Delta()
          ..insert('Figura 1 - Mapa')
          ..insert('\n', {
            HiddenAttributes.bookmarks: jsonEncode(['_Ref1']),
          })
          ..insert('Tabela 2')
          ..insert('\n', {
            HiddenAttributes.bookmarks: jsonEncode(['Tabela-2']),
          })
          ..insert('Ver ')
          ..insert({
            EmbedTypes.opaqueInline: field(r' REF _Ref1 \h ', 'Figura 1'),
          })
          ..insert(' e ')
          ..insert({
            EmbedTypes.opaqueInline: field(r' PAGEREF Tabela-2 \h ', '1'),
          })
          ..insert('.\n'),
      ),
    );
    expect(
      _line(rtf, 'Mapa'),
      endsWith(r'{\*\bkmkstart _Ref1}Figura 1 - Mapa{\*\bkmkend _Ref1}\par'),
    );
    expect(
      _line(rtf, 'Tabela 2'),
      endsWith(r'{\*\bkmkstart Tabela_2}Tabela 2{\*\bkmkend Tabela_2}\par'),
    );
    expect(rtf, contains(r'{\*\fldinst{ REF _Ref1 \\h }}'));
    expect(rtf, contains(r'{\*\fldinst{ PAGEREF Tabela_2 \\h }}'));
  });

  test('empty paragraphs before a section break survive saving again', () {
    final section = encodeSection(
      '<w:sectPr xmlns:w="${Namespaces.w}">'
      '<w:pgSz w:w="11906" w:h="16838"/></w:sectPr>',
    );
    final delta = Delta()
      ..insert('Capa\n\n\n')
      ..insert({EmbedTypes.sectionBreak: section})
      ..insert('\n')
      ..insert('Resumo\n')
      ..insert({EmbedTypes.sectionBreak: section})
      ..insert('\n')
      ..insert('Texto\n');
    final look = _docx.createEmpty().look;
    final rtf = latin1.decode(_codec.encode(delta, look: look));
    expect(rtf, contains('Resumo\\sect\r\n'));
    final once = _codec.decode(Uint8List.fromList(latin1.encode(rtf)));
    expect(_shape(once.delta), _shape(delta));
    expect(_shape(_again(once).delta), _shape(delta));
  });

  test('each section says whether its first page differs', () {
    String titlePages(String sectionXml, {required bool differentFirstPage}) {
      final rtf = latin1.decode(
        _codec.encode(
          Delta()
            ..insert('Capa\n')
            ..insert({
              EmbedTypes.sectionBreak: encodeSection(
                '<w:sectPr xmlns:w="${Namespaces.w}">'
                '<w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/>'
                '$sectionXml</w:sectPr>',
              ),
            })
            ..insert('\n')
            ..insert('Texto\n'),
          look: _docx.createEmpty().look,
          headersFooters: const HeadersFooters().copyWith(
            differentFirstPage: differentFirstPage,
          ),
        ),
      );
      return [
        for (final match in RegExp(r'\\sectd[^\r\n]*').allMatches(rtf))
          match[0]!.contains(r'\titlepg') ? 'first' : 'same',
      ].join(' ');
    }

    expect(titlePages('', differentFirstPage: true), 'same first');
    expect(titlePages('<w:titlePg/>', differentFirstPage: false), 'first same');
    expect(
      titlePages('<w:titlePg w:val="0"/>', differentFirstPage: true),
      'same first',
    );
  });

  test('each section keeps how it numbers its pages', () {
    String paragraph(String text, String numbers) =>
        '<w:p><w:pPr><w:sectPr><w:pgSz w:w="11906" w:h="16838"/>$numbers'
        '</w:sectPr></w:pPr><w:r><w:t>$text</w:t></w:r></w:p>';
    final opened = _openDocx(
      '${paragraph('Preface', '<w:pgNumType w:fmt="lowerRoman"/>')}'
      '${paragraph('Chapter', '<w:pgNumType w:start="1"/>')}'
      '${paragraph('Notes', '')}'
      '<w:p><w:r><w:t>Appendix</w:t></w:r></w:p>',
      section: '<w:pgNumType w:fmt="upperLetter" w:start="3"/>',
    );
    final rtf = _save(opened);
    final sections = [
      for (final match in RegExp(r'\\sectd[^\r\n]*').allMatches(rtf)) match[0]!,
    ];

    expect(sections, hasLength(4));
    expect(sections[0], contains(r'\pgnlcrm'));
    expect(sections[0], isNot(contains(r'\pgnrestart')));
    expect(sections[1], contains(r'\pgnrestart\pgnstarts1'));
    expect(sections[2], isNot(contains(r'\pgn')));
    expect(sections[3], contains(r'\pgnucltr\pgnrestart\pgnstarts3'));

    final again = _openRtf(rtf);
    final breaks = [
      for (final operation in again.delta.toList())
        if (operation.data case {EmbedTypes.sectionBreak: final String xml})
          sectionXmlOf(xml),
    ];
    expect(breaks, hasLength(3));
    expect(breaks[0], contains('<w:pgNumType w:fmt="lowerRoman"/>'));
    expect(breaks[1], contains('<w:pgNumType w:start="1"/>'));
    expect(breaks[2], isNot(contains('pgNumType')));
    expect(
      (again.source! as DocxPackage).text('word/document.xml'),
      contains('<w:pgNumType w:fmt="upperLetter" w:start="3"/>'),
    );
  });

  test('fields keep their character formatting', () {
    final opened = _openRtf(
      r'{\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}'
      r'\sectd{\footer\pard\plain\qc {\b\fs16 Pagina }{\field{\*\fldinst'
      r'{\b\fs16 PAGE }}{\fldrslt{\b\fs16 1}}}\par}'
      r'\pard\plain Corpo\par}',
    );
    final saved = _save(opened);
    expect(
      _line(saved, 'PAGE'),
      contains(r'{\field{\*\fldinst{\b\fs16 PAGE }}{\fldrslt{\b\fs16 1}}}'),
    );
    final again = _openRtf(saved).headersFooters.footers[PageVariant.normal]!;
    final field = again.delta.toList().firstWhere(
      (operation) => operation.data is Map,
    );
    expect(
      OpaqueContent.decode((field.data as Map)[EmbedTypes.opaqueInline]).xml,
      allOf(contains('<w:b/>'), contains('<w:sz w:val="16"/>')),
    );
  });

  test('Word lists keep their number formats, starts and counting', () async {
    String level(int level, String format, String text) =>
        '<w:lvl w:ilvl="$level"><w:start w:val="1"/>'
        '<w:numFmt w:val="$format"/><w:lvlText w:val="$text"/><w:pPr>'
        '<w:ind w:left="${720 * (level + 1)}" w:hanging="360"/></w:pPr>'
        '</w:lvl>';
    String item(String text, [int? numId, int level = 0]) =>
        '<w:p>${numId == null ? '' : '<w:pPr><w:numPr><w:ilvl w:val="$level"/>'
                  '<w:numId w:val="$numId"/></w:numPr></w:pPr>'}'
        '<w:r><w:t>$text</w:t></w:r></w:p>';
    final opened = _openDocx(
      [
        item('Alpha', 1),
        item('Beta', 1),
        item('Beta sub', 1, 1),
        item('One', 2),
        item('One one', 2, 1),
        item('Break'),
        item('Two', 2),
        item('Roman', 3),
        item('Roman two', 3),
        item('Five', 4),
        item('Six', 4),
        item('Fruit', 5),
        item('Apple', 5, 1),
        item('Pear', 5, 1),
        item('Leaf', 5),
        item('Leek', 5, 1),
      ].join(),
      numbering:
          '<w:numbering xmlns:w="${Namespaces.w}">'
          '<w:abstractNum w:abstractNumId="1">'
          '${level(0, 'lowerLetter', '%1)')}${level(1, 'lowerRoman', '(%2)')}'
          '</w:abstractNum><w:abstractNum w:abstractNumId="2">'
          '${level(0, 'decimal', '%1.')}${level(1, 'decimal', '%1.%2.')}'
          '</w:abstractNum><w:abstractNum w:abstractNumId="3">'
          '${level(0, 'upperRoman', '%1.')}'
          '</w:abstractNum><w:abstractNum w:abstractNumId="4">'
          '${level(0, 'bullet', '–')}${level(1, 'decimal', '%2.')}'
          '</w:abstractNum>'
          '<w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>'
          '<w:num w:numId="2"><w:abstractNumId w:val="2"/></w:num>'
          '<w:num w:numId="3"><w:abstractNumId w:val="3"/></w:num>'
          '<w:num w:numId="4"><w:abstractNumId w:val="2"/><w:lvlOverride '
          'w:ilvl="0"><w:startOverride w:val="5"/></w:lvlOverride></w:num>'
          '<w:num w:numId="5"><w:abstractNumId w:val="4"/></w:num>'
          '</w:numbering>',
    );
    final rtf = _save(opened);
    _expectBalanced(rtf);
    // The number readers without lists show, without its punctuation.
    String shown(String text) => RegExp(
      r'\{\\listtext\\f\d+ (\w+)[^}]*\\tab\}'
      '${RegExp.escape(text)}'
      r'\\par',
    ).firstMatch(rtf)![1]!;
    expect(shown('Beta'), 'b');
    expect(shown('Beta sub'), 'i');
    expect(shown('Two'), '2', reason: 'an interrupted list goes on');
    expect(shown('Roman two'), 'II');
    expect(shown('Five'), '5');
    expect(shown('Six'), '6');
    expect(shown('Leek'), '1', reason: 'numbers restart under each bullet');

    final reopened = _again(opened);
    final numbering = ListNumbering.of(reopened.source);
    final lines = {
      for (final block in documentBlocks(reopened.delta))
        if (block is LineBlock) block.plainText: block,
    };
    int numId(String text) =>
        (lines[text]!.attributes[HiddenAttributes.numbering] as num).toInt();
    String? format(String text, [int level = 0]) =>
        numbering.level(numId(text), level)?.format;
    expect(format('Alpha'), 'lowerLetter');
    expect(format('Alpha', 1), 'lowerRoman');
    expect(format('One', 1), 'decimal');
    expect(format('Roman'), 'upperRoman');
    expect(format('Fruit'), 'bullet');
    expect(format('Fruit', 1), 'decimal');
    expect(numbering.level(numId('Five'), 0)?.start, 5);
    expect(numId('Two'), numId('One'));
    expect(numId('Five'), isNot(numId('One')));
    expect(numId('Leek'), numId('Fruit'));
    expect(lines['Leek']!.list, 'ordered');
    expect(lines['Leaf']!.list, 'bullet');

    final textutil = File('/usr/bin/textutil');
    if (!textutil.existsSync()) return;
    final folder = Directory.systemTemp.createTempSync('rtf_lists');
    addTearDown(() => folder.deleteSync(recursive: true));
    final file = File('${folder.path}/lists.rtf')
      ..writeAsStringSync(rtf, encoding: latin1);
    final result = await Process.run(textutil.path, [
      '-convert',
      'html',
      file.path,
      '-stdout',
    ]);
    expect(result.exitCode, 0);
    expect(
      result.stdout,
      allOf(
        contains('list-style-type: lower-alpha'),
        contains('list-style-type: lower-roman'),
        contains('list-style-type: upper-roman'),
        contains('Leek'),
      ),
    );
  });

  test('checklist items are bullets of boxes in Segoe UI Symbol', () {
    final rtf = latin1.decode(
      _codec.encode(
        Delta()
          ..insert('Done')
          ..insert('\n', {'list': 'checked'})
          ..insert('Open')
          ..insert('\n', {'list': 'unchecked'})
          ..insert('Inside')
          ..insert('\n', {'list': 'checked', 'indent': 1}),
        look: _docx.createEmpty().look,
      ),
    );
    final font = RegExp(
      r'\{\\f(\d+)\\fnil\\fcharset0 Segoe UI Symbol;\}',
    ).firstMatch(rtf)![1];
    for (final (marker, box) in [('check', '9745'), ('box', '9744')]) {
      expect(
        rtf,
        contains(
          '{\\*\\levelmarker \\{$marker\\}}'
          "{\\leveltext\\'01\\u$box?;}{\\levelnumbers;}\\f$font\\fi-360\\li720",
        ),
      );
    }
    expect(_line(rtf, 'Done'), contains('{\\listtext\\f$font \\u9745?\\tab}'));
    expect(_line(rtf, 'Open'), contains('{\\listtext\\f$font \\u9744?\\tab}'));
    expect(_line(rtf, 'Inside'), contains(r'\ilvl1'));

    final reopened = _openRtf(rtf);
    final numbering = (reopened.source! as DocxPackage).text(
      'word/numbering.xml',
    )!;
    for (final box in ['☑', '☐']) {
      expect(
        numbering,
        contains('<w:numFmt w:val="bullet"/><w:lvlText w:val="$box"/>'),
      );
    }
    expect(
      RegExp('w:ascii="Segoe UI Symbol"').allMatches(numbering),
      hasLength(18),
    );
    expect(
      _lineAttributes(reopened.delta, 'Done')?[HiddenAttributes.numbering],
      isNot(
        _lineAttributes(reopened.delta, 'Open')?[HiddenAttributes.numbering],
      ),
    );
  });
}
