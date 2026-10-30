import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../document/picture_crop.dart';
import '../docx/image_formats.dart';
import 'byte_view.dart';

/// A picture stored in the file, with its size in points when known.
typedef DocPicture = ({
  Uint8List bytes,
  String mime,
  double? width,
  double? height,
});

/// Fractions of a picture's width and height cut off each side; negative
/// ones add space.
typedef PictureCrop = ({double left, double top, double right, double bottom});

/// Largest picture kept, compressed or not.
const maxPictureBytes = 64 * 1024 * 1024;

/// What the pictures of one document may still take, so that many pictures,
/// or one repeated many times, can't exhaust memory or time.
class PictureBudget {
  /// Bytes of the pictures the document shows.
  var kept = 256 * 1024 * 1024;

  /// Bytes compressed pictures inflate to, failed attempts included.
  var inflated = 256 * 1024 * 1024;

  /// Pixels decoded to crop pictures; past it they show whole.
  var cropped = 50 * 1000 * 1000;
}

/// An OfficeArtFBSE's header and fixed fields, before its name.
const _storeEntrySize = 8 + 36;

/// The inline picture whose PICFAndOfficeArtData (MS-DOC 2.9.192) starts at
/// [offset] of the Data stream; null when it is linked to a file, in a format
/// Word can't show, damaged or past the [budget].
DocPicture? inlinePicture(ByteView data, int offset, PictureBudget budget) {
  if (!data.has(offset, 68)) return null;
  final size = data.i32(offset);
  if (size < 68 || data.u16(offset + 4) != 68 || !data.has(offset, size)) {
    return null;
  }
  // 0x64 holds an OfficeArt shape; 0x66 points to a file on disk.
  if (data.u16(offset + 6) != 0x64) return null;
  final width = data.i16(offset + 28) * data.u16(offset + 32) / 1000 / 20;
  final height = data.i16(offset + 30) * data.u16(offset + 34) / 1000 / 20;
  final end = offset + size;
  final shape = _Record.at(data, offset + 68, end);
  if (shape == null || shape.type != 0xF004) return null;
  var at = shape.end;
  while (at < end) {
    final record = _Record.at(data, at, end);
    if (record == null) break;
    final picture = record.type == 0xF007
        ? _storedPicture(data, record, budget)
        : blipPicture(data, record.start, record.end, budget);
    if (picture != null) {
      return croppedPicture(
        picture,
        _cropOf(data, _children(data, shape)),
        width: width > 0 ? width : null,
        height: height > 0 ? height : null,
        budget: budget,
      );
    }
    at = record.end;
  }
  return null;
}

/// [picture] with [crop] cut off, in the frame of [width] by [height] points
/// that the part left fills. A picture that can't be cropped shows whole at
/// the same scale, in a larger frame, instead of stretched.
DocPicture croppedPicture(
  ({Uint8List bytes, String mime}) picture,
  PictureCrop crop, {
  double? width,
  double? height,
  required PictureBudget budget,
}) {
  final shownWidth = 1 - crop.left - crop.right;
  final shownHeight = 1 - crop.top - crop.bottom;
  if (crop == _noCrop || shownWidth <= 0 || shownHeight <= 0) {
    return (
      bytes: picture.bytes,
      mime: picture.mime,
      width: width,
      height: height,
    );
  }
  final pixels = imagePixelSize(picture.bytes);
  final cost = pixels == null ? 0 : pixels.width * pixels.height;
  ({Uint8List bytes, String mime})? cut;
  if (cost > 0 && cost <= budget.cropped) {
    budget.cropped -= cost;
    cut = cropPicture(
      picture.bytes,
      picture.mime,
      left: crop.left,
      top: crop.top,
      right: crop.right,
      bottom: crop.bottom,
    );
  }
  double part(double value) => cut == null ? 0 : value.clamp(0.0, 1.0);
  final keptWidth = 1 - part(crop.left) - part(crop.right);
  final keptHeight = 1 - part(crop.top) - part(crop.bottom);
  return (
    bytes: cut?.bytes ?? picture.bytes,
    mime: cut?.mime ?? picture.mime,
    width: width == null ? null : width / shownWidth * keptWidth,
    height: height == null ? null : height / shownHeight * keptHeight,
  );
}

