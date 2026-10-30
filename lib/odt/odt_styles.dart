import 'package:xml/xml.dart';

import '../docx/docx_builder.dart';
import 'odf_xml.dart';

const _style = OdfNamespaces.style;
const _fo = OdfNamespaces.fo;
const _text = OdfNamespaces.text;

/// A `style:style` element: named (shared) or automatic (direct formatting).
class OdfStyle {
  OdfStyle(this.element, {required this.automatic})
    : name = element.odfAttribute(_style, 'name') ?? '',
      family = element.odfAttribute(_style, 'family') ?? '',
      parent = element.odfAttribute(_style, 'parent-style-name');

  final XmlElement element;
  final bool automatic;
  final String name;
  final String family;
  final String? parent;

  String get displayName =>
      element.odfAttribute(_style, 'display-name') ?? odfDisplayName(name);

  /// 1 to 10 for heading styles.
  int? get outlineLevel =>
      int.tryParse(element.odfAttribute(_style, 'default-outline-level') ?? '');

  String? get next => element.odfAttribute(_style, 'next-style-name');

  String? get listStyleName => element.odfAttribute(_style, 'list-style-name');

  String? get masterPageName =>
      element.odfAttribute(_style, 'master-page-name');

  /// `paragraph`, `text`, `table`, `table-column`, `table-cell`...
  XmlElement? properties(String kind) =>
      element.odfChild(_style, '$kind-properties');
}

/// Automatic styles of one part: content.xml's are used by the body,
/// styles.xml's by headers and footers.
class StyleScope {
  StyleScope(XmlElement? automaticStyles) {
    for (final element in automaticStyles?.childElements ?? <XmlElement>[]) {
      if (element.isOdf(_style, 'style')) {
        final style = OdfStyle(element, automatic: true);
        styles.putIfAbsent(_key(style.family, style.name), () => style);
      } else if (element.isOdf(_text, 'list-style')) {
        final name = element.odfAttribute(_style, 'name');
        if (name != null) lists.putIfAbsent(name, () => element);
      }
    }
  }

  final styles = <String, OdfStyle>{};
  final lists = <String, XmlElement>{};
}

String _key(String family, String name) => '$family\u0000$name';

/// Whether a paragraph property starts or ends a page.
typedef PageBreaks = ({bool? before, bool? after});

/// The styles of a document, resolved into the builder's formats.
class OdtStyles {
  OdtStyles._(
    this._fonts,
    this._defaults,
    this._named,
    this._namedLists,
    this.pageLayouts,
    this.masterPages,
    this.body,
    this.master,
  );

  factory OdtStyles.parse(XmlDocument content, XmlDocument? styles) {
    final fonts = <String, String>{};
    final defaults = <String, XmlElement>{};
    final named = <String, OdfStyle>{};
    final namedLists = <String, XmlElement>{};
    final pageLayouts = <String, XmlElement>{};
    final masterPages = <String, XmlElement>{};

    void readFonts(XmlElement? root) {
      final declarations = root?.odfChild(
        OdfNamespaces.office,
        'font-face-decls',
      );
      for (final face
          in declarations?.odfChildren(_style, 'font-face') ??
              const <XmlElement>[]) {
        final name = face.odfAttribute(_style, 'name');
        final family =
            odfFontFamily(
              face.odfAttribute(OdfNamespaces.svg, 'font-family'),
            ) ??
            name;
        if (name != null && family != null) {
          fonts.putIfAbsent(name, () => family);
        }
      }
    }

    final stylesRoot = styles?.rootElement;
    readFonts(content.rootElement);
    readFonts(stylesRoot);
    final common = stylesRoot?.odfChild(OdfNamespaces.office, 'styles');
    for (final element in common?.childElements ?? <XmlElement>[]) {
      if (element.isOdf(_style, 'default-style')) {
        final family = element.odfAttribute(_style, 'family');
        if (family != null) defaults.putIfAbsent(family, () => element);
      } else if (element.isOdf(_style, 'style')) {
        final style = OdfStyle(element, automatic: false);
        named.putIfAbsent(_key(style.family, style.name), () => style);
      } else if (element.isOdf(_text, 'list-style')) {
        final name = element.odfAttribute(_style, 'name');
        if (name != null) namedLists.putIfAbsent(name, () => element);
      }
    }
    final masterAutomatic = stylesRoot?.odfChild(
      OdfNamespaces.office,
      'automatic-styles',
    );
    for (final layout
        in masterAutomatic?.odfChildren(_style, 'page-layout') ??
            const <XmlElement>[]) {
      final name = layout.odfAttribute(_style, 'name');
      if (name != null) pageLayouts.putIfAbsent(name, () => layout);
    }
    final masterStyles = stylesRoot?.odfChild(
      OdfNamespaces.office,
      'master-styles',
    );
    for (final page
        in masterStyles?.odfChildren(_style, 'master-page') ??
            const <XmlElement>[]) {
      final name = page.odfAttribute(_style, 'name');
      if (name != null) masterPages.putIfAbsent(name, () => page);
    }
    return OdtStyles._(
      fonts,
      defaults,
      named,
      namedLists,
      pageLayouts,
      masterPages,
      StyleScope(
        content.rootElement.odfChild(OdfNamespaces.office, 'automatic-styles'),
      ),
      StyleScope(masterAutomatic),
    );
  }

