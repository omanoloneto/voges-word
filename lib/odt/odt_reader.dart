import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:xml/xml.dart';

import '../document/document_codec.dart';
import '../document/headers_footers.dart';
import '../docx/docx_builder.dart';
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
const _loext =
    'urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0';

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
    a.columns == b.columns;

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

  /// Characters of text, plus picture bytes / 8, the document may produce,
  /// repeated rows and cells included.
  static const _maxOutput = 64 * 1024 * 1024;

  late final DocumentSpec _spec;
  late final RunFormat _baseRun;
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
  var _lists = 0;
  var _cells = 0;
  var _output = 0;
  var _started = false;
  var _pendingBreak = false;
  var _sections = 0;
  String? _firstMaster;
  String? _master;

  DocumentSpec read() {
    final defaults = _styles.defaultStyle('paragraph');
    final text = defaults?.odfChild(_style, 'text-properties');
    final paragraph = defaults?.odfChild(_style, 'paragraph-properties');
    _baseRun = const RunFormat(
      size: 12,
    ).merge(_styles.runOf(text, inheritedSize: 12));
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

    // One section takes the headers of the page style it started with.
    final master = _sections > 0 ? _master : _firstMaster;
    _spec.page = _page(master);
    _readHeadersFooters(master);
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
    var direct = const ParagraphFormat();
    var directRun = const RunFormat();
    bool? before;
    bool? after;
    String? master;
    int? outline;
    String? list;
    OdfStyle? named;
    for (final style in _styles.chain(scope, 'paragraph', name)) {
      final ownRun = _styles.runOf(
        style.properties('text'),
        inheritedSize: run.size ?? 12,
      );
      final properties = style.properties('paragraph');
      final ownParagraph = _styles.paragraphOf(properties);
      run = run.merge(ownRun);
      paragraph = paragraph.merge(ownParagraph);
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
        case 'section' || 'index-body' || 'index-title':
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
      if (inlines.isNotEmpty) out.add(ParagraphSpec(inlines));
      out.addAll(floating);
    } else if (namespace == _office && local == 'annotation') {
      notices.add(DocumentNotice.commentsHidden);
    }
  }

  void _paragraph(
    XmlElement element,
    List<BlockSpec> out,
    _Context context, {
    ListRef? list,
    double? indent,
  }) {
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
    if (list != null) {
      // The numbering sets the indents and the tab after the number.
      format = _withoutIndents(format, list: list);
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

    final inlines = <InlineSpec>[if (newPage) const BreakSpec(BreakKind.page)];
    final floating = <BlockSpec>[];
    _Inlines(
        this,
        context,
        floating,
        paragraphSize: style.resolvedRun.size ?? 12,
      )
      ..read(element, run, inlines)
      ..flush();
    out
      ..add(ParagraphSpec(inlines, format: format, heading: heading, mark: run))
      ..addAll(floating);
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
      return false;
    }
    if (known != null) {
      final previous = _master;
      _master = known;
      if (_samePage(_page(known), _page(previous))) return true;
      out.add(SectionBreakSpec(_page(previous)));
      _sections++;
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
    final _ListState state;
    if (parent != null && (own == null || own == parent.styleName)) {
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
      state = _ListState(
        styleName,
        continued ?? _addList(_withStart(spec, level, _firstStart(element))),
        spec,
      );
    }
    final id = element.getAttribute('id', namespaceUri: _xml);
    if (id != null) _listsById[id] = state.numId;
    _listsByStyle[state.styleName] = state.numId;

    for (final item in element.childElements) {
      final header = item.isOdf(_text, 'list-header');
      if (!header && !item.isOdf(_text, 'list-item')) continue;
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

  static int? _firstStart(XmlElement list) {
    final item = list.odfChild(_text, 'list-item');
    return int.tryParse(item?.odfAttribute(_text, 'start-value') ?? '');
  }

  static ListSpec _withStart(ListSpec spec, int level, int? start) {
    if (start == null || level > 8) return spec;
    return ListSpec([
      for (final (index, definition) in spec.levels.indexed)
        index == level
            ? ListLevelSpec(
                format: definition.format,
                text: definition.text,
                start: start.clamp(0, 32767),
                indentLeft: definition.indentLeft,
                hanging: definition.hanging,
                font: definition.font,
              )
            : definition,
    ]);
  }

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
      out.add(SectionBreakSpec(_page(_master)));
      _sections++;
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

  ({Uint8List bytes, String mime})? _picture(XmlElement image) {
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

  bool _hasPart(({XmlElement? main, XmlElement? first}) masters, String kind) =>
      _part(masters.main, kind) != null ||
      _part(masters.main, '$kind-left') != null ||
      _part(masters.main, '$kind-first') != null ||
      _part(masters.first, kind) != null;

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
    );
  }

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

  void _readHeadersFooters(String? name) {
    final masters = _masters(name);
    final main = masters.main;
    if (main == null) return;
    _spec
      ..differentFirstPage =
          masters.first != null ||
          _part(main, 'header-first') != null ||
          _part(main, 'footer-first') != null
      ..differentOddEven =
          _part(main, 'header-left') != null ||
          _part(main, 'footer-left') != null;
    for (final (kind, stories) in [
      ('header', _spec.headers),
      ('footer', _spec.footers),
    ]) {
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

/// The rows of a table, with spans and merges on the column grid.
class _TableReader {
  _TableReader(this.reader, this.context);

  final OdtReader reader;

  /// The context of the cells' content.
  final _Context context;
  final rows = <RowSpec>[];
  var bordered = false;
  final _cover = <int, _Cover>{};
  final _contents = <XmlElement, ({List<BlockSpec> blocks, int cost})>{};
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

  /// Read once; repeated cells reuse it and still count toward the limit.
  List<BlockSpec> _content(XmlElement cell) {
    final cached = _contents[cell];
    if (cached != null) {
      reader._charge(cached.cost);
      return cached.blocks;
    }
    final before = reader._output;
    final blocks = <BlockSpec>[];
    reader._blocks(cell, blocks, context);
    reader._charge(1);
    _contents[cell] = (blocks: blocks, cost: reader._output - before);
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

/// The inline content of one paragraph.
class _Inlines {
  _Inlines(
    this.reader,
    this.context,
    this.floating, {
    required this.paragraphSize,
  });

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
          read(node, _span(node, format), out);
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
        case 'bookmark' || 'bookmark-start':
          final name = _nonEmpty(node.odfAttribute(_text, 'name'));
          if (name != null) _add(BookmarkSpec(name), out);
        case 'note':
          _note(node, format, out);
        case 'page-number':
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
              _numbered('NUMPAGES', node),
              result: _shown(node),
              format: format,
            ),
            out,
          );
        case 'ruby':
          final base = node.odfChild(_text, 'ruby-base');
          if (base != null) read(base, format, out);
        case 'soft-page-break' ||
            'bookmark-end' ||
            'change' ||
            'change-start' ||
            'change-end' ||
            'note-citation' ||
            'note-body' ||
            'script' ||
            'hidden-text' ||
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

  void _emit(String text, RunFormat format, List<InlineSpec> out) {
    reader._charge(text.length);
    if (!identical(format, _pendingFormat) || !identical(out, _pendingOut)) {
      flush();
      _pendingFormat = format;
      _pendingOut = out;
    }
    _pending.write(text);
  }

  void _add(InlineSpec inline, List<InlineSpec> out) {
    flush();
    out.add(inline);
    if (inline is! BookmarkSpec && inline is! LinkSpec) _space = false;
  }

  /// Character styles keep their name; their formatting is also applied
  /// directly, since spans nest and a Word run has one style.
  RunFormat _span(XmlElement span, RunFormat format) {
    final chain = reader._styles.chain(
      context.scope,
      'text',
      span.odfAttribute(_text, 'style-name'),
    );
    var result = format;
    OdfStyle? named;
    for (final style in chain) {
      result = result.merge(
        reader._styles.runOf(
          style.properties('text'),
          inheritedSize: result.size ?? paragraphSize,
        ),
      );
      if (!style.automatic) named = style;
    }
    final id = named == null ? null : reader._ids[_idKey('text', named.name)];
    return id == null ? result : result.merge(RunFormat(styleId: id));
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

  static String _numbered(String field, XmlElement element) =>
      switch (element.odfAttribute(_style, 'num-format')) {
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
        reader._charge(picture.bytes.length ~/ 8 + 1);
        _add(
          ImageSpec(
            picture.bytes,
            picture.mime,
            width: width,
            height: height,
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
