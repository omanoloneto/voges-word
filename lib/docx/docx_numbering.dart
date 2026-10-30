import 'package:xml/xml.dart';

import 'docx_builder.dart' show ListSuffix;
import 'docx_package.dart';
import 'word_xml.dart';

/// Kinds of list item, named as the editor's list attribute.
enum ListKind { bullet, ordered, checked, unchecked }

/// Font of the checklist boxes, which has ☐ and ☑.
const _checkboxFont = 'Segoe UI Symbol';

/// Word numbers levels 0 to 8 only.
const wordListLevels = 9;

/// The hidden line attribute with the Word level of a paragraph at a level
/// of its list without numbers (w:numFmt none), which the editor shows as a
/// plain paragraph; the attribute with its list is
/// `HiddenAttributes.numbering`.
const unnumberedLevelAttribute = 'vw-nlvl';

/// Word keeps list ids in 32 bits.
const _maxWordId = 0x7FFFFFFF;

/// A level of a Word list, as its w:lvl defines it.
class WordLevel {
  const WordLevel({
    this.start = 1,
    this.format = 'decimal',
    this.text = '',
    this.suffix = ListSuffix.tab,
    this.left,
    this.hanging,
    this.justification,
    this.font,
    this.legal = false,
    this.picture = false,
  });

  final int start;

  /// Word's number format, like `decimal`, `lowerLetter`, `bullet` or
  /// `none`.
  final String format;

  /// Word's level text: `%1.%2.` shows the numbers of the first two levels.
  final String text;
  final ListSuffix suffix;

  /// Points from the margin to the text, and from the text back to the
  /// number; null when the level leaves them out.
  final double? left;
  final double? hanging;

  /// Word's w:lvlJc, like `left`, `center` or `right`.
  final String? justification;

  /// The font of the number or bullet.
  final String? font;

  /// Word's w:isLgl: the numbers the text shows are all in decimal.
  final bool legal;

  /// A picture bullet, whose text is what shows without the picture.
  final bool picture;

  bool get numbered => format != 'bullet' && format != 'none';

  /// A level whose paragraphs show its text without a number of their own.
  bool get unnumbered => format == 'none';

  /// Only Unicode boxes make checklists: a symbol font's private-use glyph
  /// stays a bullet.
  ListKind? get kind {
    if (format == 'none') return null;
    if (format != 'bullet') return ListKind.ordered;
    if (picture) return ListKind.bullet;
    return switch (text) {
      '☐' => ListKind.unchecked,
      '☑' || '☒' => ListKind.checked,
      _ => ListKind.bullet,
    };
  }

  WordLevel _startingAt(int start) => WordLevel(
    start: start,
    format: format,
    text: text,
    suffix: suffix,
    left: left,
    hanging: hanging,
    justification: justification,
    font: font,
    legal: legal,
    picture: picture,
  );
}

/// A Word list (w:num): its abstract list (w:abstractNum) and the levels it
/// redefines or restarts.
typedef _List = ({
  int? abstractId,
  Map<int, WordLevel> redefined,
  Map<int, int> starts,
});

/// The lists of a Word numbering part. A list keeps what it overrides apart
/// from its abstract list, so many lists of one definition don't each copy
/// all of its levels.
class DocxNumbering {
  DocxNumbering._(
    this._abstracts,
    this._lists,
    this.maxAbstractId,
    this.maxNumId,
  );

