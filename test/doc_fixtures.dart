import 'dart:convert';
import 'dart:typed_data';

import 'package:voges_word/doc/doc_sprms.dart';

/// Writes small Word 97 files byte by byte, so the tests can build the
/// structures that converters like textutil never produce.

/// A sprm with its operand; variable-size sprms get their size byte.
List<int> sprm(int code, [List<int> operand = const []]) => [
  code & 0xFF,
  code >> 8,
  if (code >> 13 == 6) operand.length,
  ...operand,
];

List<int> u16(int value) => [value & 0xFF, (value >> 8) & 0xFF];

List<int> u32(int value) => [
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
];

List<int> utf16(String text) => [
  for (final unit in text.codeUnits) ...u16(unit),
];

final bold = sprm(Sprm.cFBold, [1]);
final italic = sprm(Sprm.cFItalic, [1]);
final special = sprm(Sprm.cFSpec, [1]);
List<int> fontSize(int points) => sprm(Sprm.cHps, u16(points * 2));
List<int> font(int index) => sprm(Sprm.cRgFtc0, u16(index));
List<int> inTable([int depth = 1]) => [
  ...sprm(Sprm.pFInTable, [1]),
  ...sprm(Sprm.pItap, u32(depth)),
];

/// A table row definition: cell edges in twips and per-cell merge flags
/// (TC80 tcgrf), with single borders.
List<int> rowDefinition(List<int> edges, {List<int> flags = const []}) {
  final cells = edges.length - 1;
  final operand = [
    cells,
    for (final edge in edges) ...u16(edge),
    for (var index = 0; index < cells; index++) ...[
      ...u16(index < flags.length ? flags[index] : 0),
      ...u16(0),
      for (var side = 0; side < 4; side++) ...[4, 1, 1, 0],
    ],
  ];
  // sprmTDefTable's size takes two bytes and counts one more.
  return [...u16(Sprm.tDefTable), ...u16(operand.length + 1), ...operand];
}

class StyleFixture {
  const StyleFixture.paragraph(
    this.name, {
    this.builtIn = 0x0FFE,
    this.base = 0x0FFF,
    this.paragraph = const [],
    this.character = const [],
  }) : kind = 1;

  const StyleFixture.character(
    this.name, {
    this.builtIn = 0x0FFE,
    this.base = 10,
    this.character = const [],
  }) : kind = 2,
       paragraph = const [];

  final String name;
  final int kind;
  final int builtIn;
  final int base;
  final List<int> paragraph;
  final List<int> character;
}

typedef ListLevelFixture = ({
  int format,
  String text,
  int start,
  int left,
  int hanging,
  int? font,
});

/// The characters of the main text and the subdocuments after it, with
/// their formatting, and the tables that point into them.
class DocWriter {
  final _text = StringBuffer();
  final _runs = <(int, int, List<int>)>[];
  final _paragraphs = <(int, int, List<int>)>[];
  var _paragraphStart = 0;

  final styles = <int, StyleFixture>{
    0: const StyleFixture.paragraph('Normal', builtIn: 0),
    10: const StyleFixture.character('Default Paragraph Font', builtIn: 65),
  };
  final fonts = ['Times New Roman', 'Symbol', 'Arial'];
  final _lists = <(int, List<ListLevelFixture>)>[];
  final _overrides = <(int, int?)>[];

  /// Ends of the sections (character positions after their marks) and their
  /// SEPX grpprls.
  final sections = <(int, List<int>)>[];

  /// PlcfHdd positions, from the start of the header subdocument.
  List<int>? headerStories;

  /// Notes: reference position, and text bounds in their subdocument.
  final footnotes = <(int, int, int)>[];
  final endnotes = <(int, int, int)>[];
  final bookmarks = <(String, int, int)>[];
  final comments = <int>[];
  final _data = BytesBuilder();
  final _documentExtra = BytesBuilder();
  List<int>? drawings;
  final floatingAnchors = <(int, int, int, int)>[];

