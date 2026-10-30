import 'package:xml/xml.dart';

/// OpenDocument namespaces; every ODF version uses these URIs.
abstract final class OdfNamespaces {
  static const office = 'urn:oasis:names:tc:opendocument:xmlns:office:1.0';
  static const style = 'urn:oasis:names:tc:opendocument:xmlns:style:1.0';
  static const text = 'urn:oasis:names:tc:opendocument:xmlns:text:1.0';
  static const table = 'urn:oasis:names:tc:opendocument:xmlns:table:1.0';
  static const draw = 'urn:oasis:names:tc:opendocument:xmlns:drawing:1.0';
  static const fo =
      'urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0';
  static const svg = 'urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0';
  static const xlink = 'http://www.w3.org/1999/xlink';
  static const meta = 'urn:oasis:names:tc:opendocument:xmlns:meta:1.0';
  static const dc = 'http://purl.org/dc/elements/1.1/';
  static const number = 'urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0';
  static const manifest = 'urn:oasis:names:tc:opendocument:xmlns:manifest:1.0';
}

/// Lookups by namespace URI, since files may use any prefix.
extension OdfElement on XmlElement {
  bool isOdf(String namespace, String local) =>
      name.local == local && name.namespaceUri == namespace;

  String? odfAttribute(String namespace, String local) =>
      getAttribute(local, namespaceUri: namespace);

  XmlElement? odfChild(String namespace, String local) {
    for (final child in childElements) {
      if (child.isOdf(namespace, local)) return child;
    }
    return null;
  }

  Iterable<XmlElement> odfChildren(String namespace, String local) =>
      childElements.where((child) => child.isOdf(namespace, local));
}

final _length = RegExp(
  r'^([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)\s*(pt|in|cm|mm|pc|px)?$',
  caseSensitive: false,
);

/// Points from a length such as `2cm`, `0.5in` or `12pt`; null for
/// percentages and anything else.
double? odfLength(String? value) {
  if (value == null) return null;
  final match = _length.firstMatch(value.trim());
  if (match == null) return null;
  final number = double.tryParse(match[1]!);
  if (number == null || !number.isFinite) return null;
  final points = switch (match[2]?.toLowerCase()) {
    'in' => number * 72,
    'cm' => number * 72 / 2.54,
    'mm' => number * 72 / 25.4,
    'pc' => number * 12,
    'px' => number * 0.75,
    _ => number,
  };
  return points.clamp(-100000.0, 100000.0);
}

/// `130%` as 1.3.
double? odfPercent(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || !trimmed.endsWith('%')) return null;
  final number = double.tryParse(trimmed.substring(0, trimmed.length - 1));
  if (number == null || !number.isFinite) return null;
  return number.clamp(-10000.0, 10000.0) / 100;
}

/// `RRGGBB` from `#rrggbb`; null for `transparent` and anything else.
String? odfColor(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(value.trim());
  return match?[1]!.toUpperCase();
}

/// The first family of a CSS-like list, without quotes.
String? odfFontFamily(String? value) {
  if (value == null) return null;
  final first = value.split(',').first.trim();
  final unquoted =
      first.length >= 2 &&
          (first.startsWith("'") && first.endsWith("'") ||
              first.startsWith('"') && first.endsWith('"'))
      ? first.substring(1, first.length - 1).trim()
      : first;
  return unquoted.isEmpty ? null : unquoted;
}

/// Style names encode spaces and other characters as `_20_`.
String odfDisplayName(String name) => name.replaceAllMapped(
  RegExp(r'_([0-9a-fA-F]{2})_'),
  (match) => String.fromCharCode(int.parse(match[1]!, radix: 16)),
);

/// A length in points as written in the files this app saves.
String odfPoints(double points) {
  final value = points.isFinite ? points.clamp(-100000.0, 100000.0) : 0.0;
  var text = value.toStringAsFixed(2);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'\.?0+$'), '');
  }
  return '${text == '-0' ? '0' : text}pt';
}
