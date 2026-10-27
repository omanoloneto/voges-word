import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';

import 'document_codec.dart';
import 'document_look.dart';
import 'embeds.dart';
import 'tables.dart';

class PlainTextCodec implements DocumentCodec {
  PlainTextCodec({required this.look, required this.tables});

  final DocumentLook look;
  final TableStore tables;

  @override
  DocumentFormat get format => DocumentFormat.plainText;

  @override
  LoadedDocument decode(Uint8List bytes) {
    final text = _decodeText(
      bytes,
    ).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final delta = Delta();
    if (text.isNotEmpty) delta.insert(text);
    if (!text.endsWith('\n')) delta.insert('\n');
    return LoadedDocument(delta: delta, look: look);
  }

  @override
  Uint8List encode(Delta delta, {Object? source}) =>
      Uint8List.fromList(utf8.encode(plainTextOf(delta)));

  String plainTextOf(Delta delta) {
    final out = StringBuffer();
    for (final operation in delta.toList()) {
      final data = operation.data;
      if (data is String) {
        out.write(data.replaceAll('\u2028', '\n'));
        continue;
      }
      if (data is! Map) continue;
      final value = data.values.first;
      switch (data.keys.first) {
        case EmbedTypes.opaqueInline || EmbedTypes.opaqueBlock:
          out.write(OpaqueContent.decode(value).text);
        case EmbedTypes.pageBreak:
          out.write('\n');
        case EmbedTypes.table:
          final table = tables[tableIdOf(value)];
          if (table == null) break;
          out.write(
            table.rows
                .map(
                  (row) => row.cells
                      .map(
                        (cell) => plainTextOf(
                          cell.controller.document.toDelta(),
                        ).trim().replaceAll('\n', ' '),
                      )
                      .join('\t'),
                )
                .join('\n'),
          );
      }
    }
    return out.toString();
  }

  static String _decodeText(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 &&
        (bytes[0] == 0xFF && bytes[1] == 0xFE ||
            bytes[0] == 0xFE && bytes[1] == 0xFF)) {
      final littleEndian = bytes[0] == 0xFF;
      final units = <int>[
        for (var i = 2; i + 1 < bytes.length; i += 2)
          littleEndian
              ? bytes[i] | bytes[i + 1] << 8
              : bytes[i] << 8 | bytes[i + 1],
      ];
      return String.fromCharCodes(units);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }
}