  final Map<String, String> _fonts;
  final Map<String, XmlElement> _defaults;
  final Map<String, OdfStyle> _named;
  final Map<String, XmlElement> _namedLists;
  final Map<String, XmlElement> pageLayouts;

  /// In document order; the first one is the default.
  final Map<String, XmlElement> masterPages;

  final StyleScope body;
  final StyleScope master;

  Iterable<OdfStyle> namedStyles(String family) =>
      _named.values.where((style) => style.family == family);

  OdfStyle? find(StyleScope scope, String family, String? name) {
    if (name == null) return null;
    final key = _key(family, name);
    return scope.styles[key] ?? _named[key];
  }

  OdfStyle? named(String family, String? name) =>
      name == null ? null : _named[_key(family, name)];

  /// The style and its ancestors, the root first; parents are always named
  /// styles. Without a [scope], only named styles are looked up.
  List<OdfStyle> chain(StyleScope? scope, String family, String? name) {
    final chain = <OdfStyle>[];
    final seen = <String>{};
    var current = scope == null
        ? named(family, name)
        : find(scope, family, name);
    while (current != null && seen.add(current.name) && chain.length < 32) {
      chain.add(current);
      current = named(family, current.parent);
    }
    return chain.reversed.toList();
  }

  XmlElement? defaultStyle(String family) => _defaults[family];

  XmlElement? listStyle(StyleScope scope, String? name) =>
      name == null ? null : scope.lists[name] ?? _namedLists[name];

  String? fontFamily(String name) => _fonts[name] ?? name;

  /// Character formatting set by `style:text-properties`; percentages of
  /// the font size are taken from [inheritedSize].
  RunFormat runOf(XmlElement? properties, {required double inheritedSize}) {
    if (properties == null) return const RunFormat();
    String? attribute(String namespace, String local) =>
        properties.odfAttribute(namespace, local);

    final fontName = attribute(_style, 'font-name');
    final font = fontName != null
        ? fontFamily(fontName)
        : odfFontFamily(attribute(_fo, 'font-family'));
    final sizeValue = attribute(_fo, 'font-size');
    var size = odfLength(sizeValue);
    if (size == null) {
      final percent = odfPercent(sizeValue);
      if (percent != null) size = inheritedSize * percent;
    }
    final weight = attribute(_fo, 'font-weight');
    final fontStyle = attribute(_fo, 'font-style');
    final position = attribute(
      _style,
      'text-position',
    )?.trim().split(RegExp(r'\s+'));
    final shift = position == null
        ? null
        : switch (position.first) {
            'super' => 1.0,
            'sub' => -1.0,
            final value => odfPercent(value),
          };
    final transform = attribute(_fo, 'text-transform');
    final variant = attribute(_fo, 'font-variant');
    final display = attribute(_text, 'display');
    return RunFormat(
      font: font,
      size: size != null && size > 0 && size <= 1600 ? size : null,
      bold: switch (weight) {
        null => null,
        'bold' || 'bolder' => true,
        'normal' || 'lighter' => false,
        _ => (int.tryParse(weight) ?? 400) >= 600,
      },
      italic: fontStyle == null ? null : fontStyle != 'normal',
      underline: _line(
        attribute(_style, 'text-underline-style'),
        attribute(_style, 'text-underline-type'),
      ),
      strike: _line(
        attribute(_style, 'text-line-through-style'),
        attribute(_style, 'text-line-through-type'),
      ),
      color: odfColor(attribute(_fo, 'color')),
      background: odfColor(attribute(_fo, 'background-color')),
      position: shift == null || shift == 0
          ? null
          : shift > 0
          ? VerticalPosition.superscript
          : VerticalPosition.subscript,
      allCaps: switch (transform) {
        'uppercase' => true,
        'none' => false,
        _ => null,
      },
      smallCaps: switch (variant) {
        'small-caps' => true,
        'normal' => false,
        _ => null,
      },
      hidden: switch (display) {
        'none' => true,
        'true' => false,
        _ => null,
      },
    );
  }

