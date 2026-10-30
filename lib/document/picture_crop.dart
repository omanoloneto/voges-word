import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../docx/image_formats.dart';

/// Larger pictures are shown whole: decoding them takes too long and too
/// much memory.
const _maxPixels = 40000000;

/// What is left of a picture after cutting off [left], [top], [right] and
/// [bottom], each a fraction of its width or height, the way Word and
/// LibreOffice crop. Null when the picture can't be cropped (metafiles,
/// other types, very large pictures) or nothing would be left; it is then
/// shown whole.
({Uint8List bytes, String mime})? cropPicture(
  Uint8List bytes,
  String mime, {
  double left = 0,
  double top = 0,
  double right = 0,
  double bottom = 0,
}) {
  double fraction(double value) =>
      value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0;
  final (cutLeft, cutTop, cutRight, cutBottom) = (
    fraction(left),
    fraction(top),
    fraction(right),
    fraction(bottom),
  );
  if (cutLeft + cutRight >= 1 || cutTop + cutBottom >= 1) return null;
  final size = imagePixelSize(bytes);
  if (size == null ||
      size.width <= 0 ||
      size.height <= 0 ||
      size.width.toDouble() * size.height > _maxPixels) {
    return null;
  }
  try {
    final image = switch (mime) {
      'image/png' => img.decodePng(bytes, frame: 0),
      'image/jpeg' => img.decodeJpg(bytes, maxPixels: _maxPixels),
      'image/gif' => img.decodeGif(bytes, frame: 0),
      'image/bmp' => img.decodeBmp(bytes),
      _ => null,
    };
    if (image == null) return null;
    final width = (image.width * (1 - cutLeft - cutRight)).round();
    final height = (image.height * (1 - cutTop - cutBottom)).round();
    if (width < 1 || height < 1) return null;
    final cropped = img.copyCrop(
      image,
      x: (image.width * cutLeft).round(),
      y: (image.height * cutTop).round(),
      width: width,
      height: height,
    );
    return mime == 'image/jpeg'
        ? (bytes: img.encodeJpg(cropped, quality: 92), mime: mime)
        : (bytes: img.encodePng(cropped), mime: 'image/png');
  } catch (_) {
    // Decoders of pictures from untrusted files may throw anything.
    return null;
  }
}
