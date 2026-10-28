import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:xml/xml.dart';

import '../document/document_codec.dart';
import '../document/document_look.dart';
import '../document/embeds.dart';
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

  LoadedDocument read() {
    final path = package.mainDocumentPath;
    final document = package.xml(path)!;
    final root = document.rootElement;
    final x = WordXml(root);
    final body = x.child(root, 'body');
    if (body == null) {
      throw const FormatException(
        'O documento do Word está vazio ou danificado.',
      );
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
    );

    final delta = Delta();
    _BlockReader(context, delta).read(body.childElements);
    if (delta.isEmpty || !_endsWithNewline(delta)) delta.insert('\n');

    return LoadedDocument(
      delta: delta,
      look: _look(styles, x, x.child(body, 'sectPr')),
      source: package,
      notices: context.notices.toList(),
    );
  }

  XmlDocument? _xmlOf(String? path) => path == null ? null : package.xml(path);

  static bool _endsWithNewline(Delta delta) {
    final last = delta.last.data;
    return last is String && last.endsWith('\n');
  }

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
  final RunProps normalRun;
  final ParagraphProps normalParagraph;
  final String? listParagraphStyleId;
  final notices = <String>{};
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
  final Delta delta;
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
        _opaqueBlock(element, label: 'Conteúdo especial');
      }
    }
  }

  void _noteTrackedChanges() =>
      c.notices.add('As alterações controladas do documento foram aceitas.');

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
      paragraphStyleId: styleId,
      baseline: header != null ? c.styles.runProps(styleId) : c.normalRun,
    )..readParagraph(paragraph);
    for (final operation in inline.ops.toList()) {
      delta.push(operation);
    }

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
      if (list != null) 'list': list == ListKind.bullet ? 'bullet' : 'ordered',
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
          'Table of Contents' => 'Sumário',
          'Cover Pages' => 'Capa',
          'Bibliographies' => 'Bibliografia',
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
        final content = Delta();
        _BlockReader(c, content).read(cell.childElements);
        if (content.isEmpty || !DocxReader._endsWithNewline(content)) {
          content.insert('\n');
        }
        cells.add(
          TableCellModel(
            controller: c.tables.newCellController(content),
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
    this.c, {
    required this.paragraphStyleId,
    required this.baseline,
  });

  final _ReadContext c;
  final String? paragraphStyleId;
  final RunProps baseline;
  final ops = Delta();
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
      c.notices.add('As alterações controladas do documento foram aceitas.');
      _read(element, link);
    } else if (x.isW(element, 'del') || x.isW(element, 'moveFrom')) {
      c.notices.add('As alterações controladas do documento foram aceitas.');
    } else if (x.isW(element, 'sdt')) {
      final content = x.child(element, 'sdtContent');
      if (content != null) _read(content, link);
    } else if (x.isW(element, 'bookmarkStart')) {
      final bookmark = x.attr(element, 'name');
      if (bookmark != null && bookmark != '_GoBack') bookmarks.add(bookmark);
    } else if (x.isW(element, 'commentRangeStart')) {
      c.notices.add('Os comentários do documento não aparecem no Voges Word.');
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
      c.notices.add('Os comentários do documento não aparecem no Voges Word.');
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
        if (x.attr(child, 'type') == 'page') {
          flush();
          ops.insert({EmbedTypes.pageBreak: 'page'});
        } else {
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
        if (x.isW(child, 'drawing')) {
          _drawing(child, xml);
        } else if (x.isW(child, 'footnoteReference') ||
            x.isW(child, 'endnoteReference')) {
          _opaque(xml, '${++c.footnotes}', label: 'nota');
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
          {EmbedTypes.image: dataUri(bytes, path)},
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
      if (uri.endsWith('/chart')) return 'gráfico';
      if (uri.endsWith('/diagram')) return 'diagrama';
      if (descendant.name.local == 'txbxContent') return 'caixa de texto';
      if (descendant.name.local == 'oMath') return 'equação';
    }
    return fallback == null ? 'objeto' : null;
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
