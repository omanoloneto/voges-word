import 'dart:io';
import 'dart:typed_data';

typedef ByteReader = Uint8List Function(int offset, int length);

const _collectionTag = 0x74746366;
const _nameTag = 0x6E616D65;
const _fontExtensions = {'.ttf', '.otf', '.ttc', '.otc'};

/// Famílias de todos os arquivos de fonte das pastas, em ordem alfabética.
List<String> fontFamiliesIn(Iterable<String> directories) {
  final families = <String>{};
  for (final path in directories) {
    final directory = Directory(path);
    if (!directory.existsSync()) continue;
    for (final entry in directory.listSync(recursive: true)) {
      final name = entry.path.toLowerCase();
      if (entry is! File ||
          !_fontExtensions.any((extension) => name.endsWith(extension))) {
        continue;
      }
      RandomAccessFile? file;
      try {
        file = entry.openSync();
        final opened = file;
        families.addAll(
          familyNamesOf((offset, length) {
            opened.setPositionSync(offset);
            final bytes = opened.readSync(length);
            if (bytes.length != length) throw const FormatException();
            return bytes;
          }),
        );
      } catch (_) {
        continue;
      } finally {
        file?.closeSync();
      }
    }
  }
  return families.where((name) => !name.startsWith('.')).toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
}

/// Nome da família de cada fonte do arquivo (.ttf, .otf ou coleção .ttc).
Set<String> familyNamesOf(ByteReader read) {
  final header = ByteData.sublistView(read(0, 12));
  if (header.getUint32(0) != _collectionTag) return {?_familyAt(read, 0)};
  final count = header.getUint32(8);
  final offsets = ByteData.sublistView(read(12, 4 * count));
  return {
    for (var i = 0; i < count; i++) ?_familyAt(read, offsets.getUint32(i * 4)),
  };
}

String? _familyAt(ByteReader read, int offset) {
  final tables = ByteData.sublistView(read(offset, 12)).getUint16(4);
  final directory = ByteData.sublistView(read(offset + 12, 16 * tables));
  for (var i = 0; i < tables; i++) {
    if (directory.getUint32(i * 16) != _nameTag) continue;
    return _familyIn(
      read(directory.getUint32(i * 16 + 8), directory.getUint32(i * 16 + 12)),
    );
  }
  return null;
}

/// Prefere o nome tipográfico (id 16) ao antigo (id 1), e o inglês.
String? _familyIn(Uint8List table) {
  final data = ByteData.sublistView(table);
  final count = data.getUint16(2);
  final strings = data.getUint16(4);
  String? best;
  var bestScore = -1;
  for (var i = 0; i < count; i++) {
    final record = 6 + i * 12;
    final platform = data.getUint16(record);
    final language = data.getUint16(record + 4);
    final id = data.getUint16(record + 6);
    if (id != 1 && id != 16 || platform != 1 && platform != 3) continue;
    final english = platform == 3 ? language == 0x409 : language == 0;
    final score =
        (id == 16 ? 4 : 0) + (platform == 3 ? 2 : 0) + (english ? 1 : 0);
    if (score <= bestScore) continue;
    final start = strings + data.getUint16(record + 10);
    final bytes = table.sublist(start, start + data.getUint16(record + 8));
    final name = (platform == 3 ? _utf16 : String.fromCharCodes)(bytes).trim();
    if (name.isEmpty) continue;
    best = name;
    bestScore = score;
  }
  return best;
}

String _utf16(List<int> bytes) => String.fromCharCodes([
  for (var i = 0; i + 1 < bytes.length; i += 2) bytes[i] << 8 | bytes[i + 1],
]);
