import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';
import 'package:voges_word/spell/spell_checker.dart';

// Many times what a laptop takes in debug mode, so loaded machines pass.
const _bound = Duration(seconds: 60);

List<Misspelling> _hauses(String text) => [
  for (final match in RegExp('hause').allMatches(text))
    Misspelling(match.start, match.end, const ['house']),
];

class _InstantBackend implements SpellBackend {
  @override
  Future<List<List<Misspelling>>> check(
    List<String> texts,
    String language,
  ) async => [for (final text in texts) _hauses(text)];
}

/// Answers each batch at the end of the next frame, as when rebuilding a
/// long document takes longer than checking a batch.
class _FramePacedBackend implements SpellBackend {
  var texts = 0;
  var pending = 0;

  @override
  Future<List<List<Misspelling>>> check(List<String> texts, String language) {
    this.texts += texts.length;
    pending++;
    final answer = Completer<List<List<Misspelling>>>();
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        pending--;
        answer.complete([for (final text in texts) _hauses(text)]);
      })
      ..scheduleFrame();
    return answer.future;
  }
}

/// Counts how many times the editor asks for each paragraph.
class _CountingChecker extends SpellChecker {
  _CountingChecker(super.backend);

  final asked = <String, int>{};

  @override
  List<Misspelling>? misspellingsOf(String text) {
    asked.update(text, (count) => count + 1, ifAbsent: () => 1);
    return super.misspellingsOf(text);
  }
}

Future<EditorSession> _show(
  WidgetTester tester,
  Delta content,
  SpellChecker checker,
) async {
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
  session.open(OpenedFile(name: 'text.docx', bytes: docx.encode(content)));
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
      spelling: checker,
    ),
  );
  return session;
}

/// Lets the checker start, check and announce what the editor asked for.
Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

List<String> _underlined(WidgetTester tester) => [
  for (final text in tester.widgetList<RichText>(find.byType(RichText)))
    for (final span in _spans(text.text))
      if (span.style?.decorationStyle == TextDecorationStyle.wavy) span.text!,
];

List<TextSpan> _spans(InlineSpan root) {
  final spans = <TextSpan>[];
  root.visitChildren((span) {
    if (span is TextSpan) spans.add(span);
    return true;
  });
  return spans;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('underlines the misspelled part of every run', (tester) async {
    final checker = SpellChecker(_InstantBackend());
    addTearDown(checker.dispose);
    await _show(
      tester,
      Delta()
        ..insert('My ha')
        ..insert('use is', {'bold': true})
        ..insert(' blue, hause')
        ..insert(' and hause', {'italic': true})
        ..insert('\n'),
      checker,
    );
    await _settle(tester);

    expect(_underlined(tester), ['ha', 'use', 'hause', 'hause']);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('the underline follows its word when a run goes before it', (
    tester,
  ) async {
    final checker = SpellChecker(_InstantBackend());
    addTearDown(checker.dispose);
    final session = await _show(
      tester,
      Delta()
        ..insert('My ')
        ..insert('hause is blue', {'italic': true})
        ..insert('\n'),
      checker,
    );
    await _settle(tester);
    expect(_underlined(tester), ['hause']);

    session.controller.compose(
      Delta()
        ..retain(3)
        ..insert('big ', {'bold': true}),
      const TextSelection.collapsed(offset: 7),
      ChangeSource.local,
    );
    await _settle(tester);

    expect(session.controller.document.toPlainText(), 'My big hause is blue\n');
    // Quill's cached offset of the italic run stays where it was.
    expect(_underlined(tester), ['hause']);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets(
    'a paragraph of many runs is looked up once per build',
    (tester) async {
      final checker = _CountingChecker(_InstantBackend());
      addTearDown(checker.dispose);
      final content = Delta();
      for (var index = 0; index < 10000; index++) {
        content.insert(
          index % 100 == 0 ? 'hause ' : 'word$index ',
          index.isOdd ? {'bold': true} : null,
        );
      }
      content.insert('\n');
      await _show(tester, content, checker);
      await _settle(tester);
      final paragraph = checker.asked.keys.single;
      final asked = checker.asked[paragraph]!;

      final watch = Stopwatch()..start();
      checker.ignore('nothing');
      await tester.pump();

      // It was once per run: each build cost the runs times the paragraph.
      expect(checker.asked[paragraph]! - asked, 1);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(_underlined(tester), List.filled(100, 'hause'));
      await tester.pump(const Duration(milliseconds: 500));
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  testWidgets(
    'a long document is checked with few rebuilds of the editor',
    (tester) async {
      final backend = _FramePacedBackend();
      final checker = _CountingChecker(backend);
      addTearDown(checker.dispose);
      final content = Delta();
      for (var index = 0; index < 2000; index++) {
        content.insert('Paragraph $index has a hause in it.\n');
      }
      await _show(tester, content, checker);
      const first = 'Paragraph 0 has a hause in it.';
      final shown = checker.asked[first]!;

      final watch = Stopwatch()..start();
      var checked = -1;
      while (checked != backend.texts) {
        checked = backend.texts;
        await tester.pump(const Duration(milliseconds: 500));
        while (backend.pending > 0) {
          await tester.pump();
        }
      }

      // Every batch of 20 paragraphs rebuilt the editor: 200 rebuilds.
      expect(checker.asked[first]! - shown, lessThanOrEqualTo(15));
      expect(watch.elapsed, lessThan(_bound));
      expect(_underlined(tester), hasLength(2000));
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
