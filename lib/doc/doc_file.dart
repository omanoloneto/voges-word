import 'dart:math' as math;
import 'dart:typed_data';

import '../document/document_codec.dart';
import 'byte_view.dart';
import 'compound_file.dart';
import 'doc_fib.dart';
import 'doc_lists.dart';
import 'doc_pictures.dart';
import 'doc_properties.dart';
import 'doc_runs.dart';
import 'doc_sprms.dart';
import 'doc_styles.dart';
import 'doc_text.dart';

/// Positions of a PLC (MS-DOC 2.2.2) and its data elements.
class _Plc {
  const _Plc(this.positions, this.data, this.dataSize);

  /// One more than the elements.
  final List<int> positions;
  final ByteView data;
  final int dataSize;

  int get length => positions.length - 1;

  int dataAt(int index) => positions.length * 4 + index * dataSize;
}

/// A section: where it ends (exclusive) and its properties.
typedef DocSection = ({int end, SectionProps props});

/// A footnote or endnote: its reference mark and its text.
typedef DocNote = ({bool endnote, int start, int end});

/// A floating shape's anchor (SPA): the shape and its size in twips.
typedef ShapeAnchor = ({int shape, int width, int height});

/// The parts of a Word 97–2003 file the reader needs, and the formatting at
/// each character position.
class DocFile {
  DocFile._({
    required this.compound,
    required this.fib,
    required this.document,
    required this.table,
    required this.data,
    required this.pieces,
    required this.characterRuns,
    required this.paragraphRuns,
  });

  /// Throws [DocumentProblemException] for files it can't open, and a
  /// [FormatException] when the file is damaged.
  factory DocFile.open(Uint8List bytes) {
    if (bytes.length > maxFileBytes) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
    final compound = CompoundFile.parse(bytes);
    // A password-protected .docx is a compound file with the package inside.
    if (compound.contains('EncryptedPackage')) {
      throw DocumentProblemException(DocumentProblem.passwordProtected);
    }
    final wordDocument = compound.stream('WordDocument');
    if (wordDocument == null) {
      throw DocumentProblemException(DocumentProblem.notWordDocument);
    }
    final fib = Fib.parse(wordDocument);
    final tableBytes = compound.stream(fib.tableStreamName);
    if (tableBytes == null) throw const FormatException('No table stream');
    final document = ByteView(wordDocument);
    final table = ByteView(tableBytes);
    final data = compound.stream('Data');
    ByteView part(FibPart part) {
      final (:offset, :size) = fib[part];
      return size == 0 ? ByteView(Uint8List(0)) : table.view(offset, size);
    }

    final pieces = PieceTable.parse(
      part(FibPart.pieces),
      document,
      maxCharacters: maxCharacters,
    );
    if (fib.lengths.text > pieces.length) {
      throw const FormatException('Text beyond the piece table');
    }
    return DocFile._(
      compound: compound,
      fib: fib,
      document: document,
      table: table,
      data: data == null ? null : ByteView(data),
      pieces: pieces,
      characterRuns: FormattingRuns.characters(
        part(FibPart.characterRuns),
        document,
      ),
      paragraphRuns: FormattingRuns.paragraphs(
        part(FibPart.paragraphRuns),
        document,
      ),
    );
  }

  /// Larger files are refused before reading.
  static const maxFileBytes = 256 * 1024 * 1024;

  /// Bounds the memory the text takes (64 MB).
  static const maxCharacters = 1 << 25;

  final CompoundFile compound;
  final Fib fib;
  final ByteView document;
  final ByteView table;
  final ByteView? data;
  final PieceTable pieces;
  final FormattingRuns characterRuns;
  final FormattingRuns paragraphRuns;

  /// Optional parts that were damaged and left out.
  var skippedParts = false;

  /// Some writers give the stylesheet a size short of its last style, so it
  /// is read up to the end of the table stream, like the lists.
  late final DocStyles styles =
      _optional(() {
        final (:offset, :size) = fib[FibPart.styles];
        if (size == 0) return null;
        if (!table.has(offset, size)) throw const FormatException('Styles');
        return DocStyles.parse(table.view(offset, table.length - offset));
      }) ??
      DocStyles.empty();

  late final List<String?> fonts =
      _optional(() => parseFonts(_part(FibPart.fonts)!)) ?? const [];

  late final DocLists lists =
      _optional(() {
        final (:offset, :size) = fib[FibPart.lists];
        final overrides = _part(FibPart.listOverrides);
        if (size == 0 || overrides == null) return null;
        if (!table.has(offset, size)) throw const FormatException('Lists');
        return DocLists.parse(
          table.view(offset, table.length - offset),
          overrides,
        );
      }) ??
      DocLists.empty;

