import 'dart:math' as math;
import 'dart:typed_data';

// RTF keeps Windows pictures as they are in memory: metafiles without the
// placeable header and bitmaps without the file header that files on disk
// (and packages) have.

const _little = Endian.little;

bool isPng(Uint8List bytes) =>
    bytes.length > 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

bool isJpeg(Uint8List bytes) =>
    bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;

/// Some writers put GIF data in a `\pngblip`.
bool isGif(Uint8List bytes) =>
    bytes.length > 10 &&
    bytes[0] == 0x47 &&
    bytes[1] == 0x49 &&
    bytes[2] == 0x46 &&
    bytes[3] == 0x38;

bool isEmf(Uint8List bytes) =>
    bytes.length > 44 &&
    ByteData.sublistView(bytes).getUint32(0, _little) == 1 &&
    ByteData.sublistView(bytes).getUint32(40, _little) == 0x464D4520;

bool _isPlaceableWmf(Uint8List bytes) =>
    bytes.length > 40 &&
    ByteData.sublistView(bytes).getUint32(0, _little) == 0x9AC6CDD7;

bool _isMetafile(Uint8List bytes) {
  if (bytes.length < 18) return false;
  final data = ByteData.sublistView(bytes);
  final type = data.getUint16(0, _little);
  return (type == 1 || type == 2) && data.getUint16(2, _little) == 9;
}

/// A .wmf file from the metafile in `\wmetafile`; [width] and [height] are
/// the picture's size in hundredths of a millimeter (`\picw`, `\pich`).
Uint8List? placeableWmf(Uint8List metafile, {int width = 0, int height = 0}) {
  if (_isPlaceableWmf(metafile)) return metafile;
  if (!_isMetafile(metafile)) return null;
  final window = _window(metafile);
  int left, top, right, bottom, inch;
  if (window != null) {
    left = math.min(window.x, window.x + window.width);
    right = math.max(window.x, window.x + window.width);
    top = math.min(window.y, window.y + window.height);
    bottom = math.max(window.y, window.y + window.height);
    inch = width > 0 ? (window.width.abs() * 2540 / width).round() : 1440;
  } else {
    left = top = 0;
    right = width > 0 ? width * 1440 ~/ 2540 : 1440;
    bottom = height > 0 ? height * 1440 ~/ 2540 : 1440;
    inch = 1440;
  }
  final out = Uint8List(22 + metafile.length);
  final data = ByteData.sublistView(out)
    ..setUint32(0, 0x9AC6CDD7, _little)
    ..setInt16(6, left.clamp(-32768, 32767), _little)
    ..setInt16(8, top.clamp(-32768, 32767), _little)
    ..setInt16(10, right.clamp(-32768, 32767), _little)
    ..setInt16(12, bottom.clamp(-32768, 32767), _little)
    ..setUint16(14, inch.clamp(1, 65535), _little);
  var checksum = 0;
  for (var offset = 0; offset < 20; offset += 2) {
    checksum ^= data.getUint16(offset, _little);
  }
  data.setUint16(20, checksum, _little);
  out.setRange(22, out.length, metafile);
  return out;
}

/// The metafile of a .wmf file, as `\wmetafile` holds it.
Uint8List? rawWmf(Uint8List file) {
  final metafile = _isPlaceableWmf(file)
      ? Uint8List.sublistView(file, 22)
      : file;
  return _isMetafile(metafile) ? metafile : null;
}

/// The logical window the metafile draws in (SetWindowOrg, SetWindowExt).
({int x, int y, int width, int height})? _window(Uint8List metafile) {
  final data = ByteData.sublistView(metafile);
  var offset = data.getUint16(2, _little) * 2;
  int? x, y, width, height;
  for (var records = 0; records < 4096; records++) {
    if (offset + 10 > metafile.length) break;
    final words = data.getUint32(offset, _little);
    final function = data.getUint16(offset + 4, _little);
    if (words < 3 || function == 0) break;
    if (function == 0x020B) {
      y = data.getInt16(offset + 6, _little);
      x = data.getInt16(offset + 8, _little);
    } else if (function == 0x020C) {
      height = data.getInt16(offset + 6, _little);
      width = data.getInt16(offset + 8, _little);
    }
    offset += words * 2;
  }
  if (width == null || height == null || width == 0 || height == 0) {
    return null;
  }
  return (x: x ?? 0, y: y ?? 0, width: width, height: height);
}

