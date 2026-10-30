import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:xml/xml.dart';

import '../document/document_codec.dart';
import '../document/document_look.dart';
import '../document/embeds.dart';
import '../document/headers_footers.dart';
import '../document/tables.dart';
import 'docx_numbering.dart';
import 'docx_package.dart';
import 'docx_styles.dart';
import 'image_formats.dart';
import 'word_xml.dart';

class DocxReader {
  DocxReader(this.package, this.tables);

  final DocxPackage package;
  final TableStore tables;

  /// Each picture's data URI, made once however often the picture appears.
  final _pictures = <String, String>{};

  LoadedDocument read() {
    final path = package.mainDocumentPath;
    final document = package.xml(path)!;
    final root = document.rootElement;
    final x = WordXml(root);
    final body = x.child(root, 'body');
    if (body == null) {
      throw DocumentProblemException(DocumentProblem.damaged);
    }

    final relationships = package.relationships(path);
    String? partOf(String type) {
      for (final relationship in relationships) {
        if (relationship.hasType(type)) {
          return DocxPackage.resolve(path, relationship.target);
        }
      }
      return null;
    }

    final styles = DocxStyles.parse(
      _xmlOf(partOf('styles')),
      _xmlOf(partOf('theme')),
    );
    final context = _ReadContext(
      package: package,
      documentPath: path,
      x: x,
      styles: styles,
      numbering: DocxNumbering.parse(_xmlOf(partOf('numbering'))),
      relationships: {for (final r in relationships) r.id: r},
      tables: tables,
      pictures: _pictures,
    );

    final delta = _DeltaBuilder();
    _BlockReader(context, delta).read(body.childElements);
    delta.endWithNewline();

    final section = x.child(body, 'sectPr');
    final firstSection = x
        .children(body, 'p')
        .map((paragraph) => x.child(x.child(paragraph, 'pPr'), 'sectPr'))
        .nonNulls
        .firstOrNull;
    return LoadedDocument(
      delta: delta.build(),
      look: _look(styles, x, section),
      source: package,
      notices: context.notices.toList(),
      headersFooters: _headersFooters(
        context,
        section,
        firstSection ?? section,
        _xmlOf(partOf('settings')),
      ),
    );
  }

  HeadersFooters _headersFooters(
    _ReadContext main,
    XmlElement? section,
    XmlElement? firstSection,
    XmlDocument? settings,
  ) {
    final x = main.x;
    Map<PageVariant, HeaderFooterStory> read(String reference) {
      Map<PageVariant, String?> ids(XmlElement? section) => {
        if (section != null)
          for (final element in x.children(section, reference))
            switch (x.attr(element, 'type')) {
              'first' => PageVariant.first,
              'even' => PageVariant.even,
              _ => PageVariant.normal,
            }: x.relAttr(
              element,
              'id',
            ),
      };
      final last = ids(section);
      // DocxBuilder repeats the normal story as a later section's first-page
      // one; the document's first page is then the first section's.
      if (last[PageVariant.first] != null &&
          last[PageVariant.first] == last[PageVariant.normal]) {
        last[PageVariant.first] = ids(firstSection)[PageVariant.first];
      }
      return {
        for (final MapEntry(key: variant, value: id) in last.entries)
          variant: ?_story(main, id),
      };
    }

    double distance(String name) =>
        (double.tryParse(x.attr(x.child(section, 'pgMar'), name) ?? '') ??
            708) /
        20;

    final settingsRoot = settings?.rootElement;
    return HeadersFooters(
      headers: read('headerReference'),
      footers: read('footerReference'),
      differentFirstPage: x.onOff(x.child(section, 'titlePg')) ?? false,
      differentOddEven:
          settingsRoot != null &&
          (WordXml(settingsRoot).onOff(
                WordXml(settingsRoot).child(settingsRoot, 'evenAndOddHeaders'),
              ) ??
              false),
      headerDistance: distance('header'),
      footerDistance: distance('footer'),
    );
  }

