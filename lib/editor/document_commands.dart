import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

import '../document/embeds.dart';

const _inlineFormats = <Attribute>[
  Attribute.bold,
  Attribute.italic,
  Attribute.underline,
  Attribute.strikeThrough,
  Attribute.font,
  Attribute.size,
  Attribute.color,
  Attribute.background,
];

class InsertLineBreakIntent extends Intent {
  const InsertLineBreakIntent();
}

class InsertPageBreakIntent extends Intent {
  const InsertPageBreakIntent();
}

extension DocumentCommands on QuillController {
  bool isActive(Attribute attribute) =>
      getSelectionStyle().attributes[attribute.key]?.value == attribute.value;

  T? valueOf<T>(String key) {
    final value = getSelectionStyle().attributes[key]?.value;
    return value is T ? value : null;
  }

  void toggle(Attribute attribute) => formatSelection(
    isActive(attribute) ? Attribute.clone(attribute, null) : attribute,
  );

  void setInline(Attribute attribute, Object? value) =>
      formatSelection(Attribute.clone(attribute, value));

  void setHeading(int level) => formatSelection(
    level == 0 ? Attribute.header : HeaderAttribute(level: level),
  );

  void setAlignment(String align) => formatSelection(
    align == 'left'
        ? Attribute.clone(Attribute.align, null)
        : AlignAttribute(align),
  );

  void toggleList(Attribute attribute) => formatSelection(
    isActive(attribute) ? Attribute.clone(Attribute.list, null) : attribute,
  );

  void setLineSpacing(double? multiple) => formatSelection(
    multiple == null
        ? Attribute.clone(Attribute.lineHeight, null)
        : LineHeightAttribute(lineHeight: multiple),
  );

  void clearFormatting() {
    for (final attribute in _inlineFormats) {
      formatSelection(Attribute.clone(attribute, null));
    }
    formatSelection(Attribute.clone(Attribute.script, null));
  }

  /// Line break within the same paragraph (Word's Shift+Enter).
  void insertLineBreak() {
    final start = selection.start;
    replaceText(
      start,
      selection.end - start,
      '\u2028',
      TextSelection.collapsed(offset: start + 1),
    );
  }

  void insertPageBreak() {
    final start = selection.start;
    compose(
      Delta()
        ..retain(start)
        ..delete(selection.end - start)
        ..insert({EmbedTypes.pageBreak: 'page'})
        ..insert('\n'),
      TextSelection.collapsed(offset: start + 2),
      ChangeSource.local,
    );
    updateSelection(
      TextSelection.collapsed(offset: start + 2),
      ChangeSource.local,
    );
  }

  void insertImage(
    String dataUri, {
    required double width,
    required double height,
  }) {
    final start = selection.start;
    compose(
      Delta()
        ..retain(start)
        ..delete(selection.end - start)
        ..insert(
          {EmbedTypes.image: dataUri},
          {
            Attribute.width.key: _points(width),
            Attribute.height.key: _points(height),
          },
        ),
      TextSelection.collapsed(offset: start + 1),
      ChangeSource.local,
    );
    updateSelection(
      TextSelection.collapsed(offset: start + 1),
      ChangeSource.local,
    );
  }

  /// Tables sit on a line of their own, as in Word.
  void insertTable(String tableId) {
    final text = document.toPlainText();
    final start = selection.start;
    final delta = Delta()..retain(start);
    if (selection.end > start) delta.delete(selection.end - start);
    var offset = start;
    if (start > 0 && text[start - 1] != '\n') {
      delta.insert('\n');
      offset++;
    }
    delta
      ..insert({EmbedTypes.table: encodeTableId(tableId)})
      ..insert('\n');
    final cursor = TextSelection.collapsed(offset: offset + 2);
    compose(delta, cursor, ChangeSource.local);
    updateSelection(cursor, ChangeSource.local);
  }

  void removeTable(String tableId) {
    var offset = 0;
    for (final operation in document.toDelta().toList()) {
      final data = operation.data;
      if (data is Map &&
          data[EmbedTypes.table] != null &&
          tableIdOf(data[EmbedTypes.table]) == tableId) {
        replaceText(offset, 1, '', TextSelection.collapsed(offset: offset));
        return;
      }
      offset += operation.length ?? 1;
    }
  }

  static String _points(double value) =>
      ((value * 100).round() / 100).toString();
}
