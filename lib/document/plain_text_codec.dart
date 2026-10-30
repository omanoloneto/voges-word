import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';

import 'document_codec.dart';
import 'document_look.dart';
import 'embeds.dart';
import 'headers_footers.dart';
import 'tables.dart';
import 'text_encodings.dart';

class PlainTextCodec implements DocumentCodec {
  PlainTextCodec({required this.look, required this.tables});

  final DocumentLook look;
  final TableStore tables;

  @override
  LoadedDocument decode(Uint8List bytes) {
    final text = decodeText(
      bytes,
    ).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final delta = Delta();
    if (text.isNotEmpty) delta.insert(text);
    if (!text.endsWith('\n')) delta.insert('\n');
    return LoadedDocument(delta: delta, look: look);
  }

  @override
  Uint8List encode(
    Delta delta, {
    Object? source,
    DocumentLook look = const DocumentLook(),
    bool pageSetupChanged = false,
    HeadersFooters? headersFooters,
  }) => Uint8List.fromList(utf8.encode(plainTextOf(delta)));

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
}
