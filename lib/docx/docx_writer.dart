import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';
import 'package:xml/xml.dart';

import '../document/document_look.dart';
import '../document/embeds.dart';
import '../document/headers_footers.dart';
import '../document/tables.dart';
import 'docx_numbering.dart';
import 'docx_package.dart';
import 'docx_styles.dart';
import 'image_formats.dart';
import 'word_xml.dart';

class DocxWriter {
  DocxWriter(this.tables);

  final TableStore tables;

  Uint8List write(
    Delta delta,
    DocxPackage source, {
    DocumentLook? pageSetup,
    HeadersFooters? headersFooters,
  }) {
    final package = source.copy();
    final path = package.mainDocumentPath;
    final document = package.xml(path)!;
    final root = document.rootElement;
    final x = WordXml(root);
    final body = x.child(root, 'body')!;
    var section = x.child(body, 'sectPr');
    if (pageSetup != null) {
      section ??= XmlElement(XmlName.parts('sectPr', prefix: 'w'));
      _applyPageSetup(section, pageSetup, x);
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

    final stylesPath = partOf('styles');
    final numberingPath = partOf('numbering');
    final styles = DocxStyles.parse(
      stylesPath == null ? null : package.xml(stylesPath),
      partOf('theme') == null ? null : package.xml(partOf('theme')!),
    );
    final numbering = DocxNumbering.parse(
      numberingPath == null ? null : package.xml(numberingPath),
    );
    final pageWidth =
        double.tryParse(x.attr(x.child(section, 'pgSz'), 'w') ?? '') ?? 11906;
    final margins = x.child(section, 'pgMar');
    final marginLeft = double.tryParse(x.attr(margins, 'left') ?? '') ?? 1701;
    final marginRight = double.tryParse(x.attr(margins, 'right') ?? '') ?? 1701;

    final takenMedia = {...package.parts.keys};
    _WriteContext contextFor(
      List<Relationship> relationships, {
      int bookmarkStart = 100000,
    }) => _WriteContext(
      packageId: package.id,
      styles: styles,
      numbering: numbering,
      usedRelationshipIds: {for (final r in relationships) r.id},
      existingHyperlinks: {
        for (final r in relationships)
          if (r.type == RelationshipTypes.hyperlink) r.target: r.id,
      },
      tables: tables,
      contentWidthTwips: pageWidth - marginLeft - marginRight,
      takenMedia: takenMedia,
      bookmarkStart: bookmarkStart,
    );
    final context = contextFor(relationships);

    final bodyXml = _renumberDrawings(_BlockWriter(context).write(delta));

    final overrides = <String, String>{};
    if (headersFooters != null) {
      section ??= XmlElement(XmlName.parts('sectPr', prefix: 'w'));
      _writeStories(
        package,
        context,
        section,
        headersFooters,
        x,
        overrides,
        contextFor,
      );
    }

    body.children.clear();
    body.children.add(XmlComment('vw-body'));
    if (section != null) body.children.add(section);
    _declareNamespaces(root, bodyXml + (section?.toXmlString() ?? ''));
    package.setText(
      path,
      document.toXmlString().replaceFirst('<!--vw-body-->', bodyXml),
    );

    if (!context.numberingPlan.isEmpty) {
      final target = numberingPath ?? 'word/numbering.xml';
      package.setText(
        target,
        context.numberingPlan.apply(package.text(target)),
      );
      if (numberingPath == null) {
        context.newRelationships.add(
          Relationship(
            id: context.newRelationshipId(),
            type: RelationshipTypes.numbering,
            target: 'numbering.xml',
          ),
        );
        overrides['/$target'] =
            'application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml';
      }
    }
    if (context.addedHeadingStyles.isNotEmpty && stylesPath != null) {
      package.setText(
        stylesPath,
        _withHeadingStyles(package.text(stylesPath)!, context),
      );
    }
    context.media.forEach(
      (mediaPath, bytes) => package.parts[mediaPath] = bytes,
    );
    package.addRelationships(path, context.newRelationships);
    package.ensureContentTypes(
      defaults: context.mediaTypes,
      overrides: overrides,
    );
    return package.encode();
  }

  static const _sectionOrder = [
    'headerReference',
    'footerReference',
    'footnotePr',
    'endnotePr',
    'type',
    'pgSz',
    'pgMar',
    'paperSrc',
    'pgBorders',
    'lnNumType',
    'pgNumType',
    'cols',
    'formProt',
    'vAlign',
    'noEndnote',
    'titlePg',
    'textDirection',
    'bidi',
    'rtlGutter',
    'docGrid',
    'printerSettings',
    'sectPrChange',
  ];

  /// Puts the element in the section, following the order of Word's schema.
  static void _insertInSection(XmlElement section, XmlElement element) {
    final rank = _sectionOrder.indexOf(element.name.local);
    final children = section.children;
    var index = 0;
    for (var i = 0; i < children.length; i++) {
      final node = children[i];
      if (node is XmlElement) {
        final other = _sectionOrder.indexOf(node.name.local);
        if (other < 0 || other > rank) break;
      }
      index = i + 1;
    }
    children.insert(index, element);
  }

  static const _storyContentTypes = {
    'hdr':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml',
    'ftr':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml',
  };

  /// Rewrites only the edited headers and footers; new ones get a part, a
  /// relationship and a reference in the section.
  static void _writeStories(
    DocxPackage package,
    _WriteContext main,
    XmlElement section,
    HeadersFooters stories,
    WordXml x,
    Map<String, String> overrides,
    _WriteContext Function(List<Relationship>, {int bookmarkStart}) contextFor,
  ) {
    var drawingStart = 20000;
    var bookmarkStart = 200000;
    for (final (reference, rootName, type, all) in [
      ('headerReference', 'hdr', RelationshipTypes.header, stories.headers),
      ('footerReference', 'ftr', RelationshipTypes.footer, stories.footers),
    ]) {
      for (final MapEntry(key: variant, value: story) in all.entries) {
        if (!story.edited) continue;
        final original = story.partPath;
        final existing = original != null && package.parts.containsKey(original)
            ? original
            : null;
        final partPath = existing ?? _newPartPath(package, reference);
        final context = contextFor(
          existing == null ? const [] : package.relationships(existing),
          bookmarkStart: bookmarkStart,
        );
        final content = _renumberDrawings(
          _BlockWriter(context).write(story.delta),
          start: drawingStart,
        );
        drawingStart += 1000;
        bookmarkStart += 10000;

        final document = existing == null
            ? XmlDocument.parse(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                '<w:$rootName xmlns:w="${Namespaces.w}" xmlns:r="${Namespaces.r}"/>',
              )
            : package.xml(existing)!;
        final root = document.rootElement;
        root.children
          ..clear()
          ..add(XmlComment('vw-story'));
        _declareNamespaces(root, content);
        package.setText(
          partPath,
          document.toXmlString().replaceFirst('<!--vw-story-->', content),
        );
        package.addRelationships(partPath, context.newRelationships);
        context.media.forEach((path, bytes) => package.parts[path] = bytes);
        main.mediaTypes.addAll(context.mediaTypes);
        if (existing != null) continue;

        final id = main.newRelationshipId();
        main.newRelationships.add(
          Relationship(
            id: id,
            type: type,
            target: partPath.substring('word/'.length),
          ),
        );
        overrides['/$partPath'] = _storyContentTypes[rootName]!;
        final variantName = switch (variant) {
          PageVariant.normal => 'default',
          PageVariant.first => 'first',
          PageVariant.even => 'even',
        };
        section.children.removeWhere(
          (node) =>
              node is XmlElement &&
              x.isW(node, reference) &&
              (x.attr(node, 'type') ?? 'default') == variantName,
        );
        _insertInSection(
          section,
          XmlElement(XmlName.parts(reference, prefix: 'w'), [
            XmlAttribute(XmlName.parts('type', prefix: 'w'), variantName),
            XmlAttribute(XmlName.parts('id', prefix: 'r'), id),
          ]),
        );
      }
    }

    final titlePage = x.child(section, 'titlePg');
    if (stories.differentFirstPage && titlePage == null) {
      _insertInSection(
        section,
        XmlElement(XmlName.parts('titlePg', prefix: 'w')),
      );
    } else if (!stories.differentFirstPage && titlePage != null) {
      titlePage.remove();
    }
  }

  static String _newPartPath(DocxPackage package, String reference) {
    final base = reference == 'headerReference' ? 'header' : 'footer';
    var number = 1;
    while (package.parts.containsKey('word/$base$number.xml')) {
      number++;
    }
    return 'word/$base$number.xml';
  }

  /// Writes size, orientation and margins to the document's last section.
  static void _applyPageSetup(
    XmlElement section,
    DocumentLook look,
    WordXml x,
  ) {
    String twips(double points) => '${(points * 20).round()}';

    XmlElement ensure(String local) {
      final existing = x.child(section, local);
      if (existing != null) return existing;
      final element = XmlElement(XmlName.parts(local, prefix: 'w'));
      _insertInSection(section, element);
      return element;
    }

    final size = ensure('pgSz')
      ..setAttribute('w:w', twips(look.pageWidth))
      ..setAttribute('w:h', twips(look.pageHeight));
    if (look.isLandscape) {
      size.setAttribute('w:orient', 'landscape');
    } else {
      size.removeAttribute('w:orient');
    }
    final margins = ensure('pgMar')
      ..setAttribute('w:top', twips(look.margins.top))
      ..setAttribute('w:right', twips(look.margins.right))
      ..setAttribute('w:bottom', twips(look.margins.bottom))
      ..setAttribute('w:left', twips(look.margins.left));
    for (final (name, value) in const [
      ('w:header', '708'),
      ('w:footer', '708'),
      ('w:gutter', '0'),
    ]) {
      if (margins.getAttribute(name) == null) margins.setAttribute(name, value);
    }
  }

  static String _renumberDrawings(String xml, {int start = 10000}) {
    var next = start;
    return xml.replaceAllMapped(
      RegExp(r'(<(?:\w+:)?docPr\b[^>]*?\sid=")(\d+)(")'),
      (match) => '${match[1]}${next++}${match[3]}',
    );
  }

  static void _declareNamespaces(XmlElement root, String xml) {
    final declared = {
      for (final attribute in root.attributes)
        if (attribute.name.prefix == 'xmlns') attribute.name.local,
    };
    final used = <String>{
      for (final match in RegExp(r'</?([A-Za-z_][\w.-]*):').allMatches(xml))
        match[1]!,
      for (final match in RegExp(
        r'\s([A-Za-z_][\w.-]*):[\w.-]+="',
      ).allMatches(xml))
        match[1]!,
    }..removeAll(const {'xmlns', 'xml'});
    for (final prefix in used.difference(declared)) {
      final uri = Namespaces.known[prefix];
      if (uri != null) {
        root.attributes.add(
          XmlAttribute(XmlName.parts(prefix, prefix: 'xmlns'), uri),
        );
      }
    }
  }

  static String _withHeadingStyles(String stylesXml, _WriteContext context) {
    final document = XmlDocument.parse(stylesXml);
    final normal = context.styles.defaultParagraphStyleId;
    for (final entry in context.addedHeadingStyles.entries) {
      final level = entry.key;
      final props = context.headingBaseline(level);
      final size = (props.size * 2).round();
      final basedOn = normal == null
          ? ''
          : '<w:basedOn w:val="$normal"/><w:next w:val="$normal"/>';
      document.rootElement.children.add(
        parseFragment(
          '<w:style xmlns:w="${Namespaces.w}" w:type="paragraph" w:styleId="${entry.value}">'
          '<w:name w:val="heading $level"/>$basedOn<w:uiPriority w:val="9"/><w:qFormat/>'
          '<w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/>'
          '<w:outlineLvl w:val="${level - 1}"/></w:pPr>'
          '<w:rPr><w:b/><w:bCs/><w:sz w:val="$size"/><w:szCs w:val="$size"/></w:rPr></w:style>',
        ).copy()..removeAttribute('xmlns:w'),
      );
    }
    return document.toXmlString();
  }
}

class _WriteContext {
  _WriteContext({
    required this.packageId,
    required this.styles,
    required this.numbering,
    required this.usedRelationshipIds,
    required this.existingHyperlinks,
    required this.tables,
    required this.contentWidthTwips,
    required this.takenMedia,
    int bookmarkStart = 100000,
  }) : _bookmarkId = bookmarkStart,
       numberingPlan = NumberingPlan(numbering),
       normalRun = styles.runProps(null),
       normalParagraph = styles.paragraphProps(null),
       listParagraphStyleId = styles.idByName('List Paragraph'),
       hyperlinkStyleId = styles.idByName('Hyperlink', type: 'character');