  factory DocxNumbering.parse(XmlDocument? numbering) {
    if (numbering == null) return DocxNumbering._(const {}, const {}, 0, 0);
    final root = numbering.rootElement;
    final x = WordXml(root);

    var maxAbstract = 0;
    final abstracts = <int, Map<int, WordLevel>>{};
    // The abstract list of a list made with a Word list style only names the
    // style (w:numStyleLink); the levels are in the one that defines the
    // style (w:styleLink).
    final styleLinks = <int, String>{};
    final styleLevels = <String, int>{};
    for (final element in x.children(root, 'abstractNum')) {
      final id = int.tryParse(x.attr(element, 'abstractNumId') ?? '');
      if (id == null) continue;
      if (id > maxAbstract) maxAbstract = id;
      final levels = abstracts[id] = {};
      for (final child in element.childElements) {
        if (x.namespaceOf(child.name) != Namespaces.w) continue;
        switch (child.name.local) {
          case 'lvl':
            final index = _levelIndex(x.attr(child, 'ilvl'));
            if (index != null) levels[index] = _level(x, child);
          case 'numStyleLink':
            if (x.val(child) case final style?) styleLinks[id] = style;
          case 'styleLink':
            if (x.val(child) case final style?) {
              styleLevels.putIfAbsent(style, () => id);
            }
        }
      }
    }
    int? definition(int? abstractId) =>
        styleLevels[styleLinks[abstractId]] ?? abstractId;

    var maxNum = 0;
    final lists = <int, _List>{};
    for (final element in x.children(root, 'num')) {
      final id = int.tryParse(x.attr(element, 'numId') ?? '');
      if (id == null) continue;
      if (id > maxNum) maxNum = id;
      Map<int, WordLevel>? redefined;
      Map<int, int>? starts;
      for (final override in x.children(element, 'lvlOverride')) {
        final index = _levelIndex(x.attr(override, 'ilvl'));
        if (index == null) continue;
        final definition = x.child(override, 'lvl');
        if (definition != null) {
          (redefined ??= {})[index] = _level(x, definition);
        }
        final start = int.tryParse(x.childVal(override, 'startOverride') ?? '');
        if (start != null) (starts ??= {})[index] = start;
      }
      lists[id] = (
        abstractId: definition(
          int.tryParse(x.childVal(element, 'abstractNumId') ?? ''),
        ),
        redefined: redefined ?? const {},
        starts: starts ?? const {},
      );
    }
    return DocxNumbering._(abstracts, lists, maxAbstract, maxNum);
  }

  /// The numbering of the package an opened document keeps; none for other
  /// sources, or when the part can't be read.
  factory DocxNumbering.of(Object? source) {
    if (source is DocxPackage) {
      try {
        final main = source.mainDocumentPath;
        for (final relationship in source.relationships(main)) {
          if (relationship.hasType('numbering') && !relationship.external) {
            return DocxNumbering.parse(
              source.xml(DocxPackage.resolve(main, relationship.target)),
            );
          }
        }
      } catch (_) {
        return DocxNumbering.parse(null);
      }
    }
    return DocxNumbering.parse(null);
  }

  final Map<int, Map<int, WordLevel>> _abstracts;
  final Map<int, _List> _lists;
  final int maxAbstractId;
  final int maxNumId;

  static int? _levelIndex(String? value) {
    final index = int.tryParse(value ?? '');
    return index != null && index >= 0 && index < wordListLevels ? index : null;
  }

  /// Reads each property from the first element that has it, in one pass:
  /// documents can hold hundreds of thousands of levels.
  static WordLevel _level(WordXml x, XmlElement level) {
    XmlElement? start, format, text, suffix, justification, legal;
    XmlElement? paragraph, run;
    var picture = false;
    for (final child in level.childElements) {
      if (x.namespaceOf(child.name) != Namespaces.w) continue;
      switch (child.name.local) {
        case 'start':
          start ??= child;
        case 'numFmt':
          format ??= child;
        case 'lvlText':
          text ??= child;
        case 'suff':
          suffix ??= child;
        case 'lvlJc':
          justification ??= child;
        case 'isLgl':
          legal ??= child;
        case 'lvlPicBulletId':
          picture = true;
        case 'pPr':
          paragraph ??= child;
        case 'rPr':
          run ??= child;
      }
    }
    final indents = <String, double>{};
    for (final attribute in x.child(paragraph, 'ind')?.attributes ?? []) {
      final twips = double.tryParse(attribute.value);
      if (twips != null &&
          twips.isFinite &&
          x.namespaceOf(attribute.name) == Namespaces.w) {
        indents.putIfAbsent(attribute.name.local, () => twips / 20);
      }
    }
    final firstLine = indents['firstLine'];
    final fonts = x.child(run, 'rFonts');
    return WordLevel(
      // Word counts a level without w:start from 0.
      start: start == null ? 0 : int.tryParse(x.val(start) ?? '') ?? 1,
      format: x.val(format) ?? 'decimal',
      text: x.val(text) ?? '',
      suffix: switch (x.val(suffix)) {
        'space' => ListSuffix.space,
        'nothing' => ListSuffix.nothing,
        _ => ListSuffix.tab,
      },
      left: indents['left'] ?? indents['start'],
      hanging: indents['hanging'] ?? (firstLine == null ? null : -firstLine),
      justification: x.val(justification),
      font: x.attr(fonts, 'ascii') ?? x.attr(fonts, 'hAnsi'),
      legal: x.onOff(legal) ?? false,
      picture: picture,
    );
  }

