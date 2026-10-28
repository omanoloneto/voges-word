import 'package:flutter/foundation.dart';

import '../document/nodes/line.dart';

/// Voges Word: a paragraph's own spacing and indents, in the same units as
/// the text (the editor applies the TextScaler).
@immutable
class LineFormat {
  const LineFormat({
    this.spaceBefore = 0,
    this.spaceAfter = 0,
    this.indentRight = 0,
    this.firstLine = 0,
  });

  final double spaceBefore;
  final double spaceAfter;
  final double indentRight;

  /// First-line indent; only positive values are drawn.
  final double firstLine;
}

typedef LineFormatBuilder = LineFormat? Function(Line line);
