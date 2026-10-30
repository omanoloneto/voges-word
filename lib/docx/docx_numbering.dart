import 'package:xml/xml.dart';

import 'word_xml.dart';

/// Kinds of list item, named as the editor's list attribute.
enum ListKind { bullet, ordered, checked, unchecked }

/// Font of the checklist boxes, which has ☐ and ☑.
const _checkboxFont = 'Segoe UI Symbol';

typedef _Levels = Map<int, ListKind?>;

class DocxNumbering {
  DocxNumbering._(this._lists, this.maxAbstractId, this.maxNumId);

  factory DocxNumbering.parse(XmlDocument? numbering) {
    if (numbering == null) return DocxNumbering._(const {}, 0, 0);
    final root = numbering.rootElement;
    final x = WordXml(root);

    // Only Unicode boxes: a symbol font's private-use glyph stays a bullet.
    ListKind? kindOf(XmlElement level) {
      final format = x.childVal(level, 'numFmt') ?? 'decimal';
      if (format == 'none') return null;
      if (format != 'bullet') return ListKind.ordered;
      if (x.child(level, 'lvlPicBulletId') != null) return ListKind.bullet;
      return switch (x.childVal(level, 'lvlText')) {
        '☐' => ListKind.unchecked,
        '☑' || '☒' => ListKind.checked,
        _ => ListKind.bullet,
      };
    }

    _Levels levelKinds(XmlElement parent) => {
      for (final level in x.children(parent, 'lvl'))
        int.tryParse(x.attr(level, 'ilvl') ?? '') ?? 0: kindOf(level),
    };

    var maxAbstract = 0;
    final abstracts = <int, _Levels>{};
    for (final element in x.children(root, 'abstractNum')) {
      final id = int.tryParse(x.attr(element, 'abstractNumId') ?? '');
      if (id == null) continue;
      if (id > maxAbstract) maxAbstract = id;
      abstracts[id] = levelKinds(element);
    }

    // A list keeps its redefined levels apart from the shared definition, so
    // many lists of one definition don't each copy all of its levels.
    var maxNum = 0;
    final lists = <int, (_Levels, _Levels)>{};
    for (final element in x.children(root, 'num')) {
      final id = int.tryParse(x.attr(element, 'numId') ?? '');
      if (id == null) continue;
      if (id > maxNum) maxNum = id;
      final abstractId = int.tryParse(
        x.childVal(element, 'abstractNumId') ?? '',
      );
      final redefined = <int, ListKind?>{};
      for (final override in x.children(element, 'lvlOverride')) {
        final level = int.tryParse(x.attr(override, 'ilvl') ?? '') ?? 0;
        final definition = x.child(override, 'lvl');
        if (definition != null) redefined[level] = kindOf(definition);
      }
      lists[id] = (abstracts[abstractId] ?? const {}, redefined);
    }
    return DocxNumbering._(lists, maxAbstract, maxNum);
  }

  final Map<int, (_Levels, _Levels)> _lists;
  final int maxAbstractId;
  final int maxNumId;

  /// Levels a list doesn't define take its first level's kind.
  ListKind? kind(int numId, int level) {
    final list = _lists[numId];
    if (list == null) return null;
    final (shared, redefined) = list;
    (ListKind?,)? at(int level) => redefined.containsKey(level)
        ? (redefined[level],)
        : shared.containsKey(level)
        ? (shared[level],)
        : null;
    return (at(level) ?? at(0))?.$1;
  }
}

/// List definitions that Voges Word adds when saving.
class NumberingPlan {
  NumberingPlan(this._numbering);

  final DocxNumbering _numbering;
  final _abstracts = <ListKind, int>{};
  final _shared = <ListKind, int>{};
  final _nums = <int, int>{};
  late int _nextAbstract = _numbering.maxAbstractId + 1;
  late int _nextNum = _numbering.maxNumId + 1;

  bool get isEmpty => _nums.isEmpty;

  /// The list all bullets share, or all checklist items of a state.
  int sharedList(ListKind kind) {
    assert(kind != ListKind.ordered);
    return _shared[kind] ??= _register(kind);
  }

  /// Each contiguous numbered list restarts at 1.
  int newOrderedList() => _register(ListKind.ordered);

  int _register(ListKind kind) {
    final id = _nextNum++;
    _nums[id] = _abstracts[kind] ??= _nextAbstract++;
    return id;
  }

  String apply(String? existingXml) {
    final abstracts = StringBuffer();
    for (final kind in ListKind.values) {
      final id = _abstracts[kind];
      if (id != null) abstracts.write(_abstractXml(id, kind));
    }
    final ordered = _abstracts[ListKind.ordered];
    final nums = StringBuffer();
    _nums.forEach((numId, abstractId) {
      nums.write(
        '<w:num w:numId="$numId"><w:abstractNumId w:val="$abstractId"/>',
      );
      if (abstractId == ordered) {
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
        : abstractIndex + _abstracts.length;
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

  /// Checklists take the bullets' indents, so checked and unchecked items
  /// line up as one list.
  static String _abstractXml(int id, ListKind kind) {
    const bullets = ['•', '◦', '▪'];
    const formats = ['decimal', 'lowerLetter', 'lowerRoman'];
    final box = kind == ListKind.checked || kind == ListKind.unchecked;
    final font = box
        ? '<w:rPr><w:rFonts w:ascii="$_checkboxFont" w:hAnsi="$_checkboxFont" '
              'w:eastAsia="$_checkboxFont" w:cs="$_checkboxFont" '
              'w:hint="default"/></w:rPr>'
        : '';
    final levels = StringBuffer();
    for (var level = 0; level < 9; level++) {
      final format = kind == ListKind.ordered ? formats[level % 3] : 'bullet';
      final text = switch (kind) {
        ListKind.ordered => '%${level + 1}.',
        ListKind.bullet => bullets[level % 3],
        ListKind.checked => '☑',
        ListKind.unchecked => '☐',
      };
      final left = 720 * (level + 1);
      levels.write(
        '<w:lvl w:ilvl="$level"><w:start w:val="1"/>'
        '<w:numFmt w:val="$format"/><w:lvlText w:val="$text"/>'
        '<w:lvlJc w:val="left"/><w:pPr><w:ind w:left="$left" w:hanging="360"/></w:pPr>'
        '$font</w:lvl>',
      );
    }
    return '<w:abstractNum w:abstractNumId="$id">'
        '<w:multiLevelType w:val="hybridMultilevel"/>$levels</w:abstractNum>';
  }
}
