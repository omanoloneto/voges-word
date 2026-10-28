import 'dart:convert';
import 'dart:typed_data';

const _mimeByExtension = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'bmp': 'image/bmp',
  'webp': 'image/webp',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'emf': 'image/x-emf',
  'wmf': 'image/x-wmf',
  'svg': 'image/svg+xml',
};

/// Formatos que o Flutter consegue desenhar e o Word consegue abrir.
const insertableImageExtensions = ['png', 'jpg', 'jpeg', 'gif', 'bmp'];

String mimeForPath(String path) {
  final dot = path.lastIndexOf('.');
  final extension = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  return _mimeByExtension[extension] ?? 'application/octet-stream';
}

String extensionForMime(String mime) => switch (mime) {
  'image/jpeg' => 'jpeg',
  'image/gif' => 'gif',
  'image/bmp' => 'bmp',
  'image/webp' => 'webp',
  'image/tiff' => 'tiff',
  'image/x-emf' => 'emf',
  'image/x-wmf' => 'wmf',
  'image/svg+xml' => 'svg',
  _ => 'png',
};

bool isDisplayable(String mime) => const {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/bmp',
  'image/webp',
}.contains(mime);

String dataUri(Uint8List bytes, String path) =>
    'data:${mimeForPath(path)};base64,${base64Encode(bytes)}';

String dataUriFromMime(Uint8List bytes, String mime) =>
    'data:$mime;base64,${base64Encode(bytes)}';

({Uint8List bytes, String mime})? decodeDataUri(String uri) {
  if (!uri.startsWith('data:')) return null;
  final comma = uri.indexOf(',');
  if (comma < 0) return null;
  final header = uri.substring(5, comma);
  if (!header.endsWith(';base64')) return null;
  try {
    return (
      bytes: base64Decode(uri.substring(comma + 1)),
      mime: header.substring(0, header.length - 7),
    );
  } on FormatException {
    return null;
  }
}

/// Tamanho em pixels lido do cabeçalho (PNG, JPEG, GIF e BMP).
({int width, int height})? imagePixelSize(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length > 24 && bytes[0] == 0x89 && bytes[1] == 0x50) {
    return (width: data.getUint32(16), height: data.getUint32(20));
  }
  if (bytes.length > 10 && bytes[0] == 0x47 && bytes[1] == 0x49) {
    return (
      width: data.getUint16(6, Endian.little),
      height: data.getUint16(8, Endian.little),
    );
  }
  if (bytes.length > 26 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return (
      width: data.getInt32(18, Endian.little).abs(),
      height: data.getInt32(22, Endian.little).abs(),
    );
  }
  if (bytes.length > 4 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    var offset = 2;
    while (offset + 9 < bytes.length) {
      if (bytes[offset] != 0xFF) {
        offset++;
        continue;
      }
      final marker = bytes[offset + 1];
      final length = data.getUint16(offset + 2);
      final isFrame =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isFrame) {
        return (
          height: data.getUint16(offset + 5),
          width: data.getUint16(offset + 7),
        );
      }
      offset += 2 + length;
    }
  }
  return null;
}
