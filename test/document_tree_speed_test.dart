import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/tables.dart';

// Bounds are several times what a laptop takes in debug mode, so slow
// machines pass; before these steps were linear they took minutes.
const _bound = Duration(seconds: 10);
const _timeout = Timeout(Duration(minutes: 4));

T _timed<T>(String what, T Function() work) {
  final watch = Stopwatch()..start();
  final result = work();
  expect(watch.elapsed, lessThan(_bound), reason: what);
  return result;
}

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

  test('a paragraph of 100k runs gives its delta quickly', () {
    final delta = Delta();
    for (var index = 0; index < 100000; index++) {
      delta.insert('word $index ', index.isEven ? {'bold': true} : null);
    }
    delta.insert('\n');
    final document = Document.fromDelta(delta);
    final line = document.root.children.single as Line;
    expect(line.childCount, 100000);
    expect(_timed('line', line.toDelta), delta);
    expect(_timed('document', document.root.toDelta), delta);
  }, timeout: _timeout);
}
