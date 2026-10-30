import 'dart:convert';
import 'dart:math';

import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/embeds.dart';

/// The first difference between two trees, with its path, or null. Lengths
/// and offsets are checked by [_staleCache].
String? _difference(Node actual, Node expected, [String path = 'root']) {
  if (actual.runtimeType != expected.runtimeType) {
    return '$path: ${actual.runtimeType} instead of ${expected.runtimeType}';
  }
  final style = _styleJson(actual.style);
  if (style != _styleJson(expected.style)) {
    return '$path: style $style instead of ${_styleJson(expected.style)}';
  }
  final children = _children(actual);
  final others = _children(expected);
  if (children.length != others.length) {
    return '$path: ${children.length} children instead of ${others.length}';
  }
  for (var index = 0; index < children.length; index++) {
    if (!identical(children[index].parent, actual)) {
      return '$path/$index: wrong parent';
    }
    final found = _difference(children[index], others[index], '$path/$index');
    if (found != null) return found;
  }
  switch ((actual, expected)) {
    case (final QuillText a, final QuillText e) when a.value != e.value:
      return '$path: "${a.value}" instead of "${e.value}"';
    case (final Embed a, final Embed e)
        when a.value.runtimeType != e.value.runtimeType ||
            jsonEncode(a.value.toJson()) != jsonEncode(e.value.toJson()):
      return '$path: embed ${a.value.toJson()} instead of ${e.value.toJson()}';
  }
  return null;
}

List<Node> _children(Node node) => switch (node) {
  Root() => node.children.toList(),
  Block() => node.children.toList(),
  Line() => node.children.toList(),
  _ => const [],
};

/// Attributes in their order, which is the order they are saved in.
String _styleJson(Style style) => jsonEncode([
  for (final MapEntry(:key, :value) in style.attributes.entries)
    [key, value.key, value.scope.name, value.value],
]);

/// Counted from the leaves, so a stale cached length shows up.
int _countedLength(Node node) => switch (node) {
  QuillText() => node.value.length,
  Embed() => 1,
  Line() => _children(
    node,
  ).fold(1, (sum, child) => sum + _countedLength(child)),
  _ => _children(node).fold(0, (sum, child) => sum + _countedLength(child)),
};

/// The first node whose cached length or offset is not what counting from
/// the leaves gives, or null. Quill can leave a leaf's offset stale after
/// some edits, so [leaves] is false after editing.
String? _staleCache(
  Node node, {
  bool leaves = true,
  int start = 0,
  String path = 'root',
}) {
  if (node.length != _countedLength(node)) return '$path: length';
  var offset = 0;
  final children = _children(node);
  for (var index = 0; index < children.length; index++) {
    final child = children[index];
    final childPath = '$path/$index';
    final documentOffset = node is Root ? offset : start + offset;
    if (leaves || node is! Line) {
      if (child.offset != offset) {
        return '$childPath: offset ${child.offset} instead of $offset';
      }
      if (child.documentOffset != documentOffset) {
        return '$childPath: document offset ${child.documentOffset} '
            'instead of $documentOffset';
      }
    }
    final found = _staleCache(
      child,
      leaves: leaves,
      start: documentOffset,
      path: childPath,
    );
    if (found != null) return found;
    offset += _countedLength(child);
  }
  return null;
}

/// The node's delta as Quill made it, folding the children's with concat.
Delta _concatenated(Node node) {
  if (node is Leaf) return node.toDelta();
  final delta = _children(
    node,
  ).map(_concatenated).fold(Delta(), (a, b) => a.concat(b));
  if (node is! Line) return delta;
  final parent = node.parent;
  final style = parent is Block
      ? node.style.mergeAll(parent.style)
      : node.style;
  return delta..insert('\n', style.toJson());
}

String _deltaJson(Delta delta) => jsonEncode(delta.toJson());

/// Reads some offsets in random order, so the caches hold a mix of known and
/// unknown offsets before an edit.
void _readSomeOffsets(Document document, Random random) {
  final nodes = <Node>[];
  void collect(Node node) {
    nodes.add(node);
    _children(node).forEach(collect);
  }

  collect(document.root);
  nodes.shuffle(random);
  for (final node in nodes.take(random.nextInt(nodes.length + 1))) {
    node.documentOffset;
  }
}

