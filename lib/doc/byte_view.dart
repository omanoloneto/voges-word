import 'dart:typed_data';

/// Little-endian reads that throw a [FormatException] outside the data, so
/// hostile offsets never surface as a [RangeError].
class ByteView {
  ByteView(this.bytes) : _data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _data;

  int get length => bytes.length;

  bool has(int offset, int count) =>
      offset >= 0 && count >= 0 && offset <= bytes.length - count;

  int u8(int offset) {
    _check(offset, 1);
    return bytes[offset];
  }

  int u16(int offset) {
    _check(offset, 2);
    return _data.getUint16(offset, Endian.little);
  }

  int i16(int offset) {
    _check(offset, 2);
    return _data.getInt16(offset, Endian.little);
  }

  int u32(int offset) {
    _check(offset, 4);
    return _data.getUint32(offset, Endian.little);
  }

  int i32(int offset) {
    _check(offset, 4);
    return _data.getInt32(offset, Endian.little);
  }

  /// A view, not a copy.
  Uint8List slice(int offset, int count) {
    _check(offset, count);
    return Uint8List.sublistView(bytes, offset, offset + count);
  }

  ByteView view(int offset, int count) => ByteView(slice(offset, count));

  /// UTF-16LE text of [count] code units.
  String utf16(int offset, int count) {
    _check(offset, count * 2);
    return String.fromCharCodes([
      for (var index = 0; index < count; index++)
        _data.getUint16(offset + index * 2, Endian.little),
    ]);
  }

  void _check(int offset, int count) {
    if (!has(offset, count)) throw const FormatException('Out of range');
  }
}
