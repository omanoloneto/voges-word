import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'byte_view.dart';

/// A picture stored in the file, with its size in points when known.
typedef DocPicture = ({
  Uint8List bytes,
  String mime,
  double? width,
  double? height,
});

/// Largest picture kept, compressed or not.
const maxPictureBytes = 64 * 1024 * 1024;

/// An OfficeArtFBSE's header and fixed fields, before its name.
const _storeEntrySize = 8 + 36;

/// The inline picture whose PICFAndOfficeArtData (MS-DOC 2.9.192) starts at
/// [offset] of the Data stream; null when it is linked to a file, in a format
/// Word can't show or damaged.
DocPicture? inlinePicture(ByteView data, int offset) {
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
        ? _storedPicture(data, record)
        : blipPicture(data, record.start, record.end);
    if (picture != null) {
      return (
        bytes: picture.bytes,
        mime: picture.mime,
        width: width > 0 ? width : null,
        height: height > 0 ? height : null,
      );
    }
    at = record.end;
  }
  return null;
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
    final shapes = <int, int>{};
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

  /// Shape id → picture index in the store, from 1.
  final Map<int, int> _shapes;

  /// The picture of shape [id]; null when it isn't a picture.
  ({Uint8List bytes, String mime})? operator [](int id) {
    final index = _shapes[id];
    if (index == null || index < 1 || index > _store.length) return null;
    final entry = _store[index - 1];
    if (entry.end - entry.start < _storeEntrySize) return null;
    final nameSize = _table.u8(entry.start + 8 + 33);
    final embedded = entry.start + 8 + 36 + nameSize;
    if (embedded + 8 <= entry.end) {
      return blipPicture(_table, embedded, entry.end);
    }
    final size = _table.u32(entry.start + 8 + 20);
    final offset = _table.u32(entry.start + 8 + 28);
    if (!_document.has(offset, size)) return null;
    return blipPicture(_document, offset, offset + size);
  }

  /// Picture shapes of a drawing, walked without recursion and with a cap on
  /// the records visited.
  static void _collectShapes(
    ByteView data,
    _Record drawing,
    Map<int, int> shapes,
  ) {
    final pending = [drawing];
    var visited = 0;
    while (pending.isNotEmpty && visited < 100000) {
      final container = pending.removeLast();
      int? id;
      int? picture;
      for (final child in _children(data, container)) {
        visited++;
        if (child.isContainer) {
          if (pending.length < 1000) pending.add(child);
        } else if (child.type == 0xF00A && child.end - child.start >= 16) {
          id = data.u32(child.start + 8);
        } else if (child.type == 0xF00B) {
          picture = _pictureProperty(data, child) ?? picture;
        }
      }
      if (container.type == 0xF004 && id != null && picture != null) {
        shapes[id] = picture;
      }
    }
  }

  /// The pib property (MS-ODRAW 2.3.23.1) of an OfficeArtFOPT.
  static int? _pictureProperty(ByteView data, _Record properties) {
    final count = properties.instance;
    for (var index = 0; index < count; index++) {
      final at = properties.start + 8 + index * 6;
      if (at + 6 > properties.end) break;
      if (data.u16(at) & 0x3FFF == 0x0104) return data.u32(at + 2);
    }
    return null;
  }

  static List<_Record> _children(ByteView data, _Record container) {
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
}

/// The picture of the BLIP record (MS-ODRAW 2.2.23) at [start].
({Uint8List bytes, String mime})? blipPicture(
  ByteView data,
  int start,
  int end,
) {
  final record = _Record.at(data, start, end);
  if (record == null) return null;
  final uids = record.instance & 1 == 1 ? 2 : 1;
  final body = record.start + 8 + 16 * uids;
  switch (record.type) {
    case 0xF01A || 0xF01B:
      return _metafile(data, body, record.end, wmf: record.type == 0xF01B);
    case 0xF01D || 0xF01E || 0xF01F || 0xF029:
      if (body + 1 >= record.end) return null;
      final bytes = data.slice(body + 1, record.end - body - 1);
      return switch (record.type) {
        0xF01D => (bytes: bytes, mime: 'image/jpeg'),
        0xF01E => (bytes: bytes, mime: 'image/png'),
        0xF029 => (bytes: bytes, mime: 'image/tiff'),
        _ => _bitmapFile(bytes),
      };
  }
  return null;
}

/// An OfficeArtFBSE with its BLIP inside.
({Uint8List bytes, String mime})? _storedPicture(ByteView data, _Record fbse) {
  if (fbse.end - fbse.start < _storeEntrySize) return null;
  final nameSize = data.u8(fbse.start + 8 + 33);
  final blip = fbse.start + 8 + 36 + nameSize;
  return blip + 8 <= fbse.end ? blipPicture(data, blip, fbse.end) : null;
}

({Uint8List bytes, String mime})? _metafile(
  ByteView data,
  int at,
  int end, {
  required bool wmf,
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
  final bytes = compressed
      ? inflateCapped(stored, size < maxPictureBytes ? size : maxPictureBytes)
      : stored;
  if (bytes == null || bytes.isEmpty) return null;
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
