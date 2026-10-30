/// A `property: value` pair of a `style` attribute or a rule.
class CssDeclaration {
  const CssDeclaration(this.property, this.value, {this.important = false});

  /// Lowercase.
  final String property;
  final String value;
  final bool important;
}

const _maxDeclarations = 128;
const _maxRules = 20000;
const _maxRulesPerKey = 32;

/// Classes of an element that rules are looked up for.
const maxClasses = 16;
final _important = RegExp(r'!\s*important\s*$', caseSensitive: false);
final _whitespace = RegExp(r'\s+');
final _unsafeFontCharacters = RegExp(r'[\u0000-\u001F\u007F"\\<>{};]');
final _colorSeparators = RegExp(r'[\s,/]+');

/// Declarations in source order; later ones win.
List<CssDeclaration> parseDeclarations(String text) {
  final declarations = <CssDeclaration>[];
  for (final part in splitCss(_withoutComments(text), 0x3B)) {
    final colon = part.indexOf(':');
    if (colon <= 0) continue;
    final property = part.substring(0, colon).trim().toLowerCase();
    var value = part.substring(colon + 1).trim();
    final important = _important.firstMatch(value);
    if (important != null) value = value.substring(0, important.start).trim();
    if (property.isEmpty || value.isEmpty) continue;
    declarations.add(
      CssDeclaration(property, value, important: important != null),
    );
    if (declarations.length >= _maxDeclarations) break;
  }
  return declarations;
}

/// Splits at [separator] outside quotes, parentheses and brackets.
List<String> splitCss(String text, int separator) {
  final parts = <String>[];
  var depth = 0;
  int? quote;
  var start = 0;
  for (var index = 0; index < text.length; index++) {
    final char = text.codeUnitAt(index);
    if (quote != null) {
      if (char == 0x5C) {
        index++;
      } else if (char == quote) {
        quote = null;
      }
    } else if (char == 0x22 || char == 0x27) {
      quote = char;
    } else if (char == 0x28 || char == 0x5B) {
      depth++;
    } else if ((char == 0x29 || char == 0x5D) && depth > 0) {
      depth--;
    } else if (char == separator && depth == 0) {
      parts.add(text.substring(start, index));
      start = index + 1;
    }
  }
  parts.add(text.substring(start));
  return parts;
}

String _withoutComments(String css) {
  if (!css.contains('/*')) return css;
  final out = StringBuffer();
  var index = 0;
  while (true) {
    final open = css.indexOf('/*', index);
    if (open < 0) break;
    out.write(css.substring(index, open));
    final close = css.indexOf('*/', open + 2);
    if (close < 0) return out.toString();
    index = close + 2;
  }
  out.write(css.substring(index));
  return out.toString();
}

/// A compound selector made of a tag, classes and an id, such as `p.MsoNormal`;
/// selectors with combinators, attributes or pseudo-classes aren't supported.
class CssSelector {
  const CssSelector({this.tag, this.classes = const [], this.id});

  /// Lowercase; null matches any element.
  final String? tag;

  /// Lowercase, like [id]: Word and old pages don't match their case.
  final List<String> classes;
  final String? id;

  static final _pattern = RegExp(r'^(\*|[a-zA-Z][\w-]*)?((?:[.#][\w-]+)*)$');
  static final _part = RegExp(r'[.#][\w-]+');

  static CssSelector? parse(String text) {
    final match = _pattern.firstMatch(text.trim());
    if (match == null || match[0]!.isEmpty) return null;
    final tag = match[1]?.toLowerCase();
    final classes = <String>[];
    String? id;
    for (final part in _part.allMatches(match[2]!)) {
      final value = part[0]!.substring(1).toLowerCase();
      if (part[0]!.startsWith('.')) {
        classes.add(value);
      } else if (id == null) {
        id = value;
      } else {
        return null;
      }
    }
    return CssSelector(tag: tag == '*' ? null : tag, classes: classes, id: id);
  }

  int get specificity =>
      (id == null ? 0 : 1 << 20) +
      (classes.length.clamp(0, 255) << 10) +
      (tag == null ? 0 : 1);

