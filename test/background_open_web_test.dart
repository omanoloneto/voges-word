// The web has no isolates; run with `flutter test --platform chrome`.
@TestOn('browser')
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('on the web files are read here, with no time limit', () async {
    expect(kIsWeb, isTrue);
    final tables = TableStore();
    final docx = DocxCodec(tables);
    final session = EditorSession(
      docx: docx,
      plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
      files: DocumentFiles(),
      tables: tables,
    )..openTimeLimit = Duration.zero;

    await session.openInBackground(
      OpenedFile(
        name: 'page.html',
        bytes: Uint8List.fromList(utf8.encode('<p>Web page</p>')),
      ),
    );
    expect(session.name, 'page.html');
    expect(session.controller.document.toPlainText(), 'Web page\n');

    await expectLater(
      session.openInBackground(
        OpenedFile(name: 'x.docx', bytes: Uint8List.fromList([1, 2, 3])),
      ),
      throwsA(
        isA<DocumentProblemException>().having(
          (error) => error.problem,
          'problem',
          DocumentProblem.notWordDocument,
        ),
      ),
    );
  });
}
