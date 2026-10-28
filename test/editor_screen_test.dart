import 'package:flutter/widgets.dart' show Scrollable, ScrollableState;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';

Future<EditorSession> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final tables = TableStore();
  final docx = DocxCodec(tables);
  final files = DocumentFiles();
  final session = EditorSession(
    docx: docx,
    plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
    files: files,
    tables: tables,
  );

  final table = tables.createEmpty(rows: 2, columns: 2, totalWidth: 9000);
  table.rows[0].cells[0].controller.document.insert(0, 'Turma');
  final bytes = docx.encode(
    Delta()
      ..insert('Texto antes da tabela\n')
      ..insert({EmbedTypes.table: encodeTableId(table.id)})
      ..insert('\nTexto depois\n'),
  );
  session.open(OpenedFile(name: 'teste.docx', bytes: bytes));

  await tester.pumpWidget(
    VogesWordApp(
      session: session,
      systemOpen: SystemOpen(files),
      recents: RecentFiles(files),
      launchArguments: const [],
    ),
  );
  await tester.pumpAndSettle();
  return session;
}

Finder _richText(String text) => find.textContaining(text, findRichText: true);

void main() {
  testWidgets('clicar numa célula edita a célula, não o texto principal', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    final mainText = session.controller.document.toPlainText();

    await tester.tap(_richText('Turma'));
    await tester.pumpAndSettle();

    final cell = session.activeCell.value;
    expect(cell, isNotNull);
    expect(session.activeController.value, same(cell!.cell.controller));

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Turma A\n',
        selection: TextSelection.collapsed(offset: 7),
      ),
    );
    await tester.pumpAndSettle();

    expect(cell.cell.controller.document.toPlainText(), 'Turma A\n');
    expect(session.controller.document.toPlainText(), mainText);
    expect(session.dirty, isTrue);

    await tester.tap(_richText('Texto depois'));
    await tester.pumpAndSettle();
    expect(session.activeCell.value, isNull);
    expect(session.activeController.value, same(session.controller));
  });

  testWidgets('negrito da barra vale para o trecho selecionado', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    await tester.tap(_richText('Texto antes'));
    await tester.pumpAndSettle();

    session.controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 5),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Negrito (Ctrl+B)'));
    await tester.pumpAndSettle();

    final first = session.controller.document.toDelta().toList().first;
    expect(first.data, 'Texto');
    expect(first.attributes?['bold'], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('atalho Shift+Enter quebra a linha sem novo parágrafo', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    await tester.tap(_richText('Texto antes'));
    await tester.pumpAndSettle();
    session.controller.updateSelection(
      const TextSelection.collapsed(offset: 5),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pumpAndSettle();

    expect(
      session.controller.document.toPlainText().startsWith('Texto\u2028 antes'),
      isTrue,
    );
  });

  testWidgets(
    'clique em parágrafo dividido entre páginas acha a palavra certa',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final tables = TableStore();
      final docx = DocxCodec(tables);
      final files = DocumentFiles();
      final session = EditorSession(
        docx: docx,
        plainText: PlainTextCodec(
          look: docx.createEmpty().look,
          tables: tables,
        ),
        files: files,
        tables: tables,
      );
      final words = List.generate(900, (i) => 'palavra$i').join(' ');
      final bytes = docx.encode(Delta()..insert('$words MARCADOR fim\n'));
      session.open(OpenedFile(name: 'longo.docx', bytes: bytes));
      await tester.pumpWidget(
        VogesWordApp(
          session: session,
          systemOpen: SystemOpen(files),
          recents: RecentFiles(files),
          launchArguments: const [],
        ),
      );
      await tester.pumpAndSettle();

      final editor = tester
          .state<EditorState>(find.byType(QuillRawEditor))
          .renderEditor;
      expect(editor.pageCount, greaterThan(1));
      final target =
          session.controller.document.toPlainText().indexOf('MARCADOR') + 3;
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(QuillEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final caret = editor.getLocalRectForCaret(TextPosition(offset: target));
      scroll.position.jumpTo(caret.top - 200);
      await tester.pumpAndSettle();

      final endpoint = editor
          .getEndpointsForSelection(TextSelection.collapsed(offset: target))
          .single
          .point;
      final point = editor.localToGlobal(endpoint - const Offset(0, 6));
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      final got = session.controller.selection.baseOffset;
      expect((got - target).abs(), lessThanOrEqualTo(1));
    },
  );

  testWidgets('barra de status fica acima da barra de navegação do celular', (
    tester,
  ) async {
    await _pumpApp(tester);
    tester.view.padding = const FakeViewPadding(bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    await tester.pumpAndSettle();

    final words = tester.getRect(find.textContaining('palavras'));
    expect(words.bottom, lessThanOrEqualTo(900 - 48));
  });
}