  /// Only a tag, like `h1`.
  bool get isTagOnly => tag != null && classes.isEmpty && id == null;

  bool matches(String tag, Set<String> classes, String? id) =>
      (this.tag == null || this.tag == tag) &&
      (this.id == null || this.id == id) &&
      this.classes.every(classes.contains);
}

class CssRule {
  const CssRule(this.selector, this.declarations, this.order);

  final CssSelector selector;
  final List<CssDeclaration> declarations;
  final int order;
}

/// The rules of a page's `<style>` elements.
class StyleSheet {
  StyleSheet.parse(Iterable<String> sources) {
    for (final source in sources) {
      _parse(_withoutComments(source));
    }
  }

  final _byTag = <String, List<CssRule>>{};
  final _byClass = <String, List<CssRule>>{};
  final _byId = <String, List<CssRule>>{};
  final _universal = <CssRule>[];
  var _rules = 0;

  /// Declarations of the `@page` rules, in order.
  final pages = <List<CssDeclaration>>[];

  /// Word's list definitions, such as `@list l0:level1`, by `l0:level1`.
  final listLevels = <String, List<CssDeclaration>>{};

  bool get isEmpty => _rules == 0;

  void _parse(String css) {
    var index = 0;
    while (index < css.length && _rules < _maxRules) {
      final char = css.codeUnitAt(index);
      if (char <= 0x20 || char == 0x3B || char == 0x7D) {
        index++;
      } else if (css.startsWith('<!--', index)) {
        index += 4;
      } else if (css.startsWith('-->', index)) {
        index += 3;
      } else {
        final open = _find(css, index, const {0x7B, 0x3B});
        if (open >= css.length) return;
        final prelude = css.substring(index, open).trim();
        if (css.codeUnitAt(open) == 0x3B) {
          index = open + 1;
          continue;
        }
        final close = _blockEnd(css, open);
        final block = css.substring(open + 1, close);
        if (prelude.startsWith('@')) {
          _atRule(prelude, block);
        } else {
          _rule(prelude, block);
        }
        index = close + 1;
      }
    }
  }

  void _atRule(String prelude, String block) {
    final name = prelude.substring(1).split(_whitespace).first.toLowerCase();
    // `@page :first` and the like apply to some pages only.
    if (name == 'page' && !prelude.contains(':')) {
      pages.add(parseDeclarations(block));
      _rules++;
    } else if (name == 'list') {
      final key = prelude.substring(5).trim().toLowerCase();
      if (key.contains(':level')) {
        listLevels[key] = parseDeclarations(block);
        _rules++;
      }
    }
  }

  void _rule(String prelude, String block) {
    List<CssDeclaration>? declarations;
    for (final text in splitCss(prelude, 0x2C)) {
      final selector = CssSelector.parse(text);
      if (selector == null) continue;
      declarations ??= parseDeclarations(block);
      final rule = CssRule(selector, declarations, _rules++);
      final key = selector.id ?? selector.classes.firstOrNull;
      final rules = selector.id != null
          ? _byId[key!] ??= []
          : key != null
          ? _byClass[key] ??= []
          : selector.tag != null
          ? _byTag[selector.tag!] ??= []
          : _universal;
      // Pages repeat rules to slow down matching; later ones win anyway.
      if (rules.length >= _maxRulesPerKey) rules.removeAt(0);
      rules.add(rule);
      if (_rules >= _maxRules) return;
    }
  }

  /// Rules that apply to an element, from the weakest to the strongest; only
  /// the first [maxClasses] classes of an element count.
  List<CssRule> rulesFor(String tag, Set<String> classes, String? id) {
    if (_rules == 0) return const [];
    final candidates = <CssRule>[
      ..._universal,
      ...?_byTag[tag],
      for (final name in classes.take(maxClasses)) ...?_byClass[name],
      if (id != null) ...?_byId[id],
    ];
    if (candidates.isEmpty) return const [];
    final rules = [
      for (final rule in candidates)
        if (rule.selector.matches(tag, classes, id)) rule,
    ];
    rules.sort((a, b) {
      final bySpecificity = a.selector.specificity.compareTo(
        b.selector.specificity,
      );
      return bySpecificity != 0 ? bySpecificity : a.order.compareTo(b.order);
    });
    return rules;
  }

