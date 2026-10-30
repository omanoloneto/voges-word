import 'dart:math' as math;

import 'package:markdown/markdown.dart' as md;

import '../document/document_codec.dart';
import '../docx/docx_builder.dart';
import 'html_writer.dart';

/// Text Markdown may have besides pictures inside `data:` URIs.
const maxMarkdownText = 4 * 1024 * 1024;

const _maxNesting = 100;

/// Cost of runs of link reference definitions: package:markdown rereads the
/// rest of the run for each one.
const _maxDefinitionWork = 300000000;

/// Sum over inline blocks of the square of their delimiters, brackets and
/// lines; package:markdown takes quadratic time on some of them.
const _maxInlineWork = 150000000;

/// Characters package:markdown may read again, summed over inline blocks:
/// see [_scans].
const _maxScanWork = 50000000;

/// Cells of Markdown tables; package:markdown pads every row to the width of
/// the header.
const _maxCells = 300000;

/// Ways package:markdown's pattern for the delimiter row of a table may try
/// to share the spaces of a line that isn't one, times the spaces it reads
/// each time.
const _maxDelimiterWork = 1000000;

/// A Markdown file as HTML, and what of it the editor can't keep.
typedef MarkdownHtml = ({String html, Set<DocumentNotice> notices});

/// GitHub flavored Markdown as HTML. package:markdown recurses on nesting and
/// is slow on some shapes, so the text is checked first: nesting depth,
/// reference definitions, tables and, on a first parse of its blocks, how
/// much work each inline block would take. Front matter and the content of
/// fenced code never reach it.
MarkdownHtml markdownHtml(String markdown) {
  final text = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  var pictures = 0;
  for (final pattern in [_picture, _htmlPicture]) {
    for (final match in pattern.allMatches(text)) {
      pictures += (match[1] ?? match[2])!.length;
    }
  }
  if (text.length - pictures > maxMarkdownText) {
    throw DocumentProblemException(DocumentProblem.tooLarge);
  }
  final lines = text.split('\n');
  final front = _frontMatter(lines);
  final head = front == 0
      ? ''
      : '<pre>${escapeHtmlText(lines.take(front).join('\n'))}</pre>';
  final body = lines.sublist(front);
  final code = <String>[];
  final skeleton = text.contains(_codeMark) || text.contains(_codeEnd)
      ? null
      : _takeOutCode(body, code);
  final parsed =
      (skeleton == null ? null : _parse(skeleton, code)) ??
      _parse(body, const [])!;
  return (html: '$head${parsed.html}', notices: parsed.notices);
}

/// Markdown pictures inside `data:` URIs, which package:markdown reads once
/// as the destination; group 1 or 2 is the URI.
final _picture = RegExp(
  r'!\[[^\[\]\n\\]*\]\([ \t]*'
  r'(?:<(data:[\w/+.-]+;base64,[A-Za-z0-9+/=]*)>|'
  r'(data:[\w/+.-]+;base64,[A-Za-z0-9+/=]*))[ \t]*\)',
);

/// HTML pictures inside `data:` URIs, as tables that Markdown can't hold
/// keep them.
final _htmlPicture = RegExp(
  r'''<img\b[^<>]*?\bsrc\s*=\s*["']?(data:[\w/+.-]+;base64,[A-Za-z0-9+/=]+)''',
  caseSensitive: false,
);

/// Lines of the front matter static site generators read at the top of a
/// file, between `---` (or `...`) lines in YAML or `+++` lines in TOML; 0
/// when there's none.
int _frontMatter(List<String> lines) {
  final fence = lines.first.trimRight();
  if ((fence != '---' && fence != '+++') ||
      lines.length < 3 ||
      lines[1].trim().isEmpty) {
    return 0;
  }
  for (var index = 1; index < lines.length; index++) {
    final line = lines[index].trimRight();
    if (line == fence || (fence == '---' && line == '...')) return index + 1;
  }
  return 0;
}

/// Marks of the lines of fenced code taken out before parsing.
const _codeMark = '\uE000';
const _codeEnd = '\uE001';
final _codeLine = RegExp('$_codeMark([0-9]{1,9})$_codeEnd');

final _fenceOpening = RegExp(r'^ {0,3}(`{3,}(?=[^`]*$)|~{3,})');
final _fenceClosing = RegExp(r'^ {0,3}(`{3,}|~{3,})\s*$');

