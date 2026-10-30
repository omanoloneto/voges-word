import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:xml/xml.dart';

import '../document/document_codec.dart';
import '../document/headers_footers.dart';
import '../document/picture_crop.dart';
import '../docx/docx_builder.dart';
import '../docx/image_formats.dart';
import 'odf_xml.dart';
import 'odt_package.dart';
import 'odt_styles.dart';

const _office = OdfNamespaces.office;
const _style = OdfNamespaces.style;
const _text = OdfNamespaces.text;
const _table = OdfNamespaces.table;
const _draw = OdfNamespaces.draw;
const _fo = OdfNamespaces.fo;
const _svg = OdfNamespaces.svg;
const _xlink = OdfNamespaces.xlink;
const _xml = 'http://www.w3.org/XML/1998/namespace';
const _dr3d = 'urn:oasis:names:tc:opendocument:xmlns:dr3d:1.0';
const _loext = OdfNamespaces.loext;

/// Where blocks are read; only the body takes page and section breaks.
enum _Place { body, cell, frame, note, header }

class _Context {
  const _Context(this.scope, this.place, [this.tables = 0]);

  final StyleScope scope;
  final _Place place;

  /// Tables around the content.
  final int tables;
}

/// What a paragraph's style gives it.
class _ParagraphStyle {
  const _ParagraphStyle({
    required this.styleId,
    required this.direct,
    required this.directRun,
    required this.resolved,
    required this.resolvedRun,
    required this.textCase,
    required this.breaks,
    required this.masterPage,
    required this.outlineLevel,
    required this.listStyle,
  });

  /// The named style, as the builder knows it.
  final String? styleId;

  /// The automatic style's own formatting.
  final ParagraphFormat direct;
  final RunFormat directRun;

  /// What the defaults and the whole style chain give.
  final ParagraphFormat resolved;
  final RunFormat resolvedRun;
  final TextCase textCase;
  final PageBreaks breaks;
  final String? masterPage;
  final int? outlineLevel;
  final String? listStyle;
}

class _ListState {
  const _ListState(this.styleName, this.numId, this.spec);

  final String? styleName;
  final int numId;
  final ListSpec spec;
}

typedef _Cover = ({int lastRow, int span, String? background});

typedef _Picture = ({Uint8List bytes, String mime});

/// Fractions of a picture's width or height cut off each side.
typedef _Cut = ({double left, double top, double right, double bottom});

String _idKey(String family, String? name) => '$family/$name';

double? _positive(double? value) =>
    value != null && value.isFinite && value > 0 ? value : null;

String? _nonEmpty(String? value) =>
    value == null || value.trim().isEmpty ? null : value;

int _repeat(String? value) =>
    (int.tryParse(value?.trim() ?? '') ?? 1).clamp(1, 10000);

int? _headingName(String name) {
  final match = RegExp(
    r'^heading\s*(\d)$',
    caseSensitive: false,
  ).firstMatch(name.trim());
  final level = match == null ? null : int.parse(match[1]!);
  return level != null && level >= 1 ? level : null;
}

ParagraphFormat _withoutIndents(ParagraphFormat format, {ListRef? list}) =>
    ParagraphFormat(
      styleId: format.styleId,
      align: format.align,
      indentRight: format.indentRight,
      spaceBefore: format.spaceBefore,
      spaceAfter: format.spaceAfter,
      lineSpacing: format.lineSpacing,
      keepNext: format.keepNext,
      keepLines: format.keepLines,
      pageBreakBefore: format.pageBreakBefore,
      contextualSpacing: format.contextualSpacing,
      rightToLeft: format.rightToLeft,
      list: list ?? format.list,
      tabs: format.tabs,
    );

ParagraphFormat _withoutTabs(ParagraphFormat format) => ParagraphFormat(
  styleId: format.styleId,
  align: format.align,
  indentLeft: format.indentLeft,
  indentRight: format.indentRight,
  firstLine: format.firstLine,
  spaceBefore: format.spaceBefore,
  spaceAfter: format.spaceAfter,
  lineSpacing: format.lineSpacing,
  keepNext: format.keepNext,
  keepLines: format.keepLines,
  contextualSpacing: format.contextualSpacing,
  rightToLeft: format.rightToLeft,
  list: format.list,
);

bool _samePage(PageSpec a, PageSpec b) =>
    (a.width - b.width).abs() < 0.5 &&
    (a.height - b.height).abs() < 0.5 &&
    a.margins == b.margins &&
    a.columns == b.columns &&
    a.numberFormat == b.numberFormat;

/// Builds a [DocumentSpec] from an OpenDocument Text package.
class OdtReader {
  OdtReader(this.package)
    : _styles = OdtStyles.parse(package.content, package.styles);

  final OdtPackage package;
  final OdtStyles _styles;

  /// What was left out or adjusted while reading.
  final notices = <DocumentNotice>{};

  static const _maxStyles = 5000;
  static const _maxLists = 5000;
  static const _maxCells = 100000;
  static const _maxTableDepth = 16;
  static const _maxColumns = 63;

  /// Characters of text, picture bytes / 8 and roughly the bytes of markup
  /// each paragraph, run, cell and other element adds, repeated rows and
  /// cells included.
  static const _maxOutput = 64 * 1024 * 1024;

  /// Rough markup of one element of the built document.
  static const _elementCost = 32;
  static const _pictureCost = 1024;

  /// Pixels decoded to crop pictures; past it they are shown whole.
  static const _maxCropPixels = 160000000;

  late final DocumentSpec _spec;
  late final RunFormat _baseRun;
  late final TextCase _baseCase;
  late final ParagraphFormat _baseParagraph;
  final _ids = <String, String>{};
  final _usedIds = <String>{
    'Normal',
    'DefaultParagraphFont',
    'TableNormal',
    'Hyperlink',
    'FootnoteText',
    'FootnoteReference',
    'EndnoteText',
    'EndnoteReference',
    for (var level = 1; level <= 9; level++) 'Heading$level',
  };
  final _headingLevels = <String, int>{};
  final _headingIds = <int, String>{};
  final _paragraphStyles = <StyleScope, Map<String, _ParagraphStyle>>{};
  final _listSpecs = <(StyleScope, String?), ListSpec>{};
  final _listsById = <String, int>{};
  final _listsByStyle = <String?, int>{};
  final _pages = <String?, PageSpec>{};
  final _crops = <(Uint8List, double, double, double, double), _Picture?>{};
  _Outline? _outline;
  var _lists = 0;
  var _cells = 0;
  var _output = 0;
  var _cropPixels = 0.0;
  var _started = false;
  var _pendingBreak = false;
  String? _firstMaster;
  String? _master;

  /// The page style each section starts with, and every one the body uses.
  final _sectionMasters = <String?>[];
  final _usedMasters = <String>{};

  DocumentSpec read() {
    final defaults = _styles.defaultStyle('paragraph');
    final text = defaults?.odfChild(_style, 'text-properties');
    final paragraph = defaults?.odfChild(_style, 'paragraph-properties');
    _baseRun = const RunFormat(
      size: 12,
    ).merge(_styles.runOf(text, inheritedSize: 12));
    _baseCase = OdtStyles.textCaseOf(text) ?? TextCase.asWritten;
    _baseParagraph = _styles.paragraphOf(paragraph);
    _spec = DocumentSpec(
      defaultRun: RunFormat(
        font: _baseRun.font ?? 'Times New Roman',
        size: _baseRun.size,
        color: _baseRun.color,
      ),
      defaultParagraph: ParagraphFormat(
        spaceBefore: _baseParagraph.spaceBefore ?? 0,
        spaceAfter: _baseParagraph.spaceAfter ?? 0,
        lineSpacing:
            _baseParagraph.lineSpacing ?? const LineSpacing.multiple(1),
      ),
      language: _language(text),
      defaultTabStop:
          _positive(
            odfLength(paragraph?.odfAttribute(_style, 'tab-stop-distance')),
          ) ??
          35.4,
    );
    _addStyles();
    _outline = _Outline.of(_styles.outlineStyle);
    if (package.hasMacros || _hasScripts()) {
      notices.add(DocumentNotice.contentNotImported);
    }

    _master = _firstMaster = _styles.masterPages.containsKey('Standard')
        ? 'Standard'
        : _styles.masterPages.keys.firstOrNull;
    final body = package.content.rootElement
        .odfChild(_office, 'body')!
        .odfChild(_office, 'text')!;
    _blocks(body, _spec.body, _Context(_styles.body, _Place.body));

    if (_sectionMasters.isEmpty) _sectionMasters.add(_firstMaster);
    _usedMasters.addAll(_sectionMasters.whereType<String>());
    _spec.page = _page(_sectionMasters.last);
    _readHeadersFooters();
    return _spec;
  }

