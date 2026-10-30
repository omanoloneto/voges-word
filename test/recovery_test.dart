import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
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
  RecoverySnapshot? stored;
  var cleared = 0;

  @override
  Future<void> save(RecoverySnapshot snapshot) async => stored = snapshot;

  @override
  Future<RecoverySnapshot?> load() async => stored;

  @override
  Future<void> clear() async {
    stored = null;
    cleared++;
  }
}

EditorSession _session() {
  final tables = TableStore();
  final docx = DocxCodec(tables);
  return EditorSession(
    docx: docx,
    plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
    files: DocumentFiles(),
    tables: tables,
  );
}

Future<void> _pump(
  WidgetTester tester,
  EditorSession session,
  RecoveryStore recovery,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final files = DocumentFiles();
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
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('saves, checks and deletes the recovery copy', () async {
    final folder = Directory.systemTemp.createTempSync('recovery');
    addTearDown(() {
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    });
    final store = RecoveryStore(directory: () async => folder);
    final savedAt = DateTime(2026, 10, 27, 21, 30);
    await store.save(
      RecoverySnapshot(
        name: 'contract.docx',
        path: '/tmp/contract.docx',
        format: DocumentFormat.docx,
        bytes: Uint8List.fromList([1, 2, 3]),
        savedAt: savedAt,
      ),
    );

    final loaded = await store.load();
    expect(loaded?.name, 'contract.docx');
    expect(loaded?.path, '/tmp/contract.docx');
    expect(loaded?.bytes, [1, 2, 3]);
    expect(loaded?.savedAt, savedAt);

    File('${folder.path}/documento.bin').writeAsBytesSync([9, 9]);
    expect(await store.load(), isNull);

    await store.clear();
    expect(await store.load(), isNull);
  });

  testWidgets('keeps a copy while there are unsaved changes', (tester) async {
    final session = _session();
    final recovery = _MemoryRecovery();
    await _pump(tester, session, recovery);

    session.controller.replaceText(
      0,
      0,
      'New text',
      const TextSelection.collapsed(offset: 8),
    );
    await tester.pump(const Duration(seconds: 16));

    final stored = recovery.stored;
    expect(stored, isNotNull);
    final reopened = DocxCodec(TableStore()).decode(stored!.bytes);
    expect(Document.fromDelta(reopened.delta).toPlainText(), 'New text\n');
  });

  testWidgets('offers recovery on launch and reopens as unsaved', (
    tester,
  ) async {
    final tables = TableStore();
    final bytes = DocxCodec(
      tables,
    ).encode(Delta()..insert('Half-written report\n'));
    final recovery = _MemoryRecovery()
      ..stored = RecoverySnapshot(
        name: 'report.docx',
        format: DocumentFormat.docx,
        bytes: bytes,
        savedAt: DateTime(2026, 10, 27, 21, 30),
      );
    final session = _session();
    await _pump(tester, session, recovery);

    expect(find.text('Recover document?'), findsOneWidget);
    await tester.tap(find.text('Recover'));
    // The copy is read on a background isolate, whose reply only arrives
    // outside the fake clock.
    await tester.pump();
    for (var turn = 0; turn < 3000 && session.name != 'report.docx'; turn++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(session.name, 'report.docx');
    expect(session.dirty, isTrue);
    expect(session.controller.document.toPlainText(), 'Half-written report\n');
  });

  testWidgets('discarding the recovery deletes the copy', (tester) async {
    final recovery = _MemoryRecovery()
      ..stored = RecoverySnapshot(
        name: 'draft.docx',
        format: DocumentFormat.docx,
        bytes: DocxCodec(TableStore()).encode(Delta()..insert('x\n')),
        savedAt: DateTime(2026, 10, 27),
      );
    final session = _session();
    await _pump(tester, session, recovery);

    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    expect(recovery.stored, isNull);
    expect(session.dirty, isFalse);
  });
}
