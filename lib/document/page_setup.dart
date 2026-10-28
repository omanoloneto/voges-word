import 'package:flutter/painting.dart';

class PaperSize {
  const PaperSize(this.name, this.width, this.height, this.description);

  final String name;

  /// Retrato, em pontos.
  final double width;
  final double height;
  final String description;

  bool matches(double width, double height) =>
      ((this.width - width).abs() < 2 && (this.height - height).abs() < 2) ||
      ((this.width - height).abs() < 2 && (this.height - width).abs() < 2);
}

const paperSizes = [
  PaperSize('A4', 595.3, 841.9, '21 × 29,7 cm'),
  PaperSize('Carta', 612, 792, '21,6 × 27,9 cm'),
  PaperSize('Ofício', 612, 1008, '21,6 × 35,6 cm'),
  PaperSize('A5', 419.5, 595.3, '14,8 × 21 cm'),
];

class MarginPreset {
  const MarginPreset(this.name, this.margins, this.description);

  final String name;

  /// Em pontos (1 cm = 28,35 pt).
  final EdgeInsets margins;
  final String description;

  bool matches(EdgeInsets other) =>
      (margins.left - other.left).abs() < 1 &&
      (margins.top - other.top).abs() < 1 &&
      (margins.right - other.right).abs() < 1 &&
      (margins.bottom - other.bottom).abs() < 1;
}

const marginPresets = [
  MarginPreset(
    'Normal',
    EdgeInsets.fromLTRB(85.05, 70.85, 85.05, 70.85),
    'Superior e inferior 2,5 cm · laterais 3 cm',
  ),
  MarginPreset(
    'ABNT',
    EdgeInsets.fromLTRB(85.05, 85.05, 56.7, 56.7),
    'Superior e esquerda 3 cm · inferior e direita 2 cm',
  ),
  MarginPreset('Estreita', EdgeInsets.all(36), '1,27 cm em todos os lados'),
  MarginPreset(
    'Moderada',
    EdgeInsets.fromLTRB(54.15, 72, 54.15, 72),
    'Superior e inferior 2,54 cm · laterais 1,91 cm',
  ),
  MarginPreset(
    'Larga',
    EdgeInsets.fromLTRB(144, 72, 144, 72),
    'Superior e inferior 2,54 cm · laterais 5,08 cm',
  ),
];
