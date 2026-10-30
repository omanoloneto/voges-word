import 'dart:convert';

import 'package:flutter/material.dart'
    show CircularProgressIndicator, FocusManager, SnackBar, TextButton;
import 'package:flutter/services.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/recovery.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';

class _MemoryRecovery extends RecoveryStore {
  _MemoryRecovery(this.stored);

  RecoverySnapshot? stored;

  @override
  Future<void> save(RecoverySnapshot snapshot) async => stored = snapshot;

  @override
  Future<RecoverySnapshot?> load() async => stored;

  @override
  Future<void> clear() async => stored = null;
}

Future<EditorSession> _pumpApp(
  WidgetTester tester, {
  RecoveryStore? recovery,
}) async {
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
      recovery: recovery,
    ),
  );
  await tester.pumpAndSettle();
  return session;
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// What the system sends when the user opens files with the app.
Future<void> _openWith(
  WidgetTester tester,
  Map<String, Uint8List> files,
) async {
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'voges_word/open',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('open', [
        for (final MapEntry(key: name, value: bytes) in files.entries)
          {'name': name, 'bytes': bytes},
      ]),
    ),
    (_) {},
  );
  // The first pump runs the handler, which pushes the progress; the second
  // draws it.
  await tester.pump();
  await tester.pump();
}

/// The isolate that reads the file answers through real events, which the
/// fake clock of widget tests only lets through in [WidgetTester.runAsync].
Future<void> _waitUntil(WidgetTester tester, bool Function() done) async {
  for (var turn = 0; turn < 3000 && !done(); turn++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(done(), isTrue);
}

Finder _opening(String name) => find.text('Opening “$name”…');

final _cancel = find.widgetWithText(TextButton, 'Cancel');

bool _gone(Finder finder) => finder.evaluate().isEmpty;

/// Markdown that takes about a second to read in debug mode, so it is still
/// opening when the test cancels it.
Uint8List _slowMarkdown() => _bytes(
  List.generate(
    50000,
    (index) => 'Paragraph $index with **bold** text.\n',
  ).join('\n'),
);

Future<void> _openAndWait(
  WidgetTester tester,
  EditorSession session,
  String name,
  String text,
) async {
  final generation = session.generation;
  await _openWith(tester, {name: _bytes(text)});
  await _waitUntil(tester, () => session.generation > generation);
  await tester.pumpAndSettle();
}

String? get _focused => FocusManager.instance.primaryFocus?.debugLabel;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a file shows the progress until it is open', (tester) async {
    final session = await _pumpApp(tester);

    await _openWith(tester, {'page.html': _bytes('<p>The opened page</p>')});
    expect(_opening('page.html'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(_opening('page.html'), findsOneWidget);
    expect(session.isUntitled, isTrue);

    await _waitUntil(tester, () => _gone(_opening('page.html')));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(session.name, 'page.html');
    expect(
      find.textContaining('The opened page', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('a file that does not open takes the progress away and '
      'says why', (tester) async {
    final session = await _pumpApp(tester);
    expect(_focused, 'document');

    await _openWith(tester, {'broken.docx': _bytes('not a document')});
    expect(_opening('broken.docx'), findsOneWidget);
    // Nothing typed goes into the document that is being replaced.
    expect(_focused, isNot('document'));

    await _waitUntil(tester, () => _gone(_opening('broken.docx')));
    await tester.pump();
    expect(find.text('The file isn’t a valid document.'), findsOneWidget);
    expect(session.isUntitled, isTrue);
    expect(_focused, 'document');
  });

  testWidgets('files asked for while one opens open after it, in turn', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    final generation = session.generation;
    final long = List.generate(
      5000,
      (index) => 'Paragraph $index with **bold** text.\n',
    ).join('\n');

    await _openWith(tester, {
      'long.md': _bytes(long),
      'short.html': _bytes('<p>Short</p>'),
    });
    expect(_opening('long.md'), findsOneWidget);
    expect(_opening('short.html'), findsNothing);

    await _waitUntil(tester, () => session.generation == generation + 2);
    await tester.pumpAndSettle();
    expect(session.name, 'short.html');
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('Cancel stops the open and keeps the document that was open', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    await _openAndWait(tester, session, 'page.html', '<p>The opened page</p>');
    final generation = session.generation;

    await _openWith(tester, {'long.md': _slowMarkdown()});
    await tester.pump(const Duration(milliseconds: 500));
    expect(_opening('long.md'), findsOneWidget);
    await tester.tap(_cancel);
    await _waitUntil(tester, () => _gone(_opening('long.md')));
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(session.generation, generation);
    expect(session.name, 'page.html');
    expect(session.dirty, isFalse);
    expect(session.controller.document.toPlainText(), 'The opened page\n');
    expect(_focused, 'document');
  });

  testWidgets('the back button cancels the open too', (tester) async {
    final session = await _pumpApp(tester);

    await _openWith(tester, {'long.md': _slowMarkdown()});
    expect(_opening('long.md'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await _waitUntil(tester, () => _gone(_opening('long.md')));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
    expect(session.isUntitled, isTrue);
    expect(session.controller.document.toPlainText(), '\n');
  });

  testWidgets('files asked for after a canceled one still open', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    final generation = session.generation;

    await _openWith(tester, {
      'long.md': _slowMarkdown(),
      'short.html': _bytes('<p>Short</p>'),
    });
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(_cancel);
    await _waitUntil(tester, () => session.generation > generation);
    await tester.pumpAndSettle();

    expect(session.generation, generation + 1);
    expect(session.name, 'short.html');
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a canceled recovery keeps the copy to offer it again', (
    tester,
  ) async {
    final snapshot = RecoverySnapshot(
      name: 'long.md',
      format: DocumentFormat.markdown,
      bytes: _slowMarkdown(),
      savedAt: DateTime(2026, 10, 30, 9),
    );
    final recovery = _MemoryRecovery(snapshot);
    final session = await _pumpApp(tester, recovery: recovery);
    await tester.tap(find.text('Recover'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_opening('long.md'), findsOneWidget);

    await tester.tap(_cancel);
    await _waitUntil(tester, () => _gone(_opening('long.md')));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
    expect(session.isUntitled, isTrue);
    expect(session.dirty, isFalse);
    expect(recovery.stored, same(snapshot));
  });

  testWidgets('the recovery copy is restored with the progress up', (
    tester,
  ) async {
    final recovery = _MemoryRecovery(
      RecoverySnapshot(
        name: 'report.docx',
        format: DocumentFormat.docx,
        bytes: DocxCodec(
          TableStore(),
        ).encode(Delta()..insert('Half-written report\n')),
        savedAt: DateTime(2026, 10, 30, 9),
      ),
    );
    final session = await _pumpApp(tester, recovery: recovery);
    await tester.tap(find.text('Recover'));
    await tester.pump();
    expect(_opening('report.docx'), findsOneWidget);

    await _waitUntil(tester, () => _gone(_opening('report.docx')));
    await tester.pumpAndSettle();
    expect(session.name, 'report.docx');
    expect(session.dirty, isTrue);
    expect(session.controller.document.toPlainText(), 'Half-written report\n');
  });
}
