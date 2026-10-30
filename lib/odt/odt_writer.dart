import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/painting.dart' show Color, EdgeInsets;
import 'package:flutter_quill/quill_delta.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart'
    show XmlEndElementEvent, XmlStartElementEvent, parseEvents;

import '../document/delta_blocks.dart';
import '../document/document_look.dart';
import '../document/embeds.dart';
import '../document/headers_footers.dart';
import '../document/picture_crop.dart';
import '../document/tables.dart';
import '../docx/docx_builder.dart' show safeLinkTarget;
import '../docx/docx_codec.dart';
import '../docx/docx_package.dart';
import '../docx/image_formats.dart';
import '../docx/word_xml.dart';
import 'odf_xml.dart';
import 'odt_package.dart' show odtMimeType;

enum _Place { body, header, footer, footnote, endnote }

const _namespaces =
    'xmlns:office="${OdfNamespaces.office}" '
    'xmlns:style="${OdfNamespaces.style}" '
    'xmlns:text="${OdfNamespaces.text}" '
    'xmlns:table="${OdfNamespaces.table}" '
    'xmlns:draw="${OdfNamespaces.draw}" '
    'xmlns:fo="${OdfNamespaces.fo}" '
    'xmlns:xlink="${OdfNamespaces.xlink}" '
    'xmlns:dc="${OdfNamespaces.dc}" '
    'xmlns:meta="${OdfNamespaces.meta}" '
    'xmlns:number="${OdfNamespaces.number}" '
    'xmlns:svg="${OdfNamespaces.svg}"';

const _declaration = '<?xml version="1.0" encoding="UTF-8"?>';

/// Picture types other applications show.
const _pictureTypes = {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/bmp',
  'image/webp',
  'image/tiff',
  'image/svg+xml',
  'image/x-emf',
  'image/x-wmf',
};

/// Pictures in the text sit on the baseline.
const _inlinePicture =
    ' style:vertical-pos="top" style:vertical-rel="baseline"';

String _attribute(String value) =>
    escapeXmlAttribute(stripInvalidXmlChars(value));

/// fo:[local] and the Asian and complex-script versions LibreOffice applies
/// to those scripts.
String _inEveryScript(String local, String value) =>
    ' fo:$local="$value" style:$local-asian="$value" '
    'style:$local-complex="$value"';

String _fontNames(String font) {
  final name = _attribute(font);
  return ' style:font-name="$name" style:font-name-asian="$name" '
      'style:font-name-complex="$name"';
}

/// A stored fragment of Word XML, under one root; null when it is malformed.
XmlElement? _fragment(Object? xml) {
  if (xml is! String || xml.isEmpty) return null;
  try {
    return XmlDocument.parse('<x>$xml</x>').rootElement;
  } catch (_) {
    return null;
  }
}

XmlElement? _child(XmlElement? parent, String local) {
  if (parent == null) return null;
  for (final element in parent.childElements) {
    if (element.name.local == local) return element;
  }
  return null;
}

XmlElement? _descendant(XmlElement? root, String local) {
  if (root == null) return null;
  for (final element in root.descendantElements) {
    if (element.name.local == local) return element;
  }
  return null;
}

double? _positive(double? value) =>
    value != null && value.isFinite && value > 0 ? value : null;

/// Writes the editor's content as an OpenDocument Text file (ODF 1.3).
class OdtWriter {
  OdtWriter(this.tables);

  final TableStore tables;

