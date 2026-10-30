import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../docx/image_formats.dart';
import '../document/document_look.dart';
import '../document/embeds.dart';
import '../document/headers_footers.dart';
import 'paper_styles.dart';
import 'picture_decoding.dart';

/// Paints the header and footer on each page, in points: text, page number
/// and images (anchored logos at the position Word uses).
class HeaderFooterPainter extends ChangeNotifier {
  HeaderFooterPainter(this.stories, this.look) {
    ready = _decodeImages();
  }

  /// Completes when the header and footer images are ready.
  late final Future<void> ready;

  final HeadersFooters stories;
  final DocumentLook look;
  final _images = <String, ui.Image>{};
  final _layouts = <(HeaderFooterStory, int, int), _StoryLayout>{};
  var _disposed = false;

  Iterable<HeaderFooterStory> get _all => [
    ...stories.headers.values,
    ...stories.footers.values,
  ];

  /// How far down the tallest header reaches, from the top of the page.
  double get headerBottom => stories.headers.values.fold(
    0,
    (bottom, story) => math.max(
      bottom,
      stories.headerDistance + _layoutFor(story, 1, 1).height,
    ),
  );

  /// How far up the tallest footer reaches, from the bottom of the page.
  double get footerTop => stories.footers.values.fold(
    0,
    (top, story) =>
        math.max(top, stories.footerDistance + _layoutFor(story, 1, 1).height),
  );

  void paint(Canvas canvas, Rect page, int index, int count) {
    final header = stories.headerFor(index);
    final footer = stories.footerFor(index);
    if (header == null && footer == null) return;
    canvas
      ..save()
      ..translate(page.left, page.top)
      ..scale(page.width / look.pageWidth);
    if (header != null) {
      _paint(
        canvas,
        _layoutFor(header, index + 1, count),
        stories.headerDistance,
      );
    }
    if (footer != null) {
      final layout = _layoutFor(footer, index + 1, count);
      _paint(
        canvas,
        layout,
        look.pageHeight - stories.footerDistance - layout.height,
      );
    }
    canvas.restore();
  }

  void _paint(Canvas canvas, _StoryLayout layout, double top) {
    final paint = Paint()..filterQuality = FilterQuality.medium;
    for (final anchor in layout.anchors) {
      final image = _images[anchor.source];
      if (image == null) continue;
      _drawImage(canvas, image, anchor.rect(look, top), paint);
    }
    for (final text in layout.texts) {
      final origin = text.offset.translate(0, top);
      text.painter.paint(canvas, origin);
      final boxes = text.painter.inlinePlaceholderBoxes ?? const [];
      for (var i = 0; i < math.min(boxes.length, text.images.length); i++) {
        final image = _images[text.images[i]];
        if (image != null) {
          _drawImage(canvas, image, boxes[i].toRect().shift(origin), paint);
        }
      }
    }
  }

  static void _drawImage(
    Canvas canvas,
    ui.Image image,
    Rect rect,
    Paint paint,
  ) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      paint,
    );
  }

  _StoryLayout _layoutFor(HeaderFooterStory story, int page, int count) {
    final dynamic = _hasFields(story);
    final key = (story, dynamic ? page : 0, dynamic ? count : 0);
    if (_layouts.length > 200) _layouts.clear();
    return _layouts[key] ??= _StoryLayout.build(story, look, page, count);
  }

  static bool _hasFields(HeaderFooterStory story) => story.delta.toList().any(
    (op) => op.data is Map && _isField((op.data as Map).keys.first as String),
  );

  static bool _isField(String type) =>
      type == EmbedTypes.pageNumber || type == EmbedTypes.opaqueInline;

  /// Each picture is decoded once, at the largest size it is drawn.
  Future<void> _decodeImages() async {
    final sizes = <String, Size>{};
    for (final story in _all) {
      for (final op in story.delta.toList()) {
        if (op.data case {EmbedTypes.image: final String source}) {
          final size = _imageSize(op.attributes);
          final other = sizes[source] ?? Size.zero;
          sizes[source] = Size(
            math.max(size.width, other.width),
            math.max(size.height, other.height),
          );
        }
      }
    }
    final pixelRatio = _devicePixelRatio;
    for (final MapEntry(key: source, value: size) in sizes.entries) {
      final decoded = decodeDataUri(source);
      if (decoded == null || size.isEmpty) continue;
      try {
        final codec = await openPicture(
          decoded.bytes,
          drawnSize: drawnPictureSize(size.width, size.height, pixelRatio),
        );
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (_disposed) {
          frame.image.dispose();
          return;
        }
        _images[source] = frame.image;
        notifyListeners();
      } catch (_) {
        continue;
      }
    }
  }

  /// The sharpest screen's: the pictures stay sharp when the window moves to
  /// another screen.
  static double get _devicePixelRatio {
    final platform = PaintingBinding.instance.platformDispatcher;
    return [
      for (final view in platform.views) view.devicePixelRatio,
      for (final display in platform.displays) display.devicePixelRatio,
    ].fold(1.0, math.max);
  }

  @override
  void dispose() {
    _disposed = true;
    for (final image in _images.values) {
      image.dispose();
    }
    super.dispose();
  }
}

