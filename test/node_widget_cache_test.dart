import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
// ignore: implementation_imports
import 'package:flutter_quill/src/editor/widgets/text/text_line.dart';
import 'package:flutter_test/flutter_test.dart';

const _styles = DefaultStyles();

const _justified = {'align': 'justify'};

/// An editor on [delta] alone on the screen. Every [pump] gives it a new
/// configuration, as the screens of the app do when they build.
class _Stage {
  _Stage(this.tester, Delta delta)
    : controller = QuillController(
        document: Document.fromDelta(delta),
        selection: const TextSelection.collapsed(offset: 0),
      ) {
    addTearDown(() {
      controller.dispose();
      focusNode.dispose();
      scrollController.dispose();
    });
  }

  final WidgetTester tester;
  final QuillController controller;
  final focusNode = FocusNode();
  final scrollController = ScrollController();

  Future<void> pump({
    String? placeholder,
    DefaultStyles styles = _styles,
    LineFormatBuilder? lineFormat,
    TextSpanBuilder spanBuilder = defaultSpanBuilder,
    Iterable<EmbedBuilder>? embedBuilders,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: Scaffold(
          body: QuillEditor(
            controller: controller,
            focusNode: focusNode,
            scrollController: scrollController,
            config: QuillEditorConfig(
              placeholder: placeholder,
              customStyles: styles,
              lineFormat: lineFormat,
              textSpanBuilder: spanBuilder,
              embedBuilders: embedBuilders,
            ),
          ),
        ),
      ),
    );
  }

  /// Where paragraph [index] of [_paragraphs] starts in the document.
  int startOf(int index) =>
      controller.document.toPlainText().indexOf('Paragraph $index ');

  void moveCaretTo(int offset) => controller.updateSelection(
    TextSelection.collapsed(offset: offset),
    ChangeSource.local,
  );

  void type(int offset, String text) => controller.replaceText(
    offset,
    0,
    text,
    TextSelection.collapsed(offset: offset + text.length),
  );
}

/// Shows [delta] in an editor that has the focus, as it has while someone
/// types in it.
Future<_Stage> _show(WidgetTester tester, Delta delta) async {
  final stage = _Stage(tester, delta);
  await stage.pump();
  stage.focusNode.requestFocus();
  await tester.pump();
  return stage;
}

Delta _paragraphs(int count, {int from = 0, Map<String, dynamic>? attributes}) {
  final delta = Delta();
  for (var i = from; i < from + count; i++) {
    delta
      ..insert('Paragraph $i goes on for a while, as body text does.')
      ..insert('\n', attributes);
  }
  return delta;
}

String _name(String text) => text.split(' goes').first.trim();

/// The paragraphs built by [action] and by the frame after it, by their first
/// words and in the order they were built.
Future<List<String>> _built(
  WidgetTester tester,
  FutureOr<void> Function() action,
) async {
  final built = <String>[];
  debugOnRebuildDirtyWidget = (element, _) {
    final widget = element.widget;
    if (widget is TextLine) {
      built.add(_name(widget.line.toPlainText()));
    }
  };
  try {
    await action();
    await tester.pump();
  } finally {
    debugOnRebuildDirtyWidget = null;
  }
  return built;
}

Map<Line, State> _states(WidgetTester tester) => {
  for (final element in find.byType(TextLine).evaluate())
    (element.widget as TextLine).line: (element as StatefulElement).state,
};

List<String> _numbers(WidgetTester tester) => [
  for (final point in tester.widgetList<QuillNumberPoint>(
    find.byType(QuillNumberPoint),
  ))
    point.index,
];

/// The text under the underline of what is being composed, by the first words
/// of its paragraph.
Map<String, String> _composing(WidgetTester tester) => {
  for (final text in tester.widgetList<RichText>(find.byType(RichText)))
    for (final span in _spans(text.text))
      if (span.style?.decoration == TextDecoration.underline &&
          (span.text ?? '').isNotEmpty)
        _name(text.text.toPlainText()): span.text!,
};

List<TextSpan> _spans(InlineSpan root) {
  final spans = <TextSpan>[];
  root.visitChildren((span) {
    if (span is TextSpan) spans.add(span);
    return true;
  });
  return spans;
}

/// The bar an empty paragraph paints to show it is selected.
PaintPattern _selectedMark() => paints
  ..something(
    (method, arguments) =>
        method == #drawRect && (arguments[0] as Rect).width == 3,
  );