  static bool? _line(String? style, String? type) {
    if (style == null) return type == 'none' ? false : null;
    return style != 'none' && type != 'none';
  }

  /// Paragraph formatting set by `style:paragraph-properties`.
  ParagraphFormat paragraphOf(XmlElement? properties) {
    if (properties == null) return const ParagraphFormat();
    String? attribute(String namespace, String local) =>
        properties.odfAttribute(namespace, local);

    final margin = odfLength(attribute(_fo, 'margin'));
    final lineHeight = attribute(_fo, 'line-height');
    final atLeast = odfLength(attribute(_style, 'line-height-at-least'));
    final percent = odfPercent(lineHeight);
    final exact = odfLength(lineHeight);
    final LineSpacing? lineSpacing;
    if (lineHeight == 'normal') {
      lineSpacing = const LineSpacing.multiple(1);
    } else if (percent != null && percent > 0) {
      lineSpacing = LineSpacing.multiple(percent);
    } else if (exact != null && exact > 0) {
      lineSpacing = LineSpacing.exactly(exact);
    } else if (atLeast != null && atLeast > 0) {
      lineSpacing = LineSpacing.atLeast(atLeast);
    } else {
      lineSpacing = null;
    }
    final writingMode = attribute(_style, 'writing-mode');
    return ParagraphFormat(
      align: switch (attribute(_fo, 'text-align')) {
        'start' || 'left' => ParagraphAlign.left,
        'end' || 'right' => ParagraphAlign.right,
        'center' => ParagraphAlign.center,
        'justify' => ParagraphAlign.justify,
        _ => null,
      },
      indentLeft: odfLength(attribute(_fo, 'margin-left')) ?? margin,
      indentRight: odfLength(attribute(_fo, 'margin-right')) ?? margin,
      firstLine: odfLength(attribute(_fo, 'text-indent')),
      spaceBefore: odfLength(attribute(_fo, 'margin-top')) ?? margin,
      spaceAfter: odfLength(attribute(_fo, 'margin-bottom')) ?? margin,
      lineSpacing: lineSpacing,
      keepNext: _keep(attribute(_fo, 'keep-with-next')),
      keepLines: _keep(attribute(_fo, 'keep-together')),
      contextualSpacing: switch (attribute(_style, 'contextual-spacing')) {
        'true' => true,
        'false' => false,
        _ => null,
      },
      rightToLeft: switch (writingMode) {
        'rl-tb' || 'rl' || 'tb-rl' => true,
        'lr-tb' || 'lr' || 'tb-lr' => false,
        _ => null,
      },
      tabs: _tabs(properties.odfChild(_style, 'tab-stops')),
    );
  }

  static bool? _keep(String? value) => switch (value) {
    'always' => true,
    'auto' => false,
    _ => null,
  };

  static List<TabStop> _tabs(XmlElement? stops) {
    if (stops == null) return const [];
    return [
      for (final stop in stops.odfChildren(_style, 'tab-stop').take(64))
        if (odfLength(stop.odfAttribute(_style, 'position'))
            case final position? when position >= 0)
          TabStop(
            position,
            align: switch (stop.odfAttribute(_style, 'type')) {
              'center' => TabAlign.center,
              'right' => TabAlign.right,
              'char' => TabAlign.decimal,
              _ => TabAlign.left,
            },
            leader: _leader(
              stop.odfAttribute(_style, 'leader-text'),
              stop.odfAttribute(_style, 'leader-style'),
            ),
          ),
    ];
  }

  static TabLeader _leader(String? text, String? style) {
    if (style == 'none') return TabLeader.none;
    return switch (text?.trim()) {
      '.' || '…' => TabLeader.dot,
      '-' => TabLeader.hyphen,
      '_' => TabLeader.underscore,
      _ => switch (style) {
        'dotted' => TabLeader.dot,
        'dash' || 'long-dash' => TabLeader.hyphen,
        'solid' => TabLeader.underscore,
        _ => TabLeader.none,
      },
    };
  }

