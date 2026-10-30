import 'package:markdown/markdown.dart' as md;

import '../document/document_codec.dart';

/// Text Markdown may have besides pictures inside `data:` URIs.
const maxMarkdownText = 4 * 1024 * 1024;

const _maxNesting = 100;

/// Cost of runs of link reference definitions: package:markdown rereads the
/// rest of the run for each one.
const _maxDefinitionWork = 40000000;

/// Sum over inline blocks of the square of their delimiters, brackets and
/// lines; package:markdown takes quadratic time on some of them.
const _maxInlineWork = 150000000;

/// GitHub flavored Markdown as HTML. package:markdown recurses on nesting and
/// is slow on some shapes, so the text is checked first: nesting depth,
/// reference definitions and, on a first parse of its blocks, how much work
/// each inline block would take.
String markdownHtml(String markdown) {
  final text = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final pictures = _pictures
      .allMatches(text)
      .fold<int>(0, (sum, match) => sum + match.end - match.start);
  if (text.length - pictures > maxMarkdownText) {
    throw DocumentProblemException(DocumentProblem.tooLarge);
  }
  final lines = text.split('\n');
  _checkLines(lines);
  _checkInlines(
    md.BlockParser(
      lines.map(md.Line.new).toList(),
      md.Document(extensionSet: md.ExtensionSet.gitHubFlavored),
    ).parseLines(),
  );
  return _render(
    md.Document(extensionSet: md.ExtensionSet.gitHubFlavored).parseLines(lines),
  );
}

final _pictures = RegExp(r'data:[\w/+.-]+;base64,[A-Za-z0-9+/=]+');
final _definition = RegExp(r'^\[[^\]]*\]:');

void _checkLines(List<String> lines) {
  var definitions = 0;
  var characters = 0;
  var work = 0;
  void endBlock() {
    work += definitions * characters;
    definitions = 0;
    characters = 0;
    if (work > _maxDefinitionWork) {
      throw const FormatException('Too many link definitions in a row.');
    }
  }

  for (final line in lines) {
    final (:depth, :content) = _containers(line);
    if (depth > _maxNesting) {
      throw const FormatException('The Markdown nests too deeply.');
    }
    if (content.trim().isEmpty) {
      endBlock();
      continue;
    }
    characters += line.length;
    if (_definition.hasMatch(content)) definitions++;
  }
  endBlock();
}

/// The most containers (quotes and list items) a line can be inside: one per
/// marker, and one per two columns of indentation before or between them,
/// since a list item needs at least that much to go on. Lines without
/// markers open nothing.
({int depth, String content}) _containers(String line) {
  var index = 0;
  var markers = 0;
  var columns = 0;
  while (index < line.length) {
    final char = line.codeUnitAt(index);
    if (char == 0x20) {
      columns++;
    } else if (char == 0x09) {
      columns += 4;
    } else if (char == 0x3E) {
      markers++;
    } else if ((char == 0x2D || char == 0x2B || char == 0x2A) &&
        (index + 1 == line.length ||
            line.codeUnitAt(index + 1) == 0x20 ||
            line.codeUnitAt(index + 1) == 0x09)) {
      markers++;
    } else if (char >= 0x30 && char <= 0x39) {
      var end = index;
      while (end < line.length &&
          end - index < 9 &&
          line.codeUnitAt(end) >= 0x30 &&
          line.codeUnitAt(end) <= 0x39) {
        end++;
      }
      final isMarker =
          end < line.length &&
          (line.codeUnitAt(end) == 0x2E || line.codeUnitAt(end) == 0x29) &&
          (end + 1 == line.length ||
              line.codeUnitAt(end + 1) == 0x20 ||
              line.codeUnitAt(end + 1) == 0x09);
      if (!isMarker) break;
      markers++;
      index = end;
    } else {
      break;
    }
    index++;
  }
  return (
    depth: markers == 0 ? 0 : markers + columns ~/ 2,
    content: line.substring(index),
  );
}

void _checkInlines(List<md.Node> nodes) {
  var work = 0;
  final stack = [...nodes];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    if (node is md.UnparsedContent) {
      final tokens = _tokens(node.textContent);
      work += tokens * tokens;
      if (work > _maxInlineWork) {
        throw const FormatException('The Markdown is too complex.');
      }
    } else if (node is md.Element) {
      stack.addAll(node.children ?? const []);
    }
  }
}

/// Characters that start inline syntax, and lines.
int _tokens(String text) {
  var count = 1;
  for (var index = 0; index < text.length; index++) {
    switch (text.codeUnitAt(index)) {
      case 0x0A ||
          0x2A ||
          0x5F ||
          0x7E ||
          0x60 ||
          0x5B ||
          0x5D ||
          0x21 ||
          0x3C ||
          0x3E ||
          0x26 ||
          0x5C ||
          0x28 ||
          0x29:
        count++;
    }
  }
  return count;
}

/// HTML of the nodes, walked without recursion. Text nodes already hold HTML:
/// escaped text, or the raw HTML written in the Markdown, which the HTML
/// reader treats as any other page. Tables get borders, as GitHub shows
/// them.
String _render(List<md.Node> nodes) {
  final out = StringBuffer();
  final stack = <Object>[...nodes.reversed];
  while (stack.isNotEmpty) {
    final item = stack.removeLast();
    if (item is String) {
      out.write(item);
    } else if (item is md.Element) {
      out.write('<${item.tag}');
      item.attributes.forEach(
        (name, value) =>
            out.write(' $name="${value.replaceAll('"', '&quot;')}"'),
      );
      if (item.tag == 'table') out.write(' border="1"');
      final children = item.children;
      if (children == null) {
        out.write(' />');
        continue;
      }
      out.write('>');
      stack
        ..add('</${item.tag}>')
        ..addAll(children.reversed);
    } else if (item is md.Node) {
      out.write(item.textContent);
    }
  }
  return out.toString();
}
