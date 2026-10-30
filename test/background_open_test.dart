import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/document_look.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/headers_footers.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recovery.dart';
import 'package:voges_word/formats/background_open.dart';
import 'package:voges_word/formats/document_codecs.dart';

import 'doc_fixtures.dart';
import 'odt_fixtures.dart';

const _noLimit = Duration(minutes: 5);

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

DocumentCodecs _codecs(TableStore tables) => DocumentCodecs(
  docx: DocxCodec(tables),
  plainText: PlainTextCodec(look: const DocumentLook(), tables: tables),
);

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

Matcher _refusedAs(DocumentProblem problem) => throwsA(
  isA<DocumentProblemException>().having(
    (error) => error.problem,
    'problem',
    problem,
  ),
);

/// An ordinary Markdown file that takes package:markdown about a second in
/// debug mode.
Uint8List _longMarkdown() => _bytes(
  List.generate(
    50000,
    (index) => 'Paragraph $index with **bold** text.\n',
  ).join('\n'),
);

/// Sends a heartbeat now and then, and never ends.
Never _spin(SendPort heartbeat) {
  for (var count = 0; ; count++) {
    if (count % 1000000 == 0) heartbeat.send(count);
  }
}

int _double(int value) => value * 2;

int _refuse(DocumentProblem problem) => throw DocumentProblemException(problem);

/// A .docx with what the readers carry: styles, lists, a table, a header.
Uint8List _richDocx() {
  final tables = TableStore();
  final table = tables.createEmpty(rows: 2, columns: 2, totalWidth: 9000);
  table.rows[0].cells[0].controller.document.insert(0, 'Cell');
  return DocxCodec(tables).encode(
    Delta()
      ..insert('Title')
      ..insert('\n', {'header': 1})
      ..insert('Bold', {'bold': true})
      ..insert(' text\nItem')
      ..insert('\n', {'list': 'ordered'})
      ..insert({EmbedTypes.table: encodeTableId(table.id)})
      ..insert('\nAfter the table\n'),
    headersFooters: HeadersFooters(
      headers: {
        PageVariant.normal: HeaderFooterStory(
          delta: Delta()..insert('Header\n'),
          edited: true,
        ),
      },
    ),
  );
}

/// A Word document with macros, as a .docm holds them.
Uint8List _docm() {
  final package = DocxPackage.decode(
    DocxCodec(
      TableStore(),
      flavor: DocxFlavor.macroEnabled,
    ).encode(Delta()..insert('Macros\n')),
  );
  package.parts['word/vbaProject.bin'] = Uint8List.fromList([1, 2, 3]);
  package.addRelationships(package.mainDocumentPath, const [
    Relationship(
      id: 'rIdVba',
      type: 'http://schemas.microsoft.com/office/2006/relationships/vbaProject',
      target: 'vbaProject.bin',
    ),
  ]);
  package.ensureContentTypes(
    defaults: {'bin': 'application/vnd.ms-office.vbaProject'},
  );
  return package.encode();
}

/// Files of every format, and the ways of naming them that change how they
/// open: templates, files named in another format, a page that loses
/// characters.
Map<String, Uint8List> _openable() {
  final word = _richDocx();
  final rtf = Uint8List.fromList(
    latin1.encode(
      r'{\rtf1\ansi{\fonttbl{\f0 Arial;}}\f0 Plain {\b bold}\par Next\par}',
    ),
  );
  final doc =
      (DocWriter()
            ..line('Word 97 text', sprms: bold)
            ..line('Second line'))
          .build();
  final odt = odtFile(
    body: '<text:h text:outline-level="1">Title</text:h><text:p>Body</text:p>',
  );
  return {
    for (final file in Directory(
      'test/fixtures',
    ).listSync(recursive: true).whereType<File>())
      file.path.substring('test/fixtures/'.length).replaceAll('/', '-'): file
          .readAsBytesSync(),
    'report.docx': word,
    'Letter.dotx': word,
    'macros.docm': _docm(),
    'old.doc': doc,
    'Old.dot': doc,
    'text.odt': odt,
    'Form.ott': odt,
    'letter.rtf': rtf,
    'report.doc': rtf,
    'Word file.rtf': word,
    'page.html': _bytes(
      '<!DOCTYPE html><html><body><h1>Title</h1><p>Body <b>bold</b></p>'
      '<ul><li>One</li><li>Two</li></ul></body></html>',
    ),
    'japanese.html': Uint8List.fromList([
      ...latin1.encode(
        '<html><head><meta charset="iso-2022-jp"></head><body><p>Hi ',
      ),
      0x1B, 0x24, 0x42, 0x30, 0x21, 0x1B, 0x28, 0x42, //
      ...latin1.encode('</p></body></html>'),
    ]),
    'notes.md': _bytes('# Title\n\nBody with *emphasis*.\n\n- One\n- Two\n'),
    'notes.txt': _bytes('Line one\r\nLine two\rLine three'),
  };
}