  HeaderFooterStory? _story(_ReadContext main, String? relationshipId) {
    final relationship = main.relationships[relationshipId];
    if (relationship == null || relationship.external) return null;
    final path = DocxPackage.resolve(main.documentPath, relationship.target);
    final root = package.xml(path)?.rootElement;
    if (root == null) return null;
    final context = _ReadContext(
      package: package,
      documentPath: path,
      x: WordXml(root),
      styles: main.styles,
      numbering: main.numbering,
      relationships: {for (final r in package.relationships(path)) r.id: r},
      tables: tables,
      pictures: _pictures,
    );
    final delta = _DeltaBuilder();
    _BlockReader(context, delta).read(root.childElements);
    delta.endWithNewline();
    main.notices.addAll(context.notices);
    return HeaderFooterStory(delta: delta.build(), partPath: path);
  }

  /// The footnotes or endnotes ([kind] is `footnote` or `endnote`) by id,
  /// read like the body, without the reference mark that starts each one.
  Map<String, Delta> notes(String kind) {
    final main = package.mainDocumentPath;
    final relationships = package.relationships(main);
    String? partOf(String type) {
      for (final relationship in relationships) {
        if (relationship.hasType(type) && !relationship.external) {
          return DocxPackage.resolve(main, relationship.target);
        }
      }
      return null;
    }

    final path = partOf('${kind}s');
    final root = path == null ? null : package.xml(path)?.rootElement;
    if (path == null || root == null) return const {};
    final x = WordXml(root);
    final context = _ReadContext(
      package: package,
      documentPath: path,
      x: x,
      styles: DocxStyles.parse(
        _xmlOf(partOf('styles')),
        _xmlOf(partOf('theme')),
      ),
      numbering: DocxNumbering.parse(_xmlOf(partOf('numbering'))),
      relationships: {for (final r in package.relationships(path)) r.id: r},
      tables: tables,
      pictures: _pictures,
    );
    final notes = <String, Delta>{};
    for (final note in root.childElements) {
      final id = x.attr(note, 'id');
      if (!x.isW(note, kind) || id == null) continue;
      final delta = _DeltaBuilder();
      _BlockReader(context, delta).read(note.childElements);
      notes[id] = _withoutNoteMark(delta.build());
    }
    return notes;
  }

  static Delta _withoutNoteMark(Delta delta) {
    final out = _DeltaBuilder();
    var leading = true;
    var marked = false;
    for (final op in delta.operations) {
      final data = op.data;
      if (leading && data is Map) {
        final value = data[EmbedTypes.opaqueInline];
        if (!marked &&
            value != null &&
            RegExp(
              r'<w:(footnoteRef|endnoteRef)\b',
            ).hasMatch(OpaqueContent.decode(value).xml)) {
          marked = true;
          continue;
        }
      }
      if (leading && marked && data is String) {
        final trimmed = data.replaceFirst(RegExp(r'^[ \t]+'), '');
        if (trimmed.isEmpty) continue;
        out.insert(trimmed, op.attributes);
        leading = false;
        continue;
      }
      leading = false;
      out.push(op);
    }
    out.endWithNewline();
    return out.build();
  }

  XmlDocument? _xmlOf(String? path) => path == null ? null : package.xml(path);

  static DocumentLook _look(DocxStyles styles, WordXml x, XmlElement? section) {
    TextLook lookOf(RunProps run, ParagraphProps paragraph) => TextLook(
      fontSize: run.size,
      fontFamily: run.font,
      color: colorFromHex(run.color) ?? const Color(0xFF000000),
      bold: run.bold,
      italic: run.italic,
      spaceBefore: paragraph.spaceBefore,
      spaceAfter: paragraph.spaceAfter,
      indentRight: paragraph.indentRight / 20,
      firstLine: paragraph.firstLine / 20,
    );

    final normal = styles.paragraphProps(null);
    final headings = <int, TextLook>{};
    for (var level = 1; level <= 6; level++) {
      final id = styles.headingStyleId(level);
      if (id != null) {
        headings[level] = lookOf(
          styles.runProps(id),
          styles.paragraphProps(id),
        );
      }
    }

    double twips(XmlElement? element, String name, double fallback) {
      final value = double.tryParse(x.attr(element, name) ?? '');
      return value == null ? fallback : value / 20;
    }

    const defaults = DocumentLook();
    final size = x.child(section, 'pgSz');
    final margins = x.child(section, 'pgMar');
    return DocumentLook(
      pageWidth: twips(size, 'w', defaults.pageWidth),
      pageHeight: twips(size, 'h', defaults.pageHeight),
      margins: EdgeInsets.fromLTRB(
        twips(margins, 'left', defaults.margins.left),
        twips(margins, 'top', defaults.margins.top),
        twips(margins, 'right', defaults.margins.right),
        twips(margins, 'bottom', defaults.margins.bottom),
      ),
      body: lookOf(styles.runProps(null), normal),
      headings: headings,
      lineSpacing: normal.exactLineSpacing ? 1 : normal.lineSpacing,
    );
  }
}

