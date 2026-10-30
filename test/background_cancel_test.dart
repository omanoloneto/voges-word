import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/formats/background_open.dart';

const _noLimit = Duration(minutes: 5);

final _canceled = throwsA(isA<BackgroundWorkCanceled>());

/// Sends a heartbeat now and then, and never ends.
Never _spin(SendPort heartbeat) {
  for (var count = 0; ; count++) {
    if (count % 1000000 == 0) heartbeat.send(count);
  }
}

int _double(int value) => value * 2;

/// Counts the heartbeats of [_spin].
final class _Heart {
  _Heart() {
    _port.listen((_) => beats++);
  }

  final _port = ReceivePort();
  var beats = 0;

  SendPort get sendPort => _port.sendPort;

  void close() => _port.close();

  Future<void> firstBeat() async {
    while (beats == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Heartbeats sent just before the kill may still be on their way.
  Future<void> expectStopped() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final afterKill = beats;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(beats, afterKill);
  }
}

/// Markdown that takes about a second to read in debug mode.
Uint8List _slowMarkdown() => Uint8List.fromList(
  utf8.encode(
    List.generate(
      50000,
      (index) => 'Paragraph $index with **bold** text.\n',
    ).join('\n'),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cancel kills work that never ends at once', () async {
    final heart = _Heart();
    addTearDown(heart.close);
    final scope = CancelScope();

    final work = scope.run(
      () => runWithTimeLimit(_spin, heart.sendPort, _noLimit),
    );
    await heart.firstBeat();
    scope.cancel();
    await expectLater(work, _canceled);
    await heart.expectStopped();
  });

  test('cancel while the isolate starts kills it as soon as it runs', () async {
    final heart = _Heart();
    addTearDown(heart.close);
    final scope = CancelScope();

    final work = scope.run(
      () => runWithTimeLimit(_spin, heart.sendPort, _noLimit),
    );
    scope.cancel();
    await expectLater(work, _canceled);
    await heart.expectStopped();
  });

  test('cancel reaches only the work started in its scope, and only while '
      'it runs', () async {
    final scope = CancelScope();
    expect(await scope.run(() => runWithTimeLimit(_double, 21, _noLimit)), 42);
    scope.cancel();
    expect(await runWithTimeLimit(_double, 4, _noLimit), 8);

    final heart = _Heart();
    addTearDown(heart.close);
    final other = CancelScope();
    final spinning = other.run(
      () => runWithTimeLimit(_spin, heart.sendPort, _noLimit),
    );
    await heart.firstBeat();
    CancelScope().cancel();
    expect(await runWithTimeLimit(_double, 5, _noLimit), 10);
    final beats = heart.beats;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(heart.beats, greaterThan(beats));
    other.cancel();
    await expectLater(spinning, _canceled);
  });

  test('a canceled open is not refused as a damaged file and leaves the '
      'session as it was', () async {
    final tables = TableStore();
    final docx = DocxCodec(tables);
    final session = EditorSession(
      docx: docx,
      plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
      files: DocumentFiles(),
      tables: tables,
    );
    final generation = session.generation;
    final scope = CancelScope();

    final opening = scope.run(
      () => session.openInBackground(
        OpenedFile(name: 'long.md', bytes: _slowMarkdown()),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    scope.cancel();
    await expectLater(opening, _canceled);
    expect(session.generation, generation);
    expect(session.isUntitled, isTrue);
  });
}
