import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../docx/image_formats.dart';

/// Pictures larger than this are never decoded, however small the file: the
/// same limit the HTML reader puts on each picture.
const maxPicturePixels = 100000000;

/// Longest side a picture is decoded to: more than the screen at the largest
/// zoom and printing at 200 dpi need.
const maxPictureSide = 4096;

class PictureTooLargeException implements Exception {
  const PictureTooLargeException(this.width, this.height);

  final int width;
  final int height;

  @override
  String toString() => 'PictureTooLargeException: ${width}x$height pixels';
}

bool exceedsPictureLimit(int width, int height) =>
    width.toDouble() * height > maxPicturePixels;

/// Opens a picture at most [maxPictureSide] pixels on its longest side, or
/// throws [PictureTooLargeException] rather than decode one too large for
/// memory. The engine's own reading counts too: a GIF frame can be larger
/// than its header, and an animation can't be decoded smaller.
Future<ui.Codec> openPicture(
  Uint8List bytes, {
  ImageDecoderCallback? decode,
}) async {
  if (imagePixelSize(bytes) case final size?
      when exceedsPictureLimit(size.width, size.height)) {
    throw PictureTooLargeException(size.width, size.height);
  }
  ({int width, int height})? shrunk;
  final codec =
      await (decode ?? PaintingBinding.instance.instantiateImageCodecWithSize)(
        await ui.ImmutableBuffer.fromUint8List(bytes),
        getTargetSize: (width, height) {
          if (exceedsPictureLimit(width, height)) {
            throw PictureTooLargeException(width, height);
          }
          final longest = math.max(width, height);
          if (longest <= maxPictureSide) return const ui.TargetImageSize();
          shrunk = (width: width, height: height);
          final scale = maxPictureSide / longest;
          return ui.TargetImageSize(
            width: math.max(1, (width * scale).round()),
            height: math.max(1, (height * scale).round()),
          );
        },
      );
  if (shrunk case final size? when codec.frameCount > 1) {
    codec.dispose();
    throw PictureTooLargeException(size.width, size.height);
  }
  return codec;
}

/// A picture drawn through [openPicture]. The same bytes give the same key, so
/// a precached picture is found in the cache when the page draws it.
@immutable
class PictureImage extends ImageProvider<PictureImage> {
  const PictureImage(this.bytes);

  final Uint8List bytes;

  @override
  Future<PictureImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<PictureImage>(this);

  @override
  ImageStreamCompleter loadImage(
    PictureImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: openPicture(key.bytes, decode: decode),
    scale: 1,
    debugLabel: 'PictureImage(${describeIdentity(key.bytes)})',
  );

  @override
  bool operator ==(Object other) =>
      other is PictureImage && identical(other.bytes, bytes);

  @override
  int get hashCode => identityHashCode(bytes);

  @override
  String toString() => 'PictureImage(${describeIdentity(bytes)})';
}
