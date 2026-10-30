import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter/material.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/image_formats.dart';
import 'package:voges_word/document/document_look.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/headers_footers.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/editor/embeds/embed_builders.dart';
import 'package:voges_word/editor/header_footer_painter.dart';
import 'package:voges_word/editor/picture_decoding.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/l10n/l10n.dart';
import 'package:voges_word/print/page_renderer.dart';

final _onePixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// Reads only the size of each picture handed to the decoder and decodes a
/// single pixel instead, so no test allocates a large picture, even against
/// code that would decode it whole.
class _DecoderSpy extends AutomatedTestWidgetsFlutterBinding {
  var requests = 0;
  final log = <String>[];

  @override
  Future<ui.Codec> instantiateImageCodecWithSize(
    ui.ImmutableBuffer buffer, {
    ui.TargetImageSizeCallback? getTargetSize,
  }) async {
    requests++;
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final (width, height) = (descriptor.width, descriptor.height);
    descriptor.dispose();
    buffer.dispose();
    final ui.TargetImageSize? target;
    try {
      target = getTargetSize?.call(width, height);
    } on PictureTooLargeException {
      log.add('${width}x$height refused');
      rethrow;
    }
    log.add(
      '${width}x$height -> '
      '${target?.width ?? width}x${target?.height ?? height}',
    );
    return ui.instantiateImageCodec(_onePixel);
  }
}

/// A PNG whose header says [width] by [height] pixels; its data is 8x8.
Uint8List _png(int width, int height) {
  final bytes = img.encodePng(img.Image(width: 8, height: 8));
  ByteData.sublistView(bytes)
    ..setUint32(16, width)
    ..setUint32(20, height)
    ..setUint32(29, getCrc32(bytes.sublist(12, 29)));
  return bytes;
}

/// A GIF whose header says [screen] pixels square and whose frame says
/// [frame]; the engine takes the larger.
Uint8List _gif({required int screen, int frame = 8}) {
  final bytes = img.encodeGif(img.Image(width: 8, height: 8));
  final flags = bytes[10];
  var offset = 13 + ((flags & 0x80) == 0 ? 0 : 3 << ((flags & 7) + 1));
  while (bytes[offset] == 0x21) {
    offset += 2;
    while (bytes[offset] != 0) {
      offset += bytes[offset] + 1;
    }
    offset++;
  }
  expect(bytes[offset], 0x2C);
  ByteData.sublistView(bytes)
    ..setUint16(6, screen, Endian.little)
    ..setUint16(8, screen, Endian.little)
    ..setUint16(offset + 5, frame, Endian.little)
    ..setUint16(offset + 7, frame, Endian.little);
  return bytes;
}

Uint8List _bmp(int width, int height) {
  final bytes = img.encodeBmp(img.Image(width: 8, height: 8));
  ByteData.sublistView(bytes)
    ..setInt32(18, width, Endian.little)
    ..setInt32(22, height, Endian.little);
  return bytes;
}

Uint8List _jpeg(int width, int height) {
  final bytes = img.encodeJpg(img.Image(width: 8, height: 8));
  final data = ByteData.sublistView(bytes);
  var offset = 2;
  while (bytes[offset + 1] != 0xC0) {
    offset += 2 + data.getUint16(offset + 2);
  }
  data
    ..setUint16(offset + 5, height)
    ..setUint16(offset + 7, width);
  return bytes;
}

/// An icon holding [png]: only the engine reads its size.
Uint8List _icon(Uint8List png) {
  final directory = ByteData(22)
    ..setUint16(2, 1, Endian.little)
    ..setUint16(4, 1, Endian.little)
    ..setUint16(10, 1, Endian.little)
    ..setUint16(12, 32, Endian.little)
    ..setUint32(14, png.length, Endian.little)
    ..setUint32(18, 22, Endian.little);
  return Uint8List.fromList([...directory.buffer.asUint8List(), ...png]);
}

Future<BuildContext> _show(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(child: SizedBox(width: 400, child: child)),
      ),
    ),
  );
  return tester.element(find.byType(Scaffold));
}

/// Precaches like the PDF does, then shows the picture on a page.
Future<void> _precacheAndShow(WidgetTester tester, String source) async {
  final context = await _show(tester, const SizedBox());
  await tester.runAsync(() => EmbeddedImage.precache(source, context));
  await _show(tester, EmbeddedImage(source: source, width: 300, height: 150));
}

