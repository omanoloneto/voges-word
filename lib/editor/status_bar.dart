import 'dart:async';

import 'package:flutter/material.dart';

import '../document/document_codec.dart';
import 'editor_session.dart';

const zoomLevels = [0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0];

class StatusBar extends StatefulWidget {
  const StatusBar({
    required this.session,
    required this.zoom,
    required this.onZoomChanged,
    super.key,
  });

  final EditorSession session;
  final double zoom;
  final ValueChanged<double> onZoomChanged;

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  Timer? _debounce;
  var _words = 0;
  var _characters = 0;
  StreamSubscription<void>? _changes;
  StreamSubscription<void>? _tableChanges;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_listen);
    _tableChanges = widget.session.tables.edits.listen((_) => _schedule());
    _listen();
  }

  @override
  void dispose() {
    widget.session.removeListener(_listen);
    _changes?.cancel();
    _tableChanges?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  void _listen() {
    _changes?.cancel();
    _changes = widget.session.controller.document.changes.listen(
      (_) => _schedule(),
    );
    _count();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _count);
  }

  void _count() {
    final text = widget.session.plainTextContent();
    final words = RegExp(
      r'[\p{L}\p{N}]+(?:[-’\x27][\p{L}\p{N}]+)*',
      unicode: true,
    ).allMatches(text).length;
    final characters = text.replaceAll(RegExp(r'[\n\uFFFC]'), '').length;
    if (!mounted) return;
    setState(() {
      _words = words;
      _characters = characters;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final session = widget.session;
    final zoomIndex = zoomLevels.indexWhere(
      (level) => (level - widget.zoom).abs() < 0.001,
    );

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: theme.colorScheme.surfaceContainer,
      child: Row(
        children: [
          Text(
            '$_words ${_words == 1 ? 'palavra' : 'palavras'} · $_characters caracteres',
            style: small,
          ),
          if (session.format == DocumentFormat.plainText) ...[
            const SizedBox(width: 12),
            Tooltip(
              message:
                  'Arquivos .txt guardam só o texto. Use "Salvar como" para manter a formatação.',
              child: Text(
                'Texto simples',
                style: small?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          ],
          const Spacer(),
          IconButton(
            tooltip: 'Diminuir zoom',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: zoomIndex > 0
                ? () => widget.onZoomChanged(zoomLevels[zoomIndex - 1])
                : null,
            icon: const Icon(Icons.remove),
          ),
          TextButton(
            onPressed: () => widget.onZoomChanged(1),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: Text('${(widget.zoom * 100).round()}%', style: small),
          ),
          IconButton(
            tooltip: 'Aumentar zoom',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: zoomIndex < zoomLevels.length - 1
                ? () => widget.onZoomChanged(zoomLevels[zoomIndex + 1])
                : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
