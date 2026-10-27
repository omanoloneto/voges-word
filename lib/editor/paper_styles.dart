import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../document/document_look.dart';

const pointsToPixels = 96 / 72;

/// O "simples" do Word equivale a cerca de 1,17 vez o tamanho da fonte.
const naturalLineHeight = 1.17;

const paperTextColor = Color(0xFF000000);

const linkColor = Color(0xFF0563C1);

/// Estilos do editor em pontos; o zoom vem do TextScaler e dos espaçamentos.
DefaultStyles paperStyles(DocumentLook look, double scale) {
  TextStyle textOf(TextLook text, {double? lineSpacing}) => TextStyle(
    fontFamily: text.fontFamily,
    fontSize: text.fontSize,
    color: text.color,
    fontWeight: text.bold ? FontWeight.bold : FontWeight.normal,
    fontStyle: text.italic ? FontStyle.italic : FontStyle.normal,
    height: (lineSpacing ?? look.lineSpacing) * naturalLineHeight,
    decoration: TextDecoration.none,
    letterSpacing: 0,
  );

  VerticalSpacing spacing(double before, double after) =>
      VerticalSpacing(before * scale, after * scale);

  DefaultTextBlockStyle block(
    TextStyle style,
    VerticalSpacing vertical, [
    VerticalSpacing line = VerticalSpacing.zero,
  ]) => DefaultTextBlockStyle(
    style,
    HorizontalSpacing.zero,
    vertical,
    line,
    null,
  );

  final body = textOf(look.body);
  final paragraphSpacing = spacing(look.body.spaceBefore, look.body.spaceAfter);

  DefaultTextBlockStyle heading(int level) {
    final text = look.heading(level);
    return block(
      textOf(text, lineSpacing: 1),
      spacing(text.spaceBefore, text.spaceAfter),
    );
  }

  DefaultTextBlockStyle lineHeight(double multiple) => block(
    body.copyWith(height: multiple * naturalLineHeight),
    VerticalSpacing.zero,
  );

  return DefaultStyles(
    h1: heading(1),
    h2: heading(2),
    h3: heading(3),
    h4: heading(4),
    h5: heading(5),
    h6: heading(6),
    paragraph: block(body, paragraphSpacing),
    lineHeightNormal: lineHeight(1),
    lineHeightTight: lineHeight(1.15),
    lineHeightOneAndHalf: lineHeight(1.5),
    lineHeightDouble: lineHeight(2),
    bold: const TextStyle(fontWeight: FontWeight.bold),
    italic: const TextStyle(fontStyle: FontStyle.italic),
    underline: const TextStyle(decoration: TextDecoration.underline),
    strikeThrough: const TextStyle(decoration: TextDecoration.lineThrough),
    link: const TextStyle(
      color: linkColor,
      decoration: TextDecoration.underline,
    ),
    color: paperTextColor,
    placeHolder: block(
      body.copyWith(color: const Color(0x61000000)),
      paragraphSpacing,
    ),
    lists: DefaultListBlockStyle(
      body,
      HorizontalSpacing.zero,
      spacing(0, look.body.spaceAfter),
      VerticalSpacing.zero,
      null,
      null,
      indentWidthBuilder: (block, context, count, numberPointWidth) =>
          _indentWidth(block, scale),
      numberPointWidthBuilder: (fontSize, count) =>
          ('$count'.length > 2 ? 28 : 18) * scale,
    ),
    leading: block(body, VerticalSpacing.zero),
    indent: block(body, VerticalSpacing.zero, paragraphSpacing),
    align: block(body, VerticalSpacing.zero, paragraphSpacing),
    quote: block(
      body.copyWith(color: const Color(0xFF555555)),
      paragraphSpacing,
      paragraphSpacing,
    ),
    code: block(body.copyWith(fontFamily: 'Courier New'), paragraphSpacing),
  );
}

/// Recuos de 1,27 cm por nível, como o Word; listas ganham o espaço do marcador.
HorizontalSpacing _indentWidth(Block block, double scale) {
  final attributes = block.style.attributes;
  final level = (attributes[Attribute.indent.key]?.value as int?) ?? 0;
  final isList = attributes.containsKey(Attribute.list.key);
  return HorizontalSpacing((36 * level + (isList ? 36 : 0)) * scale, 0);
}

/// Espaçamento de linha fora dos quatro valores prontos do editor.
TextStyle lineHeightStyle(Attribute attribute) {
  if (attribute.key != Attribute.lineHeight.key) return const TextStyle();
  final value = (attribute.value as num?)?.toDouble();
  return value == null
      ? const TextStyle()
      : TextStyle(height: value * naturalLineHeight);
}
