import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/editor/dialogs.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';
import 'package:voges_word/l10n/l10n.dart';

class _Files extends DocumentFiles {
  /// What the user types in the save dialog; null cancels it.
  String? chosen;

  /// Name suggested and format of each save dialog.
  final asked = <(String, DocumentFormat)>[];
  final written = <String, Uint8List>{};
  final shared = <(String, String)>[];

  @override
  bool get canSaveInPlace => true;

  @override
  bool get canShare => true;

  @override
  Future<String?> chooseSaveLocation(
    String suggestedName,
    DocumentFormat format,
  ) async {
    asked.add((suggestedName, format));
    return chosen;
  }

  @override
  Future<void> write(String path, Uint8List bytes) async =>
      written[path] = bytes;

  @override
  Future<void> share(
    Uint8List bytes, {
    required String name,
    required String mime,
    required Rect origin,
  }) async => shared.add((name, mime));
}

Future<(EditorSession, _Files)> _pumpApp(
  WidgetTester tester, {
  Size size = const Size(1200, 900),
  OpenedFile? file,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final tables = TableStore();
  final docx = DocxCodec(tables);
  final files = _Files();
  final session = EditorSession(
    docx: docx,
    plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
    files: files,
    tables: tables,
  );
  session.open(
    file ??
        OpenedFile(
          name: 'report.docx',
          bytes: docx.encode(Delta()..insert('Body\n')),
        ),
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
      language: AppLanguage(),
    ),
  );
  await tester.pumpAndSettle();
  return (session, files);
}

Future<void> _openOtherFormats(WidgetTester tester) async {
  await tester.tap(find.text('File'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Other formats'));
  await tester.pumpAndSettle();
}

const _otherFormats = [
  ('OpenDocument Text (.odt)', DocumentFormat.odt),
  ('Rich Text Format (.rtf)', DocumentFormat.rtf),
  ('Web page (.html)', DocumentFormat.html),
  ('Markdown (.md)', DocumentFormat.markdown),
  ('Plain text (.txt)', DocumentFormat.plainText),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Save as saves a Word document', (tester) async {
    final (_, files) = await _pumpApp(tester);

    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save as'));
    await tester.pumpAndSettle();

    expect(files.asked, [('report.docx', DocumentFormat.docx)]);
  });

  testWidgets('Other formats lists only the formats saved besides .docx', (
    tester,
  ) async {
    await _pumpApp(tester);
    await _openOtherFormats(tester);

    final items = tester.widgetList<MenuItemButton>(
      find.byType(MenuItemButton),
    );
    expect(
      [for (final item in items) (item.child! as Text).data],
      [for (final (label, _) in _otherFormats) label],
    );
  });

  testWidgets('a click opens the list without selecting a format', (
    tester,
  ) async {
    await _pumpApp(tester);
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();

    for (var click = 0; click < 3; click++) {
      await tester.tap(
        find.text('Other formats'),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
    }

    final first = Focus.of(tester.element(find.text(_otherFormats.first.$1)));
    expect(first.hasFocus, isFalse);
  });

  testWidgets('each of the other formats saves in its format', (tester) async {
    final (_, files) = await _pumpApp(tester);

    for (final (label, format) in _otherFormats) {
      await _openOtherFormats(tester);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();

      expect(files.asked.last, ('report.${format.extension}', format));
      expect(find.text('Other formats'), findsNothing);
    }
    expect(files.asked, hasLength(_otherFormats.length));
  });

  testWidgets('saving as plain text writes a .txt and says what it keeps', (
    tester,
  ) async {
    final (session, files) = await _pumpApp(tester);
    files.chosen = '/documents/report.txt';

    await _openOtherFormats(tester);
    await tester.tap(find.text('Plain text (.txt)'));
    await tester.pumpAndSettle();

    expect(files.written.keys, ['/documents/report.txt']);
    expect(session.format, DocumentFormat.plainText);
    expect(session.name, 'report.txt');
    expect(find.text('Plain text'), findsOneWidget);
  });

  testWidgets('the formats can be chosen with the keyboard', (tester) async {
    final (_, files) = await _pumpApp(tester);
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();

    final button = Focus.of(tester.element(find.text('Other formats')));
    for (var presses = 0; presses < 20 && !button.hasPrimaryFocus; presses++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(button.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Rich Text Format (.rtf)'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Rich Text Format (.rtf)'), findsNothing);
    expect(button.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(files.asked, [('report.rtf', DocumentFormat.rtf)]);
    expect(find.text('Other formats'), findsNothing);
  });

  testWidgets('on a phone every format fits on the screen', (tester) async {
    const size = Size(360, 740);
    final (_, files) = await _pumpApp(tester, size: size);
    await _openOtherFormats(tester);

    for (final (label, _) in _otherFormats) {
      final rect = tester.getRect(find.text(label));
      expect(rect.left, greaterThanOrEqualTo(0), reason: label);
      expect(rect.right, lessThanOrEqualTo(size.width), reason: label);
      expect(rect.bottom, lessThanOrEqualTo(size.height), reason: label);
    }
    await tester.tap(find.text('Markdown (.md)'));
    await tester.pumpAndSettle();

    expect(files.asked, [('report.md', DocumentFormat.markdown)]);
    expect(tester.takeException(), isNull);
  });

  group('Share', () {
    Future<List<String>> choices(
      WidgetTester tester,
      DocumentFormat current,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => askShareFormat(context, current),
              child: const Text('Share'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      return [
        for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
          (tile.title! as Text).data!,
      ];
    }

    testWidgets('offers the format of the file when it is saved', (
      tester,
    ) async {
      expect(await choices(tester, DocumentFormat.markdown), [
        'Word document (.docx)',
        'Markdown (.md)',
        'PDF',
      ]);
    });

    testWidgets('offers .docx and PDF for Word and Word 97–2003 files', (
      tester,
    ) async {
      expect(await choices(tester, DocumentFormat.docx), [
        'Word document (.docx)',
        'PDF',
      ]);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      expect(await choices(tester, DocumentFormat.doc), [
        'Word document (.docx)',
        'PDF',
      ]);
    });

    testWidgets('sends the document in the format of its file', (tester) async {
      final (_, files) = await _pumpApp(
        tester,
        file: OpenedFile(
          name: 'notes.txt',
          bytes: Uint8List.fromList('Shopping list'.codeUnits),
        ),
      );

      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plain text (.txt)'));
      await tester.pumpAndSettle();

      expect(files.shared, [('notes.txt', 'text/plain')]);
    });
  });
}
