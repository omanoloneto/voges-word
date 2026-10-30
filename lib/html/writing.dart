import 'dart:convert';
import 'dart:math' as math;

import 'package:xml/xml.dart';

import '../document/delta_blocks.dart';
import '../document/embeds.dart';
import '../docx/docx_builder.dart';
import '../docx/docx_package.dart';
import '../docx/word_xml.dart';

typedef ListLevel = ({int start, String format});

final _unsafeAnchor = RegExp(r'[\s"<>]');
final _trailingZeros = RegExp(r'\.?0+$');

/// Start numbers and formats of the Word lists in the document's source, so
/// saved lists keep their numbering.
class ListNumbering {
  const ListNumbering._(this._levels);

  factory ListNumbering.of(Object? source) {
    if (source is! DocxPackage) return const ListNumbering._({});
    try {
      return ListNumbering._(_parse(source));
    } on Exception {
      return const ListNumbering._({});
    }
  }

  final Map<(int, int), ListLevel> _levels;

  ListLevel? level(int numId, int level) => _levels[(numId, level)];

  static Map<(int, int), ListLevel> _parse(DocxPackage package) {
    final main = package.mainDocumentPath;
    final relationship = package
        .relationships(main)
        .where((relationship) => relationship.hasType('numbering'))
        .firstOrNull;
    if (relationship == null) return const {};
    final root = package
        .xml(DocxPackage.resolve(main, relationship.target))
        ?.rootElement;
    if (root == null) return const {};
    final x = WordXml(root);

    ListLevel levelOf(XmlElement lvl, ListLevel? fallback) => (
      start:
          int.tryParse(x.childVal(lvl, 'start') ?? '') ?? fallback?.start ?? 1,
      format: x.childVal(lvl, 'numFmt') ?? fallback?.format ?? 'decimal',
    );

    final abstracts = <int, Map<int, ListLevel>>{};
    for (final abstract in x.children(root, 'abstractNum')) {
      final id = int.tryParse(x.attr(abstract, 'abstractNumId') ?? '');
      if (id == null) continue;
      abstracts[id] = {
        for (final lvl in x.children(abstract, 'lvl'))
          int.tryParse(x.attr(lvl, 'ilvl') ?? '') ?? 0: levelOf(lvl, null),
      };
    }
    final levels = <(int, int), ListLevel>{};
    for (final num in x.children(root, 'num')) {
      final numId = int.tryParse(x.attr(num, 'numId') ?? '');
      if (numId == null) continue;
      final abstractId = int.tryParse(x.childVal(num, 'abstractNumId') ?? '');
      final own = {...?abstracts[abstractId]};
      for (final override in x.children(num, 'lvlOverride')) {
        final level = int.tryParse(x.attr(override, 'ilvl') ?? '') ?? 0;
        final redefined = x.child(override, 'lvl');
        if (redefined != null) own[level] = levelOf(redefined, own[level]);
        final start = int.tryParse(x.childVal(override, 'startOverride') ?? '');
        if (start != null) {
          own[level] = (start: start, format: own[level]?.format ?? 'decimal');
        }
      }
      own.forEach((level, value) => levels[(numId, level)] = value);
    }
    return levels;
  }
}

/// Numbers of ordered list items as Word counts them: per list and level,
/// restarting deeper levels after an item of a lower one. Lists made in the
/// editor restart after anything that isn't a list item, as when saved as
/// .docx.
class ListCounter {
  ListCounter(this.numbering);

  final ListNumbering numbering;
  final _counts = <Object, List<int?>>{};
  var _run = 0;

  /// Ends the current run of list items.
  void breakRun() => _run++;

  /// Identifies the list [line] belongs to.
  Object keyOf(LineBlock line) => _numIdOf(line) ?? 'run$_run';

  int next(LineBlock line) {
    final numId = _numIdOf(line);
    final level = math.min(line.indent, 8);
    final counts = _counts.putIfAbsent(
      keyOf(line),
      () => List<int?>.filled(9, null),
    );
    final current = counts[level];
    counts[level] = current == null
        ? (numId == null ? 1 : numbering.level(numId, level)?.start ?? 1)
        : current + 1;
    for (var deeper = level + 1; deeper < 9; deeper++) {
      counts[deeper] = null;
    }
    return counts[level]!;
  }

  /// Word's number format of the item's level, like `lowerLetter`.
  String? formatOf(LineBlock line) {
    final numId = _numIdOf(line);
    return numId == null
        ? null
        : numbering.level(numId, math.min(line.indent, 8))?.format;
  }

  static int? _numIdOf(LineBlock line) =>
      (line.attributes[HiddenAttributes.numbering] as num?)?.toInt();
}

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
