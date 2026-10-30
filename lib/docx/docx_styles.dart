import 'package:xml/xml.dart';

import 'word_xml.dart';

const highlightColors = <String, String>{
  'yellow': 'FFFF00',
  'green': '00FF00',
  'cyan': '00FFFF',
  'magenta': 'FF00FF',
  'blue': '0000FF',
  'red': 'FF0000',
  'darkBlue': '000080',
  'darkCyan': '008080',
  'darkGreen': '008000',
  'darkMagenta': '800080',
  'darkRed': '800000',
  'darkYellow': '808000',
  'darkGray': '808080',
  'lightGray': 'C0C0C0',
  'black': '000000',
  'white': 'FFFFFF',
};

String? _hexColor(String? value) {
  if (value == null) return null;
  final upper = value.toUpperCase();
  return RegExp(r'^[0-9A-F]{6}$').hasMatch(upper) ? upper : null;
}

class RunProps {
  const RunProps({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.size = 11,
    this.font,
    this.color,
    this.background,
    this.script,
  });

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;

  /// Size in points.
  final double size;
  final String? font;

  /// RRGGBB; null means automatic.
  final String? color;
  final String? background;

  /// 'super' or 'sub'.
  final String? script;

  RunProps copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    double? size,
    String? font,
    String? Function()? color,
    String? Function()? background,
    String? Function()? script,
  }) {
    return RunProps(
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      strike: strike ?? this.strike,
      size: size ?? this.size,
      font: font ?? this.font,
      color: color != null ? color() : this.color,
      background: background != null ? background() : this.background,
      script: script != null ? script() : this.script,
    );
  }

  RunProps merge(XmlElement? rPr, WordXml x, ThemeFonts theme) =>
      rPr == null ? this : _RunLayer.of(rPr, x, theme).applyTo(this);
}

/// What one w:rPr sets; null fields keep the value below.
class _RunLayer {
  const _RunLayer({
    this.font,
    this.bold,
    this.italic,
    this.underline,
    this.strike,
    this.size,
    this.color,
    this.background,
    this.script,
  });

  factory _RunLayer.of(XmlElement? rPr, WordXml x, ThemeFonts theme) {
    if (rPr == null) return empty;
    final fonts = x.child(rPr, 'rFonts');
    final themed = x.attr(fonts, 'asciiTheme') ?? x.attr(fonts, 'hAnsiTheme');
    final underline = x.child(rPr, 'u');
    final size = double.tryParse(x.childVal(rPr, 'sz') ?? '');
    final color = x.child(rPr, 'color');
    final highlight = x.childVal(rPr, 'highlight');
    final shading = x.child(rPr, 'shd');
    final vertical = x.childVal(rPr, 'vertAlign');
    return _RunLayer(
      font: themed != null
          ? theme.resolve(themed)
          : x.attr(fonts, 'ascii') ?? x.attr(fonts, 'hAnsi'),
      bold: x.onOff(x.child(rPr, 'b')),
      italic: x.onOff(x.child(rPr, 'i')),
      strike:
          x.onOff(x.child(rPr, 'strike')) ?? x.onOff(x.child(rPr, 'dstrike')),
      underline: underline == null
          ? null
          : (x.val(underline) ?? 'single') != 'none',
      size: size == null ? null : size / 2,
      color: color == null ? null : (_hexColor(x.val(color)),),
      background: highlight != null
          ? (highlightColors[highlight],)
          : shading != null
          ? (_hexColor(x.attr(shading, 'fill')),)
          : null,
      script: vertical == null
          ? null
          : (
              switch (vertical) {
                'superscript' => 'super',
                'subscript' => 'sub',
                _ => null,
              },
            ),
    );
  }

  static const empty = _RunLayer();

  final String? font;
  final bool? bold;
  final bool? italic;
  final bool? underline;
  final bool? strike;
  final double? size;

  /// Set values that may be automatic (null).
  final (String?,)? color;
  final (String?,)? background;
  final (String?,)? script;