  static String? _language(XmlElement? properties) {
    final language = properties?.odfAttribute(OdfNamespaces.fo, 'language');
    if (language == null ||
        !RegExp(r'^[a-zA-Z]{2,8}$').hasMatch(language) ||
        const {'zxx', 'none'}.contains(language)) {
      return null;
    }
    final country = properties?.odfAttribute(OdfNamespaces.fo, 'country');
    return country != null && RegExp(r'^[a-zA-Z0-9]{2,3}$').hasMatch(country)
        ? '$language-${country.toUpperCase()}'
        : language;
  }

  bool _hasScripts() =>
      package.content.rootElement
          .odfChild(_office, 'scripts')
          ?.childElements
          .isNotEmpty ??
      false;

  void _charge(int amount) {
    _output += amount;
    if (_output > _maxOutput) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
  }

  /// Roughly what the builder writes for a run's formatting.
  static int _formatCost(RunFormat format) =>
      format.isEmpty ? 0 : 64 + 4 * (format.font?.length ?? 0);

  // Styles

  void _addStyles() {
    final paragraphs = _styles
        .namedStyles('paragraph')
        .take(_maxStyles)
        .toList();
    final characters = _styles.namedStyles('text').take(_maxStyles).toList();
    final taken = <int>{};
    for (final style in paragraphs) {
      final level = style.outlineLevel;
      if (style.name != 'Standard' &&
          level != null &&
          level >= 1 &&
          level <= 9 &&
          taken.add(level)) {
        _headingLevels[style.name] = level;
      }
    }
    for (final style in paragraphs) {
      if (style.name == 'Standard' || _headingLevels.containsKey(style.name)) {
        continue;
      }
      final level = _headingName(style.displayName);
      if (level != null && taken.add(level)) {
        _headingLevels[style.name] = level;
      }
    }
    for (final style in paragraphs) {
      final level = _headingLevels[style.name];
      final id = style.name == 'Standard'
          ? 'Normal'
          : level != null
          ? 'Heading$level'
          : _newId(style.name);
      _ids[_idKey('paragraph', style.name)] = id;
      if (level != null) _headingIds[level] = id;
    }
    for (final style in characters) {
      _ids[_idKey('text', style.name)] = _newId(style.name);
    }
    for (final style in paragraphs) {
      _spec.styles.add(_paragraphStyleSpec(style));
    }
    for (final style in characters) {
      _spec.styles.add(
        StyleSpec.character(
          _ids[_idKey('text', style.name)]!,
          _styleName(style.displayName, heading: false),
          basedOn: _ids[_idKey('text', style.parent)],
          run: _styles.runOf(
            style.properties('text'),
            inheritedSize: _parentSize('text', style),
          ),
        ),
      );
    }
  }

  StyleSpec _paragraphStyleSpec(OdfStyle style) {
    final level = _headingLevels[style.name];
    final normal = style.name == 'Standard';
    var paragraph = _withoutTabs(
      _styles.paragraphOf(style.properties('paragraph')),
    );
    if (normal) paragraph = _withoutTabs(_baseParagraph).merge(paragraph);
    return StyleSpec.paragraph(
      _ids[_idKey('paragraph', style.name)]!,
      _styleName(style.displayName, heading: level != null),
      basedOn: normal ? null : _ids[_idKey('paragraph', style.parent)],
      next: _ids[_idKey('paragraph', style.next)],
      run: _styles.runOf(
        style.properties('text'),
        inheritedSize: _parentSize('paragraph', style),
      ),
      paragraph: paragraph,
      headingLevel: level,
    );
  }

  /// The font size a named style's percentages refer to.
  double _parentSize(String family, OdfStyle style) {
    final chain = _styles.chain(null, family, style.name);
    var size = _baseRun.size ?? 12;
    for (final ancestor in chain.take(chain.length - 1)) {
      size =
          _styles
              .runOf(ancestor.properties('text'), inheritedSize: size)
              .size ??
          size;
    }
    return size;
  }

  /// Only heading styles may be called `heading N`, the name the editor
  /// recognizes.
  static String _styleName(String name, {required bool heading}) =>
      heading || _headingName(name) == null ? name : '$name.';

  String _newId(String name) {
    var base = odfDisplayName(name).replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (!RegExp(r'^[A-Za-z]').hasMatch(base)) base = 'S$base';
    if (base.length > 32) base = base.substring(0, 32);
    var id = base;
    for (var number = 2; !_usedIds.add(id); number++) {
      id = '${base}_$number';
    }
    return id;
  }

  _ParagraphStyle _paragraphStyle(StyleScope scope, String? name) {
    final cache = _paragraphStyles.putIfAbsent(scope, () => {});
    return cache[name ?? ''] ??= _resolveParagraphStyle(scope, name);
  }

  _ParagraphStyle _resolveParagraphStyle(StyleScope scope, String? name) {
    var run = _baseRun;
    var paragraph = _baseParagraph;
    var textCase = _baseCase;
    var direct = const ParagraphFormat();
    var directRun = const RunFormat();
    bool? before;
    bool? after;
    String? master;
    int? outline;
    String? list;
    OdfStyle? named;
    for (final style in _styles.chain(scope, 'paragraph', name)) {
      final text = style.properties('text');
      final ownRun = _styles.runOf(text, inheritedSize: run.size ?? 12);
      final properties = style.properties('paragraph');
      final ownParagraph = _styles.paragraphOf(properties);
      run = run.merge(ownRun);
      paragraph = paragraph.merge(ownParagraph);
      textCase = OdtStyles.textCaseOf(text) ?? textCase;
      final breaks = OdtStyles.breaksOf(properties);
      before = breaks.before ?? before;
      after = breaks.after ?? after;
      master = _nonEmpty(style.masterPageName) ?? master;
      outline = style.outlineLevel ?? outline;
      list = style.listStyleName ?? list;
      if (style.automatic) {
        direct = direct.merge(ownParagraph);
        directRun = directRun.merge(ownRun);
      } else {
        named = style;
        direct = const ParagraphFormat();
        directRun = const RunFormat();
      }
    }
    return _ParagraphStyle(
      styleId: named == null ? null : _ids[_idKey('paragraph', named.name)],
      direct: _withoutTabs(direct),
      directRun: directRun,
      resolved: paragraph,
      resolvedRun: run,
      textCase: textCase,
      breaks: (before: before, after: after),
      masterPage: master,
      outlineLevel: outline,
      listStyle: list,
    );
  }

  // Blocks

  void _blocks(XmlElement parent, List<BlockSpec> out, _Context context) {
    for (final element in parent.childElements) {
      _block(element, out, context);
    }
  }

