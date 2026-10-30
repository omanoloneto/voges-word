import 'package:flutter/material.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/editor/status_bar.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/recovery.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';

/// Pumps the app with a document whose file is in [format].
Future<void> _pumpWithFormat(
  WidgetTester tester,
  DocumentFormat format, {
  Size size = const Size(1200, 900),
  Locale? locale,
}) async {
  tester.view.physicalSize = size;
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
  session.restore(
    RecoverySnapshot(
      name: 'file.${format.extension}',
      format: format,
      content: DocumentFormat.docx,
      bytes: docx.encode(Delta()..insert('Body\n')),
      savedAt: DateTime(2026, 10, 29),
    ),
    keepPath: false,
  );
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
      language: AppLanguage(locale),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _inStatusBar(Finder finder) =>
    find.descendant(of: find.byType(StatusBar), matching: finder);

const _notes = [
  (
    DocumentFormat.plainText,
    'Plain text',
    '.txt files keep only the text. Use “Save as” to keep the formatting.',
  ),
  (
    DocumentFormat.markdown,
    'Markdown',
    '.md files keep only basic formatting. Use “Save as” to keep all of it.',
  ),
  (
    DocumentFormat.html,
    'Web page',
    'Web pages don’t keep the page setup, headers or footers. '
        'Use “Save as” to keep them.',
  ),
  (
    DocumentFormat.doc,
    'Word 97–2003',
    'Voges Word doesn’t write Word 97–2003 files: saving creates a .docx '
        'copy and leaves the original untouched.',
  ),
  (
    DocumentFormat.docm,
    'Word with macros',
    'Macros are kept when you save, but Voges Word never runs them. '
        '“Save as” creates a .docx without them.',
  ),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (format, label, message) in _notes) {
    testWidgets('a .${format.extension} file shows “$label” and why', (
      tester,
    ) async {
      await _pumpWithFormat(tester, format);

      expect(_inStatusBar(find.text(label)), findsOneWidget);
      expect(_inStatusBar(find.byTooltip(message)), findsOneWidget);
    });
  }

  for (final format in [
    DocumentFormat.docx,
    DocumentFormat.odt,
    DocumentFormat.rtf,
  ]) {
    testWidgets('a .${format.extension} file shows no note', (tester) async {
      await _pumpWithFormat(tester, format);

      expect(_inStatusBar(find.byType(Tooltip)), findsNothing);
    });
  }

  testWidgets('losses are warnings; the rest are information', (tester) async {
    await _pumpWithFormat(tester, DocumentFormat.html);
    expect(
      _inStatusBar(find.byIcon(Icons.warning_amber_rounded)),
      findsOneWidget,
    );

    await _pumpWithFormat(tester, DocumentFormat.docm);
    expect(_inStatusBar(find.byIcon(Icons.info_outline)), findsOneWidget);
    expect(
      _inStatusBar(find.byIcon(Icons.warning_amber_rounded)),
      findsNothing,
    );
  });

  testWidgets('on a phone the note is an icon that explains itself on tap', (
    tester,
  ) async {
    await _pumpWithFormat(
      tester,
      DocumentFormat.markdown,
      size: const Size(360, 740),
    );
    expect(_inStatusBar(find.text('Markdown')), findsNothing);

    await tester.tap(_inStatusBar(find.byIcon(Icons.warning_amber_rounded)));
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.text(
        '.md files keep only basic formatting. Use “Save as” to keep all of it.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the longest note fits the narrowest window', (tester) async {
    await _pumpWithFormat(
      tester,
      DocumentFormat.plainText,
      size: const Size(480, 600),
      locale: const Locale('es'),
    );

    expect(_inStatusBar(find.text('Texto sin formato')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
