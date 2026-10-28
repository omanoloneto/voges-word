import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/editor/title_bar.dart';
import 'package:voges_word/editor/window_buttons.dart';
import 'package:voges_word/files/document_files.dart';

Future<void> _pumpTitleBar(
  WidgetTester tester, {
  WindowButtonsLayout layout = WindowButtonsLayout.right,
}) async {
  tester.view.physicalSize = const Size(1200, 200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tables = TableStore();
  final docx = DocxCodec(tables);
  final session = EditorSession(
    docx: docx,
    plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
    files: DocumentFiles(),
    tables: tables,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AppTitleBar(
          session: session,
          onFile: () {},
          isMaximized: false,
          windowButtons: layout,
        ),
      ),
    ),
  );
}

double _x(WidgetTester tester, String tooltip) =>
    tester.getCenter(find.byTooltip(tooltip)).dx;

double _pill(WidgetTester tester) => tester.getCenter(find.text('Arquivo')).dx;

void main() {
  testWidgets(
    'no Mac os botões da janela são os do sistema e os atalhos ficam à direita',
    (tester) async {
      await _pumpTitleBar(tester);

      expect(_x(tester, 'Desfazer (⌘Z)'), greaterThan(_pill(tester)));
      expect(find.byTooltip('Fechar'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'no Windows os botões da janela ficam à direita e os atalhos à esquerda',
    (tester) async {
      await _pumpTitleBar(tester);

      expect(_x(tester, 'Desfazer (Ctrl+Z)'), lessThan(_pill(tester)));
      expect(_x(tester, 'Minimizar'), lessThan(_x(tester, 'Maximizar')));
      expect(_x(tester, 'Fechar'), greaterThan(1150));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'no Linux os botões seguem o lado configurado no sistema',
    (tester) async {
      await _pumpTitleBar(
        tester,
        layout: WindowButtonsLayout.parse("'close,minimize,maximize:appmenu'"),
      );

      expect(_x(tester, 'Fechar'), lessThan(_x(tester, 'Minimizar')));
      expect(_x(tester, 'Maximizar'), lessThan(_pill(tester)));
      expect(_x(tester, 'Desfazer (Ctrl+Z)'), greaterThan(_pill(tester)));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  test('lê o button-layout do GNOME', () {
    const all = [
      WindowButton.minimize,
      WindowButton.maximize,
      WindowButton.close,
    ];
    final standard = WindowButtonsLayout.parse(
      "'appmenu:minimize,maximize,close'\n",
    );
    expect(standard.leading, isEmpty);
    expect(standard.trailing, all);
    expect(WindowButtonsLayout.parse("'appmenu:close'").trailing, [
      WindowButton.close,
    ]);
    expect(WindowButtonsLayout.parse("'close,minimize,maximize:'").leading, [
      WindowButton.close,
      WindowButton.minimize,
      WindowButton.maximize,
    ]);
    expect(WindowButtonsLayout.parse('').trailing, all);
  });
}