/// [lines] with the content of fenced code blocks replaced by marks, whose
/// text goes to [code]; null when there's none. The spaces before the
/// content stay, so code inside list items stays inside them.
List<String>? _takeOutCode(List<String> lines, List<String> code) {
  List<String>? skeleton;
  String? fence;
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (fence == null) {
      fence = _fenceOpening.firstMatch(line)?[1];
      continue;
    }
    final closing = _fenceClosing.firstMatch(line)?[1];
    if (closing != null &&
        closing[0] == fence[0] &&
        closing.length >= fence.length) {
      fence = null;
      continue;
    }
    final content = line.trimLeft();
    if (content.isEmpty) continue;
    (skeleton ??= [...lines])[index] =
        '${line.substring(0, line.length - content.length)}'
        '$_codeMark${code.length}$_codeEnd';
    code.add(content);
  }
  return skeleton;
}

/// HTML of [lines], whose fenced code holds the marks of [code]; null when a
/// mark ends up outside a code block, because package:markdown saw the
/// fences otherwise.
MarkdownHtml? _parse(List<String> lines, List<String> code) {
  _checkLines(lines);
  _checkInlines(
    md.BlockParser(
      lines.map(md.Line.new).toList(),
      md.Document(extensionSet: _gitHub),
    ).parseLines(),
  );
  final renderer = _Renderer(code);
  final html = renderer.render(
    md.Document(extensionSet: _gitHub).parseLines(lines),
  );
  return renderer.misplaced ? null : (html: html, notices: renderer.notices);
}

/// GitHub's extensions, with GitHub's e-mail links: an address that doesn't
/// end with a letter, like `react@18.3`, stays text.
final _gitHub = md.ExtensionSet(md.ExtensionSet.gitHubFlavored.blockSyntaxes, [
  for (final syntax in md.ExtensionSet.gitHubFlavored.inlineSyntaxes)
    syntax is md.AutolinkExtensionSyntax ? _Autolinks() : syntax,
]);

class _Autolinks extends md.AutolinkExtensionSyntax {
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final address = match[2];
    if (address != null && !_letter.hasMatch(address[address.length - 1])) {
      return false;
    }
    return super.onMatch(parser, match);
  }
}

final _letter = RegExp('[A-Za-z]');
final _definition = RegExp(r'^\[[^\]]*\]:');

void _checkLines(List<String> lines) {
  var definitions = 0;
  var characters = 0;
  var work = 0;
  var cells = 0;
  var columns = 0;
  void endBlock() {
    work += definitions * characters;
    definitions = 0;
    characters = 0;
    columns = 0;
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
    _delimiterRow(line);
    // A table's header and every line up to a blank one get as many cells
    // as its widest delimiter row.
    final row = _delimiterRow(content);
    if (row > columns) {
      cells += row;
      columns = row;
    }
    cells += columns;
    if (cells > _maxCells) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
  }
  endBlock();
}

