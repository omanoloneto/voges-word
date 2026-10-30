import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recovery.dart';
import 'package:voges_word/formats/document_codecs.dart';

class _Files extends DocumentFiles {
  _Files(this.chosen);

  /// What the user types in the save dialog.
  final String? chosen;
  final written = <String, Uint8List>{};
  String? suggested;

  @override
  bool get canSaveInPlace => true;

  @override
  Future<String?> chooseSaveLocation(
    String suggestedName,
    DocumentFormat format,
  ) async {
    suggested = suggestedName;
    return chosen;
  }

  @override
  Future<void> write(String path, Uint8List bytes) async =>
      written[path] = bytes;
}

EditorSession _session(DocumentFiles files) {
  final tables = TableStore();
  final docx = DocxCodec(tables);
  return EditorSession(
    docx: docx,
    plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
    files: files,
    tables: tables,
  );
}

Uint8List _docx(String text) =>
    DocxCodec(TableStore()).encode(Delta()..insert('$text\n'));

Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  for (final MapEntry(key: name, value: content) in files.entries) {
    archive.addFile(
      ArchiveFile.bytes(name, utf8.encode(content))
        // OpenDocument stores its mimetype entry uncompressed.
        ..compression = name == 'mimetype' ? CompressionType.none : null,
    );
  }
  return ZipEncoder().encodeBytes(archive);
}

Uint8List _ascii(String text) => Uint8List.fromList(latin1.encode(text));

