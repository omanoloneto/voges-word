import 'dart:convert';

import '../document/delta_blocks.dart';
import '../document/embeds.dart';
import '../docx/docx_builder.dart';
import '../docx/docx_numbering.dart';

/// The codecs' name for [DocxNumbering].
typedef ListNumbering = DocxNumbering;

final _unsafeAnchor = RegExp(r'[\s"<>]');
final _trailingZeros = RegExp(r'\.?0+$');

/// [link] when it is a web, e-mail or FTP address or a `#bookmark`.
String? exportLink(String? link) {
  if (link == null) return null;
  final target = link.trim();
  if (target.startsWith('#')) {
    return target.length > 1 && !target.contains(_unsafeAnchor) ? target : null;
  }
  return safeLinkTarget(target);
}

const _monospaceFonts = {
  'courier',
  'courier new',
  'consolas',
  'menlo',
  'monaco',
  'lucida console',
  'andale mono',
  'monospace',
};

bool isMonospace(Object? font) {
  if (font is! String) return false;
  final name = font.trim().toLowerCase();
  return _monospaceFonts.contains(name) ||
      name.contains(' mono') ||
      name.endsWith('mono') ||
      name.contains('code');
}

/// The line's pieces between page breaks; every part but the last ends with
/// one.
List<List<InlinePiece>> pageParts(LineBlock line) {
  final parts = <List<InlinePiece>>[[]];
  for (final piece in line.pieces) {
    if (piece is EmbedPiece && piece.type == EmbedTypes.pageBreak) {
      parts.add([]);
    } else {
      parts.last.add(piece);
    }
  }
  return parts;
}

/// Up to two decimals, without trailing zeros.
String formatNumber(double value) {
  if (!value.isFinite) return '0';
  final text = value.toStringAsFixed(2);
  final trimmed = text.contains('.')
      ? text.replaceFirst(_trailingZeros, '')
      : text;
  return trimmed == '-0' ? '0' : trimmed;
}

/// Bookmark names of a line, from the .docx reader.
List<String> bookmarksOf(LineBlock line) {
  final raw = line.attributes[HiddenAttributes.bookmarks];
  if (raw is! String) return const [];
  try {
    final names = jsonDecode(raw);
    return [
      if (names is List)
        for (final name in names)
          if (name is String && name.isNotEmpty) name,
    ];
  } on FormatException {
    return const [];
  }
}
