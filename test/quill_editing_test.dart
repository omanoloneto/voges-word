// ignore_for_file: experimental_member_use

import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

/// Quill 11.5.0 failed these edits the same way on the tree the editor
/// builds and on the one Quill built, so each runs on both.
final _twins = <String, Document Function(Delta)>{
  'editor': Document.fromDelta,
  'Quill': Document.fromDeltaByInserts,
};

/// What the system clipboard last received.
String? _clipboard;

QuillController _controller(Document Function(Delta) twin, Delta delta) =>
    QuillController(
      document: twin(delta),
      selection: const TextSelection.collapsed(offset: 0),
    );

void _select(QuillController controller, int start, int end) =>
    controller.updateSelection(
      TextSelection(baseOffset: start, extentOffset: end),
      ChangeSource.local,
    );

/// [text] over the selection, as the keyboard sends Enter or a paste.
void _type(QuillController controller, String text) {
  final selection = controller.selection;
  controller.replaceText(
    selection.start,
    selection.end - selection.start,
    text,
    TextSelection.collapsed(offset: selection.start + text.length),
  );
}

(int, int) _find(QuillController controller, String word) {
  final start = controller.document.toPlainText().indexOf(word);
  expect(start, isNonNegative, reason: word);
  return (start, start + word.length);
}

/// What Copy, or Cut, of [word] puts on the system clipboard.
Future<String?> _copy(
  QuillController controller,
  String word, {
  bool cut = false,
}) async {
  final (start, end) = _find(controller, word);
  _select(controller, start, end);
  _clipboard = null;
  controller.clipboardSelection(!cut);
  await Future<void>.delayed(Duration.zero);
  return _clipboard;
}

/// Save writes document.toDelta() and the page shows the tree: both must
/// be [expected], with every node's offset the length of the text before it.
void _expectDocument(QuillController controller, Delta expected) {
  final document = controller.document;
  expect(document.toDelta(), expected);
  expect(document.root.toDelta(), expected);
  expect(_wrongOffset(document.root), isNull);
}

/// Copy, Indent and Cut of [paragraph], after the edit under test, touch
/// that text and its line break only.
Future<void> _expectCopyIndentCut(
  QuillController controller,
  String paragraph,
) async {
  final (start, end) = _find(controller, paragraph);
  final before = controller.document.toDelta();
  final lineBreak = (DeltaIterator(before)..skip(end)).next(1);
  expect(lineBreak.data, '\n');
  final indent = lineBreak.attributes?['indent'] as int? ?? 0;

  expect(await _copy(controller, paragraph), paragraph);
  controller.indentSelection(true);
  final indented = before.compose(
    Delta()
      ..retain(end)
      ..retain(1, {'indent': indent + 1}),
  );
  _expectDocument(controller, indented);

  expect(await _copy(controller, paragraph, cut: true), paragraph);
  _expectDocument(
    controller,
    indented.compose(
      Delta()
        ..retain(start)
        ..delete(end - start),
    ),
  );
}