  Uint8List write(
    Delta delta, {
    DocumentLook look = const DocumentLook(),
    HeadersFooters? headersFooters,
    Object? source,
  }) {
    final document = _Document(look, source);
    final contentStyles = _Styles('');
    final masterStyles = _Styles('M');
    final stories = headersFooters ?? const HeadersFooters();

    final sections = _sections(documentBlocks(delta), document.lastNumbering());
    final body = _StoryWriter(
      document,
      contentStyles,
      _Place.body,
      tables,
      part: document.mainPart,
    );
    for (final (index, section) in sections.indexed) {
      final start = section.numbering.start;
      if (sections.length > 1 || start != null) {
        body.startSection(_masterName(index, sections), pageNumber: start);
      }
      body.write(section.blocks);
    }
    final bodyXml = body.finish();

    String story(HeaderFooterStory? story, _Place place) {
      if (story == null) return '';
      return (_StoryWriter(
        document,
        masterStyles,
        place,
        tables,
        part: story.partPath,
      )..write(documentBlocks(story.delta))).finish();
    }

    final parts = StringBuffer();
    var header = false;
    var footer = false;
    for (final (kind, all, place) in [
      ('header', stories.headers, _Place.header),
      ('footer', stories.footers, _Place.footer),
    ]) {
      bool present(HeaderFooterStory? story) => story != null && !story.isEmpty;
      final normal = all[PageVariant.normal];
      final even = stories.differentOddEven ? all[PageVariant.even] : null;
      final first = stories.differentFirstPage ? all[PageVariant.first] : null;
      if (!present(normal) && !present(even) && !present(first)) continue;
      if (kind == 'header') {
        header = true;
      } else {
        footer = true;
      }
      String element(String name, HeaderFooterStory? content) {
        final xml = present(content) ? story(content, place) : '';
        return xml.isEmpty
            ? '<style:$name/>'
            : '<style:$name>$xml</style:$name>';
      }

      parts.write(element(kind, normal));
      if (stories.differentOddEven) parts.write(element('$kind-left', even));
      if (stories.differentFirstPage) {
        parts.write(element('$kind-first', first));
      }
    }

    final layouts = StringBuffer();
    final masters = StringBuffer();
    for (final (index, section) in sections.indexed) {
      if (section.blocks.isEmpty && index < sections.length - 1) continue;
      final layout = 'pm${index + 1}';
      final page = section.page;
      layouts.write(
        _pageLayout(
          layout,
          width: page?.width ?? look.pageWidth,
          height: page?.height ?? look.pageHeight,
          margins: page?.margins ?? look.margins,
          headerDistance: page?.header ?? stories.headerDistance,
          footerDistance: page?.footer ?? stories.footerDistance,
          header: header,
          footer: footer,
          numberFormat: section.numbering.format,
        ),
      );
      masters.write(
        '<style:master-page style:name="${_masterName(index, sections)}" '
        'style:page-layout-name="$layout">$parts</style:master-page>',
      );
    }

    final fonts = {
      ...document.fonts,
      ?_font(look.body.fontFamily),
      for (var level = 1; level <= 6; level++)
        ?_font(look.heading(level).fontFamily),
    };
    final fontFaces = [
      for (final font in fonts)
        '<style:font-face style:name="${_attribute(font)}" '
            'svg:font-family="${_attribute(font.contains(' ') ? "'$font'" : font)}"/>',
    ].join();

    final content =
        '$_declaration<office:document-content $_namespaces office:version="1.3">'
        '<office:font-face-decls>$fontFaces</office:font-face-decls>'
        '<office:automatic-styles>${contentStyles.xml}</office:automatic-styles>'
        '<office:body><office:text>$bodyXml</office:text></office:body>'
        '</office:document-content>';
    final styles =
        '$_declaration<office:document-styles $_namespaces office:version="1.3">'
        '<office:font-face-decls>$fontFaces</office:font-face-decls>'
        '<office:styles>${_commonStyles(look, document.languages())}</office:styles>'
        '<office:automatic-styles>$layouts${masterStyles.xml}</office:automatic-styles>'
        '<office:master-styles>$masters</office:master-styles>'
        '</office:document-styles>';
    const meta =
        '$_declaration<office:document-meta '
        'xmlns:office="${OdfNamespaces.office}" '
        'xmlns:meta="${OdfNamespaces.meta}" office:version="1.3">'
        '<office:meta><meta:generator>Voges Word</meta:generator></office:meta>'
        '</office:document-meta>';

    final manifest = StringBuffer(
      '$_declaration<manifest:manifest '
      'xmlns:manifest="${OdfNamespaces.manifest}" manifest:version="1.3">'
      '<manifest:file-entry manifest:full-path="/" manifest:version="1.3" '
      'manifest:media-type="$odtMimeType"/>',
    );
    for (final name in ['content.xml', 'styles.xml', 'meta.xml']) {
      manifest.write(
        '<manifest:file-entry manifest:full-path="$name" '
        'manifest:media-type="text/xml"/>',
      );
    }
    document.pictures.forEach((path, picture) {
      manifest.write(
        '<manifest:file-entry manifest:full-path="$path" '
        'manifest:media-type="${picture.mime}"/>',
      );
    });
    manifest.write('</manifest:manifest>');

    // The mimetype comes first and uncompressed, so the type can be told
    // from the zip's first bytes.
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes('mimetype', utf8.encode(odtMimeType))
          ..compression = CompressionType.none,
      );
    for (final (name, text) in [
      ('content.xml', content),
      ('styles.xml', styles),
      ('meta.xml', meta),
      ('META-INF/manifest.xml', manifest.toString()),
    ]) {
      archive.addFile(ArchiveFile.bytes(name, utf8.encode(text)));
    }
    document.pictures.forEach((path, picture) {
      archive.addFile(
        ArchiveFile.bytes(path, picture.bytes)
          ..compression = CompressionType.none,
      );
    });
    return ZipEncoder().encodeBytes(archive);
  }

  static String _masterName(int index, List<_Section> sections) =>
      index == sections.length - 1 ? 'Standard' : 'Section${index + 1}';

  /// Splits the body at section breaks that start a page; the last section
  /// uses the document's page setup and [last] numbering, the others what
  /// their break says.
  static List<_Section> _sections(List<DocumentBlock> blocks, _Numbering last) {
    final sections = <_Section>[];
    var current = <DocumentBlock>[];
    for (final block in blocks) {
      if (block is EmbedBlock && block.type == EmbedTypes.sectionBreak) {
        final section = _sectionOf(block.value);
        if (section == null) continue;
        sections.add((
          blocks: current,
          page: section.page,
          numbering: section.numbering,
        ));
        current = [];
      } else {
        current.add(block);
      }
    }
    sections.add((blocks: current, page: null, numbering: last));
    return sections;
  }

  /// The page of a Word section break; null for continuous ones, which
  /// OpenDocument can't start without a new page.
  static ({_SectionPage page, _Numbering numbering})? _sectionOf(
    Object? value,
  ) {
    try {
      final root = parseFragment(sectionXmlOf(value));
      if (_child(root, 'type')?.getAttribute('val', namespaceUri: '*') ==
          'continuous') {
        return null;
      }
      double? points(XmlElement? element, String local) {
        final twips = double.tryParse(
          element?.getAttribute(local, namespaceUri: '*') ?? '',
        );
        return twips == null || !twips.isFinite ? null : twips / 20;
      }

      const defaults = DocumentLook();
      final size = _child(root, 'pgSz');
      final margins = _child(root, 'pgMar');
      final numbers = _child(root, 'pgNumType');
      return (
        page: (
          width: points(size, 'w') ?? defaults.pageWidth,
          height: points(size, 'h') ?? defaults.pageHeight,
          margins: EdgeInsets.fromLTRB(
            points(margins, 'left') ?? defaults.margins.left,
            points(margins, 'top') ?? defaults.margins.top,
            points(margins, 'right') ?? defaults.margins.right,
            points(margins, 'bottom') ?? defaults.margins.bottom,
          ),
          header: points(margins, 'header'),
          footer: points(margins, 'footer'),
        ),
        numbering: _numbering(
          (name) => numbers?.getAttribute(name, namespaceUri: '*'),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// Word's w:pgNumType, from its attributes.
  static _Numbering _numbering(String? Function(String name) attribute) {
    final start = int.tryParse(attribute('start')?.trim() ?? '');
    return (
      format: switch (attribute('fmt')) {
        'lowerRoman' => 'i',
        'upperRoman' => 'I',
        'lowerLetter' => 'a',
        'upperLetter' => 'A',
        _ => null,
      },
      start: start?.clamp(0, 32767),
    );
  }

  /// The header and footer are measured from the page's edge, and the body
  /// starts after them, as in Word.
  static String _pageLayout(
    String name, {
    required double width,
    required double height,
    required EdgeInsets margins,
    required double headerDistance,
    required double footerDistance,
    required bool header,
    required bool footer,
    String? numberFormat,
  }) {
    double distance(double value) => value.isFinite && value > 0 ? value : 0.0;
    // A negative top or bottom margin only tells Word the body never moves
    // for the header; OpenDocument takes the distance.
    final marginTop = distance(margins.top.abs());
    final marginBottom = distance(margins.bottom.abs());
    final top = header
        ? math.min(distance(headerDistance), marginTop)
        : marginTop;
    final bottom = footer
        ? math.min(distance(footerDistance), marginBottom)
        : marginBottom;
    final out = StringBuffer(
      '<style:page-layout style:name="$name">'
      '<style:page-layout-properties fo:page-width="${odfPoints(width)}" '
      'fo:page-height="${odfPoints(height)}" '
      '${numberFormat == null ? '' : 'style:num-format="$numberFormat" '}'
      'style:print-orientation="${width > height ? 'landscape' : 'portrait'}" '
      'fo:margin-top="${odfPoints(top)}" '
      'fo:margin-bottom="${odfPoints(bottom)}" '
      'fo:margin-left="${odfPoints(distance(margins.left))}" '
      'fo:margin-right="${odfPoints(distance(margins.right))}" '
      'style:writing-mode="lr-tb"/>',
    );
    if (header) {
      out.write(
        '<style:header-style><style:header-footer-properties '
        'fo:min-height="${odfPoints(marginTop - top)}" '
        'fo:margin-bottom="0pt"/></style:header-style>',
      );
    }
    if (footer) {
      out.write(
        '<style:footer-style><style:header-footer-properties '
        'fo:min-height="${odfPoints(marginBottom - bottom)}" '
        'fo:margin-top="0pt"/></style:footer-style>',
      );
    }
    out.write('</style:page-layout>');
    return out.toString();
  }

  static String _commonStyles(DocumentLook look, String languages) {
    final body = look.body;
    final width = look.contentWidth;
    // The stops of Word's and LibreOffice's own Header and Footer styles,
    // which the editor also draws.
    final tabs = width.isFinite && width > 0
        ? '<style:paragraph-properties><style:tab-stops>'
              '<style:tab-stop style:position="${odfPoints(width / 2)}" '
              'style:type="center"/>'
              '<style:tab-stop style:position="${odfPoints(width)}" '
              'style:type="right"/>'
              '</style:tab-stops></style:paragraph-properties>'
        : '';
    final out = StringBuffer(
      '<style:default-style style:family="paragraph">'
      '<style:paragraph-properties style:tab-stop-distance="35.4pt" '
      'style:writing-mode="page"/>'
      '<style:text-properties${_lookText(body, withStyle: false)}$languages/>'
      '</style:default-style>'
      '<style:style style:name="Standard" style:family="paragraph" '
      'style:class="text">'
      '<style:paragraph-properties${_lookParagraph(body)} '
      'fo:line-height="${(look.lineSpacing * 100).round()}%"/>'
      '<style:text-properties${_lookWeight(body)}/>'
      '</style:style>'
      '<style:style style:name="Heading" style:family="paragraph" '
      'style:parent-style-name="Standard" style:next-style-name="Standard" '
      'style:class="text">'
      '<style:paragraph-properties fo:keep-with-next="always"/></style:style>',
    );
    for (var level = 1; level <= 6; level++) {
      final heading = look.heading(level);
      out.write(
        '<style:style style:name="Heading_20_$level" '
        'style:display-name="Heading $level" style:family="paragraph" '
        'style:parent-style-name="Heading" style:next-style-name="Standard" '
        'style:default-outline-level="$level" style:class="text">'
        '<style:paragraph-properties${_lookParagraph(heading)}/>'
        '<style:text-properties${_lookText(heading, withStyle: true)}/>'
        '</style:style>',
      );
    }
    for (final name in ['Header', 'Footer']) {
      out.write(
        '<style:style style:name="$name" style:display-name="$name" '
        'style:family="paragraph" style:parent-style-name="Standard" '
        'style:class="extra">$tabs</style:style>',
      );
    }
    for (final name in ['Footnote', 'Endnote']) {
      out.write(
        '<style:style style:name="$name" style:family="paragraph" '
        'style:parent-style-name="Standard" style:class="extra">'
        '<style:paragraph-properties fo:margin-top="0pt" '
        'fo:margin-bottom="0pt" fo:line-height="100%"/>'
        '<style:text-properties fo:font-size="10pt"/></style:style>',
      );
    }
    for (final (name, display, color) in [
      ('Internet_20_link', 'Internet link', '#0563c1'),
      ('Visited_20_Internet_20_Link', 'Visited Internet Link', '#954f72'),
    ]) {
      out.write(
        '<style:style style:name="$name" style:display-name="$display" '
        'style:family="text"><style:text-properties fo:color="$color" '
        'style:text-underline-style="solid" style:text-underline-width="auto" '
        'style:text-underline-color="font-color"/></style:style>',
      );
    }
    out.write('<text:outline-style style:name="Outline">');
    for (var level = 1; level <= 10; level++) {
      out.write(
        '<text:outline-level-style text:level="$level" style:num-format=""/>',
      );
    }
    out.write('</text:outline-style>');
    return out.toString();
  }

  static String _lookParagraph(TextLook look) =>
      ' fo:margin-top="${odfPoints(look.spaceBefore)}" '
      'fo:margin-bottom="${odfPoints(look.spaceAfter)}"'
      '${look.indentRight != 0 ? ' fo:margin-right="${odfPoints(look.indentRight)}"' : ''}'
      '${look.firstLine != 0 ? ' fo:text-indent="${odfPoints(look.firstLine)}"' : ''}';

  static String _lookText(TextLook look, {required bool withStyle}) {
    final font = _font(look.fontFamily);
    return '${font == null ? '' : _fontNames(font)}'
        '${_inEveryScript('font-size', odfPoints(look.fontSize))}'
        ' fo:color="#${_colorHex(look.color)}"'
        '${withStyle ? _lookWeight(look, explicit: true) : ''}';
  }

  static String _lookWeight(TextLook look, {bool explicit = false}) =>
      '${look.bold || explicit ? _inEveryScript('font-weight', look.bold ? 'bold' : 'normal') : ''}'
      '${look.italic || explicit ? _inEveryScript('font-style', look.italic ? 'italic' : 'normal') : ''}';

  static String? _font(Object? value) {
    if (value is! String) return null;
    final clean = stripInvalidXmlChars(value).trim();
    return clean.isEmpty || clean.length > 100 ? null : clean;
  }
}

String _colorHex(Color color) =>
    (color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');

typedef _SectionPage = ({
  double width,
  double height,
  EdgeInsets margins,
  double? header,
  double? footer,
});

/// How a section numbers its pages: an OpenDocument number format (`i`,
/// `A`...) and the number of its first page; null keeps 1, 2, 3 and goes on
/// counting.
typedef _Numbering = ({String? format, int? start});

const _Numbering _unnumbered = (format: null, start: null);

typedef _Section = ({
  List<DocumentBlock> blocks,
  _SectionPage? page,
  _Numbering numbering,
});

/// What every part of the file shares: fonts, pictures, names and counters.
class _Document {
  _Document(this.look, Object? source)
    : package = source is DocxPackage ? source : null;

  final DocumentLook look;

  /// The opened package: notes, the pictures of protected content and the
  /// last section's numbering come from it.
  final DocxPackage? package;
  final fonts = <String>{};
  final pictures = <String, ({Uint8List bytes, String mime})>{};
  final _pictureByKey = <String, String>{};
  final bookmarks = <String>{};

  /// Identity keeps a table from containing itself, whatever store it is in.
  final tablesInProgress = <TableModel>{};
  var tableCount = 0;
  var frameCount = 0;
  var footnotes = 0;
  var endnotes = 0;

  /// Tables of notes, read apart so saving leaves the editor's tables alone.
  final noteTables = TableStore();
  final _notes = <String, Map<String, Delta>>{};
  final _relationships = <String, Map<String, Relationship>>{};

  late final String? mainPart = () {
    try {
      return package?.mainDocumentPath;
    } catch (_) {
      return null;
    }
  }();

  /// The path of a picture given as a data URI; null for anything else.
  ({String path, Uint8List bytes, String mime})? picture(String uri) {
    final known = _known(uri);
    if (known != null) return known;
    final decoded = decodeDataUri(uri);
    if (decoded == null) return null;
    return addPicture(uri, decoded.bytes, decoded.mime);
  }

  /// [key] names the picture, so each one is stored once.
  ({String path, Uint8List bytes, String mime})? addPicture(
    String key,
    Uint8List bytes,
    String mime,
  ) {
    final known = _known(key);
    if (known != null) return known;
    if (bytes.isEmpty || !_pictureTypes.contains(mime)) return null;
    final path =
        'Pictures/image${pictures.length + 1}.${extensionForMime(mime)}';
    pictures[path] = (bytes: bytes, mime: mime);
    _pictureByKey[key] = path;
    return (path: path, bytes: bytes, mime: mime);
  }

  ({String path, Uint8List bytes, String mime})? _known(String key) {
    final path = _pictureByKey[key];
    if (path == null) return null;
    final picture = pictures[path]!;
    return (path: path, bytes: picture.bytes, mime: picture.mime);
  }

  /// A footnote or endnote ([kind]) of the opened package, read like the
  /// body.
  Delta? note(String kind, String id, String? packageId) {
    final package = this.package;
    if (package == null || package.id != packageId) return null;
    return (_notes[kind] ??= _readNotes(package, kind))[id];
  }

  Map<String, Delta> _readNotes(DocxPackage package, String kind) {
    try {
      return DocxCodec(noteTables).notes(package, kind);
    } catch (_) {
      return const {};
    }
  }

  /// The part with the footnotes or endnotes.
  String? notePart(String kind) {
    final main = mainPart;
    if (main == null) return null;
    for (final relationship in _relationshipsOf(main).values) {
      if (relationship.hasType('${kind}s') && !relationship.external) {
        return DocxPackage.resolve(main, relationship.target);
      }
    }
    return null;
  }

  /// The picture [id] stands for in [part].
  String? picturePath(String part, String? id) {
    final relationship = id == null ? null : _relationshipsOf(part)[id];
    if (relationship == null ||
        relationship.external ||
        !relationship.hasType('image')) {
      return null;
    }
    return DocxPackage.resolve(part, relationship.target);
  }

  Map<String, Relationship> _relationshipsOf(String part) =>
      _relationships[part] ??= () {
        try {
          return {
            for (final relationship
                in package?.relationships(part) ?? const <Relationship>[])
              relationship.id: relationship,
          };
        } catch (_) {
          return <String, Relationship>{};
        }
      }();

  /// The languages Word checks the spelling in, as fo:language and the like.
  String languages() {
    final package = this.package;
    final main = mainPart;
    if (package == null || main == null) return '';
    try {
      final styles = _relationshipsOf(main).values
          .where((relationship) => relationship.hasType('styles'))
          .firstOrNull;
      if (styles == null || styles.external) return '';
      final root = package
          .xml(DocxPackage.resolve(main, styles.target))
          ?.rootElement;
      final language = _child(
        _child(_child(_child(root, 'docDefaults'), 'rPrDefault'), 'rPr'),
        'lang',
      );
      if (language == null) return '';
      final out = StringBuffer();
      for (final (attribute, script) in [
        ('val', null),
        ('eastAsia', 'asian'),
        ('bidi', 'complex'),
      ]) {
        final tag = _languageTag(
          language.getAttribute(attribute, namespaceUri: '*'),
        );
        if (tag == null) continue;
        out.write(
          script == null
              ? ' fo:language="${tag.language}"'
              : ' style:language-$script="${tag.language}"',
        );
        if (tag.country case final country?) {
          out.write(
            script == null
                ? ' fo:country="$country"'
                : ' style:country-$script="$country"',
          );
        }
      }
      return out.toString();
    } catch (_) {
      return '';
    }
  }

  static ({String language, String? country})? _languageTag(String? tag) {
    final parts = tag?.trim().split(RegExp('[-_]')) ?? const [];
    if (parts.isEmpty || !RegExp(r'^[a-zA-Z]{2,3}$').hasMatch(parts.first)) {
      return null;
    }
    return (
      language: parts.first.toLowerCase(),
      country: parts
          .skip(1)
          .where((part) => RegExp(r'^([a-zA-Z]{2}|\d{3})$').hasMatch(part))
          .firstOrNull
          ?.toUpperCase(),
    );
  }

  /// How the last section numbers its pages, from the body's own w:sectPr,
  /// which the editor keeps in the package.
  _Numbering lastNumbering() {
    final main = mainPart;
    final text = main == null ? null : package?.text(main);
    if (text == null || !text.contains('pgNumType')) return _unnumbered;
    try {
      final path = <String>[];
      var numbering = _unnumbered;
      for (final event in parseEvents(text)) {
        if (event is XmlStartElementEvent) {
          final local = event.localName;
          final inBody = path.length >= 2 && path[1] == 'body';
          if (inBody && path.length == 2 && local == 'sectPr') {
            numbering = _unnumbered;
          } else if (inBody &&
              path.length == 3 &&
              path[2] == 'sectPr' &&
              local == 'pgNumType') {
            numbering = OdtWriter._numbering(
              (name) => event.attributes
                  .where((attribute) => attribute.localName == name)
                  .firstOrNull
                  ?.value,
            );
          }
          if (!event.isSelfClosing) path.add(local);
        } else if (event is XmlEndElementEvent && path.isNotEmpty) {
          path.removeLast();
        }
      }
      return numbering;
    } catch (_) {
      return _unnumbered;
    }
  }
}

/// Automatic styles of one part: content.xml or styles.xml.
class _Styles {
  _Styles(this.prefix);

  final String prefix;
  final _xml = StringBuffer();
  final _paragraphs = <String, String>{};
  final _texts = <String, String>{};
  final _lists = <String, String>{};
  final _columns = <String, String>{};
  final _cells = <String, String>{};
  final _graphics = <String, String>{};
  var _tables = 0;

  String get xml => _xml.toString();

  String _define(
    String name,
    String family,
    String body, {
    String? parent,
    String? master,
  }) {
    _xml.write(
      '<style:style style:name="$name" style:family="$family"'
      '${parent == null ? '' : ' style:parent-style-name="${_attribute(parent)}"'}'
      '${master == null ? '' : ' style:master-page-name="${_attribute(master)}"'}'
      '>$body</style:style>',
    );
    return name;
  }

  String paragraph(String parent, String properties, {String? master}) {
    if (properties.isEmpty && master == null) return parent;
    return _paragraphs['$parent|$properties|${master ?? ''}'] ??= _define(
      '${prefix}P${_paragraphs.length + 1}',
      'paragraph',
      properties.isEmpty ? '' : '<style:paragraph-properties$properties/>',
      parent: parent,
      master: master,
    );
  }

  String? text(String properties) {
    if (properties.isEmpty) return null;
    return _texts[properties] ??= _define(
      '${prefix}T${_texts.length + 1}',
      'text',
      '<style:text-properties$properties/>',
    );
  }

  String table(
    double width, {
    required bool breakBefore,
    String? master,
    int? pageNumber,
  }) => _define(
    '${prefix}Table${++_tables}',
    'table',
    '<style:table-properties style:width="${odfPoints(width)}" '
        'table:align="left"${breakBefore ? ' fo:break-before="page"' : ''}'
        '${pageNumber == null ? '' : ' style:page-number="$pageNumber"'}/>',
    master: master,
  );

  String column(double width) {
    final value = odfPoints(width);
    return _columns[value] ??= _define(
      '${prefix}Column${_columns.length + 1}',
      'table-column',
      '<style:table-column-properties style:column-width="$value"/>',
    );
  }

  String cell({required bool bordered, String? fill}) =>
      _cells['$bordered|$fill'] ??= _define(
        '${prefix}Cell${_cells.length + 1}',
        'table-cell',
        '<style:table-cell-properties fo:padding-left="5.4pt" '
            'fo:padding-right="5.4pt" fo:padding-top="0pt" '
            'fo:padding-bottom="0pt" '
            'fo:border="${bordered ? '0.5pt solid #000000' : 'none'}"'
            '${fill == null ? '' : ' fo:background-color="#$fill"'}/>',
      );

  String graphic(String properties) => _graphics[properties] ??= _define(
    '${prefix}fr${_graphics.length + 1}',
    'graphic',
    '<style:graphic-properties$properties/>',
  );

  /// Bullets, numbers or check boxes, ten levels deep.
  String list(String kind) => _lists[kind] ??= () {
    final name = '${prefix}L${_lists.length + 1}';
    const bullets = ['•', '◦', '▪'];
    const numbers = ['1', 'a', 'i'];
    _xml.write('<text:list-style style:name="$name">');
    for (var level = 1; level <= 10; level++) {
      final left = odfPoints(36.0 * level);
      final properties =
          '<style:list-level-properties '
          'text:list-level-position-and-space-mode="label-alignment">'
          '<style:list-level-label-alignment text:label-followed-by="listtab" '
          'text:list-tab-stop-position="$left" fo:text-indent="-18pt" '
          'fo:margin-left="$left"/></style:list-level-properties>';
      if (kind == 'ordered') {
        _xml.write(
          '<text:list-level-style-number text:level="$level" '
          'style:num-suffix="." style:num-format="${numbers[(level - 1) % 3]}">'
          '$properties</text:list-level-style-number>',
        );
      } else {
        final bullet = switch (kind) {
          'checked' => '☑',
          'unchecked' => '☐',
          _ => bullets[(level - 1) % 3],
        };
        _xml.write(
          '<text:list-level-style-bullet text:level="$level" '
          'text:bullet-char="$bullet">$properties'
          '</text:list-level-style-bullet>',
        );
      }
    }
    _xml.write('</text:list-style>');
    return name;
  }();
}

class _OpenList {
  _OpenList(this.level, this.kind);

  final int level;
  final String kind;
  var itemOpen = false;
}

/// Spaces become `text:s` where OpenDocument would collapse or drop them.
class _TextEncoder {
  var _space = true;

  void object() => _space = false;

  String encode(String text, {bool atEnd = false}) {
    final out = StringBuffer();
    var spaces = 0;
    void flush() {
      if (spaces == 0) return;
      out.write(spaces == 1 ? '<text:s/>' : '<text:s text:c="$spaces"/>');
      spaces = 0;
    }

    final runes = text.runes.toList();
    for (var index = 0; index < runes.length; index++) {
      final rune = runes[index];
      if (rune == 0x20) {
        if (_space || spaces > 0 || atEnd && index == runes.length - 1) {
          spaces++;
        } else {
          out.write(' ');
        }
        _space = true;
      } else if (rune == 0x09) {
        flush();
        out.write('<text:tab/>');
        _space = true;
      } else if (rune == 0x2028 || rune == 0x0A || rune == 0x0B) {
        flush();
        out.write('<text:line-break/>');
        _space = true;
      } else if (rune >= 0x20 && rune <= 0xD7FF ||
          rune >= 0xE000 && rune <= 0xFFFD ||
          rune >= 0x10000 && rune <= 0x10FFFF) {
        flush();
        out.write(switch (rune) {
          0x26 => '&amp;',
          0x3C => '&lt;',
          0x3E => '&gt;',
          _ => String.fromCharCode(rune),
        });
        _space = false;
      }
    }
    flush();
    return out.toString();
  }
}

/// Writes blocks of the body, a header or footer, or a note, and the cells
/// of their tables.
class _StoryWriter {
  _StoryWriter(
    this.document,
    this.styles,
    this.place,
    this.tables, {
    this.part,
    this.depth = 0,
  });

  final _Document document;
  final _Styles styles;
  final _Place place;

  /// Where the tables of the content are.
  final TableStore tables;

  /// The Word part whose relationships protected content uses.
  final String? part;

  /// Tables around the content.
  final int depth;
  final _out = StringBuffer();
  final _lists = <_OpenList>[];
  var _pendingBreak = false;
  String? _pendingMaster;
  int? _pendingNumber;

  String get _parent => depth > 0
      ? 'Standard'
      : switch (place) {
          _Place.header => 'Header',
          _Place.footer => 'Footer',
          _Place.footnote => 'Footnote',
          _Place.endnote => 'Endnote',
          _Place.body => 'Standard',
        };

  bool get _inHeaderFooter => place == _Place.header || place == _Place.footer;

  /// The next block starts a page with [master], numbered [pageNumber] when
  /// the section restarts its numbering.
  void startSection(String master, {int? pageNumber}) {
    _closeLists();
    _pendingMaster = master;
    _pendingNumber = pageNumber;
    _pendingBreak = false;
  }

  void write(List<DocumentBlock> blocks) {
    for (final (index, block) in blocks.indexed) {
      final previous = index > 0 ? blocks[index - 1] : null;
      final next = index + 1 < blocks.length ? blocks[index + 1] : null;
      switch (block) {
        case LineBlock(list: final String _):
          _listLine(block, following: next);
        case LineBlock():
          _closeLists();
          // Paragraphs of a Word style with contextual spacing add no space
          // between one another, as in the editor.
          final group = block.attributes[HiddenAttributes.contextualGroup];
          _line(
            block,
            collapseBefore: group != null && _group(previous) == group,
            collapseAfter: group != null && _group(next) == group,
          );
        case EmbedBlock():
          _closeLists();
          _embedBlock(block);
      }
    }
  }

  static Object? _group(DocumentBlock? block) => block is LineBlock
      ? block.attributes[HiddenAttributes.contextualGroup]
      : null;

  /// Every story ends with a paragraph, which cells and the body need.
  String finish() {
    _closeLists();
    if (_out.isEmpty || _pendingBreak || _pendingMaster != null) {
      _writeParagraph(null, const [], heading: null);
    }
    return _out.toString();
  }

  void _embedBlock(EmbedBlock block) {
    switch (block.type) {
      case EmbedTypes.table:
        final String id;
        try {
          id = tableIdOf(block.value);
        } catch (_) {
          return;
        }
        final table = tables[id];
        if (table != null) _table(table);
      case EmbedTypes.opaqueBlock:
        final content = _opaque(block.value);
        if (content == null || content.hidden) return;
        if (content.text.isEmpty) {
          _writeParagraph(null, [
            EmbedPiece(EmbedTypes.opaqueInline, block.value, const {}),
          ], heading: null);
          return;
        }
        for (final line in content.text.split('\n')) {
          _writeParagraph(null, [TextPiece(line, const {})], heading: null);
        }
    }
  }

  static OpaqueContent? _opaque(Object? value) {
    try {
      return OpaqueContent.decode(value);
    } catch (_) {
      return null;
    }
  }

  /// Page breaks inside a line split it: the text after one starts the next
  /// page.
  void _line(
    LineBlock line, {
    bool inList = false,
    bool collapseBefore = false,
    bool collapseAfter = false,
  }) {
    final segments = <List<InlinePiece>>[[]];
    for (final piece in line.pieces) {
      if (piece is EmbedPiece && piece.type == EmbedTypes.pageBreak) {
        segments.add([]);
      } else {
        segments.last.add(piece);
      }
    }
    var bookmarks = true;
    for (final (index, segment) in segments.indexed) {
      if (index > 0 && place == _Place.body && depth == 0) {
        _pendingBreak = true;
      }
      if (segment.isEmpty && segments.length > 1) continue;
      _writeParagraph(
        line,
        segment,
        heading: line.heading,
        inList: inList,
        bookmarks: bookmarks,
        collapseBefore: collapseBefore,
        collapseAfter: collapseAfter,
      );
      bookmarks = false;
    }
  }

  void _listLine(LineBlock line, {DocumentBlock? following}) {
    final kind = line.list!;
    final level = line.indent.clamp(0, 9);
    while (_lists.isNotEmpty && _lists.last.level > level) {
      _closeList();
    }
    if (_lists.isNotEmpty &&
        _lists.last.level == level &&
        _lists.last.kind != kind) {
      _closeList();
    }
    if (_lists.isNotEmpty && _lists.last.level == level) {
      _closeItem(_lists.last);
    } else {
      for (
        var next = _lists.isEmpty ? 0 : _lists.last.level + 1;
        next <= level;
        next++
      ) {
        if (_lists.isNotEmpty && !_lists.last.itemOpen) {
          _out.write('<text:list-item>');
          _lists.last.itemOpen = true;
        }
        final inherited = _lists.isNotEmpty && _lists.last.kind == kind;
        _out.write(
          inherited
              ? '<text:list>'
              : '<text:list text:style-name="${styles.list(kind)}">',
        );
        _lists.add(_OpenList(next, kind));
      }
    }
    _out.write('<text:list-item>');
    _lists.last.itemOpen = true;
    // Like the editor and Word's List Paragraph style, a list adds space
    // after its last item only; numbered headings keep their own.
    final spaced = line.heading != null;
    _line(
      line,
      inList: true,
      collapseBefore: !spaced,
      collapseAfter:
          !spaced && following is LineBlock && following.list != null,
    );
  }

  void _closeItem(_OpenList list) {
    if (!list.itemOpen) return;
    _out.write('</text:list-item>');
    list.itemOpen = false;
  }

  void _closeList() {
    _closeItem(_lists.removeLast());
    _out.write('</text:list>');
  }

  void _closeLists() {
    while (_lists.isNotEmpty) {
      _closeList();
    }
  }

  void _writeParagraph(
    LineBlock? line,
    List<InlinePiece> pieces, {
    required int? heading,
    bool inList = false,
    bool bookmarks = false,
    bool collapseBefore = false,
    bool collapseAfter = false,
  }) {
    final level = heading?.clamp(1, 10);
    final (master, number) = _takeMaster();
    final style = styles.paragraph(
      level == null ? _parent : 'Heading_20_$level',
      '${_paragraphProperties(line, inList: inList, collapseBefore: collapseBefore, collapseAfter: collapseAfter)}'
      '${number == null ? '' : ' style:page-number="$number"'}',
      master: master,
    );
    final tag = level == null ? 'text:p' : 'text:h';
    _out.write(
      '<$tag text:style-name="${_attribute(style)}"'
      '${level == null ? '' : ' text:outline-level="$level"'}>'
      '${bookmarks && line != null ? _bookmarks(line) : ''}'
      '${_inlines(pieces)}</$tag>',
    );
  }

  /// List items take the list's spacing, not their own, as in the editor;
  /// [collapseBefore] and [collapseAfter] take the space away.
  String _paragraphProperties(
    LineBlock? line, {
    required bool inList,
    required bool collapseBefore,
    required bool collapseAfter,
  }) {
    final out = StringBuffer();
    if (line != null) {
      switch (line.align) {
        case 'center':
          out.write(' fo:text-align="center"');
        case 'right':
          out.write(' fo:text-align="end"');
        case 'justify':
          out.write(' fo:text-align="justify"');
      }
      if (!inList && line.indent > 0) {
        out.write(
          ' fo:margin-left="${odfPoints(36.0 * math.min(line.indent, 20))}"',
        );
      }
      if (line.indentRight case final right?) {
        out.write(' fo:margin-right="${odfPoints(right)}"');
      }
      if (line.firstLine case final first? when !inList) {
        out.write(' fo:text-indent="${odfPoints(first)}"');
      }
      final before = collapseBefore ? 0.0 : (inList ? null : line.spaceBefore);
      final after = collapseAfter ? 0.0 : (inList ? null : line.spaceAfter);
      if (before != null) {
        out.write(' fo:margin-top="${odfPoints(math.max(before, 0))}"');
      }
      if (after != null) {
        out.write(' fo:margin-bottom="${odfPoints(math.max(after, 0))}"');
      }
      if (line.lineHeight case final height? when height > 0) {
        out.write(' fo:line-height="${(height * 100).round()}%"');
      }
      if (line.attributes['direction'] == 'rtl') {
        out.write(' style:writing-mode="rl-tb"');
      }
    }
    if (_pendingBreak) {
      out.write(' fo:break-before="page"');
      _pendingBreak = false;
    }
    return out.toString();
  }

  String _bookmarks(LineBlock line) {
    final raw = line.attributes[HiddenAttributes.bookmarks];
    if (raw is! String) return '';
    final List<Object?> names;
    try {
      names = jsonDecode(raw) as List<Object?>;
    } catch (_) {
      return '';
    }
    return [
      for (final name in names)
        if (name is String &&
            name.trim().isNotEmpty &&
            document.bookmarks.add(name))
          '<text:bookmark text:name="${_attribute(name)}"/>',
    ].join();
  }

  String _inlines(List<InlinePiece> pieces) {
    final encoder = _TextEncoder();
    final out = StringBuffer();
    String? openLink;
    for (final (index, piece) in pieces.indexed) {
      final link = _safeLink(piece.attributes['link']);
      if (link != openLink) {
        if (openLink != null) out.write('</text:a>');
        if (link != null) out.write(_linkStart(link));
        openLink = link;
      }
      out.write(switch (piece) {
        TextPiece() => _span(
          piece.attributes,
          encoder.encode(piece.text, atEnd: index == pieces.length - 1),
        ),
        EmbedPiece() => _embed(piece, encoder),
      });
    }
    if (openLink != null) out.write('</text:a>');
    return out.toString();
  }

  static String _linkStart(String link) =>
      '<text:a xlink:type="simple" xlink:href="${_attribute(link)}" '
      'text:style-name="Internet_20_link" '
      'text:visited-style-name="Visited_20_Internet_20_Link">';

  static String? _safeLink(Object? link) {
    if (link is! String) return null;
    if (link.startsWith('#')) return link.length > 1 ? link : null;
    return safeLinkTarget(link);
  }

  String _span(Map<String, dynamic> attributes, String content) {
    if (content.isEmpty) return '';
    final style = styles.text(_textProperties(attributes));
    return style == null
        ? content
        : '<text:span text:style-name="$style">$content</text:span>';
  }

  String _textProperties(Map<String, dynamic> attributes) {
    final out = StringBuffer();
    if (attributes['bold'] == true) {
      out.write(_inEveryScript('font-weight', 'bold'));
    }
    if (attributes['italic'] == true) {
      out.write(_inEveryScript('font-style', 'italic'));
    }
    if (attributes['underline'] == true) {
      out.write(
        ' style:text-underline-style="solid" '
        'style:text-underline-width="auto" '
        'style:text-underline-color="font-color"',
      );
    }
    if (attributes['strike'] == true) {
      out.write(
        ' style:text-line-through-style="solid" '
        'style:text-line-through-type="single"',
      );
    }
    final size = _size(attributes['size']);
    if (size != null) {
      out.write(_inEveryScript('font-size', odfPoints(size)));
    }
    final font = OdtWriter._font(attributes['font']);
    if (font != null) {
      document.fonts.add(font);
      out.write(_fontNames(font));
    }
    if (_hex(attributes['color']) case final color?) {
      out.write(' fo:color="#$color"');
    }
    if (_hex(attributes['background']) case final background?) {
      out.write(' fo:background-color="#$background"');
    }
    switch (attributes['script']) {
      case 'super':
        out.write(' style:text-position="super 58%"');
      case 'sub':
        out.write(' style:text-position="sub 58%"');
    }
    return out.toString();
  }

  static double? _size(Object? value) {
    final size = switch (value) {
      'small' => 9.0,
      'large' => 18.0,
      'huge' => 28.0,
      _ => pointsValue(value),
    };
    return size != null && size.isFinite && size >= 1 && size <= 1638
        ? size
        : null;
  }

  static String? _hex(Object? value) {
    if (value is! String) return null;
    var hex = value.startsWith('#') ? value.substring(1) : value;
    if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
    if (hex.length == 8) hex = hex.substring(2);
    return RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex) ? hex.toLowerCase() : null;
  }

  String _embed(EmbedPiece piece, _TextEncoder encoder) {
    switch (piece.type) {
      case EmbedTypes.image:
        final frame = _frame(piece);
        if (frame.isNotEmpty) encoder.object();
        return frame;
      case EmbedTypes.pageNumber:
        encoder.object();
        final value = piece.value;
        return _span(
          piece.attributes,
          _pageNumber(value is String ? value : null),
        );
      case EmbedTypes.opaqueInline:
        final content = _opaque(piece.value);
        if (content == null || content.hidden) return '';
        return _protected(content, piece.attributes, encoder);
      default:
        return '';
    }
  }

  /// Word content the editor keeps as it came: fields and notes become their
  /// OpenDocument kind; the rest keeps its text, its picture or a placeholder
  /// that shows something was there.
  String _protected(
    OpaqueContent content,
    Map<String, dynamic> attributes,
    _TextEncoder encoder,
  ) {
    switch (fieldNameOf(content.xml)) {
      case 'PAGE':
        encoder.object();
        return _span(attributes, _pageNumber(_instruction(content.xml)));
      case 'NUMPAGES' || 'SECTIONPAGES':
        encoder.object();
        return _span(attributes, '<text:page-count>1</text:page-count>');
      case 'HYPERLINK':
        final text = _span(attributes, encoder.encode(content.text));
        final link = attributes['link'] == null
            ? _hyperlink(_instruction(content.xml))
            : null;
        return link == null || text.isEmpty
            ? text
            : '${_linkStart(link)}$text</text:a>';
      case _?:
        // Fields like INCLUDEPICTURE show a picture.
        final picture = _hasPicture(content.xml)
            ? _preview(_fragment(content.xml), content)
            : '';
        if (picture.isNotEmpty) encoder.object();
        return '$picture${_span(attributes, encoder.encode(content.text))}';
    }
    if (content.label == OpaqueLabels.note) {
      final note = _note(content);
      if (note != null) {
        encoder.object();
        return note;
      }
      return _span(attributes, encoder.encode(content.text));
    }
    return _object(content, attributes, encoder);
  }

  String _object(
    OpaqueContent content,
    Map<String, dynamic> attributes,
    _TextEncoder encoder,
  ) {
    final xml = content.xml;
    // A note's own mark only means something inside the note, where
    // OpenDocument writes it.
    if (RegExp(r'<w:(?:footnote|endnote)Ref\b').hasMatch(xml)) return '';
    final root =
        xml.contains('oMath') || xml.contains('sym') || _hasPicture(xml)
        ? _fragment(xml)
        : null;
    final top = root?.childElements.firstOrNull?.name.local;
    if (content.label == OpaqueLabels.equation ||
        top == 'oMath' ||
        top == 'oMathPara') {
      final math = _math(root, attributes, encoder);
      if (math.isNotEmpty) return math;
    }
    final symbol = _symbol(root, attributes, encoder);
    if (symbol.isNotEmpty) return symbol;
    final picture = _preview(root, content);
    if (picture.isNotEmpty) {
      encoder.object();
      return '$picture${_span(attributes, encoder.encode(content.text))}';
    }
    if (content.text.isNotEmpty) {
      return _span(attributes, encoder.encode(content.text));
    }
    // The editor shows nothing for these in headers and footers.
    if (_inHeaderFooter) return '';
    encoder.object();
    return _span(attributes, _placeholder(content.label));
  }

  /// The text of a Word equation, with its superscripts and subscripts.
  String _math(
    XmlElement? root,
    Map<String, dynamic> attributes,
    _TextEncoder encoder,
  ) {
    final runs = <({String text, String? script})>[];
    void add(String text, String? script) {
      if (text.isEmpty) return;
      if (runs.isNotEmpty && runs.last.script == script) {
        runs.last = (text: runs.last.text + text, script: script);
      } else {
        runs.add((text: text, script: script));
      }
    }

    String plain(XmlElement? element) => [
      for (final text in element?.descendantElements ?? <XmlElement>[])
        if (text.name.local == 't') text.innerText,
    ].join();

    void walk(XmlElement? element, String? script, int depth) {
      if (element == null || depth > 64) return;
      final local = element.name.local;
      if (local.endsWith('Pr')) return;
      void each(String name, String? script) =>
          walk(_child(element, name), script, depth + 1);
      String? setting(String name) => _child(
        _child(element, '${local}Pr'),
        name,
      )?.getAttribute('val', namespaceUri: '*');
      void grouped(String name) {
        final part = _child(element, name);
        final long = plain(part).runes.length > 1;
        if (long) add('(', script);
        walk(part, script, depth + 1);
        if (long) add(')', script);
      }

      switch (local) {
        case 't':
          add(element.innerText, script);
        case 'sSup' || 'sSub' || 'sSubSup':
          each('e', script);
          each('sub', 'sub');
          each('sup', 'super');
        case 'sPre':
          each('sub', 'sub');
          each('sup', 'super');
          each('e', script);
        case 'f':
          grouped('num');
          add('/', script);
          grouped('den');
        case 'rad':
          each('deg', 'super');
          add('√', script);
          grouped('e');
        case 'd':
          add(setting('begChr') ?? '(', script);
          for (final (index, item)
              in element.childElements
                  .where((child) => child.name.local == 'e')
                  .indexed) {
            if (index > 0) add(setting('sepChr') ?? '|', script);
            walk(item, script, depth + 1);
          }
          add(setting('endChr') ?? ')', script);
        case 'nary':
          add(setting('chr') ?? '∫', script);
          each('sub', 'sub');
          each('sup', 'super');
          each('e', script);
        case 'oMathPara' || 'eqArr':
          for (final (index, line)
              in element.childElements
                  .where((child) => !child.name.local.endsWith('Pr'))
                  .indexed) {
            if (index > 0) add(' ', script);
            walk(line, script, depth + 1);
          }
        default:
          for (final child in element.childElements) {
            walk(child, script, depth + 1);
          }
      }
    }

    walk(root, null, 0);
    return [
      for (final run in runs)
        _span(
          run.script == null
              ? attributes
              : {...attributes, 'script': run.script},
          encoder.encode(run.text),
        ),
    ].join();
  }

  /// A character of a symbol font (w:sym).
  String _symbol(
    XmlElement? root,
    Map<String, dynamic> attributes,
    _TextEncoder encoder,
  ) {
    final symbol = _descendant(root, 'sym');
    final code = int.tryParse(
      symbol?.getAttribute('char', namespaceUri: '*') ?? '',
      radix: 16,
    );
    if (code == null || code < 0x20 || code > 0xFFFD) return '';
    return _span({
      ...attributes,
      'font': ?symbol?.getAttribute('font', namespaceUri: '*'),
    }, encoder.encode(String.fromCharCode(code)));
  }

  /// The picture Word shows for an object, a legacy picture or a shape.
  String _preview(XmlElement? root, OpaqueContent content) {
    final package = document.package;
    final part = this.part;
    if (root == null ||
        package == null ||
        part == null ||
        content.packageId != package.id) {
      return '';
    }
    for (final element in root.descendantElements) {
      final local = element.name.local;
      if (local != 'imagedata' && local != 'blip') continue;
      final vml = local == 'imagedata';
      final style = (element.parentElement?.getAttribute('style') ?? '')
          .replaceAll(' ', '')
          .toLowerCase();
      // Floating shapes of headers, like watermarks, would push the text.
      if (_inHeaderFooter &&
          (style.contains('position:absolute') ||
              _descendant(root, 'anchor') != null)) {
        return '';
      }
      final path = document.picturePath(
        part,
        vml
            ? element.getAttribute('id', namespaceUri: '*') ??
                  element.getAttribute('relid', namespaceUri: '*')
            : element.getAttribute('embed', namespaceUri: '*'),
      );
      final bytes = path == null ? null : package.parts[path];
      if (path == null || bytes == null) continue;

      final object = _descendant(root, 'object');
      final extent = _descendant(root, 'extent');
      double? twips(XmlElement? element, String name) {
        final value = double.tryParse(
          element?.getAttribute(name, namespaceUri: '*') ?? '',
        );
        return value == null ? null : value / 20;
      }

      double? emus(String name) {
        final value = double.tryParse(extent?.getAttribute(name) ?? '');
        return value == null ? null : value / 12700;
      }

      var width = _positive(
        vml
            ? _cssLength(style, 'width') ?? twips(object, 'dxaOrig')
            : emus('cx'),
      );
      var height = _positive(
        vml
            ? _cssLength(style, 'height') ?? twips(object, 'dyaOrig')
            : emus('cy'),
      );

      final crop = vml ? _vmlCrop(element) : _drawingCrop(element);
      var picture = (bytes: bytes, mime: mimeForPath(path));
      if (crop.any((value) => value > 0)) {
        final cropped = cropPicture(
          bytes,
          picture.mime,
          left: crop[0],
          top: crop[1],
          right: crop[2],
          bottom: crop[3],
        );
        if (cropped != null) {
          picture = cropped;
        } else if (width != null &&
            height != null &&
            crop[0] + crop[2] < 1 &&
            crop[1] + crop[3] < 1) {
          // The whole picture, made to fit the box without stretching it.
          final whole = (
            width: width / (1 - crop[0] - crop[2]),
            height: height / (1 - crop[1] - crop[3]),
          );
          final scale = math.min(width / whole.width, height / whole.height);
          width = whole.width * scale;
          height = whole.height * scale;
        }
      }
      final stored = document.addPicture(
        '${package.id}/$path/${crop.join(',')}',
        picture.bytes,
        picture.mime,
      );
      if (stored == null) continue;
      return _pictureFrame(stored, width: width, height: height);
    }
    return '';
  }

  static bool _hasPicture(String xml) =>
      xml.contains('imagedata') || xml.contains('blip');

  static double? _cssLength(String style, String name) =>
      odfLength(RegExp('(?:^|;)$name:([^;]+)').firstMatch(style)?.group(1));

  static double _cropFraction(double? value) =>
      value != null && value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0;

  /// Left, top, right and bottom cuts of v:imagedata: fractions, or 65536ths
  /// when they end in `f`.
  static List<double> _vmlCrop(XmlElement imageData) => [
    for (final side in ['left', 'top', 'right', 'bottom'])
      switch (imageData.getAttribute('crop$side')?.trim()) {
        final String text when text.endsWith('f') => _cropFraction(
          (double.tryParse(text.substring(0, text.length - 1)) ?? 0) / 65536,
        ),
        final text => _cropFraction(double.tryParse(text ?? '')),
      },
  ];

  /// Left, top, right and bottom cuts of a:srcRect, in 100000ths.
  static List<double> _drawingCrop(XmlElement blip) {
    final source = _child(blip.parentElement, 'srcRect');
    return [
      for (final side in ['l', 't', 'r', 'b'])
        _cropFraction(
          (double.tryParse(source?.getAttribute(side) ?? '') ?? 0) / 100000,
        ),
    ];
  }

  /// LibreOffice shows a placeholder field in grey, as the editor shows
  /// protected content.
  static String _placeholder(String? label) {
    final (type, name) = switch (label) {
      OpaqueLabels.chart => ('object', 'chart'),
      OpaqueLabels.diagram => ('object', 'diagram'),
      OpaqueLabels.equation => ('object', 'equation'),
      OpaqueLabels.textBox => ('text-box', 'text box'),
      OpaqueLabels.tableOfContents => ('text', 'table of contents'),
      OpaqueLabels.coverPage => ('text', 'cover page'),
      OpaqueLabels.bibliography => ('text', 'bibliography'),
      OpaqueLabels.special => ('text', 'special content'),
      null || OpaqueLabels.object || OpaqueLabels.note => ('object', 'object'),
      final other => ('text', other),
    };
    return '<text:placeholder text:placeholder-type="$type">'
        '&lt;${escapeXmlText(stripInvalidXmlChars(name))}&gt;'
        '</text:placeholder>';
  }

  /// The instruction of a Word field, as Word shows it.
  static String? _instruction(String xml) {
    final simple = RegExp(r'w:instr="([^"]*)"').firstMatch(xml)?.group(1);
    final complex = RegExp(
      r'<w:instrText[^>]*>([^<]*)</w:instrText>',
    ).allMatches(xml).map((match) => match.group(1)).join();
    final instruction = defaultEntityMapping.decode(simple ?? complex).trim();
    return instruction.isEmpty ? null : instruction;
  }

  /// The address of a HYPERLINK field: a web address, a bookmark (`\l`) or
  /// both.
  static String? _hyperlink(String? instruction) {
    if (instruction == null) return null;
    final words = [
      for (final match in RegExp(r'"([^"]*)"|(\S+)').allMatches(instruction))
        match[1] ?? match[2]!,
    ];
    String? address;
    String? bookmark;
    for (var index = 1; index < words.length; index++) {
      final word = words[index].toLowerCase();
      if (const {r'\l', r'\o', r'\t'}.contains(word)) {
        final value = index + 1 < words.length ? words[++index] : null;
        if (word == r'\l') bookmark = value;
      } else if (!word.startsWith(r'\')) {
        address ??= words[index];
      }
    }
    final anchor = bookmark == null || bookmark.isEmpty ? '' : '#$bookmark';
    return address == null
        ? _safeLink(anchor)
        : safeLinkTarget('$address$anchor');
  }

  /// A PAGE field; without a format of its own it numbers pages as their
  /// page style does.
  static String _pageNumber(String? instruction) {
    final format = RegExp(r'\\\*\s*(\w+)')
        .allMatches(instruction ?? '')
        .map((match) => match[1]!)
        .map(
          (name) => switch (name.toLowerCase()) {
            'roman' => name == 'roman' ? 'i' : 'I',
            'alphabetic' => name == 'alphabetic' ? 'a' : 'A',
            'arabic' => '1',
            _ => null,
          },
        )
        .nonNulls
        .firstOrNull;
    return '<text:page-number text:select-page="current"'
        '${format == null ? '' : ' style:num-format="$format"'}>1'
        '</text:page-number>';
  }

  String? _note(OpaqueContent content) {
    if (place != _Place.body) return null;
    final reference = RegExp(
      r'<w:(footnote|endnote)Reference\b[^>]*?\bw:id="(-?\d+)"',
    ).firstMatch(content.xml);
    if (reference == null) return null;
    final kind = reference[1]!;
    final note = document.note(kind, reference[2]!, content.packageId);
    if (note == null) return null;
    final endnote = kind == 'endnote';
    final number = endnote ? ++document.endnotes : ++document.footnotes;
    final body = (_StoryWriter(
      document,
      styles,
      endnote ? _Place.endnote : _Place.footnote,
      document.noteTables,
      part: document.notePart(kind),
    )..write(documentBlocks(note))).finish();
    return '<text:note text:id="${endnote ? 'edn' : 'ftn'}$number" '
        'text:note-class="$kind"><text:note-citation>$number</text:note-citation>'
        '<text:note-body>$body</text:note-body></text:note>';
  }

  String _frame(EmbedPiece piece) {
    final value = piece.value;
    if (value is! String) return '';
    final picture = document.picture(value);
    if (picture == null) return '';
    return _pictureFrame(
      picture,
      width: _positive(pointsValue(piece.attributes['width'])),
      height: _positive(pointsValue(piece.attributes['height'])),
      drawing: _fragment(piece.attributes[HiddenAttributes.drawing]),
    );
  }

  /// A picture in the text, or one Word floats in a header or footer, at the
  /// place the editor draws it; [drawing] is Word's own description of it.
  String _pictureFrame(
    ({String path, Uint8List bytes, String mime}) picture, {
    double? width,
    double? height,
    XmlElement? drawing,
  }) {
    final pixels = imagePixelSize(picture.bytes);
    final natural = pixels == null
        ? null
        : (width: pixels.width * 0.75, height: pixels.height * 0.75);
    final ratio = natural == null || natural.width <= 0 || natural.height <= 0
        ? 1.0
        : natural.height / natural.width;
    var w = width ?? (height != null ? height / ratio : natural?.width ?? 72);
    var h = height ?? w * ratio;
    final anchor = _inHeaderFooter ? _descendant(drawing, 'anchor') : null;
    final maxWidth = document.look.contentWidth;
    if (anchor == null && w > maxWidth && maxWidth > 0) {
      h = h * maxWidth / w;
      w = maxWidth;
    }
    final floating = anchor == null ? null : _floating(anchor, h);
    final name = 'Image${++document.frameCount}';
    return '<draw:frame draw:style-name="${styles.graphic(floating?.properties ?? _inlinePicture)}" '
        'draw:name="$name" '
        'text:anchor-type="${floating == null ? 'as-char' : 'paragraph'}"'
        '${floating?.position ?? ''} svg:width="${odfPoints(w)}" '
        'svg:height="${odfPoints(h)}" draw:z-index="0">'
        '<draw:image xlink:href="${picture.path}" xlink:type="simple" '
        'xlink:show="embed" xlink:actuate="onLoad" '
        'draw:mime-type="${picture.mime}"/>${_altText(drawing)}</draw:frame>';
  }

  /// Word's place for a floating picture ([anchor] is its wp:anchor), as the
  /// header painter computes it.
  ({String properties, String position}) _floating(
    XmlElement anchor,
    double height,
  ) {
    ({String from, String? align, double offset}) position(String axis) {
      final element = _child(anchor, axis);
      final align = _child(element, 'align')?.innerText.trim();
      final offset = double.tryParse(
        _child(element, 'posOffset')?.innerText.trim() ?? '',
      );
      return (
        from: element?.getAttribute('relativeFrom') ?? 'margin',
        align: align == null || align.isEmpty ? null : align,
        offset: offset == null || !offset.isFinite ? 0 : offset / 12700,
      );
    }

    final horizontal = position('positionH');
    final horizontalPosition = switch (horizontal.align) {
      'left' || 'inside' => 'left',
      'center' => 'center',
      'right' || 'outside' => 'right',
      _ => 'from-left',
    };
    final horizontalArea = switch (horizontal.from) {
      'page' => 'page',
      'leftMargin' => 'page-start-margin',
      'rightMargin' => 'page-end-margin',
      _ => 'page-content',
    };

    final vertical = position('positionV');
    final look = document.look;
    final margins = look.margins;
    final range = switch (vertical.from) {
      'page' => (0.0, look.pageHeight),
      'margin' => (margins.top, look.pageHeight - margins.bottom),
      'topMargin' => (0.0, margins.top),
      'bottomMargin' => (look.pageHeight - margins.bottom, look.pageHeight),
      _ => null,
    };
    final String verticalPosition;
    final String verticalArea;
    double? y;
    if (range case (final top, final bottom)) {
      // OpenDocument measures its page area from the header down, so the
      // place is given from the page's edge.
      verticalPosition = 'from-top';
      verticalArea = 'page';
      y = switch (vertical.align) {
        'center' => (top + bottom - height) / 2,
        'bottom' || 'outside' => bottom - height,
        'top' || 'inside' => top,
        _ => top + vertical.offset,
      };
    } else {
      verticalArea = 'paragraph';
      verticalPosition = switch (vertical.align) {
        'top' || 'inside' => 'top',
        'center' => 'middle',
        'bottom' || 'outside' => 'bottom',
        _ => 'from-top',
      };
      if (verticalPosition == 'from-top') y = vertical.offset;
    }

    final behind = const {
      '1',
      'true',
      'on',
    }.contains(anchor.getAttribute('behindDoc'));
    final wrap = behind
        ? 'run-through'
        : switch (anchor.childElements
              .map((element) => element.name.local)
              .where((name) => name.startsWith('wrap'))
              .firstOrNull) {
            'wrapSquare' => 'parallel',
            'wrapTight' || 'wrapThrough' => 'dynamic',
            'wrapTopAndBottom' => 'none',
            _ => 'run-through',
          };
    return (
      properties:
          ' style:wrap="$wrap"'
          '${wrap == 'run-through' ? ' style:run-through="${behind ? 'background' : 'foreground'}"' : ''}'
          ' style:vertical-pos="$verticalPosition" '
          'style:vertical-rel="$verticalArea" '
          'style:horizontal-pos="$horizontalPosition" '
          'style:horizontal-rel="$horizontalArea" style:flow-with-text="false"',
      position:
          '${horizontalPosition == 'from-left' ? ' svg:x="${odfPoints(horizontal.offset)}"' : ''}'
          '${y == null ? '' : ' svg:y="${odfPoints(y)}"'}',
    );
  }

  /// The title and description Word keeps for screen readers.
  static String _altText(XmlElement? drawing) {
    final properties = _descendant(drawing, 'docPr');
    if (properties == null) return '';
    String part(String attribute, String element) {
      final text = stripInvalidXmlChars(
        properties.getAttribute(attribute) ?? '',
      ).trim();
      return text.isEmpty
          ? ''
          : '<svg:$element>${escapeXmlText(text)}</svg:$element>';
    }

    return '${part('title', 'title')}${part('descr', 'desc')}';
  }

  void _table(TableModel table) {
    if (depth >= 32 || table.rows.isEmpty) return;
    if (!document.tablesInProgress.add(table)) return;
    try {
      _out.write(_tableXml(table));
    } finally {
      document.tablesInProgress.remove(table);
    }
  }

  String _tableXml(TableModel table) {
    final rows = table.rows;
    final starts = [
      for (final row in rows)
        [
          for (final (index, _) in row.cells.indexed)
            row.cells
                .take(index)
                .fold<int>(0, (sum, cell) => sum + math.max(cell.gridSpan, 1)),
        ],
    ];
    final columns = [
      for (final row in rows)
        row.cells.fold<int>(0, (sum, cell) => sum + math.max(cell.gridSpan, 1)),
    ].fold<int>(1, math.max);
    // Word's grid may have more columns than the rows use; the cells take
    // the first ones, as in the editor.
    var widths = [
      for (final width in table.columnWidths.take(columns)) width / 20,
    ];
    if (widths.length != columns ||
        widths.any((width) => !width.isFinite || width <= 0)) {
      widths = List.filled(
        columns,
        math.max(document.look.contentWidth, 72.0) / columns,
      );
    }

    // Cells that continue a vertical merge from above become covered cells.
    final covered = <(int, int)>{};
    final rowSpans = <(int, int), int>{};
    for (final (r, row) in rows.indexed) {
      for (final (c, cell) in row.cells.indexed) {
        if (cell.verticalMerge != VerticalMerge.restart) continue;
        var span = 1;
        while (r + span < rows.length) {
          final next = rows[r + span].cells.indexed.where(
            (entry) =>
                starts[r + span][entry.$1] == starts[r][c] &&
                entry.$2.verticalMerge == VerticalMerge.continuation,
          );
          if (next.isEmpty) break;
          covered.add((r + span, next.first.$1));
          span++;
        }
        if (span > 1) rowSpans[(r, c)] = span;
      }
    }

    final (master, number) = _takeMaster();
    final out = StringBuffer(
      '<table:table table:name="Table${++document.tableCount}" '
      'table:style-name="${styles.table(widths.fold(0, (sum, width) => sum + width), breakBefore: _takeBreak(), master: master, pageNumber: number)}">',
    );
    for (final width in widths) {
      out.write(
        '<table:table-column table:style-name="${styles.column(width)}"/>',
      );
    }
    var headerRows = 0;
    while (headerRows < rows.length &&
        (rows[headerRows].propertiesXml?.contains('tblHeader') ?? false)) {
      headerRows++;
    }
    for (final (r, row) in rows.indexed) {
      if (r == 0 && headerRows > 0) out.write('<table:table-header-rows>');
      out.write('<table:table-row>');
      if (row.cells.isEmpty) out.write('<table:table-cell/>');
      for (final (c, cell) in row.cells.indexed) {
        final span = math.max(cell.gridSpan, 1);
        if (covered.contains((r, c))) {
          out.write('<table:covered-table-cell/>' * span);
          continue;
        }
        final rowSpan = rowSpans[(r, c)] ?? 1;
        final content = _StoryWriter(
          document,
          styles,
          place,
          tables,
          part: part,
          depth: depth + 1,
        )..write(documentBlocks(cell.controller.document.toDelta()));
        final fill = cell.fill == null ? null : _colorHex(cell.fill!);
        out.write(
          '<table:table-cell table:style-name="${styles.cell(bordered: table.bordered, fill: fill)}" '
          'office:value-type="string"'
          '${span > 1 ? ' table:number-columns-spanned="$span"' : ''}'
          '${rowSpan > 1 ? ' table:number-rows-spanned="$rowSpan"' : ''}>'
          '${content.finish()}</table:table-cell>',
        );
        if (span > 1) out.write('<table:covered-table-cell/>' * (span - 1));
      }
      out.write('</table:table-row>');
      if (r == headerRows - 1) out.write('</table:table-header-rows>');
    }
    out.write('</table:table>');
    return out.toString();
  }

  bool _takeBreak() {
    final pending = _pendingBreak;
    _pendingBreak = false;
    return pending;
  }

  /// The page style the next block starts, and the number of its first page.
  (String?, int?) _takeMaster() {
    final master = _pendingMaster;
    final number = master == null ? null : _pendingNumber;
    _pendingMaster = null;
    _pendingNumber = null;
    return (master, number);
  }
}
