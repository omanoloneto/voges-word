import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voges_word/doc/doc_codec.dart';
import 'package:voges_word/doc/doc_context.dart';
import 'package:voges_word/doc/doc_file.dart';
import 'package:voges_word/doc/doc_pictures.dart';
import 'package:voges_word/doc/doc_sprms.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/image_formats.dart';

import 'doc_fixtures.dart';

/// A document with a bit of everything, to damage.
DocWriter _rich() {
  final doc = DocWriter()
    ..styles[1] = StyleFixture.paragraph(
      'heading 1',
      builtIn: 1,
      base: 0,
      character: [...bold, ...fontSize(16)],
    )
    ..line('Heading', style: 1);
  final list = doc.addList([
    (format: 23, text: '', start: 1, left: 720, hanging: 360, font: 1),
  ]);
  doc
    ..line('item', sprms: DocWriter.listParagraph(list))
    ..bookmarks.add(('mark', doc.position, doc.position))
    ..text('\x13', special)
    ..text(' HYPERLINK "https://example.com/" ')
    ..text('\x14', special)
    ..text('link')
    ..text('\x15', special)
    ..text('\x02', special)
    ..text('\x01', [
      ...special,
      ...sprm(Sprm.cPicLocation, u32(doc.addPicture(png))),
    ])
    ..paragraph()
    ..text('cell')
    ..paragraph(sprms: inTable(), mark: '\x07')
    ..paragraph(
      sprms: [
        ...inTable(),
        ...sprm(Sprm.pFTtp, [1]),
        ...rowDefinition([0, 3000]),
      ],
      mark: '\x07',
    )
    ..line('end');
  final noteReference = doc.position - 8;
  doc.mainLength = doc.position;
  doc
    ..text('\x02', special)
    ..text(' note')
    ..paragraph()
    ..footnotes.add((noteReference, 0, doc.position - doc.mainLength));
  doc.footnoteLength = doc.position - doc.mainLength;
  final headerStart = doc.position;
  doc
    ..line('header')
    ..paragraph();
  doc
    ..headerLength = doc.position - headerStart
    ..headerStories = [
      for (var index = 0; index < 7; index++) 0,
      for (var index = 0; index < 6; index++) doc.position - headerStart,
    ]
    ..sections.add((doc.mainLength, sprm(Sprm.sBkc, [2])));
  return doc;
}

String _plain(Delta delta) => delta
    .toList()
    .map((operation) => operation.data)
    .whereType<String>()
    .join();

DocumentProblem? _problem(Uint8List bytes) {
  try {
    DocCodec(DocxCodec(TableStore())).decode(bytes);
    return null;
  } on DocumentProblemException catch (error) {
    return error.problem;
  }
}

