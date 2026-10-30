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

/// A line's misspellings for one build of the line's widget.
final class _LineSpelling {
  _LineSpelling(this._widget, this._line, this.misspellings);

  final Widget _widget;
  final Line _line;
  final List<Misspelling>? misspellings;
  Map<Node, int>? _starts;

  bool isFor(Widget widget, Line line) =>
      identical(widget, _widget) && identical(line, _line);

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

/// Underlines misspelled words with a wavy red line.
TextSpanBuilder spellingSpanBuilder(SpellChecker checker) {
  _LineSpelling? last;
  return (context, node, nodeOffset, text, style, recognizer) {
    final line = node.parent;
    _LineSpelling? paragraph;
    if (recognizer == null && line is Line && text.isNotEmpty) {
      paragraph = last;
      // Quill builds a line's leaves one after another for the same widget,
      // so each build looks the paragraph up once instead of once per leaf.
      if (paragraph == null || !paragraph.isFor(context.widget, line)) {
        paragraph = last = _LineSpelling(
          context.widget,
          line,
          checker.misspellingsOf(spellingTextOf(line)),
        );
      }
    }
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
}

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
