import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../document/document_look.dart';
import '../document/embeds.dart';

const pointsToPixels = 96 / 72;

/// Word's "single" spacing is about 1.17 times the font size.
const naturalLineHeight = 1.17;

const paperTextColor = Color(0xFF000000);

const linkColor = Color(0xFF0563C1);

/// Editor styles in points; zoom comes from the TextScaler and the spacing.
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

/// Indents of 1.27 cm per level, like Word; lists get room for the marker.
HorizontalSpacing _indentWidth(Block block, double scale) {
  final attributes = block.style.attributes;
  final level = (attributes[Attribute.indent.key]?.value as int?) ?? 0;
  final isList = attributes.containsKey(Attribute.list.key);
  return HorizontalSpacing((36 * level + (isList ? 36 : 0)) * scale, 0);
}

/// Each paragraph's spacing and indents as in the file. Lists follow the
/// block's spacing, like Word's List Paragraph style.
LineFormat? paragraphFormat(Line line, DocumentLook look) {
  final attributes = line.style.attributes;
  if (attributes.containsKey(Attribute.list.key) || _isBlockEmbed(line)) {
    return null;
  }
  final level = (attributes[Attribute.header.key]?.value as num?)?.toInt();
  final base = level == null ? look.body : look.heading(level);
  double value(String key, double fallback) =>
      (attributes[key]?.value as num?)?.toDouble() ?? fallback;

  var before = value(HiddenAttributes.spaceBefore, base.spaceBefore);
  var after = value(HiddenAttributes.spaceAfter, base.spaceAfter);
  final group = attributes[HiddenAttributes.contextualGroup]?.value;
  if (group != null) {
    if (_contextualGroup(_neighbor(line, before: true)) == group) before = 0;
    if (_contextualGroup(_neighbor(line, before: false)) == group) after = 0;
  }
  return LineFormat(
    spaceBefore: before,
    spaceAfter: after,
    indentRight: value(HiddenAttributes.indentRight, base.indentRight),
    firstLine: value(HiddenAttributes.firstLine, base.firstLine),
  );
}

/// Tables and other blocks do not inherit paragraph indents, as in Word.
bool _isBlockEmbed(Line line) =>
    line.childCount == 1 &&
    line.children.single is Embed &&
    EmbedTypes.blockLevel.contains((line.children.single as Embed).value.type);

Object? _contextualGroup(Line? line) =>
    line?.style.attributes[HiddenAttributes.contextualGroup]?.value;

/// Neighboring paragraph, across block boundaries (lists, alignment).
Line? _neighbor(Line line, {required bool before}) {
  final parent = line.parent;
  final sibling =
      (before ? line.previous : line.next) ??
      (parent is Block ? (before ? parent.previous : parent.next) : null);
  return switch (sibling) {
    Line() => sibling,
    Block() =>
      (before ? sibling.children.last : sibling.children.first) as Line,
    _ => null,
  };
}

/// Line spacing outside the editor's four preset values.
TextStyle lineHeightStyle(Attribute attribute) {
  if (attribute.key != Attribute.lineHeight.key) return const TextStyle();
  final value = (attribute.value as num?)?.toDouble();
  return value == null
      ? const TextStyle()
      : TextStyle(height: value * naturalLineHeight);
}