/// Builds both ways and compares everything a document exposes.
void _expectSameDocument(Delta delta, String reason) {
  final Document expected;
  try {
    expected = Document.fromDeltaByInserts(delta);
  } catch (error) {
    expect(
      () => Document.fromDelta(delta),
      throwsA(
        isA<Object>().having((e) => e.runtimeType, 'type', error.runtimeType),
      ),
      reason: reason,
    );
    return;
  }
  final actual = Document.fromDelta(delta);
  expect(_staleCache(expected.root), isNull, reason: reason);
  expect(_staleCache(actual.root), isNull, reason: reason);
  expect(_difference(actual.root, expected.root), isNull, reason: reason);
  expect(actual.toDelta(), expected.toDelta(), reason: reason);
  expect(
    _deltaJson(actual.root.toDelta()),
    _deltaJson(_concatenated(expected.root)),
    reason: reason,
  );
  expect(actual.toPlainText(), expected.toPlainText(), reason: reason);
  expect(actual.length, expected.length, reason: reason);
  expect(actual.isEmpty(), expected.isEmpty(), reason: reason);
}

/// Random documents in the shapes the readers and the editor make: inline,
/// block and hidden attributes, line breaks alone or inside text, embeds at
/// the start, middle and end of lines, and operations that Delta.push would
/// have joined.
class _Deltas {
  _Deltas(int seed) : _random = Random(seed);

  final Random _random;

  static final _inline = <Map<String, Object?>>[
    {'bold': true},
    {'italic': true},
    {'underline': true},
    {'strike': true},
    {'small': true},
    {'code': true},
    {'link': 'https://example.com/a'},
    {'link': '#mark'},
    {'color': '#FF0000'},
    {'background': '#FFFF00'},
    {'size': '14'},
    {'size': 'large'},
    {'font': 'Carlito'},
    {'script': 'super'},
    {'script': 'sub'},
    {'bold': null},
    {'italic': null},
    {'link': null},
    {HiddenAttributes.runProperties: '<w:rPr><w:caps/></w:rPr>'},
    {HiddenAttributes.bookmarks: '["_Toc1"]'},
    {HiddenAttributes.package: 'p1'},
    {'vw-unknown': 3},
    {'width': '120', 'height': '80'},
  ];

  static final _block = <Map<String, Object?>>[
    {'list': 'bullet'},
    {'list': 'ordered'},
    {'list': 'checked'},
    {'list': 'unchecked'},
    {'list': null},
    {'code-block': true},
    {'blockquote': true},
    {'indent': 1},
    {'indent': 2},
    {'indent': 3},
    {'indent': null},
    {'align': 'center'},
    {'align': 'right'},
    {'align': 'justify'},
    {'align': null},
    {'header': 1},
    {'header': 2},
    {'header': 6},
    {'header': null},
    {'direction': 'rtl'},
    {'line-height': 1.5},
    {HiddenAttributes.paragraphProperties: '<w:pPr><w:keepNext/></w:pPr>'},
    {HiddenAttributes.numbering: '3'},
    {HiddenAttributes.spaceBefore: 6.0},
    {HiddenAttributes.spaceAfter: 12.0},
    {HiddenAttributes.indentRight: 0.5},
    {HiddenAttributes.firstLine: 18.0},
    {HiddenAttributes.contextualGroup: 'ListParagraph'},
  ];

  static final _embeds = <Object>[
    {EmbedTypes.image: 'data:image/png;base64,iVBORw0KGgo='},
    {EmbedTypes.table: encodeTableId('t1')},
    {EmbedTypes.pageBreak: 'page'},
    {EmbedTypes.sectionBreak: encodeSection('<w:sectPr/>')},
    {
      EmbedTypes.opaqueBlock: const OpaqueContent(
        xml: '<w:sdt/>',
        text: 'Contents',
        label: OpaqueLabels.tableOfContents,
      ).encode(),
    },
    {
      EmbedTypes.opaqueInline: const OpaqueContent(
        xml: '<w:fldSimple w:instr="DATE"/>',
        text: '1/1/2026',
      ).encode(),
    },
    {EmbedTypes.pageNumber: 'PAGE'},
    {'video': 'https://example.com/v.mp4'},
    {
      'custom': {'nested': true},
    },
    BlockEmbed.image('picture.png'),
    const Embeddable(EmbedTypes.pageBreak, 'page'),
  ];