  final String packageId;
  final DocxStyles styles;
  final DocxNumbering numbering;
  final NumberingPlan numberingPlan;
  final Set<String> usedRelationshipIds;
  final Map<String, String> existingHyperlinks;
  final TableStore tables;
  final double contentWidthTwips;
  final RunProps normalRun;
  final ParagraphProps normalParagraph;
  final String? listParagraphStyleId;
  final String? hyperlinkStyleId;

  /// Media paths already used in the package, across all parts.
  final Set<String> takenMedia;

  final newRelationships = <Relationship>[];
  final media = <String, Uint8List>{};
  final mediaTypes = <String, String>{};
  final addedHeadingStyles = <int, String>{};
  final usedBookmarks = <String>{};
  var _relationshipCounter = 0;
  var _mediaCounter = 0;
  int _bookmarkId;

  String newRelationshipId() {
    String id;
    do {
      id = 'rIdVw${++_relationshipCounter}';
    } while (usedRelationshipIds.contains(id));
    usedRelationshipIds.add(id);
    return id;
  }

  String hyperlink(String url) {
    final existing = existingHyperlinks[url];
    if (existing != null) return existing;
    final id = newRelationshipId();
    newRelationships.add(
      Relationship(
        id: id,
        type: RelationshipTypes.hyperlink,
        target: url,
        external: true,
      ),
    );
    existingHyperlinks[url] = id;
    return id;
  }