/// Files that are refused, each for a different reason.
Map<String, Uint8List> _refused() => {
  'slides.pages': _richDocx(),
  'text.docx': _bytes('not a document'),
  'secret.doc':
      (DocWriter()
            ..encrypted = true
            ..line('secret'))
          .build(),
  'old95.doc':
      (DocWriter()
            ..version = 0x68
            ..line('Word 95'))
          .build(),
  'broken.doc':
      (DocWriter()
            ..version = 0xC1
            ..line('Dear'))
          .build(
            mutate: (name, stream) {
              if (name == 'WordDocument') stream.setRange(0, 2, u16(0x1234));
            },
          ),
  'locked.odt': odtFile(
    manifest:
        '<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0">'
        '<manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/>'
        '<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml">'
        '<manifest:encryption-data manifest:checksum-type="SHA1/1K" manifest:checksum="x"/>'
        '</manifest:file-entry></manifest:manifest>',
  ),
  'huge.md': _bytes('word ' * (1024 * 1024)),
};

String _delta(Delta delta) => jsonEncode(
  delta.toJson(),
  toEncodable: (value) => '$value',
).replaceAll(_packageId, 'pkg');

/// Each read makes a new package, with a new id.
final _packageId = RegExp(r'pkg\d+');

Map<String, Object?> _textLook(TextLook look) => {
  'size': look.fontSize,
  'family': look.fontFamily,
  'color': look.color.toARGB32(),
  'bold': look.bold,
  'italic': look.italic,
  'before': look.spaceBefore,
  'after': look.spaceAfter,
  'right': look.indentRight,
  'first': look.firstLine,
};

Map<String, Object?> _look(DocumentLook look) => {
  'page': [look.pageWidth, look.pageHeight],
  'margins': '${look.margins}',
  'body': _textLook(look.body),
  'headings': {
    for (final MapEntry(:key, :value) in look.headings.entries)
      '$key': _textLook(value),
  },
  'lineSpacing': look.lineSpacing,
};

Map<String, Object?> _stories(Map<PageVariant, HeaderFooterStory> stories) => {
  for (final MapEntry(:key, :value) in stories.entries)
    key.name: {
      'text': _delta(value.delta),
      'part': value.partPath,
      'edited': value.edited,
    },
};

Map<String, Object?> _headersFooters(HeadersFooters value) => {
  'headers': _stories(value.headers),
  'footers': _stories(value.footers),
  'firstPage': value.differentFirstPage,
  'oddEven': value.differentOddEven,
  'distances': [value.headerDistance, value.footerDistance],
};

Map<String, Object?> _table(TableModel table) => {
  'id': table.id,
  'package': table.packageId?.replaceAll(_packageId, 'pkg'),
  'widths': table.columnWidths,
  'properties': table.propertiesXml,
  'bordered': table.bordered,
  'rows': [
    for (final row in table.rows)
      {
        'properties': row.propertiesXml,
        'cells': [
          for (final cell in row.cells)
            {
              'properties': cell.propertiesXml,
              'span': cell.gridSpan,
              'merge': cell.verticalMerge.name,
              'fill': cell.fill?.toARGB32(),
              'text': _delta(cell.controller.document.toDelta()),
            },
        ],
      },
  ],
};

Map<String, String> _parts(Map<String, Uint8List> parts) => {
  for (final MapEntry(:key, :value) in parts.entries)
    key: sha256.convert(value).toString(),
};

/// What a read file gives the editor.
Map<String, Object?> _loaded(LoadedDocument loaded, TableStore tables) => {
  'text': _delta(loaded.delta),
  'look': _look(loaded.look),
  'headersFooters': _headersFooters(loaded.headersFooters),
  'notices': [for (final notice in loaded.notices) notice.name],
  'source': switch (loaded.source) {
    final DocxPackage package => _parts(package.parts),
    final other => '$other',
  },
  'tables': [for (final table in tables.all) _table(table)],
};

/// What a session shows and saves.
Map<String, Object?> _shown(EditorSession session) => {
  'name': session.name,
  'path': session.path,
  'untitled': session.isUntitled,
  'format': session.format.name,
  'dirty': session.dirty,
  'notices': [for (final notice in session.notices) notice.name],
  'look': _look(session.look),
  'headersFooters': _headersFooters(session.headersFooters),
  'text': _delta(session.controller.document.toDelta()),
  'tables': [for (final table in session.tables.all) _table(table)],
  'saved': _parts(
    DocxPackage.decode(session.encode(DocumentFormat.docx)).parts,
  ),
};