final _cfb = Uint8List.fromList([
  0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, //
  ...List.filled(504, 0),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('detectFormat', () {
    ({DocumentFormat format, bool template})? detect(
      String name,
      Uint8List bytes,
    ) => detectFormat(name, bytes);

    test('goes by the content before the name', () {
      final odt = _zip({
        'mimetype': 'application/vnd.oasis.opendocument.text',
        'content.xml': '<x/>',
      });
      expect(detect('a.doc', _cfb)?.format, DocumentFormat.doc);
      expect(detect('a.docx', _cfb)?.format, DocumentFormat.doc);
      expect(detect('a.doc', _docx('x'))?.format, DocumentFormat.docx);
      expect(detect('a.docx', odt)?.format, DocumentFormat.odt);
      expect(
        detect('a.doc', _ascii(r'{\rtf1\ansi x}'))?.format,
        DocumentFormat.rtf,
      );
      expect(
        detect(
          'a.doc',
          Uint8List.fromList(
            utf8.encode('\uFEFF  <!DOCTYPE html><html><body>x'),
          ),
        )?.format,
        DocumentFormat.html,
      );
      expect(
        detect(
          'a.doc',
          Uint8List.fromList([0xEF, 0xBB, 0xBF, ...'<html>'.codeUnits]),
        )?.format,
        DocumentFormat.html,
      );
    });

    test('keeps the name when the content says nothing', () {
      expect(detect('a.odt', _zip({'x': 'y'}))?.format, DocumentFormat.odt);
      expect(detect('a.docm', _docx('x'))?.format, DocumentFormat.docm);
      expect(detect('a.rtf', _ascii('plain'))?.format, DocumentFormat.rtf);
      expect(detect('A.HTM', _ascii('hi'))?.format, DocumentFormat.html);
      expect(
        detect('a.markdown', _ascii('# hi'))?.format,
        DocumentFormat.markdown,
      );
    });

    test('text and Markdown stay text', () {
      expect(
        detect('a.txt', _ascii('<html>x'))?.format,
        DocumentFormat.plainText,
      );
      expect(
        detect('a.md', _ascii(r'{\rtf1 x}'))?.format,
        DocumentFormat.markdown,
      );
      expect(detect('a.txt', _cfb)?.format, DocumentFormat.plainText);
    });

    test('templates', () {
      expect(detect('a.dotx', _docx('x')), (
        format: DocumentFormat.docx,
        template: true,
      ));
      expect(detect('a.dotm', _docx('x')), (
        format: DocumentFormat.docx,
        template: true,
      ));
      expect(detect('a.dot', _cfb), (
        format: DocumentFormat.doc,
        template: true,
      ));
      expect(detect('a.ott', _zip({'x': 'y'})), (
        format: DocumentFormat.odt,
        template: true,
      ));
    });

    test('unknown extensions are not opened', () {
      expect(detect('a.pages', _docx('x')), isNull);
      expect(detect('noextension', _cfb), isNull);
    });
  });

  group('EditorSession', () {
    test('a template opens as a new document', () {
      final session = _session(_Files(null));
      session.open(
        OpenedFile(
          name: 'Letter.dotx',
          bytes: _docx('Dear'),
          path: '/t/Letter.dotx',
        ),
      );
      expect(session.isUntitled, isTrue);
      expect(session.path, isNull);
      expect(session.format, DocumentFormat.docx);
      expect(session.controller.document.toPlainText(), 'Dear\n');
    });

    test('a misnamed file opens by its content and keeps its name', () {
      final session = _session(_Files(null));
      session.open(
        OpenedFile(name: 'old.doc', bytes: _docx('Hi'), path: '/t/old.doc'),
      );
      expect(session.format, DocumentFormat.docx);
      expect(session.name, 'old.doc');
      expect(session.notices, isEmpty);
    });

    test('unknown names and broken files report the problem', () {
      final session = _session(_Files(null));
      expect(
        () => session.open(OpenedFile(name: 'a.pages', bytes: _docx('x'))),
        throwsA(
          isA<DocumentProblemException>().having(
            (error) => error.problem,
            'problem',
            DocumentProblem.unsupportedFormat,
          ),
        ),
      );
      expect(
        () => session.open(
          OpenedFile(name: 'a.docx', bytes: _ascii('not a zip')),
        ),
        throwsA(isA<DocumentProblemException>()),
      );
    });

    test('a format that isn\'t saved goes to Save As .docx', () async {
      final files = _Files('/t/report.docx');
      final session = _session(files);
      session.restore(
        RecoverySnapshot(
          name: 'report.doc',
          path: '/t/report.doc',
          format: DocumentFormat.doc,
          content: DocumentFormat.docx,
          bytes: _docx('Body'),
          savedAt: DateTime(2026, 10, 29),
        ),
        keepPath: true,
      );

      expect(await session.save(), isTrue);
      expect(files.suggested, 'report.docx');
      expect(files.written.keys, ['/t/report.docx']);
      expect(session.format, DocumentFormat.docx);
      expect(session.path, '/t/report.docx');
      expect(session.dirty, isFalse);
    });

    test(
      'a typed extension of a format that isn\'t saved is not used',
      () async {
        final files = _Files('/t/copy.doc');
        final session = _session(files);
        expect(await session.saveAs(DocumentFormat.docx), isTrue);
        expect(files.written.keys, ['/t/copy.doc.docx']);
        expect(session.format, DocumentFormat.docx);
      },
    );

    test('a typed extension of another saved format is honored', () async {
      final files = _Files('/t/notes.txt');
      final session = _session(files);
      expect(await session.saveAs(DocumentFormat.docx), isTrue);
      expect(files.written.keys, ['/t/notes.txt']);
      expect(session.format, DocumentFormat.plainText);
    });

    test('the recovery copy of a text file is a .docx', () {
      final session = _session(_Files(null));
      session.open(
        OpenedFile(name: 'notes.txt', bytes: _ascii('line'), path: '/t/n.txt'),
      );
      final snapshot = session.snapshot();
      expect(snapshot.format, DocumentFormat.plainText);
      expect(snapshot.content, DocumentFormat.docx);

      final other = _session(_Files(null))..restore(snapshot, keepPath: true);
      expect(other.format, DocumentFormat.plainText);
      expect(other.controller.document.toPlainText(), 'line\n');
    });
  });

  test('recovery copies from 1.2.0 read their bytes in their format', () async {
    final folder = Directory.systemTemp.createTempSync('recovery');
    addTearDown(() => folder.deleteSync(recursive: true));
    final store = RecoveryStore(directory: () async => folder);
    await store.save(
      RecoverySnapshot(
        name: 'old.txt',
        format: DocumentFormat.plainText,
        bytes: Uint8List.fromList(utf8.encode('old text')),
        savedAt: DateTime(2026, 10, 20),
      ),
    );
    final info = File('${folder.path}/documento.json');
    final json = jsonDecode(info.readAsStringSync()) as Map<String, dynamic>
      ..remove('content');
    info.writeAsStringSync(jsonEncode(json));

    final loaded = await store.load();
    expect(loaded?.format, DocumentFormat.plainText);
    expect(loaded?.content, DocumentFormat.plainText);
  });
}
