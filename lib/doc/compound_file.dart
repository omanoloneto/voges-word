import 'dart:math' as math;
import 'dart:typed_data';

import '../document/document_codec.dart';
import 'byte_view.dart';

typedef _Entry = ({
  String name,
  int type,
  int left,
  int right,
  int child,
  int start,
  int size,
});

/// The streams at the root of a Compound File Binary file (MS-CFB), the
/// container of Word 97–2003 documents.
class CompoundFile {
  CompoundFile._(this._file, this._version, this._sectorSize)
    : _sectorCount = (_file.length - 1) ~/ _sectorSize;

  /// Throws [DocumentProblemException] with [DocumentProblem.notWordDocument]
  /// when [bytes] isn't a compound file, and a [FormatException] when it is
  /// damaged.
  factory CompoundFile.parse(Uint8List bytes) {
    if (!_hasSignature(bytes)) {
      throw DocumentProblemException(DocumentProblem.notWordDocument);
    }
    if (bytes.length < 512) throw const FormatException('Truncated header');
    final header = ByteView(bytes);
    final version = header.u16(26);
    final shift = header.u16(30);
    final supported =
        header.u16(28) == 0xFFFE &&
        (version == 3 && shift == 9 || version == 4 && shift == 12) &&
        header.u16(32) == 6 &&
        header.u32(56) == _miniCutoff;
    if (!supported) throw const FormatException('Unsupported compound file');
    final sectorSize = 1 << shift;
    if (bytes.length <= sectorSize) throw const FormatException('No sectors');
    return CompoundFile._(bytes, version, sectorSize).._load(header);
  }

  static const _signature = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
  static const _miniCutoff = 4096;
  static const _miniSectorSize = 64;
  static const _endOfChain = 0xFFFFFFFE;
  static const _noStream = 0xFFFFFFFF;
  static const _storage = 1;
  static const _stream = 2;
  static const _root = 5;

  static bool _hasSignature(Uint8List bytes) {
    if (bytes.length < _signature.length) return false;
    for (var index = 0; index < _signature.length; index++) {
      if (bytes[index] != _signature[index]) return false;
    }
    return true;
  }

  final Uint8List _file;
  final int _version;
  final int _sectorSize;

  /// Sectors after the header; a partial last one reads as zero-padded.
  final int _sectorCount;

  late final Uint32List _fat;
  late final Uint32List _miniFat;
  late final Uint8List _miniStream;
  late final ByteView _directory;
  final _children = <String, _Entry>{};

  /// Whether the root holds a stream or storage named [name] (any case).
  bool contains(String name) => _children.containsKey(name.toUpperCase());

  /// A stream at the root; null when missing.
  Uint8List? stream(String name) {
    final entry = _children[name.toUpperCase()];
    if (entry == null || entry.type != _stream) return null;
    return _read(entry.start, entry.size, mini: entry.size < _miniCutoff);
  }

