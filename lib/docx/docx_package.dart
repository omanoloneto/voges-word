import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'word_xml.dart';

class Relationship {
  const Relationship({
    required this.id,
    required this.type,
    required this.target,
    this.external = false,
  });

  final String id;
  final String type;
  final String target;
  final bool external;

  bool hasType(String suffix) => type.endsWith('/$suffix');
}

abstract final class RelationshipTypes {
  static const _base =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  static const image = '$_base/image';
  static const hyperlink = '$_base/hyperlink';
  static const numbering = '$_base/numbering';
}

/// Arquivo .docx aberto: todas as partes do zip, para salvar sem perder nada.
class DocxPackage {
  DocxPackage(Map<String, Uint8List> parts, {String? id})
    : parts = Map.of(parts),
      id = id ?? 'pkg${++_counter}';

  factory DocxPackage.decode(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException(
        'O arquivo não é um documento do Word válido.',
      );
    }
    final declaredSize = archive.files.fold<int>(
      0,
      (sum, file) => sum + file.size,
    );
    if (declaredSize > _maxUncompressedBytes) {
      throw const FormatException('O arquivo é grande demais para abrir.');
    }
    final parts = <String, Uint8List>{
      for (final file in archive.files)
        if (file.isFile) file.name: file.content,
    };
    final package = DocxPackage(parts);
    if (!parts.containsKey(package.mainDocumentPath)) {
      throw const FormatException(
        'O arquivo não é um documento do Word válido.',
      );
    }
    return package;
  }

  static int _counter = 0;

  /// Protege contra arquivos compactados que explodem na memória.
  static const _maxUncompressedBytes = 512 * 1024 * 1024;

  final Map<String, Uint8List> parts;
  final String id;

  DocxPackage copy() => DocxPackage(parts, id: id);

  String get mainDocumentPath {
    for (final relationship in relationships('')) {
      if (relationship.hasType('officeDocument')) {
        return resolve('', relationship.target);
      }
    }
    return 'word/document.xml';
  }

  String? text(String path) {
    final bytes = parts[path];
    if (bytes == null) return null;
    final decoded = utf8.decode(bytes, allowMalformed: true);
    return decoded.startsWith('\uFEFF') ? decoded.substring(1) : decoded;
  }

  XmlDocument? xml(String path) {
    final source = text(path);
    return source == null ? null : XmlDocument.parse(source);
  }

  void setText(String path, String content) =>
      parts[path] = Uint8List.fromList(utf8.encode(content));

  List<Relationship> relationships(String sourcePath) {
    final document = xml(relationshipsPath(sourcePath));
    if (document == null) return const [];
    return [
      for (final element in document.rootElement.childElements)
        if (element.name.local == 'Relationship')
          Relationship(
            id: element.getAttribute('Id') ?? '',
            type: element.getAttribute('Type') ?? '',
            target: element.getAttribute('Target') ?? '',
            external: element.getAttribute('TargetMode') == 'External',
          ),
    ];
  }

  static String relationshipsPath(String sourcePath) {
    if (sourcePath.isEmpty) return '_rels/.rels';
    final slash = sourcePath.lastIndexOf('/');
    final directory = slash < 0 ? '' : sourcePath.substring(0, slash + 1);
    return '${directory}_rels/${sourcePath.substring(slash + 1)}.rels';
  }

  static String resolve(String sourcePath, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final slash = sourcePath.lastIndexOf('/');
    final segments = slash < 0
        ? <String>[]
        : sourcePath.substring(0, slash).split('/');
    for (final segment in target.split('/')) {
      if (segment == '..') {
        if (segments.isNotEmpty) segments.removeLast();
      } else if (segment.isNotEmpty && segment != '.') {
        segments.add(segment);
      }
    }
    return segments.join('/');
  }

  /// Gera o zip com [Content_Types].xml primeiro, como o Word espera.
  Uint8List encode() {
    final archive = Archive();
    const contentTypes = '[Content_Types].xml';
    final names = [
      if (parts.containsKey(contentTypes)) contentTypes,
      ...parts.keys.where((name) => name != contentTypes),
    ];
    for (final name in names) {
      archive.addFile(ArchiveFile.bytes(name, parts[name]!));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  void addRelationships(String sourcePath, List<Relationship> added) {
    if (added.isEmpty) return;
    final path = relationshipsPath(sourcePath);
    final document =
        xml(path) ??
        XmlDocument.parse(
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="${Namespaces.packageRelationships}"/>',
        );
    for (final relationship in added) {
      document.rootElement.children.add(
        XmlElement(XmlName.parts('Relationship'), [
          XmlAttribute(XmlName.parts('Id'), relationship.id),
          XmlAttribute(XmlName.parts('Type'), relationship.type),
          XmlAttribute(XmlName.parts('Target'), relationship.target),
          if (relationship.external)
            XmlAttribute(XmlName.parts('TargetMode'), 'External'),
        ]),
      );
    }
    setText(path, document.toXmlString());
  }

  void ensureContentTypes({
    Map<String, String> defaults = const {},
    Map<String, String> overrides = const {},
  }) {
    const path = '[Content_Types].xml';
    final document = xml(path);
    if (document == null) return;
    final root = document.rootElement;
    final existingDefaults = {
      for (final element in root.childElements)
        if (element.name.local == 'Default')
          (element.getAttribute('Extension') ?? '').toLowerCase(),
    };
    final existingOverrides = {
      for (final element in root.childElements)
        if (element.name.local == 'Override') element.getAttribute('PartName'),
    };
    var changed = false;
    defaults.forEach((extension, type) {
      if (existingDefaults.contains(extension.toLowerCase())) return;
      root.children.insert(
        0,
        XmlElement(XmlName.parts('Default'), [
          XmlAttribute(XmlName.parts('Extension'), extension),
          XmlAttribute(XmlName.parts('ContentType'), type),
        ]),
      );
      changed = true;
    });
    overrides.forEach((partName, type) {
      if (existingOverrides.contains(partName)) return;
      root.children.add(
        XmlElement(XmlName.parts('Override'), [
          XmlAttribute(XmlName.parts('PartName'), partName),
          XmlAttribute(XmlName.parts('ContentType'), type),
        ]),
      );
      changed = true;
    });
    if (changed) setText(path, document.toXmlString());
  }
}
