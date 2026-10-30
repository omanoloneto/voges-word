import '../document/delta_blocks.dart';
import '../document/embeds.dart';
import 'docx_numbering.dart';

final _placeholder = RegExp('%([1-9])');

/// Numbers list paragraphs as Word does: the lists of one abstract list count
/// together, a list's w:startOverride restarts the level at the list's first
/// paragraph there, and each paragraph restarts the levels below its own.
/// The editor's numbered lists count apart, in runs a writer ends with
/// [breakRun].
class WordListCounter {
  WordListCounter(this.numbering);

  final DocxNumbering numbering;
  final _counts = <Object?, List<int?>>{};
  final _restarted = <(int, int)>{};
  var _run = 0;

  /// Longer level texts are left out of [textOf].
  static const maxText = 255;

  /// The list level of [line], from 0: the level a paragraph at a level of
  /// its Word list without numbers keeps, or else the line's indent.
  static int levelOf(LineBlock line) =>
      ((line.list == null ? _unnumberedLevel(line) : null) ?? line.indent)
          .clamp(0, wordListLevels - 1);

  static int? _unnumberedLevel(LineBlock line) {
    final value = line.attributes[HiddenAttributes.unnumberedLevel];
    return value is num && value.isFinite ? value.toInt() : null;
  }

  /// Ends the run of the editor's numbered items: the next one starts at 1.
  void breakRun() => _run++;

  /// The Word list whose numbers or bullets [line] shows: the one it keeps
  /// from the opened document while it is still the kind of list its level
  /// is, as the .docx writer keeps it. Checklists show the editor's boxes.
  int? wordList(LineBlock line) =>
      line.list == 'checked' || line.list == 'unchecked' || line.list == null
      ? null
      : _listOf(line);

  /// The Word list of a paragraph the editor shows without a list, at a
  /// level of the list without numbers: Word counts it, and [textOf] gives
  /// the level's text that it shows.
  int? unnumberedList(LineBlock line) =>
      line.list == null ? _listOf(line) : null;

  /// Identifies the list a numbered [line] belongs to, before [count] counts
  /// it.
  Object keyOf(LineBlock line) => wordList(line) ?? 'run$_run';

  /// Counts [line]: Word's number for a paragraph of a Word list, its run's
  /// for a numbered item made in the editor, null for other lines. A number
  /// of a Word list ends the run, as the .docx writer starts another list
  /// after it.
  int? count(LineBlock line) {
    final level = levelOf(line);
    final numId = _listOf(line);
    if (numId == null) {
      return line.isOrdered
          ? _next(_counts.putIfAbsent('run$_run', _noCounts), level, 1)
          : null;
    }
    final counts = _counts.putIfAbsent(numbering.groupOf(numId), _noCounts);
    if (numbering.restarts(numId, level) && _restarted.add((numId, level))) {
      counts[level] = null;
    }
    // Word shows the levels above that haven't counted yet at their start,
    // and counts them there.
    for (var above = 0; above < level; above++) {
      counts[above] ??= numbering.level(numId, above)?.start ?? 1;
    }
    final number = _next(counts, level, numbering.level(numId, level)!.start);
    if (line.isOrdered) breakRun();
    return number;
  }

  /// [line]'s number as its Word level writes it, like `1.1.`, `(a)` or
  /// `Article I.`, once [count] counted it; the level's text, like
  /// `Schedule`, for a paragraph at a level without numbers. Null for other
  /// lines and for level texts longer than [maxText]; empty when the text
  /// names a level below the line's, which Word shows nothing for.
  String? textOf(LineBlock line) {
    final numId = _listOf(line);
    if (numId == null) return null;
    final level = levelOf(line);
    final word = numbering.level(numId, level)!;
    final counts = _counts[numbering.groupOf(numId)];
    if (counts == null || word.text.length > maxText) return null;
    final placeholders = _placeholder.allMatches(word.text);
    if (placeholders.any((match) => int.parse(match[1]!) - 1 > level)) {
      return '';
    }
    return word.text.replaceAllMapped(_placeholder, (match) {
      final shown = int.parse(match[1]!) - 1;
      final definition = numbering.level(numId, shown);
      final format = definition?.format ?? 'decimal';
      return wordNumber(
        counts[shown] ?? definition?.start ?? 1,
        word.legal ? legalFormat(format) : format,
      );
    });
  }

  /// The Word list [line] belongs to while the line is still the kind of
  /// list its level is, or while a line without a list stays at its level
  /// without numbers.
  int? _listOf(LineBlock line) {
    final value = line.attributes[HiddenAttributes.numbering];
    if (value is! num || !value.isFinite) return null;
    final numId = value.toInt();
    final word = numbering.level(numId, levelOf(line));
    if (word == null) return null;
    return switch (line.list) {
      null => word.unnumbered && _unnumberedLevel(line) != null ? numId : null,
      final list => word.kind?.name == list ? numId : null,
    };
  }

  static List<int?> _noCounts() => List.filled(wordListLevels, null);

  static int _next(List<int?> counts, int level, int start) {
    final current = counts[level];
    final number = current == null ? start : current + 1;
    counts[level] = number;
    counts.fillRange(level + 1, counts.length, null);
    return number;
  }
}

/// The format a level of [format] shows its numbers in under Word's legal
/// numbering (w:isLgl): decimal, unless already decimal or zero-padded, as
/// in `Section 1.01`; levels without a number still show none.
String legalFormat(String format) => switch (format) {
  'decimalZero' || 'none' || 'bullet' => format,
  _ => 'decimal',
};

/// [number] in a Word number format, like `upperRoman`; other formats, and
/// numbers out of a format's range, come in decimal.
String wordNumber(int number, String format) {
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