const PictureCrop _noCrop = (left: 0, top: 0, right: 0, bottom: 0);

/// The cropping in a shape's property tables (OfficeArtFOPT and
/// OfficeArtTertiaryFOPT, MS-ODRAW 2.3.23), as 16.16 fixed-point fractions.
PictureCrop _cropOf(ByteView data, Iterable<_Record> records) {
  var (left, top, right, bottom) = (0.0, 0.0, 0.0, 0.0);
  for (final record in records) {
    if (record.type != 0xF00B && record.type != 0xF122) continue;
    for (final (id, value) in _properties(data, record)) {
      final fraction = value.toSigned(32) / 65536;
      switch (id) {
        case 0x0100:
          top = fraction;
        case 0x0101:
          bottom = fraction;
        case 0x0102:
          left = fraction;
        case 0x0103:
          right = fraction;
      }
    }
  }
  return (left: left, top: top, right: right, bottom: bottom);
}

/// The id and value of each property of an OfficeArtFOPT.
Iterable<(int, int)> _properties(ByteView data, _Record properties) sync* {
  for (var index = 0; index < properties.instance; index++) {
    final at = properties.start + 8 + index * 6;
    if (at + 6 > properties.end) break;
    yield (data.u16(at) & 0x3FFF, data.u32(at + 2));
  }
}

List<_Record> _children(ByteView data, _Record container) {
  final children = <_Record>[];
  var at = container.start + 8;
  while (at < container.end) {
    final child = _Record.at(data, at, container.end);
    if (child == null) break;
    children.add(child);
    at = child.end;
  }
  return children;
}

/// The pictures of the floating shapes of one drawing (the main document's
/// or the headers'), from the OfficeArtContent (MS-DOC 2.9.172) of the table
/// stream; the pictures themselves are in the WordDocument stream.
class FloatingPictures {
  FloatingPictures._(this._table, this._document, this._store, this._shapes);

  /// [header] picks the headers' drawing instead of the main document's.
  factory FloatingPictures.parse(
    ByteView table,
    int offset,
    int size,
    ByteView document, {
    required bool header,
  }) {
    final end = offset + size;
    final group = _Record.at(table, offset, end);
    if (group == null || group.type != 0xF000) {
      throw const FormatException('No drawing group');
    }
    final store = <_Record>[];
    for (final child in _children(table, group)) {
      if (child.type == 0xF001) {
        store.addAll(_children(table, child).where((r) => r.type == 0xF007));
      }
    }
    final shapes = <int, ({int picture, PictureCrop crop})>{};
    var at = group.end;
    while (at + 9 <= end) {
      final label = table.u8(at);
      final drawing = _Record.at(table, at + 1, end);
      if (drawing == null || drawing.type != 0xF002) break;
      if (label == (header ? 1 : 0)) _collectShapes(table, drawing, shapes);
      at = drawing.end;
    }
    return FloatingPictures._(table, document, store, shapes);
  }

  final ByteView _table;
  final ByteView _document;
  final List<_Record> _store;

  /// Shape id → picture index in the store, from 1, and its cropping.
  final Map<int, ({int picture, PictureCrop crop})> _shapes;

  /// The picture of shape [id] in its frame of [width] by [height] points;
  /// null when it isn't a picture or is past the [budget].
  DocPicture? picture(
    int id, {
    double? width,
    double? height,
    required PictureBudget budget,
  }) {
    final shape = _shapes[id];
    final index = shape?.picture ?? 0;
    if (index < 1 || index > _store.length) return null;
    final entry = _store[index - 1];
    if (entry.end - entry.start < _storeEntrySize) return null;
    final nameSize = _table.u8(entry.start + 8 + 33);
    final embedded = entry.start + 8 + 36 + nameSize;
    final ({Uint8List bytes, String mime})? picture;
    if (embedded + 8 <= entry.end) {
      picture = blipPicture(_table, embedded, entry.end, budget);
    } else {
      final size = _table.u32(entry.start + 8 + 20);
      final offset = _table.u32(entry.start + 8 + 28);
      picture = _document.has(offset, size)
          ? blipPicture(_document, offset, offset + size, budget)
          : null;
    }
    if (picture == null) return null;
    return croppedPicture(
      picture,
      shape!.crop,
      width: width,
      height: height,
      budget: budget,
    );
  }

