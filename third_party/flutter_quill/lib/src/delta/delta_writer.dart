import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../../quill_delta.dart';

/// Voges Word: builds a [Delta] as [Delta.push] does, but text that joins
/// the last insert goes to a buffer and is copied once, when the insert is
/// complete. [Delta.push] copied all the text joined so far for each piece,
/// so a delta with many lines of the same style took quadratic time.
@internal
class DeltaWriter {
  final _delta = Delta();

  /// The text of the last insert, once another piece has joined it.
  StringBuffer? _text;
  var _length = 0;

  /// The last piece that joined [_text]; its attributes are the insert's.
  Operation? _joined;

  void push(Operation operation) {
    if (operation.isEmpty) return;
    final last = _delta.isEmpty ? null : _delta.last;
    if (last != null &&
        last.isInsert &&
        operation.isInsert &&
        last.hasSameAttributes(operation) &&
        operation.data is String &&
        last.data is String) {
      final text = _text ??= StringBuffer(last.data as String);
      if (_joined == null) _length = last.length!;
      text.write(operation.data as String);
      _length += operation.length!;
      _joined = operation;
      return;
    }
    _join();
    _delta.push(operation);
  }

  /// Adds [operations] after the last one without joining them to it, as
  /// [Delta.concat] does after its first operation.
  void addAll(Iterable<Operation> operations) {
    if (operations.isEmpty) return;
    _join();
    _delta.operations.addAll(operations);
  }

  Delta toDelta() {
    _join();
    return _delta;
  }

  void _join() {
    final joined = _joined;
    if (joined == null) return;
    _delta.operations[_delta.length - 1] =
        Operation(joined.key, _length, _text.toString(), joined.attributes);
    _text = null;
    _joined = null;
  }
}

/// Voges Word: [Delta.compose] writing its result with a [DeltaWriter], so
/// a change that leaves many lines in one style takes linear time.
@internal
Delta composeDeltas(Delta delta, Delta other) {
  final result = DeltaWriter();
  final thisIter = DeltaIterator(delta);
  final otherIter = DeltaIterator(other);

  while (thisIter.hasNext || otherIter.hasNext) {
    final newOp = _composeOperation(thisIter, otherIter);
    if (newOp != null) result.push(newOp);
  }
  return result.toDelta()..trim();
}

/// A copy of the private Delta._composeOperation of dart_quill_delta 10.8.3.
Operation? _composeOperation(DeltaIterator thisIter, DeltaIterator otherIter) {
  if (otherIter.isNextInsert) return otherIter.next();
  if (thisIter.isNextDelete) return thisIter.next();

  final length = math.min(thisIter.peekLength(), otherIter.peekLength());
  final thisOp = thisIter.next(length);
  final otherOp = otherIter.next(length);
  assert(thisOp.length == otherOp.length);

  if (otherOp.isRetain) {
    final attributes = Delta.composeAttributes(
      thisOp.attributes,
      otherOp.attributes,
      keepNull: thisOp.isRetain,
    );
    if (thisOp.isRetain) {
      return Operation.retain(thisOp.length, attributes);
    } else if (thisOp.isInsert) {
      return Operation.insert(thisOp.data, attributes);
    } else {
      throw StateError('Unreachable');
    }
  } else {
    // otherOp == delete && thisOp in [retain, insert]
    assert(otherOp.isDelete);
    if (thisOp.isRetain) return otherOp;
    assert(thisOp.isInsert);
    // otherOp(delete) + thisOp(insert) => null
  }
  return null;
}
