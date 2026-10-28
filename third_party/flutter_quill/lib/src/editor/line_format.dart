import 'package:flutter/foundation.dart';

import '../document/nodes/line.dart';

/// Voges Word: espaçamento e recuos próprios de um parágrafo, nas mesmas
/// unidades do texto (o editor aplica o TextScaler).
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

  /// Recuo da primeira linha; só valores positivos são desenhados.
  final double firstLine;
}

typedef LineFormatBuilder = LineFormat? Function(Line line);
