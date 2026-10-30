import 'dart:typed_data';

import '../document/document_codec.dart';
import 'byte_view.dart';

/// Pairs of the FibRgFcLcb97 used here: offset and size of a structure in
/// the table stream.
enum FibPart {
  styles(1),
  footnoteReferences(2),
  footnoteTexts(3),
  commentReferences(4),
  sections(6),
  headers(11),
  characterRuns(12),
  paragraphRuns(13),
  fonts(15),
  bookmarkNames(21),
  bookmarkStarts(22),
  documentProperties(31),
  pieces(33),
  shapeAnchors(40),
  headerShapeAnchors(41),
  endnoteReferences(46),
  endnoteTexts(47),
  drawings(50),
  lists(73),
  listOverrides(74);

  const FibPart(this.pair);

  final int pair;
}

/// The File Information Block at the start of the WordDocument stream
/// (MS-DOC 2.5.1).
class Fib {
  Fib._(this._view, this._pairs, this._pairCount, this._flags, this.lengths);

  /// Throws [DocumentProblemException] for old Word versions and encrypted
  /// files, and a [FormatException] when the block is damaged.
  factory Fib.parse(Uint8List wordDocument) {
    final view = ByteView(wordDocument);
    final ident = view.u16(0);
    final version = view.u16(2);
    // Word's empty "new document" and the BiDi build of Word 97 save 0xC0
    // and 0xC2 for 0xC1 (MS-DOC 2.5.2). Word 6 and 95 save from 0x65, and
    // some of their templates and Asian versions use other identifiers.
    final legacy = version < 0xC0 && (ident == 0xA5EC || version >= 0x65);
    if (legacy || ident == 0xA5DC) {
      throw DocumentProblemException(DocumentProblem.legacyDoc);
    }
    if (ident != 0xA5EC) throw const FormatException('Not a Word FIB');
    final flags = view.u16(10);
    if (flags & 0x0100 != 0 || flags & 0x8000 != 0) {
      throw DocumentProblemException(DocumentProblem.passwordProtected);
    }
    final shortCount = view.u16(32);
    var offset = 34 + shortCount * 2;
    final longCount = view.u16(offset);
    final longs = offset + 2;
    offset = longs + longCount * 4;
    final pairCount = view.u16(offset);
    final pairs = offset + 2;
    if (!view.has(pairs, pairCount * 8) || longCount < 11) {
      throw const FormatException('Truncated FIB');
    }
    int long(int index) => view.i32(longs + index * 4);
    final lengths = (
      text: long(3),
      footnotes: long(4),
      headers: long(5),
      macros: long(6),
      comments: long(7),
      endnotes: long(8),
      textBoxes: long(9),
      headerTextBoxes: long(10),
    );
    final all = [
      lengths.text,
      lengths.footnotes,
      lengths.headers,
      lengths.macros,
      lengths.comments,
      lengths.endnotes,
      lengths.textBoxes,
      lengths.headerTextBoxes,
    ];
    if (all.any((count) => count < 0)) {
      throw const FormatException('Bad text lengths');
    }
    return Fib._(view, pairs, pairCount, flags, lengths);
  }

  final ByteView _view;
  final int _pairs;
  final int _pairCount;
  final int _flags;

  /// Characters in the main text and in each subdocument that follows it.
  final ({
    int text,
    int footnotes,
    int headers,
    int macros,
    int comments,
    int endnotes,
    int textBoxes,
    int headerTextBoxes,
  })
  lengths;

  /// Language of the Word that saved the file.
  int get language => _view.u16(6);

  /// 1Table instead of 0Table.
  String get tableStreamName => _flags & 0x0200 != 0 ? '1Table' : '0Table';

  /// Offset and size of [part] in the table stream; size 0 when absent.
  ({int offset, int size}) operator [](FibPart part) {
    if (part.pair >= _pairCount) return (offset: 0, size: 0);
    final at = _pairs + part.pair * 8;
    return (offset: _view.u32(at), size: _view.u32(at + 4));
  }

  /// First character of each subdocument.
  int get footnotesStart => lengths.text;
  int get headersStart => footnotesStart + lengths.footnotes;
  int get commentsStart => headersStart + lengths.headers + lengths.macros;
  int get endnotesStart => commentsStart + lengths.comments;
  int get textBoxesStart => endnotesStart + lengths.endnotes;
  int get end => textBoxesStart + lengths.textBoxes + lengths.headerTextBoxes;
}
