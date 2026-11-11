// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'dart:convert';
import 'dart:math';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_quill/src/delta/delta_writer.dart';
import 'package:flutter_test/flutter_test.dart';

const _attributes = <Map<String, dynamic>?>[
  null,
  {},
  {'bold': true},
  {'bold': true, 'italic': null},
  {'list': 'bullet'},
  {'list': null},
  {'align': 'justify', 'line-height': 1.5},
];

Map<String, dynamic>? _pick(Random random) =>
    _attributes[random.nextInt(_attributes.length)];

/// A document's delta as it can be kept: operations that compose would join
/// or drop are left as they are.
Delta _document(Random random) {
  final operations = <Operation>[];
  final count = 1 + random.nextInt(30);
  for (var index = 0; index < count; index++) {
    final roll = random.nextInt(10);
    operations.add(switch (roll) {
      0 => Operation.insert(''),
      1 => Operation.insert({'image': 'a.png'}, _pick(random)),
      _ => Operation.insert(
        roll.isEven ? 'word\n' : 'text ${'x' * random.nextInt(5)}',
        _pick(random),
      ),
    });
  }
  operations.add(Operation.insert('\n'));
  return Delta.fromOperations(operations);
}

/// A change to a document of [length] characters, as edits make them.
Delta _change(Random random, int length) {
  final change = Delta();
  var at = 0;
  while (at < length && random.nextInt(4) != 0) {
    final step = 1 + random.nextInt(max(1, min(12, length - at)));
    switch (random.nextInt(5)) {
      case 0:
        change.retain(step);
        at += step;
      case 1:
        change.retain(step, _pick(random));
        at += step;
      case 2:
        change.insert('new', _pick(random));
      case 3:
        change.insert({'image': 'b.png'});
      default:
        change.delete(min(step, length - at));
        at += min(step, length - at);
    }
  }
  return change;
}

void main() {
  test('composeDeltas gives what Delta.compose gives', () {
    for (var seed = 0; seed < 20000; seed++) {
      final random = Random(seed);
      final document = _document(random);
      final length = document.toList().fold(0, (sum, op) => sum + op.length!);
      final change = _change(random, length);

      expect(
        jsonEncode(composeDeltas(document, change).toJson()),
        jsonEncode(document.compose(change).toJson()),
        reason:
            'seed $seed: ${jsonEncode(change.toJson())} on '
            '${jsonEncode(document.toJson())}',
      );
    }
  });
}
