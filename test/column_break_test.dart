import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/editor/editor_factory.dart';
import 'package:voges_word/formats/document_codecs.dart';
import 'package:voges_word/l10n/l10n.dart';

LoadedDocument _twoColumns(DocxCodec codec) => codec.read(
  DocxBuilder(
    DocumentSpec(page: const PageSpec(columns: 2))
      ..body.add(
        const ParagraphSpec([
          TextSpec('Left column'),
          BreakSpec(BreakKind.column),
          TextSpec('Right column'),
        ]),
      ),
  ).build(),
);

void main() {
  for (final (language, label) in [
    ('en', 'Column break'),
    ('pt', 'Quebra de coluna'),
    ('es', 'Salto de columna'),
  ]) {
    testWidgets('a column break shows as a marked break ($language)', (
      tester,
    ) async {
      final tables = TableStore();
      final loaded = _twoColumns(DocxCodec(tables));
      final controller = QuillController(
        document: Document.fromDelta(loaded.delta),
        selection: const TextSelection.collapsed(offset: 0),
      );
      final focusNode = FocusNode();
      final cellFocus = FocusNode();
      final scrollController = ScrollController();
      addTearDown(() {
        controller.dispose();
        focusNode.dispose();
        cellFocus.dispose();
        scrollController.dispose();
      });
      final factory = EditorFactory(
        look: loaded.look,
        zoom: 1,
        tables: tables,
        contentWidth: 600,
        onCellFocused: (_, _) {},
        onFind: () {},
        onInsertImage: () {},
        onEditLink: () {},
        cellFocusParent: cellFocus,
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          localizationsDelegates: const [
            ...AppLocalizations.localizationsDelegates,
            FlutterQuillLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: QuillEditor(
              controller: controller,
              focusNode: focusNode,
              scrollController: scrollController,
              config: factory.config(controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final marker = find.text(label);
      expect(marker, findsOneWidget);
      final line = find.ancestor(
        of: marker,
        matching: find.byType(CustomPaint),
      );
      expect(tester.getSize(line.first).width, greaterThan(500));
    });
  }

  test(
    'the column break still saves as one in .docx and as a line break elsewhere',
    () {
      final tables = TableStore();
      final docx = DocxCodec(tables);
      final codecs = DocumentCodecs(
        docx: docx,
        plainText: PlainTextCodec(
          look: docx.createEmpty().look,
          tables: tables,
        ),
      );
      final loaded = _twoColumns(docx);
      String saved(DocumentFormat format) {
        final bytes = codecs
            .encoder(format)
            .encode(loaded.delta, source: loaded.source, look: loaded.look);
        return switch (format) {
          DocumentFormat.docx || DocumentFormat.docm => DocxPackage.decode(
            bytes,
          ).text('word/document.xml')!,
          DocumentFormat.odt => utf8.decode(
            ZipDecoder().decodeBytes(bytes).findFile('content.xml')!.content,
          ),
          _ => utf8.decode(bytes),
        };
      }

      for (final format in [DocumentFormat.docx, DocumentFormat.docm]) {
        expect(saved(format), contains('<w:br w:type="column"/>'));
        expect(saved(format), isNot(contains('<w:br/>')));
      }
      expect(
        saved(DocumentFormat.odt),
        matches(RegExp(r'Left column<text:line-break\s*/>Right column')),
      );
      expect(
        saved(DocumentFormat.rtf),
        matches(RegExp(r'Left column\{?\\line ?\}?\s*Right column')),
      );
      expect(
        saved(DocumentFormat.html),
        matches(RegExp(r'Left column<br\s*/?>\s*Right column')),
      );
      expect(
        saved(DocumentFormat.markdown),
        matches(RegExp(r'Left column(\\|  )\nRight column')),
      );
      expect(saved(DocumentFormat.plainText), 'Left column\nRight column\n');
    },
  );
}