  /// This layer's values where it sets them, [below]'s elsewhere.
  _RunLayer over(_RunLayer below) => _RunLayer(
    font: font ?? below.font,
    bold: bold ?? below.bold,
    italic: italic ?? below.italic,
    underline: underline ?? below.underline,
    strike: strike ?? below.strike,
    size: size ?? below.size,
    color: color ?? below.color,
    background: background ?? below.background,
    script: script ?? below.script,
  );

  RunProps applyTo(RunProps props) {
    final (color, background, script) = (
      this.color,
      this.background,
      this.script,
    );
    return props.copyWith(
      font: font,
      bold: bold,
      italic: italic,
      underline: underline,
      strike: strike,
      size: size,
      color: color == null ? null : () => color.$1,
      background: background == null ? null : () => background.$1,
      script: script == null ? null : () => script.$1,
    );
  }
}

class ParagraphProps {
  const ParagraphProps({
    this.align = 'left',
    this.lineSpacing = 1,
    this.exactLineSpacing = false,
    this.spaceBefore = 0,
    this.spaceAfter = 0,
    this.indentLeft = 0,
    this.indentRight = 0,
    this.firstLine = 0,
    this.contextualSpacing = false,
    this.numId,
    this.level = 0,
  });

  final String align;

  /// Multiple of single line spacing (240 = 1.0).
  final double lineSpacing;
  final bool exactLineSpacing;

  /// Spacing in points.
  final double spaceBefore;
  final double spaceAfter;

  /// Indents in twips; a negative [firstLine] is a hanging indent.
  final double indentLeft;
  final double indentRight;
  final double firstLine;

  /// No space between paragraphs of the same style.
  final bool contextualSpacing;
  final int? numId;
  final int level;

  ParagraphProps merge(XmlElement? pPr, WordXml x) {
    if (pPr == null) return this;
    var align = this.align;
    var lineSpacing = this.lineSpacing;
    var exact = exactLineSpacing;
    var before = spaceBefore;
    var after = spaceAfter;
    var indent = indentLeft;
    var right = indentRight;
    var first = firstLine;
    var numId = this.numId;
    var level = this.level;

    final jc = x.childVal(pPr, 'jc');
    if (jc != null) align = alignmentFromWord(jc);

    final spacing = x.child(pPr, 'spacing');
    if (spacing != null) {
      before = _twipsToPoints(x.attr(spacing, 'before')) ?? before;
      after = _twipsToPoints(x.attr(spacing, 'after')) ?? after;
      final line = double.tryParse(x.attr(spacing, 'line') ?? '');
      if (line != null) {
        final rule = x.attr(spacing, 'lineRule') ?? 'auto';
        exact = rule != 'auto';
        lineSpacing = exact ? line / 20 : line / 240;
      }
    }

    final ind = x.child(pPr, 'ind');
    if (ind != null) {
      indent =
          double.tryParse(x.attr(ind, 'left') ?? x.attr(ind, 'start') ?? '') ??
          indent;
      right =
          double.tryParse(x.attr(ind, 'right') ?? x.attr(ind, 'end') ?? '') ??
          right;
      final hanging = double.tryParse(x.attr(ind, 'hanging') ?? '');
      final firstLine = double.tryParse(x.attr(ind, 'firstLine') ?? '');
      if (hanging != null) {
        first = -hanging;
      } else if (firstLine != null) {
        first = firstLine;
      }
    }
    final contextual =
        x.onOff(x.child(pPr, 'contextualSpacing')) ?? contextualSpacing;

    final numPr = x.child(pPr, 'numPr');
    if (numPr != null) {
      numId = int.tryParse(x.childVal(numPr, 'numId') ?? '') ?? numId;
      level = int.tryParse(x.childVal(numPr, 'ilvl') ?? '') ?? level;
    }

    return ParagraphProps(
      align: align,
      lineSpacing: lineSpacing,
      exactLineSpacing: exact,
      spaceBefore: before,
      spaceAfter: after,
      indentLeft: indent,
      indentRight: right,
      firstLine: first,
      contextualSpacing: contextual,
      numId: numId,
      level: level,
    );
  }