  String addImage(Uint8List bytes, String mime) {
    final extension = extensionForMime(mime);
    String path;
    do {
      path = 'word/media/vw-image${++_mediaCounter}.$extension';
    } while (!takenMedia.add(path));
    media[path] = bytes;
    mediaTypes[extension] = mime;
    final id = newRelationshipId();
    newRelationships.add(
      Relationship(
        id: id,
        type: RelationshipTypes.image,
        target: path.substring('word/'.length),
      ),
    );
    return id;
  }

  int nextBookmarkId() => _bookmarkId++;

  String headingStyleId(int level) {
    final existing = styles.headingStyleId(level) ?? addedHeadingStyles[level];
    if (existing != null) return existing;
    var id = 'Heading$level';
    if (styles.contains(id)) id = 'VWHeading$level';
    return addedHeadingStyles[level] = id;
  }

  RunProps headingBaseline(int level) {
    final id = styles.headingStyleId(level);
    if (id != null) return styles.runProps(id);
    return normalRun.copyWith(
      bold: true,
      size: normalRun.size * headingScale(level),
    );
  }
}

sealed class _Segment {
  const _Segment(this.attributes);

  final Map<String, dynamic>? attributes;

  String? get link => attributes?['link'] as String?;
}

class _TextSegment extends _Segment {
  const _TextSegment(this.text, super.attributes);

