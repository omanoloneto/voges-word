import '../../quill_delta.dart';
import 'document.dart';
import 'structs/doc_change.dart';
import 'structs/history_changed.dart';

class History {
  History({
    this.ignoreChange = false,
    this.interval = 400,
    this.maxStack = 100,
    this.userOnly = false,
    this.lastRecorded = 0,
  });

  HistoryStack stack = HistoryStack.empty();

  bool get hasUndo => stack.undo.isNotEmpty;

  bool get hasRedo => stack.redo.isNotEmpty;

  /// used for disable redo or undo function
  bool ignoreChange;

  int lastRecorded;

  /// Collaborative editing's conditions should be true
  final bool userOnly;

  ///max operation count for undo
  final int maxStack;

  ///record delay
  final int interval;

  void handleDocChange(DocChange docChange) {
    if (ignoreChange) return;
    if (!userOnly || docChange.source == ChangeSource.local) {
      record(docChange.change, docChange.before);
    } else {
      transform(docChange.change);
    }
  }

  void clear() {
    stack.clear();
  }

  void record(Delta change, Delta before) {
    if (change.isEmpty) return;
    stack.redo.clear();
    var undoDelta = _invert(change, before);
    final timeStamp = DateTime.now().millisecondsSinceEpoch;

    if (lastRecorded + interval > timeStamp && stack.undo.isNotEmpty) {
      final lastDelta = stack.undo.removeLast();
      undoDelta = undoDelta.compose(lastDelta);
    } else {
      lastRecorded = timeStamp;
    }

    if (undoDelta.isEmpty) return;
    stack.undo.add(undoDelta);

    if (stack.undo.length > maxStack) {
      stack.undo.removeAt(0);
    }
  }

  ///
  ///It will override pre local undo delta,replaced by remote change
  ///
  void transform(Delta delta) {
    transformStack(stack.undo, delta);
    transformStack(stack.redo, delta);
  }

  void transformStack(List<Delta> stack, Delta delta) {
    for (var i = stack.length - 1; i >= 0; i -= 1) {
      final oldDelta = stack[i];
      stack[i] = delta.transform(oldDelta, true);
      delta = oldDelta.transform(delta, false);
      if (stack[i].length == 0) {
        stack.removeAt(i);
      }
    }
  }

  HistoryChanged _change(Document doc, List<Delta> source, List<Delta> dest) {
    if (source.isEmpty) {
      return const HistoryChanged(false, 0);
    }
    final delta = source.removeLast();
    // look for insert or delete
    var len = 0;
    final ops = delta.toList();
    for (var i = 0; i < ops.length; i++) {
      if ((ops[i].key == Operation.insertKey) ||
          (ops[i].key == Operation.retainKey)) {
        len += ops[i].length ?? 0;
      }
    }
    final base = Delta.from(doc.toDelta());
    final inverseDelta = _invert(delta, base);
    dest.add(inverseDelta);
    lastRecorded = 0;
    ignoreChange = true;
    doc.compose(delta, ChangeSource.local);
    ignoreChange = false;
    return HistoryChanged(true, len);
  }

  HistoryChanged undo(Document doc) {
    return _change(doc, stack.undo, stack.redo);
  }

  /// Voges Word: [Delta.invert] in one pass over [base]. Quill's sliced
  /// [base] from its start for every formatted or deleted run, so a change
  /// to every line of a long document took quadratic time to record or
  /// undo. Tests check that both give the same delta.
  static Delta _invert(Delta change, Delta base) {
    final inverted = Delta();
    if (base.isEmpty) return inverted;

    final rest = DeltaIterator(base);
    for (final op in change.operations) {
      if (op.isInsert) {
        inverted.delete(op.length!);
      } else if (op.isRetain && op.isPlain) {
        inverted.retain(op.length!);
        rest.skip(op.length!);
      } else if (op.isDelete || (op.isRetain && op.isNotPlain)) {
        // What base.slice gave, read on from where the last run ended.
        final length = op.length!;
        final slice = Delta();
        for (var taken = 0; taken < length && rest.hasNext;) {
          final baseOp = rest.next(length - taken);
          slice.push(baseOp);
          taken += baseOp.length!;
        }
        for (final baseOp in slice.toList()) {
          if (op.isDelete) {
            inverted.push(baseOp);
          } else {
            final invertAttr =
                Delta.invertAttributes(op.attributes, baseOp.attributes);
            inverted.retain(
                baseOp.length!, invertAttr.isEmpty ? null : invertAttr);
          }
        }
      } else {
        throw StateError('Unreachable');
      }
    }
    inverted.trim();
    return inverted;
  }

  HistoryChanged redo(Document doc) {
    return _change(doc, stack.redo, stack.undo);
  }
}

class HistoryStack {
  HistoryStack.empty()
      : undo = [],
        redo = [];

  List<Delta> undo;
  List<Delta> redo;

  void clear() {
    undo.clear();
    redo.clear();
  }
}
