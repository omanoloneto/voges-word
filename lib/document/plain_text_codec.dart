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
  LoadedDocument decode(Uint8List bytes) => load(prepare(bytes));

  /// The text of the file, with its line breaks as `\n`.
  static PreparedText prepare(Uint8List bytes) => PreparedText(
    decodeText(bytes).replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
  );

  @override
  LoadedDocument load(covariant PreparedText prepared) {
    final text = prepared.text;
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
        out.write(_withLineBreaks(data));
        continue;
      }
      if (data is! Map) continue;
      final value = data.values.first;
      switch (data.keys.first) {
        case EmbedTypes.opaqueInline || EmbedTypes.opaqueBlock:
          out.write(_withLineBreaks(OpaqueContent.decode(value).text));
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

  static String _withLineBreaks(String text) => text.replaceAll('\u2028', '\n');
}