/// Size in points from the image embed's attributes; nothing is drawn
/// without one.
Size _imageSize(Map<String, dynamic>? attributes) => Size(
  double.tryParse('${attributes?[Attribute.width.key]}') ?? 0,
  double.tryParse('${attributes?[Attribute.height.key]}') ?? 0,
);

class _PlacedText {
  const _PlacedText(this.painter, this.offset, this.images);

  final TextPainter painter;
  final Offset offset;

  /// Inline images, in the order of their placeholders.
  final List<String> images;
}

/// Floating image: positioned by the wp:anchor kept in the hidden attribute.
class _Anchor {
  const _Anchor(this.source, this.xml, this.size, this.paragraphTop);

  final String source;
  final String xml;
  final Size size;
  final double paragraphTop;

  Rect rect(DocumentLook look, double storyTop) {
    final margins = look.margins;
    final horizontal = _position(xml, 'positionH');
    final vertical = _position(xml, 'positionV');
    final (left, right) = switch (horizontal.from) {
      'page' => (0.0, look.pageWidth),
      'leftMargin' => (0.0, margins.left),
      'rightMargin' => (look.pageWidth - margins.right, look.pageWidth),
      _ => (margins.left, look.pageWidth - margins.right),
    };
    final (top, bottom) = switch (vertical.from) {
      'page' => (0.0, look.pageHeight),
      'margin' => (margins.top, look.pageHeight - margins.bottom),
      'topMargin' => (0.0, margins.top),
      'bottomMargin' => (look.pageHeight - margins.bottom, look.pageHeight),
      _ => (storyTop + paragraphTop, storyTop + paragraphTop + size.height),
    };
    final x = switch (horizontal.align) {
      'center' => (left + right - size.width) / 2,
      'right' || 'outside' => right - size.width,
      'left' || 'inside' => left,
      _ => left + horizontal.offset,
    };
    final y = switch (vertical.align) {
      'center' => (top + bottom - size.height) / 2,
      'bottom' || 'outside' => bottom - size.height,
      'top' || 'inside' => top,
      _ => top + vertical.offset,
    };
    return Offset(x, y) & size;
  }

  static ({String from, String? align, double offset}) _position(
    String xml,
    String axis,
  ) {
    final match = RegExp(
      '<wp:$axis\\b[^>]*relativeFrom="(\\w+)"[^>]*>(.*?)</wp:$axis>',
      dotAll: true,
    ).firstMatch(xml);
    final body = match?.group(2) ?? '';
    final align = RegExp(r'<wp:align>(\w+)</wp:align>').firstMatch(body);
    final offset = RegExp(
      r'<wp:posOffset>(-?\d+)</wp:posOffset>',
    ).firstMatch(body);
    return (
      from: match?.group(1) ?? 'margin',
      align: align?.group(1),
      offset: (int.tryParse(offset?.group(1) ?? '') ?? 0) / 12700,
    );
  }
}

class _StoryLayout {
  _StoryLayout(this.texts, this.anchors, this.height);

