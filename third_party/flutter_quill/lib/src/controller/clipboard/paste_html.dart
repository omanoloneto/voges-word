import 'package:flutter_quill_delta_from_html/flutter_quill_delta_from_html.dart';
import 'package:flutter_quill_delta_from_html/parser/default_html_to_ops.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:meta/meta.dart';

import '../../../quill_delta.dart';

/// Voges Word: the [Delta] of HTML pasted from elsewhere.
///
/// HtmlToDelta ended a paragraph only when it had an alignment or an
/// indent, so plain paragraphs, as chat answers and web pages have them,
/// ran together. It also drops the line breaks of the source, which are
/// the lines of the text in a `<pre>`; those become `<br>` first. What it
/// gives ends with one line break, not with an empty line after the last
/// paragraph, heading or list.
@internal
Delta pastedHtmlToDelta(String html) {
  final body = html_parser.parse(html).body;
  if (body == null) return _endingOnce(_converter.convert(html));
  for (final pre in body.querySelectorAll('pre')) {
    _keepLines(pre);
  }
  return _endingOnce(_converter.convert(body.outerHtml));
}

/// [delta] without the line break HtmlToDelta adds at the end when the
/// content ended its last line already.
Delta _endingOnce(Delta delta) {
  final operations = delta.toList();
  final last = operations.lastOrNull;
  if (last == null || last.attributes != null || last.data is! String) {
    return delta;
  }
  final text = last.data! as String;
  if (text.endsWith('\n\n')) {
    return Delta.fromOperations([
      ...operations.take(operations.length - 1),
      Operation.insert(text.substring(0, text.length - 1)),
    ]);
  }
  final before =
      operations.length < 2 ? null : operations[operations.length - 2].data;
  if (text == '\n' && before is String && before.endsWith('\n')) {
    return Delta.fromOperations(
        operations.take(operations.length - 1).toList());
  }
  return delta;
}

final _converter = HtmlToDelta(htmlToOperations: _PasteOperations());

void _keepLines(dom.Node node) {
  for (final child in node.nodes.toList()) {
    if (child is! dom.Text) {
      _keepLines(child);
      continue;
    }
    final lines = child.text.split('\n');
    if (lines.length == 1) continue;
    final parent = child.parentNode!;
    for (var index = 0; index < lines.length; index++) {
      if (index > 0) parent.insertBefore(dom.Element.tag('br'), child);
      if (lines[index].isNotEmpty) {
        parent.insertBefore(dom.Text(lines[index]), child);
      }
    }
    child.remove();
  }
}

class _PasteOperations extends DefaultHtmlToOperations {
  _PasteOperations() : super(null);

  /// A paragraph of the page ends its line. Those in lists and other blocks
  /// are ended by them.
  @override
  List<Operation> paragraphToOp(dom.Element element) {
    final operations = super.paragraphToOp(element);
    final parent = element.parent?.localName;
    if (parent != null && parent != 'body' && parent != 'html') {
      return operations;
    }
    final last = operations.lastOrNull?.data;
    if (last is String && last.endsWith('\n')) return operations;
    return [...operations, Operation.insert('\n')];
  }
}
