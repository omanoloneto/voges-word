import 'package:flutter/painting.dart';

enum PaperName { a4, letter, legal, a5 }

class PaperSize {
  const PaperSize(this.name, this.width, this.height);

  final PaperName name;

  /// Portrait, in points.
  final double width;
  final double height;

  bool matches(double width, double height) =>
      ((this.width - width).abs() < 2 && (this.height - height).abs() < 2) ||
      ((this.width - height).abs() < 2 && (this.height - width).abs() < 2);
}

const paperSizes = [
  PaperSize(PaperName.a4, 595.3, 841.9),
  PaperSize(PaperName.letter, 612, 792),
  PaperSize(PaperName.legal, 612, 1008),
  PaperSize(PaperName.a5, 419.5, 595.3),
];

enum MarginPresetName { normal, abnt, narrow, moderate, wide }

class MarginPreset {
  const MarginPreset(this.name, this.margins);

  final MarginPresetName name;

  /// In points (1 cm = 28.35 pt).
  final EdgeInsets margins;

  bool matches(EdgeInsets other) =>
      (margins.left - other.left).abs() < 1 &&
      (margins.top - other.top).abs() < 1 &&
      (margins.right - other.right).abs() < 1 &&
      (margins.bottom - other.bottom).abs() < 1;
}

const marginPresets = [
  MarginPreset(
    MarginPresetName.normal,
    EdgeInsets.fromLTRB(85.05, 70.85, 85.05, 70.85),
  ),
  MarginPreset(
    MarginPresetName.abnt,
    EdgeInsets.fromLTRB(85.05, 85.05, 56.7, 56.7),
  ),
  MarginPreset(MarginPresetName.narrow, EdgeInsets.all(36)),
  MarginPreset(
    MarginPresetName.moderate,
    EdgeInsets.fromLTRB(54.15, 72, 54.15, 72),
  ),
  MarginPreset(MarginPresetName.wide, EdgeInsets.fromLTRB(144, 72, 144, 72)),
];
