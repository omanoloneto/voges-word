import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../l10n/l10n.dart';
import 'spell_checker.dart';

const _wavyColor = Color(0xFFE53935);

/// Paragraph text as the spell checker gets it; embeds become spaces so the
/// offsets still match.
String spellingTextOf(Line line) {
  final text = line.toPlainText();
  return (text.endsWith('\n') ? text.substring(0, text.length - 1) : text)
      .replaceAll('￼', ' ');
}

/// What a paragraph found, kept with the paragraph until it changes or the
/// checker's results read differently.
final class _LineSpelling {
  _LineSpelling._(
    this._checker,
    this._line,
    this.text,
    this.misspellings, {
    required this.waiting,
  }) : _revision = _line.revision,
       _generation = _checker.generation,
       _round = _checker.round;

  factory _LineSpelling.of(SpellChecker checker, Line line) {
    final text = spellingTextOf(line);
    final misspellings = checker.misspellingsOf(text);
    return _LineSpelling._(
      checker,
      line,
      text,
      misspellings,
      waiting: misspellings == null && checker.isWaiting(text),
    );
  }

  final SpellChecker _checker;
  final Line _line;
  final int _revision;
  final int _generation;
  final int _round;
  final String text;

  /// Null while the paragraph waits to be checked or is not checked.
  final List<Misspelling>? misspellings;

  /// Whether the checker has yet to answer for [text].
  final bool waiting;

  Map<Node, int>? _starts;

  /// Whether this still holds for [checker]: the paragraph is the same, and
  /// one that waits has had no announcement since.
  bool isCurrentFor(SpellChecker checker) =>
      identical(checker, _checker) &&
      _revision == _line.revision &&
      _generation == checker.generation &&
      (!waiting || _round == checker.round);

  /// Whether the checker answered since, so the paragraph has to show it.
  bool get answered => waiting && !_checker.isWaiting(text);

  /// Where [leaf] starts in the paragraph's text, from one walk over the
  /// line: Quill's cached offset of a run stays put when another run is
  /// inserted before it.
  int startOf(Node leaf) {
    var start = _starts?[leaf];
    if (start == null) {
      final starts = _starts = Map.identity();
      var offset = 0;
      for (final child in _line.children) {
        starts[child] = offset;
        offset += child.length;
      }
      start = starts[leaf]!;
    }
    return start;
  }
}

final _spellings = Expando<_LineSpelling>('spelling');

/// Builds a paragraph again when the checker answers for it, and every
/// paragraph when the results read differently, without building the
/// editor again.
class SpellingScope extends InheritedModel<Line> {
  SpellingScope({required this.checker, required super.child, super.key})
    : _generation = checker.generation,
      _round = checker.round;

  final SpellChecker checker;
  final int _generation;
  final int _round;

  @override
  bool updateShouldNotify(SpellingScope oldWidget) =>
      !identical(checker, oldWidget.checker) ||
      _generation != oldWidget._generation ||
      _round != oldWidget._round;

  @override
  bool updateShouldNotifyDependent(
    SpellingScope oldWidget,
    Set<Line> dependencies,
  ) =>
      !identical(checker, oldWidget.checker) ||
      _generation != oldWidget._generation ||
      dependencies.any((line) => _spellings[line]?.answered ?? false);
}

/// [line]'s spelling, looked up once while it stays the same: Quill builds a
/// paragraph's runs one after another, each with this.
_LineSpelling _spellingOf(
  BuildContext context,
  SpellChecker checker,
  Line line,
) {
  InheritedModel.inheritFrom<SpellingScope>(context, aspect: line);
  final kept = _spellings[line];
  if (kept != null && kept.isCurrentFor(checker)) return kept;
  return _spellings[line] = _LineSpelling.of(checker, line);
}

/// Underlines misspelled words with a wavy red line. A [SpellingScope] above
/// the editor shows what the checker finds later.
TextSpanBuilder spellingSpanBuilder(SpellChecker checker) =>
    (context, node, nodeOffset, text, style, recognizer) {
      final line = node.parent;
      final paragraph = recognizer == null && line is Line && text.isNotEmpty
          ? _spellingOf(context, checker, line)
          : null;
      final found = paragraph?.misspellings;
      if (paragraph == null || found == null || found.isEmpty) {
        return defaultSpanBuilder(
          context,
          node,
          nodeOffset,
          text,
          style,
          recognizer,
        );
      }
      final start = paragraph.startOf(node) + nodeOffset;
      final end = start + text.length;
      final wavy = (style ?? const TextStyle()).copyWith(
        decoration: TextDecoration.combine([
          ?style?.decoration,
          TextDecoration.underline,
        ]),
        decorationStyle: TextDecorationStyle.wavy,
        decorationColor: _wavyColor,
      );
      final children = <TextSpan>[];
      var cursor = start;
      for (final misspelling in found) {
        final from = math.max(misspelling.start, start);
        final to = math.min(misspelling.end, end);
        if (from >= to) continue;
        if (from > cursor) {
          children.add(
            TextSpan(text: text.substring(cursor - start, from - start)),
          );
        }
        children.add(
          TextSpan(text: text.substring(from - start, to - start), style: wavy),
        );
        cursor = to;
      }
      if (children.isEmpty) {
        return defaultSpanBuilder(
          context,
          node,
          nodeOffset,
          text,
          style,
          recognizer,
        );
      }
      if (cursor < end) {
        children.add(TextSpan(text: text.substring(cursor - start)));
      }
      return TextSpan(style: style, children: children);
    };

/// Right-click (or long-press) menu with suggestions for the word.
QuillEditorContextMenuBuilder spellingContextMenu(SpellChecker checker) =>
    (context, state) {
      final items = [...state.contextMenuButtonItems];
      final word = _misspellingAt(checker, state.controller);
      if (word != null) {
        items.insertAll(0, [
          for (final suggestion in word.suggestions.take(4))
            ContextMenuButtonItem(
              label: suggestion,
              onPressed: () {
                state.controller.replaceText(
                  word.offset,
                  word.text.length,
                  suggestion,
                  TextSelection.collapsed(
                    offset: word.offset + suggestion.length,
                  ),
                );
                state.hideToolbar();
              },
            ),
          ContextMenuButtonItem(
            label: context.l10n.ignoreWord(word.text),
            onPressed: () {
              checker.ignore(word.text);
              state.hideToolbar();
            },
          ),
        ]);
      }
      return TextFieldTapRegion(
        child: AdaptiveTextSelectionToolbar.buttonItems(
          buttonItems: items,
          anchors: state.contextMenuAnchors,
        ),
      );
    };

({int offset, String text, List<String> suggestions})? _misspellingAt(
  SpellChecker checker,
  QuillController controller,
) {
  final selection = controller.selection;
  if (!selection.isValid) return null;
  final query = controller.document.queryChild(selection.start);
  final line = query.node;
  if (line is! Line) return null;
  final text = spellingTextOf(line);
  final position = query.offset;
  final selected = selection.end - selection.start;
  for (final misspelling in checker.misspellingsOf(text) ?? const []) {
    if (position < misspelling.start || position > misspelling.end) continue;
    if (position + selected > misspelling.end) continue;
    return (
      offset: (line.documentOffset + misspelling.start).toInt(),
      text: text.substring(misspelling.start, misspelling.end),
      suggestions: misspelling.suggestions,
    );
  }
  return null;
}
