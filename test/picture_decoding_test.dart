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

/// Precaches like the PDF does, then shows the pictures on a page.
Future<BuildContext> _precacheAndShow(
  WidgetTester tester,
  List<EmbeddedImage> pictures,
) async {
  final context = await _show(tester, const SizedBox());
  for (final picture in pictures) {
    await tester.runAsync(() => picture.precache(context));
  }
  return _show(tester, Column(children: pictures));
}

EmbeddedImage _picture(String source) =>
    EmbeddedImage(source: source, width: 300, height: 150);

/// A screen with [ratio] device pixels to each logical pixel.
void _screen(WidgetTester tester, double ratio) {
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.resetDevicePixelRatio);
}

Iterable<ui.Image?> _drawn(WidgetTester tester) =>
    tester.widgetList<RawImage>(find.byType(RawImage)).map((raw) => raw.image);

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
        await _precacheAndShow(tester, [
          _picture(dataUriFromMime(bytes, 'image/$type')),
        ]);

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
        await _precacheAndShow(tester, [_picture(source)]);
        expect(find.byTooltip(tooLarge), findsOneWidget);
      }
      expect(spy.log, ['30000x30000 refused', '30000x30000 refused']);
    },
  );

  test('pictures are decoded for the largest zoom and for printing', () {
    // 300 by 150 points at 200%, on a screen of ratio 2.
    expect(drawnPictureSize(300, 150, 2), (width: 1600, height: 800));
    // On a screen of ratio 1, printing at 200 dpi needs more than 200%.
    expect(drawnPictureSize(300, 150, 1), (width: 833, height: 417));
    expect(drawnPictureSize(5000, 0.01, 2), (width: 4096, height: 1));
    expect(drawnPictureSize(double.infinity, double.nan, 2), (
      width: 4096,
      height: 1,
    ));
  });

  testWidgets(
    'pictures are decoded at the size they are drawn, never above their own, once for printing and the page',
    (tester) async {
      _screen(tester, 2);
      await _precacheAndShow(tester, [
        _picture(dataUriFromMime(_png(6000, 3000), 'image/png')),
      ]);
      expect(_drawn(tester), [isNotNull]);

      await _precacheAndShow(tester, [
        _picture(dataUriFromMime(_png(800, 600), 'image/png')),
      ]);
      expect(_drawn(tester), [isNotNull]);

      expect(spy.log, ['6000x3000 -> 1600x800', '800x600 -> 800x600']);
    },
  );

  testWidgets(
    'on a screen of ratio 1 pictures are decoded for printing at 200 dpi',
    (tester) async {
      _screen(tester, 1);
      await _precacheAndShow(tester, [
        _picture(dataUriFromMime(_png(6000, 3000), 'image/png')),
      ]);
      expect(_drawn(tester), [isNotNull]);

      expect(spy.log, ['6000x3000 -> 834x417']);
    },
  );

  testWidgets(
    'pictures drawn larger than 4096 px are decoded at most 4096 px on the long side',
    (tester) async {
      _screen(tester, 2);
      await _precacheAndShow(tester, [
        EmbeddedImage(
          source: dataUriFromMime(_png(6000, 3000), 'image/png'),
          width: 1000,
          height: 500,
        ),
      ]);
      expect(_drawn(tester), [isNotNull]);

      expect(spy.log, ['6000x3000 -> 4096x2048']);
    },
  );

  testWidgets('a picture drawn at two sizes is decoded once for each', (
    tester,
  ) async {
    _screen(tester, 2);
    final source = dataUriFromMime(_png(6000, 3000), 'image/png');
    await _precacheAndShow(tester, [
      EmbeddedImage(source: source, width: 300, height: 150),
      EmbeddedImage(source: source, width: 150, height: 75),
    ]);
    expect(_drawn(tester), [isNotNull, isNotNull]);

    expect(spy.log, ['6000x3000 -> 1600x800', '6000x3000 -> 800x400']);
  });

  test(
    'header and footer pictures are decoded once, at the largest size they are drawn',
    () async {
      final view = spy.platformDispatcher.implicitView!;
      view.devicePixelRatio = 2;
      addTearDown(view.resetDevicePixelRatio);
      final logo = dataUriFromMime(_png(6000, 3000), 'image/png');
      HeaderFooterStory story(String source, [Map<String, dynamic>? size]) =>
          HeaderFooterStory(
            delta: Delta()
              ..insert({EmbedTypes.image: source}, size)
              ..insert('\n'),
          );
      final painter = HeaderFooterPainter(
        HeadersFooters(
          headers: {
            PageVariant.normal: story(logo, {'width': '150', 'height': '75'}),
            // Without a size it isn't drawn, so it isn't decoded.
            PageVariant.first: story(
              dataUriFromMime(_png(5000, 5000), 'image/png'),
            ),
          },
          footers: {
            PageVariant.normal: story(logo, {'width': '300', 'height': '150'}),
          },
        ),
        const DocumentLook(),
      );
      addTearDown(painter.dispose);
      await painter.ready;

      expect(spy.log, ['6000x3000 -> 1600x800']);
    },
  );

  testWidgets('the PDF draws the pictures the editor already decoded', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final tables = TableStore();
    final docx = DocxCodec(tables);
    final loaded = docx.read(
      DocxBuilder(
        DocumentSpec()
          ..body.add(
            ParagraphSpec([
              ImageSpec(_png(6000, 3000), 'image/png', width: 300, height: 150),
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
        name: 'picture.docx',
        bytes: docx.encode(loaded.delta, source: loaded.source),
      ),
    );
    final op = session.controller.document.toDelta().toList().firstWhere(
      (op) => op.data is Map,
    );
    final picture = EmbeddedImage.fromAttributes(
      (op.data! as Map)[EmbedTypes.image] as String,
      op.attributes,
    );

    final page = await _precacheAndShow(tester, [picture]);
    expect(_drawn(tester), [isNotNull]);
    final pdf = await tester.runAsync(() => documentPdf(page, session));

    expect(pdf, isNotNull);
    expect(spy.requests, 1);
    expect(imageCache.currentSize + imageCache.pendingImageCount, 1);
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
          openPicture(bytes, drawnSize: (width: 100, height: 100)),
          throwsA(isA<PictureTooLargeException>()),
        );
      }
      expect(spy.requests, 0);
    },
  );

  test(
    'the engine shrinks still pictures to the size drawn but not animations, so large animations are refused',
    () async {
      Uint8List gif(int width, int height, {int frames = 1}) {
        final picture = img.Image(width: width, height: height);
        for (var frame = 1; frame < frames; frame++) {
          picture.addFrame(img.Image(width: width, height: height));
        }
        return img.encodeGif(picture);
      }

      Future<(int, int, int)> open(
        Uint8List bytes,
        ({int width, int height}) drawnSize,
      ) async {
        final codec = await openPicture(
          bytes,
          drawnSize: drawnSize,
          decode: ui.instantiateImageCodecWithSize,
        );
        final frame = await codec.getNextFrame();
        final opened = (
          codec.frameCount,
          frame.image.width,
          frame.image.height,
        );
        frame.image.dispose();
        codec.dispose();
        return opened;
      }

      expect(await open(gif(5000, 2), (width: 5000, height: 2)), (1, 4096, 2));
      expect(await open(gif(300, 200), (width: 150, height: 100)), (
        1,
        150,
        100,
      ));
      expect(await open(gif(300, 200, frames: 2), (width: 150, height: 100)), (
        2,
        300,
        200,
      ));
      await expectLater(
        open(gif(5000, 2, frames: 2), (width: 100, height: 1)),
        throwsA(isA<PictureTooLargeException>()),
      );
    },
  );
}
