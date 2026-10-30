import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../l10n/l10n.dart';
import '../spell/spell_checker.dart';
import 'editor_factory.dart';
import 'editor_session.dart';
import 'header_footer_painter.dart';
import 'pagination.dart';
import 'paper_styles.dart';

/// The document as separate pages, like Word; on narrow screens (or in
/// continuous mode) it becomes a single sheet that follows the width.
class PaperView extends StatefulWidget {
  const PaperView({
    required this.session,
    required this.zoom,
    required this.pagesView,
    required this.focusNode,
    required this.scrollController,
    required this.editorKey,
    required this.onFind,
    required this.onInsertImage,
    required this.onEditLink,
    required this.onPageCountChanged,
    this.spelling,
    super.key,
  });

  final EditorSession session;
  final double zoom;
  final bool pagesView;
  final FocusNode focusNode;
  final ScrollController scrollController;
  final GlobalKey<EditorState> editorKey;
  final VoidCallback onFind;
  final VoidCallback onInsertImage;
  final VoidCallback onEditLink;
  final ValueChanged<int> onPageCountChanged;
  final SpellChecker? spelling;

  @override
  State<PaperView> createState() => _PaperViewState();
}

class _PaperViewState extends State<PaperView> {
  EditorFactory? _factory;
  Object? _factoryKey;
  QuillPageLayout? _pageLayout;
  Object? _pageLayoutKey;
  HeaderFooterPainter? _decorations;
  final _paperFocus = FocusNode(canRequestFocus: false, skipTraversal: true);

  @override
  void dispose() {
    _paperFocus.dispose();
    _decorations?.dispose();
    super.dispose();
  }

  HeaderFooterPainter _decorationsFor(double pixelRatio) {
    final session = widget.session;
    final current = _decorations;
    if (current != null &&
        current.stories == session.headersFooters &&
        current.look == session.look) {
      return current..raisePixelRatio(pixelRatio);
    }
    final next = HeaderFooterPainter(session.headersFooters, session.look)
      ..raisePixelRatio(pixelRatio);
    WidgetsBinding.instance.addPostFrameCallback((_) => current?.dispose());
    return _decorations = next;
  }

  EditorFactory _factoryFor(double contentWidth) {
    final key = (
      widget.session.generation,
      widget.session.look,
      widget.zoom,
      contentWidth,
      widget.spelling,
    );
    if (_factory == null || _factoryKey != key) {
      _factoryKey = key;
      _factory = EditorFactory(
        look: widget.session.look,
        zoom: widget.zoom,
        tables: widget.session.tables,
        contentWidth: contentWidth,
        onCellFocused: widget.session.focusCell,
        onFind: widget.onFind,
        onInsertImage: widget.onInsertImage,
        onEditLink: widget.onEditLink,
        cellFocusParent: _paperFocus,
        spelling: widget.spelling,
      );
    }
    return _factory!;
  }

  QuillPageLayout _pageLayoutFor(double scale, double pixelRatio) {
    final decorations = _decorationsFor(pixelRatio);
    final key = (widget.session.look, scale, decorations);
    if (_pageLayout == null || _pageLayoutKey != key) {
      _pageLayoutKey = key;
      _pageLayout = pageLayoutFor(
        widget.session.look,
        scale,
        onPageCountChanged: widget.onPageCountChanged,
        decorations: decorations,
      );
    }
    return _pageLayout!;
  }

  @override
  Widget build(BuildContext context) {
    final spelling = widget.spelling;
    if (spelling == null) return _paper(context);
    return ListenableBuilder(
      listenable: spelling,
      builder: (context, _) => _paper(context),
    );
  }

  Widget _paper(BuildContext context) {
    final look = widget.session.look;
    final scale = pointsToPixels * widget.zoom;
    final colors = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final pageWidth = look.pageWidth * scale;
        final compact = constraints.maxWidth < pageWidth + 32;
        final paged = widget.pagesView && !compact;
        final sheetWidth = compact ? constraints.maxWidth : pageWidth;
        final EdgeInsets padding;
        if (compact) {
          padding = const EdgeInsets.fromLTRB(16, 20, 16, 48);
        } else {
          padding = EdgeInsets.fromLTRB(
            look.margins.left * scale,
            look.margins.top * scale + (paged ? pageGap : 0),
            look.margins.right * scale,
            look.margins.bottom * scale + (paged ? pageGap : 0),
          );
        }
        final factory = _factoryFor(sheetWidth - padding.horizontal);
        final controller = widget.session.controller;

        return Focus(
          focusNode: _paperFocus,
          child: ColoredBox(
            color: colors.surfaceContainerHighest,
            child: Stack(
              children: [
                if (!paged)
                  Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      width: sheetWidth,
                      height: constraints.maxHeight,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        boxShadow: compact
                            ? null
                            : const [
                                BoxShadow(
                                  color: Color(0x33000000),
                                  blurRadius: 8,
                                ),
                              ],
                      ),
                    ),
                  ),
                MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: QuillEditor(
                    key: ValueKey(widget.session.generation),
                    controller: controller,
                    focusNode: widget.focusNode,
                    scrollController: widget.scrollController,
                    config: factory.config(
                      controller,
                      padding: padding,
                      maxContentWidth: sheetWidth,
                      scrollable: true,
                      expands: true,
                      autoFocus: true,
                      placeholder: context.l10n.startWriting,
                      editorKey: widget.editorKey,
                      pageLayout: paged
                          ? _pageLayoutFor(
                              scale,
                              MediaQuery.devicePixelRatioOf(context),
                            )
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