/// The problem the screen reports for what [open] throws.
Future<DocumentProblem?> _problemOf(FutureOr<void> Function() open) async {
  try {
    await open();
    return null;
  } on DocumentProblemException catch (error) {
    return error.problem;
  } on FormatException {
    return DocumentProblem.damaged;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('runWithTimeLimit', () {
    test('returns what the work returns and throws what it throws', () async {
      expect(await runWithTimeLimit(_double, 21, _noLimit), 42);
      await expectLater(
        runWithTimeLimit(_refuse, DocumentProblem.legacyDoc, _noLimit),
        _refusedAs(DocumentProblem.legacyDoc),
      );
    });

    test(
      'kills work that never ends at the limit, and this isolate runs meanwhile',
      () async {
        final heartbeats = ReceivePort();
        addTearDown(heartbeats.close);
        var beats = 0;
        heartbeats.listen((_) => beats++);
        var ticks = 0;
        final ticker = Timer.periodic(
          const Duration(milliseconds: 5),
          (_) => ticks++,
        );
        addTearDown(ticker.cancel);

        await expectLater(
          runWithTimeLimit(
            _spin,
            heartbeats.sendPort,
            const Duration(milliseconds: 500),
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(ticks, greaterThan(5));
        expect(beats, greaterThan(0));

        // Heartbeats sent just before the kill may still be on their way.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final afterKill = beats;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(beats, afterKill);
      },
    );
  });

  group('EditorSession.openInBackground', () {
    test(
      'refuses a file it takes longer than the limit to prepare as too large, '
      'and this isolate runs meanwhile',
      () async {
        final session = _session()
          ..openTimeLimit = const Duration(milliseconds: 150);
        final long = OpenedFile(name: 'long.md', bytes: _longMarkdown());
        var ticks = 0;
        final ticker = Timer.periodic(
          const Duration(milliseconds: 5),
          (_) => ticks++,
        );
        addTearDown(ticker.cancel);

        await expectLater(
          session.openInBackground(long),
          _refusedAs(DocumentProblem.tooLarge),
        );
        ticker.cancel();
        expect(ticks, greaterThan(5));
        expect(session.isUntitled, isTrue);
        expect(session.controller.document.toPlainText(), '\n');

        // Without the short limit the same file opens.
        final prepared = await prepareInBackground(
          DocumentFormat.markdown,
          long.bytes,
          timeLimit: _noLimit,
        );
        expect(prepared, isA<PreparedPackage>());
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'files open as they do on the UI isolate',
      () async {
        final formats = <DocumentFormat>{};
        final notices = <DocumentNotice>{};
        for (final MapEntry(key: name, value: bytes) in _openable().entries) {
          final file = OpenedFile(name: name, bytes: bytes, path: '/t/$name');
          final here = _session()..open(file);
          final background = _session();
          await background.openInBackground(file);
          expect(_shown(background), _shown(here), reason: name);
          formats.add(detectFormat(name, bytes)!.format);
          notices.addAll(background.notices);
        }
        expect(formats, DocumentFormat.values.toSet());
        expect(
          notices,
          containsAll([
            DocumentNotice.contentNotImported,
            DocumentNotice.savesAsDocx,
          ]),
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'each format reads the same off the UI isolate',
      () async {
        for (final MapEntry(key: name, value: bytes) in _openable().entries) {
          final format = detectFormat(name, bytes)!.format;
          final hereTables = TableStore();
          final here = _codecs(hereTables).decoder(format).decode(bytes);
          final prepared = await prepareInBackground(
            format,
            bytes,
            timeLimit: _noLimit,
          );
          final backgroundTables = TableStore();
          final background = _codecs(
            backgroundTables,
          ).decoder(format).load(prepared);
          expect(
            _loaded(background, backgroundTables),
            _loaded(here, hereTables),
            reason: name,
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('refused files are refused for the same reason', () async {
      final problems = <DocumentProblem?>{};
      for (final MapEntry(key: name, value: bytes) in _refused().entries) {
        final file = OpenedFile(name: name, bytes: bytes);
        final here = await _problemOf(() => _session().open(file));
        final background = await _problemOf(
          () => _session().openInBackground(file),
        );
        expect(background, here, reason: name);
        problems.add(background);
      }
      expect(problems, DocumentProblem.values.toSet());
    });
  });

  group('EditorSession.restoreInBackground', () {
    test(
      'reopens the recovery copy as unsaved, as on the UI isolate',
      () async {
        final source = _session()
          ..open(OpenedFile(name: 'report.docx', bytes: _richDocx()));
        final snapshots = [
          source.snapshot(),
          // Copies saved by 1.2.0 hold the document in the format of its file.
          RecoverySnapshot(
            name: 'old.md',
            path: '/t/old.md',
            format: DocumentFormat.markdown,
            bytes: _bytes('# Old\n\nText\n'),
            savedAt: DateTime(2026, 10, 20),
          ),
        ];
        for (final snapshot in snapshots) {
          final here = _session()..restore(snapshot, keepPath: true);
          final background = _session();
          await background.restoreInBackground(snapshot, keepPath: true);
          expect(background.dirty, isTrue);
          expect(_shown(background), _shown(here), reason: snapshot.name);
        }
      },
    );

    test(
      'refuses a copy that takes too long to prepare',
      () async {
        final session = _session()
          ..openTimeLimit = const Duration(milliseconds: 150);
        await expectLater(
          session.restoreInBackground(
            RecoverySnapshot(
              name: 'long.md',
              format: DocumentFormat.markdown,
              bytes: _longMarkdown(),
              savedAt: DateTime(2026, 10, 30),
            ),
            keepPath: false,
          ),
          _refusedAs(DocumentProblem.tooLarge),
        );
        expect(session.dirty, isFalse);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