  /// Sections in order; the last one ends the main text.
  late final List<DocSection> sections =
      _optional(() {
        final plc = _plc(FibPart.sections, 12);
        if (plc == null) return null;
        return [
          for (var index = 0; index < plc.length; index++)
            (
              end: plc.positions[index + 1],
              props: _section(plc.data.i32(plc.dataAt(index) + 2)),
            ),
        ];
      }) ??
      const [];

  /// Boundaries of the header and footer stories, from the start of their
  /// subdocument.
  late final List<int> headerStories =
      _optional(() => _plc(FibPart.headers, 0)?.positions) ?? const [];

  /// Notes by the position of their reference mark in the main text.
  late final Map<int, DocNote> notes = {
    ...?_optional(() => _notes(endnote: false)),
    ...?_optional(() => _notes(endnote: true)),
  };

  /// Bookmark names by the position where they start.
  late final Map<int, List<String>> bookmarks =
      _optional(_bookmarks) ?? const {};

  /// Floating shapes by the position of their anchor, in the main text and
  /// in the headers.
  late final Map<int, ShapeAnchor> mainShapes =
      _optional(() => _anchors(FibPart.shapeAnchors, 0)) ?? const {};
  late final Map<int, ShapeAnchor> headerShapes =
      _optional(() => _anchors(FibPart.headerShapeAnchors, fib.headersStart)) ??
      const {};

  late final FloatingPictures? mainPictures = _optional(
    () => _drawing(header: false),
  );
  late final FloatingPictures? headerPictures = _optional(
    () => _drawing(header: true),
  );

  late final bool hasComments =
      fib.lengths.comments > 0 ||
      (_optional(() => _plc(FibPart.commentReferences, 30)?.length) ?? 0) > 0;

  /// Different headers on odd and even pages, and the default tab stop.
  late final ({bool facingPages, int tabStop}) settings =
      _optional(() {
        final dop = _part(FibPart.documentProperties);
        if (dop == null || dop.length < 12) return null;
        return (facingPages: dop.u8(0) & 0x01 != 0, tabStop: dop.u16(10));
      }) ??
      (facingPages: false, tabStop: 720);

  final _paragraphCache = <(int, int, int), ParaProps>{};
  final _characterCache = <(int, int, int), (CharProps, CharProps)>{};

  /// Properties of the paragraph whose mark is at [position].
  ParaProps paragraphAt(int position) {
    final piece = pieces.pieceAt(position);
    final run = piece == null
        ? null
        : paragraphRuns.find(piece.offsetOf(position));
    final key = (run?.grpprlStart ?? -1, run?.style ?? 0, piece?.prm ?? 0);
    final cached = _paragraphCache[key];
    if (cached != null) return cached;
    final style = run?.style ?? 0;
    final props = styles.paragraphProps(style).copy();
    if (run != null) props.apply(document, run.grpprlStart, run.grpprlEnd);
    final huge = props.hugeGrpprl;
    final data = this.data;
    if (huge >= 0 && data != null && data.has(huge, 2)) {
      final size = data.i16(huge);
      if (size > 0 && data.has(huge + 2, size)) {
        props.apply(data, huge + 2, huge + 2 + size);
      }
    }
    if (_modifier(piece) case final modifier?) {
      props.apply(modifier, 0, modifier.length);
    }
    return _paragraphCache[key] = props;
  }

  /// Character properties at [position] in a paragraph of style
  /// [paragraphStyle]: what the styles give, and with direct formatting.
  (CharProps, CharProps) charactersAt(int position, int paragraphStyle) {
    final piece = pieces.pieceAt(position);
    final run = piece == null
        ? null
        : characterRuns.find(piece.offsetOf(position));
    final key = (run?.grpprlStart ?? -1, paragraphStyle, piece?.prm ?? 0);
    final cached = _characterCache[key];
    if (cached != null) return cached;
    final modifier = _modifier(piece);
    var characterStyle = 10;
    void findStyle(ByteView data, int start, int end) =>
        forEachSprm(data, start, end, (sprm, at, _) {
          if (sprm == Sprm.cIstd) characterStyle = data.u16(at);
        });
    if (run != null) findStyle(document, run.grpprlStart, run.grpprlEnd);
    if (modifier != null) findStyle(modifier, 0, modifier.length);
    final base = styles.withCharacterStyle(
      styles.charProps(paragraphStyle),
      characterStyle,
    );
    final props = base.copy();
    if (run != null) {
      props.apply(document, run.grpprlStart, run.grpprlEnd, base);
    }
    if (modifier != null) props.apply(modifier, 0, modifier.length, base);
    return _characterCache[key] = (base, props);
  }

