import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voges_word/document/picture_crop.dart';
import 'package:voges_word/docx/image_formats.dart';

Uint8List _picture(int width, int height, {bool jpeg = false}) {
  final image = img.Image(width: width, height: height);
  for (var x = 0; x < width; x++) {
    for (var y = 0; y < height; y++) {
      image.setPixelRgb(
        x,
        y,
        x < width / 2 ? 255 : 0,
        0,
        x < width / 2 ? 0 : 255,
      );
    }
  }
  return jpeg ? img.encodeJpg(image) : img.encodePng(image);
}

void main() {
  test('cuts the given fractions off each side', () {
    final cropped = cropPicture(
      _picture(40, 20),
      'image/png',
      left: 0.5,
      top: 0.25,
      bottom: 0.25,
    )!;
    expect(cropped.mime, 'image/png');
    expect(imagePixelSize(cropped.bytes), (width: 20, height: 10));
    final pixel = img.decodePng(cropped.bytes)!.getPixel(0, 0);
    expect((pixel.r, pixel.b), (0, 255));
  });

  test('JPEG stays JPEG', () {
    final cropped = cropPicture(
      _picture(64, 32, jpeg: true),
      'image/jpeg',
      right: 0.5,
    )!;
    expect(cropped.mime, 'image/jpeg');
    expect(imagePixelSize(cropped.bytes), (width: 32, height: 32));
  });

  test('pictures that cannot be cropped are left whole', () {
    final png = _picture(10, 10);
    expect(cropPicture(png, 'image/png', left: 0.6, right: 0.4), isNull);
    expect(cropPicture(png, 'image/x-emf', left: 0.1), isNull);
    expect(cropPicture(Uint8List(30), 'image/png', left: 0.1), isNull);
    final huge = Uint8List.fromList(png)
      ..buffer.asByteData().setUint32(16, 100000)
      ..buffer.asByteData().setUint32(20, 100000);
    expect(cropPicture(huge, 'image/png', left: 0.1), isNull);
  });
}
