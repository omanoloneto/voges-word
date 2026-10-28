import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'spell_checker.dart';

const _wavyColor = Color(0xFFE53935);

/// Texto do parágrafo como o corretor recebe; embutidos viram espaço para as
/// posições continuarem batendo.
String spellingTextOf(Line line) {
  final text = line.toPlainText();
  return (text.endsWith('\n') ? text.substring(0, text.length - 1) : text)
      .replaceAll('￼', ' ');
}

/// Sublinha em vermelho ondulado as palavras com erro.
TextSpanBuilder spellingSpanBuilder(SpellChecker checker) =>
    (context, node, nodeOffset, text, style, recognizer) {
      final line = node.parent;
      final found = recognizer != null || line is! Line || text.isEmpty
          ? null
          : checker.misspellingsOf(spellingTextOf(line));
      if (found == null || found.isEmpty) {
        return defaultSpanBuilder(
          context,
          node,
          nodeOffset,
          text,
          style,
          recognizer,
        );
      }
      final start = node.offset + nodeOffset;
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

/// Menu do botão direito (ou do toque longo) com as sugestões da palavra.
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
            label: 'Ignorar "${word.text}"',
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
