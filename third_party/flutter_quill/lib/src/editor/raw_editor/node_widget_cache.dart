import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';

import '../../document/attribute.dart';
import '../../document/nodes/block.dart';
import '../../document/nodes/node.dart';
import '../../document/style.dart';

/// Voges Word: the widgets of the paragraphs as built last time. A build that
/// hands the same widget back skips that paragraph, so a key press builds the
/// paragraph typed in and not the whole document.
class NodeWidgetCache {
  Expando<_Entry> _entries = Expando<_Entry>();
  List<Object?>? _environment;

  /// What every paragraph's widget is built from besides the paragraph
  /// itself. Every widget is forgotten when any of it changes.
  void useEnvironment(List<Object?> environment) {
    if (listEquals(_environment, environment)) {
      return;
    }
    _environment = environment;
    _entries = Expando<_Entry>();
  }

  /// The widget kept for [node], when it was built from [inputs].
  Widget? lookup(Node node, NodeInputs inputs) {
    final entry = _entries[node];
    return entry != null && entry.inputs == inputs ? entry.widget : null;
  }

  void store(Node node, NodeInputs inputs, Widget widget) {
    _entries[node] = _Entry(inputs, widget);
  }

  /// Whether the paragraphs of [block] are kept one by one. Those of lists
  /// and code blocks are not: each numbers itself after the ones before it.
  static bool keepsLinesOf(Block block) {
    final attributes = block.style.attributes;
    return !attributes.containsKey(Attribute.list.key) &&
        !attributes.containsKey(Attribute.codeBlock.key);
  }
}

class _Entry {
  const _Entry(this.inputs, this.widget);

  final NodeInputs inputs;
  final Widget widget;
}

/// Voges Word: what the widget of a paragraph, or of a block of them, is built
/// from besides the environment. The widget is built again when any of it
/// changes.
@immutable
class NodeInputs {
  const NodeInputs._({
    required this.revision,
    required this.previous,
    required this.previousRevision,
    required this.next,
    required this.nextRevision,
    required this.selection,
    required this.composing,
    required this.hasFocus,
    required this.offset,
    required this.blockStyle,
    required this.isFirst,
    required this.isLast,
  });

  /// The inputs of [node], which starts at [offset] in the document.
  ///
  /// [selection], [composing] and [hasFocus] are the editor's, or those the
  /// block of [node] was given. [previous] and [next] are the nodes around
  /// it, across the ends of its block. A paragraph in a block also takes the
  /// [blockStyle] and whether it [isFirst] or [isLast] there.
  factory NodeInputs.of(
    Node node, {
    required int offset,
    required Node? previous,
    required Node? next,
    required TextSelection selection,
    required TextRange composing,
    required bool hasFocus,
    Style? blockStyle,
    bool isFirst = false,
    bool isLast = false,
  }) {
    final length = node.length;
    final own = _selectionWithin(selection, offset, length);
    final ownComposing = _composingWithin(composing, offset, length);
    return NodeInputs._(
      revision: node.revision,
      previous: previous,
      previousRevision: previous?.revision ?? -1,
      next: next,
      nextRevision: next?.revision ?? -1,
      selection: own,
      composing: ownComposing,
      hasFocus: hasFocus && own.isValid,
      offset: own.isValid || ownComposing.isValid ? offset : null,
      blockStyle: blockStyle,
      isFirst: isFirst,
      isLast: isLast,
    );
  }

  final int revision;

  /// A paragraph's spacing may follow the paragraphs around it; see
  /// LineFormatBuilder.
  final Node? previous;
  final int previousRevision;
  final Node? next;
  final int nextRevision;

  /// The part of the selection in the node, in document offsets, or an
  /// invalid selection when it has none. A node the selection only passes by
  /// is not built again when the selection moves.
  final TextSelection selection;

  /// The composing range, when it is in the node.
  final TextRange composing;

  /// Whether the editor has the focus and the node the selection. Only the
  /// caret is drawn from it.
  final bool hasFocus;

  /// Where the node starts, when it draws a selection or a composing range:
  /// both are in document offsets.
  final int? offset;

  final Style? blockStyle;
  final bool isFirst;
  final bool isLast;

  @override
  bool operator ==(Object other) =>
      other is NodeInputs &&
      revision == other.revision &&
      identical(previous, other.previous) &&
      previousRevision == other.previousRevision &&
      identical(next, other.next) &&
      nextRevision == other.nextRevision &&
      selection == other.selection &&
      composing == other.composing &&
      hasFocus == other.hasFocus &&
      offset == other.offset &&
      identical(blockStyle, other.blockStyle) &&
      isFirst == other.isFirst &&
      isLast == other.isLast;

  @override
  int get hashCode => Object.hash(revision, selection, composing, offset);
}

const _noSelection = TextSelection.collapsed(offset: -1);

/// The part of [selection] in the [length] characters from [start] on, as the
/// paragraph there draws it: a caret belongs to the paragraph it is in, and a
/// range to every paragraph it has a character of.
TextSelection _selectionWithin(TextSelection selection, int start, int length) {
  if (!selection.isValid) {
    return _noSelection;
  }
  final end = start + length;
  if (selection.isCollapsed) {
    return start <= selection.baseOffset && selection.baseOffset < end
        ? selection
        : _noSelection;
  }
  if (selection.end <= start || selection.start >= end) {
    return _noSelection;
  }
  return selection.copyWith(
    baseOffset: selection.baseOffset.clamp(start, end),
    extentOffset: selection.extentOffset.clamp(start, end),
  );
}

TextRange _composingWithin(TextRange composing, int start, int length) =>
    composing.isValid &&
            !composing.isCollapsed &&
            composing.start >= start &&
            composing.end <= start + length
        ? composing
        : TextRange.empty;
