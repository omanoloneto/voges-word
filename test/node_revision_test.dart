// ignore_for_file: experimental_member_use

import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

/// The editor builds again the paragraphs whose revision moved, so an edit
/// has to move the revision of what it touched and of nothing else. Each
/// case runs on the tree the editor builds and on the one Quill built.
final _twins = <String, Document Function(Delta)>{
  'editor': Document.fromDelta,
  'Quill': Document.fromDeltaByInserts,
};

Delta _five() => Delta()
  ..insert('Zero\nOne two three\nTwo\n')
  ..insert('Three')
  ..insert('\n', {'list': 'bullet'})
  ..insert('Four')
  ..insert('\n', {'list': 'bullet'})
  ..insert('Five\n');

QuillController _controller(Document Function(Delta) twin, [Delta? delta]) =>
    QuillController(
      document: twin(delta ?? _five()),
      selection: const TextSelection.collapsed(offset: 0),
    );

int _offsetOf(QuillController controller, String word) {
  final start = controller.document.toPlainText().indexOf(word);
  expect(start, isNonNegative, reason: word);
  return start;
}

Map<Node, int> _revisions(Iterable<Node> nodes) =>
    Map.identity()
      ..addEntries([for (final node in nodes) MapEntry(node, node.revision)]);

/// The text of the [nodes] that are new, or changed, since [before] was
/// taken.
List<String> _changed(Iterable<Node> nodes, Map<Node, int> before) => [
  for (final node in nodes)
    if (before[node] != node.revision) node.toPlainText().trimRight(),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final MapEntry(key: name, value: twin) in _twins.entries) {
    group('node revisions ($name)', () {
      test('typing moves the paragraph typed in, and no other', () {
        final controller = _controller(twin);
        final root = controller.document.root.children;
        final before = _revisions(root);

        final at = _offsetOf(controller, 'two');
        controller.replaceText(
          at,
          0,
          'x',
          TextSelection.collapsed(offset: at + 1),
        );

        expect(_changed(root, before), ['One xtwo three']);
      });

      test('deleting moves the paragraph deleted from, and no other', () {
        final controller = _controller(twin);
        final root = controller.document.root.children;
        final before = _revisions(root);

        final at = _offsetOf(controller, 'two');
        controller.replaceText(at, 4, '', TextSelection.collapsed(offset: at));

        expect(_changed(root, before), ['One three']);
      });

      test('formatting a word moves its paragraph, and no other', () {
        final controller = _controller(twin);
        final root = controller.document.root.children;
        final before = _revisions(root);

        controller.formatText(_offsetOf(controller, 'two'), 3, Attribute.bold);

        expect(_changed(root, before), ['One two three']);
        before
          ..clear()
          ..addAll(_revisions(root));

        controller.formatText(
          _offsetOf(controller, 'two'),
          3,
          Attribute.clone(Attribute.bold, null),
        );

        expect(_changed(root, before), ['One two three']);
      });

      test('formatting a paragraph moves it, and no other', () {
        final controller = _controller(twin);
        final root = controller.document.root.children;
        final before = _revisions(root);

        controller.formatText(
          _offsetOf(controller, 'Two'),
          0,
          Attribute.centerAlignment,
        );

        expect(_changed(root, before), ['Two']);
      });

      test('Enter moves the paragraph it splits and makes a new one', () {
        final controller = _controller(twin);
        final root = controller.document.root.children;
        final before = _revisions(root);

        final at = _offsetOf(controller, ' three');
        controller.replaceText(
          at,
          0,
          '\n',
          TextSelection.collapsed(offset: at + 1),
        );

        expect(_changed(root, before), ['One two', ' three']);
      });

      test('joining two paragraphs moves the one that stays', () {
        final controller = _controller(twin);
        final root = controller.document.root.children;
        final before = _revisions(root);

        final at = _offsetOf(controller, 'Two') - 1;
        controller.replaceText(at, 1, '', TextSelection.collapsed(offset: at));

        expect(_changed(root, before), ['One two threeTwo']);
      });

      test('typing in a list moves the list and the item typed in', () {
        final controller = _controller(twin);
        final root = controller.document.root.children;
        final before = _revisions(root);
        final list = root.whereType<Block>().single.children;
        final items = _revisions(list);

        final at = _offsetOf(controller, 'Four');
        controller.replaceText(
          at,
          0,
          'x',
          TextSelection.collapsed(offset: at + 1),
        );

        expect(_changed(root, before), ['Three\nxFour']);
        expect(_changed(list, items), ['xFour']);
      });

      test('a paragraph that joins a list leaves the others alone', () {
        final controller = _controller(twin);
        final root = controller.document.root.children;
        final before = _revisions(root);

        controller.formatText(_offsetOf(controller, 'Two'), 0, Attribute.ul);

        expect(_changed(root, before), ['Two\nThree\nFour']);
      });

      test('the caret alone moves nothing', () {
        final controller = _controller(twin);
        final root = controller.document.root.children;
        final before = _revisions(root);

        controller.updateSelection(
          const TextSelection(baseOffset: 2, extentOffset: 12),
          ChangeSource.local,
        );

        expect(_changed(root, before), isEmpty);
      });

      test('undo moves the paragraph it restores', () {
        final controller = _controller(twin);
        final root = controller.document.root.children;
        final at = _offsetOf(controller, 'two');
        controller.replaceText(
          at,
          0,
          'x',
          TextSelection.collapsed(offset: at + 1),
        );
        final before = _revisions(root);

        controller.undo();

        expect(_changed(root, before), ['One two three']);
      });
    });
  }
}
