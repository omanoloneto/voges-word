import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

/// An editor on [delta] with the focus, as while someone types in it.
Future<QuillController> _show(WidgetTester tester, Delta delta) async {
  final controller = QuillController(
    document: Document.fromDelta(delta),
    selection: const TextSelection.collapsed(offset: 0),
  );
  final focusNode = FocusNode();
  final scrollController = ScrollController();
  addTearDown(() {
    controller.dispose();
    focusNode.dispose();
    scrollController.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [FlutterQuillLocalizations.delegate],
      home: Scaffold(
        body: QuillEditor(
          controller: controller,
          focusNode: focusNode,
          scrollController: scrollController,
        ),
      ),
    ),
  );
  focusNode.requestFocus();
  await tester.pump();
  return controller;
}

Delta _paragraphs(int count) {
  final delta = Delta();
  for (var index = 0; index < count; index++) {
    delta.insert('Paragraph $index goes on for a while, as body text does.\n');
  }
  return delta;
}

/// What the system has: its text, and where that starts in the document.
({String text, int start, TextSelection selection}) _remote(
  WidgetTester tester,
  QuillController controller,
) {
  final state = tester.testTextInput.editingState!;
  final text = state['text'] as String;
  final selection = TextSelection(
    baseOffset: state['selectionBase'] as int,
    extentOffset: state['selectionExtent'] as int,
  );
  return (
    text: text,
    start: controller.selection.baseOffset - selection.baseOffset,
    selection: selection,
  );
}

Future<void> _moveCaret(
  WidgetTester tester,
  QuillController controller,
  int offset,
) async {
  controller.updateSelection(
    TextSelection.collapsed(offset: offset),
    ChangeSource.local,
  );
  await tester.pump();
}

void main() {
  testWidgets('the system gets the text around the caret', (tester) async {
    final controller = await _show(tester, _paragraphs(400));
    final document = controller.document.toPlainText();
    final caret = document.indexOf('Paragraph 200 ') + 5;
    await _moveCaret(tester, controller, caret);

    final remote = _remote(tester, controller);

    expect(remote.text.length, lessThan(2100));
    expect(
      remote.selection,
      TextSelection.collapsed(offset: caret - remote.start),
    );
    expect(
      document.substring(remote.start, remote.start + remote.text.length),
      remote.text,
    );
  });

  testWidgets('typing through the system edits the document at the caret', (
    tester,
  ) async {
    final controller = await _show(tester, _paragraphs(400));
    final caret = controller.document.toPlainText().indexOf('Paragraph 200 ');
    await _moveCaret(tester, controller, caret);
    final remote = _remote(tester, controller);
    final at = remote.selection.baseOffset;

    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: remote.text.replaceRange(at, at, 'Long '),
        selection: TextSelection.collapsed(offset: at + 5),
      ),
    );
    await tester.pump();

    final document = controller.document.toPlainText();
    expect(document.substring(caret, caret + 19), 'Long Paragraph 200 ');
    expect(controller.selection, TextSelection.collapsed(offset: caret + 5));
    expect(document.indexOf('Long'), caret, reason: 'once, at the caret');

    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: remote.text.replaceRange(at, at, 'Long'),
        selection: TextSelection.collapsed(offset: at + 4),
      ),
    );
    await tester.pump();
    expect(
      controller.document.toPlainText().substring(caret, caret + 18),
      'LongParagraph 200 ',
      reason: 'a deletion lands at the caret too',
    );
  });

  testWidgets('the text the system has stays while the caret moves within it '
      'and follows it far away', (tester) async {
    final controller = await _show(tester, _paragraphs(400));
    final document = controller.document.toPlainText();
    final caret = document.indexOf('Paragraph 200 ');
    await _moveCaret(tester, controller, caret);
    final before = _remote(tester, controller);

    await _moveCaret(tester, controller, caret + 40);
    final near = _remote(tester, controller);
    expect(near.start, before.start);
    expect(near.text, before.text);
    expect(near.selection.baseOffset, before.selection.baseOffset + 40);

    final far = document.indexOf('Paragraph 350 ');
    await _moveCaret(tester, controller, far);
    final moved = _remote(tester, controller);
    expect(moved.text, contains('Paragraph 350 '));
    expect(
      document.substring(moved.start, moved.start + moved.text.length),
      moved.text,
    );
  });

  testWidgets('what is being composed is underlined where it is', (
    tester,
  ) async {
    final controller = await _show(tester, _paragraphs(400));
    final caret = controller.document.toPlainText().indexOf('Paragraph 300 ');
    await _moveCaret(tester, controller, caret + 9);
    final remote = _remote(tester, controller);
    final at = remote.selection.baseOffset;

    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: remote.text,
        selection: remote.selection,
        composing: TextRange(start: at - 9, end: at),
      ),
    );
    await tester.pump();

    final underlined = [
      for (final text in tester.widgetList<RichText>(find.byType(RichText)))
        for (final span in _spans(text.text))
          if (span.style?.decoration == TextDecoration.underline &&
              (span.text ?? '').isNotEmpty)
            (text.text.toPlainText().split(' goes').first, span.text),
    ];
    expect(underlined, [('Paragraph 300', 'Paragraph')]);
  });

  testWidgets('a character of two code units stays whole at the edge', (
    tester,
  ) async {
    final controller = await _show(
      tester,
      Delta()..insert('${'a' * 999}😀${'b' * 3000}\n'),
    );
    // A thousand code units before the caret falls between the two halves
    // of the emoji.
    await _moveCaret(tester, controller, 2000);

    final remote = _remote(tester, controller);

    expect(remote.text, startsWith('😀'));
    expect(remote.start, 999);
  });
}

List<TextSpan> _spans(InlineSpan root) {
  final spans = <TextSpan>[];
  root.visitChildren((span) {
    if (span is TextSpan) spans.add(span);
    return true;
  });
  return spans;
}