Color? colorFromHex(String? hex) =>
    hex == null ? null : Color(int.parse('FF$hex', radix: 16));

String formatPoints(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();

class _ReadContext {
  _ReadContext({
    required this.package,
    required this.documentPath,
    required this.x,
    required this.styles,
    required this.numbering,
    required this.relationships,
    required this.tables,
    required this.pictures,
  }) : normalRun = styles.runProps(null),
       normalParagraph = styles.paragraphProps(null),
       listParagraphStyleId = styles.idByName('List Paragraph');

  final DocxPackage package;
  final String documentPath;
  final WordXml x;
  final DocxStyles styles;
  final DocxNumbering numbering;
  final Map<String, Relationship> relationships;
  final TableStore tables;
  final Map<String, String> pictures;
  final RunProps normalRun;
  final ParagraphProps normalParagraph;
  final String? listParagraphStyleId;
  final notices = <DocumentNotice>{};
  var footnotes = 0;

  String textOf(XmlElement element) {
    final buffer = StringBuffer();
    void walk(XmlElement node) {
      for (final child in node.childElements) {
        if (x.isW(child, 't')) {
          buffer.write(child.innerText);
        } else if (x.isW(child, 'tab')) {
          buffer.write('\t');
        } else if (x.isW(child, 'delText') || x.isW(child, 'instrText')) {
          continue;
        } else if (child.name.local == 'Fallback') {
          continue;
        } else {
          walk(child);
          if (x.isW(child, 'p') && buffer.isNotEmpty) buffer.write('\n');
        }
      }
    }

    walk(element);
    return buffer.toString().trimRight();
  }
}

const _changeMarkers = {
  'ins',
  'del',
  'moveFrom',
  'moveTo',
  'rPrChange',
  'pPrChange',
};
const _ignoredMarkers = {
  'bookmarkEnd',
  'proofErr',
  'permStart',
  'permEnd',
  'commentRangeStart',
  'commentRangeEnd',
  'moveFromRangeStart',
  'moveFromRangeEnd',
  'moveToRangeStart',
  'moveToRangeEnd',
  'customXmlInsRangeStart',
  'customXmlInsRangeEnd',
  'customXmlDelRangeStart',
  'customXmlDelRangeEnd',
  'lastRenderedPageBreak',
};

class _BlockReader {
  _BlockReader(this.c, this.delta);

  final _ReadContext c;
  final _DeltaBuilder delta;
  final _pendingBookmarks = <String>[];

  WordXml get x => c.x;

  void read(Iterable<XmlElement> elements) {
    for (final element in elements) {
      if (x.isW(element, 'p')) {
        _paragraph(element);
      } else if (x.isW(element, 'tbl')) {
        _table(element);
      } else if (x.isW(element, 'sdt')) {
        _structuredBlock(element);
      } else if (x.isW(element, 'customXml') ||
          x.isW(element, 'ins') ||
          x.isW(element, 'moveTo')) {
        if (!x.isW(element, 'customXml')) _noteTrackedChanges();
        read(element.childElements);
      } else if (x.isW(element, 'del') || x.isW(element, 'moveFrom')) {
        _noteTrackedChanges();
      } else if (x.isW(element, 'bookmarkStart')) {
        final name = x.attr(element, 'name');
        if (name != null) _pendingBookmarks.add(name);
      } else if (x.isW(element, 'sectPr') ||
          x.isW(element, 'tcPr') ||
          _ignoredMarkers.contains(element.name.local)) {
        continue;
      } else {
        _opaqueBlock(element, label: OpaqueLabels.special);
      }
    }
  }

  void _noteTrackedChanges() =>
      c.notices.add(DocumentNotice.trackedChangesAccepted);

  void _paragraph(XmlElement paragraph) {
    final pPr = x.child(paragraph, 'pPr');
    final styleId =
        x.childVal(pPr, 'pStyle') ?? c.styles.defaultParagraphStyleId;
    final level = c.styles.headingLevel(styleId);
    final header = level != null && level <= 6 ? level : null;
    final props = c.styles.paragraphProps(styleId).merge(pPr, x);
    final numId = props.numId;
    final list = numId == null || numId == 0
        ? null
        : c.numbering.kind(numId, props.level);

    final inline = _InlineReader(
      c,
      delta,
      paragraphStyleId: styleId,
      baseline: header != null ? c.styles.runProps(styleId) : c.normalRun,
    )..readParagraph(paragraph);

    final bookmarks = [..._pendingBookmarks, ...inline.bookmarks];
    _pendingBookmarks.clear();
    final indentLevel = list != null
        ? props.level
        : (props.indentLeft / 720).round();
    final base = header != null
        ? c.styles.paragraphProps(styleId)
        : c.normalParagraph;
    bool differs(double a, double b) => (a - b).abs() > 0.05;
    final attributes = <String, dynamic>{
      'header': ?header,
      if (list != null) 'list': list.name,
      if (indentLevel > 0) 'indent': math.min(indentLevel, 8),
      if (props.align != 'left') 'align': props.align,
      if (!props.exactLineSpacing &&
          (props.lineSpacing - c.normalParagraph.lineSpacing).abs() > 0.01)
        'line-height': (props.lineSpacing * 100).round() / 100,
      if (list != null) HiddenAttributes.numbering: numId,
      if (list == null) ...{
        if (differs(props.spaceBefore, base.spaceBefore))
          HiddenAttributes.spaceBefore: props.spaceBefore,
        if (differs(props.spaceAfter, base.spaceAfter))
          HiddenAttributes.spaceAfter: props.spaceAfter,
        if (differs(props.indentRight, base.indentRight))
          HiddenAttributes.indentRight: props.indentRight / 20,
        if (differs(props.firstLine, base.firstLine))
          HiddenAttributes.firstLine: props.firstLine / 20,
        if (props.contextualSpacing)
          HiddenAttributes.contextualGroup: styleId ?? '',
      },
      if (bookmarks.isNotEmpty)
        HiddenAttributes.bookmarks: jsonEncode(bookmarks),
    };
    final preserved = _preservedParagraphProperties(
      pPr,
      dropStyle:
          header != null ||
          (list != null && x.childVal(pPr, 'pStyle') == c.listParagraphStyleId),
      isList: list != null,
      exactSpacing: props.exactLineSpacing,
    );
    if (preserved != null) {
      attributes[HiddenAttributes.paragraphProperties] = preserved;
    }
    delta.insert('\n', attributes.isEmpty ? null : attributes);

    final section = x.child(pPr, 'sectPr');
    if (section != null) {
      delta
        ..insert({
          EmbedTypes.sectionBreak: encodeSection(section.toXmlString()),
        })
        ..insert('\n');
    }
  }

  String? _preservedParagraphProperties(
    XmlElement? pPr, {
    required bool dropStyle,
    required bool isList,
    required bool exactSpacing,
  }) {
    if (pPr == null) return null;
    final copy = pPr.copy();
    final removed = <XmlElement>[];
    for (final element in copy.childElements) {
      final name = element.name.local;
      final drop = switch (name) {
        'pStyle' => dropStyle,
        'numPr' || 'ind' => isList,
        'jc' || 'sectPr' => true,
        _ => _changeMarkers.contains(name),
      };
      if (drop) {
        removed.add(element);
      } else if (name == 'spacing' && !exactSpacing) {
        element.attributes.removeWhere(
          (a) => a.name.local == 'line' || a.name.local == 'lineRule',
        );
        if (element.attributes.isEmpty) removed.add(element);
      } else if (name == 'rPr') {
        element.children.removeWhere(
          (node) =>
              node is XmlElement && _changeMarkers.contains(node.name.local),
        );
      }
    }
    for (final element in removed) {
      element.remove();
    }
    return copy.childElements.isEmpty ? null : copy.toXmlString();
  }

  void _structuredBlock(XmlElement sdt) {
    final properties = x.child(sdt, 'sdtPr');
    final gallery = x.childVal(
      x.child(properties, 'docPartObj'),
      'docPartGallery',
    );
    if (gallery != null) {
      _opaqueBlock(
        sdt,
        label: switch (gallery) {
          'Table of Contents' => OpaqueLabels.tableOfContents,
          'Cover Pages' => OpaqueLabels.coverPage,
          'Bibliographies' => OpaqueLabels.bibliography,
          _ => gallery,
        },
      );
      return;
    }
    final content = x.child(sdt, 'sdtContent');
    if (content != null) read(content.childElements);
  }

  void _opaqueBlock(XmlElement element, {required String label}) {
    final content = OpaqueContent(
      xml: element.toXmlString(),
      text: c.textOf(element),
      packageId: c.package.id,
      label: label,
    );
    delta
      ..insert({EmbedTypes.opaqueBlock: content.encode()})
      ..insert('\n');
  }

  void _table(XmlElement table) {
    final properties = x.child(table, 'tblPr');
    final grid = x.child(table, 'tblGrid');
    final widths = <double>[
      if (grid != null)
        for (final column in x.children(grid, 'gridCol'))
          double.tryParse(x.attr(column, 'w') ?? '') ?? 0,
    ];

    final rows = <TableRowModel>[];
    for (final row in _unwrap(table, 'tr')) {
      final rowProperties = row.childElements
          .where((e) => x.isW(e, 'tblPrEx') || x.isW(e, 'trPr'))
          .map((e) => e.toXmlString())
          .join();
      final cells = <TableCellModel>[];
      for (final cell in _unwrap(row, 'tc')) {
        final cellProperties = x.child(cell, 'tcPr');
        final merge = x.child(cellProperties, 'vMerge');
        final content = _DeltaBuilder();
        _BlockReader(c, content).read(cell.childElements);
        content.endWithNewline();
        cells.add(
          TableCellModel(
            controller: c.tables.newCellController(content.build()),
            propertiesXml: cellProperties?.toXmlString(),
            gridSpan:
                int.tryParse(x.childVal(cellProperties, 'gridSpan') ?? '') ?? 1,
            verticalMerge: merge == null
                ? VerticalMerge.none
                : x.val(merge) == 'restart'
                ? VerticalMerge.restart
                : VerticalMerge.continuation,
            fill: colorFromHex(
              _hexOrNull(x.attr(x.child(cellProperties, 'shd'), 'fill')),
            ),
          ),
        );
      }
      if (cells.isEmpty) continue;
      rows.add(
        TableRowModel(
          cells: cells,
          propertiesXml: rowProperties.isEmpty ? null : rowProperties,
        ),
      );
    }
    if (rows.isEmpty) return;

    final columns = rows
        .map(
          (row) => row.cells.fold<int>(0, (sum, cell) => sum + cell.gridSpan),
        )
        .reduce(math.max);
    if (widths.length < columns || widths.every((width) => width <= 0)) {
      widths
        ..clear()
        ..addAll(List.filled(columns, 9000 / columns));
    }

    final model = TableModel(
      id: c.tables.nextId(),
      packageId: c.package.id,
      rows: rows,
      columnWidths: widths,
      bordered:
          c.styles.hasVisibleBorders(properties) ||
          c.styles.tableStyleHasBorders(x.childVal(properties, 'tblStyle')),
      propertiesXml: properties?.toXmlString(),
    );
    c.tables.add(model);
    delta
      ..insert({EmbedTypes.table: encodeTableId(model.id)})
      ..insert('\n');
  }

  Iterable<XmlElement> _unwrap(XmlElement parent, String local) sync* {
    for (final element in parent.childElements) {
      if (x.isW(element, local)) {
        yield element;
      } else if (x.isW(element, 'sdt')) {
        final content = x.child(element, 'sdtContent');
        if (content != null) yield* _unwrap(content, local);
      } else if (x.isW(element, 'customXml')) {
        yield* _unwrap(element, local);
      }
    }
  }
}

String? _hexOrNull(String? value) {
  if (value == null) return null;
  final upper = value.toUpperCase();
  return RegExp(r'^[0-9A-F]{6}$').hasMatch(upper) ? upper : null;
}

class _InlineReader {
  _InlineReader(
    this.c,
    this.ops, {
    required this.paragraphStyleId,
    required this.baseline,
  });

  final _ReadContext c;

  /// The content of the story being read, which the runs are added to.
  final _DeltaBuilder ops;
  final String? paragraphStyleId;
  final RunProps baseline;
  final bookmarks = <String>[];

  List<XmlElement>? _field;
  var _fieldDepth = 0;
  var _fieldSeparated = false;
  final _fieldText = StringBuffer();
  var _ignoreFields = false;

  WordXml get x => c.x;

  void readParagraph(XmlElement paragraph) {
    _read(paragraph, null);
    final unfinished = _field;
    if (unfinished != null) {
      _field = null;
      _ignoreFields = true;
      for (final element in unfinished) {
        _element(element, null);
      }
    }
  }

  void _read(XmlElement container, String? link) {
    for (final element in container.childElements) {
      if (x.isW(element, 'pPr') || x.isW(element, 'rPr')) continue;
      if (_field != null) {
        _collectField(element);
      } else {
        _element(element, link);
      }
    }
  }

  void _element(XmlElement element, String? link) {
    final name = element.name.local;
    if (x.isW(element, 'r')) {
      if (!_ignoreFields && _startsField(element)) {
        _field = [];
        _fieldDepth = 0;
        _fieldSeparated = false;
        _fieldText.clear();
        _collectField(element);
      } else {
        _run(element, link);
      }
    } else if (x.isW(element, 'hyperlink')) {
      _read(element, _linkOf(element));
    } else if (x.isW(element, 'smartTag') ||
        x.isW(element, 'customXml') ||
        x.isW(element, 'dir') ||
        x.isW(element, 'bdo')) {
      _read(element, link);
    } else if (x.isW(element, 'ins') || x.isW(element, 'moveTo')) {
      c.notices.add(DocumentNotice.trackedChangesAccepted);
      _read(element, link);
    } else if (x.isW(element, 'del') || x.isW(element, 'moveFrom')) {
      c.notices.add(DocumentNotice.trackedChangesAccepted);
    } else if (x.isW(element, 'sdt')) {
      final content = x.child(element, 'sdtContent');
      if (content != null) _read(content, link);
    } else if (x.isW(element, 'bookmarkStart')) {
      final bookmark = x.attr(element, 'name');
      if (bookmark != null && bookmark != '_GoBack') bookmarks.add(bookmark);
    } else if (x.isW(element, 'commentRangeStart')) {
      c.notices.add(DocumentNotice.commentsHidden);
    } else if (_ignoredMarkers.contains(name)) {
      return;
    } else if (x.isW(element, 'fldSimple')) {
      _opaque(element.toXmlString(), c.textOf(element));
    } else {
      _opaque(
        element.toXmlString(),
        c.textOf(element),
        label: _labelFor(element),
      );
    }
  }

  bool _startsField(XmlElement run) => x
      .children(run, 'fldChar')
      .any((e) => x.attr(e, 'fldCharType') == 'begin');

  void _collectField(XmlElement element) {
    _field!.add(element);
    if (!x.isW(element, 'r')) {
      if (_fieldSeparated && _fieldDepth == 1) {
        _fieldText.write(c.textOf(element));
      }
      return;
    }
    for (final child in element.childElements) {
      if (x.isW(child, 'fldChar')) {
        switch (x.attr(child, 'fldCharType')) {
          case 'begin':
            _fieldDepth++;
          case 'separate':
            if (_fieldDepth == 1) _fieldSeparated = true;
          case 'end':
            _fieldDepth--;
        }
      } else if (x.isW(child, 't') && _fieldSeparated && _fieldDepth == 1) {
        _fieldText.write(child.innerText);
      } else if (x.isW(child, 'tab') && _fieldSeparated && _fieldDepth == 1) {
        _fieldText.write('\t');
      }
    }
    if (_fieldDepth <= 0) {
      final xml = _field!.map((e) => e.toXmlString()).join();
      _field = null;
      _opaque(xml, _fieldText.toString());
    }
  }

  String? _linkOf(XmlElement hyperlink) {
    final id = x.relAttr(hyperlink, 'id');
    if (id != null) {
      final target = c.relationships[id];
      if (target != null) return target.target;
    }
    final anchor = x.attr(hyperlink, 'anchor');
    return anchor == null ? null : '#$anchor';
  }

  void _run(XmlElement run, String? link) {
    final rPr = x.child(run, 'rPr');
    if (x.onOff(x.child(rPr, 'vanish')) ?? false) {
      _opaque(run.toXmlString(), '', hidden: true);
      return;
    }
    if (run.childElements.any(
      (e) => x.isW(e, 'commentReference') || x.isW(e, 'annotationRef'),
    )) {
      c.notices.add(DocumentNotice.commentsHidden);
      return;
    }

    final props = c.styles
        .runProps(paragraphStyleId, x.childVal(rPr, 'rStyle'))
        .merge(rPr, x, c.styles.theme);
    final attributes = _attributes(props, _preservedRunProperties(rPr), link);
    final rPrXml = rPr?.toXmlString() ?? '';
    final text = StringBuffer();

    void flush() {
      if (text.isEmpty) return;
      ops.insert(text.toString(), attributes);
      text.clear();
    }

    for (final child in run.childElements) {
      final name = child.name.local;
      if (x.isW(child, 't')) {
        text.write(child.innerText.replaceAll('\n', ' '));
      } else if (x.isW(child, 'tab') || x.isW(child, 'ptab')) {
        text.write('\t');
      } else if (x.isW(child, 'br')) {
        switch (x.attr(child, 'type')) {
          case 'page':
            flush();
            ops.insert({EmbedTypes.pageBreak: 'page'});
          case 'column':
            // Kept as it is for Word; other formats get a line break.
            flush();
            _opaque(
              '<${run.name.qualified}>$rPrXml${child.toXmlString()}'
                  '</${run.name.qualified}>',
              '\u2028',
            );
          default:
            text.write('\u2028');
        }
      } else if (x.isW(child, 'cr')) {
        text.write('\u2028');
      } else if (x.isW(child, 'noBreakHyphen')) {
        text.write('\u2011');
      } else if (x.isW(child, 'softHyphen')) {
        text.write('\u00AD');
      } else if (x.isW(child, 'rPr') ||
          x.isW(child, 'fldChar') ||
          x.isW(child, 'instrText') ||
          x.isW(child, 'delText') ||
          x.isW(child, 'lastRenderedPageBreak')) {
        continue;
      } else {
        flush();
        final xml =
            '<${run.name.qualified}>$rPrXml${child.toXmlString()}</${run.name.qualified}>';
        final alternative = name == 'AlternateContent'
            ? child.descendantElements
                  .where((element) => x.isW(element, 'drawing'))
                  .firstOrNull
            : null;
        if (x.isW(child, 'drawing')) {
          _drawing(child, xml);
        } else if (alternative != null) {
          _drawing(alternative, xml);
        } else if (x.isW(child, 'footnoteReference') ||
            x.isW(child, 'endnoteReference')) {
          _opaque(xml, '${++c.footnotes}', label: OpaqueLabels.note);
        } else {
          _opaque(
            xml,
            c.textOf(child),
            label: _labelFor(child, fallback: name),
          );
        }
      }
    }
    flush();
  }

  void _drawing(XmlElement drawing, String runXml) {
    XmlElement? find(String local) {
      for (final element in drawing.descendantElements) {
        if (element.name.local == local) return element;
      }
      return null;
    }

    final blip = find('blip');
    final relationship = blip == null
        ? null
        : c.relationships[x.relAttr(blip, 'embed')];
    final extent = find('extent');
    final width = (int.tryParse(extent?.getAttribute('cx') ?? '') ?? 0) / 12700;
    final height =
        (int.tryParse(extent?.getAttribute('cy') ?? '') ?? 0) / 12700;

    if (relationship != null && !relationship.external) {
      final path = DocxPackage.resolve(c.documentPath, relationship.target);
      final bytes = c.package.parts[path];
      if (bytes != null) {
        ops.insert(
          {
            EmbedTypes.image: c.pictures.putIfAbsent(
              path,
              () => dataUri(bytes, path),
            ),
          },
          {
            'width': formatPoints((width * 100).round() / 100),
            'height': formatPoints((height * 100).round() / 100),
            HiddenAttributes.drawing: runXml,
            HiddenAttributes.package: c.package.id,
          },
        );
        return;
      }
    }
    _opaque(runXml, c.textOf(drawing), label: _labelFor(drawing));
  }

  void _opaque(String xml, String text, {String? label, bool hidden = false}) {
    final content = OpaqueContent(
      xml: xml,
      text: text,
      packageId: c.package.id,
      label: label,
      hidden: hidden,
    );
    ops.insert({EmbedTypes.opaqueInline: content.encode()});
  }

  String? _labelFor(XmlElement element, {String? fallback}) {
    for (final descendant in [element, ...element.descendantElements]) {
      final uri = descendant.getAttribute('uri') ?? '';
      if (uri.endsWith('/chart')) return OpaqueLabels.chart;
      if (uri.endsWith('/diagram')) return OpaqueLabels.diagram;
      if (descendant.name.local == 'txbxContent') return OpaqueLabels.textBox;
      if (descendant.name.local == 'oMath') return OpaqueLabels.equation;
    }
    return fallback == null ? OpaqueLabels.object : null;
  }

  Map<String, dynamic>? _attributes(
    RunProps props,
    String? preserved,
    String? link,
  ) {
    final base = baseline;
    final attributes = <String, dynamic>{
      if (props.bold && !base.bold) 'bold': true,
      if (props.italic && !base.italic) 'italic': true,
      if (props.underline && !base.underline) 'underline': true,
      if (props.strike && !base.strike) 'strike': true,
      if (props.size != base.size) 'size': formatPoints(props.size),
      if (props.font != null && props.font != base.font) 'font': props.font,
      if (props.color != base.color) 'color': '#${props.color ?? '000000'}',
      if (props.background != null) 'background': '#${props.background}',
      if (props.script != null) 'script': props.script,
      'link': ?link,
      HiddenAttributes.runProperties: ?preserved,
    };
    return attributes.isEmpty ? null : attributes;
  }

  String? _preservedRunProperties(XmlElement? rPr) {
    if (rPr == null) return null;
    final copy = rPr.copy();
    copy.children.removeWhere(
      (node) =>
          node is XmlElement &&
          (_modeledRunProperties.contains(node.name.local) ||
              _changeMarkers.contains(node.name.local)),
    );
    return copy.childElements.isEmpty ? null : copy.toXmlString();
  }
}

const _modeledRunProperties = {
  'rFonts',
  'b',
  'bCs',
  'i',
  'iCs',
  'strike',
  'dstrike',
  'u',
  'sz',
  'szCs',
  'color',
  'highlight',
  'shd',
  'vertAlign',
};

/// Makes the same Delta as [Delta.insert] and [Delta.push], which join
/// neighboring text with the same attributes, in linear time: [Delta.push]
/// copies all the text joined so far on each join.
class _DeltaBuilder {
  final _operations = <Operation>[];
  final _text = StringBuffer();

  /// The last text operation, whose text ends [_text].
  Operation? _tail;

  void insert(Object data, [Map<String, dynamic>? attributes]) {
    if (data is String && data.isEmpty) return;
    push(Operation.insert(data, attributes));
  }

  void push(Operation operation) {
    if (operation.isEmpty) return;
    final data = operation.data;
    final tail = _tail;
    if (data is String) {
      if (tail == null || !tail.hasSameAttributes(operation)) _flush();
      _text.write(data);
      _tail = operation;
    } else {
      _flush();
      _operations.add(operation);
    }
  }

  /// Ends the content with a line, as documents and cells must.
  void endWithNewline() {
    final tail = _tail;
    final last = tail?.data ?? _operations.lastOrNull?.data;
    if (last is! String || !last.endsWith('\n')) insert('\n');
  }

  Delta build() {
    _flush();
    return Delta.fromOperations(_operations);
  }

  void _flush() {
    final tail = _tail;
    if (tail == null) return;
    final text = _text.toString();
    _operations.add(
      text.length == tail.length
          ? tail
          : Operation.insert(text, tail.attributes),
    );
    _text.clear();
    _tail = null;
  }
}
