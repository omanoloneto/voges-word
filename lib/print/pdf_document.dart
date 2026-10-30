import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';

/// Page resolution in the PDF and when printing.
const printDpi = 200.0;

/// A PDF page: the page image as it looks in the editor, with each line's
/// invisible text on top so it can be searched and copied.
class PdfPageContent {
  const PdfPageContent({
    required this.size,
    required this.imageWidth,
    required this.imageHeight,
    required this.rgb,
    this.lines = const [],
  });

  /// Page size in points.
  final Size size;
  final int imageWidth;
  final int imageHeight;

  /// 8-bit RGB pixels, row by row, with no alpha.
  final Uint8List rgb;

  /// Rectangles in points, with the origin at the top of the page.
  final List<(Rect, String)> lines;
}

/// Builds a simple PDF 1.4; each page is compressed as it is added, to avoid
/// keeping every uncompressed image in memory.
class PdfBuilder {
  final _pages =
      <
        ({Size size, int width, int height, Uint8List image, Uint8List content})
      >[];

  int get pageCount => _pages.length;

  void addPage(PdfPageContent page) {
    _pages.add((
      size: page.size,
      width: page.imageWidth,
      height: page.imageHeight,
      image: const ZLibEncoder().encodeBytes(page.rgb, level: 6),
      content: const ZLibEncoder().encodeBytes(_contentOf(page)),
    ));
  }

  Uint8List build({String title = ''}) {
    final out = BytesBuilder(copy: false);
    final offsets = <int, int>{};
    void text(String value) => out.add(latin1.encode(value));
    void object(int id, String dictionary, [Uint8List? stream]) {
      offsets[id] = out.length;
      text('$id 0 obj\n$dictionary');
      if (stream != null) {
        text('\nstream\n');
        out.add(stream);
        text('\nendstream');
      }
      text('\nendobj\n');
    }

    out.add([..._ascii('%PDF-1.4\n%'), 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);
    final kids = [for (var i = 0; i < _pages.length; i++) '${5 + 3 * i} 0 R'];
    object(1, '<< /Type /Catalog /Pages 2 0 R >>');
    object(
      2,
      '<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${_pages.length} >>',
    );
    object(
      3,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
      '/Encoding /WinAnsiEncoding >>',
    );
    object(
      4,
      '<< /Title ${_textString(title)} /Producer (Voges Word) '
      '/Creator (Voges Word) >>',
    );
    for (var i = 0; i < _pages.length; i++) {
      final page = _pages[i];
      final id = 5 + 3 * i;
      object(
        id,
        '<< /Type /Page /Parent 2 0 R '
        '/MediaBox [0 0 ${_number(page.size.width)} ${_number(page.size.height)}] '
        '/Resources << /XObject << /Im0 ${id + 1} 0 R >> /Font << /F1 3 0 R >> >> '
        '/Contents ${id + 2} 0 R >>',
      );
      object(
        id + 1,
        '<< /Type /XObject /Subtype /Image /Width ${page.width} '
        '/Height ${page.height} /ColorSpace /DeviceRGB /BitsPerComponent 8 '
        '/Filter /FlateDecode /Length ${page.image.length} >>',
        page.image,
      );
      object(
        id + 2,
        '<< /Filter /FlateDecode /Length ${page.content.length} >>',
        page.content,
      );
    }

    final count = 5 + 3 * _pages.length;
    final xref = out.length;
    final entries = StringBuffer('xref\n0 $count\n0000000000 65535 f \n');
    for (var id = 1; id < count; id++) {
      entries.write('${'${offsets[id]}'.padLeft(10, '0')} 00000 n \n');
    }
    text(
      '$entries'
      'trailer\n<< /Size $count /Root 1 0 R /Info 4 0 R >>\n'
      'startxref\n$xref\n%%EOF\n',
    );
    return out.takeBytes();
  }

  static Uint8List _contentOf(PdfPageContent page) {
    final width = _number(page.size.width);
    final height = page.size.height;
    final out = BytesBuilder(copy: false)
      ..add(_ascii('q $width 0 0 ${_number(height)} 0 0 cm /Im0 Do Q\n'));
    if (page.lines.isNotEmpty) {
      out.add(_ascii('BT 3 Tr /F1 1 Tf\n'));
      for (final (rect, line) in page.lines) {
        final encoded = _winAnsi(line);
        final units = encoded.fold<int>(0, (sum, code) => sum + _width(code));
        if (units == 0 || rect.width <= 0 || rect.height <= 0) continue;
        final size = rect.height * 0.8;
        final stretch = rect.width / (units / 1000);
        final baseline = height - rect.top - rect.height * 0.8;
        out
          ..add(
            _ascii(
              '${_number(stretch)} 0 0 ${_number(size)} '
              '${_number(rect.left)} ${_number(baseline)} Tm (',
            ),
          )
          ..add(_escape(encoded))
          ..add(_ascii(') Tj\n'));
      }
      out.add(_ascii('ET\n'));
    }
    return out.takeBytes();
  }

  static List<int> _ascii(String value) => latin1.encode(value);

  static String _number(double value) {
    final fixed = value.toStringAsFixed(3);
    return fixed.contains('.')
        ? fixed.replaceFirst(RegExp(r'\.?0+$'), '')
        : fixed;
  }

  /// Title in UTF-16, for accents and any other script.
  static String _textString(String value) {
    final hex = StringBuffer('<FEFF');
    for (final unit in value.codeUnits) {
      hex.write(unit.toRadixString(16).padLeft(4, '0').toUpperCase());
    }
    return '$hex>';
  }

  static List<int> _escape(List<int> codes) => [
    for (final code in codes)
      ...switch (code) {
        0x28 || 0x29 || 0x5C => [0x5C, code],
        _ => [code],
      },
  ];

  /// WinAnsi encoding of the standard font; characters it lacks become "?".
  static List<int> _winAnsi(String text) => [
    for (final rune in text.runes)
      if (rune >= 0x20 && rune < 0x7F || rune >= 0xA0 && rune <= 0xFF)
        rune
      else
        _windows1252[rune] ?? (rune < 0x20 ? 0x20 : 0x3F),
  ];

  static int _width(int code) =>
      code >= 0x20 && code < 0x7F ? _helvetica[code - 0x20] : 556;

  static const _windows1252 = {
    0x20AC: 0x80,
    0x201A: 0x82,
    0x0192: 0x83,
    0x201E: 0x84,
    0x2026: 0x85,
    0x2020: 0x86,
    0x2021: 0x87,
    0x02C6: 0x88,
    0x2030: 0x89,
    0x0160: 0x8A,
    0x2039: 0x8B,
    0x0152: 0x8C,
    0x017D: 0x8E,
    0x2018: 0x91,
    0x2019: 0x92,
    0x201C: 0x93,
    0x201D: 0x94,
    0x2022: 0x95,
    0x2013: 0x96,
    0x2014: 0x97,
    0x02DC: 0x98,
    0x2122: 0x99,
    0x0161: 0x9A,
    0x203A: 0x9B,
    0x0153: 0x9C,
    0x017E: 0x9E,
    0x0178: 0x9F,
  };

  /// Helvetica widths (standard AFM) from " " to "~", in thousandths.
  static const _helvetica = [
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, //
    278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, //
    584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278,
    500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944,
    667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556, 556,
    278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500,
    278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
  ];
}
