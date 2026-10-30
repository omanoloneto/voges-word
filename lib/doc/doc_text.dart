import 'dart:typed_data';

import '../document/document_codec.dart';
import '../document/text_encodings.dart';
import 'byte_view.dart';

/// A run of the document's characters stored together in the WordDocument
/// stream.
class Piece {
  const Piece(this.start, this.end, this.offset, this.compressed, this.prm);

  /// Character positions [start, end).
  final int start;
  final int end;

  /// Byte offset of [start] in the WordDocument stream.
  final int offset;

  /// One byte per character instead of two.
  final bool compressed;

  /// Property modifier: formatting saved by a fast save.
  final int prm;

  int get width => compressed ? 1 : 2;

  int offsetOf(int position) => offset + (position - start) * width;
}

/// The document's characters, rebuilt from the piece table in the Clx
/// (MS-DOC 2.4.1).
class PieceTable {
  PieceTable._(this.pieces, this.modifiers, this.text);

  /// Throws [DocumentProblemException] with [DocumentProblem.tooLarge] past
  /// [maxCharacters] and a [FormatException] when the table is damaged.
  factory PieceTable.parse(
    ByteView clx,
    ByteView wordDocument, {
    required int maxCharacters,
  }) {
    var at = 0;
    final modifiers = <Uint8List>[];
    late final ByteView plc;
    while (true) {
      final type = clx.u8(at);
      if (type == 0x01) {
        final size = clx.i16(at + 1);
        if (size < 0) throw const FormatException('Bad Prc');
        modifiers.add(clx.slice(at + 3, size));
        at += 3 + size;
      } else if (type == 0x02) {
        plc = clx.view(at + 5, clx.u32(at + 1));
        break;
      } else {
        throw const FormatException('Bad Clx');
      }
    }

    if (plc.length < 16 || (plc.length - 4) % 12 != 0) {
      throw const FormatException('Bad PlcPcd');
    }
    final count = (plc.length - 4) ~/ 12;
    final pieces = <Piece>[];
    var previous = 0;
    // Pieces that share their bytes would repeat the same text many times;
    // without sharing, they can't hold more than the stream does.
    var stored = 0;
    for (var index = 0; index < count; index++) {
      final start = plc.i32(index * 4);
      final end = plc.i32(index * 4 + 4);
      if (start < previous || end < start) {
        throw const FormatException('Bad piece positions');
      }
      previous = end;
      if (end > maxCharacters) {
        throw DocumentProblemException(DocumentProblem.tooLarge);
      }
      final descriptor = (count + 1) * 4 + index * 8;
      final raw = plc.u32(descriptor + 2);
      final compressed = raw & 0x40000000 != 0;
      final offset = compressed ? (raw & 0x3FFFFFFF) ~/ 2 : raw & 0x3FFFFFFF;
      final piece = Piece(
        start,
        end,
        offset,
        compressed,
        plc.u16(descriptor + 6),
      );
      if (!wordDocument.has(offset, (end - start) * piece.width)) {
        throw const FormatException('Piece outside the stream');
      }
      stored += (end - start) * piece.width;
      if (stored > wordDocument.length) {
        throw const FormatException('Pieces overlap');
      }
      if (end > start) pieces.add(piece);
    }

    final text = Uint16List(previous);
    final bytes = wordDocument.bytes;
    for (final piece in pieces) {
      for (var position = piece.start; position < piece.end; position++) {
        final at = piece.offsetOf(position);
        text[position] = piece.compressed
            ? _compressedCharacters[bytes[at]]
            : bytes[at] | bytes[at + 1] << 8;
      }
    }
    return PieceTable._(pieces, modifiers, text);
  }

  final List<Piece> pieces;

  /// Grpprls of the Clx that fast-saved pieces point to.
  final List<Uint8List> modifiers;

  /// UTF-16 code unit of each character position.
  final Uint16List text;

  int get length => text.length;

  /// The piece holding [position], or null.
  Piece? pieceAt(int position) {
    var low = 0;
    var high = pieces.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final piece = pieces[middle];
      if (position < piece.start) {
        high = middle - 1;
      } else if (position >= piece.end) {
        low = middle + 1;
      } else {
        return piece;
      }
    }
    return null;
  }
}

/// Windows-1252 for the bytes MS-DOC maps to it; the others keep their value.
final Uint16List _compressedCharacters = () {
  final table = Uint16List(256);
  for (var byte = 0; byte < 256; byte++) {
    table[byte] = byte;
  }
  final windows = decodeCodePage([for (var b = 0x80; b < 0xA0; b++) b], 1252);
  for (var index = 0; index < 32; index++) {
    final unit = windows.codeUnitAt(index);
    if (unit != 0xFFFD) table[0x80 + index] = unit;
  }
  return table;
}();
