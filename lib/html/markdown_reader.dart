import 'dart:math' as math;

import 'package:markdown/markdown.dart' as md;

import '../document/document_codec.dart';
import '../docx/docx_builder.dart';
import 'html_writer.dart';

/// Text Markdown may have besides pictures inside `data:` URIs.
const maxMarkdownText = 4 * 1024 * 1024;

const _maxNesting = 100;

/// Work package:markdown may do rereading runs of link reference
/// definitions on each pass over the blocks, about a nanosecond a unit: see
/// [_Definitions].
const _maxDefinitionWork = 2500000000;

/// Sum over inline blocks of the square of their delimiters, brackets and
/// lines; package:markdown takes quadratic time on some of them.
const _maxInlineWork = 150000000;

/// Characters package:markdown may read again, summed over inline blocks:
/// see [_scans].
const _maxScanWork = 50000000;

/// Work package:markdown may do on brackets, about a nanosecond a unit: see
/// [_LinkWork].
const _maxLinkWork = 1000000000;

/// Longest label that can name a reference or a footnote, in CommonMark and
/// on GitHub.
const _maxLabel = 999;

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
/// the labels of reference definitions, tables and, on a first parse of its
/// blocks, how much work each inline block would take; runs of reference
/// definitions and brackets are counted as they are parsed. Front matter
/// and the content of fenced code never reach it.
MarkdownHtml markdownHtml(String markdown) {
  final text = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  var pictures = 0;
  for (final picture in _pictures(text)) {
    pictures += picture.uri;
  }
  for (final match in _pictureDefinition.allMatches(text)) {
    pictures += match[1]!.length;
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

/// Where a picture's `data:` URI is in a text: the characters
/// package:markdown reads only once, from [start] to [end], and the length
/// of the URI.
typedef _Picture = ({int start, int end, int uri});

/// Markdown pictures inside `data:` URIs, with an optional title: group 1
/// runs to the destination, which is group 2 or 3. An alt text with a
/// backtick might close a code span opened before it, which would leave the
/// URI to be read as text.
final _picture = RegExp(
  r'(!\[(?:[^\[\]\\`]|\\[^`])*\]\([ \t\n]*)'
  r'(?:<(data:[\w/+.-]+;base64,[A-Za-z0-9+/=]*)>|'
  r'(data:[\w/+.-]+;base64,[A-Za-z0-9+/=]*))'
  r'''(?:[ \t\n]+(?:"[^"]*"|'[^']*'|\([^()]*\)))?[ \t\n]*\)''',
);

/// `<img>` tags, as tables that Markdown can't hold keep their pictures,
/// that package:markdown's pattern for raw HTML takes whole. A backtick in
/// one might close a code span opened before it.
final _htmlPicture = RegExp(
  r'<img(?:\s+[a-zA-Z_:][\w.:-]*'
  r'''(?:\s*=\s*(?:[^\s"'=<>`]+|'[^'`]*'|"[^"`]*"))?)*\s*/?>''',
  caseSensitive: false,
);

/// The `data:` URI of a picture tag's `src`, in group 1.
final _pictureSource = RegExp(
  r'''\ssrc\s*=\s*["']?(data:[\w/+.-]+;base64,[A-Za-z0-9+/=]+)''',
  caseSensitive: false,
);

/// Reference definitions of pictures inside `data:` URIs, as in
/// `![Shot][s0]` and `[s0]: data:…`; group 1 is the URI.
final _pictureDefinition = RegExp(
  r'^ {0,3}\[(?:[^\[\]\\]|\\[^])+\]:[ \t]*\n?[ \t]*<?'
  r'(data:[\w/+.-]+;base64,[A-Za-z0-9+/=]*)',
  multiLine: true,
);

/// The pictures of [text], in order. Those of a tag the backslash before it
/// turns into text don't count.
List<_Picture> _pictures(String text) {
  final found = <_Picture>[
    for (final match in _picture.allMatches(text))
      (
        start: match.start + match[1]!.length,
        end: match.end,
        uri: (match[2] ?? match[3])!.length,
      ),
  ];
  for (final tag in _htmlPicture.allMatches(text)) {
    var backslashes = 0;
    while (tag.start - backslashes > 0 &&
        text.codeUnitAt(tag.start - backslashes - 1) == 0x5C) {
      backslashes++;
    }
    final source = backslashes.isEven
        ? _pictureSource.firstMatch(tag[0]!)
        : null;
    if (source == null) continue;
    final uri = source[1]!;
    final end = tag.start + source.end;
    found.add((start: end - uri.length, end: end, uri: uri.length));
  }
  found.sort((a, b) => a.start - b.start);
  final pictures = <_Picture>[];
  for (final picture in found) {
    if (pictures.isEmpty || picture.start >= pictures.last.end) {
      pictures.add(picture);
    }
  }
  return pictures;
}

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

/// Fences at the start of a line. Indented ones may belong to a list item,
/// whose lines package:markdown reads with laziness of its own, so they are
/// left to it.
final _fenceOpening = RegExp(r'^(`{3,}(?=[^`]*$)|~{3,})');
final _fenceClosing = RegExp(r'^ {0,3}(`{3,}|~{3,})\s*$');

/// [lines] with the content of fenced code blocks replaced by marks, whose
/// text goes to [code]; null when there's none.
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
  final work = _LinkWork();
  _checkLines(lines, work);
  _checkInlines(
    md.BlockParser(
      lines.map(md.Line.new).toList(),
      _document(_LinkWork()),
    ).parseLines(),
  );
  final renderer = _Renderer(code);
  final html = renderer.render(_document(work).parseLines(lines));
  return renderer.misplaced ? null : (html: html, notices: renderer.notices);
}

/// GitHub's extensions, with GitHub's e-mail links (an address that doesn't
/// end with a letter, like `react@18.3`, stays text) and footnotes (the
/// first definition of a label wins), and with the work on reference
/// definitions and on links counted, the latter in [work].
md.Document _document(_LinkWork work) => md.Document(
  extensionSet: md.ExtensionSet(
    [
      _Definitions(),
      for (final syntax in md.ExtensionSet.gitHubFlavored.blockSyntaxes)
        syntax is md.FootnoteDefSyntax ? _Footnotes() : syntax,
    ],
    [
      for (final syntax in md.ExtensionSet.gitHubFlavored.inlineSyntaxes)
        syntax is md.AutolinkExtensionSyntax ? _Autolinks() : syntax,
      _Links(work),
      _Pictures(work),
    ],
  ),
);

/// Counts what package:markdown does on runs of link reference definitions
/// as it does it: for each definition it reads the rest of the block,
/// checking every line for the start of another block, about a microsecond,
/// and copying its characters, 5 nanoseconds each. It goes before every
/// other syntax, so it sees each check of a line, and it never parses one.
class _Definitions extends md.BlockSyntax {
  var _work = 0;

  @override
  RegExp get pattern => _nothing;

  @override
  bool canParse(md.BlockParser parser) {
    if (!parser.isDone &&
        parser.currentSyntax is md.LinkReferenceDefinitionSyntax) {
      _work += 1000 + parser.current.content.length * 5;
      if (_work > _maxDefinitionWork) {
        throw const FormatException('Too many link definitions in a row.');
      }
    }
    return false;
  }

  @override
  md.Node? parse(md.BlockParser parser) => null;
}

final _nothing = RegExp(r'[^\s\S]');

/// Footnote definitions after the first of their label are left out, as
/// GitHub does: package:markdown would give each of them a back-link to
/// every reference.
class _Footnotes extends md.FootnoteDefSyntax {
  final _labels = <String>{};

  @override
  md.Node? parse(md.BlockParser parser) {
    final footnote = super.parse(parser);
    final label = footnote is md.Element ? footnote.footnoteLabel : null;
    if (label != null && !_labels.add(label.toLowerCase())) return md.Text('');
    return footnote;
  }
}

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

/// Checks nesting and tables, and counts in [work] the labels of reference
/// definitions, which package:markdown normalizes on both passes over the
/// blocks.
void _checkLines(List<String> lines, _LinkWork work) {
  var cells = 0;
  var columns = 0;
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    final (:depth, :content) = _containers(line);
    if (depth > _maxNesting) {
      throw const FormatException('The Markdown nests too deeply.');
    }
    if (content.trim().isEmpty) {
      columns = 0;
      continue;
    }
    if (content.codeUnitAt(0) == 0x5B) {
      work.add(_definitionLabel(lines, index, content) * 2);
    }
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
}

/// What normalizing the label of a reference definition that may start
/// [content], the rest of line [index] of [lines], costs package:markdown:
/// the label is read as [md.LinkParser] reads it, across lines, and copied
/// once per character that may fold; 0 when no definition starts there.
int _definitionLabel(List<String> lines, int index, String content) {
  var text = content;
  var position = 1;
  var length = 0;
  var folded = 0;
  int? next() {
    if (position == text.length) {
      if (++index == lines.length) return null;
      text = '\n${lines[index]}';
      position = 0;
    }
    final char = text.codeUnitAt(position++);
    length++;
    if (_folds(char)) folded++;
    return char;
  }

  for (var steps = 0; steps <= _maxLabel; steps++) {
    final char = next();
    if (char == null || char == 0x5B) return 0;
    if (char == 0x5D) {
      final colon = position < text.length && text.codeUnitAt(position) == 0x3A;
      return colon ? (length - 1) * (50 + folded) : 0;
    }
    if (char == 0x5C && next() == null) return 0;
  }
  return 0;
}

/// The most containers (quotes, list items and footnotes) a line can be
/// inside: one per marker, and one per two columns of indentation before or
/// between them, since a list item needs at least that much to go on. Lines
/// without markers open nothing, and neither does a thematic break.
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
    } else if (char == 0x5B) {
      final footnote = _footnoteStart.matchAsPrefix(line, index);
      if (footnote == null) break;
      markers++;
      index = footnote.end;
      continue;
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

/// The label that starts a footnote definition, whose content
/// package:markdown parses as blocks of their own.
final _footnoteStart = RegExp(r'\[\^[^\] \r\n\x00\t]+\]:[ \t]*');

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
      final pictures = _pictures(text);
      characters += text.length;
      for (final picture in pictures) {
        characters -= picture.uri;
      }
      if (characters > maxMarkdownText) {
        throw DocumentProblemException(DocumentProblem.tooLarge);
      }
      final tokens = _tokens(text);
      work += tokens * tokens;
      if (work > _maxInlineWork) {
        throw const FormatException('The Markdown is too complex.');
      }
      scans += _scans(text, pictures, _maxScanWork - scans);
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

/// Characters package:markdown may read in [text] besides its one pass,
/// refused past [limit]; its [pictures] it reads once. Raw HTML and
/// autolinks read as far as their patterns go, backticks to the next run as
/// long, a web address to the next space, and every character of a run of
/// letters, digits or spaces reads the rest of the run. Brackets are counted
/// as they are parsed.
int _scans(String text, List<_Picture> pictures, int limit) {
  final length = text.length;
  var work = 0;
  void read(int characters) {
    work += characters;
    if (work > limit) {
      throw const FormatException('The Markdown is too complex.');
    }
  }

  var next = 0;
  var word = 0;
  var spaces = 0;
  var addresses = 0;
  final ticks = <({int start, int count})>[];
  for (var index = 0; index < length; index++) {
    if (next < pictures.length && index == pictures[next].start) {
      final end = pictures[next++].end;
      read(word * word + spaces * spaces + addresses * (end - index));
      word = 0;
      spaces = 0;
      index = end - 1;
      continue;
    }
    final char = text.codeUnitAt(index);
    if (_isWord(char)) {
      word++;
    } else {
      read(word * word);
      word = 0;
    }
    if (char == 0x20) {
      spaces++;
    } else {
      read(spaces * spaces);
      spaces = 0;
    }
    if (char <= 0x20 || char == 0x3C) {
      addresses = 0;
    } else {
      read(addresses);
    }
    switch (char) {
      case 0x3C:
        read(_tagEnd(text, index) - index);
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
  read(word * word + spaces * spaces);
  final runs = <int, int>{};
  for (final run in ticks.reversed) {
    read((runs[run.count] ?? length) - run.start);
    runs[run.count] = run.start;
  }
  return work;
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

bool _isLetter(int char) =>
    (char >= 0x41 && char <= 0x5A) || (char >= 0x61 && char <= 0x7A);

/// How far package:markdown's patterns for raw HTML and autolinks may read
/// from the `<` at [start]: to the end of a comment, processing
/// instruction, CDATA section or declaration, past the quoted values of a
/// tag, or to the end of an autolink; to the end of [text] when none ends.
int _tagEnd(String text, int start) {
  final length = text.length;
  int after(String end, int from) {
    final index = text.indexOf(end, from);
    return index < 0 ? length : index + end.length;
  }

  if (text.startsWith('<!--', start)) return after('--', start + 4);
  if (text.startsWith('<![CDATA[', start)) return after(']]>', start + 9);
  final next = start + 1 < length ? text.codeUnitAt(start + 1) : 0;
  if (next == 0x21) return after('>', start + 2);
  if (next == 0x3F) return after('?>', start + 2);
  if (next != 0x2F && !_isLetter(next)) return start + 1;
  // A tag ends at its `>` and can't hold a `<` outside its quotes.
  var index = start + 1;
  while (index < length) {
    final char = text.codeUnitAt(index);
    if (char == 0x3E || char == 0x3C) break;
    if (char == 0x22 || char == 0x27) {
      index = text.indexOf(String.fromCharCode(char), index + 1);
      if (index < 0) return length;
    }
    index++;
  }
  return math.max(math.min(index + 1, length), _autolinkEnd(text, start + 1));
}

/// Where the pattern for an autolink like `<https://…>` whose scheme starts
/// at [index] stops: its address reads up to a space or a `>`.
int _autolinkEnd(String text, int index) {
  final length = text.length;
  final scheme = index;
  while (index < length) {
    final char = text.codeUnitAt(index);
    if (!_isLetter(char) && char != 0x2D && char != 0x2B && char != 0x2E) {
      break;
    }
    index++;
  }
  if (index - scheme >= 2 && _isAt(text, index, 0x3A)) {
    while (index < length &&
        text.codeUnitAt(index) > 0x20 &&
        text.codeUnitAt(index) != 0x3E) {
      index++;
    }
  }
  return math.min(index + 1, length);
}

/// Counts what package:markdown does on brackets before it does it, in
/// about nanoseconds: reading a destination or a label takes 10 a
/// character, normalizing a label for a lookup 50 a character plus a copy
/// of it per character it may fold, and the lookup 30 per footnote plus a
/// character of their labels. HTML made again from the same text, as a
/// definition's destination and title on each use after the first or the
/// label of a footnote on each reference, takes [_repeated] a character,
/// read by the HTML reader afterwards.
class _LinkWork {
  var _work = 0;

  /// Work of looking a label up among the footnotes.
  int get lookup => _lookup;
  var _lookup = 0;

  /// Uses so far of the destination of each reference definition, by
  /// identity: package:markdown passes on the definition's own string.
  Map<String, int>? _uses;

  void add(int work) {
    _work += work;
    if (_work > _maxLinkWork) {
      throw const FormatException('The Markdown is too complex.');
    }
  }

  /// The brackets of [document] are being parsed, after all its reference
  /// definitions and footnotes.
  void start(md.Document document) {
    if (_uses != null) return;
    _uses = Map.identity();
    for (final definition in document.linkReferences.values) {
      _uses![definition.destination] = 0;
    }
    for (final label in document.footnoteReferences.keys) {
      _lookup += 30 + label.length;
    }
  }

  /// A link or picture to [destination] with [title] is being made.
  void link(String destination, String? title) {
    final uses = _uses?[destination];
    if (uses == null) return;
    if (uses > 0) {
      add((destination.length + (title?.length ?? 0)) * _repeated);
    }
    _uses![destination] = uses + 1;
  }
}

/// Work, in [_LinkWork]'s units, on each character of HTML made again.
const _repeated = 100;

/// Brackets whose cost is counted before package:markdown resolves them. A
/// bracket that isn't an inline link has its whole text normalized as a
/// reference, copied once per capital letter, and compared with every
/// footnote; a text longer than [_maxLabel] is no reference at all, so it
/// isn't looked up. A footnote reference repeats its label, percent-encoded,
/// in its link, its id and its back-link.
mixin _Counted on md.LinkSyntax {
  _LinkWork get work;

  @override
  Iterable<md.Node>? close(
    md.InlineParser parser,
    md.SimpleDelimiter opener,
    md.Delimiter? closer, {
    String? tag,
    required List<md.Node> Function() getChildren,
  }) {
    work.start(parser.document);
    final text = parser.source;
    final end = parser.pos;
    final next = end + 1 < text.length ? text.codeUnitAt(end + 1) : null;
    var start = opener.endPos;
    var stop = end;
    if (next == 0x28) {
      final link = _inlineLink(text, end + 1);
      work.add((link.end - end) * 10 + end - start);
      if (link.found) {
        return super.close(
          parser,
          opener,
          closer,
          tag: tag,
          getChildren: getChildren,
        );
      }
    } else if (next == 0x5B &&
        !(end + 2 < text.length && text.codeUnitAt(end + 2) == 0x5D)) {
      final label = _referenceLabel(text, end + 1);
      work.add((label.end - end) * 10);
      if (!label.found) return null;
      start = end + 2;
      stop = label.end;
    }
    if (stop - start > _maxLabel) return null;
    var folded = 0;
    var encoded = 0;
    for (var index = start; index < stop; index++) {
      final char = text.codeUnitAt(index);
      if (_folds(char)) folded++;
      encoded += char < 0x80 ? 3 : (char < 0x800 ? 6 : 9);
    }
    work.add((stop - start) * (50 + folded) + work.lookup);
    if (stop > start && text.codeUnitAt(start) == 0x5E) {
      work.add((130 + encoded * 3) * _repeated);
    }
    return super.close(
      parser,
      opener,
      closer,
      tag: tag,
      getChildren: getChildren,
    );
  }
}

/// Characters package:markdown's case folding may replace, each with a copy
/// of the whole label: the blocks of the scripts that have case.
bool _folds(int char) =>
    (char >= 0x41 && char <= 0x5A) ||
    (char >= 0xB5 && char < 0x590) ||
    (char >= 0x10A0 && char < 0x1100) ||
    (char >= 0x13A0 && char < 0x1400) ||
    (char >= 0x1C80 && char < 0x2200) ||
    (char >= 0x24B6 && char < 0x24EA) ||
    (char >= 0x2C00 && char < 0x2D00) ||
    (char >= 0xA640 && char < 0xA800) ||
    (char >= 0xAB70 && char < 0xABC0) ||
    (char >= 0xFB00 && char < 0xFB18) ||
    (char >= 0xFF21 && char < 0xFF3B);

class _Links extends md.LinkSyntax with _Counted {
  _Links(this.work);

  @override
  final _LinkWork work;

  /// The destination as written, its backslash escapes resolved:
  /// package:markdown percent-encodes characters like `|`, so links would
  /// read back changed.
  @override
  md.Node createNode(
    String destination,
    String? title, {
    required List<md.Node> Function() getChildren,
  }) {
    work.link(destination, title);
    final link =
        super.createNode(destination, title, getChildren: getChildren)
            as md.Element;
    link.attributes['href'] = destination
        .replaceAllMapped(_escaped, (match) => match[1]!)
        .replaceAllMapped(_markup, (match) => _entities[match[0]]!);
    return link;
  }
}

class _Pictures extends md.ImageSyntax with _Counted {
  _Pictures(this.work);

  @override
  final _LinkWork work;

  @override
  md.Element createNode(
    String destination,
    String? title, {
    required List<md.Node> Function() getChildren,
  }) {
    work.link(destination, title);
    return super.createNode(destination, title, getChildren: getChildren);
  }
}

final _escaped = RegExp(r'''\\([!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])''');

/// `<`, `>` and the `&`s that start no character reference, which HTML
/// would read otherwise in an attribute.
final _markup = RegExp(
  r'[<>]|&(?!#[0-9]{1,7};|#[xX][0-9a-fA-F]{1,6};|[A-Za-z][A-Za-z0-9]*;)',
);
const _entities = {'<': '&lt;', '>': '&gt;', '&': '&amp;'};

/// Where package:markdown's reading of an inline link from the `(` at
/// [open] stops, and whether it finds one: the steps of [md.LinkSyntax].
({int end, bool found}) _inlineLink(String text, int open) {
  final length = text.length;
  var index = _skipLinkSpaces(text, open + 1);
  if (index == length) return (end: index, found: false);
  if (text.codeUnitAt(index) == 0x3C) {
    for (index++; ; index++) {
      if (index == length) return (end: index, found: false);
      final char = text.codeUnitAt(index);
      if (char == 0x5C) {
        if (++index == length) return (end: index, found: false);
      } else if (char == 0x0A || char == 0x0D || char == 0x0C) {
        return (end: index, found: false);
      } else if (char == 0x3E) {
        break;
      }
    }
    if (++index == length) return (end: index, found: false);
    final char = text.codeUnitAt(index);
    if (char == 0x29) return (end: index, found: true);
    if (!_endsDestination(char)) return (end: index, found: false);
    final title = _linkTitle(text, index);
    return (end: title.end, found: title.found || _isAt(text, title.end, 0x29));
  }
  var depth = 1;
  while (true) {
    final char = text.codeUnitAt(index);
    if (char == 0x5C) {
      if (++index == length) return (end: index, found: false);
    } else if (_endsDestination(char)) {
      final title = _linkTitle(text, index);
      index = title.end;
      if (!title.found && !_isAt(text, index, 0x29)) {
        return (end: index, found: false);
      }
      if (--depth == 0) return (end: index, found: true);
    } else if (char == 0x28) {
      depth++;
    } else if (char == 0x29 && --depth == 0) {
      return (end: index, found: true);
    }
    if (++index == length) return (end: index, found: false);
  }
}

/// Where the title of an inline link after the spaces at [index] ends at
/// its `)`, or where reading it stops.
({int end, bool found}) _linkTitle(String text, int index) {
  final length = text.length;
  index = _skipLinkSpaces(text, index);
  if (index == length) return (end: index, found: false);
  final delimiter = text.codeUnitAt(index);
  if (delimiter != 0x22 && delimiter != 0x27 && delimiter != 0x28) {
    return (end: index, found: false);
  }
  final close = delimiter == 0x28 ? 0x29 : delimiter;
  if (++index == length) return (end: index, found: false);
  while (true) {
    final char = text.codeUnitAt(index);
    if (char == 0x5C) {
      if (++index == length) return (end: index, found: false);
    } else if (char == close) {
      break;
    }
    if (++index == length) return (end: index, found: false);
  }
  index = _skipLinkSpaces(text, index + 1);
  return (end: index, found: _isAt(text, index, 0x29));
}

/// Where the label of a full reference link from the `[` at [open] ends at
/// its `]`, or where reading it stops.
({int end, bool found}) _referenceLabel(String text, int open) {
  final length = text.length;
  var index = open + 1;
  if (index == length) return (end: index, found: false);
  while (true) {
    final char = text.codeUnitAt(index);
    if (char == 0x5C) {
      if (++index == length) return (end: index, found: false);
    } else if (char == 0x5B) {
      return (end: index, found: false);
    } else if (char == 0x5D) {
      return (end: index, found: true);
    }
    if (++index == length) return (end: index, found: false);
  }
}

int _skipLinkSpaces(String text, int index) {
  while (index < text.length) {
    final char = text.codeUnitAt(index);
    if (char != 0x20 && (char < 0x09 || char > 0x0D)) break;
    index++;
  }
  return index;
}

bool _endsDestination(int char) =>
    char == 0x20 || char == 0x0A || char == 0x0D || char == 0x0C;

bool _isAt(String text, int index, int char) =>
    index < text.length && text.codeUnitAt(index) == char;

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
/// which also tells them from the paragraphs of list items. The boxes of
/// task list items go before their text, where the HTML reader makes them
/// ☐ and ☑ list levels.
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
        case md.Element(tag: 'hr'):
          // The editor has no rule; saving leaves it out.
          notices.add(DocumentNotice.contentNotImported);
        case md.Element(
              tag: 'p',
              children: [
                final md.Element box && md.Element(tag: 'input'),
                ...final rest,
              ],
            )
            when box.attributes['type'] == 'checkbox':
          // A loose item's box would come inside its paragraph.
          stack
            ..add(md.Element('p', rest))
            ..add(box);
        case final md.Element element:
          if (element.tag == 'ol') _renumber(element);
          _start(element, out);
          final children = element.children;
          if (children == null || element.tag == 'input') {
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

  /// Gives the first item after task items of a numbered [list] its number:
  /// the HTML reader takes task items out of the numbering, as ☑ and ☐
  /// levels, and the items after them would be numbered on from the ones
  /// before.
  static void _renumber(md.Element list) {
    var number = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    var afterTask = false;
    for (final item in list.children ?? const <md.Node>[]) {
      if (item is! md.Element || item.tag != 'li') continue;
      final task = item.attributes['class'] == 'task-list-item';
      if (afterTask && !task) item.attributes['value'] = '$number';
      afterTask = task;
      number++;
    }
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
