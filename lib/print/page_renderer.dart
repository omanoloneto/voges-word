import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../document/embeds.dart';
import '../editor/editor_factory.dart';
import '../editor/editor_session.dart';
import '../editor/embeds/embed_builders.dart';
import '../editor/header_footer_painter.dart';
import '../editor/pagination.dart';
import '../editor/paper_styles.dart';
import 'pdf_document.dart';

/// Draws the document off-screen, in pages and just like the editor, and
/// builds the PDF page by page.
Future<Uint8List> documentPdf(
  BuildContext context,
  EditorSession session, {
  ValueChanged<(int page, int count)>? onProgress,
}) async {
  final look = session.look;
  const scale = pointsToPixels;
  final pageWidth = look.pageWidth * scale;
  final decorations = HeaderFooterPainter(session.headersFooters, look);
  final cellFocus = FocusNode(canRequestFocus: false, skipTraversal: true);
  final focusNode = FocusNode(canRequestFocus: false);
  final scrollController = ScrollController();
  final controller = QuillController(
    document: Document.fromDelta(session.controller.document.toDelta()),
    selection: const TextSelection.collapsed(offset: 0),
    readOnly: true,
  );
  final focusManager = FocusManager();
  final view = View.of(context);
  final theme = Theme.of(context);
  final pixelRatio = MediaQuery.devicePixelRatioOf(context);

  try {
    await decorations.ready;
    if (!context.mounted) throw StateError('Screen closed');
    await _precacheImages(context, session);
    if (!context.mounted) throw StateError('Screen closed');

    final layout = pageLayoutFor(look, scale, decorations: decorations);
    final factory = EditorFactory(
      look: look,
      zoom: 1,
      tables: session.tables,
      contentWidth: look.contentWidth * scale,
      onCellFocused: (_, _) {},
      onFind: () {},
      onInsertImage: () {},
      onEditLink: () {},
      cellFocusParent: cellFocus,
    );
    final editor = Localizations.override(
      context: context,
      child: MediaQuery(
        data: MediaQueryData(
          size: Size(pageWidth, _maxHeight),
          // The editor's ratio: pictures draw from the ones it decoded.
          devicePixelRatio: pixelRatio,
          textScaler: const TextScaler.linear(scale),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Theme(
            data: theme,
            child: Material(
              type: MaterialType.transparency,
              child: QuillEditor(
                controller: controller,
                focusNode: focusNode,
                scrollController: scrollController,
                config: factory
                    .config(
                      controller,
                      padding: EdgeInsets.fromLTRB(
                        look.margins.left * scale,
                        look.margins.top * scale + pageGap,
                        look.margins.right * scale,
                        look.margins.bottom * scale + pageGap,
                      ),
                      maxContentWidth: pageWidth,
                      pageLayout: layout,
                    )
                    .copyWith(showCursor: false),
              ),
            ),
          ),
        ),
      ),
    );

    final boundary = _PageBoundary();
    final topLeft = RenderPositionedBox(
      alignment: Alignment.topLeft,
      child: boundary,
    );
    final renderView = RenderView(
      view: view,
      configuration: ViewConfiguration(
        logicalConstraints: BoxConstraints(
          maxWidth: pageWidth,
          maxHeight: _maxHeight,
        ),
        physicalConstraints: BoxConstraints(
          maxWidth: pageWidth,
          maxHeight: _maxHeight,
        ),
        devicePixelRatio: 1,
      ),
      child: topLeft,
    );
    final pipeline = PipelineOwner()..rootNode = renderView;
    renderView.prepareInitialFrame();
    final buildOwner = BuildOwner(focusManager: focusManager);
    final root = RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
      child: editor,
    ).attachToRenderTree(buildOwner);

    void frame() {
      buildOwner
        ..buildScope(root)
        ..finalizeTree();
      pipeline
        ..flushLayout()
        ..flushCompositingBits()
        ..flushPaint();
    }

    try {
      frame();
      await Future<void>.delayed(Duration.zero);
      frame();

      // A GlobalKey only sees the main tree; here the search is direct.
      final renderEditor = _find<RenderEditor>(boundary)!;
      final origin = renderEditor.localToGlobal(
        Offset.zero,
        ancestor: boundary,
      );
      final left = origin.dx + (renderEditor.size.width - pageWidth) / 2;
      final lines = visualTextLines(boundary);
      final count = renderEditor.pageCount;
      final pdf = PdfBuilder();
      for (var page = 0; page < count; page++) {
        onProgress?.call((page + 1, count));
        final rect = Rect.fromLTWH(
          left,
          origin.dy + layout.pageTop(page),
          pageWidth,
          layout.pageHeight,
        );
        final image = await boundary.capture(rect, printDpi / 96);
        final rgb = await _rgbOf(image);
        pdf.addPage(
          PdfPageContent(
            size: Size(look.pageWidth, look.pageHeight),
            imageWidth: image.width,
            imageHeight: image.height,
            rgb: rgb,
            lines: [
              for (final (line, text) in lines)
                if (rect.contains(line.center))
                  (
                    Rect.fromLTRB(
                      (line.left - rect.left) / scale,
                      (line.top - rect.top) / scale,
                      (line.right - rect.left) / scale,
                      (line.bottom - rect.top) / scale,
                    ),
                    text,
                  ),
            ],
          ),
        );
        image.dispose();
        await Future<void>.delayed(Duration.zero);
      }
      return pdf.build(title: session.baseName);
    } finally {
      // Rebuilt with no child, the root unmounts the editor, whose states let
      // go of the pictures and the table cells.
      RenderObjectToWidgetAdapter<RenderBox>(
        container: boundary,
      ).attachToRenderTree(buildOwner, root);
      buildOwner
        ..buildScope(root)
        ..finalizeTree();
      pipeline
        ..rootNode = null
        ..dispose();
      for (final node in [renderView, topLeft, boundary]) {
        node.dispose();
      }
    }
  } finally {
    decorations.dispose();
    controller.dispose();
    focusNode.dispose();
    cellFocus.dispose();
    scrollController.dispose();
    focusManager.dispose();
  }
}

