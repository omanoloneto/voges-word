import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../docx/docx_template.dart';
import '../document/document_codec.dart';
import '../files/recent_files.dart';
import '../l10n/app_language.dart';
import '../l10n/l10n.dart';
import 'app_logo.dart';
import 'editor_session.dart';
import 'ribbon/ribbon_style.dart';

class FilePanelActions {
  const FilePanelActions({
    required this.open,
    required this.save,
    required this.saveAs,
    required this.newDocument,
    required this.openRecent,
    required this.findAndReplace,
    required this.exportPdf,
    required this.print,
    this.share,
  });

  final VoidCallback open;
  final VoidCallback save;
  final ValueChanged<DocumentFormat> saveAs;
  final ValueChanged<DocumentTemplate> newDocument;
  final ValueChanged<RecentFile> openRecent;
  final VoidCallback findAndReplace;
  final VoidCallback exportPdf;
  final VoidCallback print;

  /// Null where the system cannot share files.
  final VoidCallback? share;
}

/// The "File" panel: actions, new document from templates, and recent files.
Future<void> showFilePanel(
  BuildContext context, {
  required EditorSession session,
  required RecentFiles recents,
  required AppLanguage language,
  required FilePanelActions actions,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: context.l10n.close,
    barrierColor: const Color(0x22000000),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (context, _, _) => SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: _FilePanel(
            session: session,
            recents: recents,
            language: language,
            actions: actions,
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, -0.02),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    ),
  );
}

class _FilePanel extends StatelessWidget {
  const _FilePanel({
    required this.session,
    required this.recents,
    required this.language,
    required this.actions,
  });

  final EditorSession session;
  final RecentFiles recents;
  final AppLanguage language;
  final FilePanelActions actions;

  void _run(BuildContext context, VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final width = math.min(600.0, MediaQuery.sizeOf(context).width - 24);
    return Material(
      color: RibbonColors.menu,
      elevation: 16,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
                child: Row(
                  children: [
                    const AppLogo(size: 22, outlined: true),
                    const SizedBox(width: 10),
                    Text(l10n.fileMenu, style: RibbonText.activeTab),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: RibbonColors.field,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          session.name,
                          overflow: TextOverflow.ellipsis,
                          style: RibbonText.control,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: double.infinity,
                color: const Color(0x14000000),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  children: [
                    _PanelAction(
                      Icons.folder_open_outlined,
                      l10n.open,
                      () => _run(context, actions.open),
                    ),
                    _PanelAction(
                      Icons.save_outlined,
                      l10n.save,
                      () => _run(context, actions.save),
                    ),
                    _PanelAction(
                      Icons.save_as_outlined,
                      l10n.saveAs,
                      () => _run(
                        context,
                        () => actions.saveAs(DocumentFormat.docx),
                      ),
                    ),
                    _PanelAction(
                      Icons.text_snippet_outlined,
                      l10n.plainTextFile,
                      () => _run(
                        context,
                        () => actions.saveAs(DocumentFormat.plainText),
                      ),
                    ),
                    _PanelAction(
                      Icons.picture_as_pdf_outlined,
                      'PDF',
                      () => _run(context, actions.exportPdf),
                    ),
                    _PanelAction(
                      Icons.print_outlined,
                      l10n.print,
                      () => _run(context, actions.print),
                    ),
                    if (actions.share case final share?)
                      _PanelAction(
                        Icons.ios_share,
                        l10n.share,
                        () => _run(context, share),
                      ),
                    _PanelAction(
                      Icons.find_replace,
                      l10n.replace,
                      () => _run(context, actions.findAndReplace),
                    ),
                  ],
                ),
              ),
              _SectionTitle(l10n.newDocument),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final template in DocumentTemplate.values)
                      _Card(
                        label: _templateLabel(l10n, template),
                        preview: _TemplatePreview(template),
                        onTap: () =>
                            _run(context, () => actions.newDocument(template)),
                      ),
                  ],
                ),
              ),
              if (recents.isSupported) ...[
                _SectionTitle(l10n.recentlyOpened),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: ListenableBuilder(
                    listenable: recents,
                    builder: (context, _) => Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final file in recents.items)
                          _Card(
                            label: file.name,
                            tooltip: file.path,
                            preview: const _RecentPreview(),
                            onTap: () =>
                                _run(context, () => actions.openRecent(file)),
                          ),
                        _Card(
                          label: l10n.openAnother,
                          preview: const Center(
                            child: Icon(
                              Icons.add_circle_outline,
                              color: RibbonColors.text,
                              size: 28,
                            ),
                          ),
                          onTap: () => _run(context, actions.open),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              _SectionTitle(l10n.language),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: ListenableBuilder(
                  listenable: language,
                  builder: (context, _) => Wrap(
                    spacing: 4,
                    children: [
                      for (final option in [null, ...appLanguages])
                        _PanelAction(
                          language.locale == option
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          option == null
                              ? l10n.languageSystem
                              : languageName(option),
                          () => language.select(option),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
            ],
          ),
        ),
      ),
    );
  }
}

