import 'byte_view.dart';

/// Formatting of byte ranges of the WordDocument stream, read from the
/// character (ChpxFkp) or paragraph (PapxFkp) pages a PlcBte points to
/// (MS-DOC 2.8.25, 2.9.25). Each run has a grpprl, and paragraph runs a
/// style.
class FormattingRuns {
  FormattingRuns._(this._runs);

  factory FormattingRuns.characters(ByteView plc, ByteView document) =>
      FormattingRuns._(_parse(plc, document, paragraphs: false));

  factory FormattingRuns.paragraphs(ByteView plc, ByteView document) =>
      FormattingRuns._(_parse(plc, document, paragraphs: true));

  final List<FormattingRun> _runs;

  /// The run holding byte [offset].
  FormattingRun? find(int offset) {
    final index = _last(offset);
    final run = index < 0 ? null : _runs[index];
    return run != null && offset < run.end ? run : null;
  }

  /// Start of the first run after [offset]; null when there is none.
  int? nextStart(int offset) {
    final index = _last(offset) + 1;
    return index < _runs.length ? _runs[index].start : null;
  }

  /// Index of the last run starting at or before [offset], or -1.
  int _last(int offset) {
    var low = 0;
    var high = _runs.length - 1;
    var found = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (_runs[middle].start <= offset) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return found;
  }

  static List<FormattingRun> _parse(
    ByteView plc,
    ByteView document, {
    required bool paragraphs,
  }) {
    if (plc.length < 4) return const [];
    if ((plc.length - 4) % 8 != 0) throw const FormatException('Bad PlcBte');
    final pages = (plc.length - 4) ~/ 8;
    if (pages > document.length ~/ 512 + 1) {
      throw const FormatException('Too many formatting pages');
    }
    final runs = <FormattingRun>[];
    for (var index = 0; index < pages; index++) {
      final page = (plc.u32((pages + 1) * 4 + index * 4) & 0x3FFFFF) * 512;
      if (!document.has(page, 512)) {
        throw const FormatException('Formatting page out of range');
      }
      final count = document.u8(page + 511);
      final entry = paragraphs ? 13 : 1;
      if ((count + 1) * 4 + count * entry > 511) {
        throw const FormatException('Bad formatting page');
      }
      for (var run = 0; run < count; run++) {
        final start = document.u32(page + run * 4);
        final end = document.u32(page + run * 4 + 4);
        final slot = document.u8(page + (count + 1) * 4 + run * entry);
        runs.add(
          paragraphs
              ? _paragraph(document, page, start, end, slot)
              : _character(document, page, start, end, slot),
        );
      }
    }
    runs.sort((a, b) => a.start.compareTo(b.start));
    return runs;
  }

  static FormattingRun _character(
    ByteView document,
    int page,
    int start,
    int end,
    int slot,
  ) {
    if (slot == 0) return FormattingRun(start, end, 0, 0);
    final at = page + slot * 2;
    final size = document.u8(at);
    if (at + 1 + size > page + 511) {
      throw const FormatException('Bad CHPX');
    }
    return FormattingRun(start, end, at + 1, at + 1 + size);
  }

  static FormattingRun _paragraph(
    ByteView document,
    int page,
    int start,
    int end,
    int slot,
  ) {
    if (slot == 0) return FormattingRun(start, end, 0, 0);
    final at = page + slot * 2;
    final first = document.u8(at);
    final (data, size) = first == 0
        ? (at + 2, document.u8(at + 1) * 2)
        : (at + 1, first * 2 - 1);
    if (size < 2 || data + size > page + 511) {
      return FormattingRun(start, end, 0, 0);
    }
    return FormattingRun(
      start,
      end,
      data + 2,
      data + size,
      style: document.u16(data),
    );
  }
}

/// Formatting of the bytes [start, end): the grpprl at [grpprlStart,
/// grpprlEnd) of the WordDocument stream.
class FormattingRun {
  const FormattingRun(
    this.start,
    this.end,
    this.grpprlStart,
    this.grpprlEnd, {
    this.style = 0,
  });

  final int start;
  final int end;
  final int grpprlStart;
  final int grpprlEnd;
  final int style;
}