void main() {
  final spy = _DecoderSpy();
  final tooLarge = lookupAppLocalizations(const Locale('en')).pictureTooLarge;

  setUp(() {
    spy
      ..requests = 0
      ..log.clear()
      ..imageCache.clear();
  });

  testWidgets(
    'pictures over 100 megapixels by their header show a placeholder and never reach the decoder',
    (tester) async {
      final pictures = {
        'png': _png(30000, 30000),
        'gif': _gif(screen: 30000),
        'bmp': _bmp(30000, 30000),
        'jpeg': _jpeg(30000, 30000),
      };
      for (final MapEntry(key: type, value: bytes) in pictures.entries) {
        expect(imagePixelSize(bytes), (width: 30000, height: 30000));
        await _precacheAndShow(tester, dataUriFromMime(bytes, 'image/$type'));

        expect(find.byType(Image), findsNothing, reason: type);
        expect(find.byTooltip(tooLarge), findsOneWidget, reason: type);
      }
      expect(spy.requests, 0);
    },
  );

  testWidgets(
    'the size the engine reads is checked before decoding: a GIF frame larger than its header, an icon',
    (tester) async {
      for (final source in [
        dataUriFromMime(_gif(screen: 8, frame: 30000), 'image/gif'),
        dataUriFromMime(_icon(_png(30000, 30000)), 'image/png'),
      ]) {
        await _precacheAndShow(tester, source);
        expect(find.byTooltip(tooLarge), findsOneWidget);
      }
      expect(spy.log, ['30000x30000 refused', '30000x30000 refused']);
    },
  );

  testWidgets(
    'large pictures are decoded at most 4096 px on the long side, once for printing and the page',
    (tester) async {
      await _precacheAndShow(
        tester,
        dataUriFromMime(_png(6000, 3000), 'image/png'),
      );
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);

      await _precacheAndShow(
        tester,
        dataUriFromMime(_png(800, 600), 'image/png'),
      );
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);

      expect(spy.log, ['6000x3000 -> 4096x2048', '800x600 -> 800x600']);
    },
  );

  test('header and footer pictures are decoded the same way', () async {
    final painter = HeaderFooterPainter(
      HeadersFooters(
        headers: {
          PageVariant.normal: HeaderFooterStory(
            delta: Delta()
              ..insert({
                EmbedTypes.image: dataUriFromMime(
                  _png(6000, 3000),
                  'image/png',
                ),
              })
              ..insert('\n'),
          ),
        },
      ),
      const DocumentLook(),
    );
    addTearDown(painter.dispose);
    await painter.ready;

    expect(spy.log, ['6000x3000 -> 4096x2048']);
  });

  testWidgets(
    'the PDF draws placeholders and protected content, which have no overlay for tooltips there',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final metafile = Uint8List(64);
      ByteData.sublistView(metafile)
        ..setUint32(0, 1, Endian.little)
        ..setUint32(40, 0x464D4520, Endian.little);
      final tables = TableStore();
      final docx = DocxCodec(tables);
      final loaded = docx.read(
        DocxBuilder(
          DocumentSpec()
            ..body.add(
              ParagraphSpec([
                ImageSpec(
                  _png(30000, 30000),
                  'image/png',
                  width: 80,
                  height: 80,
                ),
                ImageSpec(metafile, 'image/x-emf', width: 80, height: 80),
                const FieldSpec('DATE', result: '30/10/2026'),
                const FieldSpec('PAGE', result: '1'),
              ]),
            ),
        ).build(),
      );
      final session = EditorSession(
        docx: docx,
        plainText: PlainTextCodec(look: loaded.look, tables: tables),
        files: DocumentFiles(),
        tables: tables,
      );
      session.open(
        OpenedFile(
          name: 'pictures.docx',
          bytes: docx.encode(loaded.delta, source: loaded.source),
        ),
      );

      final context = await _show(tester, const SizedBox());
      final pdf = await tester.runAsync(() => documentPdf(context, session));

      expect(pdf, isNotNull);
      expect(tester.takeException(), isNull);
      expect(spy.requests, 0);
    },
  );

  test(
    'pictures over the limit are refused before reaching the decoder',
    () async {
      for (final bytes in [
        _png(30000, 30000),
        _gif(screen: 30000),
        _bmp(30000, 30000),
        _jpeg(30000, 30000),
        _png(0xFFFFFFFF, 0xFFFFFFFF),
      ]) {
        await expectLater(
          openPicture(bytes),
          throwsA(isA<PictureTooLargeException>()),
        );
      }
      expect(spy.requests, 0);
    },
  );

  test(
    'the engine shrinks still pictures but not animations, so large animations are refused',
    () async {
      Uint8List gif(int width, {int frames = 1}) {
        final picture = img.Image(width: width, height: 2);
        for (var frame = 1; frame < frames; frame++) {
          picture.addFrame(img.Image(width: width, height: 2));
        }
        return img.encodeGif(picture);
      }

      final still = await openPicture(
        gif(5000),
        decode: ui.instantiateImageCodecWithSize,
      );
      final frame = await still.getNextFrame();
      expect((frame.image.width, frame.image.height), (4096, 2));
      frame.image.dispose();
      still.dispose();

      final small = await openPicture(
        gif(300, frames: 2),
        decode: ui.instantiateImageCodecWithSize,
      );
      expect(small.frameCount, 2);
      small.dispose();

      await expectLater(
        openPicture(
          gif(5000, frames: 2),
          decode: ui.instantiateImageCodecWithSize,
        ),
        throwsA(isA<PictureTooLargeException>()),
      );
    },
  );
}