  final String text;
}

class _EmbedSegment extends _Segment {
  const _EmbedSegment(this.type, this.value, super.attributes);

  final String type;
  final Object? value;

  bool get isBlock => EmbedTypes.blockLevel.contains(type);
}

class _Block {
  _Block.paragraph(this.properties, this.content) : xml = null;

  _Block.raw(this.xml) : properties = const [], content = '';

  final List<XmlElement> properties;
  final String content;
  final String? xml;
  String? sectionXml;

  bool get isParagraph => xml == null;

  String render() {
    if (xml != null) return xml!;
    final all = [
      ...properties,
      if (sectionXml != null) parseFragment(sectionXml!).copy(),
    ];
    final pPr = all.isEmpty
        ? ''
        : '<w:pPr>${sortProperties(all, paragraphPropertyOrder).map((e) => e.toXmlString()).join()}</w:pPr>';
    return '<w:p>$pPr$content</w:p>';
  }
}

class _BlockWriter {
  _BlockWriter(this.c);

  final _WriteContext c;
  final _blocks = <_Block>[];
  int? _orderedListNum;

  String write(Delta delta) {
    var segments = <_Segment>[];
    for (final operation in delta.toList()) {
      final data = operation.data;
      final attributes = operation.attributes;
      if (data is String) {
        var start = 0;
        while (true) {
          final newline = data.indexOf('\n', start);
          if (newline < 0) {
            if (start < data.length) {
              segments.add(_TextSegment(data.substring(start), attributes));
            }
            break;
          }
          if (newline > start) {
            segments.add(
              _TextSegment(data.substring(start, newline), attributes),
            );
          }
          _line(segments, attributes ?? const {});
          segments = [];
          start = newline + 1;
        }
      } else if (data is Map) {
        segments.add(
          _EmbedSegment(
            data.keys.first as String,
            data.values.first,
            attributes,
          ),
        );
      }
    }
    if (segments.isNotEmpty) _line(segments, const {});
    if (_blocks.isEmpty || !_blocks.last.isParagraph) {
      _blocks.add(_Block.paragraph(const [], ''));
    }
    return _blocks.map((block) => block.render()).join();
  }

