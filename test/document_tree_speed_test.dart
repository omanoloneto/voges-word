// ignore_for_file: experimental_member_use

import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/tables.dart';

// Bounds are several times what a laptop takes in debug mode, so slow
// machines pass; before these steps were linear they took minutes.
const _bound = Duration(seconds: 10);
const _timeout = Timeout(Duration(minutes: 4));

// Commands on everything take under a second in debug mode on a laptop.
const _commandBound = Duration(seconds: 20);

T _timed<T>(String what, T Function() work, {Duration bound = _bound}) {
  final watch = Stopwatch()..start();
  final result = work();
  expect(watch.elapsed, lessThan(bound), reason: what);
  return result;
}

T _command<T>(String what, T Function() work) =>
    _timed(what, work, bound: _commandBound);

/// Paragraphs as a long .txt opens.
Delta _plainLines(int count) {
  final text = StringBuffer();
  for (var index = 0; index < count; index++) {
    text.write('Line $index of the document.\n');
  }
  return Delta()..insert(text.toString());
}

/// A controller with all of [delta] selected, as after Ctrl+A.
QuillController _allSelected(Delta delta) {
  final document = Document.fromDelta(delta);
  return QuillController(
    document: document,
    selection: TextSelection(baseOffset: 0, extentOffset: document.length - 1),
  );
}

/// Each command is undone on its own, as when the user pauses between them.
void _pause(QuillController controller) =>
    controller.document.history.lastRecorded = 0;