/// Where the pixels start in a device-independent bitmap: after the header,
/// the color masks and the palette.
int? _pixelOffset(Uint8List dib) {
  if (dib.length < 12) return null;
  final data = ByteData.sublistView(dib);
  final header = data.getUint32(0, _little);
  int palette;
  var masks = 0;
  if (header == 12) {
    final bits = data.getUint16(10, _little);
    palette = bits <= 8 ? (1 << bits) * 3 : 0;
  } else if (header >= 40 && header <= 124 && dib.length >= 40) {
    final bits = data.getUint16(14, _little);
    final compression = data.getUint32(16, _little);
    final used = data.getUint32(32, _little);
    palette = (used != 0 ? used : (bits <= 8 ? 1 << bits : 0)) * 4;
    if (header == 40 && compression == 3) masks = 12;
    if (header == 40 && compression == 6) masks = 16;
  } else {
    return null;
  }
  final offset = header + masks + palette;
  return offset <= dib.length ? offset : null;
}

/// A .bmp file from a device-independent bitmap (`\dibitmap`).
Uint8List? bitmapFromDib(Uint8List dib) {
  final pixels = _pixelOffset(dib);
  if (pixels == null) return null;
  final out = Uint8List(14 + dib.length);
  out
    ..[0] = 0x42
    ..[1] = 0x4D
    ..setRange(14, out.length, dib);
  ByteData.sublistView(out)
    ..setUint32(2, out.length, _little)
    ..setUint32(10, 14 + pixels, _little);
  return out;
}

/// The device-independent bitmap of a .bmp file.
Uint8List? dibFromBitmap(Uint8List bitmap) {
  if (bitmap.length < 26 || bitmap[0] != 0x42 || bitmap[1] != 0x4D) {
    return null;
  }
  final dib = Uint8List.sublistView(bitmap, 14);
  final pixels = _pixelOffset(dib);
  final start = ByteData.sublistView(bitmap).getUint32(10, _little);
  if (pixels == null || start < 14 + pixels || start > bitmap.length) {
    return null;
  }
  return Uint8List.fromList([
    ...Uint8List.sublistView(bitmap, 14, 14 + pixels),
    ...Uint8List.sublistView(bitmap, start),
  ]);
}

/// A .bmp file from a device-dependent bitmap (`\wbitmap`), whose rows go
/// from the top and are [widthBytes] long. Monochrome and true color only:
/// the others need the palette of the device that made them.
Uint8List? bitmapFromDdb(
  Uint8List bits, {
  required int width,
  required int height,
  required int bitsPerPixel,
  int? widthBytes,
}) {
  if (!const {1, 24, 32}.contains(bitsPerPixel)) return null;
  if (width <= 0 || height <= 0 || width > 32767 || height > 32767) {
    return null;
  }
  final used = (width * bitsPerPixel + 7) ~/ 8;
  final sourceStride = widthBytes ?? (width * bitsPerPixel + 15) ~/ 16 * 2;
  if (sourceStride < used || sourceStride * height > bits.length) return null;
  final stride = (width * bitsPerPixel + 31) ~/ 32 * 4;
  final palette = bitsPerPixel == 1 ? 8 : 0;
  final offset = 14 + 40 + palette;
  final out = Uint8List(offset + stride * height);
  out
    ..[0] = 0x42
    ..[1] = 0x4D;
  ByteData.sublistView(out)
    ..setUint32(2, out.length, _little)
    ..setUint32(10, offset, _little)
    ..setUint32(14, 40, _little)
    ..setInt32(18, width, _little)
    ..setInt32(22, height, _little)
    ..setUint16(26, 1, _little)
    ..setUint16(28, bitsPerPixel, _little)
    ..setUint32(34, stride * height, _little);
  if (bitsPerPixel == 1) out.fillRange(58, 61, 0xFF);
  for (var row = 0; row < height; row++) {
    final source = row * sourceStride;
    final target = offset + (height - 1 - row) * stride;
    out.setRange(target, target + used, bits, source);
  }
  return out;
}
