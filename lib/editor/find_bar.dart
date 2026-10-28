import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';

class FindBar extends StatefulWidget {
  const FindBar({
    required this.controller,
    required this.onClose,
    required this.onReveal,
    this.startWithReplace = false,
    super.key,
  });

  final QuillController controller;
  final VoidCallback onClose;
  final ValueChanged<int> onReveal;
  final bool startWithReplace;

  @override
  State<FindBar> createState() => _FindBarState();
}

class _FindBarState extends State<FindBar> {
  final _query = TextEditingController();
  final _replacement = TextEditingController();
  final _focus = FocusNode();
  var _matches = <TextRange>[];
  var _current = -1;
  late var _replacing = widget.startWithReplace;

  @override
  void initState() {
    super.initState();
    final selection = widget.controller.selection;
    if (!selection.isCollapsed) {
      final selected = widget.controller.document.toPlainText().substring(
        selection.start,
        selection.end,
      );
      if (!selected.contains('\n')) _query.text = selected;
    }
    _query.addListener(_search);
    _search();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
      _query.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _query.text.length,
      );
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _replacement.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _search() {
    final query = _query.text;
    if (query.isEmpty) {
      setState(() {
        _matches = [];
        _current = -1;
      });
      return;
    }
    final text = widget.controller.document.toPlainText();
    final pattern = RegExp(RegExp.escape(query), caseSensitive: false);
    final from = widget.controller.selection.start;
    final matches = [
      for (final match in pattern.allMatches(text))
        TextRange(start: match.start, end: match.end),
    ];
    setState(() {
      _matches = matches;
      _current = matches.isEmpty
          ? -1
          : matches.indexWhere((m) => m.start >= from);
      if (_current < 0 && matches.isNotEmpty) _current = 0;
    });
    if (_current >= 0) _select(_current);
  }

  void _select(int index) {
    final match = _matches[index];
    widget.controller.updateSelection(
      TextSelection(baseOffset: match.start, extentOffset: match.end),
      ChangeSource.local,
    );
    widget.onReveal(match.start);
  }

  void _step(int delta) {
    if (_matches.isEmpty) return;
    setState(() => _current = (_current + delta) % _matches.length);
    _select(_current);
  }

  void _replaceCurrent() {
    if (_current < 0) return;
    final match = _matches[_current];
    final text = _replacement.text;
    widget.controller.replaceText(
      match.start,
      match.end - match.start,
      text,
      TextSelection.collapsed(offset: match.start + text.length),
    );
    _search();
  }

  void _replaceAll() {
    final count = _matches.length;
    final text = _replacement.text;
    for (final match in _matches.reversed) {
      widget.controller.replaceText(
        match.start,
        match.end - match.start,
        text,
        null,
      );
    }
    _search();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count == 1
              ? '1 ocorrência substituída'
              : '$count ocorrências substituídas',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _query.text.isEmpty
        ? ''
        : _matches.isEmpty
        ? 'Nenhum resultado'
        : '${_current + 1} de ${_matches.length}';
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
        const SingleActivator(LogicalKeyboardKey.enter): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.enter, shift: true): () =>
            _step(-1),
      },
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: _replacing
                          ? 'Ocultar substituição'
                          : 'Substituir',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        _replacing ? Icons.expand_less : Icons.find_replace,
                      ),
                      onPressed: () => setState(() => _replacing = !_replacing),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _query,
                        focusNode: _focus,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Localizar',
                          suffixText: status,
                          border: const OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _step(1),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Anterior',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.keyboard_arrow_up),
                      onPressed: _matches.isEmpty ? null : () => _step(-1),
                    ),
                    IconButton(
                      tooltip: 'Próximo',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.keyboard_arrow_down),
                      onPressed: _matches.isEmpty ? null : () => _step(1),
                    ),
                    IconButton(
                      tooltip: 'Fechar (Esc)',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close),
                      onPressed: widget.onClose,
                    ),
                  ],
                ),
                if (_replacing) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const SizedBox(width: 40),
                      Expanded(
                        child: TextField(
                          controller: _replacement,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: 'Substituir por',
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _replaceCurrent(),
                        ),
                      ),
                      TextButton(
                        onPressed: _current < 0 ? null : _replaceCurrent,
                        child: const Text('Substituir'),
                      ),
                      TextButton(
                        onPressed: _matches.isEmpty ? null : _replaceAll,
                        child: const Text('Todas'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
