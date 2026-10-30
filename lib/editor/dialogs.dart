import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../document/document_codec.dart';
import '../l10n/l10n.dart';
import 'format_names.dart';

enum UnsavedChoice { save, discard, cancel }

Future<UnsavedChoice> askToSave(BuildContext context, String name) async {
  final choice = await showDialog<UnsavedChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.saveChangesTitle),
      content: Text(context.l10n.saveChangesMessage(name)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, UnsavedChoice.cancel),
          child: Text(context.l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, UnsavedChoice.discard),
          child: Text(context.l10n.dontSave),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, UnsavedChoice.save),
          child: Text(context.l10n.save),
        ),
      ],
    ),
  );
  return choice ?? UnsavedChoice.cancel;
}

/// True to recover the copy; false to discard it.
Future<bool> askToRecover(
  BuildContext context,
  String name,
  DateTime savedAt,
) async {
  final localizations = MaterialLocalizations.of(context);
  final date = localizations.formatShortDate(savedAt);
  final time = localizations.formatTimeOfDay(TimeOfDay.fromDateTime(savedAt));
  final recover = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.recoverTitle),
      content: Text(context.l10n.recoverMessage(name, date, time)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.discard),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.l10n.recover),
        ),
      ],
    ),
  );
  return recover ?? false;
}

/// [current] is the document in the format of its file.
enum ShareFormat { docx, current, pdf }

/// Offers the document's own format only when it is saved and isn't a .docx.
Future<ShareFormat?> askShareFormat(
  BuildContext context,
  DocumentFormat current,
) => showDialog<ShareFormat>(
  context: context,
  builder: (context) {
    final l10n = context.l10n;
    Widget option(
      ShareFormat value,
      IconData icon,
      String title,
      String hint,
    ) => SimpleDialogOption(
      onPressed: () => Navigator.pop(context, value),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(hint),
      ),
    );
    return SimpleDialog(
      title: Text(l10n.shareAs),
      children: [
        option(
          ShareFormat.docx,
          Icons.description_outlined,
          l10n.formatDocx,
          l10n.shareWordDocumentHint,
        ),
        if (current.writable && current != DocumentFormat.docx)
          option(
            ShareFormat.current,
            Icons.insert_drive_file_outlined,
            formatName(l10n, current),
            l10n.shareCurrentFormatHint,
          ),
        option(
          ShareFormat.pdf,
          Icons.picture_as_pdf_outlined,
          l10n.sharePdf,
          l10n.sharePdfHint,
        ),
      ],
    );
  },
);

/// Dialog showing the progress while the PDF is built.
void showPdfProgress(
  BuildContext context,
  ValueListenable<(int, int)?> progress,
) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: ValueListenableBuilder(
          valueListenable: progress,
          builder: (context, value, _) => Row(
            children: [
              const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Text(
                  value == null
                      ? context.l10n.preparingPdf
                      : context.l10n.buildingPdfPage(value.$1, value.$2),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class LinkRequest {
  const LinkRequest({required this.url, this.text});

  /// Null removes the link.
  final String? url;
  final String? text;
}

Future<LinkRequest?> askForLink(
  BuildContext context, {
  required String? currentUrl,
  required bool needsText,
}) {
  return showDialog<LinkRequest>(
    context: context,
    builder: (context) =>
        _LinkDialog(currentUrl: currentUrl, needsText: needsText),
  );
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({required this.currentUrl, required this.needsText});

  final String? currentUrl;
  final bool needsText;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final _url = TextEditingController(text: widget.currentUrl);
  final _text = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _text.dispose();
    super.dispose();
  }

  /// An address without a protocol becomes https; an email becomes mailto.
  static String normalize(String value) {
    final url = value.trim();
    if (url.isEmpty ||
        url.startsWith('#') ||
        RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(url)) {
      return url;
    }
    if (RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(url)) {
      return 'mailto:$url';
    }
    return 'https://$url';
  }

  void _submit() {
    final url = normalize(_url.text);
    if (url.isEmpty) return;
    final text = _text.text.trim();
    Navigator.pop(
      context,
      LinkRequest(url: url, text: text.isEmpty ? url : text),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.currentUrl == null
            ? context.l10n.insertLink
            : context.l10n.editLink,
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.needsText) ...[
              TextField(
                controller: _text,
                decoration: InputDecoration(labelText: context.l10n.linkText),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _url,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(labelText: context.l10n.linkAddress),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.currentUrl != null)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, const LinkRequest(url: null)),
            child: Text(context.l10n.removeLink),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(context.l10n.ok)),
      ],
    );
  }
}