/// Lines as the readers make them: formatted text, then a line break with
/// list, heading, alignment or hidden paragraph attributes.
Delta _formattedLines(int count) {
  final delta = Delta();
  for (var index = 0; index < count; index++) {
    delta
      ..insert('Line $index ', {'bold': true})
      ..insert('of the document')
      ..insert('\n', switch (index % 6) {
        0 || 1 => {'list': 'bullet', HiddenAttributes.numbering: '1'},
        2 => {'header': 2},
        3 => {
          'align': 'center',
          HiddenAttributes.paragraphProperties: '<w:pPr/>',
        },
        _ => null,
      });
  }
  return delta;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('40k formatted lines load quickly', () {
    final delta = _formattedLines(40000);
    expect(delta.length, greaterThan(100000));
    final document = _timed('load', () => Document.fromDelta(delta));
    expect(document.root.childCount, 33333);
    expect(document.toPlainText(), startsWith('Line 0 of the document\n'));
  }, timeout: _timeout);

  test('100k lines in one insert load quickly', () {
    final text = StringBuffer();
    for (var index = 0; index < 100000; index++) {
      text.write('Line $index of the document.\n');
    }
    final document = _timed(
      'load',
      () => Document.fromDelta(Delta()..insert(text.toString())),
    );
    expect(document.root.childCount, 100000);
  }, timeout: _timeout);

  test('a table cell with 40k lines opens quickly', () {
    final tables = TableStore();
    final controller = _timed(
      'cell',
      () => tables.newCellController(_formattedLines(40000)),
    );
    expect(controller.document.root.childCount, 33333);
  }, timeout: _timeout);

  test('the offset of every line of 100k is found quickly', () {
    final document = Document.fromDelta(_formattedLines(100000));
    final lines = [
      for (final node in document.root.children)
        if (node is Block) ...node.children else node,
    ];
    expect(lines, hasLength(100000));
    final offsets = _timed('in order', () {
      return [for (final line in lines) line.documentOffset];
    });
    expect(offsets.last, document.length - lines.last.length);

    // An edit at the top makes every offset below it unknown.
    document.root.insert(0, 'x', null);
    final backwards = _timed('backwards', () {
      return [for (final line in lines.reversed) line.documentOffset];
    });
    expect(backwards.first, offsets.last + 1);
    expect(backwards.last, 0);
  }, timeout: _timeout);

  test(
    'an edit at the top of 200k lines does not run out of stack',
    () {
      final text = StringBuffer();
      for (var index = 0; index < 200000; index++) {
        text.write('Line $index\n');
      }
      final document = Document.fromDelta(Delta()..insert(text.toString()));
      _timed('edit', () => document.root.insert(0, 'x', null));
      expect(
        document.root.children.last.documentOffset,
        text.length - 'Line 199999\n'.length + 1,
      );
    },
    timeout: _timeout,
  );

  // Quill recursed once per line, out of stack from 50k lines, and changed
  // each line after searching the tree from the first one: minutes.
  group('with 100k lines selected', () {
    test('the ribbon reads the style and Copy takes the text', () {
      for (final delta in [_plainLines(100000), _formattedLines(100000)]) {
        final controller = _allSelected(delta);
        final style = _command('style', controller.getSelectionStyle);
        expect(style.containsKey(Attribute.bold.key), isFalse);
        _command('copy', () => controller.clipboardSelection(true));
        expect(
          controller.pastePlainText,
          controller.document.toPlainText().substring(
            0,
            controller.document.length - 1,
          ),
        );
        _command('styles', controller.getAllSelectionStyles);
        _command(
          'styles with offsets',
          () => controller.document.collectAllStylesWithOffset(
            0,
            controller.selection.end,
          ),
        );
      }
    }, timeout: _timeout);

    test('Bold and Bold again', () {
      final delta = _plainLines(100000);
      final controller = _allSelected(delta);
      _command('bold', () => controller.formatSelection(Attribute.bold));
      expect(controller.getSelectionStyle().attributes, {
        Attribute.bold.key: Attribute.bold,
      });
      _pause(controller);
      _command(
        'bold again',
        () => controller.formatSelection(Attribute.clone(Attribute.bold, null)),
      );
      expect(controller.document.toDelta(), delta);
      _pause(controller);
      _command('undo', controller.undo);
      expect(controller.document.toDelta().length, 200000);
    }, timeout: _timeout);

    test('Delete and Undo', () {
      for (final delta in [_plainLines(100000), _formattedLines(100000)]) {
        final controller = _allSelected(delta);
        _command(
          'delete',
          () => controller.replaceText(
            0,
            controller.selection.end,
            '',
            const TextSelection.collapsed(offset: 0),
          ),
        );
        expect(controller.document.length, 1);
        _pause(controller);
        _command('undo', controller.undo);
        expect(controller.document.toDelta(), delta);
      }
    }, timeout: _timeout);

    test('a list on every paragraph', () {
      final controller = _allSelected(_formattedLines(100000));
      _command('list', () => controller.formatSelection(Attribute.ul));
      expect(
        controller.getSelectionStyle().attributes[Attribute.list.key],
        Attribute.ul,
      );
    }, timeout: _timeout);
  });

  test('a paragraph of 100k runs gives its delta quickly', () {
    final delta = _runs(100000);
    final document = Document.fromDelta(delta);
    final line = document.root.children.single as Line;
    expect(line.childCount, 100000);
    expect(_timed('line', line.toDelta), delta);
    expect(_timed('document', document.root.toDelta), delta);
  }, timeout: _timeout);

  // Each run counted its offset from the start of its line, so reading them
  // all, as the editor does while the keyboard composes and as Indent did,
  // took minutes.
  test(
    'a paragraph of 100k runs is split, joined and read quickly',
    () {
      final delta = _runs(100000);
      final controller = QuillController(
        document: Document.fromDelta(delta),
        selection: const TextSelection.collapsed(offset: 0),
      );
      final document = controller.document;
      List<int> offsets() => [
        for (final line in document.root.children)
          for (final run in (line as Line).children) run.documentOffset,
      ];

      // As the editor reads them while the keyboard composes text.
      final before = _timed('offsets', offsets);
      expect(before[1], 'word 0 '.length);
      final middle = before[50000];
      _command(
        'enter',
        () => controller.replaceText(
          middle,
          0,
          '\n',
          TextSelection.collapsed(offset: middle + 1),
        ),
      );
      expect(_timed('offsets after enter', offsets), [
        ...before.take(50000),
        for (final offset in before.skip(50000)) offset + 1,
      ]);
      _command(
        'backspace',
        () => controller.replaceText(
          middle,
          1,
          '',
          TextSelection.collapsed(offset: middle),
        ),
      );
      expect(document.toDelta(), delta);
      expect(_timed('offsets after backspace', offsets), before);

      controller.updateSelection(
        TextSelection(baseOffset: 0, extentOffset: document.length - 1),
        ChangeSource.local,
      );
      _command('copy', () => controller.clipboardSelection(true));
      expect(
        controller.pastePlainText,
        document.toPlainText().substring(0, document.length - 1),
      );
      final styles = _command(
        'styles with offsets',
        () => document.collectAllStylesWithOffset(0, document.length - 1),
      );
      expect([for (final style in styles.take(100000)) style.offset], before);
    },
    timeout: _timeout,
  );
}

/// One paragraph of [count] runs, bold and plain in turn.
Delta _runs(int count) {
  final delta = Delta();
  for (var index = 0; index < count; index++) {
    delta.insert('word $index ', index.isEven ? {'bold': true} : null);
  }
  return delta..insert('\n');
}