String? _wrongOffset(Node node, [int start = 0, String path = 'root']) {
  final children = switch (node) {
    Root() => node.children.toList(),
    Block() => node.children.toList(),
    Line() => node.children.toList(),
    _ => const <Node>[],
  };
  var offset = start;
  for (final (index, child) in children.indexed) {
    if (child.documentOffset != offset) {
      return '$path/$index: ${child.documentOffset} instead of $offset';
    }
    final found = _wrongOffset(child, offset, '$path/$index');
    if (found != null) return found;
    offset += child.toPlainText().length;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            _clipboard = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  for (final MapEntry(key: name, value: twin) in _twins.entries) {
    group('Enter or a paste over a heading in a block ($name)', () {
      test('splits a centered Heading 1 that ends the document', () async {
        final original = Delta()
          ..insert('Title')
          ..insert('\n', {'header': 1, 'align': 'center'});
        final controller = _controller(twin, original);
        _select(controller, 0, 1);

        _type(controller, '\n');

        _expectDocument(
          controller,
          Delta()
            ..insert('\n', {'header': 1, 'align': 'center'})
            ..insert('itle')
            ..insert('\n', {'align': 'center'}),
        );
        await _expectCopyIndentCut(controller, 'itle');
        while (controller.hasUndo) {
          controller.undo();
        }
        _expectDocument(controller, original);
      });

      test('pastes two lines over a word of a numbered Heading 2', () async {
        final controller = _controller(
          twin,
          Delta()
            ..insert('Chapter one')
            ..insert('\n', {'header': 2, 'list': 'ordered'})
            ..insert('End\n'),
        );
        _select(controller, 0, 7);

        _type(controller, 'Part\nTwo');

        _expectDocument(
          controller,
          Delta()
            ..insert('Part')
            ..insert('\n', {'header': 2, 'list': 'ordered'})
            ..insert('Two one')
            ..insert('\n', {'list': 'ordered'})
            ..insert('End\n'),
        );
        await _expectCopyIndentCut(controller, 'Two one');
      });

      test('leaves the heading of the next paragraph alone', () async {
        final controller = _controller(
          twin,
          Delta()
            ..insert('Title')
            ..insert('\n', {'header': 1, 'align': 'center'})
            ..insert('\n', {'header': 2})
            ..insert('Body\n'),
        );
        _select(controller, 0, 1);

        _type(controller, '\n');

        _expectDocument(
          controller,
          Delta()
            ..insert('\n', {'header': 1, 'align': 'center'})
            ..insert('itle')
            ..insert('\n', {'align': 'center'})
            ..insert('\n', {'header': 2})
            ..insert('Body\n'),
        );
        await _expectCopyIndentCut(controller, 'itle');
      });
    });

    group('Enter over a selection from an empty last line ($name)', () {
      test('of a nested list', () async {
        final controller = _controller(
          twin,
          Delta()
            ..insert('Item')
            ..insert('\n\n', {'list': 'bullet', 'indent': 1})
            ..insert('Next paragraph\n'),
        );
        _select(controller, 5, 8);

        _type(controller, '\n');

        _expectDocument(
          controller,
          Delta()
            ..insert('Item')
            ..insert('\n\n', {'list': 'bullet', 'indent': 1})
            ..insert('xt paragraph\n'),
        );
        await _expectCopyIndentCut(controller, 'xt paragraph');
      });

      test('that is a centered heading', () async {
        final controller = _controller(
          twin,
          Delta()
            ..insert('Intro\n')
            ..insert('\n', {'header': 2, 'align': 'center'})
            ..insert('Body text here\n'),
        );
        _select(controller, 6, 10);

        _type(controller, '\n');

        _expectDocument(
          controller,
          Delta()
            ..insert('Intro\n')
            ..insert('\n', {'header': 2, 'align': 'center'})
            ..insert('y text here\n'),
        );
        await _expectCopyIndentCut(controller, 'y text here');
      });

      test('while Enter at the caret there still ends the list', () async {
        final controller = _controller(
          twin,
          Delta()
            ..insert('Item')
            ..insert('\n\n', {'list': 'bullet'})
            ..insert('Next\n'),
        );
        _select(controller, 5, 5);

        _type(controller, '\n');

        _expectDocument(
          controller,
          Delta()
            ..insert('Item')
            ..insert('\n', {'list': 'bullet'})
            ..insert('\nNext\n'),
        );
        await _expectCopyIndentCut(controller, 'Next');
      });
    });

    group('Copy, Cut and Indent take the selected text ($name)', () {
      test('after Enter splits a paragraph', () async {
        final controller = _controller(
          twin,
          Delta()
            ..insert('One ')
            ..insert('two ', {'bold': true})
            ..insert('three four five six\n'),
        );
        expect(await _copy(controller, 'six'), 'six');

        controller.replaceText(
          4,
          0,
          '\n',
          const TextSelection.collapsed(offset: 5),
        );

        for (final word in ['six', 'five', 'three']) {
          expect(await _copy(controller, word), word);
        }
        _expectDocument(
          controller,
          Delta()
            ..insert('One \n')
            ..insert('two ', {'bold': true})
            ..insert('three four five six\n'),
        );
      });

      test('after Backspace joins two paragraphs', () async {
        final controller = _controller(
          twin,
          Delta()
            ..insert('Hi ', {'bold': true})
            ..insert('\n')
            ..insert('Say ', {'italic': true})
            ..insert('hello and goodbye\n'),
        );
        expect(await _copy(controller, 'hello'), 'hello');

        controller.replaceText(
          3,
          1,
          '',
          const TextSelection.collapsed(offset: 3),
        );

        expect(await _copy(controller, 'hello', cut: true), 'hello');
        expect(controller.pastePlainText, 'hello');
        _expectDocument(
          controller,
          Delta()
            ..insert('Hi ', {'bold': true})
            ..insert('Say ', {'italic': true})
            ..insert(' and goodbye\n'),
        );
      });

      test('after a picture goes in between two runs', () async {
        final controller = _controller(
          twin,
          Delta()
            ..insert('Total: ')
            ..insert('42', {'bold': true})
            ..insert(' items here\n'),
        );
        expect(await _copy(controller, 'items'), 'items');

        controller.replaceText(7, 0, BlockEmbed.image('chart.png'), null);

        expect(await _copy(controller, 'items'), 'items');
        expect(await _copy(controller, '42'), '42');
        _expectDocument(
          controller,
          Delta()
            ..insert('Total: ')
            ..insert(BlockEmbed.image('chart.png').toJson())
            ..insert('42', {'bold': true})
            ..insert(' items here\n'),
        );
      });

      test('Indent after Enter changes only the selected paragraph', () async {
        final controller = _controller(
          twin,
          Delta()
            ..insert('Intro paragraph that is fairly long ')
            ..insert('bold', {'bold': true})
            ..insert(' end of it\nSecond paragraph\nThird paragraph\n'),
        );
        expect(await _copy(controller, 'end'), 'end');
        final (bold, _) = _find(controller, 'bold');
        controller.replaceText(
          bold,
          0,
          '\n',
          TextSelection.collapsed(offset: bold + 1),
        );
        final (start, end) = _find(controller, 'bold end of it');
        _select(controller, start, end);

        controller.indentSelection(true);

        _expectDocument(
          controller,
          Delta()
            ..insert('Intro paragraph that is fairly long \n')
            ..insert('bold', {'bold': true})
            ..insert(' end of it')
            ..insert('\n', {'indent': 1})
            ..insert('Second paragraph\nThird paragraph\n'),
        );
      });

      test('Indent of a list item leaves the next one alone', () {
        final controller = _controller(
          twin,
          Delta()
            ..insert('One')
            ..insert('\n', {'list': 'bullet', 'indent': 1})
            ..insert('Two')
            ..insert('\n', {'list': 'bullet', 'indent': 1})
            ..insert('Three')
            ..insert('\n', {'list': 'bullet', 'indent': 1}),
        );
        _select(controller, 4, 7);

        controller.indentSelection(true);
        controller.document.history.lastRecorded = 0;

        _expectDocument(
          controller,
          Delta()
            ..insert('One')
            ..insert('\n', {'list': 'bullet', 'indent': 1})
            ..insert('Two')
            ..insert('\n', {'list': 'bullet', 'indent': 2})
            ..insert('Three')
            ..insert('\n', {'list': 'bullet', 'indent': 1}),
        );

        controller.indentSelection(false);
        controller.indentSelection(false);

        _expectDocument(
          controller,
          Delta()
            ..insert('One')
            ..insert('\n', {'list': 'bullet', 'indent': 1})
            ..insert('Two')
            ..insert('\n', {'list': 'bullet'})
            ..insert('Three')
            ..insert('\n', {'list': 'bullet', 'indent': 1}),
        );
      });

      test('Indent from the middle of a paragraph leaves the next one', () {
        final controller = _controller(
          twin,
          Delta()..insert('First paragraph here\nSecond paragraph\n'),
        );
        _select(controller, 6, 20);

        controller.indentSelection(true);

        _expectDocument(
          controller,
          Delta()
            ..insert('First paragraph here')
            ..insert('\n', {'indent': 1})
            ..insert('Second paragraph\n'),
        );
      });
    });
  }
}