  var footnoteLength = 0;
  var endnoteLength = 0;
  var headerLength = 0;
  var commentLength = 0;
  var textBoxLength = 0;
  var mainLength = -1;
  var facingPages = false;
  var compressed = false;
  var encrypted = false;
  var version = 0x00C1;

  /// Extra streams, such as `EncryptedPackage` or `Macros`.
  final streams = <String, List<int>>{};

  int get position => _text.length;

  void text(String text, [List<int> sprms = const []]) {
    final start = position;
    _text.write(text);
    if (sprms.isNotEmpty) _runs.add((start, position, sprms));
  }

  /// Ends the paragraph with [mark]: `\r`, or `\x07` for table cells.
  void paragraph({
    int style = 0,
    List<int> sprms = const [],
    String mark = '\r',
    List<int> markSprms = const [],
  }) {
    text(mark, markSprms);
    _paragraphs.add((position, style, sprms));
    _paragraphStart = position;
  }

  /// Text in its own paragraph.
  void line(String text, {int style = 0, List<int> sprms = const []}) {
    this.text(text);
    paragraph(style: style, sprms: sprms);
  }

  /// A list definition; returns its sprmPIlfo operand.
  int addList(List<ListLevelFixture> levels, {int? startOverride}) {
    final id = 1000 + _lists.length;
    _lists.add((id, levels));
    _overrides.add((id, startOverride));
    return _overrides.length;
  }

  static List<int> listParagraph(int ilfo, [int level = 0]) => [
    ...sprm(Sprm.pIlfo, u16(ilfo)),
    ...sprm(Sprm.pIlvl, [level]),
  ];

  /// An inline picture's PICF with an OfficeArt BLIP in the Data stream;
  /// returns its offset for sprmCPicLocation.
  int addPicture(
    List<int> bytes, {
    int blipType = 0xF01E,
    int instance = 0x6E0,
    int width = 1440,
    int height = 720,
    int mode = 0x64,
  }) {
    final offset = _data.length;
    final blip = [
      ...u16(instance << 4),
      ...u16(blipType),
      ...u32(16 + 1 + bytes.length),
      ...List.filled(16, 7),
      0xFF,
      ...bytes,
    ];
    final store = [
      ...u16(0x0002),
      ...u16(0xF007),
      ...u32(36 + blip.length),
      6,
      6,
      ...List.filled(16, 7),
      ...u16(0xFF),
      ...u32(blip.length),
      ...u32(1),
      ...u32(0),
      0,
      0,
      0,
      0,
      ...blip,
    ];
    final shape = [...u16(0x000F), ...u16(0xF004), ...u32(0)];
    final size = 68 + shape.length + store.length;
    _data.add([
      ...u32(size),
      ...u16(68),
      ...u16(mode),
      ...List.filled(20, 0),
      ...u16(width),
      ...u16(height),
      ...u16(1000),
      ...u16(1000),
      ...List.filled(68 - 36, 0),
      ...shape,
      ...store,
    ]);
    return offset;
  }

  /// Bytes appended to the Data stream; returns their offset.
  int addData(List<int> bytes) {
    final offset = _data.length;
    _data.add(bytes);
    return offset;
  }

  /// Bytes appended to the WordDocument stream; returns their offset.
  int addToDocument(List<int> bytes) {
    final offset = _documentBase + _documentExtra.length;
    _documentExtra.add(bytes);
    return offset;
  }

  /// Offset of extra bytes in the WordDocument stream, after everything the
  /// writer lays out itself.
  static const _documentBase = 0x8000;

