import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../docx/image_formats.dart';
import '../print/pdf_document.dart' show printDpi;
import 'paper_styles.dart' show pointsToPixels;
import 'zoom.dart';

/// Pictures larger than this are never decoded, however small the file: the
/// same limit the HTML reader puts on each picture.
const maxPicturePixels = 100000000;

/// Longest side a picture is decoded to, however large it is drawn.
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

/// Bytes kept of the pictures decoded last; the newest is always kept.
const _recentBytesLimit = 32 << 20;

final _recent = <String, ({Uint8List bytes, String mime})>{};
var _recentBytes = 0;

/// The picture in a data URI. The last ones decoded are kept, since a page
/// reads a picture's header and draws it right after.
({Uint8List bytes, String mime})? readPictureUri(String uri) {
  if (_recent.remove(uri) case final picture?) return _recent[uri] = picture;
  final picture = decodeDataUri(uri);
  if (picture == null) return null;
  _recent[uri] = picture;
  _recentBytes += picture.bytes.length;
  while (_recentBytes > _recentBytesLimit && _recent.length > 1) {
    _recentBytes -= _recent.remove(_recent.keys.first)!.bytes.length;
  }
  return picture;
}

/// The picture in data URI [uri], drawn through [openPicture] at
/// [drawnSize]. The same picture at the same size gives the same key, from
/// any widget or copy of the document, so rebuilding the page, precaching
/// and the PDF's pages find it in the cache; at another size it is decoded
/// again.
@immutable
class PictureImage extends ImageProvider<PictureImage> {
  const PictureImage(this.uri, this.drawnSize);

  final String uri;

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
    codec: _open(key, decode),
    scale: 1,
    debugLabel: '$key',
  );

  static Future<ui.Codec> _open(
    PictureImage key,
    ImageDecoderCallback decode,
  ) async {
    final picture = readPictureUri(key.uri);
    if (picture == null) throw const FormatException('Not a picture data URI');
    return openPicture(picture.bytes, drawnSize: key.drawnSize, decode: decode);
  }

  @override
  bool operator ==(Object other) =>
      other is PictureImage && other.drawnSize == drawnSize && other.uri == uri;

  @override
  int get hashCode => Object.hash(uri, drawnSize);

  @override
  String toString() =>
      'PictureImage(${shortHash(uri)}, '
      '${drawnSize.width}x${drawnSize.height})';
}