  static double? _twipsToPoints(String? value) {
    final twips = double.tryParse(value ?? '');
    return twips == null ? null : twips / 20;
  }
}

String alignmentFromWord(String jc) => switch (jc) {
  'center' => 'center',
  'right' || 'end' => 'right',
  'both' ||
  'distribute' ||
  'thaiDistribute' ||
  'lowKashida' ||
  'mediumKashida' ||
  'highKashida' => 'justify',
  _ => 'left',
};

String alignmentToWord(String align) => switch (align) {
  'center' => 'center',
  'right' => 'right',
  'justify' => 'both',
  _ => 'left',
};

class ThemeFonts {
  const ThemeFonts({this.major, this.minor});

  factory ThemeFonts.parse(XmlDocument? theme) {
    if (theme == null) return const ThemeFonts();
    String? latinOf(String scheme) {
      for (final element in theme.descendantElements) {
        if (element.name.local != scheme) continue;
        for (final child in element.childElements) {
          if (child.name.local == 'latin') {
            return child.getAttribute('typeface');
          }
        }
      }
      return null;
    }

    return ThemeFonts(major: latinOf('majorFont'), minor: latinOf('minorFont'));
  }

  final String? major;
  final String? minor;

  String? resolve(String themeFont) =>
      themeFont.startsWith('major') ? major : minor;
}

class _Style {
  const _Style({
    required this.id,
    required this.name,
    required this.type,
    required this.basedOn,
    required this.element,
    required this.isDefault,
  });

  final String id;
  final String name;
  final String type;
  final String? basedOn;
  final XmlElement element;
  final bool isDefault;
}

class DocxStyles {
  DocxStyles._(
    this._x,
    this._styles,
    this._theme,
    this._runDefaults,
    this._paragraphDefaults,
  );

  factory DocxStyles.parse(XmlDocument? styles, XmlDocument? theme) {
    final themeFonts = ThemeFonts.parse(theme);
    if (styles == null) {
      return DocxStyles._(
        WordXml(XmlElement(XmlName.parts('styles'))),
        const {},
        themeFonts,
        null,
        null,
      );
    }
    final root = styles.rootElement;
    final x = WordXml(root);
    final docDefaults = x.child(root, 'docDefaults');
    final map = <String, _Style>{};
    for (final element in x.children(root, 'style')) {
      final id = x.attr(element, 'styleId');
      if (id == null) continue;
      map[id] = _Style(
        id: id,
        name: (x.childVal(element, 'name') ?? id).toLowerCase(),
        type: x.attr(element, 'type') ?? 'paragraph',
        basedOn: x.childVal(element, 'basedOn'),
        element: element,
        isDefault: const {
          '1',
          'true',
          'on',
        }.contains(x.attr(element, 'default')),
      );
    }
    return DocxStyles._(
      x,
      map,
      themeFonts,
      x.child(x.child(docDefaults, 'rPrDefault'), 'rPr'),
      x.child(x.child(docDefaults, 'pPrDefault'), 'pPr'),
    );
  }

  final WordXml _x;
  final Map<String, _Style> _styles;
  final ThemeFonts _theme;
  final XmlElement? _runDefaults;
  final XmlElement? _paragraphDefaults;

  // Each style is resolved once: documents ask for the same ones on every
  // paragraph and run.
  late final String? defaultParagraphStyleId = _defaultOf('paragraph');
  late final String? defaultCharacterStyleId = _defaultOf('character');
  late final _ids = _idsByName();
  late final _baseRun = const RunProps().merge(_runDefaults, _x, _theme);
  late final _baseParagraph = const ParagraphProps().merge(
    _paragraphDefaults,
    _x,
  );
  final _runLayers = <String, _RunLayer>{};
  final _runs = <(String?, String?), RunProps>{};
  final _paragraphs = <String, ParagraphProps>{};
  final _bordered = <String, bool>{};

  ThemeFonts get theme => _theme;