  /// Picture shapes of a drawing, walked without recursion and with a cap on
  /// the records visited.
  static void _collectShapes(
    ByteView data,
    _Record drawing,
    Map<int, ({int picture, PictureCrop crop})> shapes,
  ) {
    final pending = [drawing];
    var visited = 0;
    while (pending.isNotEmpty && visited < 100000) {
      final container = pending.removeLast();
      final children = _children(data, container);
      int? id;
      int? picture;
      for (final child in children) {
        visited++;
        if (child.isContainer) {
          if (pending.length < 1000) pending.add(child);
        } else if (child.type == 0xF00A && child.end - child.start >= 16) {
          id = data.u32(child.start + 8);
        } else if (child.type == 0xF00B) {
          for (final (property, value) in _properties(data, child)) {
            if (property == 0x0104) picture = value;
          }
        }
      }
      if (container.type == 0xF004 && id != null && picture != null) {
        shapes[id] = (picture: picture, crop: _cropOf(data, children));
      }
    }
  }
}

/// The picture of the BLIP record (MS-ODRAW 2.2.23) at [start]; null when
/// it can't be read or is past the [budget].
({Uint8List bytes, String mime})? blipPicture(
  ByteView data,
  int start,
  int end,
  PictureBudget budget,
) {
  final record = _Record.at(data, start, end);
  if (record == null) return null;
  final uids = record.instance & 1 == 1 ? 2 : 1;
  final body = record.start + 8 + 16 * uids;
  switch (record.type) {
    case 0xF01A || 0xF01B:
      return _metafile(
        data,
        body,
        record.end,
        wmf: record.type == 0xF01B,
        budget: budget,
      );
    case 0xF01D || 0xF01E || 0xF01F || 0xF029:
      if (body + 1 >= record.end) return null;
      final bytes = data.slice(body + 1, record.end - body - 1);
      return switch (record.type) {
        0xF01D => (bytes: bytes, mime: 'image/jpeg'),
        0xF01E => (bytes: bytes, mime: 'image/png'),
        0xF029 => (bytes: bytes, mime: 'image/tiff'),
        _ when bytes.length + 14 > budget.kept => null,
        _ => _bitmapFile(bytes),
      };
  }
  return null;
}

/// An OfficeArtFBSE with its BLIP inside.
({Uint8List bytes, String mime})? _storedPicture(
  ByteView data,
  _Record fbse,
  PictureBudget budget,
) {
  if (fbse.end - fbse.start < _storeEntrySize) return null;
  final nameSize = data.u8(fbse.start + 8 + 33);
  final blip = fbse.start + 8 + 36 + nameSize;
  return blip + 8 <= fbse.end
      ? blipPicture(data, blip, fbse.end, budget)
      : null;
}

({Uint8List bytes, String mime})? _metafile(
  ByteView data,
  int at,
  int end, {
  required bool wmf,
  required PictureBudget budget,
}) {
  if (at + 34 > end) return null;
  final size = data.u32(at);
  final bounds = (
    left: data.i32(at + 4),
    top: data.i32(at + 8),
    right: data.i32(at + 12),
    bottom: data.i32(at + 16),
  );
  final widthEmu = data.i32(at + 20);
  final saved = data.u32(at + 28);
  final compressed = data.u8(at + 32) == 0;
  if (at + 34 + saved > end || saved > maxPictureBytes) return null;
  final stored = data.slice(at + 34, saved);
  var bytes = stored;
  if (compressed) {
    // The size the picture says it inflates to is checked, and counted,
    // before inflating.
    final limit = math.min(size, maxPictureBytes);
    if (limit > math.min(budget.kept, budget.inflated)) return null;
    budget.inflated -= limit;
    final inflated = inflateCapped(stored, limit);
    if (inflated == null) return null;
    bytes = inflated;
  }
  if (bytes.isEmpty) return null;
  return wmf
      ? (bytes: _placeableWmf(bytes, bounds, widthEmu), mime: 'image/x-wmf')
      : (bytes: bytes, mime: 'image/x-emf');
}