  void _block(XmlElement element, List<BlockSpec> out, _Context context) {
    final namespace = element.name.namespaceUri;
    final local = element.name.local;
    if (namespace == _text) {
      switch (local) {
        case 'p' || 'h':
          _paragraph(element, out, context);
        case 'list':
          _list(element, out, context, level: 0);
        case 'numbered-paragraph':
          _numberedParagraph(element, out, context);
        case 'section':
          if (_hiddenSection(element)) {
            notices.add(DocumentNotice.contentNotImported);
          } else {
            _blocks(element, out, context);
          }
        case 'index-body' || 'index-title':
          _blocks(element, out, context);
        case 'table-of-content' ||
            'illustration-index' ||
            'table-index' ||
            'object-index' ||
            'user-index' ||
            'alphabetical-index' ||
            'bibliography':
          final content = element.odfChild(_text, 'index-body');
          if (content != null) _blocks(content, out, context);
        case 'tracked-changes':
          if (element.childElements.isNotEmpty) {
            notices.add(DocumentNotice.trackedChangesAccepted);
          }
      }
    } else if (namespace == _table && local == 'table') {
      _readTable(element, out, context);
    } else if (namespace == _draw || namespace == _dr3d) {
      final inlines = <InlineSpec>[];
      final floating = <BlockSpec>[];
      _Inlines(this, context, floating, paragraphSize: _baseRun.size ?? 12)
        ..node(element, const RunFormat(), inlines)
        ..flush();
      if (inlines.isNotEmpty) {
        _charge(2 * _elementCost);
        out.add(ParagraphSpec(inlines));
      }
      out.addAll(floating);
    } else if (namespace == _office && local == 'annotation') {
      notices.add(DocumentNotice.commentsHidden);
    }
  }

  /// Hidden always, or by a condition that held when the file was saved.
  static bool _hiddenSection(XmlElement section) =>
      switch (section.odfAttribute(_text, 'display')) {
        'none' => true,
        'condition' => section.odfAttribute(_text, 'is-hidden') == 'true',
        _ => false,
      };

  /// A hidden-paragraph field whose condition held when the file was saved.
  static bool _hiddenParagraph(XmlElement container) {
    for (final child in container.childElements) {
      if (child.isOdf(_text, 'hidden-paragraph')) {
        if (child.odfAttribute(_text, 'is-hidden') == 'true') return true;
      } else if ((child.isOdf(_text, 'span') || child.isOdf(_text, 'a')) &&
          _hiddenParagraph(child)) {
        return true;
      }
    }
    return false;
  }

  void _paragraph(
    XmlElement element,
    List<BlockSpec> out,
    _Context context, {
    ListRef? list,
    double? indent,
  }) {
    if (_hiddenParagraph(element)) {
      notices.add(DocumentNotice.contentNotImported);
      return;
    }
    final style = _paragraphStyle(
      context.scope,
      element.odfAttribute(_text, 'style-name'),
    );
    final newPage =
        context.place == _Place.body &&
        _beforeBodyBlock(out, style.masterPage, style.breaks);
    final heading = element.isOdf(_text, 'h')
        ? (int.tryParse(element.odfAttribute(_text, 'outline-level') ?? '') ??
                  style.outlineLevel ??
                  1)
              .clamp(1, 9)
        : null;
    final number =
        list ??
        (heading != null && indent == null
            ? _outlineNumber(element, style, heading, context)
            : null);

    var format = ParagraphFormat(
      styleId: style.styleId == 'Normal' ? null : style.styleId,
    ).merge(style.direct);
    var run = style.directRun;
    if (heading != null && _headingIds[heading] != style.styleId) {
      // Another style with an outline level: its look becomes direct
      // formatting on the level's heading style.
      format = _withoutTabs(style.resolved);
      run = style.resolvedRun;
    }
    if (number != null) {
      // The numbering sets the indents and the tab after the number.
      format = _withoutIndents(format, list: number);
    } else {
      if (indent != null) {
        format = format.merge(
          ParagraphFormat(indentLeft: indent, firstLine: 0),
        );
      }
      final shift = package.tabsRelativeToIndent
          ? format.indentLeft ?? style.resolved.indentLeft ?? 0
          : 0.0;
      format = format.merge(
        ParagraphFormat(
          tabs: [
            for (final tab in style.resolved.tabs)
              TabStop(
                tab.position + shift,
                align: tab.align,
                leader: tab.leader,
              ),
          ],
        ),
      );
    }
    _charge(
      2 * _elementCost + _elementCost * format.tabs.length + _formatCost(run),
    );

    final inlines = <InlineSpec>[if (newPage) const BreakSpec(BreakKind.page)];
    final floating = <BlockSpec>[];
    _Inlines(
        this,
        context,
        floating,
        paragraphSize: style.resolvedRun.size ?? 12,
        textCase: style.textCase,
      )
      ..read(element, run, inlines)
      ..flush();
    out
      ..add(ParagraphSpec(inlines, format: format, heading: heading, mark: run))
      ..addAll(floating);
  }

  /// Headings outside lists take their numbers from the outline style, as
  /// in LibreOffice, unless their style has a list of its own.
  ListRef? _outlineNumber(
    XmlElement heading,
    _ParagraphStyle style,
    int level,
    _Context context,
  ) {
    final outline = _outline;
    if (outline == null ||
        context.place == _Place.header ||
        style.styleId == null ||
        style.listStyle != null && style.listStyle != outline.name ||
        heading.odfAttribute(_text, 'is-list-header') == 'true') {
      return null;
    }
    final restart = heading.odfAttribute(_text, 'restart-numbering') == 'true'
        ? (int.tryParse(heading.odfAttribute(_text, 'start-value') ?? '') ??
                  outline.spec.levels[level - 1].start)
              .clamp(0, 32767)
        : null;
    return outline.number(level - 1, restart, _addList);
  }

  /// Page and section breaks before a paragraph or table of the body;
  /// returns whether it starts a new page without a new section.
  bool _beforeBodyBlock(
    List<BlockSpec> out,
    String? master,
    PageBreaks breaks,
  ) {
    final known = master != null && _styles.masterPages.containsKey(master)
        ? master
        : null;
    final pending = _pendingBreak;
    _pendingBreak = breaks.after ?? false;
    if (!_started) {
      _started = true;
      if (known != null) _master = _firstMaster = known;
      _sectionMasters.add(_master);
      return false;
    }
    if (known != null) {
      final previous = _master;
      _master = known;
      _usedMasters.add(known);
      if (_samePage(_page(known), _page(previous))) return true;
      _charge(16 * _elementCost);
      out.add(SectionBreakSpec(_page(previous)));
      _sectionMasters.add(known);
      return false;
    }
    return pending || (breaks.before ?? false);
  }

  // Lists

  void _list(
    XmlElement element,
    List<BlockSpec> out,
    _Context context, {
    required int level,
    _ListState? parent,
  }) {
    final own = element.odfAttribute(_text, 'style-name');
    final inherited =
        parent != null && (own == null || own == parent.styleName);
    final firstItem = element.odfChild(_text, 'list-item');
    var startsHere = false;
    _ListState state;
    if (inherited) {
      state = parent;
    } else {
      final styleName =
          own ?? parent?.styleName ?? _firstListStyle(element, context);
      final spec = _listSpec(context.scope, styleName);
      final continueList = element.odfAttribute(_text, 'continue-list');
      final continued =
          (continueList == null ? null : _listsById[continueList]) ??
          (element.odfAttribute(_text, 'continue-numbering') == 'true'
              ? _listsByStyle[styleName]
              : null);
      startsHere = continued == null;
      state = _ListState(
        styleName,
        continued ?? _addList(_withStart(spec, level, _startOf(firstItem))),
        spec,
      );
    }
    final id = element.getAttribute('id', namespaceUri: _xml);
    if (id != null) _listsById[id] = state.numId;
    _listsByStyle[state.styleName] = state.numId;

    for (final item in element.childElements) {
      final header = item.isOdf(_text, 'list-header');
      if (!header && !item.isOdf(_text, 'list-item')) continue;
      final start = header ? null : _startOf(item);
      if (start != null &&
          level <= 8 &&
          !(startsHere && identical(item, firstItem))) {
        // The numbering starts again at this item.
        state = _ListState(
          state.styleName,
          _addList(_withStart(state.spec, level, start)),
          state.spec,
        );
        if (!inherited) {
          if (id != null) _listsById[id] = state.numId;
          _listsByStyle[state.styleName] = state.numId;
        }
      }
      var numbered = !header;
      for (final child in item.childElements) {
        if (child.isOdf(_text, 'p') || child.isOdf(_text, 'h')) {
          _paragraph(
            child,
            out,
            context,
            list: numbered ? ListRef(state.numId, math.min(level, 8)) : null,
            indent: numbered ? null : _levelIndent(state.spec, level),
          );
          numbered = false;
        } else if (child.isOdf(_text, 'list')) {
          _list(child, out, context, level: level + 1, parent: state);
          numbered = false;
        } else {
          _block(child, out, context);
        }
      }
    }
  }

