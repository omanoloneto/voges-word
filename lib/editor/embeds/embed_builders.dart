import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../docx/image_formats.dart';
import '../../document/embeds.dart';

const _guideColor = Color(0xFF9E9E9E);

class ImageEmbedBuilder extends EmbedBuilder {
  const ImageEmbedBuilder();

  @override
  String get key => EmbedTypes.image;

  @override
  bool get expanded => false;

  @override
  String toPlainText(Embed node) => '';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final node = embedContext.node;
    double? sizeOf(String key) {
      final value = double.tryParse(
        '${node.style.attributes[key]?.value ?? ''}',
      );
      return value == null || value <= 0 ? null : value;
    }

    return EmbeddedImage(
      source: node.value.data as String,
      width: sizeOf(Attribute.width.key),
      height: sizeOf(Attribute.height.key),
    );
  }
}

class EmbeddedImage extends StatelessWidget {
  const EmbeddedImage({
    required this.source,
    this.width,
    this.height,
    super.key,
  });

  final String source;

  /// Tamanho em pontos; o texto ao redor já aplica o zoom aos embutidos.
  final double? width;
  final double? height;

  static final _cache = <String, ({Uint8List bytes, String mime})?>{};

  static ({Uint8List bytes, String mime})? _decode(String source) {
    if (_cache.containsKey(source)) {
      final cached = _cache.remove(source);
      _cache[source] = cached;
      return cached;
    }
    final decoded = decodeDataUri(source);
    _cache[source] = decoded;
    if (_cache.length > 48) _cache.remove(_cache.keys.first);
    return decoded;
  }

  @override
  Widget build(BuildContext context) {
    final decoded = _decode(source);
    final pixels = decoded == null ? null : imagePixelSize(decoded.bytes);
    final width = this.width ?? (pixels?.width ?? 200) * 0.75;
    final naturalRatio = pixels == null || pixels.height == 0
        ? 4 / 3
        : pixels.width / pixels.height;
    final height = this.height ?? width / naturalRatio;
    final Widget image;
    if (decoded != null && isDisplayable(decoded.mime)) {
      image = Image.memory(
        decoded.bytes,
        fit: BoxFit.fill,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) =>
            _placeholder(decoded.mime),
      );
    } else {
      image = _placeholder(decoded?.mime);
    }
    return Semantics(
      image: true,
      label: 'Imagem',
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: AspectRatio(aspectRatio: width / height, child: image),
      ),
    );
  }

  Widget _placeholder(String? mime) {
    final format = mime == null ? '' : extensionForMime(mime).toUpperCase();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF2F2F2),
        border: Border.all(color: _guideColor, width: 0.5),
      ),
      child: Center(
        child: Tooltip(
          message:
              'Imagem $format: aparece no Word, mas não aqui. É mantida ao salvar.',
          child: const Icon(Icons.image_outlined, color: _guideColor),
        ),
      ),
    );
  }
}

class PageBreakEmbedBuilder extends EmbedBuilder {
  const PageBreakEmbedBuilder();

  @override
  String get key => EmbedTypes.pageBreak;

  @override
  bool get expanded => false;

  @override
  String toPlainText(Embed node) => '\n';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) =>
      const _BreakMarker(label: 'Quebra de página');
}

class SectionBreakEmbedBuilder extends EmbedBuilder {
  const SectionBreakEmbedBuilder();

  @override
  String get key => EmbedTypes.sectionBreak;

  @override
  String toPlainText(Embed node) => '\n';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) =>
      const _BreakMarker(label: 'Quebra de seção');
}

class _BreakMarker extends StatelessWidget {
  const _BreakMarker({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      child: SizedBox(
        width: double.infinity,
        height: 22,
        child: CustomPaint(
          painter: const _DashedLinePainter(),
          child: Center(
            child: ColoredBox(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  label,
                  textScaler: TextScaler.noScaling,
                  style: const TextStyle(
                    fontSize: 11,
                    color: _guideColor,
                    fontStyle: FontStyle.normal,
                    fontWeight: FontWeight.normal,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  const _DashedLinePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _guideColor
      ..strokeWidth = 1;
    final y = size.height / 2;
    for (var x = 0.0; x < size.width; x += 6) {
      canvas.drawLine(Offset(x, y), Offset(x + 3, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class OpaqueInlineEmbedBuilder extends EmbedBuilder {
  const OpaqueInlineEmbedBuilder();

  @override
  String get key => EmbedTypes.opaqueInline;

  @override
  bool get expanded => false;

  @override
  WidgetSpan buildWidgetSpan(Widget widget) => WidgetSpan(
    child: widget,
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
  );

  @override
  String toPlainText(Embed node) => OpaqueContent.decode(node.value.data).text;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final content = OpaqueContent.decode(embedContext.node.value.data);
    if (content.hidden) return const SizedBox.shrink();
    final style = embedContext.textStyle;
    final size = style.fontSize ?? 12;
    if (content.label == 'nota') {
      return Transform.translate(
        offset: Offset(0, -size * 0.35),
        child: Text(
          content.text,
          textScaler: TextScaler.noScaling,
          style: style.copyWith(fontSize: size * 0.65),
        ),
      );
    }
    final text = content.text.isNotEmpty
        ? content.text
        : '[${content.label ?? 'objeto'}]';
    return Tooltip(
      message: 'Conteúdo do Word mantido como está ao salvar',
      child: ColoredBox(
        color: const Color(0xFFE6E6E6),
        child: Text(text, style: style, textScaler: TextScaler.noScaling),
      ),
    );
  }
}

/// Campo de número da página: no cabeçalho vira o número de cada folha.
class PageNumberEmbedBuilder extends EmbedBuilder {
  const PageNumberEmbedBuilder();

  @override
  String get key => EmbedTypes.pageNumber;

  @override
  bool get expanded => false;

  @override
  WidgetSpan buildWidgetSpan(Widget widget) => WidgetSpan(
    child: widget,
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
  );

  @override
  String toPlainText(Embed node) => '#';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    return Tooltip(
      message: 'Número da página',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFDCE7FB),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Text(
            '#',
            style: embedContext.textStyle,
            textScaler: TextScaler.noScaling,
          ),
        ),
      ),
    );
  }
}

class OpaqueBlockEmbedBuilder extends EmbedBuilder {
  const OpaqueBlockEmbedBuilder();

  @override
  String get key => EmbedTypes.opaqueBlock;

  @override
  String toPlainText(Embed node) => OpaqueContent.decode(node.value.data).text;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final content = OpaqueContent.decode(embedContext.node.value.data);
    final style = embedContext.textStyle;
    return Semantics(
      label: content.label,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFBDBDBD)),
          color: const Color(0xFFF7F7F7),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${content.label ?? 'Conteúdo especial'} · mantido como está ao salvar',
              textScaler: TextScaler.noScaling,
              style: const TextStyle(fontSize: 11, color: Color(0xFF757575)),
            ),
            if (content.text.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(content.text, style: style),
            ],
          ],
        ),
      ),
    );
  }
}

class UnknownEmbedBuilder extends EmbedBuilder {
  const UnknownEmbedBuilder();

  @override
  String get key => 'unknown';

  @override
  bool get expanded => false;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) =>
      const Tooltip(
        message: 'Conteúdo colado que o Voges Word não salva',
        child: Icon(Icons.help_outline, size: 16, color: _guideColor),
      );
}