  /// [mutate] changes the streams before they are packed, to damage them.
  Uint8List build({void Function(String name, Uint8List bytes)? mutate}) {
    if (_paragraphStart != position) paragraph();
    final textLength = mainLength >= 0 ? mainLength : position;
    final total = position;
    final textBytes = compressed
        ? latin1.encode(_text.toString())
        : Uint8List.fromList(utf16(_text.toString()));

    // WordDocument: FIB, text, then FKP pages.
    const textOffset = 0x800;
    final document = BytesBuilder();
    final pages = <List<int>>[];
    final firstPage = (textOffset + textBytes.length + 511) ~/ 512 + 1;
    int offsetOf(int position) => textOffset + position * (compressed ? 1 : 2);

    final characterPages = _characterPages(offsetOf, total);
    final paragraphPages = _paragraphPages(offsetOf);
    pages
      ..addAll(characterPages.map((page) => page.$2))
      ..addAll(paragraphPages.map((page) => page.$2));

    // Table stream structures.
    final table = BytesBuilder();
    final parts = <int, (int, int)>{};
    void part(int index, List<int> bytes) {
      parts[index] = (table.length, bytes.length);
      table.add(bytes);
    }

    part(1, _stylesheet());
    part(15, _fontTable());
    final characterPlc = <int>[
      for (final page in characterPages) ...u32(page.$1.$1),
      ...u32(characterPages.isEmpty ? 0 : characterPages.last.$1.$2),
      for (var index = 0; index < characterPages.length; index++)
        ...u32(firstPage + index),
    ];
    part(12, characterPlc);
    final paragraphPlc = <int>[
      for (final page in paragraphPages) ...u32(page.$1.$1),
      ...u32(paragraphPages.isEmpty ? 0 : paragraphPages.last.$1.$2),
      for (var index = 0; index < paragraphPages.length; index++)
        ...u32(firstPage + characterPages.length + index),
    ];
    part(13, paragraphPlc);
    final piece = compressed ? (textOffset * 2) | 0x40000000 : textOffset;
    part(33, [
      0x02,
      ...u32(16),
      ...u32(0),
      ...u32(total),
      ...u16(0),
      ...u32(piece),
      ...u16(0),
    ]);
    if (sections.isNotEmpty) {
      final sepx = <int>[];
      for (final (_, grpprl) in sections) {
        sepx.add(addToDocument([...u16(grpprl.length), ...grpprl]));
      }
      part(6, [
        ...u32(0),
        for (final (end, _) in sections) ...u32(end),
        for (final offset in sepx) ...[
          ...u16(0),
          ...u32(offset),
          ...u16(0),
          ...u32(0),
        ],
      ]);
    }
    if (headerStories case final stories?) {
      part(11, [for (final story in stories) ...u32(story)]);
    }
    for (final (notes, references, texts) in [
      (footnotes, 2, 3),
      (endnotes, 46, 47),
    ]) {
      if (notes.isEmpty) continue;
      part(references, [
        for (final (reference, _, _) in notes) ...u32(reference),
        ...u32(textLength),
        for (var index = 0; index < notes.length; index++) ...u16(1),
      ]);
      part(texts, [
        for (final (_, start, _) in notes) ...u32(start),
        ...u32(notes.last.$3),
        ...u32(notes.last.$3 + 1),
      ]);
    }
    if (bookmarks.isNotEmpty) {
      part(21, [
        ...u16(0xFFFF),
        ...u16(bookmarks.length),
        ...u16(0),
        for (final (name, _, _) in bookmarks) ...[
          ...u16(name.length),
          ...utf16(name),
        ],
      ]);
      part(22, [
        for (final (_, start, _) in bookmarks) ...u32(start),
        ...u32(textLength),
        for (var index = 0; index < bookmarks.length; index++) ...[
          ...u16(index),
          ...u16(0),
        ],
      ]);
      part(23, [
        for (final (_, _, end) in bookmarks) ...u32(end),
        ...u32(textLength),
      ]);
    }
    if (comments.isNotEmpty) {
      part(4, [
        for (final reference in comments) ...u32(reference),
        ...u32(textLength),
        for (var index = 0; index < comments.length; index++)
          ...List.filled(30, 0),
      ]);
    }
    if (_lists.isNotEmpty) {
      final definitions = _listDefinitions();
      part(73, definitions.$1);
      table.add(definitions.$2);
      part(74, _listOverrides());
    }
    if (floatingAnchors.isNotEmpty) {
      part(40, [
        for (final (anchor, _, _, _) in floatingAnchors) ...u32(anchor),
        ...u32(textLength),
        for (final (_, shape, width, height) in floatingAnchors) ...[
          ...u32(shape),
          ...u32(0),
          ...u32(0),
          ...u32(width),
          ...u32(height),
          ...u16(0),
          ...u32(0),
        ],
      ]);
    }
    if (drawings case final content?) part(50, content);
    final dop = List.filled(500, 0);
    dop[0] = facingPages ? 1 : 0;
    dop[10] = 720 & 0xFF;
    dop[11] = 720 >> 8;
    part(31, dop);

    final fib = _fib(
      textLength: textLength,
      parts: parts,
      flags: 0x0200 | (encrypted ? 0x0100 : 0),
    );
    document.add(fib);
    document.add(List.filled(textOffset - fib.length, 0));
    document.add(textBytes);
    document.add(List.filled(firstPage * 512 - document.length, 0));
    for (final page in pages) {
      document.add(page);
    }
    if (document.length > _documentBase) {
      throw StateError('Fixture too large');
    }
    document.add(List.filled(_documentBase - document.length, 0));
    document.add(_documentExtra.toBytes());

    final packed = <String, Uint8List>{
      'WordDocument': document.toBytes(),
      '1Table': table.toBytes(),
      if (_data.isNotEmpty) 'Data': _data.toBytes(),
      for (final MapEntry(key: name, value: bytes) in streams.entries)
        name: Uint8List.fromList(bytes),
    };
    if (mutate != null) packed.forEach(mutate);
    return compoundFile(packed);
  }

