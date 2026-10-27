import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:window_manager/window_manager.dart';

import '../docx/image_formats.dart';
import '../document/document_codec.dart';
import '../files/document_files.dart';
import '../files/system_open.dart';
import 'dialogs.dart';
import 'document_commands.dart';
import 'editor_factory.dart';
import 'editor_session.dart';
import 'find_bar.dart';
import 'paper_view.dart';
import 'status_bar.dart';
import 'toolbar/editor_toolbar.dart';

bool get isDesktop =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

class EditorScreen extends StatefulWidget {
  const EditorScreen({
    required this.session,
    required this.systemOpen,
    required this.launchArguments,
    super.key,
  });

  final EditorSession session;
  final SystemOpen systemOpen;
  final List<String> launchArguments;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> with WindowListener {
  final _focusNode = FocusNode(debugLabel: 'documento');
  final _scrollController = ScrollController();
  final _editorKey = GlobalKey<EditorState>();
  late final AppLifecycleListener _lifecycle;
  var _zoom = 1.0;
  var _findOpen = false;
  var _findReplace = false;
  var _closing = false;
  String? _title;

  EditorSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) session.focusMain();
    });
    session.addListener(_updateTitle);
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    if (isDesktop) windowManager.addListener(this);
    widget.systemOpen.listen(_openFromSystem);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _updateTitle();
      final pending = await widget.systemOpen.pending(widget.launchArguments);
      if (pending.isNotEmpty) _load(pending.first);
    });
  }

  @override
  void dispose() {
    session.removeListener(_updateTitle);
    _lifecycle.dispose();
    if (isDesktop) windowManager.removeListener(this);
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _updateTitle() {
    final title = '${session.dirty ? '• ' : ''}${session.name} — Voges Word';
    if (title == _title) return;
    _title = title;
    if (isDesktop) windowManager.setTitle(title).ignore();
  }

  Future<AppExitResponse> _onExitRequested() async {
    if (_closing || await _confirmDiscard()) return AppExitResponse.exit;
    return AppExitResponse.cancel;
  }

  @override
  Future<void> onWindowClose() async {
    if (_closing || await _confirmDiscard()) {
      _closing = true;
      await windowManager.destroy();
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!session.dirty) return true;
    switch (await askToSave(context, session.name)) {
      case UnsavedChoice.save:
        return _save();
      case UnsavedChoice.discard:
        return true;
      case UnsavedChoice.cancel:
        return false;
    }
  }

  Future<void> _newDocument() async {
    if (!await _confirmDiscard()) return;
    session.newDocument();
    _afterLoad();
  }

  Future<void> _open() async {
    if (!await _confirmDiscard()) return;
    final OpenedFile? file;
    try {
      file = await session.files.pickDocument();
    } catch (error) {
      _showError('Não foi possível abrir o arquivo.');
      return;
    }
    if (file != null) _load(file);
  }

  Future<void> _openFromSystem(OpenedFile file) async {
    if (await _confirmDiscard()) _load(file);
  }

  void _load(OpenedFile file) {
    try {
      session.open(file);
    } on UserFacingException catch (error) {
      _showError(error.message);
      return;
    } catch (error) {
      _showError(
        'Não foi possível abrir "${file.name}". O arquivo pode estar danificado.',
      );
      return;
    }
    _afterLoad();
    if (session.notices.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(session.notices.join('\n')),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  void _afterLoad() {
    setState(() => _findOpen = false);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    _focusNode.requestFocus();
  }

  Future<bool> _save() => _runSave(session.save);

  Future<bool> _saveAs(DocumentFormat format) =>
      _runSave(() => session.saveAs(format));

  Future<bool> _runSave(Future<bool> Function() save) async {
    try {
      final saved = await save();
      if (saved && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Salvo como ${session.name}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return saved;
    } catch (error) {
      _showError(
        'Não foi possível salvar. Verifique se o arquivo está aberto em outro programa.',
      );
      return false;
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  void _refocus() {
    final cellFocus = session.activeCellFocus;
    (cellFocus ?? _focusNode).requestFocus();
  }

  Future<void> _insertImage() async {
    final controller = session.activeController.value;
    final PickedImage? image;
    try {
      image = await session.files.pickImage();
    } catch (error) {
      _showError('Não foi possível abrir a imagem.');
      return;
    }
    if (image == null) return;
    final pixels = imagePixelSize(image.bytes);
    if (pixels == null) {
      _showError(
        'Formato de imagem não reconhecido. Use PNG, JPG, GIF ou BMP.',
      );
      return;
    }
    var width = pixels.width * 0.75;
    var height = pixels.height * 0.75;
    final maxWidth = session.look.contentWidth;
    if (width > maxWidth) {
      height = height * maxWidth / width;
      width = maxWidth;
    }
    controller.insertImage(
      dataUriFromMime(image.bytes, image.mime),
      width: width,
      height: height,
    );
    _refocus();
  }

  Future<void> _editLink() async {
    final controller = session.activeController.value;
    final selection = controller.selection;
    final current = controller.valueOf<String>(Attribute.link.key);
    final request = await askForLink(
      context,
      currentUrl: current,
      needsText: selection.isCollapsed && current == null,
    );
    if (request == null) {
      _refocus();
      return;
    }
    final url = request.url;
    if (url == null) {
      controller.formatSelection(Attribute.clone(Attribute.link, null));
    } else if (selection.isCollapsed && current == null) {
      final text = request.text ?? url;
      controller.replaceText(selection.start, 0, text, null);
      controller.formatText(selection.start, text.length, LinkAttribute(url));
      controller.updateSelection(
        TextSelection.collapsed(offset: selection.start + text.length),
        ChangeSource.local,
      );
    } else {
      controller.formatSelection(LinkAttribute(url));
    }
    _refocus();
  }

  void _insertTable(int rows, int columns) {
    final table = session.tables.createEmpty(
      rows: rows,
      columns: columns,
      totalWidth: session.look.contentWidth * 20,
    );
    session.activeController.value.insertTable(table.id);
    _refocus();
  }

  void _removeTable() {
    final cell = session.activeCell.value;
    if (cell == null) return;
    session.removeTable(cell.table);
    _focusNode.requestFocus();
  }

  void _openFind({bool replace = false}) => setState(() {
    _findOpen = true;
    _findReplace = replace;
  });

  void _closeFind() {
    setState(() => _findOpen = false);
    _focusNode.requestFocus();
  }

  void _reveal(int offset) {
    final editor = _editorKey.currentState;
    if (editor == null || !_scrollController.hasClients) return;
    final rect = editor.renderEditor.getLocalRectForCaret(
      TextPosition(offset: offset),
    );
    final position = _scrollController.position;
    final visibleTop = position.pixels;
    final visibleBottom = visibleTop + position.viewportDimension;
    if (rect.top >= visibleTop + 40 && rect.bottom <= visibleBottom - 40) {
      return;
    }
    final target = rect.top - position.viewportDimension / 3;
    _scrollController.animateTo(
      math.max(0, math.min(target, position.maxScrollExtent)),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _setZoom(double zoom) => setState(() => _zoom = zoom);

  void _stepZoom(int direction) {
    final index = zoomLevels.indexWhere(
      (level) => (level - _zoom).abs() < 0.001,
    );
    final next = (index < 0 ? zoomLevels.indexOf(1.0) : index) + direction;
    if (next >= 0 && next < zoomLevels.length) _setZoom(zoomLevels[next]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => PopScope(
        canPop: !session.dirty,
        onPopInvokedWithResult: (didPop, _) async {
          if (!didPop && await _confirmDiscard()) SystemNavigator.pop();
        },
        child: CallbackShortcuts(
          bindings: {
            shortcut(LogicalKeyboardKey.keyN): _newDocument,
            shortcut(LogicalKeyboardKey.keyO): _open,
            shortcut(LogicalKeyboardKey.keyS): _save,
            shortcut(LogicalKeyboardKey.keyS, shift: true): () =>
                _saveAs(DocumentFormat.docx),
            shortcut(LogicalKeyboardKey.keyF): _openFind,
            shortcut(LogicalKeyboardKey.keyH): () => _openFind(replace: true),
            shortcut(LogicalKeyboardKey.equal): () => _stepZoom(1),
            shortcut(LogicalKeyboardKey.minus): () => _stepZoom(-1),
            shortcut(LogicalKeyboardKey.digit0): () => _setZoom(1),
          },
          child: Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  _FileBar(
                    session: session,
                    onNew: _newDocument,
                    onOpen: _open,
                    onSave: _save,
                    onSaveAs: _saveAs,
                    onFind: () => _openFind(replace: true),
                  ),
                  ColoredBox(
                    color: theme.colorScheme.surface,
                    child: EditorToolbar(
                      session: session,
                      actions: ToolbarActions(
                        insertImage: _insertImage,
                        editLink: _editLink,
                        insertTable: _insertTable,
                        removeTable: _removeTable,
                        refocus: _refocus,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: Stack(
                      children: [
                        PaperView(
                          session: session,
                          zoom: _zoom,
                          focusNode: _focusNode,
                          scrollController: _scrollController,
                          editorKey: _editorKey,
                          onFind: _openFind,
                          onInsertImage: _insertImage,
                          onEditLink: _editLink,
                          pagesView: true,
                          onPageCountChanged: (_) {},
                        ),
                        if (_findOpen)
                          Positioned(
                            top: 8,
                            right: 16,
                            child: FindBar(
                              key: ValueKey(session.generation),
                              controller: session.controller,
                              startWithReplace: _findReplace,
                              onClose: _closeFind,
                              onReveal: _reveal,
                            ),
                          ),
                      ],
                    ),
                  ),
                  StatusBar(
                    session: session,
                    zoom: _zoom,
                    onZoomChanged: _setZoom,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FileBar extends StatelessWidget {
  const _FileBar({
    required this.session,
    required this.onNew,
    required this.onOpen,
    required this.onSave,
    required this.onSaveAs,
    required this.onFind,
  });

  final EditorSession session;
  final VoidCallback onNew;
  final VoidCallback onOpen;
  final VoidCallback onSave;
  final ValueChanged<DocumentFormat> onSaveAs;
  final VoidCallback onFind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mod = isApplePlatform ? '⌘' : 'Ctrl+';
    final wide = MediaQuery.sizeOf(context).width > 640;

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: theme.colorScheme.primary,
      child: Row(
        children: [
          Semantics(
            label: 'Voges Word',
            child: Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.onPrimary,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'VW',
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          MenuAnchor(
            menuChildren: [
              MenuItemButton(
                leadingIcon: const Icon(Icons.note_add_outlined),
                shortcut: shortcut(LogicalKeyboardKey.keyN),
                onPressed: onNew,
                child: const Text('Novo'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.folder_open_outlined),
                shortcut: shortcut(LogicalKeyboardKey.keyO),
                onPressed: onOpen,
                child: const Text('Abrir…'),
              ),
              const Divider(height: 8),
              MenuItemButton(
                leadingIcon: const Icon(Icons.save_outlined),
                shortcut: shortcut(LogicalKeyboardKey.keyS),
                onPressed: onSave,
                child: const Text('Salvar'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.save_as_outlined),
                shortcut: shortcut(LogicalKeyboardKey.keyS, shift: true),
                onPressed: () => onSaveAs(DocumentFormat.docx),
                child: const Text('Salvar como documento do Word (.docx)…'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.text_snippet_outlined),
                onPressed: () => onSaveAs(DocumentFormat.plainText),
                child: const Text('Salvar como texto simples (.txt)…'),
              ),
              const Divider(height: 8),
              MenuItemButton(
                leadingIcon: const Icon(Icons.find_replace),
                shortcut: shortcut(LogicalKeyboardKey.keyH),
                onPressed: onFind,
                child: const Text('Localizar e substituir'),
              ),
            ],
            builder: (context, menu, _) => TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.onPrimary,
              ),
              onPressed: () => menu.isOpen ? menu.close() : menu.open(),
              icon: const Icon(Icons.menu),
              label: const Text('Arquivo'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              session.dirty ? '${session.name} • não salvo' : session.name,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onPrimary,
              ),
            ),
          ),
          if (wide) ...[
            IconButton(
              tooltip: 'Abrir ($mod${'O'})',
              color: theme.colorScheme.onPrimary,
              onPressed: onOpen,
              icon: const Icon(Icons.folder_open_outlined),
            ),
            IconButton(
              tooltip: 'Salvar ($mod${'S'})',
              color: theme.colorScheme.onPrimary,
              onPressed: onSave,
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ],
      ),
    );
  }
}
