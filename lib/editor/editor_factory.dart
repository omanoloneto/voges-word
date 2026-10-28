import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../document/document_look.dart';
import '../document/embeds.dart';
import '../document/tables.dart';
import 'document_commands.dart';
import 'embeds/embed_builders.dart';
import 'embeds/table_embed.dart';
import 'paper_styles.dart';

class OpenFindIntent extends Intent {
  const OpenFindIntent();
}

class InsertImageIntent extends Intent {
  const InsertImageIntent();
}

class EditLinkIntent extends Intent {
  const EditLinkIntent();
}

class AlignIntent extends Intent {
  const AlignIntent(this.align);

  final String align;
}

bool get isApplePlatform =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

bool get isDesktopPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

SingleActivator shortcut(LogicalKeyboardKey key, {bool shift = false}) =>
    SingleActivator(
      key,
      control: !isApplePlatform,
      meta: isApplePlatform,
      shift: shift,
    );

/// Monta o editor principal e os editores das células com a mesma aparência.
class EditorFactory {
  EditorFactory({
    required this.look,
    required this.zoom,
    required this.tables,
    required this.contentWidth,
    required this.onCellFocused,
    required this.onFind,
    required this.onInsertImage,
    required this.onEditLink,
    required this.cellFocusParent,
  });

  final DocumentLook look;
  final double zoom;
  final TableStore tables;
  final double contentWidth;
  final CellFocusCallback onCellFocused;
  final VoidCallback onFind;
  final VoidCallback onInsertImage;
  final VoidCallback onEditLink;

  /// Células não ficam sob o foco do editor principal; senão ele acha que
  /// ainda tem o foco quando o usuário clica de volta no texto.
  final FocusNode cellFocusParent;

  double get scale => pointsToPixels * zoom;

  late final DefaultStyles styles = paperStyles(look, scale);

  late final List<EmbedBuilder> embedBuilders = [
    const ImageEmbedBuilder(),
    const PageBreakEmbedBuilder(),
    const SectionBreakEmbedBuilder(),
    const OpaqueInlineEmbedBuilder(),
    const OpaqueBlockEmbedBuilder(),
    TableEmbedBuilder(
      tables: tables,
      cellEditor: _cellEditor,
      maxWidth: contentWidth,
      onCellFocused: onCellFocused,
    ),
  ];

  static final _shortcuts = <ShortcutActivator, Intent>{
    const SingleActivator(LogicalKeyboardKey.enter, shift: true):
        const InsertLineBreakIntent(),
    shortcut(LogicalKeyboardKey.enter): const InsertPageBreakIntent(),
    shortcut(LogicalKeyboardKey.keyF): const OpenFindIntent(),
    shortcut(LogicalKeyboardKey.keyG): const InsertImageIntent(),
    shortcut(LogicalKeyboardKey.keyK): const EditLinkIntent(),
    shortcut(LogicalKeyboardKey.keyE): const AlignIntent('center'),
    shortcut(LogicalKeyboardKey.keyL): const AlignIntent('left'),
    shortcut(LogicalKeyboardKey.keyR): const AlignIntent('right'),
    shortcut(LogicalKeyboardKey.keyJ): const AlignIntent('justify'),
  };

  QuillEditorConfig config(
    QuillController controller, {
    EdgeInsets padding = EdgeInsets.zero,
    double? maxContentWidth,
    bool scrollable = false,
    bool expands = false,
    bool autoFocus = false,
    String? placeholder,
    GlobalKey<EditorState>? editorKey,
    QuillPageLayout? pageLayout,
  }) {
    return QuillEditorConfig(
      padding: padding,
      maxContentWidth: maxContentWidth,
      pageLayout: pageLayout,
      scrollable: scrollable,
      expands: expands,
      autoFocus: autoFocus,
      placeholder: placeholder,
      editorKey: editorKey,
      customStyles: styles,
      lineFormat: (line) => paragraphFormat(line, look),
      embedBuilders: embedBuilders,
      unknownEmbedBuilder: const UnknownEmbedBuilder(),
      customStyleBuilder: lineHeightStyle,
      onTapOutsideEnabled: false,
      textSelectionThemeData: const TextSelectionThemeData(
        cursorColor: paperTextColor,
        selectionColor: Color(0x553A7BD5),
      ),
      onTapDown: (details, positionFor) =>
          _isOnTable(controller, positionFor(details.globalPosition)),
      onTapUp: (details, positionFor) =>
          _isOnTable(controller, positionFor(details.globalPosition)),
      onSingleLongTapStart: (details, positionFor) =>
          _isOnTable(controller, positionFor(details.globalPosition)),
      customShortcuts: _shortcuts,
      customActions: {
        InsertLineBreakIntent: CallbackAction<InsertLineBreakIntent>(
          onInvoke: (_) => controller.insertLineBreak(),
        ),
        InsertPageBreakIntent: CallbackAction<InsertPageBreakIntent>(
          onInvoke: (_) => controller.insertPageBreak(),
        ),
        OpenFindIntent: CallbackAction<OpenFindIntent>(
          onInvoke: (_) => onFind(),
        ),
        InsertImageIntent: CallbackAction<InsertImageIntent>(
          onInvoke: (_) => onInsertImage(),
        ),
        EditLinkIntent: CallbackAction<EditLinkIntent>(
          onInvoke: (_) => onEditLink(),
        ),
        AlignIntent: CallbackAction<AlignIntent>(
          onInvoke: (intent) => controller.setAlignment(intent.align),
        ),
      },
    );
  }

  /// O toque do flutter_quill é "transparente": sem isso o editor de fora
  /// disputa o foco com a célula clicada.
  static bool _isOnTable(QuillController controller, TextPosition position) {
    final line = controller.document.queryChild(position.offset).node;
    return line is Line &&
        line.children.any(
          (child) => child is Embed && child.value.type == EmbedTypes.table,
        );
  }

  Widget _cellEditor(
    TableCellRef cell,
    FocusNode focusNode,
    ScrollController scrollController,
  ) {
    final controller = cell.cell.controller;
    return Focus(
      parentNode: cellFocusParent,
      canRequestFocus: false,
      skipTraversal: true,
      child: QuillEditor(
        controller: controller,
        focusNode: focusNode,
        scrollController: scrollController,
        config: config(controller),
      ),
    );
  }
}
