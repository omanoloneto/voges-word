import 'dart:math' as math;

import 'package:flutter_quill/quill_delta.dart';

import '../document/embeds.dart';

/// Content pasted from elsewhere keeps only the formatting Voges Word saves.
Delta sanitizePastedDelta(Delta delta) {
  final result = Delta();
  for (final operation in delta.toList()) {
    final data = operation.data;
    if (data is Map) {
      final image = data[EmbedTypes.image];
      if (image is String && image.startsWith('data:image/')) {
        result.insert({EmbedTypes.image: image});
      }
      continue;
    }
    if (data is! String) continue;
    final attributes = _clean(operation.attributes ?? const {});
    result.insert(data, attributes.isEmpty ? null : attributes);
  }
  return result;
}

Map<String, dynamic> _clean(Map<String, dynamic> attributes) {
  final clean = <String, dynamic>{};
  attributes.forEach((key, value) {
    switch (key) {
      case 'bold' || 'italic' || 'underline' || 'strike':
        if (value == true) clean[key] = true;
      case 'link':
        if (value is String && value.isNotEmpty) clean[key] = value;
      case 'color' || 'background':
        final hex = cssColorToHex(value);
        if (hex != null) clean[key] = hex;
      case 'size':
        final points = cssSizeToPoints(value);
        if (points != null) clean[key] = points;
      case 'font':
        if (value is String && RegExp(r'^[\w ]+$').hasMatch(value.trim())) {
          clean[key] = value.trim();
        }
      case 'script':
        if (value == 'super' || value == 'sub') clean[key] = value;
      case 'header':
        final level = value is num ? value.toInt() : int.tryParse('$value');
        if (level != null && level > 0) clean[key] = math.min(level, 3);
      case 'list':
        if (value == 'ordered') {
          clean[key] = 'ordered';
        } else if (value != null) {
          clean[key] = 'bullet';
        }
      case 'align':
        if (const {'center', 'right', 'justify'}.contains(value)) {
          clean[key] = value;
        }
      case 'indent':
        final level = value is num ? value.toInt() : int.tryParse('$value');
        if (level != null && level > 0) clean[key] = math.min(level, 8);
    }
  });
  return clean;
}

String? cssColorToHex(Object? value) {
  if (value is! String) return null;
  final text = value.trim().toLowerCase();
  final hex = RegExp(r'^#([0-9a-f]{3}|[0-9a-f]{6})$').firstMatch(text);
  if (hex != null) {
    final digits = hex.group(1)!;
    final full = digits.length == 3
        ? digits.split('').map((c) => '$c$c').join()
        : digits;
    return '#${full.toUpperCase()}';
  }
  final rgb = RegExp(
    r'^rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)$',
  ).firstMatch(text);
  if (rgb == null) return null;
  final alpha = double.tryParse(rgb.group(4) ?? '1') ?? 1;
  if (alpha == 0) return null;
  final channels = [1, 2, 3].map((i) => int.parse(rgb.group(i)!).clamp(0, 255));
  return '#${channels.map((c) => c.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';
}

String? cssSizeToPoints(Object? value) {
  if (value is num) return _format(value.toDouble());
  if (value is! String) return null;
  final match = RegExp(
    r'^([\d.]+)\s*(px|pt|em|rem)?$',
  ).firstMatch(value.trim());
  final number = double.tryParse(match?.group(1) ?? '');
  if (number == null) return null;
  final points = switch (match!.group(2)) {
    'px' => number * 0.75,
    'em' || 'rem' => number * 12,
    _ => number,
  };
  if (points < 6 || points > 96) return null;
  return _format((points * 2).round() / 2);
}

String _format(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();
