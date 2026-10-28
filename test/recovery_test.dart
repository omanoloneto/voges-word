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
      recovery: recovery,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('guarda, confere e apaga a cópia de recuperação', () async {
    final folder = Directory.systemTemp.createTempSync('recuperacao');
    addTearDown(() {
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    });
    final store = RecoveryStore(directory: () async => folder);
    final savedAt = DateTime(2026, 10, 27, 21, 30);
    await store.save(
      RecoverySnapshot(
        name: 'contrato.docx',
        path: '/tmp/contrato.docx',
        format: DocumentFormat.docx,
        bytes: Uint8List.fromList([1, 2, 3]),
        savedAt: savedAt,
      ),
    );

    final loaded = await store.load();
    expect(loaded?.name, 'contrato.docx');
    expect(loaded?.path, '/tmp/contrato.docx');
    expect(loaded?.bytes, [1, 2, 3]);
    expect(loaded?.savedAt, savedAt);

    File('${folder.path}/documento.bin').writeAsBytesSync([9, 9]);
    expect(await store.load(), isNull);

    await store.clear();
    expect(await store.load(), isNull);
  });

  testWidgets('guarda uma cópia enquanto há alterações não salvas', (
    tester,
  ) async {
    final session = _session();
    final recovery = _MemoryRecovery();
    await _pump(tester, session, recovery);

    session.controller.replaceText(
      0,
      0,
      'Texto novo',
      const TextSelection.collapsed(offset: 10),
    );
    await tester.pump(const Duration(seconds: 16));

    final stored = recovery.stored;
    expect(stored, isNotNull);
    final reopened = DocxCodec(TableStore()).decode(stored!.bytes);
    expect(Document.fromDelta(reopened.delta).toPlainText(), 'Texto novo\n');
  });

  testWidgets('oferece recuperar ao abrir e reabre como não salvo', (
    tester,
  ) async {
    final tables = TableStore();
    final bytes = DocxCodec(
      tables,
    ).encode(Delta()..insert('Parecer pela metade\n'));
    final recovery = _MemoryRecovery()
      ..stored = RecoverySnapshot(
        name: 'parecer.docx',
        format: DocumentFormat.docx,
        bytes: bytes,
        savedAt: DateTime(2026, 10, 27, 21, 30),
      );
    final session = _session();
    await _pump(tester, session, recovery);

    expect(find.text('Recuperar documento?'), findsOneWidget);
    await tester.tap(find.text('Recuperar'));
    await tester.pumpAndSettle();

    expect(session.name, 'parecer.docx');
    expect(session.dirty, isTrue);
    expect(session.controller.document.toPlainText(), 'Parecer pela metade\n');
  });

  testWidgets('descartar a recuperação apaga a cópia', (tester) async {
    final recovery = _MemoryRecovery()
      ..stored = RecoverySnapshot(
        name: 'rascunho.docx',
        format: DocumentFormat.docx,
        bytes: DocxCodec(TableStore()).encode(Delta()..insert('x\n')),
        savedAt: DateTime(2026, 10, 27),
      );
    final session = _session();
    await _pump(tester, session, recovery);

    await tester.tap(find.text('Descartar'));
    await tester.pumpAndSettle();

    expect(recovery.stored, isNull);
    expect(session.dirty, isFalse);
  });
}
