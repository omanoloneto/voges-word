import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';

// Several times what a laptop takes in debug mode, so slow machines pass.
const _bound = Duration(seconds: 60);

/// Paragraphs, headings, lists and a small table every 50 paragraphs.
DocumentSpec _longDocument(int paragraphs) {
  final spec = DocumentSpec();
  var list = 0;
  for (var index = 0; index < paragraphs; index++) {
    if (index % 40 == 0) list = spec.addList(ListSpec.bullets());
    spec.body.add(switch (index % 50) {
      0 => TableSpec([
        for (var row = 0; row < 2; row++)
          RowSpec([
            for (var column = 0; column < 2; column++)
              CellSpec([
                ParagraphSpec([TextSpec('Cell $index $row $column')]),
              ]),
          ]),
      ]),
      1 => ParagraphSpec([TextSpec('Heading $index')], heading: 2),
      >= 2 && < 12 => ParagraphSpec([
        TextSpec('Item $index'),
      ], format: ParagraphFormat(list: ListRef(list))),
      _ => ParagraphSpec([
        TextSpec('Text $index with '),
        TextSpec('bold', const RunFormat(bold: true)),
        TextSpec(' words.'),
      ]),
    });
  }
  return spec;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'a long document opens and shows its pages in time',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final bytes = DocxBuilder(_longDocument(3000)).build().encode();
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

      final watch = Stopwatch()..start();
      session.open(OpenedFile(name: 'long.docx', bytes: bytes));
      await tester.pumpWidget(
        VogesWordApp(
          session: session,
          systemOpen: SystemOpen(files),
          recents: RecentFiles(files),
          fonts: FontCatalog(
            listSystemFonts: () async => const [],
            readGoogleCatalog: () async => '',
          ),
          launchArguments: const [],
          language: AppLanguage(),
        ),
      );
      expect(watch.elapsed, lessThan(_bound));

      expect(session.controller.document.root.childCount, 2460);
      expect(
        find.textContaining('Text 2999 with', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Cell 2950 1 1', findRichText: true),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
