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
    if (last != null && _joins(last, operation)) {
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

  /// Adds [operation] after [previous], the last one pushed, joining them as
  /// [push] does; it skips the checks [push] has to make.
  void pushAfter(Operation previous, Operation operation) {
    if (_joins(previous, operation)) {
      push(operation);
      return;
    }
    _join();
    _delta.operations.add(operation);
  }

  static bool _joins(Operation last, Operation operation) =>
      last.isInsert &&
      operation.isInsert &&
      operation.data is String &&
      last.data is String &&
      last.hasSameAttributes(operation);

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
///
/// The operations of [delta] that [other] only retains, without attributes,
/// are taken over as they are when compose would give them back the same;
/// making each one again made a key press cost as much as the whole
/// document.
@internal
Delta composeDeltas(Delta delta, Delta other) {
  final result = DeltaWriter();
  final thisIter = _Operations(delta.operations);
  final otherIter = _Operations(other.operations);
  final operations = delta.operations;

  while (thisIter.hasNext || otherIter.hasNext) {
    final kept = otherIter.plainRetainLength;
    if (kept > 0 && thisIter.isAtStartOfOperation) {
      final first = thisIter.index;
      var last = first;
      var length = 0;
      while (last < operations.length) {
        final operation = operations[last];
        if (length + operation.length! > kept || !_keepsAsIs(operation)) break;
        length += operation.length!;
        last++;
      }
      if (last > first) {
        result.push(operations[first]);
        for (var index = first + 1; index < last; index++) {
          result.pushAfter(operations[index - 1], operations[index]);
        }
        thisIter.index = last;
        otherIter.next(length);
        continue;
      }
    }
    final newOp = _composeOperation(thisIter, otherIter);
    if (newOp != null) result.push(newOp);
  }
  return result.toDelta()..trim();
}

/// Whether composing [operation] with a plain retain gives it back as is:
/// compose drops empty operations and attributes set to null, and empty
/// attributes become none.
bool _keepsAsIs(Operation operation) {
  if (!operation.isInsert || operation.isEmpty) return false;
  final attributes = operation.attributes;
  return attributes == null ||
      attributes.isNotEmpty && !attributes.containsValue(null);
}

/// [DeltaIterator] over [_operations], which can also say where it is.
final class _Operations {
  _Operations(this._operations);

  final List<Operation> _operations;
  var index = 0;
  var _offset = 0;

  bool get hasNext => index < _operations.length;

  bool get isAtStartOfOperation => _offset == 0;

  bool get isNextInsert => hasNext && _operations[index].isInsert;

  bool get isNextDelete => hasNext && _operations[index].isDelete;

  /// What is left of the next operation when it is a retain without
  /// attributes, everything when no operation is left, and 0 otherwise.
  int get plainRetainLength {
    if (!hasNext) return DeltaIterator.maxLength;
    final operation = _operations[index];
    return operation.isRetain && operation.isPlain
        ? operation.length! - _offset
        : 0;
  }

  int peekLength() =>
      hasNext ? _operations[index].length! - _offset : DeltaIterator.maxLength;

  /// As [DeltaIterator.next].
  Operation next([int length = DeltaIterator.maxLength]) {
    if (!hasNext) return Operation.retain(length);
    final op = _operations[index];
    final currentOffset = _offset;
    final actualLength = math.min(op.length! - currentOffset, length);
    if (actualLength == op.length! - currentOffset) {
      index++;
      _offset = 0;
    } else {
      _offset += actualLength;
    }
    final opData = op.isInsert && op.data is String
        ? (op.data as String).substring(
            currentOffset,
            currentOffset + actualLength,
          )
        : op.data;
    final opIsNotEmpty = opData is String ? opData.isNotEmpty : true;
    final opLength = opData is String ? opData.length : 1;
    final opActualLength = opIsNotEmpty ? opLength : actualLength;
    return Operation(op.key, opActualLength, opData, op.attributes);
  }
}

/// A copy of the private Delta._composeOperation of dart_quill_delta 10.8.3.
Operation? _composeOperation(_Operations thisIter, _Operations otherIter) {
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