  /// Declarations of the rules for the bare tag, like `h1 { ... }`.
  List<CssDeclaration> tagDeclarations(String tag) => [
    for (final rule in _byTag[tag] ?? const <CssRule>[])
      if (rule.selector.isTagOnly) ...rule.declarations,
  ];

  /// Index of the first of [stops] outside quotes, or [css]'s length.
  static int _find(String css, int start, Set<int> stops) {
    int? quote;
    for (var index = start; index < css.length; index++) {
      final char = css.codeUnitAt(index);
      if (quote != null) {
        if (char == 0x5C) {
          index++;
        } else if (char == quote) {
          quote = null;
        }
      } else if (char == 0x22 || char == 0x27) {
        quote = char;
      } else if (stops.contains(char)) {
        return index;
      }
    }
    return css.length;
  }

  /// Index of the `}` that closes the block opened at [open].
  static int _blockEnd(String css, int open) {
    var depth = 0;
    var index = open;
    while (index < css.length) {
      index = _find(css, index, const {0x7B, 0x7D});
      if (index >= css.length) break;
      if (css.codeUnitAt(index) == 0x7B) {
        depth++;
      } else if (--depth == 0) {
        return index;
      }
      index++;
    }
    return css.length;
  }
}

final _length = RegExp(r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))([a-z%]*)$');

/// Points of a CSS length (unitless numbers are pixels, as in attributes);
/// `em` refers to [fontSize] and `%` to [percentOf].
double? cssLength(String value, {double fontSize = 12, double? percentOf}) {
  final match = _length.firstMatch(value.trim().toLowerCase());
  if (match == null) return null;
  final number = double.tryParse(match[1]!);
  if (number == null) return null;
  final points = switch (match[2]) {
    'pt' => number,
    'px' || '' => number * 0.75,
    'pc' => number * 12,
    'in' => number * 72,
    'cm' => number * 72 / 2.54,
    'mm' => number * 72 / 25.4,
    'q' => number * 72 / 101.6,
    'em' => number * fontSize,
    'rem' => number * 12,
    'ex' || 'ch' => number * fontSize / 2,
    '%' when percentOf != null => number * percentOf / 100,
    _ => null,
  };
  return points != null && points.isFinite ? points : null;
}

/// Points of a `font-size`, relative to the parent's [parent] size.
double? cssFontSize(String value, double parent) {
  final text = value.trim().toLowerCase();
  final size = switch (text) {
    'xx-small' => 6.75,
    'x-small' => 7.5,
    'small' => 9.75,
    'medium' => 12.0,
    'large' => 13.5,
    'x-large' => 18.0,
    'xx-large' => 24.0,
    'xxx-large' => 36.0,
    'smaller' => parent / 1.2,
    'larger' => parent * 1.2,
    _ => cssLength(text, fontSize: parent, percentOf: parent),
  };
  return size != null && size > 0 ? size.clamp(1, 1638).toDouble() : null;
}

/// Points of the legacy `<font size>`, 1 to 7 or relative like `+1`.
double? legacyFontSize(String value) {
  final text = value.trim();
  final number = int.tryParse(text.replaceFirst('+', ''));
  if (number == null) return null;
  final size = text.startsWith('+') || text.startsWith('-')
      ? 3 + number
      : number;
  return const [7.5, 10.0, 12.0, 13.5, 18.0, 24.0, 36.0][size.clamp(1, 7) - 1];
}

/// The first family of a `font-family` list that names a font; generic
/// families become common fonts.
String? cssFontFamily(String value) {
  for (final part in splitCss(value, 0x2C)) {
    var name = part.trim();
    if (name.length >= 2 &&
        (name.startsWith('"') || name.startsWith("'")) &&
        name.endsWith(name[0])) {
      name = name.substring(1, name.length - 1).trim();
    }
    final lower = name.toLowerCase();
    final generic = switch (lower) {
      'serif' => 'Times New Roman',
      'sans-serif' => 'Arial',
      'monospace' => 'Courier New',
      'cursive' => 'Comic Sans MS',
      'fantasy' => 'Impact',
      _ => null,
    };
    if (generic != null) return generic;
    if (name.isEmpty ||
        lower.startsWith('-') ||
        lower.startsWith('ui-') ||
        const {
          'system-ui',
          'inherit',
          'initial',
          'unset',
          'emoji',
          'math',
          'fangsong',
        }.contains(lower)) {
      continue;
    }
    final clean = safeFontName(name);
    if (clean != null) return clean;
  }
  return null;
}

