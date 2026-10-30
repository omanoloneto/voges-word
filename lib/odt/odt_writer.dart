import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/painting.dart' show Color, EdgeInsets;
import 'package:flutter_quill/quill_delta.dart';
import 'package:xml/xml.dart';

import '../document/delta_blocks.dart';
import '../document/document_look.dart';
import '../document/embeds.dart';
import '../document/headers_footers.dart';
import '../document/tables.dart';
import '../docx/docx_builder.dart' show safeLinkTarget;
import '../docx/docx_package.dart';
import '../docx/image_formats.dart';
import '../docx/word_xml.dart';
import 'odf_xml.dart';
import 'odt_package.dart' show odtMimeType;

enum _Place { body, cell, header, footer, note }

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

String _attribute(String value) =>
    escapeXmlAttribute(stripInvalidXmlChars(value));

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
    final document = _Document(tables, look, source);
    final contentStyles = _Styles('');
    final masterStyles = _Styles('M');
    final stories = headersFooters ?? const HeadersFooters();

    final sections = _sections(documentBlocks(delta));
    final body = _StoryWriter(document, contentStyles, _Place.body);
    for (final (index, section) in sections.indexed) {
      if (sections.length > 1) body.startSection(_masterName(index, sections));
      body.write(section.blocks);
    }
    final bodyXml = body.finish();

    String story(HeaderFooterStory? story, _Place place) {
      if (story == null) return '';
      return (_StoryWriter(
        document,
        masterStyles,
        place,
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
        '<office:styles>${_commonStyles(look)}</office:styles>'
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
  /// uses the document's page setup, the others the setup in their break.
  static List<_Section> _sections(List<DocumentBlock> blocks) {
    final sections = <_Section>[];
    var current = <DocumentBlock>[];
    for (final block in blocks) {
      if (block is EmbedBlock && block.type == EmbedTypes.sectionBreak) {
        final page = _sectionPage(block.value);
        if (page == null) continue;
        sections.add((blocks: current, page: page));
        current = [];
      } else {
        current.add(block);
      }
    }
    sections.add((blocks: current, page: null));
    return sections;
  }

  /// The page of a Word section break; null for continuous ones, which
  /// OpenDocument can't start without a new page.
  static _SectionPage? _sectionPage(Object? value) {
    try {
      final root = parseFragment(sectionXmlOf(value));
      XmlElement? child(String local) {
        for (final element in root.childElements) {
          if (element.name.local == local) return element;
        }
        return null;
      }

      if (child('type')?.getAttribute('val', namespaceUri: '*') ==
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
      final size = child('pgSz');
      final margins = child('pgMar');
      return (
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
      );
    } catch (_) {
      return null;
    }
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
  }) {
    final top = header ? math.min(headerDistance, margins.top) : margins.top;
    final bottom = footer
        ? math.min(footerDistance, margins.bottom)
        : margins.bottom;
    final out = StringBuffer(
      '<style:page-layout style:name="$name">'
      '<style:page-layout-properties fo:page-width="${odfPoints(width)}" '
      'fo:page-height="${odfPoints(height)}" '
      'style:print-orientation="${width > height ? 'landscape' : 'portrait'}" '
      'fo:margin-top="${odfPoints(top)}" '
      'fo:margin-bottom="${odfPoints(bottom)}" '
      'fo:margin-left="${odfPoints(margins.left)}" '
      'fo:margin-right="${odfPoints(margins.right)}" '
      'style:writing-mode="lr-tb"/>',
    );
    if (header) {
      out.write(
        '<style:header-style><style:header-footer-properties '
        'fo:min-height="${odfPoints(math.max(margins.top - top, 0))}" '
        'fo:margin-bottom="0pt"/></style:header-style>',
      );
    }
    if (footer) {
      out.write(
        '<style:footer-style><style:header-footer-properties '
        'fo:min-height="${odfPoints(math.max(margins.bottom - bottom, 0))}" '
        'fo:margin-top="0pt"/></style:footer-style>',
      );
    }
    out.write('</style:page-layout>');
    return out.toString();
  }

  static String _commonStyles(DocumentLook look) {
    final body = look.body;
    final out = StringBuffer(
      '<style:default-style style:family="paragraph">'
      '<style:paragraph-properties style:tab-stop-distance="35.4pt" '
      'style:writing-mode="page"/>'
      '<style:text-properties${_lookText(body, withStyle: false)}/>'
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
    for (final (name, display) in [
      ('Header', 'Header'),
      ('Footer', 'Footer'),
    ]) {
      out.write(
        '<style:style style:name="$name" style:display-name="$display" '
        'style:family="paragraph" style:parent-style-name="Standard" '
        'style:class="extra"/>',
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
    final size = odfPoints(look.fontSize);
    return '${font == null ? '' : ' style:font-name="${_attribute(font)}"'}'
        ' fo:font-size="$size" style:font-size-asian="$size" '
        'style:font-size-complex="$size" fo:color="#${_colorHex(look.color)}"'
        '${withStyle ? _lookWeight(look, explicit: true) : ''}';
  }

  static String _lookWeight(TextLook look, {bool explicit = false}) =>
      '${look.bold || explicit ? ' fo:font-weight="${look.bold ? 'bold' : 'normal'}"' : ''}'
      '${look.italic || explicit ? ' fo:font-style="${look.italic ? 'italic' : 'normal'}"' : ''}';

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

typedef _Section = ({List<DocumentBlock> blocks, _SectionPage? page});

/// What every part of the file shares: fonts, pictures, names and counters.
class _Document {
  _Document(this.tables, this.look, this.source);

  final TableStore tables;
  final DocumentLook look;

  /// The opened package, where the text of footnotes is.
  final Object? source;
  final fonts = <String>{};
  final pictures = <String, ({Uint8List bytes, String mime})>{};
  final _pictureByUri = <String, String>{};
  final bookmarks = <String>{};
  final tablesInProgress = <String>{};
  var tableCount = 0;
  var frameCount = 0;
  var footnotes = 0;
  var endnotes = 0;
  final _notes = <String, Map<String, List<String>>>{};

  /// The path of a picture given as a data URI; null for anything else.
  ({String path, Uint8List bytes, String mime})? picture(String uri) {
    final known = _pictureByUri[uri];
    if (known != null) {
      final picture = pictures[known]!;
      return (path: known, bytes: picture.bytes, mime: picture.mime);
    }
    final decoded = decodeDataUri(uri);
    if (decoded == null ||
        decoded.bytes.isEmpty ||
        !_pictureTypes.contains(decoded.mime)) {
      return null;
    }
    final path =
        'Pictures/image${pictures.length + 1}.${extensionForMime(decoded.mime)}';
    pictures[path] = (bytes: decoded.bytes, mime: decoded.mime);
    _pictureByUri[uri] = path;
    return (path: path, bytes: decoded.bytes, mime: decoded.mime);
  }

  /// The paragraphs of a Word footnote or endnote of the opened package.
  List<String>? noteText(String kind, String id, String? packageId) {
    final package = source;
    if (package is! DocxPackage || package.id != packageId) return null;
    return (_notes[kind] ??= _readNotes(package, kind))[id];
  }

  static Map<String, List<String>> _readNotes(
    DocxPackage package,
    String kind,
  ) {
    try {
      final main = package.mainDocumentPath;
      String? path;
      for (final relationship in package.relationships(main)) {
        if (relationship.hasType('${kind}s') && !relationship.external) {
          path = DocxPackage.resolve(main, relationship.target);
        }
      }
      final root = path == null ? null : package.xml(path)?.rootElement;
      if (root == null) return const {};
      return {
        for (final note in root.childElements)
          if (note.name.local == kind)
            note.getAttribute('id', namespaceUri: '*') ?? '': [
              for (final paragraph in note.descendantElements)
                if (paragraph.name.local == 'p') _plainText(paragraph),
            ],
      };
    } catch (_) {
      return const {};
    }
  }

  static String _plainText(XmlElement paragraph) {
    final out = StringBuffer();
    for (final element in paragraph.descendantElements) {
      switch (element.name.local) {
        case 't':
          out.write(element.innerText);
        case 'tab':
          out.write('\t');
        case 'br' || 'cr':
          out.write(' ');
      }
    }
    return out.toString();
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
  var _tables = 0;
  String? _graphic;

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
  }) => _define(
    '${prefix}Table${++_tables}',
    'table',
    '<style:table-properties style:width="${odfPoints(width)}" '
        'table:align="left"${breakBefore ? ' fo:break-before="page"' : ''}/>',
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

  String graphic() => _graphic ??= _define(
    '${prefix}fr1',
    'graphic',
    '<style:graphic-properties style:vertical-pos="top" '
        'style:vertical-rel="baseline"/>',
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

/// Writes blocks of the body, a cell, a header or footer, or a note.
class _StoryWriter {
  _StoryWriter(this.document, this.styles, this.place, [this.depth = 0]);

  final _Document document;
  final _Styles styles;
  final _Place place;

  /// Tables around the content.
  final int depth;
  final _out = StringBuffer();
  final _lists = <_OpenList>[];
  var _pendingBreak = false;
  String? _pendingMaster;

  String get _parent => switch (place) {
    _Place.header => 'Header',
    _Place.footer => 'Footer',
    _Place.note => 'Footnote',
    _Place.body || _Place.cell => 'Standard',
  };

  /// The next block starts a page with [master].
  void startSection(String master) {
    _closeLists();
    _pendingMaster = master;
    _pendingBreak = false;
  }

  void write(List<DocumentBlock> blocks) {
    for (final block in blocks) {
      switch (block) {
        case LineBlock(list: final String _):
          _listLine(block);
        case LineBlock():
          _closeLists();
          _line(block);
        case EmbedBlock():
          _closeLists();
          _embedBlock(block);
      }
    }
  }

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
        final table = document.tables[id];
        if (table != null) _table(table);
      case EmbedTypes.opaqueBlock:
        final content = _opaque(block.value);
        if (content == null || content.hidden) return;
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
  void _line(LineBlock line, {bool inList = false}) {
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
      if (index > 0 && place == _Place.body) _pendingBreak = true;
      if (segment.isEmpty && segments.length > 1) continue;
      _writeParagraph(
        line,
        segment,
        heading: line.heading,
        inList: inList,
        bookmarks: bookmarks,
      );
      bookmarks = false;
    }
  }

  void _listLine(LineBlock line) {
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
    _line(line, inList: true);
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
  }) {
    final level = heading?.clamp(1, 10);
    final master = _pendingMaster;
    _pendingMaster = null;
    final style = styles.paragraph(
      level == null ? _parent : 'Heading_20_$level',
      _paragraphProperties(line, inList: inList),
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

  String _paragraphProperties(LineBlock? line, {required bool inList}) {
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
      if (line.spaceBefore case final before?) {
        out.write(' fo:margin-top="${odfPoints(math.max(before, 0))}"');
      }
      if (line.spaceAfter case final after?) {
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
        if (link != null) {
          out.write(
            '<text:a xlink:type="simple" xlink:href="${_attribute(link)}" '
            'text:style-name="Internet_20_link" '
            'text:visited-style-name="Visited_20_Internet_20_Link">',
          );
        }
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
      out.write(
        ' fo:font-weight="bold" style:font-weight-asian="bold" '
        'style:font-weight-complex="bold"',
      );
    }
    if (attributes['italic'] == true) {
      out.write(
        ' fo:font-style="italic" style:font-style-asian="italic" '
        'style:font-style-complex="italic"',
      );
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
      final value = odfPoints(size);
      out.write(
        ' fo:font-size="$value" style:font-size-asian="$value" '
        'style:font-size-complex="$value"',
      );
    }
    final font = OdtWriter._font(attributes['font']);
    if (font != null) {
      document.fonts.add(font);
      out.write(' style:font-name="${_attribute(font)}"');
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
        return _span(piece.attributes, _pageNumber);
      case EmbedTypes.opaqueInline:
        final content = _opaque(piece.value);
        if (content == null || content.hidden) return '';
        switch (fieldNameOf(content.xml)) {
          case 'PAGE':
            encoder.object();
            return _span(piece.attributes, _pageNumber);
          case 'NUMPAGES' || 'SECTIONPAGES':
            encoder.object();
            return _span(
              piece.attributes,
              '<text:page-count>1</text:page-count>',
            );
        }
        if (content.label == OpaqueLabels.note) {
          final note = _note(content);
          if (note != null) {
            encoder.object();
            return note;
          }
        }
        return _span(piece.attributes, encoder.encode(content.text));
      default:
        return '';
    }
  }

  static const _pageNumber =
      '<text:page-number text:select-page="current">1</text:page-number>';

  String? _note(OpaqueContent content) {
    if (place != _Place.body && place != _Place.cell) return null;
    final reference = RegExp(
      r'<w:(footnote|endnote)Reference\b[^>]*?\bw:id="(-?\d+)"',
    ).firstMatch(content.xml);
    if (reference == null) return null;
    final kind = reference[1]!;
    final paragraphs = document.noteText(
      kind,
      reference[2]!,
      content.packageId,
    );
    if (paragraphs == null) return null;
    final endnote = kind == 'endnote';
    final number = endnote ? ++document.endnotes : ++document.footnotes;
    final style = endnote ? 'Endnote' : 'Footnote';
    final body = [
      for (final (index, text) in paragraphs.indexed)
        '<text:p text:style-name="$style">'
            '${_TextEncoder().encode(index == 0 ? text.trimLeft() : text, atEnd: true)}'
            '</text:p>',
    ].join();
    return '<text:note text:id="${endnote ? 'edn' : 'ftn'}$number" '
        'text:note-class="$kind"><text:note-citation>$number</text:note-citation>'
        '<text:note-body>${body.isEmpty ? '<text:p text:style-name="$style"/>' : body}'
        '</text:note-body></text:note>';
  }

  String _frame(EmbedPiece piece) {
    final value = piece.value;
    if (value is! String) return '';
    final picture = document.picture(value);
    if (picture == null) return '';
    final pixels = imagePixelSize(picture.bytes);
    final natural = pixels == null
        ? null
        : (width: pixels.width * 0.75, height: pixels.height * 0.75);
    final ratio = natural == null || natural.width <= 0 || natural.height <= 0
        ? 1.0
        : natural.height / natural.width;
    final givenWidth = _positive(pointsValue(piece.attributes['width']));
    final givenHeight = _positive(pointsValue(piece.attributes['height']));
    var width =
        givenWidth ??
        (givenHeight != null ? givenHeight / ratio : natural?.width ?? 72);
    var height = givenHeight ?? width * ratio;
    final maxWidth = document.look.contentWidth;
    if (width > maxWidth && maxWidth > 0) {
      height = height * maxWidth / width;
      width = maxWidth;
    }
    final name = 'Image${++document.frameCount}';
    return '<draw:frame draw:style-name="${styles.graphic()}" draw:name="$name" '
        'text:anchor-type="as-char" svg:width="${odfPoints(width)}" '
        'svg:height="${odfPoints(height)}" draw:z-index="0">'
        '<draw:image xlink:href="${picture.path}" xlink:type="simple" '
        'xlink:show="embed" xlink:actuate="onLoad" '
        'draw:mime-type="${picture.mime}"/></draw:frame>';
  }

  static double? _positive(double? value) =>
      value != null && value.isFinite && value > 0 ? value : null;

  void _table(TableModel table) {
    if (depth >= 32 || table.rows.isEmpty) return;
    if (!document.tablesInProgress.add(table.id)) return;
    try {
      _out.write(_tableXml(table));
    } finally {
      document.tablesInProgress.remove(table.id);
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
    var widths = [for (final width in table.columnWidths) width / 20];
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

    final out = StringBuffer(
      '<table:table table:name="Table${++document.tableCount}" '
      'table:style-name="${styles.table(widths.fold(0, (sum, width) => sum + width), breakBefore: _takeBreak(), master: _takeMaster())}">',
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
        final content = _StoryWriter(document, styles, _Place.cell, depth + 1)
          ..write(documentBlocks(cell.controller.document.toDelta()));
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

  String? _takeMaster() {
    final master = _pendingMaster;
    _pendingMaster = null;
    return master;
  }
}