  /// Paragraphs in points, with left, center and right tab stops as in Word's
  /// Header style.
  factory _StoryLayout.build(
    HeaderFooterStory story,
    DocumentLook look,
    int page,
    int count,
  ) {
    final width = look.contentWidth;
    final left = look.margins.left;
    final texts = <_PlacedText>[];
    final anchors = <_Anchor>[];
    var y = 0.0;
    for (final line in _lines(Document.fromDelta(story.delta))) {
      final format = paragraphFormat(line, look);
      y += format?.spaceBefore ?? 0;
      final base = _baseStyle(line, look);
      final segments = <List<InlineSpan>>[[]];
      final images = <List<String>>[[]];
      for (final node in line.children) {
        final style = base.merge(_runStyle(node.style.attributes));
        if (node is QuillText) {
          final parts = node.value.replaceAll(' ', '\n').split('\t');
          for (var i = 0; i < parts.length; i++) {
            if (i > 0) {
              segments.add([]);
              images.add([]);
            }
            if (parts[i].isNotEmpty) {
              segments.last.add(TextSpan(text: parts[i], style: style));
            }
          }
        } else if (node is Embed) {
          final value = node.value;
          switch (value.type) {
            case EmbedTypes.pageNumber:
              segments.last.add(TextSpan(text: '$page', style: style));
            case EmbedTypes.opaqueInline:
              final content = OpaqueContent.decode(value.data);
              final text = switch (fieldNameOf(content.xml)) {
                'PAGE' => '$page',
                'NUMPAGES' || 'SECTIONPAGES' => '$count',
                _ => content.hidden ? '' : content.text,
              };
              if (text.isNotEmpty) {
                segments.last.add(TextSpan(text: text, style: style));
              }
            case EmbedTypes.image:
              final attributes = node.style.attributes;
              final size = _imageSize(node.style.toJson());
              final xml =
                  '${attributes[HiddenAttributes.drawing]?.value ?? ''}';
              final source = value.data as String;
              if (xml.contains('<wp:anchor')) {
                anchors.add(_Anchor(source, xml, size, y));
              } else {
                segments.last.add(
                  WidgetSpan(
                    child: SizedBox.fromSize(size: size),
                    alignment: PlaceholderAlignment.bottom,
                  ),
                );
                images.last.add(source);
              }
          }
        }
      }

      final align = switch (line.style.attributes[Attribute.align.key]?.value) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        'justify' => TextAlign.justify,
        _ => TextAlign.left,
      };
      final placed = math.min(segments.length, 3);
      var height = 0.0;
      for (var i = 0; i < placed; i++) {
        final spans = i == placed - 1
            ? [for (final rest in segments.skip(i)) ...rest]
            : segments[i];
        final painter = TextPainter(
          text: TextSpan(
            style: base,
            children: spans.isEmpty
                ? [TextSpan(text: '​', style: base)]
                : spans,
          ),
          textAlign: placed == 1 ? align : TextAlign.left,
          textDirection: TextDirection.ltr,
        );
        final dimensions = [
          for (final span in spans)
            if (span is WidgetSpan)
              PlaceholderDimensions(
                size: _sizeOf(span.child),
                alignment: span.alignment,
              ),
        ];
        painter
          ..setPlaceholderDimensions(dimensions)
          ..layout(minWidth: placed == 1 ? width : 0, maxWidth: width);
        final x = switch (placed == 1 ? -1 : i) {
          1 => left + (width - painter.width) / 2,
          2 => left + width - painter.width,
          _ => left,
        };
        texts.add(
          _PlacedText(painter, Offset(x, y), [
            for (final list
                in images.skip(i).take(i == placed - 1 ? images.length : 1))
              ...list,
          ]),
        );
        height = math.max(height, painter.height);
      }
      y += height + (format?.spaceAfter ?? 0);
    }
    return _StoryLayout(texts, anchors, y);
  }

  final List<_PlacedText> texts;
  final List<_Anchor> anchors;
  final double height;

  static Size _sizeOf(Widget child) =>
      child is SizedBox ? Size(child.width ?? 0, child.height ?? 0) : Size.zero;

  static Iterable<Line> _lines(Document document) sync* {
    for (final node in document.root.children) {
      if (node is Line) {
        yield node;
      } else if (node is Block) {
        yield* node.children.cast<Line>();
      }
    }
  }

  static TextStyle _baseStyle(Line line, DocumentLook look) {
    final spacing =
        (line.style.attributes[Attribute.lineHeight.key]?.value as num?)
            ?.toDouble() ??
        look.lineSpacing;
    return TextStyle(
      fontFamily: look.body.fontFamily,
      fontSize: look.body.fontSize,
      color: look.body.color,
      height: spacing * naturalLineHeight,
    );
  }

  static TextStyle _runStyle(Map<String, Attribute<dynamic>> attributes) {
    Object? value(Attribute<dynamic> key) => attributes[key.key]?.value;
    final size = double.tryParse('${value(Attribute.size) ?? ''}');
    final script = value(Attribute.script);
    return TextStyle(
      fontWeight: value(Attribute.bold) == true ? FontWeight.bold : null,
      fontStyle: value(Attribute.italic) == true ? FontStyle.italic : null,
      decoration: TextDecoration.combine([
        if (value(Attribute.underline) == true) TextDecoration.underline,
        if (value(Attribute.strikeThrough) == true) TextDecoration.lineThrough,
      ]),
      fontSize: size == null
          ? null
          : script == null
          ? size
          : size * 0.65,
      fontFamily: value(Attribute.font) as String?,
      color: _color(value(Attribute.color)),
      backgroundColor: _color(value(Attribute.background)),
    );
  }

  static Color? _color(Object? value) {
    if (value is! String || !value.startsWith('#') || value.length != 7) {
      return null;
    }
    final parsed = int.tryParse(value.substring(1), radix: 16);
    return parsed == null ? null : Color(0xFF000000 | parsed);
  }
}