void main() {
  for (final (where, attributes) in <(String, Map<String, dynamic>?)>[
    ('', null),
    (' in a justified block', _justified),
  ]) {
    testWidgets('typing builds the paragraph typed in and the ones around '
        'it$where', (tester) async {
      final stage = await _show(
        tester,
        _paragraphs(12, attributes: attributes),
      );
      final sixth = stage.startOf(5);
      stage.moveCaretTo(sixth + 3);
      await tester.pump();

      final built = await _built(tester, () => stage.type(sixth + 3, 'x'));

      expect(built, ['Paragraph 4', 'Parxagraph 5', 'Paragraph 6']);
    });

    testWidgets('moving the caret builds the paragraphs it left and '
        'entered$where', (tester) async {
      final stage = await _show(
        tester,
        _paragraphs(12, attributes: attributes),
      );
      stage.moveCaretTo(stage.startOf(1) + 2);
      await tester.pump();

      final built = await _built(
        tester,
        () => stage.moveCaretTo(stage.startOf(4) + 2),
      );

      expect(built, ['Paragraph 1', 'Paragraph 4']);
    });

    testWidgets('moving the end of a selection builds the paragraph it ends '
        'in$where', (tester) async {
      final stage = await _show(
        tester,
        _paragraphs(12, attributes: attributes),
      );
      final controller = stage.controller;
      final end = controller.document.length - 1;
      controller.updateSelection(
        TextSelection(baseOffset: 0, extentOffset: end),
        ChangeSource.local,
      );
      await tester.pump();

      final built = await _built(
        tester,
        () => controller.updateSelection(
          TextSelection(baseOffset: 0, extentOffset: end - 1),
          ChangeSource.local,
        ),
      );

      expect(built, ['Paragraph 11']);
    });
  }

  testWidgets('a new paragraph builds only the ones around it', (tester) async {
    final stage = await _show(tester, _paragraphs(12));
    final split = stage.startOf(5) + 'Paragraph 5 goes on'.length;
    stage.moveCaretTo(split);
    await tester.pump();
    final before = _states(tester);

    final built = await _built(tester, () => stage.type(split, '\n'));

    expect(built, [
      'Paragraph 4',
      'Paragraph 5',
      'for a while, as body text does.',
      'Paragraph 6',
    ]);
    final after = _states(tester);
    expect(after, hasLength(13));
    expect([
      for (final line in before.keys)
        if (!identical(after[line], before[line])) _name(line.toPlainText()),
    ], isEmpty);
  });

  testWidgets('ordered lists keep their numbers when the paragraph between '
      'them is not built again', (tester) async {
    final stage = await _show(
      tester,
      Delta()
        ..insert('One')
        ..insert('\n', {'list': 'ordered'})
        ..insert('Two')
        ..insert('\n', {'list': 'ordered'})
        ..insert('Centered')
        ..insert('\n', {'align': 'center'})
        ..insert('Three')
        ..insert('\n', {'list': 'ordered'})
        ..insert('Nested')
        ..insert('\n', {'list': 'ordered', 'indent': 1})
        ..insert('Four')
        ..insert('\n', {'list': 'ordered'}),
    );
    const numbers = ['1', '2', '1', 'a', '2'];
    expect(_numbers(tester), numbers);

    stage.moveCaretTo(1);
    await tester.pump();
    expect(_numbers(tester), numbers);

    final centered = stage.controller.document.toPlainText().indexOf(
      'Centered',
    );
    stage.type(centered, 'x');
    await tester.pump();
    expect(_numbers(tester), numbers);

    stage.type(0, 'x');
    await tester.pump();
    expect(_numbers(tester), numbers);
  });

  testWidgets('a selected empty paragraph in a block shows as selected', (
    tester,
  ) async {
    final stage = await _show(
      tester,
      Delta()
        ..insert('Intro\n')
        ..insert('First')
        ..insert('\n', {'align': 'center'})
        ..insert('\n', {'align': 'center'})
        ..insert('Third')
        ..insert('\n', {'align': 'center'}),
    );
    final empty = tester
        .renderObjectList<RenderEditableTextLine>(find.byType(EditableTextLine))
        .singleWhere((line) => line.line.length == 1);
    expect(empty, isNot(_selectedMark()));

    stage.controller.updateSelection(
      TextSelection(
        baseOffset: 0,
        extentOffset: stage.controller.document.length - 1,
      ),
      ChangeSource.local,
    );
    await tester.pump();

    expect(empty, _selectedMark());
  });

  testWidgets('the placeholder shows whenever the document is empty', (
    tester,
  ) async {
    final stage = _Stage(tester, Delta()..insert('\n'));
    await stage.pump(placeholder: 'Start writing');
    final placeholder = find.textContaining(
      'Start writing',
      findRichText: true,
    );
    expect(placeholder, findsOneWidget);

    stage.type(0, 'Hi');
    await tester.pump();
    expect(placeholder, findsNothing);
    expect(find.textContaining('Hi', findRichText: true), findsOneWidget);

    stage.controller.replaceText(
      0,
      2,
      '',
      const TextSelection.collapsed(offset: 0),
    );
    await tester.pump();
    expect(placeholder, findsOneWidget);
  });

  for (final (what, change) in <(String, Future<void> Function(_Stage))>[
    (
      'new styles',
      (stage) =>
          stage.pump(styles: const DefaultStyles(color: Color(0xFF123456))),
    ),
    ('a new line format', (stage) => stage.pump(lineFormat: (line) => null)),
    (
      'a new span builder',
      (stage) => stage.pump(
        spanBuilder: (context, node, offset, text, style, recognizer) =>
            TextSpan(text: text, style: style, recognizer: recognizer),
      ),
    ),
    ('new embed builders', (stage) => stage.pump(embedBuilders: const [])),
  ]) {
    testWidgets('every paragraph is built again with $what', (tester) async {
      final stage = await _show(tester, _paragraphs(12));

      final built = await _built(tester, () => change(stage));

      expect(built, [for (var i = 0; i < 12; i++) 'Paragraph $i']);
    });
  }

  testWidgets('an editor built again with equal values builds no paragraph', (
    tester,
  ) async {
    final stage = await _show(tester, _paragraphs(12));

    expect(await _built(tester, stage.pump), isEmpty);
  });

  testWidgets('the composing underline follows the text being composed', (
    tester,
  ) async {
    final stage = await _show(
      tester,
      _paragraphs(2).concat(_paragraphs(2, from: 2, attributes: _justified)),
    );
    final text = stage.controller.document.toPlainText();
    final second = stage.startOf(1);
    final fourth = stage.startOf(3);

    Future<void> compose(TextRange range) async {
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: second + 9),
          composing: range,
        ),
      );
      await tester.pump();
    }

    await compose(TextRange(start: second, end: second + 9));
    expect(_composing(tester), {'Paragraph 1': 'Paragraph'});

    await compose(TextRange(start: fourth, end: fourth + 9));
    expect(_composing(tester), {'Paragraph 3': 'Paragraph'});

    await compose(TextRange.empty);
    expect(_composing(tester), isEmpty);
  });
}
