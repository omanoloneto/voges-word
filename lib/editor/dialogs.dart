import 'package:flutter/material.dart';

enum UnsavedChoice { save, discard, cancel }

Future<UnsavedChoice> askToSave(BuildContext context, String name) async {
  final choice = await showDialog<UnsavedChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Salvar alterações?'),
      content: Text('Deseja salvar as alterações em "$name"?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, UnsavedChoice.cancel),
          child: const Text('Cancelar'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, UnsavedChoice.discard),
          child: const Text('Não salvar'),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, UnsavedChoice.save),
          child: const Text('Salvar'),
        ),
      ],
    ),
  );
  return choice ?? UnsavedChoice.cancel;
}

/// Verdadeiro para recuperar a cópia; falso para descartá-la.
Future<bool> askToRecover(
  BuildContext context,
  String name,
  DateTime savedAt,
) async {
  final localizations = MaterialLocalizations.of(context);
  final when =
      '${localizations.formatShortDate(savedAt)} às '
      '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(savedAt))}';
  final recover = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Recuperar documento?'),
      content: Text(
        '"$name" foi fechado sem salvar. Há uma cópia de $when. '
        'Deseja recuperá-la?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Descartar'),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Recuperar'),
        ),
      ],
    ),
  );
  return recover ?? false;
}

class LinkRequest {
  const LinkRequest({required this.url, this.text});

  /// Nulo remove o link.
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

  /// Endereço sem protocolo vira https; e-mail vira mailto.
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
      title: Text(widget.currentUrl == null ? 'Inserir link' : 'Editar link'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.needsText) ...[
              TextField(
                controller: _text,
                decoration: const InputDecoration(labelText: 'Texto exibido'),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _url,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Endereço (site ou e-mail)',
              ),
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
            child: const Text('Remover link'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}
