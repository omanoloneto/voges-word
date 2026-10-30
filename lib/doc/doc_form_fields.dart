import 'byte_view.dart';

/// What a check box or drop-down form field shows, its box or its chosen
/// entry, from the FFData (MS-DOC 2.9.81) after the NilPICFAndBinData header
/// at [offset] of the Data stream; null for other form fields and data it
/// can't read.
String? formFieldText(ByteView data, int offset) {
  if (!data.has(offset, 6)) return null;
  final size = data.i32(offset);
  if (size < 68 + 10 || data.u16(offset + 4) != 68 || !data.has(offset, size)) {
    return null;
  }
  final field = data.view(offset + 68, size - 68);
  if (field.u32(0) != 0xFFFFFFFF) return null;
  final bits = field.u16(4);
  final type = bits & 0x03;
  final state = (bits >> 2) & 0x1F;
  if (type != 1 && type != 2) return null;
  // The name follows the version, the bits, the length and the box size.
  var at = _afterString(field, 10);
  // 25 is the default state, which follows the name.
  final chosen = state == 25 ? field.u16(at) : state;
  if (type == 1) return chosen == 0 ? '☐' : '☒';
  at += 2;
  // Format, help, status bar text, and entry and exit macros.
  for (var index = 0; index < 5; index++) {
    at = _afterString(field, at);
  }
  if (field.u16(at) != 0xFFFF) return null;
  final count = field.u16(at + 2);
  final extra = field.u16(at + 4);
  at += 6;
  for (var index = 0; index < count && index <= chosen; index++) {
    final length = field.u16(at);
    if (index == chosen) return field.utf16(at + 2, length);
    at += 2 + length * 2 + extra;
  }
  return '';
}

/// The offset after the Xstz (length, characters and terminator) at [at].
int _afterString(ByteView data, int at) => at + 2 + data.u16(at) * 2 + 2;
