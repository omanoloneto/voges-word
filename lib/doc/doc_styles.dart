import 'byte_view.dart';
import 'doc_properties.dart';

/// Font names of the font table (SttbfFfn, MS-DOC 2.9.287), by index.
List<String?> parseFonts(ByteView table) {
  final count = table.u16(0);
  final fonts = <String?>[];
  var at = 4;
  for (var index = 0; index < count && at < table.length; index++) {
    final size = table.u8(at) + 1;
    if (!table.has(at, size)) break;
    final name = StringBuffer();
    for (var char = at + 40; char + 1 < at + size; char += 2) {
      final unit = table.u16(char);
      if (unit == 0) break;
      name.writeCharCode(unit);
    }
    final trimmed = name.toString().trim();
    fonts.add(trimmed.isEmpty || trimmed.length > 64 ? null : trimmed);
    at += size;
  }
  return fonts;
}

enum DocStyleKind { paragraph, character, other }

/// A style of the stylesheet (STD) with the ranges of its grpprls.
class DocStyle {
  const DocStyle({
    required this.builtIn,
    required this.kind,
    required this.base,
    required this.next,
    required this.name,
    required this.data,
    required this.paragraph,
    required this.character,
  });

  /// Word's identifier of a built-in style (sti); 1 to 9 are headings.
  final int builtIn;
  final DocStyleKind kind;
  final int base;
  final int next;
  final String name;
  final ByteView data;
  final (int, int)? paragraph;
  final (int, int)? character;
}

/// The stylesheet (STSH, MS-DOC 2.9.271): styles by index (istd) and the
/// properties they give, following their base styles.
class DocStyles {
  DocStyles._(this.styles, this.defaultFont);

  DocStyles.empty() : this._(const [], 0);

  factory DocStyles.parse(ByteView table) {
    final headerSize = table.u16(0);
    final count = table.u16(2);
    final baseSize = table.u16(4);
    final defaultFont = headerSize >= 14 ? table.u16(14) : 0;
    final styles = <DocStyle?>[];
    var at = 2 + headerSize;
    for (var index = 0; index < count && at + 2 <= table.length; index++) {
      final size = table.u16(at);
      at += 2;
      if (size == 0) {
        styles.add(null);
        continue;
      }
      // A style cut short ends the stylesheet; the ones before it stay.
      if (!table.has(at, size)) break;
      final std = table.view(at, size);
      at += size;
      styles.add(_style(std, baseSize));
    }
    return DocStyles._(styles, defaultFont);
  }

  static const none = 0x0FFF;

  static DocStyle? _style(ByteView std, int baseSize) {
    if (baseSize < 10 || baseSize + 2 > std.length) return null;
    final kind = switch (std.u16(2) & 0x000F) {
      1 => DocStyleKind.paragraph,
      2 => DocStyleKind.character,
      _ => DocStyleKind.other,
    };
    final length = std.u16(baseSize);
    if (!std.has(baseSize + 2, length * 2)) return null;
    final fullName = std.utf16(baseSize + 2, length);
    final comma = fullName.indexOf(',');
    final name = (comma < 0 ? fullName : fullName.substring(0, comma)).trim();

    final upx = <(int, int)>[];
    var at = baseSize + 2 + (length + 1) * 2;
    final count = std.u16(4) & 0x000F;
    for (var index = 0; index < count && at + 2 <= std.length; index++) {
      final size = std.u16(at);
      at += 2;
      if (!std.has(at, size)) break;
      upx.add((at, at + size));
      at += size + (size & 1);
    }
    (int, int)? upxAt(int index) => index < upx.length ? upx[index] : null;
    final (paragraph, character) = switch (kind) {
      DocStyleKind.paragraph => (upxAt(0), upxAt(1)),
      DocStyleKind.character => (null, upxAt(0)),
      DocStyleKind.other => (null, null),
    };
    return DocStyle(
      builtIn: std.u16(0) & 0x0FFF,
      kind: kind,
      base: std.u16(2) >> 4,
      next: std.u16(4) >> 4,
      name: name.length > 253 ? name.substring(0, 253) : name,
      data: std,
      paragraph: paragraph,
      character: character,
    );
  }

  final List<DocStyle?> styles;

  /// Font index of the document's default text.
  final int defaultFont;

  final _paragraphProps = <int, ParaProps>{};
  final _charProps = <int, CharProps>{};

  DocStyle? operator [](int index) =>
      index >= 0 && index < styles.length ? styles[index] : null;

  /// Properties given before any style: Word's defaults.
  CharProps get baseCharProps => CharProps()..font = defaultFont;

  /// Paragraph properties of paragraph style [index]; Normal's when it isn't
  /// one.
  ParaProps paragraphProps(int index) {
    if (index != 0 && this[index]?.kind != DocStyleKind.paragraph) {
      return paragraphProps(0);
    }
    final cached = _paragraphProps[index];
    if (cached != null) return cached;
    final props = ParaProps();
    for (final style in _chain(index, DocStyleKind.paragraph)) {
      if (style.paragraph case (final start, final end) when end - start >= 2) {
        props.apply(style.data, start + 2, end);
      }
    }
    props
      ..style = this[index]?.kind == DocStyleKind.paragraph ? index : 0
      ..row = null;
    return _paragraphProps[index] = props;
  }

  /// Character properties of paragraph style [index]; Normal's when it isn't
  /// one.
  CharProps charProps(int index) {
    if (index != 0 && this[index]?.kind != DocStyleKind.paragraph) {
      return charProps(0);
    }
    final cached = _charProps[index];
    if (cached != null) return cached;
    var props = baseCharProps;
    for (final style in _chain(index, DocStyleKind.paragraph)) {
      props = _applyCharacters(style, props);
    }
    return _charProps[index] = props;
  }

  /// [paragraph] with character style [index] applied.
  CharProps withCharacterStyle(CharProps paragraph, int index) {
    final chain = _chain(index, DocStyleKind.character);
    if (chain.isEmpty) return paragraph;
    var props = paragraph;
    for (final style in chain) {
      props = _applyCharacters(style, props);
    }
    return props.copy()..style = index;
  }

  /// [props] with the character grpprl of [style] applied.
  static CharProps _applyCharacters(DocStyle style, CharProps props) {
    final range = style.character;
    if (range == null) return props;
    return props.copy()..apply(style.data, range.$1, range.$2, props);
  }

  /// Styles from the root base to [index]; bases that loop or are missing
  /// end the chain.
  List<DocStyle> _chain(int index, DocStyleKind kind) {
    final chain = <DocStyle>[];
    final seen = <int>{};
    var current = index;
    while (current != none && seen.add(current) && chain.length < 64) {
      final style = this[current];
      if (style == null || style.kind != kind) break;
      chain.add(style);
      current = style.base;
    }
    return chain.reversed.toList();
  }
}
