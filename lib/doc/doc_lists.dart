import 'byte_view.dart';
import 'doc_sprms.dart';

/// A level of a list definition (LVL, MS-DOC 2.9.150).
class DocListLevel {
  const DocListLevel({
    required this.start,
    required this.format,
    required this.text,
    this.left,
    this.firstLine,
    this.font,
    this.follow = 0,
  });

  final int start;

  /// Number format (nfc): 23 is a bullet, 255 no number.
  final int format;

  /// Level text with `%1`... where the level numbers go.
  final String text;

  /// Twips.
  final int? left;
  final int? firstLine;

  /// Font index of the number or bullet.
  final int? font;

  /// What follows the number (ixchFollow): 0 a tab, 1 a space, 2 nothing.
  final int follow;

  DocListLevel startingAt(int value) => DocListLevel(
    start: value,
    format: format,
    text: text,
    left: left,
    firstLine: firstLine,
    font: font,
    follow: follow,
  );
}

/// A list a paragraph points to through sprmPIlfo: the definition (LSTF and
/// its levels) with the overrides of its LFO.
class DocList {
  const DocList(this.id, this.levels, {this.overridden = false});

  /// Lists with the same id and no overrides number together.
  final int id;
  final List<DocListLevel> levels;
  final bool overridden;
}

/// The list definitions (PlfLst) and their overrides (PlfLfo).
class DocLists {
  DocLists._(this._overrides);

  static final empty = DocLists._(const []);

  /// [definitions] starts at PlfLst, whose levels follow it in the table
  /// stream; [overrides] is the PlfLfo.
  factory DocLists.parse(ByteView definitions, ByteView overrides) {
    final lists = <int, List<DocListLevel>>{};
    final count = definitions.i16(0);
    if (count < 0 || 2 + count * 28 > definitions.length) {
      throw const FormatException('Bad PlfLst');
    }
    var level = 2 + count * 28;
    for (var index = 0; index < count; index++) {
      final at = 2 + index * 28;
      final simple = definitions.u8(at + 26) & 0x01 != 0;
      final levels = <DocListLevel>[];
      for (var number = 0; number < (simple ? 1 : 9); number++) {
        final (parsed, size) = _level(definitions, level);
        levels.add(parsed);
        level += size;
      }
      lists.putIfAbsent(definitions.i32(at), () => levels);
    }

    final overrideCount = overrides.u32(0);
    if (4 + overrideCount * 16 > overrides.length) {
      throw const FormatException('Bad PlfLfo');
    }
    var data = 4 + overrideCount * 16;
    final result = <DocList?>[];
    var readable = true;
    for (var index = 0; index < overrideCount; index++) {
      final at = 4 + index * 16;
      final id = overrides.i32(at);
      final levels = lists[id];
      final changes = overrides.u8(at + 12);
      final changed = levels == null ? null : [...levels];
      try {
        if (!readable) throw const FormatException('Unreadable LFOData');
        data += 4;
        for (var change = 0; change < changes; change++) {
          final start = overrides.i32(data);
          final flags = overrides.u32(data + 4);
          data += 8;
          final number = flags & 0x0F;
          DocListLevel? replaced;
          if (flags & 0x20 != 0) {
            final (parsed, size) = _level(overrides, data);
            replaced = parsed;
            data += size;
          }
          if (changed == null || number >= changed.length) continue;
          if (replaced != null) changed[number] = replaced;
          if (flags & 0x10 != 0) {
            changed[number] = changed[number].startingAt(start);
          }
        }
      } on FormatException {
        // Overrides without their data keep the definition's levels.
        readable = false;
      }
      result.add(
        changed == null ? null : DocList(id, changed, overridden: changes > 0),
      );
    }
    return DocLists._(result);
  }

  final List<DocList?> _overrides;

  /// The list of sprmPIlfo's operand; null for none.
  DocList? operator [](int ilfo) =>
      ilfo >= 1 && ilfo <= _overrides.length ? _overrides[ilfo - 1] : null;

  static (DocListLevel, int) _level(ByteView data, int at) {
    final papxSize = data.u8(at + 25);
    final chpxSize = data.u8(at + 24);
    final papx = at + 28;
    final chpx = papx + papxSize;
    final textAt = chpx + chpxSize;
    final length = data.u16(textAt);
    final raw = data.utf16(textAt + 2, length);
    final text = StringBuffer();
    for (final unit in raw.codeUnits) {
      if (unit < 9) {
        text.write('%${unit + 1}');
      } else {
        text.writeCharCode(unit);
      }
    }
    int? left;
    int? firstLine;
    forEachSprm(data, papx, chpx, (sprm, operand, _) {
      switch (sprm) {
        case Sprm.pDxaLeft || Sprm.pDxaLeft80:
          left = data.i16(operand);
        case Sprm.pDxaLeft1 || Sprm.pDxaLeft180:
          firstLine = data.i16(operand);
      }
    });
    int? font;
    forEachSprm(data, chpx, textAt, (sprm, operand, _) {
      if (sprm == Sprm.cRgFtc0) font = data.u16(operand);
    });
    return (
      DocListLevel(
        start: data.i32(at),
        format: data.u8(at + 4),
        text: text.toString(),
        left: left,
        firstLine: firstLine,
        font: font,
        follow: data.u8(at + 15),
      ),
      28 + papxSize + chpxSize + 2 + length * 2,
    );
  }
}
