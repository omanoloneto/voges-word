import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

import '../document/embeds.dart';
import '../document/headers_footers.dart';
import 'editor_factory.dart';
import 'editor_session.dart';
import 'paper_styles.dart';

/// Edita cabeçalho e rodapé; devolve nulo se o usuário cancelar.
Future<HeadersFooters?> showHeaderFooterDialog(
  BuildContext context,
  EditorSession session,
) => showDialog<HeadersFooters>(
  context: context,
  builder: (context) => _HeaderFooterDialog(session: session),
);

typedef _Slot = (bool header, PageVariant variant);

class _HeaderFooterDialog extends StatefulWidget {
  const _HeaderFooterDialog({required this.session});

  final EditorSession session;

  @override
  State<_HeaderFooterDialog> createState() => _HeaderFooterDialogState();
}

class _HeaderFooterDialogState extends State<_HeaderFooterDialog> {
  late final HeadersFooters _original = widget.session.headersFooters;
  late var _firstDifferent = _original.differentFirstPage;
  var _variant = PageVariant.normal;
  final _controllers = <_Slot, QuillController>{};
  final _focusNodes = <_Slot, FocusNode>{};
  final _scrollControllers = <_Slot, ScrollController>{};
  final _cellParent = FocusNode(canRequestFocus: false, skipTraversal: true);

  late final EditorFactory _factory = EditorFactory(
    look: widget.session.look,
    zoom: 1,
    tables: widget.session.tables,
    contentWidth: widget.session.look.contentWidth * pointsToPixels,
    onCellFocused: (_, _) {},
    onFind: () {},
    onInsertImage: () {},
    onEditLink: () {},
    cellFocusParent: _cellParent,
  );

  HeaderFooterStory? _story(_Slot slot) =>
      (slot.$1 ? _original.headers : _original.footers)[slot.$2];

  QuillController _controller(_Slot slot) => _controllers.putIfAbsent(
    slot,
    () => QuillController(
      document: Document.fromDelta(
        _story(slot)?.delta ?? (Delta()..insert('\n')),
      ),
      selection: const TextSelection.collapsed(offset: 0),
    ),
  );

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    for (final scroll in _scrollControllers.values) {
      scroll.dispose();
    }
    _cellParent.dispose();
    super.dispose();
  }

  HeadersFooters _result() {
    Map<PageVariant, HeaderFooterStory> merged(bool header) {
      final stories = {...(header ? _original.headers : _original.footers)};
      for (final MapEntry(key: slot, value: controller)
          in _controllers.entries) {
        if (slot.$1 != header) continue;
        final delta = controller.document.toDelta();
        final previous = stories[slot.$2];
        if (previous != null && previous.delta == delta) continue;
        stories[slot.$2] = HeaderFooterStory(
          delta: delta,
          partPath: previous?.partPath,
          edited: true,
        );
      }
      return stories;
    }

    return _original.copyWith(
      headers: merged(true),
      footers: merged(false),
      differentFirstPage: _firstDifferent,
    );
  }

  @override
  Widget build(BuildContext context) {
    final variant = _firstDifferent ? _variant : PageVariant.normal;
    return AlertDialog(
      title: const Text('Cabeçalho e rodapé'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_firstDifferent) ...[
                SegmentedButton<PageVariant>(
                  segments: const [
                    ButtonSegment(
                      value: PageVariant.normal,
                      label: Text('Demais páginas'),
                    ),
                    ButtonSegment(
                      value: PageVariant.first,
                      label: Text('Primeira página'),
                    ),
                  ],
                  selected: {variant},
                  onSelectionChanged: (selection) =>
                      setState(() => _variant = selection.single),
                ),
                const SizedBox(height: 12),
              ],
              _section('Cabeçalho', (true, variant)),
              const SizedBox(height: 16),
              _section('Rodapé', (false, variant)),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _firstDifferent,
                title: const Text('Primeira página diferente'),
                subtitle: const Text(
                  'Para capa: a primeira página fica com cabeçalho e rodapé '
                  'próprios, que podem ficar vazios.',
                ),
                onChanged: (value) =>
                    setState(() => _firstDifferent = value ?? false),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _result()),
          child: const Text('Aplicar'),
        ),
      ],
    );
  }

  Widget _section(String title, _Slot slot) {
    final controller = _controller(slot);
    final focusNode = _focusNodes.putIfAbsent(slot, FocusNode.new);
    final scroll = _scrollControllers.putIfAbsent(slot, ScrollController.new);
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            _Toolbar(controller: controller, focusNode: focusNode),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          height: 96,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(6),
          ),
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(pointsToPixels)),
            child: QuillEditor(
              key: ValueKey(slot),
              controller: controller,
              focusNode: focusNode,
              scrollController: scroll,
              config: _factory.config(
                controller,
                padding: const EdgeInsets.all(10),
                scrollable: true,
                expands: true,
                placeholder: 'Vazio',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.controller, required this.focusNode});

  final QuillController controller;
  final FocusNode focusNode;

  void _toggle(Attribute attribute) {
    final on = controller.getSelectionStyle().attributes.containsKey(
      attribute.key,
    );
    controller.formatSelection(
      on ? Attribute.clone(attribute, null) : attribute,
    );
    focusNode.requestFocus();
  }

  void _align(Attribute attribute) {
    controller.formatSelection(attribute);
    focusNode.requestFocus();
  }

  void _insertPageNumber() {
    final selection = controller.selection;
    final index = selection.start < 0 ? 0 : selection.start;
    controller.replaceText(
      index,
      selection.end - index < 0 ? 0 : selection.end - index,
      const Embeddable(EmbedTypes.pageNumber, 'PAGE'),
      TextSelection.collapsed(offset: index + 1),
    );
    focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final style = controller.getSelectionStyle().attributes;
        final align = style[Attribute.align.key]?.value ?? 'left';
        Widget button(
          IconData icon,
          String tooltip,
          VoidCallback onPressed, {
          bool selected = false,
        }) => IconButton(
          icon: Icon(icon, size: 20),
          tooltip: tooltip,
          isSelected: selected,
          visualDensity: VisualDensity.compact,
          onPressed: onPressed,
        );
        return Wrap(
          children: [
            button(
              Icons.format_bold,
              'Negrito',
              () => _toggle(Attribute.bold),
              selected: style.containsKey(Attribute.bold.key),
            ),
            button(
              Icons.format_italic,
              'Itálico',
              () => _toggle(Attribute.italic),
              selected: style.containsKey(Attribute.italic.key),
            ),
            button(
              Icons.format_underlined,
              'Sublinhado',
              () => _toggle(Attribute.underline),
              selected: style.containsKey(Attribute.underline.key),
            ),
            button(
              Icons.format_align_left,
              'Alinhar à esquerda',
              () => _align(Attribute.leftAlignment),
              selected: align == 'left',
            ),
            button(
              Icons.format_align_center,
              'Centralizar',
              () => _align(Attribute.centerAlignment),
              selected: align == 'center',
            ),
            button(
              Icons.format_align_right,
              'Alinhar à direita',
              () => _align(Attribute.rightAlignment),
              selected: align == 'right',
            ),
            button(Icons.tag, 'Inserir número da página', _insertPageNumber),
          ],
        );
      },
    );
  }
}
