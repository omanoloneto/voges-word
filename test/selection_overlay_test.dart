import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

/// An editor on a few paragraphs, with the focus.
Future<(QuillController, QuillRawEditorState)> _show(
  WidgetTester tester,
) async {
  final delta = Delta();
  for (var index = 0; index < 6; index++) {
    delta.insert('Paragraph $index goes on for a while, as body text does.\n');
  }
  final controller = QuillController(
    document: Document.fromDelta(delta),
    selection: const TextSelection.collapsed(offset: 3),
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
  return (
    controller,
    tester.state<QuillRawEditorState>(find.byType(QuillRawEditor)),
  );
}

Future<void> _type(WidgetTester tester, QuillController controller) async {
  final at = controller.selection.baseOffset;
  controller.replaceText(at, 0, 'x', TextSelection.collapsed(offset: at + 1));
  await tester.pump();
}

void main() {
  testWidgets(
    'a caret has no selection overlay on a computer, and its menu opens',
    (tester) async {
      final (controller, state) = await _show(tester);
      await _type(tester, controller);
      expect(state.selectionOverlay, isNull);
      await _type(tester, controller);
      expect(state.selectionOverlay, isNull);

      expect(state.showToolbar(), isTrue);
      await tester.pump();
      expect(state.selectionOverlay?.toolbar, isNotNull);

      controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 9),
        ChangeSource.local,
      );
      await tester.pump();
      expect(state.selectionOverlay, isNotNull, reason: 'a selection has one');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'a caret keeps its selection overlay on a phone',
    (tester) async {
      final (controller, state) = await _show(tester);
      await _type(tester, controller);
      await _type(tester, controller);

      expect(state.selectionOverlay, isNotNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
