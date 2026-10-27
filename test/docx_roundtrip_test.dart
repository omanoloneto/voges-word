import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_quill/flutter_quill.dart' show Document;
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/docx/word_xml.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:xml/xml.dart';

// PNG 1x1 transparente.
final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

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

void _expectValidPackage(Uint8List bytes) {
  final package = DocxPackage.decode(bytes);
  for (final entry in package.parts.entries) {
    if (entry.key.endsWith('.xml') || entry.key.endsWith('.rels')) {
      expect(
        () => XmlDocument.parse(package.text(entry.key)!),
        returnsNormally,
        reason: entry.key,
      );
    }
  }
  final document = package.xml(package.mainDocumentPath)!;
  final x = WordXml(document.rootElement);
  for (final element in document.descendantElements) {
    if (x.isW(element, 'pPr') || x.isW(element, 'rPr')) {
      final order = x.isW(element, 'pPr')
          ? paragraphPropertyOrder
          : runPropertyOrder;
      final names = element.childElements.map((e) => e.name.local).toList();
      final ranks = names
          .map(order.indexOf)
          .where((rank) => rank >= 0)
          .toList();
      final sorted = [...ranks]..sort();
      expect(ranks, sorted, reason: 'ordem em ${element.name.local}: $names');
    }
  }
  final ids = package
      .relationships(package.mainDocumentPath)
      .map((r) => r.id)
      .toSet();
  for (final match in RegExp(
    r'r:(?:id|embed)="([^"]+)"',
  ).allMatches(package.text(package.mainDocumentPath)!)) {
    expect(ids, contains(match[1]), reason: 'relação ${match[1]}');
  }
}

void main() {
  late TableStore tables;
  late DocxCodec codec;

  setUp(() {
    tables = TableStore();
    codec = DocxCodec(tables);
  });

  test('documento novo usa o modelo padrão', () {
    final document = codec.createEmpty();
    expect(document.delta.toList().single.data, '\n');
    expect(document.look.body.fontFamily, 'Arial');
    expect(document.look.body.fontSize, 12);
    expect(document.look.headings[1]?.bold, isTrue);
  });

  test('formatação sobrevive a salvar e abrir de novo', () {
    final table = tables.createEmpty(rows: 2, columns: 2, totalWidth: 9000);
    table.rows[0].cells[0].controller.document.insert(0, 'Nome');
    table.rows[1].cells[1].controller.document.insert(0, 'Valor');
    final image = 'data:image/png;base64,${base64Encode(_pixel)}';

    final delta = Delta()
      ..insert('Título do trabalho')
      ..insert('\n', {'header': 1})
      ..insert('Texto ')
      ..insert('negrito', {'bold': true})
      ..insert(' e ')
      ..insert('itálico vermelho', {'italic': true, 'color': '#FF0000'})
      ..insert(' grande', {'size': '18'})
      ..insert(' marcado', {'background': '#FFFF00'})
      ..insert(' em Georgia', {'font': 'Georgia'})
      ..insert(' sublinhado', {'underline': true})
      ..insert(' riscado', {'strike': true})
      ..insert('\n', {'align': 'justify', 'line-height': 1.5})
      ..insert('linha 1\u2028linha 2\tcom tab')
      ..insert('\n', {'align': 'center'})
      ..insert('Primeiro')
      ..insert('\n', {'list': 'bullet'})
      ..insert('Dentro')
      ..insert('\n', {'list': 'bullet', 'indent': 1})
      ..insert('Um')
      ..insert('\n', {'list': 'ordered'})
      ..insert('Dois')
      ..insert('\n', {'list': 'ordered'})
      ..insert('Separador\n')
      ..insert('Recomeça')
      ..insert('\n', {'list': 'ordered'})
      ..insert('site', {'link': 'https://omanoloneto.pro'})
      ..insert(' ')
      ..insert({EmbedTypes.image: image})
      ..insert({EmbedTypes.pageBreak: 'page'})
      ..insert('\n')
      ..insert({EmbedTypes.table: encodeTableId(table.id)})
      ..insert('\n')
      ..insert('Recuado')
      ..insert('\n', {'indent': 2})
      ..insert('Fim\n');

    final bytes = codec.encode(delta);
    _expectValidPackage(bytes);

    final reopened = codec.decode(bytes);
    final visible = _visible(reopened.delta);
    final tableOp = visible.indexWhere(
      (op) =>
          op['insert'] is Map &&
          (op['insert'] as Map).containsKey(EmbedTypes.table),
    );
    expect(tableOp, isNot(-1));
    final reopenedTable =
        tables[tableIdOf(
          (visible[tableOp]['insert'] as Map)[EmbedTypes.table],
        )]!;
    expect(reopenedTable.rows.length, 2);
    expect(
      reopenedTable.rows[0].cells[0].controller.document.toPlainText(),
      'Nome\n',
    );
    expect(
      reopenedTable.rows[1].cells[1].controller.document.toPlainText(),
      'Valor\n',
    );

    final expected = _visible(delta);
    expected[tableOp] = visible[tableOp];
    final imageOp = expected.indexWhere(
      (op) =>
          op['insert'] is Map &&
          (op['insert'] as Map).containsKey(EmbedTypes.image),
    );
    expect((visible[imageOp]['insert'] as Map)[EmbedTypes.image], image);
    expect(visible, expected);
  });

  test('salvar de novo preserva o xml original do que não é editado', () {
    final first = codec.encode(
      Delta()
        ..insert('Antes ')
        ..insert({
          EmbedTypes.image: 'data:image/png;base64,${base64Encode(_pixel)}',
        })
        ..insert('\n'),
    );
    final reopened = codec.decode(first);
    final second = codec.encode(reopened.delta, source: reopened.source);
    _expectValidPackage(second);
    final package = DocxPackage.decode(second);
    final media = package.parts.keys.where(
      (name) => name.startsWith('word/media/'),
    );
    expect(media.length, 1, reason: 'a imagem original é reaproveitada');
  });

  test('documentos reais abrem e salvam sem erro', () {
    final folder = Platform.environment['VW_SAMPLES'];
    if (folder == null) return;
    for (final file in Directory(folder).listSync().whereType<File>()) {
      if (!file.path.endsWith('.docx')) continue;
      final opened = codec.decode(file.readAsBytesSync());
      final saved = codec.encode(opened.delta, source: opened.source);
      _expectValidPackage(saved);
      final again = codec.decode(saved);
      final text = PlainTextCodec(look: opened.look, tables: tables);
      expect(
        text.plainTextOf(again.delta),
        text.plainTextOf(opened.delta),
        reason: file.path,
      );
      expect(
        _visible(again.delta).length,
        _visible(opened.delta).length,
        reason: file.path,
      );
    }
  });
}