  List<int> _fib({
    required int textLength,
    required Map<int, (int, int)> parts,
    required int flags,
  }) {
    final lengths = [
      0,
      0,
      0,
      textLength,
      footnoteLength,
      headerLength,
      0,
      commentLength,
      endnoteLength,
      textBoxLength,
      0,
      ...List.filled(11, 0),
    ];
    return [
      ...u16(0xA5EC),
      ...u16(version),
      ...u16(0),
      ...u16(0x0409),
      ...u16(0),
      ...u16(flags),
      ...List.filled(32 - 12, 0),
      ...u16(14),
      ...List.filled(28, 0),
      ...u16(22),
      for (final value in lengths) ...u32(value),
      ...u16(0x5D),
      for (var index = 0; index < 0x5D; index++) ...[
        ...u32(parts[index]?.$1 ?? 0),
        ...u32(parts[index]?.$2 ?? 0),
      ],
      ...u16(0),
    ];
  }

  /// CHPX pages: runs cover the text, unformatted spans included.
  List<((int, int), List<int>)> _characterPages(
    int Function(int) offsetOf,
    int total,
  ) {
    final spans = <(int, int, List<int>)>[];
    var at = 0;
    for (final (start, end, grpprl) in [
      ..._runs,
    ]..sort((a, b) => a.$1.compareTo(b.$1))) {
      if (start > at) spans.add((at, start, const []));
      spans.add((start, end, grpprl));
      at = end;
    }
    if (at < total) spans.add((at, total, const []));
    return _pages([
      for (final (start, end, grpprl) in spans)
        (offsetOf(start), offsetOf(end), grpprl),
    ], paragraphs: false);
  }

  List<((int, int), List<int>)> _paragraphPages(int Function(int) offsetOf) {
    final spans = <(int, int, List<int>)>[];
    var start = 0;
    for (final (end, style, grpprl) in _paragraphs) {
      spans.add((offsetOf(start), offsetOf(end), [...u16(style), ...grpprl]));
      start = end;
    }
    return _pages(spans, paragraphs: true);
  }