  void _line(List<_Segment> segments, Map<String, dynamic> attributes) {
    if (!segments.any((s) => s is _EmbedSegment && s.isBlock)) {
      _paragraph(segments, attributes);
      return;
    }
    var group = <_Segment>[];
    for (final segment in segments) {
      if (segment is _EmbedSegment && segment.isBlock) {
        if (group.isNotEmpty) {
          _paragraph(group, attributes);
          group = [];
        }
        _blockEmbed(segment);
      } else {
        group.add(segment);
      }
    }
    if (group.isNotEmpty) _paragraph(group, attributes);
  }

  void _blockEmbed(_EmbedSegment segment) {
    switch (segment.type) {
      case EmbedTypes.table:
        final table = c.tables[tableIdOf(segment.value)];
        if (table != null) _blocks.add(_Block.raw(_table(table)));
        _orderedListNum = null;
      case EmbedTypes.opaqueBlock:
        final content = OpaqueContent.decode(segment.value);
        if (content.packageId == c.packageId) {
          _blocks.add(_Block.raw(content.xml));
        } else {
          for (final line in content.text.split('\n')) {
            _blocks.add(_Block.paragraph(const [], _plainRun(line)));
          }
        }
        _orderedListNum = null;
      case EmbedTypes.sectionBreak:
        final xml = sectionXmlOf(segment.value);
        final last = _blocks.isEmpty ? null : _blocks.last;
        if (last != null && last.isParagraph && last.sectionXml == null) {
          last.sectionXml = xml;
        } else {
          _blocks.add(_Block.paragraph(const [], '')..sectionXml = xml);
        }
    }
  }

  void _paragraph(List<_Segment> segments, Map<String, dynamic> attributes) {
    final header = attributes['header'] as int?;
    final listValue = attributes['list'] as String?;
    final list = switch (listValue) {
      'ordered' => ListKind.ordered,
      null => null,
      _ => ListKind.bullet,
    };
    final indent = math.min((attributes['indent'] as num?)?.toInt() ?? 0, 8);
    final raw = attributes[HiddenAttributes.paragraphProperties] as String?;
    final properties = raw == null
        ? <XmlElement>[]
        : [for (final e in parseFragment(raw).childElements) e.copy()];

    XmlElement? find(String local) {
      for (final element in properties) {
        if (element.name.local == local) return element;
      }
      return null;
    }

    void replace(String local, XmlElement? element) {
      properties.removeWhere((e) => e.name.local == local);
      if (element != null) properties.add(element);
    }

    String? styleId = find('pStyle')?.getAttribute('w:val');
    RunProps baseline;
    if (header != null) {
      styleId = c.headingStyleId(header);
      baseline = c.headingBaseline(header);
    } else {
      if (list != null && styleId == null) styleId = c.listParagraphStyleId;
      baseline = c.normalRun;
    }
    replace('pStyle', styleId == null ? null : _w('pStyle', {'val': styleId}));
    final styleProps = c.styles.paragraphProps(styleId);

    if (list != null) {
      final numId = _numIdFor(
        list,
        indent,
        attributes[HiddenAttributes.numbering],
      );
      replace(
        'numPr',
        _w('numPr', const {}, [
          _w('ilvl', {'val': '$indent'}),
          _w('numId', {'val': '$numId'}),
        ]),
      );
      replace('ind', null);
    } else {
      _orderedListNum = null;
      final ind = find('ind');
      final currentLeft =
          double.tryParse(
            ind?.getAttribute('w:left') ?? ind?.getAttribute('w:start') ?? '',
          ) ??
          styleProps.indentLeft;
      // The reader shows outdents as level 0 and stops at 8.
      if ((currentLeft / 720).round().clamp(0, 8) != indent) {
        final element = ind ?? _w('ind');
        final key = element.getAttribute('w:start') != null
            ? 'w:start'
            : 'w:left';
        element.setAttribute(key, '${indent * 720}');
        replace('ind', element);
      }
    }

    final align = attributes['align'] as String? ?? 'left';
    replace(
      'jc',
      align == styleProps.align
          ? null
          : _w('jc', {'val': alignmentToWord(align)}),
    );

    final lineHeight = (attributes['line-height'] as num?)?.toDouble();
    final spacing = find('spacing');
    final exact =
        spacing?.getAttribute('w:lineRule') != null &&
        spacing?.getAttribute('w:lineRule') != 'auto';
    if (lineHeight != null || !exact) {
      final desired = lineHeight ?? c.normalParagraph.lineSpacing;
      if ((desired - styleProps.lineSpacing).abs() > 0.01 ||
          styleProps.exactLineSpacing) {
        final element = spacing ?? _w('spacing');
        element
          ..setAttribute('w:line', '${(desired * 240).round()}')
          ..setAttribute('w:lineRule', 'auto');
        replace('spacing', element);
      }
    }

    final starts = StringBuffer();
    final ends = StringBuffer();
    final bookmarks = attributes[HiddenAttributes.bookmarks] as String?;
    if (bookmarks != null) {
      for (final name in (jsonDecode(bookmarks) as List).cast<String>()) {
        if (!c.usedBookmarks.add(name)) continue;
        final id = c.nextBookmarkId();
        starts.write(
          '<w:bookmarkStart w:id="$id" w:name="${escapeXmlAttribute(name)}"/>',
        );
        ends.write('<w:bookmarkEnd w:id="$id"/>');
      }
    }

    final line = _LineStyle(styleId, baseline);
    _blocks.add(
      _Block.paragraph(properties, '$starts${_runs(segments, line)}$ends'),
    );
  }

