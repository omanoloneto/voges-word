import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

/// An editor on [delta] with the focus and the caret at [caret].
Future<QuillController> _show(
  WidgetTester tester,
  Delta delta,
  TextSelection selection,
) async {
  final controller = QuillController(
    document: Document.fromDelta(delta),
    selection: selection,
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

void main() {
  testWidgets('Backspace deletes the character before the caret, with its '
      'style', (tester) async {
    final controller = await _show(
      tester,
      Delta()
        ..insert('a')
        ..insert('a', {'bold': true})
        ..insert('b\n'),
      const TextSelection.collapsed(offset: 2),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(controller.document.toDelta(), Delta()..insert('ab\n'));
    expect(controller.selection, const TextSelection.collapsed(offset: 1));

    controller.undo();
    expect(
      controller.document.toDelta(),
      Delta()
        ..insert('a')
        ..insert('a', {'bold': true})
        ..insert('b\n'),
    );
  });

  testWidgets('Backspace deletes the selection', (tester) async {
    final controller = await _show(
      tester,
      Delta()..insert('One two three\n'),
      const TextSelection(baseOffset: 8, extentOffset: 3),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(controller.document.toPlainText(), 'Onethree\n');
    expect(controller.selection, const TextSelection.collapsed(offset: 3));
  });

  testWidgets('Delete deletes the character after the caret', (tester) async {
    final controller = await _show(
      tester,
      Delta()..insert('One\ntwo\n'),
      const TextSelection.collapsed(offset: 3),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();

    expect(controller.document.toPlainText(), 'Onetwo\n');
    expect(controller.selection, const TextSelection.collapsed(offset: 3));
  });

  testWidgets('Backspace deletes a character of two code units whole', (
    tester,
  ) async {
    final controller = await _show(
      tester,
      Delta()..insert('a😀b\n'),
      const TextSelection.collapsed(offset: 3),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(controller.document.toPlainText(), 'ab\n');
    expect(controller.selection, const TextSelection.collapsed(offset: 1));
  });

  testWidgets(
    'Option and Backspace delete the word before the caret',
    (tester) async {
      final controller = await _show(
        tester,
        Delta()..insert('One two three\n'),
        const TextSelection.collapsed(offset: 7),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      expect(controller.document.toPlainText(), 'One  three\n');
      expect(controller.selection, const TextSelection.collapsed(offset: 4));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