  String? _firstListStyle(XmlElement list, _Context context) {
    for (final item in list.childElements) {
      for (final child in item.childElements) {
        if (child.isOdf(_text, 'p') || child.isOdf(_text, 'h')) {
          return _paragraphStyle(
            context.scope,
            child.odfAttribute(_text, 'style-name'),
          ).listStyle;
        }
      }
    }
    return null;
  }

  static int? _startOf(XmlElement? item) =>
      int.tryParse(item?.odfAttribute(_text, 'start-value') ?? '');

  static ListSpec _withStart(ListSpec spec, int level, int? start) =>
      start == null || level > 8 ? spec : _startingAt(spec, {level: start});

  /// [spec] with the levels in [starts] counting from other numbers.
  static ListSpec _startingAt(ListSpec spec, Map<int, int> starts) => ListSpec([
    for (final (index, definition) in spec.levels.indexed)
      switch (starts[index]) {
        final start? when start != definition.start => ListLevelSpec(
          format: definition.format,
          text: definition.text,
          start: start.clamp(0, 32767),
          indentLeft: definition.indentLeft,
          hanging: definition.hanging,
          font: definition.font,
        ),
        _ => definition,
      },
  ]);

  static double _levelIndent(ListSpec spec, int level) {
    final index = math.min(level, spec.levels.length - 1);
    return spec.levels[index].indentLeft ?? 36.0 * (index + 1);
  }

  ListSpec _listSpec(StyleScope scope, String? name) =>
      _listSpecs[(scope, name)] ??= switch (_styles.listStyle(scope, name)) {
        final XmlElement style => OdtStyles.listSpecOf(style),
        null => ListSpec.bullets(),
      };

  int _addList(ListSpec list) {
    if (++_lists > _maxLists) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
    return _spec.addList(list);
  }

  void _numberedParagraph(
    XmlElement element,
    List<BlockSpec> out,
    _Context context,
  ) {
    final level =
        ((int.tryParse(element.odfAttribute(_text, 'level') ?? '') ?? 1) - 1)
            .clamp(0, 8);
    final id = element.odfAttribute(_text, 'list-id');
    final numId =
        (id == null ? null : _listsById[id]) ??
        _addList(
          _listSpec(context.scope, element.odfAttribute(_text, 'style-name')),
        );
    if (id != null) _listsById[id] = numId;
    for (final child in element.childElements) {
      if (child.isOdf(_text, 'p') || child.isOdf(_text, 'h')) {
        _paragraph(child, out, context, list: ListRef(numId, level));
      }
    }
  }

  // Tables

  void _readTable(XmlElement element, List<BlockSpec> out, _Context context) {
    if (context.tables >= _maxTableDepth) {
      throw DocumentProblemException(DocumentProblem.damaged);
    }
    final style = _styles.find(
      context.scope,
      'table',
      element.odfAttribute(_table, 'style-name'),
    );
    final properties = style?.properties('table');
    if (context.place == _Place.body &&
        _beforeBodyBlock(
          out,
          _nonEmpty(style?.masterPageName),
          OdtStyles.breaksOf(properties),
        )) {
      // A page break, as in LibreOffice: a new section would show the first
      // page's header again.
      _charge(4 * _elementCost);
      out.add(const ParagraphSpec([BreakSpec(BreakKind.page)]));
    }
    final reader = _TableReader(
      this,
      _Context(context.scope, _Place.cell, context.tables + 1),
    )..read(element);
    if (reader.rows.isEmpty) return;
    final indent = odfLength(properties?.odfAttribute(_fo, 'margin-left'));
    out.add(
      TableSpec(
        reader.rows,
        columnWidths: _columnWidths(element, context.scope, properties),
        bordered: reader.bordered,
        indent: indent != null && indent > 0 ? indent : null,
      ),
    );
  }

  List<double>? _columnWidths(
    XmlElement table,
    StyleScope scope,
    XmlElement? tableProperties,
  ) {
    final absolute = <double?>[];
    final relative = <double?>[];
    void read(XmlElement parent) {
      for (final child in parent.childElements) {
        if (child.isOdf(_table, 'table-column')) {
          final properties = _styles
              .find(
                scope,
                'table-column',
                child.odfAttribute(_table, 'style-name'),
              )
              ?.properties('table-column');
          final width = _positive(
            odfLength(properties?.odfAttribute(_style, 'column-width')),
          );
          final share = _positive(
            double.tryParse(
              (properties?.odfAttribute(_style, 'rel-column-width') ?? '')
                  .replaceAll('*', '')
                  .trim(),
            ),
          );
          final repeat = _repeat(
            child.odfAttribute(_table, 'number-columns-repeated'),
          );
          for (var copy = 0; copy < repeat; copy++) {
            if (absolute.length > _maxColumns) return;
            absolute.add(width);
            relative.add(share);
          }
        } else if (child.isOdf(_table, 'table-columns') ||
            child.isOdf(_table, 'table-header-columns') ||
            child.isOdf(_table, 'table-column-group')) {
          read(child);
        }
      }
    }

    read(table);
    if (absolute.isEmpty || absolute.length > _maxColumns) return null;
    if (absolute.every((width) => width != null)) {
      return absolute.cast<double>();
    }
    if (relative.every((share) => share != null)) {
      final total = relative.fold<double>(0, (sum, share) => sum + share!);
      final width =
          _positive(
            odfLength(tableProperties?.odfAttribute(_style, 'width')),
          ) ??
          _page(_master).textWidth;
      return [for (final share in relative) share! / total * width];
    }
    return null;
  }

  void _countCells(int count) {
    _cells += count;
    if (_cells > _maxCells) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
  }

  // Pictures

  _Picture? _picture(XmlElement image) {
    final href = image.odfAttribute(_xlink, 'href')?.trim();
    Uint8List? bytes;
    if (href != null && href.isNotEmpty) {
      bytes = package.picture(href);
    } else if (image.odfChild(_office, 'binary-data') case final data?) {
      try {
        bytes = base64Decode(data.innerText.replaceAll(RegExp(r'\s+'), ''));
      } on FormatException {
        bytes = null;
      }
    }
    if (bytes == null || bytes.isEmpty) return null;
    final mime = _imageType(bytes);
    if (mime == null || !buildableImageTypes.contains(mime)) return null;
    return (bytes: bytes, mime: mime);
  }