  void _load(ByteView header) {
    final fatCount = header.u32(44);
    final firstDirectory = header.u32(48);
    final firstMiniFat = header.u32(60);
    final miniFatCount = header.u32(64);
    var difatSector = header.u32(68);
    final difatCount = header.u32(72);
    if (fatCount == 0 ||
        fatCount > _sectorCount ||
        difatCount > _sectorCount ||
        miniFatCount > _sectorCount) {
      throw const FormatException('Bad sector counts');
    }

    final fatSectors = <int>[
      for (var index = 0; index < math.min(fatCount, 109); index++)
        header.u32(76 + index * 4),
    ];
    final perDifat = _sectorSize ~/ 4 - 1;
    final seenDifat = <int>{};
    while (fatSectors.length < fatCount) {
      if (difatSector >= _sectorCount || !seenDifat.add(difatSector)) {
        throw const FormatException('Broken DIFAT');
      }
      final sector = ByteView(_sector(difatSector));
      for (var i = 0; i < perDifat && fatSectors.length < fatCount; i++) {
        fatSectors.add(sector.u32(i * 4));
      }
      difatSector = sector.u32(perDifat * 4);
    }

    final perSector = _sectorSize ~/ 4;
    _fat = Uint32List(fatCount * perSector);
    for (final (index, sector) in fatSectors.indexed) {
      if (sector >= _sectorCount) throw const FormatException('Bad FAT');
      final data = ByteData.sublistView(_sector(sector));
      for (var i = 0; i < perSector; i++) {
        _fat[index * perSector + i] = data.getUint32(i * 4, Endian.little);
      }
    }

    final directory = _chain(firstDirectory, _fat, _sectorCount);
    final directoryBytes = Uint8List(directory.length * _sectorSize);
    for (final (index, sector) in directory.indexed) {
      directoryBytes.setRange(
        index * _sectorSize,
        (index + 1) * _sectorSize,
        _sector(sector),
      );
    }
    _directory = ByteView(directoryBytes);
    final entryCount = directoryBytes.length ~/ 128;
    final root = _entry(0);
    if (root.type != _root) throw const FormatException('No root entry');

    _miniStream = _read(root.start, root.size, mini: false);
    if (miniFatCount == 0) {
      _miniFat = Uint32List(0);
    } else {
      final sectors = _chain(
        firstMiniFat,
        _fat,
        _sectorCount,
        length: miniFatCount,
      );
      _miniFat = Uint32List(miniFatCount * perSector);
      for (final (index, sector) in sectors.indexed) {
        final data = ByteData.sublistView(_sector(sector));
        for (var i = 0; i < perSector; i++) {
          _miniFat[index * perSector + i] = data.getUint32(
            i * 4,
            Endian.little,
          );
        }
      }
    }

    final seen = Uint8List(entryCount);
    final pending = [root.child];
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (id == _noStream) continue;
      if (id >= entryCount || seen[id] == 1) {
        throw const FormatException('Broken directory tree');
      }
      seen[id] = 1;
      final entry = _entry(id);
      pending
        ..add(entry.left)
        ..add(entry.right);
      if (entry.type == _stream || entry.type == _storage) {
        _children.putIfAbsent(entry.name.toUpperCase(), () => entry);
      }
    }
  }

  _Entry _entry(int id) {
    final offset = id * 128;
    final nameBytes = _directory.u16(offset + 64);
    final nameLength = nameBytes >= 2 && nameBytes <= 64 && nameBytes.isEven
        ? nameBytes ~/ 2 - 1
        : 0;
    final low = _directory.u32(offset + 120);
    final high = _directory.u32(offset + 124);
    // Version 3 files may leave garbage in the high half of the size.
    if (_version == 4 && high != 0) {
      throw const FormatException('Stream too large');
    }
    return (
      name: _directory.utf16(offset, nameLength),
      type: _directory.u8(offset + 66),
      left: _directory.u32(offset + 68),
      right: _directory.u32(offset + 72),
      child: _directory.u32(offset + 76),
      start: _directory.u32(offset + 116),
      size: low,
    );
  }

  Uint8List _sector(int index) {
    final start = (index + 1) * _sectorSize;
    final end = start + _sectorSize;
    if (end <= _file.length) return Uint8List.sublistView(_file, start, end);
    return Uint8List(_sectorSize)
      ..setRange(0, _file.length - start, _file, start);
  }

  /// Sector numbers of a chain; [length] stops it early, otherwise it runs to
  /// its end mark. Cycles and sectors out of range are damage.
  List<int> _chain(int start, Uint32List table, int limit, {int? length}) {
    final sectors = <int>[];
    final seen = Uint8List(limit);
    var sector = start;
    while (length == null ? sector != _endOfChain : sectors.length < length) {
      if (sector >= limit || seen[sector] == 1) {
        throw const FormatException('Broken sector chain');
      }
      seen[sector] = 1;
      sectors.add(sector);
      // macOS's writer (textutil, TextEdit) can leave the last sectors out
      // of the FAT; they follow one another up to the end of the file.
      sector = sector < table.length
          ? table[sector]
          : sector + 1 < limit
          ? sector + 1
          : _endOfChain;
    }
    return sectors;
  }

  Uint8List _read(int start, int size, {required bool mini}) {
    if (size == 0) return Uint8List(0);
    if (size > _file.length) throw const FormatException('Stream too large');
    final unit = mini ? _miniSectorSize : _sectorSize;
    final sectors = mini
        ? _chain(
            start,
            _miniFat,
            (_miniStream.length + unit - 1) ~/ unit,
            length: (size + unit - 1) ~/ unit,
          )
        : _chain(start, _fat, _sectorCount, length: (size + unit - 1) ~/ unit);
    final out = Uint8List(size);
    for (final (index, sector) in sectors.indexed) {
      final at = index * unit;
      final count = math.min(unit, size - at);
      if (mini) {
        final from = sector * unit;
        if (from + count > _miniStream.length) {
          throw const FormatException('Mini sector out of range');
        }
        out.setRange(at, at + count, _miniStream, from);
      } else {
        out.setRange(at, at + count, _sector(sector));
      }
    }
    return out;
  }
}
