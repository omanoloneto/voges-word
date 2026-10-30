import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../document/document_codec.dart';
import 'odf_xml.dart';

const odtMimeType = 'application/vnd.oasis.opendocument.text';

const _textTypes = {odtMimeType, '$odtMimeType-template'};

/// The entries of an OpenDocument Text file that the reader uses. Only these
/// are decompressed, each within a size limit, and nothing outside the zip is
/// ever read.
class OdtPackage {
  OdtPackage._(
    this._archive, {
    required this.content,
    required this.styles,
    required this.hasMacros,
    required String? tabsRelativeToIndent,
  }) : tabsRelativeToIndent = tabsRelativeToIndent != 'false';

  /// Null when the zip is a Word package, as a .docx renamed to .odt.
  static OdtPackage? decode(Uint8List bytes) {
    if (bytes.length > _maxFileBytes) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw DocumentProblemException(DocumentProblem.notWordDocument);
    }
    if (archive.length > _maxEntries) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
    final reader = _EntryReader(archive);

    final mimetype = reader.text('mimetype', 256)?.trim();
    if (mimetype == null &&
        archive.find('content.xml') == null &&
        archive.find('word/document.xml') != null) {
      return null;
    }
    final manifest = reader.xml('META-INF/manifest.xml', _maxSmallBytes);
    final type = mimetype ?? _rootMediaType(manifest);
    if (type != null && !_textTypes.contains(type)) {
      throw DocumentProblemException(DocumentProblem.notWordDocument);
    }
    if (manifest != null &&
        manifest.descendantElements.any(
          (element) => element.isOdf(OdfNamespaces.manifest, 'encryption-data'),
        )) {
      throw DocumentProblemException(DocumentProblem.passwordProtected);
    }

    final content = reader.xml('content.xml', _maxXmlBytes);
    if (content == null) {
      throw DocumentProblemException(DocumentProblem.notWordDocument);
    }
    final body = content.rootElement.odfChild(OdfNamespaces.office, 'body');
    if (body?.odfChild(OdfNamespaces.office, 'text') == null) {
      throw DocumentProblemException(DocumentProblem.notWordDocument);
    }

    return OdtPackage._(
      reader,
      content: content,
      styles: reader.xml('styles.xml', _maxXmlBytes),
      hasMacros: archive.files.any(
        (file) =>
            file.name.startsWith('Basic/') || file.name.startsWith('Scripts/'),
      ),
      tabsRelativeToIndent: _setting(
        reader.xml('settings.xml', _maxSmallBytes * 4),
        'TabsRelativeToIndent',
      ),
    );
  }

  static String? _setting(XmlDocument? settings, String name) {
    if (settings == null) return null;
    for (final item in settings.descendantElements) {
      if (item.isOdf(_config, 'config-item') &&
          item.odfAttribute(_config, 'name') == name) {
        return item.innerText.trim();
      }
    }
    return null;
  }

  static const _config = 'urn:oasis:names:tc:opendocument:xmlns:config:1.0';

  static String? _rootMediaType(XmlDocument? manifest) {
    if (manifest == null) return null;
    for (final entry in manifest.rootElement.childElements) {
      if (entry.isOdf(OdfNamespaces.manifest, 'file-entry') &&
          entry.odfAttribute(OdfNamespaces.manifest, 'full-path') == '/') {
        return entry.odfAttribute(OdfNamespaces.manifest, 'media-type');
      }
    }
    return null;
  }

  static const _maxFileBytes = 512 * 1024 * 1024;
  static const _maxEntries = 10000;
  static const _maxSmallBytes = 1024 * 1024;
  static const _maxXmlBytes = 64 * 1024 * 1024;
  static const _maxPictureBytes = 64 * 1024 * 1024;

  final _EntryReader _archive;
  final XmlDocument content;
  final XmlDocument? styles;

  /// Basic or script libraries, which are never run nor kept.
  final bool hasMacros;

  /// Tab stops measured from the paragraph's indent, LibreOffice's default,
  /// rather than from the margin.
  final bool tabsRelativeToIndent;

  final _pictures = <String, Uint8List?>{};

  /// A picture stored in the package; null for links to anything outside it,
  /// missing entries and pictures over the size limit.
  Uint8List? picture(String href) {
    final path = _entryPath(href);
    if (path == null) return null;
    return _pictures.putIfAbsent(
      path,
      () => _archive.bytes(path, _maxPictureBytes, skipLarger: true),
    );
  }

  /// Relative paths inside the zip only: no scheme, no absolute path and no
  /// way out of the package.
  static String? _entryPath(String href) {
    var path = href.trim();
    if (path.isEmpty || path.contains(':') || path.contains('\\')) return null;
    try {
      path = Uri.decodeFull(path);
    } on ArgumentError {
      return null;
    }
    while (path.startsWith('./')) {
      path = path.substring(2);
    }
    if (path.isEmpty || path.startsWith('/')) return null;
    if (path.split('/').any((segment) => segment == '..' || segment == '.')) {
      return null;
    }
    return path;
  }
}

/// Decompresses entries while keeping count of what was read.
class _EntryReader {
  _EntryReader(this._archive);

  final Archive _archive;
  var _total = 0;

  static const _maxTotalBytes = 256 * 1024 * 1024;
  static const _maxDepth = 256;

  Uint8List? bytes(String name, int limit, {bool skipLarger = false}) {
    final file = _archive.find(name);
    if (file == null || !file.isFile) return null;
    if (file.size > limit) {
      if (skipLarger) return null;
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
    _total += file.size;
    if (_total > _maxTotalBytes) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
    try {
      return file.readBytes() ?? Uint8List(0);
    } catch (_) {
      throw DocumentProblemException(DocumentProblem.damaged);
    }
  }

  String? text(String name, int limit) {
    final data = bytes(name, limit);
    if (data == null) return null;
    final decoded = utf8.decode(data, allowMalformed: true);
    return decoded.startsWith('﻿') ? decoded.substring(1) : decoded;
  }

  XmlDocument? xml(String name, int limit) {
    final source = text(name, limit);
    if (source == null) return null;
    final XmlDocument document;
    try {
      document = XmlDocument.parse(source);
    } on XmlException {
      throw DocumentProblemException(DocumentProblem.damaged);
    }
    _checkDepth(document.rootElement);
    return document;
  }

  /// Deep nesting is refused here, so the readers' recursion stays shallow.
  static void _checkDepth(XmlElement root) {
    final stack = <(XmlElement, int)>[(root, 0)];
    while (stack.isNotEmpty) {
      final (element, depth) = stack.removeLast();
      if (depth > _maxDepth) {
        throw DocumentProblemException(DocumentProblem.damaged);
      }
      for (final child in element.childElements) {
        stack.add((child, depth + 1));
      }
    }
  }
}
