import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:voges_updater/voges_updater.dart'
    show LaunchResult, UpdateCheck, UpdateStatusChip, UpdaterLocalizations;
import 'package:window_manager/window_manager.dart';

import '../docx/docx_template.dart';
import '../docx/image_formats.dart';
import '../document/document_codec.dart';
import '../files/document_files.dart';
import '../files/recent_files.dart';
import '../files/recovery.dart';
import '../files/system_open.dart';
import '../fonts/font_catalog.dart';
import '../l10n/app_language.dart';
import '../l10n/l10n.dart';
import '../print/page_renderer.dart';
import '../print/system_print.dart';
import '../spell/spell_checker.dart';
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
    required this.language,
    this.windowButtons = WindowButtonsLayout.right,
    this.recovery,
    this.spelling,
    this.updates,
    super.key,
  });

  final EditorSession session;
  final SystemOpen systemOpen;
  final RecentFiles recents;
  final FontCatalog fonts;
  final List<String> launchArguments;
  final AppLanguage language;
  final WindowButtonsLayout windowButtons;
  final RecoveryStore? recovery;
  final SpellChecker? spelling;
  final UpdateCheck? updates;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> with WindowListener {
  final _focusNode = FocusNode(debugLabel: 'document');
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
  Future<void> _opening = Future.value();

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
      if (widget.updates case final updates?) {
        updates.check().ignore();
        updates.cleanUp().ignore();
      }
      await _offerRecovery();
      final pending = await widget.systemOpen.pending(widget.launchArguments);
      if (pending.isNotEmpty) _load(pending.first);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final l10n = context.l10n;
    session.locale = SessionLocale.of(l10n);
    session.files.titles = FileDialogTitles(
      open: l10n.openDocument,
      insertPicture: l10n.insertPicture,
      saveAs: l10n.saveAs,
      export: l10n.export,
    );
    widget.spelling?.language = spellingLanguage(
      Localizations.localeOf(context),
    );
    _updateTitle();
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
    final name = snapshot.name.isEmpty
        ? context.l10n.untitledDocument
        : snapshot.name;
    if (!await askToRecover(context, name, snapshot.savedAt)) {
      await store.clear();
      return;
    }
    try {
      await _openInTurn(
        name,
        () => session.restoreInBackground(
          snapshot,
          // On macOS the sandbox only allows writing to the file the user
          // picked.
          keepPath: defaultTargetPlatform != TargetPlatform.macOS,
        ),
      );
    } catch (_) {
      _showError((l10n) => l10n.recoverFailed);
      await store.clear();
      return;
    }
    if (!mounted) return;
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

  /// The app closes for the updater to replace it, so unsaved work is
  /// handled first, exactly as when closing the window.
  Future<void> _startUpdate() async {
    final updates = widget.updates;
    if (updates == null || !await _confirmDiscard()) return;
    final revision = session.revision;
    if (await updates.startUpdater() == LaunchResult.started) {
      // Windows copies the app for the updater first, and the document may
      // change meanwhile; if the user keeps it open, the updater waits
      if (!mounted ||
          (session.revision != revision && !await _confirmDiscard())) {
        return;
      }
      _closing = true;
      await windowManager.destroy();
      return;
    }
    if (!mounted) return;
    final l10n = UpdaterLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.updateLaunchFailed),
        action: SnackBarAction(
          label: l10n.updateDownloadPage,
          onPressed: () => updates.openDownloadPage().ignore(),
        ),
      ),
    );
  }

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
      _showError((l10n) => l10n.openFailed);
      return;
    }
    if (file != null) _load(file);
  }

  Future<void> _openRecent(RecentFile recent) async {
    if (!await _confirmDiscard()) return;
    try {
      _load(await widget.recents.open(recent));
    } catch (error) {
      _showError((l10n) => l10n.recentNotFound(recent.name));
      await widget.recents.forget(recent);
    }
  }

  Future<void> _openFromSystem(OpenedFile file) async {
    if (await _confirmDiscard()) _load(file);
  }

  Future<void> _load(OpenedFile file) async {
    try {
      await _openInTurn(file.name, () => session.openInBackground(file));
    } on DocumentProblemException catch (error) {
      _showError((l10n) => _problemMessage(l10n, error.problem, file.name));
      return;
    } catch (error) {
      _showError((l10n) => l10n.problemDamaged(file.name));
      return;
    }
    if (!mounted) return;
    final path = file.path;
    if (path != null) widget.recents.remember(path);
    _afterLoad();
    if (session.notices.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            [
              for (final notice in session.notices)
                switch (notice) {
                  DocumentNotice.trackedChangesAccepted =>
                    context.l10n.noticeTrackedChangesAccepted,
                  DocumentNotice.commentsHidden =>
                    context.l10n.noticeCommentsHidden,
                  DocumentNotice.contentNotImported =>
                    context.l10n.noticeContentNotImported,
                  DocumentNotice.savesAsDocx => context.l10n.noticeSavesAsDocx,
                },
            ].join('\n'),
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  /// Runs [open] once the opens asked before it are done, so the document
  /// shown is the one asked for last.
  Future<void> _openInTurn(String name, Future<void> Function() open) {
    final turn = _opening.then((_) => _withProgress(name, open));
    _opening = turn.then((_) {}, onError: (Object _) {});
    return turn;
  }

  /// The format's work runs on another isolate, so the window stays
  /// responsive under the progress meanwhile.
  Future<void> _withProgress(String name, Future<void> Function() open) async {
    if (!mounted) return open();
    final navigator = Navigator.of(context, rootNavigator: true);
    final progress = _ProgressRoute(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor: DialogTheme.of(context).barrierColor ?? Colors.black54,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(width: 18),
              Expanded(child: Text(context.l10n.openingDocument(name))),
            ],
          ),
        ),
      ),
    );
    navigator.push(progress);
    try {
      await open();
    } finally {
      if (navigator.mounted && progress.isActive) {
        navigator.removeRoute(progress);
      }
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
            content: Text(context.l10n.savedAs(session.name)),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return saved;
    } catch (error) {
      _showError((l10n) => l10n.saveFailed);
      return false;
    }
  }

  String _problemMessage(
    AppLocalizations l10n,
    DocumentProblem problem,
    String name,
  ) {
    return switch (problem) {
      DocumentProblem.legacyDoc => l10n.problemLegacyDoc,
      DocumentProblem.unsupportedFormat => l10n.problemUnsupportedFormat,
      DocumentProblem.notWordDocument => l10n.problemNotWordDocument,
      DocumentProblem.passwordProtected => l10n.problemPasswordProtected,
      DocumentProblem.tooLarge => l10n.problemTooLarge,
      DocumentProblem.damaged => l10n.problemDamaged(name),
    };
  }

  void _showError(String Function(AppLocalizations l10n) message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message(context.l10n)),
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
      _showError((l10n) => l10n.pictureOpenFailed);
      return;
    }
    if (image == null) return;
    final pixels = imagePixelSize(image.bytes);
    if (pixels == null) {
      _showError((l10n) => l10n.pictureFormatUnknown);
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
    language: widget.language,
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

  /// Builds the PDF with the document's fonts ready and progress on screen.
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
      _showError((l10n) => l10n.pdfFailed);
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.pdfSaved(_pdfName))),
        );
      }
    } catch (error) {
      _showError((l10n) => l10n.pdfSaveFailed);
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
      _showError((l10n) => l10n.printFailed);
    }
  }

  Future<void> _share() async {
    final format = await askShareFormat(context, session.format);
    if (format != null) await _shareAs(format);
  }

  Future<void> _shareAs(ShareFormat format) async {
    final document = switch (format) {
      ShareFormat.docx => DocumentFormat.docx,
      ShareFormat.current => session.format,
      ShareFormat.pdf => null,
    };
    final Uint8List? bytes;
    final String name;
    final String mime;
    if (document == null) {
      bytes = await _buildPdf();
      name = _pdfName;
      mime = 'application/pdf';
    } else {
      try {
        bytes = session.encode(document);
      } catch (error) {
        _showError((l10n) => l10n.shareFailed);
        return;
      }
      name = '${safeFileName(session.baseName)}.${document.extension}';
      mime = mimeTypeOf(document);
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
      _showError((l10n) => l10n.shareFailed);
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
                            spelling: widget.spelling,
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
                          spelling: widget.spelling,
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
                    trailing: switch (widget.updates) {
                      final updates? => UpdateStatusChip(
                        check: updates,
                        onUpdate: _startUpdate,
                      ),
                      null => null,
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Without the system title bar the window needs resize edges: on Windows
  /// only the top one is missing; on Linux, with no frame, all of them are.
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

/// The progress of an open. It covers the window at once, so nothing goes
/// into the document being replaced, but shows only after a moment, so
/// quick opens don't flash.
class _ProgressRoute extends DialogRoute<void> {
  _ProgressRoute({
    required super.context,
    required super.builder,
    super.themes,
    super.barrierColor,
  }) : super(
         barrierDismissible: false,
         animationStyle: const AnimationStyle(
           duration: Duration(milliseconds: 450),
           curve: _appear,
         ),
       );

  static const _appear = Interval(2 / 3, 1, curve: Curves.easeOut);

  @override
  Curve get barrierCurve => _appear;
}