  static final _pieces = [
    'a',
    'word',
    'Two words',
    ' ',
    'ção',
    '☐',
    '☑ done',
    '😀',
    '\t',
    'x' * 40,
  ];

  T _pick<T>(List<T> items) => items[_random.nextInt(items.length)];

  bool _chance(double probability) => _random.nextDouble() < probability;

  /// 0 to 3 attributes of [sources], in random order.
  Map<String, Object?>? _attributes(List<Map<String, Object?>> sources) {
    if (_chance(0.35)) return null;
    final attributes = <String, Object?>{};
    final count = _random.nextInt(4);
    for (var index = 0; index < count; index++) {
      attributes.addAll(_pick(sources));
    }
    if (attributes.isEmpty && _chance(0.5)) return null;
    final keys = attributes.keys.toList()..shuffle(_random);
    return {for (final key in keys) key: attributes[key]};
  }

  String _text({required bool lineBreaks}) {
    final buffer = StringBuffer();
    final count = 1 + _random.nextInt(4);
    for (var index = 0; index < count; index++) {
      if (lineBreaks && _chance(0.4)) {
        buffer.write('\n' * (1 + _random.nextInt(3)));
      }
      buffer.write(_pick(_pieces));
    }
    if (lineBreaks && _chance(0.3)) buffer.write('\n');
    return buffer.toString();
  }

  Operation _operation() {
    final kind = _random.nextInt(10);
    if (kind < 4) {
      return Operation.insert(
        _text(lineBreaks: false),
        _attributes([..._inline, if (_chance(0.1)) ..._block]),
      );
    }
    if (kind < 6) {
      return Operation.insert(
        _text(lineBreaks: true),
        _attributes([..._inline, ..._block]),
      );
    }
    if (kind < 8) {
      return Operation.insert(
        '\n' * (_chance(0.8) ? 1 : 2 + _random.nextInt(3)),
        _attributes([..._block, ..._block, ..._inline]),
      );
    }
    if (kind < 9) {
      return Operation.insert(_pick(_embeds), _attributes(_inline));
    }
    return Operation.insert('', _attributes(_inline));
  }

  /// Through [Delta.push], as readers build them, or as raw operations.
  Delta next(int maxOperations) {
    final count = 1 + _random.nextInt(maxOperations);
    final operations = [for (var i = 0; i < count; i++) _operation()];
    final last = operations.last.data;
    if (last is! String || !last.endsWith('\n')) {
      operations.add(
        Operation.insert('\n', _attributes([..._block, ..._inline])),
      );
    }
    if (_chance(0.5)) return Delta.fromOperations(operations);
    final delta = Delta();
    for (final operation in operations) {
      delta.push(operation);
    }
    return delta;
  }
}

Delta _ops(List<Object> items) => Delta.fromOperations([
  for (final item in items) item is Operation ? item : Operation.insert(item),
]);

