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

  /// Tamanho em pontos.
  final double size;
  final String? font;

  /// RRGGBB; nulo significa automático.
  final String? color;
  final String? background;

  /// 'super' ou 'sub'.
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

  RunProps merge(XmlElement? rPr, WordXml x, ThemeFonts theme) {
    if (rPr == null) return this;
    var result = this;
    final fonts = x.child(rPr, 'rFonts');
    if (fonts != null) {
      final themed = x.attr(fonts, 'asciiTheme') ?? x.attr(fonts, 'hAnsiTheme');
      final font = themed != null
          ? theme.resolve(themed)
          : x.attr(fonts, 'ascii') ?? x.attr(fonts, 'hAnsi');
      if (font != null) result = result.copyWith(font: font);
    }
    final bold = x.onOff(x.child(rPr, 'b'));
    final italic = x.onOff(x.child(rPr, 'i'));
    final strike =
        x.onOff(x.child(rPr, 'strike')) ?? x.onOff(x.child(rPr, 'dstrike'));
    final underline = x.child(rPr, 'u');
    final size = double.tryParse(x.childVal(rPr, 'sz') ?? '');
    result = result.copyWith(
      bold: bold,
      italic: italic,
      strike: strike,
      underline: underline == null
          ? null
          : (x.val(underline) ?? 'single') != 'none',
      size: size == null ? null : size / 2,
    );
    final color = x.child(rPr, 'color');
    if (color != null) {
      result = result.copyWith(color: () => _hexColor(x.val(color)));
    }
    final highlight = x.childVal(rPr, 'highlight');
    final shading = x.child(rPr, 'shd');
    if (highlight != null) {
      result = result.copyWith(background: () => highlightColors[highlight]);
    } else if (shading != null) {
      result = result.copyWith(
        background: () => _hexColor(x.attr(shading, 'fill')),
      );
    }
    final vertical = x.childVal(rPr, 'vertAlign');
    if (vertical != null) {
      result = result.copyWith(
        script: () => switch (vertical) {
          'superscript' => 'super',
          'subscript' => 'sub',
          _ => null,
        },
      );
    }
    return result;
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

  /// Múltiplo de linha simples (240 = 1,0).
  final double lineSpacing;
  final bool exactLineSpacing;

  /// Espaços em pontos.
  final double spaceBefore;
  final double spaceAfter;

  /// Recuos em twips; [firstLine] negativo é recuo deslocado.
  final double indentLeft;
  final double indentRight;
  final double firstLine;

  /// Sem espaço entre parágrafos do mesmo estilo.
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

  ThemeFonts get theme => _theme;

  String? get defaultParagraphStyleId => _defaultOf('paragraph');

  String? get defaultCharacterStyleId => _defaultOf('character');

  String? _defaultOf(String type) {
    for (final style in _styles.values) {
      if (style.type == type && style.isDefault) return style.id;
    }
    return null;
  }

  bool contains(String id) => _styles.containsKey(id);

  String? idByName(String name, {String type = 'paragraph'}) {
    final lower = name.toLowerCase();
    for (final style in _styles.values) {
      if (style.type == type && style.name == lower) return style.id;
    }
    return null;
  }

  int? headingLevel(String? styleId) {
    final style = _styles[styleId];
    if (style == null || style.type != 'paragraph') return null;
    final match = RegExp(r'^heading (\d)$').firstMatch(style.name);
    return match == null ? null : int.parse(match.group(1)!);
  }

  String? headingStyleId(int level) => idByName('heading $level');

  RunProps runProps(String? paragraphStyleId, [String? characterStyleId]) {
    var props = const RunProps().merge(_runDefaults, _x, _theme);
    for (final style in _chain(paragraphStyleId ?? defaultParagraphStyleId)) {
      props = props.merge(_x.child(style.element, 'rPr'), _x, _theme);
    }
    for (final style in _chain(characterStyleId)) {
      props = props.merge(_x.child(style.element, 'rPr'), _x, _theme);
    }
    return props;
  }

  ParagraphProps paragraphProps(String? paragraphStyleId) {
    var props = const ParagraphProps().merge(_paragraphDefaults, _x);
    for (final style in _chain(paragraphStyleId ?? defaultParagraphStyleId)) {
      props = props.merge(_x.child(style.element, 'pPr'), _x);
    }
    return props;
  }

  /// Tabelas sem bordas próprias nem de estilo aparecem só com guias.
  bool tableStyleHasBorders(String? styleId) => _chain(
    styleId,
  ).any((style) => hasVisibleBorders(_x.child(style.element, 'tblPr')));

  bool hasVisibleBorders(XmlElement? tableProperties) {
    final borders = _x.child(tableProperties, 'tblBorders');
    if (borders == null) return false;
    return borders.childElements.any((border) {
      final value = _x.val(border);
      return value != null && value != 'nil' && value != 'none';
    });
  }

  Iterable<_Style> _chain(String? styleId) {
    final chain = <_Style>[];
    final seen = <String>{};
    var current = styleId == null ? null : _styles[styleId];
    while (current != null && seen.add(current.id)) {
      chain.add(current);
      current = current.basedOn == null ? null : _styles[current.basedOn];
    }
    return chain.reversed;
  }
}
