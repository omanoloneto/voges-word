import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../docx/image_formats.dart';
import '../print/pdf_document.dart' show printDpi;
import 'paper_styles.dart' show pointsToPixels;

/// Pictures larger than this are never decoded, however small the file: the
/// same limit the HTML reader puts on each picture.
const maxPicturePixels = 100000000;

/// Longest side a picture is decoded to, however large it is drawn.
const maxPictureSide = 4096;

/// The editor's largest zoom. Pictures are decoded for it, so zooming in
/// never decodes them again.
const largestZoom = 2.0;

class PictureTooLargeException implements Exception {
  const PictureTooLargeException(this.width, this.height);

  final int width;
  final int height;

  @override
  String toString() => 'PictureTooLargeException: ${width}x$height pixels';
}

bool exceedsPictureLimit(int width, int height) =>
    width.toDouble() * height > maxPicturePixels;

/// Device pixels a picture drawn [width] by [height] points takes: on a
/// screen with [devicePixelRatio] at the [largestZoom], or in the PDF and
/// printing, whichever needs more.
({int width, int height}) drawnPictureSize(
  double width,
  double height,
  double devicePixelRatio,
) {
  final scale = math.max(
    devicePixelRatio * pointsToPixels * largestZoom,
    printDpi / 72,
  );
  int pixels(double points) {
    final value = points * scale;
    if (value >= maxPictureSide) return maxPictureSide;
    return value >= 1 ? value.round() : 1;
  }

  return (width: pixels(width), height: pixels(height));
}

/// Opens a picture at the [drawnSize] it is drawn at, keeping its
/// proportions, but never larger than its own pixels or [maxPictureSide] on
/// its longest side. Throws [PictureTooLargeException] rather than decode
/// one too large for memory. The engine's own reading counts too: a GIF
/// frame can be larger than its header, and an animation can't be decoded
/// smaller.
Future<ui.Codec> openPicture(
  Uint8List bytes, {
  required ({int width, int height}) drawnSize,
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
          if (longest > maxPictureSide) shrunk = (width: width, height: height);
          var scale = math.min(1.0, maxPictureSide / longest);
          if (width > 0 && height > 0) {
            scale = math.min(
              scale,
              math.max(drawnSize.width / width, drawnSize.height / height),
            );
          }
          if (scale >= 1) return const ui.TargetImageSize();
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

/// A picture drawn through [openPicture] at [drawnSize]. The same bytes at
/// the same size give the same key, so a precached picture is found in the
/// cache when the page draws it; at another size it is decoded again.
@immutable
class PictureImage extends ImageProvider<PictureImage> {
  const PictureImage(this.bytes, this.drawnSize);

  final Uint8List bytes;

  /// Device pixels, from [drawnPictureSize].
  final ({int width, int height}) drawnSize;

  @override
  Future<PictureImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<PictureImage>(this);

  @override
  ImageStreamCompleter loadImage(
    PictureImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: openPicture(key.bytes, drawnSize: key.drawnSize, decode: decode),
    scale: 1,
    debugLabel: '$key',
  );

  @override
  bool operator ==(Object other) =>
      other is PictureImage &&
      identical(other.bytes, bytes) &&
      other.drawnSize == drawnSize;

  @override
  int get hashCode => Object.hash(identityHashCode(bytes), drawnSize);

  @override
  String toString() =>
      'PictureImage(${describeIdentity(bytes)}, '
      '${drawnSize.width}x${drawnSize.height})';
}