  /// [level] of list [numId] as the list numbers it: the list's own
  /// definition of the level, or else its abstract list's, starting where
  /// its w:startOverride says. Null when the list doesn't define the level.
  WordLevel? level(int numId, int level) {
    final list = _lists[numId];
    if (list == null) return null;
    final own = list.redefined[level] ?? _abstracts[list.abstractId]?[level];
    final start = list.starts[level];
    return own == null || start == null ? own : own._startingAt(start);
  }

  /// Levels a list doesn't define take its first level's kind.
  ListKind? kind(int numId, int level) =>
      (this.level(numId, level) ?? this.level(numId, 0))?.kind;

  /// The abstract list whose numbers list [numId] goes on counting: Word
  /// counts the lists of one abstract list together.
  Object? groupOf(int numId) {
    final list = _lists[numId];
    return list == null ? null : list.abstractId ?? (numId,);
  }

  /// Whether list [numId] restarts [level] at its first paragraph there, by
  /// its w:startOverride.
  bool restarts(int numId, int level) =>
      _lists[numId]?.starts.containsKey(level) ?? false;

  /// The levels list [numId] restarts by its w:startOverride, with their
  /// starts.
  Map<int, int> startOverrides(int numId) => _lists[numId]?.starts ?? const {};

  /// [level] as the abstract list of list [numId] defines it, without what
  /// the list overrides.
  WordLevel? abstractLevel(int numId, int level) =>
      _abstracts[_lists[numId]?.abstractId]?[level];

  /// Whether list [numId] numbers on its abstract list's levels, restarting
  /// some at most: it has one and redefines none of its levels.
  bool usesAbstractLevels(int numId) {
    final list = _lists[numId];
    return list != null &&
        list.abstractId != null &&
        _abstracts.containsKey(list.abstractId) &&
        list.redefined.isEmpty;
  }

  /// Whether the part has abstract list [id].
  bool hasAbstract(int id) => _abstracts.containsKey(id);

  /// Whether the part has list [numId].
  bool hasList(int numId) => _lists.containsKey(numId);

  /// The lists that number as one: each list that redefines and restarts
  /// none of its levels numbers as the other such lists of its abstract
  /// list; any other list numbers on its own.
  Object sameNumbering(int numId) {
    final list = _lists[numId];
    final abstractId = list?.abstractId;
    return list != null &&
            abstractId != null &&
            list.redefined.isEmpty &&
            list.starts.isEmpty
        ? ('abstract', abstractId)
        : ('list', numId);
  }
}

/// List definitions that Voges Word adds when saving.
class NumberingPlan {
  NumberingPlan(this._numbering);

  final DocxNumbering _numbering;
  final _abstracts = <ListKind, int>{};
  final _shared = <ListKind, int>{};
  final _nums = <int, int>{};
  late final _abstractIds = _Ids(
    _numbering.maxAbstractId,
    (id) => _numbering.hasAbstract(id) || _abstracts.containsValue(id),
  );
  late final _numIds = _Ids(
    _numbering.maxNumId,
    (id) => _numbering.hasList(id) || _nums.containsKey(id),
  );

  bool get isEmpty => _nums.isEmpty;

  /// The list all bullets share, or all checklist items of a state.
  int sharedList(ListKind kind) {
    assert(kind != ListKind.ordered);
    return _shared[kind] ??= _register(kind);
  }

  /// Each contiguous numbered list restarts at 1.
  int newOrderedList() => _register(ListKind.ordered);

  int _register(ListKind kind) {
    final id = _numIds.take();
    _nums[id] = _abstracts[kind] ??= _abstractIds.take();
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

/// New ids after the highest one the part has, or, past Word's range, the
/// lowest ones from 1 that are free.
class _Ids {
  _Ids(int highest, this._taken) : _next = highest + 1;

  final bool Function(int id) _taken;
  int _next;
  var _lowest = 1;

  int take() {
    if (_next >= 1 && _next <= _maxWordId && !_taken(_next)) return _next++;
    while (_taken(_lowest)) {
      _lowest++;
    }
    return _lowest++;
  }
}