/// The most containers (quotes and list items) a line can be inside: one per
/// marker, and one per two columns of indentation before or between them,
/// since a list item needs at least that much to go on. Lines without
/// markers open nothing, and neither does a thematic break.
({int depth, String content}) _containers(String line) {
  final rule = _ruleStart(line);
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
    } else if (index >= rule) {
      break;
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

/// Where the rest of [line] is a thematic break (`* * *`, `---`): three or
/// more of one of `*`, `-` or `_` with only spaces between them. The line's
/// length when there's none.
int _ruleStart(String line) {
  var start = line.length;
  var marks = 0;
  int? mark;
  for (var index = line.length - 1; index >= 0; index--) {
    final char = line.codeUnitAt(index);
    if (char == 0x20 || char == 0x09) continue;
    if (char != 0x2A && char != 0x2D && char != 0x5F) break;
    if ((mark ??= char) != char) break;
    if (++marks >= 3) start = index;
  }
  return start;
}

/// Cells of the delimiter row of a table (`| --- | :-: |`), or 0 when
/// [text] isn't one. package:markdown checks lines with a pattern that, on
/// a line that only starts like one, tries every way to share the spaces
/// after each pipe between the cells around it; such lines are refused when
/// those ways are too many.
int _delimiterRow(String text) {
  final length = text.length;
  var index = 0;
  while (index < 3 && index < length && text.codeUnitAt(index) == 0x20) {
    index++;
  }
  if (index < length && text.codeUnitAt(index) == 0x7C) index++;
  var cells = 0;
  var ways = 1;
  var widest = 0;
  while (true) {
    final start = index;
    index = _skipBlanks(text, index);
    if (index < length && text.codeUnitAt(index) == 0x3A) index++;
    final dashes = index;
    while (index < length && text.codeUnitAt(index) == 0x2D) {
      index++;
    }
    if (index == dashes) {
      index = start;
      break;
    }
    if (index < length && text.codeUnitAt(index) == 0x3A) index++;
    index = _skipBlanks(text, index);
    if (index == length) return cells == 0 ? 0 : cells + 1;
    if (text.codeUnitAt(index) != 0x7C) {
      index = start;
      break;
    }
    index++;
    cells++;
    final blanks = _skipBlanks(text, index) - index;
    widest = math.max(widest, blanks);
    ways = math.min(ways * (blanks + 1), _maxDelimiterWork + 1);
  }
  if (cells > 0 && _skipBlanks(text, index) == length) return cells;
  if (ways * (widest + 1) > _maxDelimiterWork) {
    throw const FormatException('The Markdown is too complex.');
  }
  return 0;
}

int _skipBlanks(String text, int index) {
  while (index < text.length &&
      (text.codeUnitAt(index) == 0x20 || text.codeUnitAt(index) == 0x09)) {
    index++;
  }
  return index;
}

void _checkInlines(List<md.Node> nodes) {
  var work = 0;
  var scans = 0;
  var characters = 0;
  final stack = [...nodes];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    if (node is md.UnparsedContent) {
      final text = node.textContent;
      final tokens = _tokens(text);
      final (:scanned, :pictures) = _scans(text);
      work += tokens * tokens;
      scans += scanned;
      characters += text.length - pictures;
      if (characters > maxMarkdownText) {
        throw DocumentProblemException(DocumentProblem.tooLarge);
      }
      if (work > _maxInlineWork || scans > _maxScanWork) {
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

/// Characters package:markdown may read in [text] besides its one pass, and
/// the characters of its [_picture]s, which it reads once. A bracket or a
/// tag that doesn't close reads to the end, backticks to the next run as
/// long, a web address to the next space, and every character of a run of
/// letters, digits or spaces reads the rest of the run.
({int scanned, int pictures}) _scans(String text) {
  final length = text.length;
  final found = _picture.allMatches(text).iterator;
  var picture = found.moveNext() ? found.current.start : length;
  var pictures = 0;
  var work = 0;
  var word = 0;
  var spaces = 0;
  var addresses = 0;
  final ticks = <({int start, int count})>[];
  for (var index = 0; index < length; index++) {
    if (index == picture) {
      final end = found.current.end;
      pictures += end - index;
      work += word * word + spaces * spaces + addresses * (end - index);
      word = 0;
      spaces = 0;
      index = end - 1;
      picture = found.moveNext() ? found.current.start : length;
      continue;
    }
    final char = text.codeUnitAt(index);
    if (_isWord(char)) {
      word++;
    } else {
      work += word * word;
      word = 0;
    }
    if (char == 0x20) {
      spaces++;
    } else {
      work += spaces * spaces;
      spaces = 0;
    }
    if (char <= 0x20 || char == 0x3C) {
      addresses = 0;
    } else {
      work += addresses;
    }
    switch (char) {
      case 0x5D:
        work += length - index;
      case 0x3C
          when index + 1 < length && _opensTag(text.codeUnitAt(index + 1)):
        work += length - index;
      case 0x60 when index == 0 || text.codeUnitAt(index - 1) != 0x60:
        var end = index + 1;
        while (end < length && text.codeUnitAt(end) == 0x60) {
          end++;
        }
        ticks.add((start: index, count: end - index));
      case 0x2F
          when index > 0 &&
              text.codeUnitAt(index - 1) == 0x3A &&
              index + 1 < length &&
              text.codeUnitAt(index + 1) == 0x2F:
        addresses++;
      case 0x2E
          when index >= 3 &&
              text.codeUnitAt(index - 1) | 0x20 == 0x77 &&
              text.codeUnitAt(index - 2) | 0x20 == 0x77 &&
              text.codeUnitAt(index - 3) | 0x20 == 0x77:
        addresses++;
    }
  }
  work += word * word + spaces * spaces;
  final next = <int, int>{};
  for (final run in ticks.reversed) {
    work += (next[run.count] ?? length) - run.start;
    next[run.count] = run.start;
  }
  return (scanned: work, pictures: pictures);
}

/// Letters, digits and the other characters of e-mail addresses.
bool _isWord(int char) =>
    (char >= 0x30 && char <= 0x39) ||
    (char >= 0x41 && char <= 0x5A) ||
    (char >= 0x61 && char <= 0x7A) ||
    char == 0x2D ||
    char == 0x2E ||
    char == 0x2B ||
    char == 0x5F;

/// Whether `<` and [char] may start inline HTML or an autolink.
bool _opensTag(int char) =>
    (char >= 0x41 && char <= 0x5A) ||
    (char >= 0x61 && char <= 0x7A) ||
    char == 0x2F ||
    char == 0x3F ||
    char == 0x21;

/// Raw HTML GitHub shows as text, as its tag filter does, and elements the
/// HTML reader leaves out with their content: a `<script>` or `<button>` in
/// the prose would otherwise hide everything after it.
final _shownAsText = RegExp(
  '<(?=/?(?:title|textarea|style|xmp|iframe|noembed|noframes|script|'
  'plaintext|noscript|template|select|button|object|applet|option|optgroup|'
  r'datalist|progress|meter|map)(?:[\s/>]|$))',
  caseSensitive: false,
);

/// HTML of package:markdown's nodes, walked without recursion. Text nodes
/// already hold HTML: escaped text, or the raw HTML written in the Markdown,
/// which the HTML reader treats as any other page. Tables get borders, as
/// GitHub shows them, and quotes a right indent, as word processors do,
/// which also tells them from the paragraphs of list items. Task list
/// boxes become ☐ and ☑.
class _Renderer {
  _Renderer(this.code);

  final List<String> code;
  final notices = <DocumentNotice>{};
  var _restored = 0;
  var _stray = false;

  /// Whether a mark of [code] ended up outside a code block.
  bool get misplaced => code.isNotEmpty && (_stray || _restored != code.length);

  String render(List<md.Node> nodes) {
    final out = StringBuffer();
    final stack = <Object>[...nodes.reversed];
    var pre = 0;
    while (stack.isNotEmpty) {
      switch (stack.removeLast()) {
        case _End(:final tag):
          out.write('</$tag>');
          if (tag == 'pre') pre--;
        case md.Element(tag: 'input', :final attributes)
            when attributes['type'] == 'checkbox':
          out.write(attributes.containsKey('checked') ? '☑ ' : '☐ ');
        case md.Element(tag: 'hr'):
          // The editor has no rule; saving leaves it out.
          notices.add(DocumentNotice.contentNotImported);
        case final md.Element element:
          _start(element, out);
          final children = element.children;
          if (children == null) {
            out.write(' />');
            continue;
          }
          out.write('>');
          if (element.tag == 'pre') pre++;
          stack
            ..add(_End(element.tag))
            ..addAll(children.reversed);
        case md.Text(:final text):
          out.write(pre > 0 ? _restore(text) : _raw(text));
        case final md.Node node:
          out.write(node.textContent);
      }
    }
    return out.toString();
  }

  void _start(md.Element element, StringBuffer out) {
    out.write('<${element.tag}');
    element.attributes.forEach((name, value) {
      if (value.contains(_codeMark)) _stray = true;
      out.write(' $name="${value.replaceAll('"', '&quot;')}"');
    });
    switch (element.tag) {
      case 'table':
        out.write(' border="1"');
      case 'blockquote':
        out.write(' style="margin-right:36pt"');
      case 'a':
        final href = element.attributes['href']?.trim() ?? '';
        if (href.isNotEmpty &&
            !href.startsWith('#') &&
            safeLinkTarget(href) == null) {
          notices.add(DocumentNotice.contentNotImported);
        }
    }
  }

  String _raw(String text) {
    if (text.contains(_codeMark)) _stray = true;
    return text.replaceAll(_shownAsText, '&lt;');
  }

  String _restore(String text) => code.isEmpty
      ? text
      : text.replaceAllMapped(_codeLine, (match) {
          final index = int.parse(match[1]!);
          if (index >= code.length) {
            _stray = true;
            return '';
          }
          _restored++;
          return escapeHtmlText(code[index]);
        });
}

class _End {
  const _End(this.tag);

  final String tag;
}