void main() {
  group('Document.fromDelta builds the tree Quill built', () {
    test('for thousands of random documents', () {
      for (var seed = 0; seed < 4000; seed++) {
        final delta = _Deltas(seed).next(seed % 10 == 0 ? 60 : 16);
        _expectSameDocument(delta, 'seed $seed: ${jsonEncode(delta.toJson())}');
      }
    });

    test('for long random documents with long blocks', () {
      for (var seed = 0; seed < 40; seed++) {
        final generator = _Deltas(100000 + seed);
        final delta = Delta();
        for (var line = 0; line < 400; line++) {
          delta
            ..insert('Line $line ', line.isEven ? {'bold': true} : null)
            ..insert(
              '\n',
              (line ~/ 25).isEven
                  ? {'list': line % 50 < 40 ? 'bullet' : 'ordered'}
                  : generator._attributes(_Deltas._block),
            );
        }
        delta.insert('\n');
        _expectSameDocument(delta, 'long seed $seed');
      }
    });

    test('for the edge cases', () {
      final cases = <String, Delta>{
        'one line break': _ops(['\n']),
        'line breaks only': _ops(['\n\n\n\n']),
        'consecutive line breaks with a list': _ops([
          Operation.insert('\n\n\n', {'list': 'bullet'}),
        ]),
        'text then a styled line break': _ops([
          'Title',
          Operation.insert('\n', {'header': 1, 'align': 'center'}),
        ]),
        'a list item and a trailing empty paragraph': _ops([
          'Item',
          Operation.insert('\n', {'list': 'ordered'}),
          '\n',
        ]),
        'embed alone on a line': _ops([
          {EmbedTypes.table: encodeTableId('t1')},
          '\n',
        ]),
        'embeds at the start, middle and end of lines': _ops([
          {EmbedTypes.pageBreak: 'page'},
          'Text',
          {EmbedTypes.pageNumber: 'PAGE'},
          'more',
          {EmbedTypes.image: 'a.png'},
          '\n',
          {EmbedTypes.image: 'b.png'},
          {EmbedTypes.image: 'c.png'},
          Operation.insert('\n', {'list': 'bullet'}),
        ]),
        'inline attributes on line breaks': _ops([
          Operation.insert('Bold', {'bold': true}),
          Operation.insert('\n', {'bold': true, 'list': 'bullet'}),
        ]),
        'block attributes on text': _ops([
          Operation.insert('Odd', {'list': 'bullet', 'header': 2}),
          '\n',
        ]),
        'unset block attributes': _ops([
          'a',
          Operation.insert('\n', {'list': null, 'indent': null}),
          'b',
          Operation.insert('\n', {'align': null, 'list': 'bullet'}),
        ]),
        'operations Delta.push would join': _ops([
          Operation.insert('a', {'bold': true}),
          Operation.insert('b', {'bold': true}),
          Operation.insert('c', {'bold': true, 'italic': null}),
          Operation.insert('d'),
          Operation.insert('e', {'link': null}),
          '\n',
        ]),
        'empty operations': _ops([
          Operation.insert(''),
          'a',
          Operation.insert('', {'bold': true}),
          '\n',
        ]),
        'checklist lines in one block': _ops([
          '☐ one',
          Operation.insert('\n', {'list': 'unchecked'}),
          '☑ two',
          Operation.insert('\n', {'list': 'checked'}),
          'three',
          Operation.insert('\n', {'list': 'unchecked'}),
        ]),
        'nested indents and code': _ops([
          'a',
          Operation.insert('\n', {'list': 'bullet'}),
          'b',
          Operation.insert('\n', {'list': 'bullet', 'indent': 1}),
          'c',
          Operation.insert('\n', {'list': 'bullet'}),
          'd\ne',
          Operation.insert('\n', {'code-block': true}),
          Operation.insert('\n', {'blockquote': true, 'direction': 'rtl'}),
        ]),
        'hidden numbering on list lines': _ops([
          'x',
          Operation.insert('\n', {
            'list': 'ordered',
            HiddenAttributes.numbering: '7',
            HiddenAttributes.paragraphProperties: '<w:pPr/>',
          }),
          'y',
          Operation.insert('\n', {
            HiddenAttributes.numbering: '7',
            'list': 'ordered',
            HiddenAttributes.paragraphProperties: '<w:pPr/>',
          }),
        ]),
        'a multi-line operation with a block': _ops([
          Operation.insert('one\ntwo\n\nthree\n', {'list': 'bullet'}),
          Operation.insert('four\n', {'align': 'right'}),
        ]),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        _expectSameDocument(value, key);
      }
    });

    test('and refuses the same deltas', () {
      final cases = {
        'empty': Delta(),
        'not ending with a line break': _ops(['text']),
        'ending with an embed': _ops([
          {EmbedTypes.image: 'a.png'},
        ]),
        'a retain': Delta.fromOperations([
          Operation.retain(1),
          Operation.insert('\n'),
        ]),
        'a delete': Delta.fromOperations([
          Operation.insert('a'),
          Operation.delete(1),
          Operation.insert('\n'),
        ]),
        'an embed that is not a map': _ops([Operation.insert(42), '\n']),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        final Object error;
        try {
          Document.fromDeltaByInserts(value);
          fail('$key: Quill accepted it');
        } catch (e) {
          error = e;
        }
        expect(
          () => Document.fromDelta(value),
          throwsA(
            isA<Object>().having(
              (e) => e.runtimeType,
              'type',
              error.runtimeType,
            ),
          ),
          reason: key,
        );
      }
    });

    test('and edits the loaded tree the same way, with right offsets', () {
      final bold = Style.attr({Attribute.bold.key: Attribute.bold});
      final lineStyles = [
        Style.attr({Attribute.list.key: Attribute.ul}),
        Style.attr({Attribute.list.key: Attribute.ol}),
        Style.attr({Attribute.list.key: Attribute.clone(Attribute.list, null)}),
        Style.attr({Attribute.align.key: Attribute.centerAlignment}),
        Style.attr({Attribute.header.key: Attribute.h1}),
      ];
      for (var seed = 0; seed < 800; seed++) {
        final delta = _Deltas(200000 + seed).next(seed.isEven ? 20 : 60);
        final Document expected;
        try {
          expected = Document.fromDeltaByInserts(delta);
        } catch (_) {
          continue;
        }
        final actual = Document.fromDelta(delta);
        final random = Random(seed);
        for (var step = 0; step < 8; step++) {
          _readSomeOffsets(actual, Random(seed * 31 + step));
          _readSomeOffsets(expected, Random(seed * 31 + step));
          final length = expected.length;
          if (length < 2) break;
          final text = expected.root.toPlainText();
          final index = random.nextInt(length - 1);
          final lineEnd = text.indexOf('\n', index);
          final inLine = lineEnd < 0 ? 1 : max(1, lineEnd - index);
          final count = 1 + random.nextInt(min(4, length - 1 - index));
          final lineStyle = lineStyles[random.nextInt(lineStyles.length)];
          final kind = random.nextInt(5);
          void edit(Document document) => switch (kind) {
            0 => document.root.insert(index, 'ab\ncd', null),
            1 => document.root.insert(index, '\n', lineStyle),
            2 when text[index] == '\n' => document.root.retain(
              index,
              1,
              lineStyle,
            ),
            2 => document.root.retain(index, min(count, inLine), bold),
            3 => document.root.insert(index, BlockEmbed.image('a.png'), null),
            _ => document.root.delete(index, count),
          };
          Object? expectedError;
          try {
            edit(expected);
          } catch (error) {
            expectedError = error.runtimeType;
          }
          Object? actualError;
          try {
            edit(actual);
          } catch (error) {
            actualError = error.runtimeType;
          }
          final reason = 'seed $seed step $step';
          expect(actualError, expectedError, reason: reason);
          expect(
            _difference(actual.root, expected.root),
            isNull,
            reason: reason,
          );
          // A failed edit can leave a half-made tree; stop there.
          if (expectedError != null) break;
          expect(
            _staleCache(actual.root, leaves: false),
            isNull,
            reason: reason,
          );
          expect(
            _staleCache(expected.root, leaves: false),
            isNull,
            reason: reason,
          );
          expect(
            _deltaJson(actual.root.toDelta()),
            _deltaJson(_concatenated(actual.root)),
            reason: reason,
          );
        }
      }
    });
  });

  test('a leaf counts its offset from the start of its line', () {
    final document = Document.fromDelta(
      Delta()
        ..insert('aaa', {'bold': true})
        ..insert('bbb')
        ..insert('ccc', {'italic': true})
        ..insert('\n'),
    );
    final leaves = (document.root.children.first as Line).children.toList();
    expect(leaves[1].offset, 3);

    // Quill keeps the old offset of the leaf it inserts before.
    document.root.insert(
      3,
      'x',
      Style.attr({Attribute.underline.key: Attribute.underline}),
    );

    expect(leaves[2].offset, 7);
    expect(document.getPlainText(7, 3), 'ccc');
  });
}
