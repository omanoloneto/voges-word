import 'dart:convert';
import 'dart:math' as math;

import 'package:xml/xml.dart';

import '../document/delta_blocks.dart';
import '../document/embeds.dart';
import '../docx/docx_builder.dart';
import '../docx/docx_package.dart';
import '../docx/word_xml.dart';

typedef ListLevel = ({int start, String format});

/// A level as Word defines it: `text` is like `%1.%2.`, and `legal` levels
/// show every number of their text in decimal.
typedef _WordLevel = ({int start, String format, String? text, bool legal});

final _unsafeAnchor = RegExp(r'[\s"<>]');
final _trailingZeros = RegExp(r'\.?0+$');
final _placeholder = RegExp('%([1-9])');
final _lineBreaksAndTabs = RegExp(r'[\t\n\r]');

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

  final Map<(int, int), _WordLevel> _levels;

  ListLevel? level(int numId, int level) => switch (_levels[(numId, level)]) {
    final found? => (start: found.start, format: found.format),
    null => null,
  };

  static Map<(int, int), _WordLevel> _parse(DocxPackage package) {
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

    _WordLevel levelOf(XmlElement lvl, _WordLevel? fallback) => (
      start:
          int.tryParse(x.childVal(lvl, 'start') ?? '') ?? fallback?.start ?? 1,
      format: x.childVal(lvl, 'numFmt') ?? fallback?.format ?? 'decimal',
      text: x.childVal(lvl, 'lvlText') ?? fallback?.text,
      legal: x.onOff(x.child(lvl, 'isLgl')) ?? fallback?.legal ?? false,
    );

    final abstracts = <int, Map<int, _WordLevel>>{};
    for (final abstract in x.children(root, 'abstractNum')) {
      final id = int.tryParse(x.attr(abstract, 'abstractNumId') ?? '');
      if (id == null) continue;
      abstracts[id] = {
        for (final lvl in x.children(abstract, 'lvl'))
          int.tryParse(x.attr(lvl, 'ilvl') ?? '') ?? 0: levelOf(lvl, null),
      };
    }
    final levels = <(int, int), _WordLevel>{};
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
          final kept = own[level];
          own[level] = (
            start: start,
            format: kept?.format ?? 'decimal',
            text: kept?.text,
            legal: kept?.legal ?? false,
          );
        }
      }
      own.forEach((level, value) => levels[(numId, level)] = value);
    }
    return levels;
  }
}

/// Numbers of ordered list items as Word counts them: per list and level,
/// restarting deeper levels after an item of a lower one. Lists made in the
/// editor restart after anything that isn't a list item and after a number
/// of a Word list, as when saved as .docx.
class ListCounter {
  ListCounter(this.numbering);

  final ListNumbering numbering;
  final _counts = <Object, List<int?>>{};
  var _run = 0;

  /// Longer level texts and numbers are left to the browser's numbering.
  static const _maxMarker = 64;

  /// The formats `<ol type>` shows, followed by a period.
  static const _browserFormats = {
    'decimal',
    'lowerLetter',
    'upperLetter',
    'lowerRoman',
    'upperRoman',
  };

  /// Ends the current run of list items.
  void breakRun() => _run++;

  /// Identifies the list [line] belongs to.
  Object keyOf(LineBlock line) => _wordList(line) ?? 'run$_run';

  int next(LineBlock line) {
    final numId = _wordList(line);
    final level = math.min(line.indent, 8);
    final counts = _counts.putIfAbsent(
      numId ?? 'run$_run',
      () => List<int?>.filled(9, null),
    );
    final current = counts[level];
    counts[level] = current == null
        ? (numId == null ? 1 : numbering._levels[(numId, level)]?.start ?? 1)
        : current + 1;
    for (var deeper = level + 1; deeper < 9; deeper++) {
      counts[deeper] = null;
    }
    if (numId != null && line.isOrdered) breakRun();
    return counts[level]!;
  }

  /// A bullet item: in a Word list it restarts the deeper levels, as a
  /// number does.
  void countBullet(LineBlock line) {
    if (_wordList(line) != null) next(line);
  }

  /// Word's number format of the item's level, like `lowerLetter`.
  String? formatOf(LineBlock line) {
    final numId = _wordList(line);
    return numId == null
        ? null
        : numbering.level(numId, math.min(line.indent, 8))?.format;
  }

  /// The number of [line] as its Word level writes it, like `1.1.`,
  /// `(a)` or `Article 1`, after [next] counted it; null when browsers
  /// show it the same way.
  String? markerOf(LineBlock line) {
    final numId = _wordList(line);
    final counts = _counts[numId];
    if (numId == null || counts == null || !line.isOrdered) return null;
    final level = math.min(line.indent, 8);
    final own = numbering._levels[(numId, level)];
    final text = own?.text;
    if (own == null || text == null || text.length > _maxMarker) return null;
    if (text == '%${level + 1}.' &&
        !own.legal &&
        _browserFormats.contains(own.format)) {
      return null;
    }
    final marker = text
        .replaceAllMapped(_placeholder, (match) {
          final shown = int.parse(match[1]!) - 1;
          final definition = numbering._levels[(numId, shown)];
          // Word shows a level that hasn't counted yet one before its start.
          final count = counts[shown] ?? (definition?.start ?? 1) - 1;
          return _number(
            count,
            own.legal ? 'decimal' : definition?.format ?? 'decimal',
          );
        })
        .replaceAll(_lineBreaksAndTabs, ' ');
    return marker.length > _maxMarker ? null : marker;
  }

  /// The Word list [line] keeps from the opened document: only while the
  /// line is still the kind of list its level is, as the .docx writer keeps
  /// it.
  int? _wordList(LineBlock line) {
    final value = line.attributes[HiddenAttributes.numbering];
    if (value is! num || !value.isFinite) return null;
    final numId = value.toInt();
    final levels = numbering._levels;
    final level = math.min(line.indent, 8);
    final format = (levels[(numId, level)] ?? levels[(numId, 0)])?.format;
    final kept = switch (format) {
      null || 'none' => false,
      'bullet' => !line.isOrdered,
      _ => line.isOrdered,
    };
    return kept ? numId : null;
  }
}

/// [number] in a Word number format, like `upperRoman`; other formats, and
/// numbers out of a format's range, come in decimal.
String _number(int number, String format) {
  switch (format) {
    case 'none' || 'bullet':
      return '';
    case 'decimalZero' when number >= 0 && number < 10:
      return '0$number';
    case 'lowerRoman' || 'upperRoman' when number >= 1 && number < 4000:
      final roman = romanNumeral(number);
      return format == 'upperRoman' ? roman.toUpperCase() : roman;
    // Word repeats the letter after z: aa, bb, cc.
    case 'lowerLetter' || 'upperLetter' when number >= 1 && number <= 260:
      final letter = String.fromCharCode(
        (format == 'upperLetter' ? 0x41 : 0x61) + (number - 1) % 26,
      );
      return letter * ((number - 1) ~/ 26 + 1);
  }
  return '$number';
}

/// [number], from 1, in lowercase roman numerals.
String romanNumeral(int number) {
  final out = StringBuffer();
  var rest = number;
  for (final (value, letters) in const [
    (1000, 'm'),
    (900, 'cm'),
    (500, 'd'),
    (400, 'cd'),
    (100, 'c'),
    (90, 'xc'),
    (50, 'l'),
    (40, 'xl'),
    (10, 'x'),
    (9, 'ix'),
    (5, 'v'),
    (4, 'iv'),
    (1, 'i'),
  ]) {
    for (; rest >= value; rest -= value) {
      out.write(letters);
    }
  }
  return out.toString();
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
