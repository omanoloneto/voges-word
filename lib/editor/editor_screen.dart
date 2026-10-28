import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:window_manager/window_manager.dart';

import '../docx/docx_template.dart';
import '../docx/image_formats.dart';
import '../document/document_codec.dart';
import '../files/document_files.dart';
import '../files/recent_files.dart';
import '../files/recovery.dart';
import '../files/system_open.dart';
import '../fonts/font_catalog.dart';
import '../print/page_renderer.dart';
import '../print/system_print.dart';
import 'dialogs.dart';
import 'document_commands.dart';
import 'editor_factory.dart';
import 'editor_session.dart';
import 'file_panel.dart';
import 'find_bar.dart';
import 'header_footer_dialog.dart';
import 'paper_view.dart';
import 'ribbon/ribbon.dart';
import 'ribbon/ribbon_style.dart';
import 'status_bar.dart';
import 'title_bar.dart';
import 'window_buttons.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({
    required this.session,
    required this.systemOpen,
    required this.recents,
    required this.fonts,
    required this.launchArguments,
    this.windowButtons = WindowButtonsLayout.right,
    this.recovery,
    super.key,
  });

  final EditorSession session;
  final SystemOpen systemOpen;
  final RecentFiles recents;
  final FontCatalog fonts;
  final List<String> launchArguments;
  final WindowButtonsLayout windowButtons;
  final RecoveryStore? recovery;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> with WindowListener {
  final _focusNode = FocusNode(debugLabel: 'documento');
  final _scrollController = ScrollController();
  final _editorKey = GlobalKey<EditorState>();
  final _pageInfo = ValueNotifier<(int, int)?>(null);
  late final AppLifecycleListener _lifecycle;
  late final Timer _recoveryTimer;
  var _recoveryRevision = -1;
  var _recoverySaved = false;
  QuillController? _watchedController;
  var _zoom = 1.0;
  var _pagesView = true;
  var _findOpen = false;
  var _findReplace = false;
  var _closing = false;
  var _maximized = false;
  var _fullScreen = false;
  var _pageInfoScheduled = false;
  String? _title;

  EditorSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) session.focusMain();
    });
    session.addListener(_onSessionChanged);
    _lifecycle = AppLifecycleListener(
      onExitRequested: _onExitRequested,
      onHide: _saveRecovery,
      onPause: _saveRecovery,
    );
    _recoveryTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _saveRecovery(),
    );
    if (isDesktopPlatform) windowManager.addListener(this);
    widget.systemOpen.listen(_openFromSystem);
    _watchController();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _updateTitle();
      _loadDocumentFonts();
      await _offerRecovery();
      final pending = await widget.systemOpen.pending(widget.launchArguments);
      if (pending.isNotEmpty) _load(pending.first);
    });
  }

  @override
  void dispose() {
    session.removeListener(_onSessionChanged);
    _watchedController?.removeListener(_schedulePageInfo);
    _lifecycle.dispose();
    _recoveryTimer.cancel();
    if (isDesktopPlatform) windowManager.removeListener(this);
    _focusNode.dispose();
    _scrollController.dispose();
    _pageInfo.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    _updateTitle();
    _watchController();
    if (!session.dirty && _recoverySaved) _clearRecovery();
  }

  Future<void> _offerRecovery() async {
    final store = widget.recovery;
    final snapshot = await store?.load();
    if (store == null || snapshot == null || !mounted) return;
    if (!await askToRecover(context, snapshot.name, snapshot.savedAt)) {
      await store.clear();
      return;
    }
    try {
      // No macOS o sandbox só deixa gravar no arquivo escolhido pelo usuário.
      session.restore(
        snapshot,
        keepPath: defaultTargetPlatform != TargetPlatform.macOS,
      );
    } catch (_) {
      _showError('Não foi possível recuperar o documento.');
      await store.clear();
      return;
    }
    _recoveryRevision = session.revision;
    _recoverySaved = true;
    _afterLoad();
  }

  Future<void> _saveRecovery() async {
    final store = widget.recovery;
    if (store == null ||
        !session.dirty ||
        session.revision == _recoveryRevision) {
      return;
    }
    _recoveryRevision = session.revision;
    try {
      await store.save(session.snapshot());
      _recoverySaved = true;
      if (!session.dirty) _clearRecovery();
    } catch (_) {
      _recoveryRevision = -1;
    }
  }

  void _clearRecovery() {
    _recoverySaved = false;
    _recoveryRevision = -1;
    widget.recovery?.clear().ignore();
  }

  void _watchController() {
    if (_watchedController == session.controller) return;
    _watchedController?.removeListener(_schedulePageInfo);
    _watchedController = session.controller..addListener(_schedulePageInfo);
    _schedulePageInfo();
  }

  void _schedulePageInfo() {
    if (_pageInfoScheduled) return;
    _pageInfoScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pageInfoScheduled = false;
      _updatePageInfo();
    });
  }

  void _updatePageInfo() {
    final editor = _editorKey.currentState?.renderEditor;
    final pages = editor?.pageLayout;
    if (editor == null || pages == null || !editor.hasSize) {
      _pageInfo.value = null;
      return;
    }
    final length = session.controller.document.length;
    final offset = math.min(
      math.max(session.controller.selection.extentOffset, 0),
      math.max(length - 1, 0),
    );
    final caret = editor.getLocalRectForCaret(TextPosition(offset: offset));
    final current = math.min(
      math.max(pages.pageAt(caret.top) + 1, 1),
      editor.pageCount,
    );
    _pageInfo.value = (current, editor.pageCount);
  }

  void _updateTitle() {
    final title = '${session.dirty ? '• ' : ''}${session.name} — Voges Word';
    if (title == _title) return;
    _title = title;
    if (isDesktopPlatform) windowManager.setTitle(title).ignore();
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

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  void onWindowEnterFullScreen() => setState(() => _fullScreen = true);

  @override
  void onWindowLeaveFullScreen() => setState(() => _fullScreen = false);

  Future<bool> _confirmDiscard() async {
    if (!session.dirty) return true;
    switch (await askToSave(context, session.name)) {
      case UnsavedChoice.save:
        return _save();
      case UnsavedChoice.discard:
        _clearRecovery();
        return true;
      case UnsavedChoice.cancel:
        return false;
    }
  }

  Future<void> _newDocument([
    DocumentTemplate template = DocumentTemplate.blank,
  ]) async {
    if (!await _confirmDiscard()) return;
    session.newDocument(template);
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

  Future<void> _openRecent(RecentFile recent) async {
    if (!await _confirmDiscard()) return;
    try {
      _load(await widget.recents.open(recent));
    } catch (error) {
      _showError(
        '"${recent.name}" não foi encontrado. Ele pode ter sido movido ou apagado.',
      );
      await widget.recents.forget(recent);
    }
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
    final path = file.path;
    if (path != null) widget.recents.remember(path);
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
    _loadDocumentFonts();
  }

  void _loadDocumentFonts() {
    for (final family in session.fontsInUse()) {
      widget.fonts.ensureLoaded(family).ignore();
    }
  }

  Future<bool> _save() => _runSave(session.save);

  Future<bool> _saveAs(DocumentFormat format) =>
      _runSave(() => session.saveAs(format));

  Future<bool> _runSave(Future<bool> Function() save) async {
    try {
      final saved = await save();
      final path = session.path;
      if (saved && path != null) widget.recents.remember(path);
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

  Future<void> _editHeadersFooters() async {
    final result = await showHeaderFooterDialog(context, session);
    if (result != null) session.setHeadersFooters(result);
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

  void _setZoom(double zoom) {
    setState(() => _zoom = zoom);
    _schedulePageInfo();
  }

  void _setPagesView(bool pages) {
    setState(() => _pagesView = pages);
    _schedulePageInfo();
  }

  void _stepZoom(int direction) {
    final index = zoomLevels.indexWhere(
      (level) => (level - _zoom).abs() < 0.001,
    );
    final next = (index < 0 ? zoomLevels.indexOf(1.0) : index) + direction;
    if (next >= 0 && next < zoomLevels.length) _setZoom(zoomLevels[next]);
  }

  void _showFilePanel() => showFilePanel(
    context,
    session: session,
    recents: widget.recents,
    actions: FilePanelActions(
      open: _open,
      save: _save,
      saveAs: _saveAs,
      newDocument: _newDocument,
      openRecent: _openRecent,
      findAndReplace: () => _openFind(replace: true),
      exportPdf: _exportPdf,
      print: _print,
      share: session.files.canShare ? _share : null,
    ),
  );

  /// Monta o PDF com as fontes do documento prontas e o andamento na tela.
  Future<Uint8List?> _buildPdf() async {
    final progress = ValueNotifier<(int, int)?>(null);
    showPdfProgress(context, progress);
    try {
      await Future.wait(session.fontsInUse().map(widget.fonts.ensureLoaded));
      if (!mounted) return null;
      return await documentPdf(
        context,
        session,
        onProgress: (value) => progress.value = value,
      );
    } catch (error) {
      _showError('Não foi possível montar o PDF.');
      return null;
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      progress.dispose();
    }
  }

  String get _pdfName => '${safeFileName(session.baseName)}.pdf';

  Future<void> _exportPdf() async {
    final pdf = await _buildPdf();
    if (pdf == null) return;
    try {
      if (await session.files.export(pdf, _pdfName, 'pdf') && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('PDF salvo: $_pdfName')));
      }
    } catch (error) {
      _showError('Não foi possível salvar o PDF.');
    }
  }

  Future<void> _print() async {
    if (!printsWithDialog && !printsFromViewer) {
      if (session.files.canShare && !kIsWeb) return _shareAs(ShareFormat.pdf);
      return _exportPdf();
    }
    final pdf = await _buildPdf();
    if (pdf == null) return;
    try {
      await printPdf(pdf, session.baseName);
    } catch (error) {
      _showError('Não foi possível abrir a impressão.');
    }
  }

  Future<void> _share() async {
    final format = await askShareFormat(context);
    if (format != null) await _shareAs(format);
  }

  Future<void> _shareAs(ShareFormat format) async {
    final Uint8List? bytes;
    final String name;
    final String mime;
    if (format == ShareFormat.pdf) {
      bytes = await _buildPdf();
      name = _pdfName;
      mime = 'application/pdf';
    } else {
      bytes = session.encode(DocumentFormat.docx);
      name = '${safeFileName(session.baseName)}.docx';
      mime =
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (bytes == null || !mounted) return;
    final size = MediaQuery.sizeOf(context);
    try {
      await session.files.share(
        bytes,
        name: name,
        mime: mime,
        origin: Rect.fromCenter(
          center: Offset(size.width / 2, 60),
          width: 1,
          height: 1,
        ),
      );
    } catch (error) {
      _showError('Não foi possível compartilhar.');
    }
  }

  @override
  Widget build(BuildContext context) {
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
            shortcut(LogicalKeyboardKey.keyP): _print,
            shortcut(LogicalKeyboardKey.keyH): () => _openFind(replace: true),
            shortcut(LogicalKeyboardKey.equal): () => _stepZoom(1),
            shortcut(LogicalKeyboardKey.minus): () => _stepZoom(-1),
            shortcut(LogicalKeyboardKey.digit0): () => _setZoom(1),
          },
          child: _resizable(
            Scaffold(
              body: Column(
                children: [
                  ColoredBox(
                    color: RibbonColors.background,
                    child: SafeArea(
                      bottom: false,
                      child: Column(
                        children: [
                          AppTitleBar(
                            session: session,
                            onFile: _showFilePanel,
                            isMaximized: _maximized,
                            isFullScreen: _fullScreen,
                            windowButtons: widget.windowButtons,
                          ),
                          Ribbon(
                            session: session,
                            fonts: widget.fonts,
                            actions: RibbonActions(
                              insertImage: _insertImage,
                              editLink: _editLink,
                              insertTable: _insertTable,
                              removeTable: _removeTable,
                              editHeadersFooters: _editHeadersFooters,
                              refocus: _refocus,
                              pagesView: _pagesView,
                              onPagesView: _setPagesView,
                              zoom: _zoom,
                              onZoom: _setZoom,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        PaperView(
                          session: session,
                          zoom: _zoom,
                          pagesView: _pagesView,
                          focusNode: _focusNode,
                          scrollController: _scrollController,
                          editorKey: _editorKey,
                          onFind: _openFind,
                          onInsertImage: _insertImage,
                          onEditLink: _editLink,
                          onPageCountChanged: (_) => _schedulePageInfo(),
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
                    pageInfo: _pageInfo,
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

  /// Sem a barra do sistema, a janela precisa das bordas para redimensionar:
  /// no Windows só falta a de cima; no Linux, sem moldura, faltam todas.
  Widget _resizable(Widget child) {
    if (!isDesktopPlatform || defaultTargetPlatform == TargetPlatform.macOS) {
      return child;
    }
    return DragToResizeArea(
      enableResizeEdges: _maximized || _fullScreen
          ? const []
          : defaultTargetPlatform == TargetPlatform.windows
          ? const [ResizeEdge.topLeft, ResizeEdge.top, ResizeEdge.topRight]
          : null,
      child: child,
    );
  }
}