  String? _defaultOf(String type) {
    for (final style in _styles.values) {
      if (style.type == type && style.isDefault) return style.id;
    }
    return null;
  }

  /// The first style of each type and name, as Word finds them.
  Map<(String, String), String> _idsByName() {
    final ids = <(String, String), String>{};
    for (final style in _styles.values) {
      ids.putIfAbsent((style.type, style.name), () => style.id);
    }
    return ids;
  }

  bool contains(String id) => _styles.containsKey(id);

  String? idByName(String name, {String type = 'paragraph'}) =>
      _ids[(type, name.toLowerCase())];

  int? headingLevel(String? styleId) {
    final style = _styles[styleId];
    if (style == null || style.type != 'paragraph') return null;
    final match = _headingName.firstMatch(style.name);
    return match == null ? null : int.parse(match.group(1)!);
  }

  String? headingStyleId(int level) => idByName('heading $level');

  RunProps runProps(String? paragraphStyleId, [String? characterStyleId]) =>
      _runs[(
        paragraphStyleId,
        characterStyleId,
      )] ??= _runLayer(characterStyleId)
          .over(_runLayer(paragraphStyleId ?? defaultParagraphStyleId))
          .applyTo(_baseRun);

  _RunLayer _runLayer(String? styleId) =>
      _resolve(
        styleId,
        _runLayers,
        (style, below) => _RunLayer.of(
          _x.child(style.element, 'rPr'),
          _x,
          _theme,
        ).over(below ?? _RunLayer.empty),
      ) ??
      _RunLayer.empty;

  ParagraphProps paragraphProps(String? paragraphStyleId) =>
      _resolve(
        paragraphStyleId ?? defaultParagraphStyleId,
        _paragraphs,
        (style, below) =>
            (below ?? _baseParagraph).merge(_x.child(style.element, 'pPr'), _x),
      ) ??
      _baseParagraph;

  /// Tables with no borders of their own or from a style show only gridlines.
  bool tableStyleHasBorders(String? styleId) =>
      _resolve(
        styleId,
        _bordered,
        (style, below) =>
            hasVisibleBorders(_x.child(style.element, 'tblPr')) ||
            (below ?? false),
      ) ??
      false;

  bool hasVisibleBorders(XmlElement? tableProperties) {
    final borders = _x.child(tableProperties, 'tblBorders');
    if (borders == null) return false;
    return borders.childElements.any((border) {
      final value = _x.val(border);
      return value != null && value != 'nil' && value != 'none';
    });
  }

  /// The value of [styleId] that [combine] makes from a style and the value
  /// of the style it's based on (null for none), worked out once per style
  /// and kept in [cache]. A style the chain comes back to ends it: each style
  /// of a loop takes the others' values only where it sets none.
  T? _resolve<T extends Object>(
    String? styleId,
    Map<String, T> cache,
    T Function(_Style style, T? below) combine,
  ) {
    final first = styleId == null ? null : _styles[styleId];
    if (first == null) return null;
    if (cache[first.id] case final known?) return known;

    final path = <_Style>[];
    final positions = <String, int>{};
    T? below;
    var style = first;
    while (true) {
      if (cache[style.id] case final known?) {
        below = known;
        break;
      }
      if (positions[style.id] case final loop?) {
        // The loop's first style takes all the others; each of the others
        // then is its own values over the next one's.
        var value = combine(path.last, null);
        for (var index = path.length - 2; index >= loop; index--) {
          value = combine(path[index], value);
        }
        final start = value;
        cache[path[loop].id] = start;
        for (var index = path.length - 1; index > loop; index--) {
          value = combine(path[index], value);
          cache[path[index].id] = value;
        }
        below = start;
        path.length = loop;
        break;
      }
      positions[style.id] = path.length;
      path.add(style);
      final base = style.basedOn == null ? null : _styles[style.basedOn];
      if (base == null) break;
      style = base;
    }
    for (final based in path.reversed) {
      final value = combine(based, below);
      cache[based.id] = value;
      below = value;
    }
    return cache[first.id];
  }
}

final _headingName = RegExp(r'^heading (\d)$');