  int _numIdFor(ListKind kind, int level, Object? original) {
    final originalId = (original as num?)?.toInt();
    if (originalId != null && c.numbering.kind(originalId, level) == kind) {
      if (kind == ListKind.ordered) _orderedListNum = null;
      return originalId;
    }
    if (kind == ListKind.bullet) return c.numberingPlan.bulletList();
    return _orderedListNum ??= c.numberingPlan.newOrderedList();
  }

  String _runs(List<_Segment> segments, _LineStyle line) {
    final out = StringBuffer();
    String? openLink;
    for (final segment in segments) {
      final link = switch (segment.link) {
        final link? => stripInvalidXmlChars(link),
        null => null,
      };
      if (link != openLink) {
        if (openLink != null) out.write('</w:hyperlink>');
        if (link != null) {
          out.write(
            link.startsWith('#')
                ? '<w:hyperlink w:anchor="${escapeXmlAttribute(link.substring(1))}" w:history="1">'
                : '<w:hyperlink r:id="${c.hyperlink(link)}" w:history="1">',
          );
        }
        openLink = link;
      }
      out.write(switch (segment) {
        _TextSegment() => _textRun(segment.text, segment.attributes, line),
        _EmbedSegment() => _inlineEmbed(segment, line),
      });
    }
    if (openLink != null) out.write('</w:hyperlink>');
    return out.toString();
  }

  String _inlineEmbed(_EmbedSegment segment, _LineStyle line) {
    switch (segment.type) {
      case EmbedTypes.image:
        return _image(segment);
      case EmbedTypes.pageNumber:
        final properties = _runProperties(segment.attributes ?? const {}, line);
        return [
          '<w:fldChar w:fldCharType="begin"/>',
          '<w:instrText xml:space="preserve"> PAGE </w:instrText>',
          '<w:fldChar w:fldCharType="separate"/>',
          '<w:t>1</w:t>',
          '<w:fldChar w:fldCharType="end"/>',
        ].map((content) => '<w:r>$properties$content</w:r>').join();
      case EmbedTypes.pageBreak:
        return '<w:r><w:br w:type="page"/></w:r>';
      case EmbedTypes.opaqueInline:
        final content = OpaqueContent.decode(segment.value);
        return content.packageId == c.packageId
            ? content.xml
            : _plainRun(content.text);
      default:
        return '';
    }
  }

  String _plainRun(String text) {
    if (text.isEmpty) return '';
    final content = [
      for (final part in text.split('\u2028'))
        if (part.isEmpty)
          ''
        else
          '<w:t xml:space="preserve">${escapeXmlText(stripInvalidXmlChars(part))}</w:t>',
    ].join('<w:br/>');
    return '<w:r>$content</w:r>';
  }

  String _textRun(
    String text,
    Map<String, dynamic>? attributes,
    _LineStyle line,
  ) {
    final content = StringBuffer();
    final pending = StringBuffer();
    void flush() {
      if (pending.isEmpty) return;
      content.write(
        '<w:t xml:space="preserve">'
        '${escapeXmlText(stripInvalidXmlChars(pending.toString()))}</w:t>',
      );
      pending.clear();
    }

    for (final rune in text.runes) {
      final element = switch (rune) {
        0x09 => '<w:tab/>',
        0x2028 => '<w:br/>',
        0x00AD => '<w:softHyphen/>',
        0x2011 => '<w:noBreakHyphen/>',
        _ => null,
      };
      if (element == null) {
        pending.writeCharCode(rune);
      } else {
        flush();
        content.write(element);
      }
    }
    flush();
    if (content.isEmpty) return '';
    return '<w:r>${_runProperties(attributes ?? const {}, line)}$content</w:r>';
  }