/// Inflates zlib data, failing past [limit] bytes instead of growing on.
Uint8List? inflateCapped(Uint8List zlib, int limit) {
  if (zlib.length < 2) return null;
  final method = zlib[0];
  final flags = zlib[1];
  if (method & 0x0F != 8 ||
      (method << 8 | flags) % 31 != 0 ||
      flags & 0x20 != 0) {
    return null;
  }
  final output = _CappedOutput(limit);
  try {
    final inflate = Inflate.lazy(
      InputMemoryStream(Uint8List.sublistView(zlib, 2)),
      output: output,
    );
    while (inflate.inflateBlock()) {}
  } catch (_) {
    // Damaged or too large: the picture is left out.
    return null;
  }
  return Uint8List.fromList(output.getBytes());
}

class _TooLarge implements Exception {
  const _TooLarge();
}

class _CappedOutput extends OutputMemoryStream {
  _CappedOutput(this.limit) : super(size: 0x8000);

  final int limit;

  void _reserve(int count) {
    if (length + count > limit) throw const _TooLarge();
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _reserve(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _reserve(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _reserve(count);
    super.writeBackReference(distance, count);
  }
}

/// A BMP file from a device-independent bitmap.
({Uint8List bytes, String mime})? _bitmapFile(Uint8List dib) {
  if (dib.length < 16) return null;
  final view = ByteView(dib);
  final headerSize = view.u32(0);
  int palette;
  if (headerSize == 12) {
    final bits = view.u16(10);
    palette = bits <= 8 ? (1 << bits) * 3 : 0;
  } else if (headerSize >= 40 && headerSize < dib.length) {
    final bits = view.u16(14);
    final compression = view.u32(16);
    final used = view.u32(32);
    palette = (used != 0 ? used : (bits <= 8 ? 1 << bits : 0)) * 4;
    if (headerSize == 40 && compression == 3) palette += 12;
    if (headerSize == 40 && compression == 6) palette += 16;
  } else {
    return null;
  }
  final pixels = 14 + headerSize + palette;
  if (pixels > 14 + dib.length) return null;
  final file = Uint8List(14 + dib.length);
  ByteData.sublistView(file)
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4D)
    ..setUint32(2, file.length, Endian.little)
    ..setUint32(10, pixels, Endian.little);
  file.setRange(14, file.length, dib);
  return (bytes: file, mime: 'image/bmp');
}

/// Metafile BLIPs drop the placeable header that .wmf files start with.
Uint8List _placeableWmf(
  Uint8List metafile,
  ({int left, int top, int right, int bottom}) bounds,
  int widthEmu,
) {
  if (metafile.length >= 4 &&
      ByteData.sublistView(metafile).getUint32(0, Endian.little) ==
          0x9AC6CDD7) {
    return metafile;
  }
  int short(int value) => value.clamp(-32768, 32767);
  final width = bounds.right - bounds.left;
  final inch = width > 0 && widthEmu > 0
      ? (width * 914400 / widthEmu).round().clamp(1, 0xFFFF)
      : 1440;
  final header = ByteData(22)
    ..setUint32(0, 0x9AC6CDD7, Endian.little)
    ..setInt16(6, short(bounds.left), Endian.little)
    ..setInt16(8, short(bounds.top), Endian.little)
    ..setInt16(10, short(bounds.right), Endian.little)
    ..setInt16(12, short(bounds.bottom), Endian.little)
    ..setUint16(14, inch, Endian.little);
  var checksum = 0;
  for (var word = 0; word < 10; word++) {
    checksum ^= header.getUint16(word * 2, Endian.little);
  }
  header.setUint16(20, checksum, Endian.little);
  return Uint8List(22 + metafile.length)
    ..setRange(0, 22, header.buffer.asUint8List())
    ..setRange(22, 22 + metafile.length, metafile);
}

/// An OfficeArt record header (MS-ODRAW 2.2.1) and where its data ends.
class _Record {
  const _Record(this.start, this.version, this.instance, this.type, this.end);

  static _Record? at(ByteView data, int start, int limit) {
    if (start < 0 || start + 8 > limit || !data.has(start, 8)) return null;
    final end = start + 8 + data.u32(start + 4);
    if (end > limit) return null;
    final header = data.u16(start);
    return _Record(start, header & 0x0F, header >> 4, data.u16(start + 2), end);
  }

  final int start;
  final int version;
  final int instance;
  final int type;
  final int end;

  bool get isContainer => version == 0x0F;
}
