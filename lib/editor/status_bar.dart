import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../document/document_codec.dart';
import 'editor_session.dart';

class StatusBar extends StatefulWidget {
  const StatusBar({
    required this.session,
    required this.pageInfo,
    required this.zoom,
    required this.onZoomChanged,
    super.key,
  });

  final EditorSession session;

  /// (página atual, total) quando o documento aparece em páginas.
  final ValueListenable<(int, int)?> pageInfo;
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

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: theme.colorScheme.surfaceContainer,
      child: Row(
        children: [
          ValueListenableBuilder(
            valueListenable: widget.pageInfo,
            builder: (context, info, _) => info == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Text(
                      'Página ${info.$1} de ${info.$2}',
                      style: small,
                    ),
                  ),
          ),
          Flexible(
            child: Text(
              '$_words ${_words == 1 ? 'palavra' : 'palavras'} · $_characters caracteres',
              style: small,
              overflow: TextOverflow.ellipsis,
            ),
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
          SizedBox(
            width: 140,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                min: 0.5,
                max: 2,
                divisions: 30,
                value: widget.zoom.clamp(0.5, 2),
                label: '${(widget.zoom * 100).round()}%',
                semanticFormatterCallback: (value) =>
                    'Zoom ${(value * 100).round()}%',
                onChanged: widget.onZoomChanged,
              ),
            ),
          ),
          TextButton(
            onPressed: () => widget.onZoomChanged(1),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: Text('${(widget.zoom * 100).round()}%', style: small),
          ),
        ],
      ),
    );
  }
}