  /// Packs runs into 512-byte FKP pages; each page's first and last offsets
  /// go into the PlcBte.
  static List<((int, int), List<int>)> _pages(
    List<(int, int, List<int>)> runs, {
    required bool paragraphs,
  }) {
    final pages = <((int, int), List<int>)>[];
    var index = 0;
    while (index < runs.length) {
      final page = List.filled(512, 0);
      final chosen = <(int, int, List<int>)>[];
      var top = 511;
      while (index < runs.length) {
        final (_, _, grpprl) = runs[index];
        final count = chosen.length + 1;
        final header = (count + 1) * 4 + count * (paragraphs ? 13 : 1);
        final size = paragraphs ? grpprl.length + 2 : grpprl.length + 1;
        var slot = (top - size) & ~1;
        if (grpprl.isEmpty && !paragraphs) slot = top;
        if (slot < header) break;
        chosen.add(runs[index]);
        index++;
        if (grpprl.isEmpty && !paragraphs) continue;
        top = slot;
      }
      if (chosen.isEmpty) throw StateError('Run too large for a page');
      top = 511;
      for (final (number, (start, end, grpprl)) in chosen.indexed) {
        page.setRange(number * 4, number * 4 + 4, u32(start));
        page.setRange(number * 4 + 4, number * 4 + 8, u32(end));
        final slotAt = (chosen.length + 1) * 4 + number * (paragraphs ? 13 : 1);
        if (!paragraphs && grpprl.isEmpty) continue;
        final List<int> bytes;
        if (paragraphs) {
          bytes = grpprl.length.isEven
              ? [0, grpprl.length ~/ 2, ...grpprl]
              : [(grpprl.length + 1) ~/ 2, ...grpprl];
        } else {
          bytes = [grpprl.length, ...grpprl];
        }
        top = (top - bytes.length) & ~1;
        page.setRange(top, top + bytes.length, bytes);
        page[slotAt] = top ~/ 2;
      }
      page[511] = chosen.length;
      pages.add(((chosen.first.$1, chosen.last.$2), page));
    }
    return pages;
  }

  List<int> _stylesheet() {
    final count = styles.keys.fold(0, (a, b) => a > b ? a : b) + 1;
    final out = <int>[
      ...u16(18),
      ...u16(count),
      ...u16(10),
      ...u16(1),
      ...u16(0x5B),
      ...u16(15),
      ...u16(0),
      ...u16(0),
      ...u16(0),
      ...u16(0),
    ];
    for (var index = 0; index < count; index++) {
      final style = styles[index];
      if (style == null) {
        out.addAll(u16(0));
        continue;
      }
      final upx = <List<int>>[
        if (style.kind == 1) [...u16(index), ...style.paragraph],
        style.character,
      ];
      final std = <int>[
        ...u16(style.builtIn),
        ...u16(style.kind | style.base << 4),
        ...u16(upx.length | 0 << 4),
        ...u16(0),
        ...u16(0),
        ...u16(style.name.length),
        ...utf16(style.name),
        ...u16(0),
        for (final entry in upx) ...[
          ...u16(entry.length),
          ...entry,
          if (entry.length.isOdd) 0,
        ],
      ];
      out
        ..addAll(u16(std.length))
        ..addAll(std);
    }
    return out;
  }

  List<int> _fontTable() => [
    ...u16(fonts.length),
    ...u16(0),
    for (final name in fonts) ...[
      40 + (name.length + 1) * 2 - 1,
      ...List.filled(39, 0),
      ...utf16(name),
      ...u16(0),
    ],
  ];