/// [name] without characters that could break out of CSS or markup.
String? safeFontName(String name) {
  final clean = name.replaceAll(_unsafeFontCharacters, '').trim();
  if (clean.isEmpty) return null;
  return clean.length > 64 ? clean.substring(0, 64) : clean;
}

final _hex = RegExp(r'^[0-9a-f]+$');

/// `RRGGBB` of a CSS color; null for colors it doesn't know or `transparent`.
String? cssColor(String value) {
  final text = value.trim().toLowerCase();
  if (text.startsWith('#')) return _hexColor(text.substring(1));
  if (text.startsWith('rgb')) {
    final open = text.indexOf('(');
    final close = text.lastIndexOf(')');
    if (open < 0 || close < open) return null;
    final parts = text
        .substring(open + 1, close)
        .split(_colorSeparators)
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length < 3) return null;
    final out = StringBuffer();
    for (final part in parts.take(3)) {
      final percent = part.endsWith('%');
      final number = double.tryParse(
        percent ? part.substring(0, part.length - 1) : part,
      );
      if (number == null || !number.isFinite) return null;
      final channel = (percent ? number * 2.55 : number).round().clamp(0, 255);
      out.write(channel.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString().toUpperCase();
  }
  return _namedColors[text];
}

/// Colors of attributes like `bgcolor`, which may leave out the `#`.
String? attributeColor(String value) =>
    cssColor(value) ?? _hexColor(value.trim().toLowerCase());

String? _hexColor(String hex) {
  if (!_hex.hasMatch(hex)) return null;
  return switch (hex.length) {
    3 || 4 => [
      for (final digit in hex.substring(0, 3).split('')) '$digit$digit',
    ].join().toUpperCase(),
    6 || 8 => hex.substring(0, 6).toUpperCase(),
    _ => null,
  };
}

const _namedColors = {
  'black': '000000',
  'windowtext': '000000',
  'silver': 'C0C0C0',
  'gray': '808080',
  'grey': '808080',
  'white': 'FFFFFF',
  'window': 'FFFFFF',
  'maroon': '800000',
  'red': 'FF0000',
  'purple': '800080',
  'fuchsia': 'FF00FF',
  'magenta': 'FF00FF',
  'green': '008000',
  'lime': '00FF00',
  'olive': '808000',
  'yellow': 'FFFF00',
  'navy': '000080',
  'blue': '0000FF',
  'teal': '008080',
  'aqua': '00FFFF',
  'cyan': '00FFFF',
  'orange': 'FFA500',
  'aliceblue': 'F0F8FF',
  'antiquewhite': 'FAEBD7',
  'aquamarine': '7FFFD4',
  'azure': 'F0FFFF',
  'beige': 'F5F5DC',
  'bisque': 'FFE4C4',
  'blanchedalmond': 'FFEBCD',
  'blueviolet': '8A2BE2',
  'brown': 'A52A2A',
  'burlywood': 'DEB887',
  'cadetblue': '5F9EA0',
  'chartreuse': '7FFF00',
  'chocolate': 'D2691E',
  'coral': 'FF7F50',
  'cornflowerblue': '6495ED',
  'cornsilk': 'FFF8DC',
  'crimson': 'DC143C',
  'darkblue': '00008B',
  'darkcyan': '008B8B',
  'darkgoldenrod': 'B8860B',
  'darkgray': 'A9A9A9',
  'darkgrey': 'A9A9A9',
  'darkgreen': '006400',
  'darkkhaki': 'BDB76B',
  'darkmagenta': '8B008B',
  'darkolivegreen': '556B2F',
  'darkorange': 'FF8C00',
  'darkorchid': '9932CC',
  'darkred': '8B0000',
  'darksalmon': 'E9967A',
  'darkseagreen': '8FBC8F',
  'darkslateblue': '483D8B',
  'darkslategray': '2F4F4F',
  'darkslategrey': '2F4F4F',
  'darkturquoise': '00CED1',
  'darkviolet': '9400D3',
  'deeppink': 'FF1493',
  'deepskyblue': '00BFFF',
  'dimgray': '696969',
  'dimgrey': '696969',
  'dodgerblue': '1E90FF',
  'firebrick': 'B22222',
  'floralwhite': 'FFFAF0',
  'forestgreen': '228B22',
  'gainsboro': 'DCDCDC',
  'ghostwhite': 'F8F8FF',
  'gold': 'FFD700',
  'goldenrod': 'DAA520',
  'greenyellow': 'ADFF2F',
  'honeydew': 'F0FFF0',
  'hotpink': 'FF69B4',
  'indianred': 'CD5C5C',
  'indigo': '4B0082',
  'ivory': 'FFFFF0',
  'khaki': 'F0E68C',
  'lavender': 'E6E6FA',
  'lavenderblush': 'FFF0F5',
  'lawngreen': '7CFC00',
  'lemonchiffon': 'FFFACD',
  'lightblue': 'ADD8E6',
  'lightcoral': 'F08080',
  'lightcyan': 'E0FFFF',
  'lightgoldenrodyellow': 'FAFAD2',
  'lightgray': 'D3D3D3',
  'lightgrey': 'D3D3D3',
  'lightgreen': '90EE90',
  'lightpink': 'FFB6C1',
  'lightsalmon': 'FFA07A',
  'lightseagreen': '20B2AA',
  'lightskyblue': '87CEFA',
  'lightslategray': '778899',
  'lightslategrey': '778899',
  'lightsteelblue': 'B0C4DE',
  'lightyellow': 'FFFFE0',
  'limegreen': '32CD32',
  'linen': 'FAF0E6',
  'mediumaquamarine': '66CDAA',
  'mediumblue': '0000CD',
  'mediumorchid': 'BA55D3',
  'mediumpurple': '9370DB',
  'mediumseagreen': '3CB371',
  'mediumslateblue': '7B68EE',
  'mediumspringgreen': '00FA9A',
  'mediumturquoise': '48D1CC',
  'mediumvioletred': 'C71585',
  'midnightblue': '191970',
  'mintcream': 'F5FFFA',
  'mistyrose': 'FFE4E1',
  'moccasin': 'FFE4B5',
  'navajowhite': 'FFDEAD',
  'oldlace': 'FDF5E6',
  'olivedrab': '6B8E23',
  'orangered': 'FF4500',
  'orchid': 'DA70D6',
  'palegoldenrod': 'EEE8AA',
  'palegreen': '98FB98',
  'paleturquoise': 'AFEEEE',
  'palevioletred': 'DB7093',
  'papayawhip': 'FFEFD5',
  'peachpuff': 'FFDAB9',
  'peru': 'CD853F',
  'pink': 'FFC0CB',
  'plum': 'DDA0DD',
  'powderblue': 'B0E0E6',
  'rebeccapurple': '663399',
  'rosybrown': 'BC8F8F',
  'royalblue': '4169E1',
  'saddlebrown': '8B4513',
  'salmon': 'FA8072',
  'sandybrown': 'F4A460',
  'seagreen': '2E8B57',
  'seashell': 'FFF5EE',
  'sienna': 'A0522D',
  'skyblue': '87CEEB',
  'slateblue': '6A5ACD',
  'slategray': '708090',
  'slategrey': '708090',
  'snow': 'FFFAFA',
  'springgreen': '00FF7F',
  'steelblue': '4682B4',
  'tan': 'D2B48C',
  'thistle': 'D8BFD8',
  'tomato': 'FF6347',
  'turquoise': '40E0D0',
  'violet': 'EE82EE',
  'wheat': 'F5DEB3',
  'whitesmoke': 'F5F5F5',
  'yellowgreen': '9ACD32',
};