  String _runProperties(Map<String, dynamic> a, _LineStyle line) {
    final raw = a[HiddenAttributes.runProperties] as String?;
    final properties = raw == null
        ? <XmlElement>[]
        : [for (final e in parseFragment(raw).childElements) e.copy()];
    var characterStyle = properties
        .where((e) => e.name.local == 'rStyle')
        .map((e) => e.getAttribute('w:val'))
        .firstOrNull;
    final isLink = a['link'] != null;
    if (isLink && characterStyle == null && c.hyperlinkStyleId != null) {
      characterStyle = c.hyperlinkStyleId;
      properties.add(_w('rStyle', {'val': characterStyle!}));
    }

    final style = c.styles.runProps(line.styleId, characterStyle);
    final base = line.baseline;
    final bold = a['bold'] == true || (a['bold'] == null && base.bold);
    final italic = a['italic'] == true || (a['italic'] == null && base.italic);
    final strike = a['strike'] == true || (a['strike'] == null && base.strike);
    var underline =
        a['underline'] == true || (a['underline'] == null && base.underline);
    final size = _points(a['size']) ?? base.size;
    final font = a['font'] as String? ?? base.font;
    var color = a['color'] == null ? base.color : _hex(a['color']);
    final background = _hex(a['background']);
    final script = a['script'] as String?;

    if (isLink) {
      if (c.hyperlinkStyleId != null) {
        if (a['color'] == null) color = style.color;
        if (a['underline'] == null) underline = style.underline;
      } else {
        if (a['color'] == null) color = '0563C1';
        if (a['underline'] == null) underline = true;
      }
    }

    if (font != null && font != style.font) {
      properties.add(
        _w('rFonts', {
          'ascii': font,
          'hAnsi': font,
          'eastAsia': font,
          'cs': font,
        }),
      );
    }
    if (bold != style.bold) {
      properties.addAll([_toggle('b', bold), _toggle('bCs', bold)]);
    }
    if (italic != style.italic) {
      properties.addAll([_toggle('i', italic), _toggle('iCs', italic)]);
    }
    if (strike != style.strike) properties.add(_toggle('strike', strike));
    if (color != style.color) {
      properties.add(_w('color', {'val': color ?? 'auto'}));
    }
    if (size != style.size) {
      final halfPoints = '${(size * 2).round()}';
      properties.addAll([
        _w('sz', {'val': halfPoints}),
        _w('szCs', {'val': halfPoints}),
      ]);
    }
    if (background != style.background) {
      final highlight = background == null
          ? 'none'
          : highlightColors.entries
                .where((entry) => entry.value == background)
                .map((entry) => entry.key)
                .firstOrNull;
      properties.add(
        highlight != null
            ? _w('highlight', {'val': highlight})
            : _w('shd', {'val': 'clear', 'color': 'auto', 'fill': background!}),
      );
    }
    if (underline != style.underline) {
      properties.add(_w('u', {'val': underline ? 'single' : 'none'}));
    }
    if (script != style.script) {
      properties.add(
        _w('vertAlign', {
          'val': switch (script) {
            'super' => 'superscript',
            'sub' => 'subscript',
            _ => 'baseline',
          },
        }),
      );
    }

    if (properties.isEmpty) return '';
    return '<w:rPr>${sortProperties(properties, runPropertyOrder).map((e) => e.toXmlString()).join()}</w:rPr>';
  }

  String _image(_EmbedSegment segment) {
    final attributes = segment.attributes ?? const {};
    final raw = attributes[HiddenAttributes.drawing] as String?;
    if (raw != null && attributes[HiddenAttributes.package] == c.packageId) {
      return raw;
    }
    final decoded = decodeDataUri(segment.value as String? ?? '');
    if (decoded == null) return '';

    final pixels = imagePixelSize(decoded.bytes);
    var width = _points(attributes['width']) ?? (pixels?.width ?? 300) * 0.75;
    var height =
        _points(attributes['height']) ??
        (pixels == null
            ? width
            : pixels.height * width / math.max(pixels.width, 1));
    final maxWidth = c.contentWidthTwips / 20;
    if (width > maxWidth) {
      height = height * maxWidth / width;
      width = maxWidth;
    }
    final cx = (width * 12700).round();
    final cy = (height * 12700).round();
    final id = c.addImage(decoded.bytes, decoded.mime);
    return '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
        '<wp:extent cx="$cx" cy="$cy"/><wp:effectExtent l="0" t="0" r="0" b="0"/>'
        '<wp:docPr id="1" name="Picture"/>'
        '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
        '<a:graphic><a:graphicData uri="${Namespaces.pic}">'
        '<pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="Picture"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="$id"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
        '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>';
  }