/// Maximum height of the drawing area, well above any real document.
const _maxHeight = 2000000.0;

Future<void> _precacheImages(BuildContext context, EditorSession session) {
  final controllers = [
    session.controller,
    for (final table in session.tables.all)
      for (final row in table.rows)
        for (final cell in row.cells) cell.controller,
  ];
  return Future.wait([
    for (final controller in controllers)
      for (final op in controller.document.toDelta().toList())
        if (op.data case {EmbedTypes.image: final String source})
          EmbeddedImage.fromAttributes(source, op.attributes).precache(context),
  ]);
}

Future<Uint8List> _rgbOf(ui.Image image) async {
  final rgba = (await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!.buffer.asUint8List();
  final pixels = image.width * image.height;
  final rgb = Uint8List(pixels * 3);
  for (var i = 0, j = 0; i < pixels; i++, j += 4) {
    // A transparent background becomes white paper.
    final alpha = rgba[j + 3];
    final white = 255 - alpha;
    rgb[i * 3] = math.min(255, rgba[j] + white);
    rgb[i * 3 + 1] = math.min(255, rgba[j + 1] + white);
    rgb[i * 3 + 2] = math.min(255, rgba[j + 2] + white);
  }
  return rgb;
}

T? _find<T extends RenderObject>(RenderObject node) {
  if (node is T) return node;
  T? found;
  node.visitChildren((child) => found ??= _find<T>(child));
  return found;
}

class _PageBoundary extends RenderRepaintBoundary {
  Future<ui.Image> capture(Rect rect, double pixelRatio) =>
      (layer! as OffsetLayer).toImage(rect, pixelRatio: pixelRatio);
}