  (List<int>, List<int>) _listDefinitions() {
    final definitions = <int>[...u16(_lists.length)];
    final levels = <int>[];
    for (final (id, entries) in _lists) {
      definitions.addAll([
        ...u32(id),
        ...u32(0),
        for (var index = 0; index < 9; index++) ...u16(0x0FFF),
        0,
        0,
      ]);
      for (var number = 0; number < 9; number++) {
        final level =
            entries[number < entries.length ? number : entries.length - 1];
        final papx = [
          ...sprm(Sprm.pDxaLeft, u16(level.left)),
          ...sprm(Sprm.pDxaLeft1, u16(-level.hanging & 0xFFFF)),
        ];
        final chpx = level.font == null ? <int>[] : font(level.font!);
        final text = <int>[];
        final placeholders = <int>[];
        for (final char in level.text.codeUnits) {
          if (char == 0x25) continue;
          if (char >= 0x31 &&
              char <= 0x39 &&
              level.text.contains('%${String.fromCharCode(char)}')) {
            placeholders.add(text.length ~/ 2 + 1);
            text.addAll(u16(char - 0x31));
          } else {
            text.addAll(u16(char));
          }
        }
        levels.addAll([
          ...u32(level.start),
          level.format,
          0,
          for (var index = 0; index < 9; index++)
            index < placeholders.length ? placeholders[index] : 0,
          0,
          ...u32(0),
          ...u32(0),
          chpx.length,
          papx.length,
          0,
          0,
          ...papx,
          ...chpx,
          ...u16(text.length ~/ 2),
          ...text,
        ]);
      }
    }
    return (definitions, levels);
  }

  List<int> _listOverrides() => [
    ...u32(_overrides.length),
    for (final (id, start) in _overrides) ...[
      ...u32(id),
      ...u32(0),
      ...u32(0),
      start == null ? 0 : 1,
      0,
      0,
      0,
    ],
    for (final (_, start) in _overrides) ...[
      ...u32(0xFFFFFFFF),
      if (start != null) ...[...u32(start), ...u32(0x10)],
    ],
  ];
}

/// A version 3 compound file; streams under 4096 bytes go to the mini
/// stream.
Uint8List compoundFile(Map<String, List<int>> streams) {
  const sectorSize = 512;
  const endOfChain = 0xFFFFFFFE;
  final entries = streams.entries.toList();
  final mini = BytesBuilder();
  final miniFat = <int>[];
  final regular = <List<int>>[];
  final placements = <(bool, int, int)>[];
  for (final MapEntry(value: bytes) in entries) {
    if (bytes.length < 4096) {
      final first = mini.length ~/ 64;
      final count = (bytes.length + 63) ~/ 64;
      for (var index = 0; index < count; index++) {
        miniFat.add(index == count - 1 ? endOfChain : first + index + 1);
      }
      mini.add([...bytes, ...List.filled(count * 64 - bytes.length, 0)]);
      placements.add((true, count == 0 ? endOfChain : first, bytes.length));
    } else {
      placements.add((false, regular.length, bytes.length));
      regular.add(bytes);
    }
  }
  int sectors(int bytes) => (bytes + sectorSize - 1) ~/ sectorSize;
  final miniStream = mini.toBytes();
  final miniFatSectors = sectors(miniFat.length * 4);
  final miniStreamSectors = sectors(miniStream.length);
  final directorySectors = sectors((entries.length + 1) * 128);
  final dataSectors = regular.fold(
    0,
    (sum, bytes) => sum + sectors(bytes.length),
  );
  var fatSectors = 1;
  while (fatSectors * 128 <
      fatSectors +
          directorySectors +
          miniFatSectors +
          miniStreamSectors +
          dataSectors) {
    fatSectors++;
  }
  final fat = <int>[];
  void chain(int count) {
    final first = fat.length;
    for (var index = 0; index < count; index++) {
      fat.add(index == count - 1 ? endOfChain : first + index + 1);
    }
  }

  for (var index = 0; index < fatSectors; index++) {
    fat.add(0xFFFFFFFD);
  }
  final directoryStart = fat.length;
  chain(directorySectors);
  final miniFatStart = fat.length;
  chain(miniFatSectors);
  final miniStreamStart = fat.length;
  chain(miniStreamSectors);
  final regularStarts = <int>[];
  for (final bytes in regular) {
    regularStarts.add(fat.length);
    chain(sectors(bytes.length));
  }
  while (fat.length < fatSectors * 128) {
    fat.add(0xFFFFFFFF);
  }

  List<int> entry(
    String name,
    int type,
    int child,
    int right,
    int start,
    int size,
  ) {
    final nameBytes = utf16(name);
    return [
      ...nameBytes,
      ...List.filled(64 - nameBytes.length, 0),
      ...u16(nameBytes.length + 2),
      type,
      1,
      ...u32(0xFFFFFFFF),
      ...u32(right),
      ...u32(child),
      ...List.filled(16 + 4 + 16, 0),
      ...u32(start),
      ...u32(size),
      ...u32(0),
    ];
  }

  final directory = <int>[
    ...entry(
      'Root Entry',
      5,
      entries.isEmpty ? 0xFFFFFFFF : 1,
      0xFFFFFFFF,
      miniStream.isEmpty ? endOfChain : miniStreamStart,
      miniStream.length,
    ),
    for (final (index, MapEntry(key: name)) in entries.indexed)
      ...entry(
        name,
        2,
        0xFFFFFFFF,
        index + 1 < entries.length ? index + 2 : 0xFFFFFFFF,
        placements[index].$1
            ? placements[index].$2
            : regularStarts[placements[index].$2],
        placements[index].$3,
      ),
  ];

  final header = <int>[
    0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, //
    ...List.filled(16, 0),
    ...u16(0x3E),
    ...u16(3),
    ...u16(0xFFFE),
    ...u16(9),
    ...u16(6),
    ...List.filled(6, 0),
    ...u32(0),
    ...u32(fatSectors),
    ...u32(directoryStart),
    ...u32(0),
    ...u32(4096),
    ...u32(miniFatSectors == 0 ? endOfChain : miniFatStart),
    ...u32(miniFatSectors),
    ...u32(endOfChain),
    ...u32(0),
    for (var index = 0; index < 109; index++)
      ...u32(index < fatSectors ? index : 0xFFFFFFFF),
  ];
  List<int> padded(List<int> bytes) => [
    ...bytes,
    ...List.filled(sectors(bytes.length) * sectorSize - bytes.length, 0),
  ];
  return Uint8List.fromList([
    ...header,
    ...padded([for (final value in fat) ...u32(value)]),
    ...padded(directory),
    ...padded([for (final value in miniFat) ...u32(value)]),
    ...padded(miniStream),
    for (final bytes in regular) ...padded(bytes),
  ]);
}