  String _table(TableModel table) {
    final sameOrigin = table.packageId == c.packageId;
    final widths = table.columnWidths;
    final grid = widths.map((w) => '<w:gridCol w:w="${w.round()}"/>').join();
    final properties =
        (sameOrigin ? table.propertiesXml : null) ??
        _defaultTableProperties(table.bordered);

    final rows = StringBuffer();
    for (final row in table.rows) {
      rows.write('<w:tr>${sameOrigin ? row.propertiesXml ?? '' : ''}');
      var column = 0;
      for (final cell in row.cells) {
        final span = math.max(cell.gridSpan, 1);
        var width = 0.0;
        for (var i = column; i < math.min(column + span, widths.length); i++) {
          width += widths[i];
        }
        column += span;
        final content = _BlockWriter(
          c,
        ).write(cell.controller.document.toDelta());
        rows.write(
          '<w:tc>${_cellProperties(cell, width, sameOrigin)}$content</w:tc>',
        );
      }
      rows.write('</w:tr>');
    }
    return '<w:tbl>$properties<w:tblGrid>$grid</w:tblGrid>$rows</w:tbl>';
  }

  static const _cellPropertyOrder = [
    'cnfStyle',
    'tcW',
    'gridSpan',
    'hMerge',
    'vMerge',
    'tcBorders',
    'shd',
    'noWrap',
    'tcMar',
    'textDirection',
    'tcFitText',
    'vAlign',
    'hideMark',
    'headers',
    'cellIns',
    'cellDel',
    'cellMerge',
    'tcPrChange',
  ];

  String _cellProperties(TableCellModel cell, double width, bool sameOrigin) {
    final raw = sameOrigin ? cell.propertiesXml : null;
    final properties = raw == null
        ? <XmlElement>[]
        : [for (final e in parseFragment(raw).childElements) e.copy()];
    properties
      ..removeWhere(
        (e) => const {'tcW', 'gridSpan', 'vMerge'}.contains(e.name.local),
      )
      ..add(_w('tcW', {'w': '${width.round()}', 'type': 'dxa'}));
    if (cell.gridSpan > 1) {
      properties.add(_w('gridSpan', {'val': '${cell.gridSpan}'}));
    }
    switch (cell.verticalMerge) {
      case VerticalMerge.restart:
        properties.add(_w('vMerge', {'val': 'restart'}));
      case VerticalMerge.continuation:
        properties.add(_w('vMerge'));
      case VerticalMerge.none:
        break;
    }
    final sorted = sortProperties(properties, _cellPropertyOrder);
    return '<w:tcPr>${sorted.map((e) => e.toXmlString()).join()}</w:tcPr>';
  }

  static String _defaultTableProperties(bool bordered) {
    final border = bordered ? 'single' : 'none';
    final sides = ['top', 'left', 'bottom', 'right', 'insideH', 'insideV']
        .map(
          (side) =>
              '<w:$side w:val="$border" w:sz="4" w:space="0" w:color="auto"/>',
        )
        .join();
    return '<w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>$sides</w:tblBorders>'
        '<w:tblLayout w:type="fixed"/>'
        '<w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="1" '
        'w:lastColumn="0" w:noHBand="0" w:noVBand="1"/></w:tblPr>';
  }

  static XmlElement _w(
    String local, [
    Map<String, String> attributes = const {},
    List<XmlElement> children = const [],
  ]) {
    return XmlElement(XmlName.parts(local, prefix: 'w'), [
      for (final entry in attributes.entries)
        XmlAttribute(XmlName.parts(entry.key, prefix: 'w'), entry.value),
    ], children);
  }

  static XmlElement _toggle(String local, bool on) =>
      on ? _w(local) : _w(local, {'val': '0'});

  static double? _points(Object? value) => switch (value) {
    num() => value.toDouble(),
    'small' => 9,
    'large' => 18,
    'huge' => 28,
    String() => double.tryParse(value),
    _ => null,
  };

  static String? _hex(Object? value) {
    if (value is! String) return null;
    var hex = value.startsWith('#') ? value.substring(1) : value;
    if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
    if (hex.length == 8) hex = hex.substring(2);
    final upper = hex.toUpperCase();
    return RegExp(r'^[0-9A-F]{6}$').hasMatch(upper) ? upper : null;
  }
}

class _LineStyle {
  const _LineStyle(this.styleId, this.baseline);

  final String? styleId;
  final RunProps baseline;
}
