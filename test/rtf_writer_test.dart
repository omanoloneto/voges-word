import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show Color, EdgeInsets;
import 'package:flutter_quill/flutter_quill.dart' show ChangeSource, Document;
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/document_look.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/headers_footers.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/editor/page_numbers.dart';
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

LoadedDocument _again(LoadedDocument document) => _codec.decode(
  _codec.encode(
    document.delta,
    look: document.look,
    headersFooters: document.headersFooters,
  ),
);

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
    (expected[checked]['attributes'] as Map)['list'] = 'bullet';
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

  test('fields of .docx headers stay fields; notes keep their number', () {
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

  test('bitmaps and metafiles are kept; other pictures are left out', () {
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
    final gif = base64Decode(
      'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
    );
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
          ..insert('\n'),
      ),
    );
    expect(rtf, contains(r'\dibitmap0'));
    expect(rtf, contains(r'\wmetafile8'));
    final pictures = [
      for (final operation
          in _codec
              .decode(Uint8List.fromList(latin1.encode(rtf)))
              .delta
              .toList())
        if (operation.data case {EmbedTypes.image: final String data}) data,
    ];
    expect(pictures, hasLength(2));
    expect(pictures.first, uri('image/bmp', bitmap));
    expect(pictures.last, startsWith('data:image/x-wmf;base64,183GmgAA'));
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
}