/// Opening damaged input either works or reports a problem, and never
/// takes long.
void _expectSafe(Uint8List bytes) {
  final watch = Stopwatch()..start();
  _problem(bytes);
  expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the rich document itself opens', () {
    final loaded = DocCodec(DocxCodec(TableStore())).decode(_rich().build());
    expect(_plain(loaded.delta), contains('Heading'));
    expect(loaded.headersFooters.headers, isNotEmpty);
  });

  test('truncated files', () {
    final bytes = _rich().build();
    final step = max(1, bytes.length ~/ 400);
    for (var length = 0; length < bytes.length; length += step) {
      _expectSafe(Uint8List.sublistView(bytes, 0, length));
    }
  });

  test('random damage to the container', () {
    final random = Random(1);
    final bytes = _rich().build();
    for (var round = 0; round < 300; round++) {
      final damaged = Uint8List.fromList(bytes);
      for (var count = random.nextInt(6) + 1; count > 0; count--) {
        // The structures live in the first sectors.
        final at = random.nextInt(min(damaged.length, 4096));
        damaged[at] = random.nextInt(256);
      }
      _expectSafe(damaged);
    }
  });

  test('random damage to the document and table streams', () {
    final random = Random(2);
    final writer = _rich();
    for (var round = 0; round < 400; round++) {
      final bytes = writer.build(
        mutate: (name, stream) {
          if (name == 'Data') return;
          // The FIB, text and formatting pages, or the whole table stream.
          final limit = name == 'WordDocument' ? 0x1000 : stream.length;
          for (var count = random.nextInt(4) + 1; count > 0; count--) {
            final at = random.nextInt(min(limit, stream.length));
            stream[at] = random.nextBool() ? 0xFF : random.nextInt(256);
          }
        },
      );
      _expectSafe(bytes);
    }
  });

  group('compound file', () {
    Uint8List rich() => _rich().build();
    void patch32(Uint8List bytes, int at, int value) =>
        ByteData.sublistView(bytes).setUint32(at, value, Endian.little);
    int read32(Uint8List bytes, int at) =>
        ByteData.sublistView(bytes).getUint32(at, Endian.little);
    // The writer puts one FAT sector first, then the directory.
    const fat = 512;
    const directory = 1024;

    test('a sector chain that loops', () {
      final bytes = rich();
      final start = read32(bytes, directory + 128 + 116);
      patch32(bytes, fat + start * 4, start);
      expect(_problem(bytes), DocumentProblem.damaged);
    });

    test('a directory that loops', () {
      final bytes = rich();
      patch32(bytes, directory + 128 + 72, 1);
      expect(_problem(bytes), DocumentProblem.damaged);
    });

    test('a stream larger than the file', () {
      final bytes = rich();
      patch32(bytes, directory + 128 + 120, 0x7FFFFFFF);
      expect(_problem(bytes), DocumentProblem.damaged);
    });

    test('sector counts beyond the file', () {
      for (final at in [44, 64, 72]) {
        final bytes = rich();
        patch32(bytes, at, 0x00FFFFFF);
        expect(_problem(bytes), DocumentProblem.damaged, reason: '$at');
      }
    });

    test('unknown versions and sector sizes', () {
      final bytes = rich();
      bytes[30] = 12;
      expect(_problem(bytes), DocumentProblem.damaged);
      final other = rich()..[26] = 5;
      expect(_problem(other), DocumentProblem.damaged);
    });

    test('sectors that macOS leaves out of the FAT follow one another', () {
      // The writer's directory is one sector after one FAT sector of 128
      // entries; move it past what the FAT describes.
      final bytes = rich();
      final relocated = BytesBuilder()
        ..add(bytes)
        ..add(Uint8List((129 - bytes.length ~/ 512) * 512))
        ..add(bytes.sublist(directory, directory + 512));
      final moved = relocated.toBytes();
      patch32(moved, 48, 128);
      expect(_problem(moved), isNull);
      final loaded = DocCodec(DocxCodec(TableStore())).decode(moved);
      expect(_plain(loaded.delta), contains('Heading'));
    });

    test('just the signature', () {
      expect(
        _problem(Uint8List.fromList(rich().sublist(0, 8))),
        DocumentProblem.damaged,
      );
    });
  });

  group('Word structures', () {
    test('a FIB larger than its stream', () {
      final bytes = _rich().build(
        mutate: (name, stream) {
          // cbRgFcLcb, after the 32-bit counts.
          if (name == 'WordDocument') stream[152] = 0xFF;
          if (name == 'WordDocument') stream[153] = 0xFF;
        },
      );
      expect(_problem(bytes), DocumentProblem.damaged);
    });

    test('negative text lengths', () {
      final bytes = _rich().build(
        mutate: (name, stream) {
          if (name == 'WordDocument') stream.setRange(76, 80, u32(0xFFFFFFFF));
        },
      );
      expect(_problem(bytes), DocumentProblem.damaged);
    });

    test('a piece table past the limit is too large', () {
      final writer = DocWriter()..line('x');
      final bytes = writer.build(
        mutate: (name, stream) {
          if (name != '1Table') return;
          // The Clx is the table stream's last part before the DOP: find its
          // marker and claim 2^26 characters in an empty piece.
          for (var at = 0; at + 21 <= stream.length; at++) {
            if (stream[at] == 0x02 &&
                stream[at + 1] == 16 &&
                stream[at + 2] == 0 &&
                stream[at + 5] == 0) {
              stream.setRange(at + 9, at + 13, u32(1 << 26));
              return;
            }
          }
        },
      );
      expect(_problem(bytes), DocumentProblem.tooLarge);
    });

    test('pieces that read the same bytes over and over are damaged', () {
      final repeated = DocWriter()
        ..compressed = true
        ..pieceCopies = 20
        ..line('x' * 2000);
      expect(_problem(repeated.build()), DocumentProblem.damaged);
      // Pieces may share a little, as long as they hold no more than the
      // stream does.
      final shared = DocWriter()
        ..compressed = true
        ..pieceCopies = 2
        ..line('x' * 20);
      expect(_problem(shared.build()), isNull);
    });

    test('fields nested past any limit', () {
      final doc = DocWriter()..text('\x13' * 5000, special);
      doc
        ..text(' PAGE ')
        ..text('\x14', special)
        ..text('text')
        ..paragraph();
      final loaded = DocCodec(DocxCodec(TableStore())).decode(doc.build());
      expect(_plain(loaded.delta), isNotEmpty);
    });

    test('tables nested past any limit', () {
      final doc = DocWriter();
      for (final depth in [1, 5000, 1 << 30]) {
        doc
          ..text('deep $depth')
          ..paragraph(
            sprms: [
              ...inTable(depth),
              ...sprm(Sprm.pFInnerTableCell, [1]),
            ],
          );
      }
      doc
        ..paragraph(
          sprms: [
            ...inTable(1 << 30),
            ...sprm(Sprm.pFInnerTtp, [1]),
            ...rowDefinition([0, 100]),
          ],
        )
        ..line('after');
      final tables = TableStore();
      final loaded = DocCodec(DocxCodec(tables)).decode(doc.build());
      expect(_plain(loaded.delta), contains('after'));
      expect(tables.all.length, lessThanOrEqualTo(17));
    });

    test('styles based on each other in a loop', () {
      final doc = DocWriter()
        ..styles[1] = StyleFixture.paragraph('loop a', base: 2, character: bold)
        ..styles[2] = StyleFixture.paragraph(
          'loop b',
          base: 1,
          character: italic,
        )
        ..line('looped', style: 1);
      final loaded = DocCodec(DocxCodec(TableStore())).decode(doc.build());
      expect(_plain(loaded.delta), 'looped\n');
    });

    test('sprms with sizes past their grpprl', () {
      final doc = DocWriter()
        ..text('text', [...bold, ...u16(Sprm.cShd), 200, 1, 2])
        ..paragraph(
          sprms: [
            ...sprm(Sprm.pJc80, [1]),
            ...u16(Sprm.tDefTable),
            ...u16(0xFFFF),
            63,
          ],
        );
      final loaded = DocCodec(DocxCodec(TableStore())).decode(doc.build());
      expect(_plain(loaded.delta), 'text\n');
    });

    test('table rows that define too many or too few cells', () {
      final definition = rowDefinition([
        for (var edge = 0; edge < 64; edge++) edge * 100,
      ]);
      final huge = [...u16(definition.length), ...definition];
      final doc = DocWriter();
      doc
        ..text('a')
        ..paragraph(sprms: inTable(), mark: '\x07')
        ..text('b')
        ..paragraph(sprms: inTable(), mark: '\x07')
        ..text('c')
        ..paragraph(sprms: inTable(), mark: '\x07')
        ..paragraph(
          sprms: [
            ...inTable(),
            ...sprm(Sprm.pFTtp, [1]),
            ...rowDefinition([500, 400]),
          ],
          mark: '\x07',
        )
        ..text('d')
        ..paragraph(sprms: inTable(), mark: '\x07')
        // Too large for its page: in the Data stream (sprmPHugePapx).
        ..paragraph(
          sprms: [
            ...inTable(),
            ...sprm(Sprm.pFTtp, [1]),
            ...sprm(Sprm.pHugePapx, u32(doc.addData(huge))),
          ],
          mark: '\x07',
        )
        ..line('after');
      final tables = TableStore();
      final loaded = DocCodec(DocxCodec(tables)).decode(doc.build());
      expect(_plain(loaded.delta), contains('after'));
      final table = tables.all.single;
      expect(table.rows.first.cells, hasLength(3));
      expect(table.rows.last.cells, hasLength(1));
      expect(table.columnWidths.first, 100);
    });

    test('list levels with sizes past the table stream', () {
      final doc = DocWriter();
      final list = doc.addList([
        (format: 0, text: '%1.', start: 1, left: 720, hanging: 360, font: null),
      ]);
      doc.line('item', sprms: DocWriter.listParagraph(list));
      final bytes = doc.build(
        mutate: (name, stream) {
          if (name != '1Table') return;
          // The first level's text size, after its 28-byte LVLF and grpprls.
          for (var at = 0; at + 4 <= stream.length; at++) {
            if (stream[at] == 0x5E &&
                stream[at + 1] == 0x84 &&
                stream[at + 2] == 0xD0 &&
                stream[at + 3] == 0x02) {
              stream.setRange(at + 8, at + 10, u16(0xFFFF));
              return;
            }
          }
        },
      );
      final loaded = DocCodec(DocxCodec(TableStore())).decode(bytes);
      expect(_plain(loaded.delta), 'item\n');
      expect(loaded.notices, contains(DocumentNotice.contentNotImported));
    });

    test('a compressed picture that inflates past its size is left out', () {
      // 4 MB of zeros declared as 1 KB.
      final inflated = Uint8List(4 * 1024 * 1024);
      final zlib = ZLibCodec(level: 9).encode(inflated);
      final metafile = [
        ...u32(1024),
        ...u32(0),
        ...u32(0),
        ...u32(100),
        ...u32(100),
        ...u32(12700),
        ...u32(12700),
        ...u32(zlib.length),
        0,
        0xFE,
        ...zlib,
      ];
      final doc = DocWriter();
      final offset = doc.addPicture(
        metafile,
        blipType: 0xF01B,
        instance: 0x216,
      );
      doc
        ..text('\x01', [...special, ...sprm(Sprm.cPicLocation, u32(offset))])
        ..paragraph();
      final watch = Stopwatch()..start();
      final loaded = DocCodec(DocxCodec(TableStore())).decode(doc.build());
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(
        loaded.delta.toList().where(
          (operation) =>
              operation.data is Map &&
              (operation.data as Map).containsKey(EmbedTypes.image),
        ),
        isEmpty,
      );
      expect(loaded.notices, contains(DocumentNotice.contentNotImported));
    });

    test('compressed pictures inflate no more than the document allows', () {
      // Each says it holds 4 MB and inflates past that, so each attempt
      // fails at its limit; a thousand of them would inflate 4 GB.
      const declared = 4 * 1024 * 1024;
      final zlib = ZLibCodec(level: 9).encode(Uint8List(declared + 1));
      final metafile = [
        ...u32(declared),
        ...u32(0),
        ...u32(0),
        ...u32(100),
        ...u32(100),
        ...u32(12700),
        ...u32(12700),
        ...u32(zlib.length),
        0,
        0xFE,
        ...zlib,
      ];
      final doc = DocWriter();
      for (var index = 0; index < 1000; index++) {
        final offset = doc.addPicture(
          metafile,
          blipType: 0xF01B,
          instance: 0x216,
        );
        doc.text('\x01', [...special, ...sprm(Sprm.cPicLocation, u32(offset))]);
      }
      doc.paragraph();
      final bytes = doc.build();
      final watch = Stopwatch()..start();
      final loaded = DocCodec(DocxCodec(TableStore())).decode(bytes);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      expect(loaded.notices, contains(DocumentNotice.contentNotImported));
    });

    test('cropping stops past its budget and shows pictures whole', () {
      final picture = (
        bytes: img.encodePng(img.Image(width: 4, height: 2)),
        mime: 'image/png',
      );
      const crop = (left: 0.5, top: 0.0, right: 0.0, bottom: 0.0);
      final budget = PictureBudget()..cropped = 10;
      DocPicture cut() =>
          croppedPicture(picture, crop, width: 30, height: 30, budget: budget);
      final first = cut();
      final second = cut();

      expect(imagePixelSize(first.bytes), (width: 2, height: 2));
      expect((first.width, first.height), (30.0, 30.0));
      expect(imagePixelSize(second.bytes), (width: 4, height: 2));
      expect((second.width, second.height), (60.0, 30.0));
    });

    test('documents with more elements than any real one are too large', () {
      final file = DocFile.open((DocWriter()..line('x')).build());
      final context = DocContext(file, DocumentSpec());
      for (var count = 0; count < DocContext.maxElements; count++) {
        context.addElement();
      }
      expect(
        context.addElement,
        throwsA(
          isA<DocumentProblemException>().having(
            (error) => error.problem,
            'problem',
            DocumentProblem.tooLarge,
          ),
        ),
      );
    });

    test('drawings nested past any limit', () {
      var nested = officeArtRecord(0x0F, 0, 0xF004, []);
      for (var depth = 0; depth < 3000; depth++) {
        nested = officeArtRecord(0x0F, 0, 0xF003, nested);
      }
      final doc = DocWriter()
        ..text('\x08', special)
        ..paragraph()
        ..floatingAnchors.add((0, 1, 100, 100))
        ..drawings = [
          ...officeArtRecord(0x0F, 0, 0xF000, []),
          0,
          ...officeArtRecord(0x0F, 0, 0xF002, nested),
        ];
      final loaded = DocCodec(DocxCodec(TableStore())).decode(doc.build());
      expect(loaded.notices, contains(DocumentNotice.contentNotImported));
    });
  });
}
