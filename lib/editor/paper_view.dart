import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'editor_factory.dart';
import 'editor_session.dart';
import 'paper_styles.dart';

/// Folha branca centralizada no tamanho da página do documento.
class PaperView extends StatefulWidget {
  const PaperView({
    required this.session,
    required this.zoom,
    required this.focusNode,
    required this.scrollController,
    required this.editorKey,
    required this.onFind,
    required this.onInsertImage,
    required this.onEditLink,
    super.key,
  });

  final EditorSession session;
  final double zoom;
  final FocusNode focusNode;
  final ScrollController scrollController;
  final GlobalKey<EditorState> editorKey;
  final VoidCallback onFind;
  final VoidCallback onInsertImage;
  final VoidCallback onEditLink;

  @override
  State<PaperView> createState() => _PaperViewState();
}

class _PaperViewState extends State<PaperView> {
  EditorFactory? _factory;
  Object? _factoryKey;
  final _paperFocus = FocusNode(canRequestFocus: false, skipTraversal: true);

  @override
  void dispose() {
    _paperFocus.dispose();
    super.dispose();
  }

  EditorFactory _factoryFor(double contentWidth) {
    final key = (widget.session.generation, widget.zoom, contentWidth);
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
      );
    }
    return _factory!;
  }

  @override
  Widget build(BuildContext context) {
    final look = widget.session.look;
    final scale = pointsToPixels * widget.zoom;
    final colors = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final pageWidth = look.pageWidth * scale;
        final compact = constraints.maxWidth < pageWidth + 32;
        final sheetWidth = compact ? constraints.maxWidth : pageWidth;
        final margins = compact
            ? const EdgeInsets.fromLTRB(16, 20, 16, 48)
            : EdgeInsets.fromLTRB(
                look.margins.left * scale,
                look.margins.top * scale,
                look.margins.right * scale,
                look.margins.bottom * scale,
              );
        final factory = _factoryFor(sheetWidth - margins.horizontal);
        final controller = widget.session.controller;

        return Focus(
          focusNode: _paperFocus,
          child: ColoredBox(
            color: colors.surfaceContainerHighest,
            child: Stack(
              children: [
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
                      padding: margins,
                      maxContentWidth: sheetWidth,
                      scrollable: true,
                      expands: true,
                      autoFocus: true,
                      placeholder: 'Comece a escrever…',
                      editorKey: widget.editorKey,
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