  static PageBreaks breaksOf(XmlElement? properties) {
    bool? page(String local) => switch (properties?.odfAttribute(_fo, local)) {
      null => null,
      'page' => true,
      _ => false,
    };
    return (before: page('break-before'), after: page('break-after'));
  }

  /// The levels of a `text:list-style`.
  static ListSpec listSpecOf(XmlElement listStyle) {
    final byLevel = <int, XmlElement>{};
    for (final child in listStyle.childElements) {
      final level = int.tryParse(child.odfAttribute(_text, 'level') ?? '');
      if (level != null && level >= 1 && level <= 9) {
        byLevel.putIfAbsent(level, () => child);
      }
    }
    final levels = <ListLevelSpec>[];
    for (var level = 1; level <= 9; level++) {
      levels.add(
        _level(byLevel[level], level, levels.isEmpty ? null : levels.last),
      );
    }
    return ListSpec(levels);
  }

  static ListLevelSpec _level(
    XmlElement? element,
    int level,
    ListLevelSpec? previous,
  ) {
    if (element == null) {
      final bullet = previous == null || previous.format == NumberFormat.bullet;
      return ListLevelSpec(
        format: bullet ? NumberFormat.bullet : previous.format,
        text: bullet ? previous?.text ?? '•' : '%$level.',
        indentLeft: previous?.indentLeft == null
            ? null
            : previous!.indentLeft! + 36,
        hanging: previous?.hanging ?? 18,
      );
    }
    final indent = _indent(element.odfChild(_style, 'list-level-properties'));
    if (element.isOdf(_text, 'list-level-style-number')) {
      final format = _numberFormat(element.odfAttribute(_style, 'num-format'));
      final shown =
          (int.tryParse(element.odfAttribute(_text, 'display-levels') ?? '') ??
                  1)
              .clamp(1, level);
      String affix(String local) =>
          (element.odfAttribute(_style, local) ?? '').replaceAll('%', '');
      final numbers = [
        for (
          var shownLevel = level - shown + 1;
          shownLevel <= level;
          shownLevel++
        )
          '%$shownLevel',
      ].join('.');
      return ListLevelSpec(
        format: format,
        text:
            '${affix('num-prefix')}'
            '${format == NumberFormat.none ? '' : numbers}'
            '${affix('num-suffix')}',
        start:
            (int.tryParse(element.odfAttribute(_text, 'start-value') ?? '') ??
                    1)
                .clamp(0, 32767),
        indentLeft: indent.left,
        hanging: indent.hanging,
      );
    }
    final char = element.isOdf(_text, 'list-level-style-bullet')
        ? element.odfAttribute(_text, 'bullet-char')
        : null;
    final rune = char == null || char.isEmpty ? null : char.runes.first;
    return ListLevelSpec(
      format: NumberFormat.bullet,
      // Private-use symbols come from fonts such as OpenSymbol.
      text: rune == null || rune >= 0xE000 && rune <= 0xF8FF || rune < 0x20
          ? '•'
          : String.fromCharCode(rune),
      indentLeft: indent.left,
      hanging: indent.hanging,
    );
  }

  static ({double? left, double hanging}) _indent(XmlElement? properties) {
    if (properties == null) return (left: null, hanging: 18);
    if (properties.odfAttribute(_text, 'list-level-position-and-space-mode') ==
        'label-alignment') {
      final alignment = properties.odfChild(
        _style,
        'list-level-label-alignment',
      );
      final indent =
          odfLength(alignment?.odfAttribute(_fo, 'text-indent')) ?? 0;
      return (
        left: odfLength(alignment?.odfAttribute(_fo, 'margin-left')),
        hanging: indent < 0 ? -indent : 0,
      );
    }
    final before = odfLength(properties.odfAttribute(_text, 'space-before'));
    final width = odfLength(properties.odfAttribute(_text, 'min-label-width'));
    if (before == null && width == null) return (left: null, hanging: 18);
    return (left: (before ?? 0) + (width ?? 0), hanging: width ?? 0);
  }

  static NumberFormat _numberFormat(String? format) => switch (format) {
    null || '1' => NumberFormat.decimal,
    '' => NumberFormat.none,
    'a' => NumberFormat.lowerLetter,
    'A' => NumberFormat.upperLetter,
    'i' => NumberFormat.lowerRoman,
    'I' => NumberFormat.upperRoman,
    _ when format.startsWith('0') => NumberFormat.decimalZero,
    _ => NumberFormat.decimal,
  };
}