/// An OfficeArt record with its header.
List<int> officeArtRecord(
  int version,
  int instance,
  int type,
  List<int> body,
) => [
  ...u16(version | instance << 4),
  ...u16(type),
  ...u32(body.length),
  ...body,
];

/// OfficeArtContent with a picture store whose pictures are in the
/// WordDocument stream (size and offset of each), and the main document's
/// drawing with picture shapes (shape id → store index).
List<int> officeArt({
  required Map<int, int> shapes,
  required List<(int, int)> store,
}) {
  final entries = [
    for (final (size, offset) in store)
      ...officeArtRecord(2, 6, 0xF007, [
        6,
        6,
        ...List.filled(16, 1),
        ...u16(0xFF),
        ...u32(size),
        ...u32(1),
        ...u32(offset),
        0,
        0,
        0,
        0,
      ]),
  ];
  final group = officeArtRecord(0x0F, 0, 0xF000, [
    ...officeArtRecord(0x0F, store.length, 0xF001, entries),
  ]);
  final drawing = officeArtRecord(0x0F, 0, 0xF002, [
    ...officeArtRecord(0x0F, 0, 0xF003, [
      for (final MapEntry(key: id, value: picture) in shapes.entries)
        ...officeArtRecord(0x0F, 0, 0xF004, [
          ...officeArtRecord(2, 75, 0xF00A, [...u32(id), ...u32(0xA00)]),
          ...officeArtRecord(3, 1, 0xF00B, [...u16(0x4104), ...u32(picture)]),
        ]),
    ]),
  ]);
  return [...group, 0, ...drawing];
}

/// A 1×1 PNG.
final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);