  /// By the content, which says more than names and declared types.
  static String? _imageType(Uint8List bytes) {
    bool startsWith(List<int> prefix) {
      if (bytes.length < prefix.length) return false;
      for (var index = 0; index < prefix.length; index++) {
        if (bytes[index] != prefix[index]) return false;
      }
      return true;
    }

    if (startsWith(const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
    if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
    if (startsWith(const [0x42, 0x4D]) && bytes.length > 26) {
      return 'image/bmp';
    }
    if (startsWith(const [0x49, 0x49, 0x2A, 0x00]) ||
        startsWith(const [0x4D, 0x4D, 0x00, 0x2A])) {
      return 'image/tiff';
    }
    if (startsWith(const [0xD7, 0xCD, 0xC6, 0x9A]) ||
        startsWith(const [0x01, 0x00, 0x09, 0x00]) ||
        startsWith(const [0x02, 0x00, 0x09, 0x00])) {
      return 'image/x-wmf';
    }
    if (bytes.length > 44 &&
        startsWith(const [0x01, 0x00, 0x00, 0x00]) &&
        bytes[40] == 0x20 &&
        bytes[41] == 0x45 &&
        bytes[42] == 0x4D &&
        bytes[43] == 0x46) {
      return 'image/x-emf';
    }
    return null;
  }

  /// `fo:clip` of a frame's graphic style.
  String? _clipOf(StyleScope scope, XmlElement frame) {
    String? clip;
    for (final style in _styles.chain(
      scope,
      'graphic',
      frame.odfAttribute(_draw, 'style-name'),
    )) {
      clip = style.properties('graphic')?.odfAttribute(_fo, 'clip') ?? clip;
    }
    return clip;
  }

  /// What the frame shows of [picture], sized within [width] by [height]
  /// without stretching it.
  ({Uint8List bytes, String mime, double? width, double? height}) _framed(
    _Picture picture,
    String? clip,
    double? width,
    double? height,
  ) {
    final sides = _clipSides(clip);
    if (sides == null) {
      return (
        bytes: picture.bytes,
        mime: picture.mime,
        width: width,
        height: height,
      );
    }
    final cut = _cutOf(picture.bytes, sides);
    final cropped = cut == null ? null : _crop(picture, cut);
    // Left whole, it shows what the crop hid.
    if (cropped == null) notices.add(DocumentNotice.contentNotImported);
    final shown = cropped ?? picture;
    final size = _fit(shown.bytes, width, height);
    return (
      bytes: shown.bytes,
      mime: shown.mime,
      width: size.width,
      height: size.height,
    );
  }

  _Picture? _crop(_Picture picture, _Cut cut) {
    final key = (picture.bytes, cut.left, cut.top, cut.right, cut.bottom);
    if (_crops.containsKey(key)) return _crops[key];
    final pixels = imagePixelSize(picture.bytes);
    if (pixels == null) return null;
    final work = pixels.width.toDouble() * pixels.height;
    if (_cropPixels + work > _maxCropPixels) return null;
    _cropPixels += work;
    return _crops[key] = cropPicture(
      picture.bytes,
      picture.mime,
      left: cut.left,
      top: cut.top,
      right: cut.right,
      bottom: cut.bottom,
    );
  }

  /// `rect(top, right, bottom, left)` in points; null when it cuts nothing.
  static List<double>? _clipSides(String? clip) {
    final match = RegExp(r'^\s*rect\s*\((.*)\)\s*$').firstMatch(clip ?? '');
    if (match == null) return null;
    final sides = [
      for (final side in match[1]!.trim().split(RegExp(r'[\s,]+')))
        side == 'auto' ? 0.0 : odfLength(side),
    ];
    if (sides.length != 4 ||
        sides.any((side) => side == null) ||
        sides.every((side) => side! <= 0)) {
      return null;
    }
    return sides.cast<double>();
  }

  /// The clip is measured on the picture at its own resolution, 96 dpi when
  /// the file has none, as LibreOffice does.
  static _Cut? _cutOf(Uint8List bytes, List<double> sides) {
    final pixels = imagePixelSize(bytes);
    if (pixels == null || pixels.width <= 0 || pixels.height <= 0) return null;
    final dpi = _resolution(bytes) ?? (x: 96.0, y: 96.0);
    final width = pixels.width * 72 / dpi.x;
    final height = pixels.height * 72 / dpi.y;
    return (
      top: sides[0] / height,
      right: sides[1] / width,
      bottom: sides[2] / height,
      left: sides[3] / width,
    );
  }

  /// Dots per inch a PNG (pHYs) or JPEG (JFIF) file gives.
  static ({double x, double y})? _resolution(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    ({double x, double y})? valid(double x, double y) =>
        x >= 1 && y >= 1 && x <= 100000 && y <= 100000 ? (x: x, y: y) : null;
    if (bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50) {
      for (var offset = 8; offset + 8 <= bytes.length;) {
        final length = data.getUint32(offset);
        final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
        if (type == 'IDAT') return null;
        if (type == 'pHYs' && length >= 9 && offset + 17 <= bytes.length) {
          // Only a unit of metres says how large the dots are.
          if (bytes[offset + 16] != 1) return null;
          return valid(
            data.getUint32(offset + 8) * 0.0254,
            data.getUint32(offset + 12) * 0.0254,
          );
        }
        offset += 12 + length;
      }
      return null;
    }
    if (bytes.length > 17 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF &&
        bytes[3] == 0xE0 &&
        String.fromCharCodes(bytes, 6, 11) == 'JFIF\u0000') {
      final x = data.getUint16(14).toDouble();
      final y = data.getUint16(16).toDouble();
      return switch (bytes[13]) {
        1 => valid(x, y),
        2 => valid(x * 2.54, y * 2.54),
        _ => null,
      };
    }
    return null;
  }

  /// The largest size within [width] by [height] with the picture's
  /// proportions.
  static ({double? width, double? height}) _fit(
    Uint8List bytes,
    double? width,
    double? height,
  ) {
    final shape = _shape(bytes);
    if (width == null ||
        height == null ||
        shape == null ||
        shape.width <= 0 ||
        shape.height <= 0) {
      return (width: width, height: height);
    }
    final scale = math.min(width / shape.width, height / shape.height);
    return (width: shape.width * scale, height: shape.height * scale);
  }

  /// A picture's pixels, or the frame a metafile is drawn in.
  static ({double width, double height})? _shape(Uint8List bytes) {
    if (imagePixelSize(bytes) case final pixels?) {
      return (width: pixels.width.toDouble(), height: pixels.height.toDouble());
    }
    final data = ByteData.sublistView(bytes);
    int at(int offset) => data.getInt32(offset, Endian.little);
    int short(int offset) => data.getInt16(offset, Endian.little);
    if (_imageType(bytes) == 'image/x-emf') {
      return (
        width: (at(32) - at(24)).toDouble(),
        height: (at(36) - at(28)).toDouble(),
      );
    }
    if (bytes.length > 14 && data.getUint32(0, Endian.little) == 0x9AC6CDD7) {
      return (
        width: (short(10) - short(6)).toDouble(),
        height: (short(12) - short(8)).toDouble(),
      );
    }
    return null;
  }

  // Page setup, headers and footers

  /// The page style used on most pages, and the one of the first page when
  /// it hands over to another (LibreOffice's "First Page").
  ({XmlElement? main, XmlElement? first}) _masters(String? name) {
    final master = name == null ? null : _styles.masterPages[name];
    if (master == null) return (main: null, first: null);
    final nextName = master.odfAttribute(_style, 'next-style-name');
    final next = nextName == null || nextName == name
        ? null
        : _styles.masterPages[nextName];
    return next == null
        ? (main: master, first: null)
        : (main: next, first: master);
  }

  static XmlElement? _part(XmlElement? master, String local) {
    if (master == null) return null;
    for (final child in master.childElements) {
      final namespace = child.name.namespaceUri;
      if (child.name.local == local &&
          (namespace == _style || namespace == _loext)) {
        return child.odfAttribute(_style, 'display') == 'false' ? null : child;
      }
    }
    return null;
  }

  /// The headers (or footers) of a page style, for every kind of page.
  static Iterable<XmlElement> _parts(
    ({XmlElement? main, XmlElement? first}) masters,
    String kind,
  ) => [
    _part(masters.main, kind),
    _part(masters.main, '$kind-left'),
    _part(masters.main, '$kind-first'),
    _part(masters.first, kind),
  ].nonNulls;

  bool _hasPart(({XmlElement? main, XmlElement? first}) masters, String kind) =>
      _parts(masters, kind).isNotEmpty;

  PageSpec _page(String? master) => _pages[master] ??= _readPage(master);

  PageSpec _readPage(String? name) {
    final masters = _masters(name);
    final layout = _styles
        .pageLayouts[masters.main?.odfAttribute(_style, 'page-layout-name')];
    final properties = layout?.odfChild(_style, 'page-layout-properties');
    const defaults = PageSpec();
    String? attribute(String local) => properties?.odfAttribute(_fo, local);

    var width =
        (_positive(odfLength(attribute('page-width'))) ?? defaults.width).clamp(
          72.0,
          3168.0,
        );
    var height =
        (_positive(odfLength(attribute('page-height'))) ?? defaults.height)
            .clamp(72.0, 3168.0);
    final orientation = properties?.odfAttribute(_style, 'print-orientation');
    if (orientation == 'landscape' && width < height ||
        orientation == 'portrait' && width > height) {
      (width, height) = (height, width);
    }
    final margin = odfLength(attribute('margin'));
    double side(String local, double fallback, double size) =>
        (odfLength(attribute(local)) ?? margin ?? fallback).clamp(
          0.0,
          size / 2 - 18,
        );
    final left = side('margin-left', defaults.margins.left, width);
    final right = side('margin-right', defaults.margins.right, width);
    var top = side('margin-top', defaults.margins.top, height);
    var bottom = side('margin-bottom', defaults.margins.bottom, height);
    var headerDistance = math.min(defaults.headerDistance, top);
    var footerDistance = math.min(defaults.footerDistance, bottom);
    // ODF measures the header from the page edge and the body after it;
    // Word measures both from the edge.
    if (_hasPart(masters, 'header')) {
      headerDistance = top;
      top += _partSpace(layout?.odfChild(_style, 'header-style'), 'bottom');
    }
    if (_hasPart(masters, 'footer')) {
      footerDistance = bottom;
      bottom += _partSpace(layout?.odfChild(_style, 'footer-style'), 'top');
    }
    final columns = properties?.odfChild(_style, 'columns');
    return PageSpec(
      width: width,
      height: height,
      margins: EdgeInsets.fromLTRB(left, top, right, bottom),
      headerDistance: headerDistance,
      footerDistance: footerDistance,
      columns:
          (int.tryParse(columns?.odfAttribute(_fo, 'column-count') ?? '') ?? 1)
              .clamp(1, 45),
      columnSpacing:
          _positive(odfLength(columns?.odfAttribute(_fo, 'column-gap'))) ??
          defaults.columnSpacing,
      numberFormat: switch (properties?.odfAttribute(_style, 'num-format')) {
        'i' => NumberFormat.lowerRoman,
        'I' => NumberFormat.upperRoman,
        'a' => NumberFormat.lowerLetter,
        'A' => NumberFormat.upperLetter,
        '' => NumberFormat.none,
        _ => null,
      },
    );
  }

  /// The `style:num-format` of a page style, which its page count fields
  /// follow.
  String? _pageNumbering(String? master) => _styles
      .pageLayouts[_masters(
        master,
      ).main?.odfAttribute(_style, 'page-layout-name')]
      ?.odfChild(_style, 'page-layout-properties')
      ?.odfAttribute(_style, 'num-format');

  /// Height of a header or footer plus its distance to the body.
  double _partSpace(XmlElement? partStyle, String side) {
    final properties = partStyle?.odfChild(_style, 'header-footer-properties');
    final height =
        _positive(odfLength(properties?.odfAttribute(_fo, 'min-height'))) ??
        _positive(odfLength(properties?.odfAttribute(_svg, 'height'))) ??
        (_baseRun.size ?? 12) * 1.2;
    final spacing = odfLength(properties?.odfAttribute(_fo, 'margin-$side'));
    return math.min(height + math.max(spacing ?? 0, 0), 720);
  }

  /// One set serves the whole document: the last section's, or the nearest
  /// earlier one's when it has none of a kind.
  void _readHeadersFooters() {
    final latestFirst = _sectionMasters.reversed.toSet();
    String? source(String kind) {
      for (final master in latestFirst) {
        if (_hasPart(_masters(master), kind)) return master;
      }
      return null;
    }

    final header = source('header');
    final footer = source('footer');
    for (final (kind, master) in [('header', header), ('footer', footer)]) {
      final kept = {
        for (final part in _parts(_masters(master), kind)) part.innerXml,
      };
      final dropped = _usedMasters.any(
        (used) => _parts(
          _masters(used),
          kind,
        ).any((part) => !kept.contains(part.innerXml)),
      );
      if (dropped) notices.add(DocumentNotice.contentNotImported);
    }

    final headers = _masters(header);
    final footers = _masters(footer);
    bool firstDiffers(
      ({XmlElement? main, XmlElement? first}) masters,
      String kind,
    ) => masters.first != null || _part(masters.main, '$kind-first') != null;
    _spec
      ..differentFirstPage =
          firstDiffers(headers, 'header') || firstDiffers(footers, 'footer')
      ..differentOddEven =
          _part(headers.main, 'header-left') != null ||
          _part(footers.main, 'footer-left') != null;
    for (final (kind, name, masters, stories) in [
      ('header', header, headers, _spec.headers),
      ('footer', footer, footers, _spec.footers),
    ]) {
      final main = masters.main;
      if (main == null) continue;
      // Its fields and tables follow its own page style.
      _master = name;
      final normal = _part(main, kind);
      if (normal != null) stories[PageVariant.normal] = _story(normal);
      if (_spec.differentOddEven) {
        final even = _part(main, '$kind-left') ?? normal;
        if (even != null) stories[PageVariant.even] = _story(even);
      }
      if (_spec.differentFirstPage) {
        final first = masters.first != null
            ? _part(masters.first, kind)
            : _part(main, '$kind-first') ?? normal;
        stories[PageVariant.first] = first == null ? [] : _story(first);
      }
    }
  }

  List<BlockSpec> _story(XmlElement part) {
    final blocks = <BlockSpec>[];
    _blocks(part, blocks, _Context(_styles.master, _Place.header));
    return blocks;
  }
}

/// Heading numbers of the outline style as LibreOffice counts them, and the
/// lists that show the same numbers in Word.
class _Outline {
  _Outline(this.spec, this.name);

  /// Null when the style numbers no level, as LibreOffice's default.
  static _Outline? of(XmlElement? style) {
    if (style == null) return null;
    final spec = OdtStyles.listSpecOf(style);
    return spec.levels.every((level) => level.format == NumberFormat.none)
        ? null
        : _Outline(spec, style.odfAttribute(_style, 'name'));
  }

  final ListSpec spec;

  /// Heading styles may name it as their list.
  final String? name;

  final _counts = List<int?>.filled(9, null);
  final _listCounts = List<int?>.filled(9, null);
  var _listStarts = const <int>[];
  int? _numId;

  /// The number of a heading at [level], from 0; [restart] starts the
  /// level again at that value.
  ListRef number(int level, int? restart, int Function(ListSpec) addList) {
    final starts = [for (final definition in spec.levels) definition.start];
    _counts[level] = restart ?? (_counts[level] ?? starts[level] - 1) + 1;
    _counts.fillRange(level + 1, 9, null);
    final shown = [
      for (var index = 0; index <= level; index++)
        _counts[index] ?? starts[index],
    ];
    // Word's list only counts on, so a restart needs another list.
    var numId = _numId;
    if (numId != null) {
      for (var index = 0; index <= level; index++) {
        final counted = index == level
            ? (_listCounts[index] ?? _listStarts[index] - 1) + 1
            : _listCounts[index] ?? _listStarts[index];
        if (counted != shown[index]) numId = null;
      }
    }
    if (numId == null) {
      _listStarts = [
        for (var index = 0; index < 9; index++)
          index <= level ? shown[index] : starts[index],
      ];
      numId = _numId = addList(
        OdtReader._startingAt(spec, _listStarts.asMap()),
      );
      _listCounts.fillRange(0, 9, null);
    }
    _listCounts[level] = shown[level];
    _listCounts.fillRange(level + 1, 9, null);
    return ListRef(numId, level);
  }
}

/// The rows of a table, with spans and merges on the column grid.
class _TableReader {
  _TableReader(this.reader, this.context);

  final OdtReader reader;

  /// The context of the cells' content.
  final _Context context;
  final rows = <RowSpec>[];
  var bordered = false;
  final _cover = <int, _Cover>{};
  final _contents =
      <XmlElement, ({List<BlockSpec> blocks, int cost, int cells})>{};
  var _row = 0;

  void read(XmlElement parent, {bool header = false}) {
    for (final child in parent.childElements) {
      if (child.isOdf(_table, 'table-row')) {
        final repeat = _repeat(
          child.odfAttribute(_table, 'number-rows-repeated'),
        );
        for (var copy = 0; copy < repeat; copy++) {
          _readRow(child, header);
        }
      } else if (child.isOdf(_table, 'table-header-rows')) {
        read(child, header: true);
      } else if (child.isOdf(_table, 'table-rows') ||
          child.isOdf(_table, 'table-row-group')) {
        read(child, header: header);
      }
    }
  }

  void _readRow(XmlElement row, bool header) {
    final index = _row++;
    final cells = <CellSpec>[];
    var column = 0;
    var skip = 0;
    for (final element in row.childElements) {
      final covered = element.isOdf(_table, 'covered-table-cell');
      if (!covered && !element.isOdf(_table, 'table-cell')) continue;
      final repeat = _repeat(
        element.odfAttribute(_table, 'number-columns-repeated'),
      );
      for (
        var copy = 0;
        copy < repeat && column < OdtReader._maxColumns;
        copy++, column++
      ) {
        if (covered) {
          if (skip > 0) {
            skip--;
            continue;
          }
          final merge = _cover[column];
          if (merge != null && merge.lastRow >= index) {
            cells.add(
              CellSpec(
                const [],
                span: merge.span,
                merge: CellMerge.continuation,
                background: merge.background,
              ),
            );
            skip = merge.span - 1;
          } else {
            cells.add(const CellSpec([]));
          }
          continue;
        }
        _cover.remove(column);
        final span = _repeat(
          element.odfAttribute(_table, 'number-columns-spanned'),
        ).clamp(1, OdtReader._maxColumns - column);
        final rowSpan = _repeat(
          element.odfAttribute(_table, 'number-rows-spanned'),
        );
        final properties = reader._styles
            .find(
              context.scope,
              'table-cell',
              element.odfAttribute(_table, 'style-name'),
            )
            ?.properties('table-cell');
        if (_hasBorder(properties)) bordered = true;
        final background = odfColor(
          properties?.odfAttribute(_fo, 'background-color'),
        );
        cells.add(
          CellSpec(
            _content(element),
            span: span,
            merge: rowSpan > 1 ? CellMerge.restart : CellMerge.none,
            background: background,
            verticalAlign: switch (properties?.odfAttribute(
              _style,
              'vertical-align',
            )) {
              'top' => CellAlign.top,
              'middle' => CellAlign.center,
              'bottom' => CellAlign.bottom,
              _ => null,
            },
          ),
        );
        if (rowSpan > 1) {
          _cover[column] = (
            lastRow: index + rowSpan - 1,
            span: span,
            background: background,
          );
        }
        skip = span - 1;
      }
    }
    reader._countCells(math.max(cells.length, 1));
    reader._charge(OdtReader._elementCost * (1 + 2 * cells.length));
    if (cells.isEmpty) return;
    final rowProperties = reader._styles
        .find(
          context.scope,
          'table-row',
          row.odfAttribute(_table, 'style-name'),
        )
        ?.properties('table-row');
    rows.add(
      RowSpec(
        cells,
        header: header,
        height: _positive(
          odfLength(
            rowProperties?.odfAttribute(_style, 'min-row-height') ??
                rowProperties?.odfAttribute(_style, 'row-height'),
          ),
        ),
      ),
    );
  }

  /// Read once; repeated cells reuse it and still count everything it holds
  /// toward the limits.
  List<BlockSpec> _content(XmlElement cell) {
    final cached = _contents[cell];
    if (cached != null) {
      reader
        .._charge(cached.cost)
        .._countCells(cached.cells);
      return cached.blocks;
    }
    final output = reader._output;
    final cells = reader._cells;
    final blocks = <BlockSpec>[];
    reader._blocks(cell, blocks, context);
    _contents[cell] = (
      blocks: blocks,
      cost: reader._output - output,
      cells: reader._cells - cells,
    );
    return blocks;
  }

  static bool _hasBorder(XmlElement? properties) {
    if (properties == null) return false;
    for (final local in const [
      'border',
      'border-top',
      'border-bottom',
      'border-left',
      'border-right',
    ]) {
      final value = properties.odfAttribute(_fo, local);
      if (value == null) continue;
      final parts = value.trim().split(RegExp(r'\s+'));
      if (parts.contains('none') || parts.contains('hidden')) continue;
      final width = odfLength(parts.first);
      if (width == null || width > 0) return true;
    }
    return false;
  }
}

/// Letters that continue a word, for capitalized text.
final _wordCharacter = RegExp(r"[\p{L}\p{N}\p{M}'’]", unicode: true);

/// The inline content of one paragraph.
class _Inlines {
  _Inlines(
    this.reader,
    this.context,
    this.floating, {
    required this.paragraphSize,
    TextCase textCase = TextCase.asWritten,
  }) : _case = textCase;

  final OdtReader reader;
  final _Context context;

  /// Content of text boxes, placed after the paragraph.
  final List<BlockSpec> floating;

  /// For font sizes given as percentages.
  final double paragraphSize;

  // ODF collapses white space like HTML, and drops it at the paragraph's
  // start.
  var _space = true;
  var _inLink = false;
  TextCase _case;
  var _inWord = false;
  final _pending = StringBuffer();
  RunFormat? _pendingFormat;
  List<InlineSpec>? _pendingOut;

  void read(XmlElement container, RunFormat format, List<InlineSpec> out) {
    for (final child in container.children) {
      node(child, format, out);
    }
  }

  void flush() {
    final out = _pendingOut;
    if (out != null && _pending.isNotEmpty) {
      reader._charge(
        OdtReader._elementCost + OdtReader._formatCost(_pendingFormat!),
      );
      out.add(TextSpec(_pending.toString(), _pendingFormat!));
    }
    _pending.clear();
    _pendingFormat = null;
    _pendingOut = null;
  }

  void node(XmlNode node, RunFormat format, List<InlineSpec> out) {
    if (node is XmlText || node is XmlCDATA) {
      _characters(node.value ?? '', format, out);
      return;
    }
    if (node is! XmlElement) return;
    final namespace = node.name.namespaceUri;
    final local = node.name.local;
    if (namespace == _text) {
      switch (local) {
        case 'span':
          final (spanFormat, spanCase) = _span(node, format);
          final outer = _case;
          _case = spanCase ?? outer;
          read(node, spanFormat, out);
          _case = outer;
        case 'a':
          _link(node, format, out);
        case 's':
          _emit(
            ' ' * _repeat(node.odfAttribute(_text, 'c')).clamp(1, 1000),
            format,
            out,
          );
          _space = false;
        case 'tab':
          _emit('\t', format, out);
          _space = false;
        case 'line-break':
          _add(const BreakSpec(BreakKind.line), out);
          _inWord = false;
        case 'bookmark' || 'bookmark-start':
          final name = _nonEmpty(node.odfAttribute(_text, 'name'));
          if (name != null) _add(BookmarkSpec(name), out);
        case 'note':
          _note(node, format, out);
        case 'page-number':
          // The section's page numbering gives the format.
          _add(
            FieldSpec(
              _numbered('PAGE', node),
              result: _shown(node),
              format: format,
            ),
            out,
          );
        case 'page-count':
          _add(
            FieldSpec(
              _numbered(
                'NUMPAGES',
                node,
                reader._pageNumbering(reader._master),
              ),
              result: _shown(node),
              format: format,
            ),
            out,
          );
        case 'ruby':
          final base = node.odfChild(_text, 'ruby-base');
          if (base != null) read(base, format, out);
          final annotation = node.odfChild(_text, 'ruby-text');
          if (annotation != null && annotation.innerText.trim().isNotEmpty) {
            // The reading follows its text, as in plain text.
            reader.notices.add(DocumentNotice.contentNotImported);
            _emit('(', format, out);
            read(annotation, format, out);
            _emit(')', format, out);
          }
        case 'hidden-text':
          if (node.odfAttribute(_text, 'is-hidden') == 'true') {
            reader.notices.add(DocumentNotice.contentNotImported);
          } else {
            read(node, format, out);
          }
        case 'soft-page-break' ||
            'bookmark-end' ||
            'change' ||
            'change-start' ||
            'change-end' ||
            'note-citation' ||
            'note-body' ||
            'number' ||
            'script' ||
            'hidden-paragraph' ||
            'tracked-changes':
          return;
        default:
          // Fields and other containers show their text.
          read(node, format, out);
      }
    } else if (namespace == _draw) {
      switch (local) {
        case 'frame':
          _frame(node, format, out);
        case 'a':
          _link(node, format, out);
        default:
          reader.notices.add(DocumentNotice.contentNotImported);
      }
    } else if (namespace == _office) {
      if (local == 'annotation' || local == 'annotation-end') {
        reader.notices.add(DocumentNotice.commentsHidden);
      }
    } else if (namespace == _dr3d) {
      reader.notices.add(DocumentNotice.contentNotImported);
    } else if (namespace != _svg && namespace != _style) {
      read(node, format, out);
    }
  }

  void _characters(String value, RunFormat format, List<InlineSpec> out) {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      if (rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D) {
        if (!_space) buffer.writeCharCode(0x20);
        _space = true;
      } else {
        buffer.writeCharCode(rune);
        _space = false;
      }
    }
    if (buffer.isNotEmpty) _emit(buffer.toString(), format, out);
  }

  /// Word has no lowercase or capitalized runs, so the text changes case.
  void _emit(String text, RunFormat format, List<InlineSpec> out) {
    final shown = switch (_case) {
      TextCase.asWritten => text,
      TextCase.lower => text.toLowerCase(),
      TextCase.capitalized => _capitalized(text),
    };
    if (shown.isNotEmpty) {
      _inWord = _wordCharacter.hasMatch(String.fromCharCode(shown.runes.last));
    }
    reader._charge(shown.length);
    if (!identical(format, _pendingFormat) || !identical(out, _pendingOut)) {
      flush();
      _pendingFormat = format;
      _pendingOut = out;
    }
    _pending.write(shown);
  }

  String _capitalized(String text) {
    final out = StringBuffer();
    var inWord = _inWord;
    for (final rune in text.runes) {
      final character = String.fromCharCode(rune);
      out.write(inWord ? character : character.toUpperCase());
      inWord = _wordCharacter.hasMatch(character);
    }
    return out.toString();
  }

  void _add(InlineSpec inline, List<InlineSpec> out) {
    flush();
    reader._charge(switch (inline) {
      FieldSpec(:final format) =>
        5 * (OdtReader._elementCost + OdtReader._formatCost(format)),
      NoteSpec(:final format) =>
        4 * OdtReader._elementCost + OdtReader._formatCost(format),
      _ => 4 * OdtReader._elementCost,
    });
    out.add(inline);
    if (inline is! BookmarkSpec && inline is! LinkSpec) _space = false;
  }

  /// Character styles keep their name; their formatting is also applied
  /// directly, since spans nest and a Word run has one style.
  (RunFormat, TextCase?) _span(XmlElement span, RunFormat format) {
    final chain = reader._styles.chain(
      context.scope,
      'text',
      span.odfAttribute(_text, 'style-name'),
    );
    var result = format;
    TextCase? textCase;
    OdfStyle? named;
    for (final style in chain) {
      final properties = style.properties('text');
      result = result.merge(
        reader._styles.runOf(
          properties,
          inheritedSize: result.size ?? paragraphSize,
        ),
      );
      textCase = OdtStyles.textCaseOf(properties) ?? textCase;
      if (!style.automatic) named = style;
    }
    final id = named == null ? null : reader._ids[_idKey('text', named.name)];
    return (
      id == null ? result : result.merge(RunFormat(styleId: id)),
      textCase,
    );
  }

  void _link(XmlElement link, RunFormat format, List<InlineSpec> out) {
    if (_inLink) {
      read(link, format, out);
      return;
    }
    final children = <InlineSpec>[];
    _inLink = true;
    read(link, format, children);
    _inLink = false;
    flush();
    if (children.isEmpty) return;
    _add(LinkSpec(link.odfAttribute(_xlink, 'href') ?? '', children), out);
  }

  void _note(XmlElement note, RunFormat format, List<InlineSpec> out) {
    if (context.place == _Place.note || context.place == _Place.header) return;
    final label = note
        .odfChild(_text, 'note-citation')
        ?.odfAttribute(_text, 'label');
    if (_nonEmpty(label) != null) {
      // The note keeps its text but gets a number for its own mark.
      reader.notices.add(DocumentNotice.contentNotImported);
    }
    final blocks = <BlockSpec>[];
    final body = note.odfChild(_text, 'note-body');
    if (body != null) {
      reader._blocks(
        body,
        blocks,
        _Context(context.scope, _Place.note, context.tables),
      );
    }
    _add(
      NoteSpec(
        note.odfAttribute(_text, 'note-class') == 'endnote'
            ? NoteKind.endnote
            : NoteKind.footnote,
        blocks,
        format: format,
      ),
      out,
    );
  }

  /// The field's own number format, or else [pageStyle]'s.
  static String _numbered(
    String field,
    XmlElement element, [
    String? pageStyle,
  ]) => switch (element.odfAttribute(_style, 'num-format') ?? pageStyle) {
    'i' => '$field \\* roman',
    'I' => '$field \\* ROMAN',
    'a' => '$field \\* alphabetic',
    'A' => '$field \\* ALPHABETIC',
    _ => field,
  };

  static String _shown(XmlElement element) {
    final text = element.innerText.trim();
    return text.isEmpty ? '1' : text;
  }

  void _frame(XmlElement frame, RunFormat format, List<InlineSpec> out) {
    final width = _positive(odfLength(frame.odfAttribute(_svg, 'width')));
    final height = _positive(odfLength(frame.odfAttribute(_svg, 'height')));
    final description =
        (frame.odfChild(_svg, 'desc') ?? frame.odfChild(_svg, 'title'))
            ?.innerText
            .trim() ??
        '';
    var placed = false;
    var missing = false;
    for (final child in frame.childElements) {
      if (child.isOdf(_draw, 'image')) {
        if (placed) continue;
        final picture = reader._picture(child);
        if (picture == null) {
          missing = true;
          continue;
        }
        final shown = reader._framed(
          picture,
          reader._clipOf(context.scope, frame),
          width,
          height,
        );
        reader._charge(shown.bytes.length ~/ 8 + OdtReader._pictureCost);
        _add(
          ImageSpec(
            shown.bytes,
            shown.mime,
            width: shown.width,
            height: shown.height,
            description: description,
          ),
          out,
        );
        placed = true;
      } else if (child.isOdf(_draw, 'text-box')) {
        // The box goes; its text and pictures follow the paragraph.
        reader.notices.add(DocumentNotice.contentNotImported);
        reader._blocks(
          child,
          floating,
          _Context(context.scope, _Place.frame, context.tables),
        );
      } else if (child.name.namespaceUri == _draw &&
          const {
            'object',
            'object-ole',
            'applet',
            'plugin',
            'floating-frame',
          }.contains(child.name.local)) {
        reader.notices.add(DocumentNotice.contentNotImported);
      }
    }
    if (!placed && missing) {
      reader.notices.add(DocumentNotice.contentNotImported);
    }
  }
}
