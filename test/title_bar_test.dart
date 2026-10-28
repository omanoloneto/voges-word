import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/editor/title_bar.dart';
import 'package:voges_word/editor/window_buttons.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/l10n/l10n.dart';

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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
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

double _pill(WidgetTester tester) => tester.getCenter(find.text('File')).dx;

void main() {
  testWidgets(
    'on the Mac the window buttons are the system ones and the shortcuts sit on the right',
    (tester) async {
      await _pumpTitleBar(tester);

      expect(_x(tester, 'Undo (⌘Z)'), greaterThan(_pill(tester)));
      expect(find.byTooltip('Close'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'on Windows the window buttons sit on the right and the shortcuts on the left',
    (tester) async {
      await _pumpTitleBar(tester);

      expect(_x(tester, 'Undo (Ctrl+Z)'), lessThan(_pill(tester)));
      expect(_x(tester, 'Minimize'), lessThan(_x(tester, 'Maximize')));
      expect(_x(tester, 'Close'), greaterThan(1150));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'on Linux the buttons follow the side set in the system',
    (tester) async {
      await _pumpTitleBar(
        tester,
        layout: WindowButtonsLayout.parse("'close,minimize,maximize:appmenu'"),
      );

      expect(_x(tester, 'Close'), lessThan(_x(tester, 'Minimize')));
      expect(_x(tester, 'Maximize'), lessThan(_pill(tester)));
      expect(_x(tester, 'Undo (Ctrl+Z)'), greaterThan(_pill(tester)));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  test('reads the GNOME button-layout', () {
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
