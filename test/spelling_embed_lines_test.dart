import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';
import 'package:voges_word/spell/spell_checker.dart';

// Transparent 1x1 PNG.
final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

class _HauseBackend implements SpellBackend {
  @override
  Future<List<List<Misspelling>>> check(
    List<String> texts,
    String language,
  ) async => [
    for (final text in texts)
      [
        for (final match in RegExp('hause').allMatches(text))
          Misspelling(match.start, match.end, const ['house']),
      ],
  ];
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

  testWidgets('paragraphs with a field or a picture are checked too', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final checker = SpellChecker(_HauseBackend());
    addTearDown(checker.dispose);
    final tables = TableStore();
    final docx = DocxCodec(tables);
    final files = DocumentFiles();
    final session = EditorSession(
      docx: docx,
      plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
      files: files,
      tables: tables,
    );
    final content = Delta()
      ..insert('Page ')
      ..insert({EmbedTypes.pageNumber: 'PAGE'})
      ..insert(' of my hause')
      ..insert('\n')
      ..insert('A ')
      ..insert(
        {EmbedTypes.image: 'data:image/png;base64,${base64Encode(_pixel)}'},
        {'width': '12', 'height': '12'},
      )
      ..insert(' and a ')
      ..insert('bold hause', {'bold': true})
      ..insert('\n')
      ..insert('No embed in this hause\n');
    session.open(OpenedFile(name: 'text.docx', bytes: docx.encode(content)));
    // The field opens as Word's content kept whole, a run of its own.
    final embeds = [
      for (final operation in session.controller.document.toDelta().toList())
        if (operation.data is Map) (operation.data as Map).keys.single,
    ];
    expect(embeds, [EmbedTypes.opaqueInline, EmbedTypes.image]);

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
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(_underlined(tester), ['hause', 'hause', 'hause']);
    await tester.pump(const Duration(milliseconds: 500));
  });
}