  /// End of the characters from [position] that share their formatting,
  /// at most [limit].
  int runEnd(int position, int limit) {
    final piece = pieces.pieceAt(position);
    if (piece == null) return position + 1;
    final offset = piece.offsetOf(position);
    final runEnd =
        characterRuns.find(offset)?.end ?? characterRuns.nextStart(offset);
    var end = math.min(limit, piece.end);
    if (runEnd != null) {
      final characters = (runEnd - offset + piece.width - 1) ~/ piece.width;
      end = math.min(end, position + characters);
    }
    return math.max(end, position + 1);
  }

  ByteView? _modifier(Piece? piece) {
    final prm = piece?.prm ?? 0;
    if (prm & 1 == 0) return null;
    final index = prm >> 1;
    return index < pieces.modifiers.length
        ? ByteView(pieces.modifiers[index])
        : null;
  }

  SectionProps _section(int offset) {
    final props = SectionProps();
    if (offset >= 0 && document.has(offset, 2)) {
      final size = document.i16(offset);
      if (size > 0 && document.has(offset + 2, size)) {
        props.apply(document, offset + 2, offset + 2 + size);
      }
    }
    return props;
  }

  Map<int, DocNote>? _notes({required bool endnote}) {
    final references = _plc(
      endnote ? FibPart.endnoteReferences : FibPart.footnoteReferences,
      2,
    );
    final texts = _plc(
      endnote ? FibPart.endnoteTexts : FibPart.footnoteTexts,
      0,
    );
    if (references == null || texts == null) return null;
    final base = endnote ? fib.endnotesStart : fib.footnotesStart;
    final limit = endnote ? fib.lengths.endnotes : fib.lengths.footnotes;
    final notes = <int, DocNote>{};
    var previous = 0;
    for (var index = 0; index < references.length; index++) {
      if (index + 1 >= texts.positions.length) break;
      final start = texts.positions[index];
      final end = texts.positions[index + 1];
      // Notes can't share text, so all of them read it at most once.
      if (start < previous || end < start || end > limit) continue;
      previous = end;
      notes[references.positions[index]] = (
        endnote: endnote,
        start: base + start,
        end: base + end,
      );
    }
    return notes;
  }

  Map<int, List<String>>? _bookmarks() {
    final names = _part(FibPart.bookmarkNames);
    final starts = _plc(FibPart.bookmarkStarts, 4);
    if (names == null || starts == null || names.u16(0) != 0xFFFF) {
      return null;
    }
    final count = names.u16(2);
    final extra = names.u16(4);
    var at = 6;
    final result = <int, List<String>>{};
    for (var index = 0; index < count && index < starts.length; index++) {
      final length = names.u16(at);
      final name = names.utf16(at + 2, length);
      at += 2 + length * 2 + extra;
      if (name.isEmpty || name == '_GoBack') continue;
      (result[starts.positions[index]] ??= []).add(name);
    }
    return result;
  }

  Map<int, ShapeAnchor>? _anchors(FibPart part, int base) {
    final plc = _plc(part, 26);
    if (plc == null) return null;
    final data = plc.data;
    return {
      for (var index = 0; index < plc.length; index++)
        base + plc.positions[index]: (
          shape: data.u32(plc.dataAt(index)),
          width:
              data.i32(plc.dataAt(index) + 12) -
              data.i32(plc.dataAt(index) + 4),
          height:
              data.i32(plc.dataAt(index) + 16) -
              data.i32(plc.dataAt(index) + 8),
        ),
    };
  }

  FloatingPictures? _drawing({required bool header}) {
    final (:offset, :size) = fib[FibPart.drawings];
    if (size == 0) return null;
    if (!table.has(offset, size)) throw const FormatException('Drawings');
    return FloatingPictures.parse(
      table,
      offset,
      size,
      document,
      header: header,
    );
  }

  ByteView? _part(FibPart part) {
    final (:offset, :size) = fib[part];
    if (size == 0) return null;
    return table.view(offset, size);
  }

  _Plc? _plc(FibPart part, int dataSize) {
    final view = _part(part);
    if (view == null) return null;
    if (view.length < 4 || (view.length - 4) % (4 + dataSize) != 0) {
      throw const FormatException('Bad PLC');
    }
    final count = (view.length - 4) ~/ (4 + dataSize);
    return _Plc(
      [for (var index = 0; index <= count; index++) view.i32(index * 4)],
      view,
      dataSize,
    );
  }

  /// A damaged optional part is left out instead of failing the file.
  T? _optional<T>(T? Function() parse) {
    try {
      return parse();
    } on FormatException {
      skippedParts = true;
      return null;
    }
  }
}