String _templateLabel(AppLocalizations l10n, DocumentTemplate template) =>
    switch (template) {
      DocumentTemplate.blank => l10n.templateBlank,
      DocumentTemplate.singleSpaced => l10n.templateSingleSpaced,
      DocumentTemplate.schoolWork => l10n.templateSchoolWork,
      DocumentTemplate.resume => l10n.templateResume,
    };

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
    child: Text(
      text,
      style: RibbonText.control.copyWith(
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
    ),
  );
}

class _PanelAction extends StatelessWidget {
  const _PanelAction(this.icon, this.label, this.onTap);

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onTap,
    style: TextButton.styleFrom(
      foregroundColor: RibbonColors.text,
      overlayColor: RibbonColors.hover,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    icon: Icon(icon, size: 18),
    label: Text(label, style: RibbonText.control),
  );
}

class _Card extends StatelessWidget {
  const _Card({
    required this.label,
    required this.preview,
    required this.onTap,
    this.tooltip,
  });

  final String label;
  final Widget preview;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final card = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      hoverColor: RibbonColors.hover,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: SizedBox(
          width: 118,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 74,
                decoration: BoxDecoration(
                  color: const Color(0x1FFFFFFF),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0x26FFFFFF)),
                ),
                child: preview,
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: RibbonText.control,
              ),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? card : Tooltip(message: tooltip!, child: card);
  }
}

class _Bars extends StatelessWidget {
  const _Bars(
    this.widths, {
    this.spacing = 6,
    this.alignment = CrossAxisAlignment.start,
  });

  final List<double> widths;
  final double spacing;
  final CrossAxisAlignment alignment;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(10),
    child: Column(
      crossAxisAlignment: alignment,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final (index, width) in widths.indexed)
          Padding(
            padding: EdgeInsets.only(top: index == 0 ? 0 : spacing),
            child: FractionallySizedBox(
              widthFactor: width,
              child: Container(
                height: 6,
                decoration: BoxDecoration(
                  color: const Color(0x40FFFFFF),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _TemplatePreview extends StatelessWidget {
  const _TemplatePreview(this.template);

  final DocumentTemplate template;

  @override
  Widget build(BuildContext context) => switch (template) {
    DocumentTemplate.blank => const SizedBox.expand(),
    DocumentTemplate.singleSpaced => const _Bars([
      1,
      1,
      0.9,
      1,
      0.6,
    ], spacing: 3),
    DocumentTemplate.schoolWork => const _Bars([1, 1, 1, 0.7], spacing: 8),
    DocumentTemplate.resume => const _Bars([
      0.55,
      0.8,
      0.35,
      0.9,
    ], alignment: CrossAxisAlignment.center),
  };
}

class _RecentPreview extends StatelessWidget {
  const _RecentPreview();

  @override
  Widget build(BuildContext context) =>
      const _Bars([0.5, 1, 1, 0.8], spacing: 5);
}
