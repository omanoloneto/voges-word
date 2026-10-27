import 'package:xml/xml.dart';

import 'word_xml.dart';

enum ListKind { bullet, ordered }

class DocxNumbering {
  DocxNumbering._(this._formats, this.maxAbstractId, this.maxNumId);

  factory DocxNumbering.parse(XmlDocument? numbering) {
    if (numbering == null) return DocxNumbering._(const {}, 0, 0);
    final root = numbering.rootElement;
    final x = WordXml(root);

    Map<int, String> levelFormats(XmlElement parent) => {
      for (final level in x.children(parent, 'lvl'))
        int.tryParse(x.attr(level, 'ilvl') ?? '') ?? 0:
            x.childVal(level, 'numFmt') ?? 'decimal',
    };

    var maxAbstract = 0;
    final abstracts = <int, Map<int, String>>{};
    for (final element in x.children(root, 'abstractNum')) {
      final id = int.tryParse(x.attr(element, 'abstractNumId') ?? '');
      if (id == null) continue;
      if (id > maxAbstract) maxAbstract = id;
      abstracts[id] = levelFormats(element);
    }

    var maxNum = 0;
    final formats = <int, Map<int, String>>{};
    for (final element in x.children(root, 'num')) {
      final id = int.tryParse(x.attr(element, 'numId') ?? '');
      if (id == null) continue;
      if (id > maxNum) maxNum = id;
      final abstractId = int.tryParse(
        x.childVal(element, 'abstractNumId') ?? '',
      );
      final levels = Map.of(abstracts[abstractId] ?? const <int, String>{});
      for (final override in x.children(element, 'lvlOverride')) {
        final level = int.tryParse(x.attr(override, 'ilvl') ?? '') ?? 0;
        final redefined = x.child(override, 'lvl');
        if (redefined != null) {
          levels[level] = x.childVal(redefined, 'numFmt') ?? 'decimal';
        }
      }
      formats[id] = levels;
    }
    return DocxNumbering._(formats, maxAbstract, maxNum);
  }

  final Map<int, Map<int, String>> _formats;
  final int maxAbstractId;
  final int maxNumId;

  ListKind? kind(int numId, int level) {
    final format = _formats[numId]?[level] ?? _formats[numId]?[0];
    return switch (format) {
      null || 'none' => null,
      'bullet' => ListKind.bullet,
      _ => ListKind.ordered,
    };
  }
}

/// Definições de lista que o Voges Word acrescenta ao salvar.
class NumberingPlan {
  NumberingPlan(this._numbering);

  final DocxNumbering _numbering;
  int? _bulletAbstract;
  int? _orderedAbstract;
  int? _bulletNum;
  final _nums = <int, int>{};
  late int _nextAbstract = _numbering.maxAbstractId + 1;
  late int _nextNum = _numbering.maxNumId + 1;

  bool get isEmpty => _nums.isEmpty;

  int bulletList() {
    _bulletAbstract ??= _nextAbstract++;
    return _bulletNum ??= _register(_bulletAbstract!);
  }

  /// Cada lista numerada contínua recomeça do 1.
  int newOrderedList() {
    _orderedAbstract ??= _nextAbstract++;
    return _register(_orderedAbstract!);
  }

  int _register(int abstractId) {
    final id = _nextNum++;
    _nums[id] = abstractId;
    return id;
  }

  String apply(String? existingXml) {
    final abstracts = StringBuffer();
    if (_bulletAbstract != null) {
      abstracts.write(_abstractXml(_bulletAbstract!, ordered: false));
    }
    if (_orderedAbstract != null) {
      abstracts.write(_abstractXml(_orderedAbstract!, ordered: true));
    }
    final nums = StringBuffer();
    _nums.forEach((numId, abstractId) {
      nums.write(
        '<w:num w:numId="$numId"><w:abstractNumId w:val="$abstractId"/>',
      );
      if (abstractId == _orderedAbstract) {
        for (var level = 0; level < 9; level++) {
          nums.write(
            '<w:lvlOverride w:ilvl="$level"><w:startOverride w:val="1"/></w:lvlOverride>',
          );
        }
      }
      nums.write('</w:num>');
    });

    if (existingXml == null) {
      return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<w:numbering xmlns:w="${Namespaces.w}">$abstracts$nums</w:numbering>';
    }
    final document = XmlDocument.parse(existingXml);
    final root = document.rootElement;
    final x = WordXml(root);
    final children = root.children;
    final lastAbstract = children.lastIndexWhere(
      (node) => node is XmlElement && x.isW(node, 'abstractNum'),
    );
    final firstNum = children.indexWhere(
      (node) => node is XmlElement && x.isW(node, 'num'),
    );
    final abstractIndex = lastAbstract >= 0
        ? lastAbstract + 1
        : (firstNum >= 0 ? firstNum : _afterPictureBullets(root, x));
    children.insertAll(abstractIndex, _parseAll(abstracts.toString()));
    final lastNum = children.lastIndexWhere(
      (node) => node is XmlElement && x.isW(node, 'num'),
    );
    final numIndex = lastNum >= 0
        ? lastNum + 1
        : abstractIndex +
              (_bulletAbstract != null ? 1 : 0) +
              (_orderedAbstract != null ? 1 : 0);
    children.insertAll(numIndex, _parseAll(nums.toString()));
    return document.toXmlString();
  }

  int _afterPictureBullets(XmlElement root, WordXml x) {
    final last = root.children.lastIndexWhere(
      (node) => node is XmlElement && x.isW(node, 'numPicBullet'),
    );
    return last + 1;
  }

  static List<XmlNode> _parseAll(String xml) {
    if (xml.isEmpty) return const [];
    final wrapper = XmlDocument.parse(
      '<w:root xmlns:w="${Namespaces.w}">$xml</w:root>',
    );
    return [
      for (final element in wrapper.rootElement.childElements) element.copy(),
    ];
  }

  static String _abstractXml(int id, {required bool ordered}) {
    const bullets = ['•', '◦', '▪'];
    const formats = ['decimal', 'lowerLetter', 'lowerRoman'];
    final levels = StringBuffer();
    for (var level = 0; level < 9; level++) {
      final format = ordered ? formats[level % 3] : 'bullet';
      final text = ordered ? '%${level + 1}.' : bullets[level % 3];
      final left = 720 * (level + 1);
      levels.write(
        '<w:lvl w:ilvl="$level"><w:start w:val="1"/>'
        '<w:numFmt w:val="$format"/><w:lvlText w:val="$text"/>'
        '<w:lvlJc w:val="left"/><w:pPr><w:ind w:left="$left" w:hanging="360"/></w:pPr></w:lvl>',
      );
    }
    return '<w:abstractNum w:abstractNumId="$id">'
        '<w:multiLevelType w:val="hybridMultilevel"/>$levels</w:abstractNum>';
  }
}
