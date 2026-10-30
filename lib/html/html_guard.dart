import 'dart:convert';

import '../document/document_codec.dart';

/// HTML ready for package:html, and what was taken out of it.
class GuardedHtml {
  const GuardedHtml(this.html, this.styleSheets, {required this.dropped});

  final String html;

  /// Text of the `<style>` elements.
  final List<String> styleSheets;

  /// Embedded frames, SVG or MathML were taken out.
  final bool dropped;
}

/// Prefix of the formatting elements the guard renames.
const renamedPrefix = 'vw-';

/// Formatting elements: the parser re-creates unclosed ones in every later
/// paragraph, so they reach it renamed and are parsed as ordinary elements.
const formattingTags = {
  'a',
  'b',
  'big',
  'code',
  'em',
  'font',
  'i',
  'nobr',
  's',
  'small',
  'strike',
  'strong',
  'tt',
  'u',
};

/// The element's name as written in the page.
String originalTagName(String name) =>
    name.startsWith(renamedPrefix) &&
        formattingTags.contains(name.substring(renamedPrefix.length))
    ? name.substring(renamedPrefix.length)
    : name;

/// Prepares untrusted HTML for package:html, whose tree builder slows down
/// quadratically with the nesting depth. Comments, scripts, frames, forms,
/// form controls, SVG and MathML are taken out, `<style>` text is kept apart
/// and formatting elements are renamed. A model of the parser's stack, which
/// never closes an element the parser keeps open, rejects pages that nest
/// deeper than [maxDepth] or make more than [maxElements] elements, and
/// pages that would keep the parser busy for long: too much text, content
/// it moves out of tables, parse errors or end tags it searches the stack
/// for in vain. In XHTML, `<x/>` is an empty element.
GuardedHtml guardHtml(
  String html, {
  int maxDepth = 256,
  int maxElements = 200000,
}) => _Guard(html, maxDepth, maxElements).run();

/// Characters of text outside tags.
const _maxText = 16 * 1024 * 1024;

/// Nodes the parser passes over to put content in front of tables (foster
/// parenting), in all.
const _maxFosterWork = 50000000;

/// Parse errors and unmatched end tags, each weighted by the stack the
/// parser searches for it; about half a second of parsing.
const _maxParserWork = 3000000;
const _errorWork = 16;

/// References past the last code point, which package:html can't read.
final _longReference = RegExp(
  r'&#(?:[xX]0*[1-9a-fA-F][0-9a-fA-F]{6,}|0*[1-9][0-9]{7,});?',
);

final _xhtmlNamespace = RegExp(
  r'''<html\b[^>]*\bxmlns\s*=\s*["']http://www\.w3\.org/1999/xhtml["']''',
  caseSensitive: false,
);

/// Where the parser moves content that isn't a table part out of the table.
const _fosterTargets = {'table', 'tbody', 'thead', 'tfoot', 'tr'};
const _tableParts = {
  'table',
  'caption',
  'colgroup',
  'col',
  'tbody',
  'thead',
  'tfoot',
  'tr',
  'td',
  'th',
};

const _rawText = {
  'script',
  'style',
  'title',
  'textarea',
  'noscript',
  'noembed',
  'noframes',
  'iframe',
  'xmp',
  'plaintext',
};

/// Taken out with their content.
const _subtrees = {'svg', 'math', 'template', 'select', 'button'};

/// Taken out, keeping their content.
const _droppedTags = {'form', 'frameset', 'frame', 'isindex'};

const _void = {
  'area',
  'base',
  'basefont',
  'bgsound',
  'br',
  'col',
  'command',
  'embed',
  'hr',
  'image',
  'img',
  'input',
  'keygen',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
};

/// Start tags that close an open `p`, as package:html does.
const _closesParagraph = {
  'address',
  'article',
  'aside',
  'blockquote',
  'center',
  'details',
  'dir',
  'div',
  'dl',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'header',
  'hgroup',
  'listing',
  'menu',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'summary',
  'table',
  'ul',
};

/// End tags package:html handles only when the element is in scope.
const _blockEnds = {
  'address',
  'article',
  'aside',
  'blockquote',
  'center',
  'details',
  'dir',
  'div',
  'dl',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'header',
  'hgroup',
  'listing',
  'menu',
  'nav',
  'ol',
  'pre',
  'section',
  'summary',
  'ul',
  'applet',
  'marquee',
  'object',
};

const _headings = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};

// Scope limits and special elements are supersets of package:html's, so the
// model stops where the parser stops or earlier and never pops more.
const _scope = {
  'applet',
  'caption',
  'html',
  'table',
  'td',
  'th',
  'marquee',
  'object',
  'template',
};
const _buttonScope = {..._scope, 'button'};
const _listScope = {..._scope, 'ol', 'ul'};
const _tableScope = {'html', 'table', 'template'};
const _tableContexts = {
  'td',
  'th',
  'tr',
  'tbody',
  'thead',
  'tfoot',
  'table',
  'caption',
  'colgroup',
  'html',
};
const _special = {
  'address',
  'applet',
  'area',
  'article',
  'aside',
  'base',
  'basefont',
  'bgsound',
  'blockquote',
  'body',
  'br',
  'button',
  'caption',
  'center',
  'col',
  'colgroup',
  'command',
  'dd',
  'details',
  'dialog',
  'dir',
  'div',
  'dl',
  'dt',
  'embed',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'frame',
  'frameset',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'head',
  'header',
  'hgroup',
  'hr',
  'html',
  'iframe',
  'image',
  'img',
  'input',
  'isindex',
  'keygen',
  'li',
  'link',
  'listing',
  'main',
  'marquee',
  'men',
  'menu',
  'meta',
  'nav',
  'noembed',
  'noframes',
  'noscript',
  'object',
  'ol',
  'p',
  'param',
  'plaintext',
  'pre',
  'script',
  'search',
  'section',
  'select',
  'source',
  'style',
  'summary',
  'table',
  'tbody',
  'td',
  'template',
  'textarea',
  'tfoot',
  'th',
  'thead',
  'title',
  'tr',
  'track',
  'ul',
  'wbr',
  'xmp',
};

typedef _Tag = ({String name, int nameEnd, int end, bool selfClosing});

class _Guard {
  _Guard(this.source, this.maxDepth, this.maxElements)
    : _xhtml = _isXhtml(source);

  final String source;
  final int maxDepth;
  final int maxElements;
  final bool _xhtml;
  final _out = StringBuffer();
  final _styles = <String>[];
  var _dropped = false;

  /// How far the input has been copied to [_out] or skipped.
  var _copied = 0;
  final _stack = <String>['html', 'body'];
  final _open = <String, int>{'html': 1, 'body': 1};
  var _elements = 3;

  /// Children of each element in [_stack] so far.
  final _children = <int>[1, 0];
  var _text = 0;
  var _fosterWork = 0;
  var _parserWork = 0;

  GuardedHtml run() {
    _out.write('<!DOCTYPE html>');
    final s = source;
    var index = 0;
    while (true) {
      final lt = s.indexOf('<', index);
      _textRun(index, lt < 0 ? s.length : lt);
      if (lt < 0 || lt + 1 >= s.length) break;
      final next = s.codeUnitAt(lt + 1);
      if (next == 0x21 || next == 0x3F) {
        index = _skip(lt, _declarationEnd(lt));
      } else if (next == 0x2F) {
        index = _endTag(lt);
      } else if (_isLetter(next)) {
        index = _startTag(lt);
      } else {
        // A `<` that starts no tag is text, and a parse error.
        _parse(_errorWork);
        index = lt + 1;
      }
    }
    _out.write(s.substring(_copied));
    final html = _out.toString();
    _invalidCharacters(html);
    return GuardedHtml(
      html.replaceAll(_longReference, '&#xFFFD;'),
      _styles,
      dropped: _dropped,
    );
  }

  static bool _isXhtml(String source) {
    final head = source.length > 4096 ? source.substring(0, 4096) : source;
    return head.trimLeft().startsWith('<?xml') ||
        _xhtmlNamespace.hasMatch(head);
  }

  /// Counts the text between [start] and [end]; outside cells, the parser
  /// moves text in a table in front of it.
  void _textRun(int start, int end) {
    if (end <= start) return;
    _text += end - start;
    if (_text > _maxText) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
    if (!_fosterTargets.contains(_stack.last)) {
      _children.last++;
      return;
    }
    for (var index = start; index < end; index++) {
      if (!_isSpace(source.codeUnitAt(index))) {
        _foster();
        return;
      }
    }
  }

  /// Content the parser puts in front of the innermost table, passing over
  /// the nodes before it.
  void _foster() {
    final parent = _stack.lastIndexOf('table') - 1;
    if (parent < 0) return;
    _fosterWork += ++_children[parent];
    if (_fosterWork > _maxFosterWork) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
  }

  void _parse(int work) {
    _parserWork += work;
    if (_parserWork > _maxParserWork) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
  }

  /// Characters package:html reports one by one: NUL, controls, lone
  /// surrogates and noncharacters.
  void _invalidCharacters(String html) {
    var count = 0;
    for (var index = 0; index < html.length; index++) {
      final char = html.codeUnitAt(index);
      if (char >= 0x20 && char < 0x7F) continue;
      if (char <= 0x08 ||
          char == 0x0B ||
          (char >= 0x0E && char <= 0x1F) ||
          (char >= 0x7F && char <= 0x9F) ||
          (char >= 0xFDD0 && char <= 0xFDEF) ||
          char == 0xFFFE ||
          char == 0xFFFF) {
        count++;
      } else if (char >= 0xD800 && char <= 0xDBFF) {
        final next = index + 1 < html.length ? html.codeUnitAt(index + 1) : 0;
        if (next >= 0xDC00 && next <= 0xDFFF) {
          index++;
        } else {
          count++;
        }
      } else if (char >= 0xDC00 && char <= 0xDFFF) {
        count++;
      }
    }
    _parse(count * _errorWork);
  }

  /// Copies the input up to [start] and leaves out everything up to [end].
  int _skip(int start, int end) {
    _out.write(source.substring(_copied, start));
    _copied = end;
    return end;
  }

  int _startTag(int lt) {
    final tag = _readTag(lt + 1);
    if (tag == null) return _skip(lt, source.length);
    final name = tag.name;
    // Foreign elements honor `/>` in HTML, and all elements do in XHTML.
    final empty =
        tag.selfClosing &&
        !_void.contains(name) &&
        (_xhtml || name == 'svg' || name == 'math');
    if (_rawText.contains(name)) {
      if (empty) {
        if (name == 'iframe') _dropped = true;
        return _skip(lt, tag.end);
      }
      final (:contentEnd, :end) = name == 'plaintext'
          ? (contentEnd: source.length, end: source.length)
          : _rawTextEnd(name, tag.end);
      final content = source.substring(tag.end, contentEnd);
      _skip(lt, end);
      switch (name) {
        case 'style':
          _styles.add(
            _xhtml
                ? content.replaceAll('<![CDATA[', '').replaceAll(']]>', '')
                : content,
          );
        case 'xmp' || 'plaintext':
          _out.write('<pre>${const HtmlEscape().convert(content)}</pre>');
          _start('pre');
          _textRun(tag.end, contentEnd);
          _end('pre');
        case 'iframe':
          _dropped = true;
      }
      return end;
    }
    if (_subtrees.contains(name)) {
      if (name == 'svg' || name == 'math') _dropped = true;
      return _skip(lt, empty ? tag.end : _subtreeEnd(name, tag.end));
    }
    if (_droppedTags.contains(name)) return _skip(lt, tag.end);
    final element = formattingTags.contains(name)
        ? '$renamedPrefix$name'
        : name;
    if (element != name) {
      if (name == 'a') _closeLink(lt);
      _out.write(source.substring(_copied, lt));
      _out.write('<$element');
      _copied = tag.nameEnd;
    }
    _start(element);
    if (empty) {
      _out.write(source.substring(_copied, tag.end));
      _out.write('</$element>');
      _copied = tag.end;
      _end(element);
    }
    return tag.end;
  }

  int _endTag(int lt) {
    final s = source;
    if (lt + 2 >= s.length) return lt + 2;
    final next = s.codeUnitAt(lt + 2);
    if (!_isLetter(next)) {
      // `</>` makes nothing and `</ x>` is a comment.
      if (next == 0x3E) return _skip(lt, lt + 3);
      return _skip(lt, _declarationEnd(lt));
    }
    final tag = _readTag(lt + 2);
    if (tag == null) return _skip(lt, s.length);
    final name = tag.name;
    if (_rawText.contains(name) ||
        _subtrees.contains(name) ||
        _droppedTags.contains(name)) {
      return _skip(lt, tag.end);
    }
    final depth = _stack.length;
    final elements = _elements;
    if (formattingTags.contains(name)) {
      _out.write(s.substring(_copied, lt));
      _out.write('</$renamedPrefix$name');
      _copied = tag.nameEnd;
      _end('$renamedPrefix$name');
    } else {
      _end(name);
    }
    // The parser searched its stack for an element that isn't there.
    if (_stack.length == depth && _elements == elements) {
      _parse(_errorWork + depth);
    }
    return tag.end;
  }

  /// The parser closes an open link before a new one; renamed links need it
  /// written.
  void _closeLink(int lt) {
    const link = '${renamedPrefix}a';
    if ((_open[link] ?? 0) == 0) return;
    for (var index = _stack.length - 1; index >= 0; index--) {
      final node = _stack[index];
      if (node == link) {
        _out.write(source.substring(_copied, lt));
        _copied = lt;
        _out.write('</$link>');
        _end(link);
        return;
      }
      if (const {
        'td',
        'th',
        'caption',
        'applet',
        'marquee',
        'object',
        'html',
      }.contains(node)) {
        return;
      }
    }
  }

  // Tokenizer

  /// End of a comment, doctype or other `<!`/`<?` declaration at [lt].
  int _declarationEnd(int lt) {
    final s = source;
    if (s.startsWith('<!--', lt)) {
      final close = s.indexOf('-->', lt + 2);
      final bang = s.indexOf('--!>', lt + 4);
      var end = close < 0 ? s.length : close + 3;
      if (bang >= 0 && bang + 4 < end) end = bang + 4;
      return end;
    }
    final gt = s.indexOf('>', lt + 2);
    return gt < 0 ? s.length : gt + 1;
  }

  /// The tag whose name starts at [start], read as the HTML tokenizer does;
  /// null when the input ends inside it.
  _Tag? _readTag(int start) {
    final s = source;
    var index = start;
    while (index < s.length) {
      final char = s.codeUnitAt(index);
      if (_isSpace(char) || char == 0x2F || char == 0x3E) break;
      index++;
    }
    if (index >= s.length) return null;
    final name = _asciiLowerCase(s.substring(start, index));
    final nameEnd = index;
    // A `/` right before `>`, outside attribute values.
    var slash = false;
    while (index < s.length) {
      var char = s.codeUnitAt(index);
      if (_isSpace(char) || char == 0x2F) {
        slash = char == 0x2F;
        index++;
        continue;
      }
      if (char == 0x3E) {
        return (
          name: name,
          nameEnd: nameEnd,
          end: index + 1,
          selfClosing: slash,
        );
      }
      slash = false;
      // Attribute name; its first character may be anything.
      index++;
      while (index < s.length) {
        char = s.codeUnitAt(index);
        if (_isSpace(char) || char == 0x2F || char == 0x3E || char == 0x3D) {
          break;
        }
        index++;
      }
      while (index < s.length && _isSpace(s.codeUnitAt(index))) {
        index++;
      }
      if (index >= s.length) return null;
      if (s.codeUnitAt(index) != 0x3D) continue;
      index++;
      while (index < s.length && _isSpace(s.codeUnitAt(index))) {
        index++;
      }
      if (index >= s.length) return null;
      char = s.codeUnitAt(index);
      if (char == 0x22 || char == 0x27) {
        final close = s.indexOf(String.fromCharCode(char), index + 1);
        if (close < 0) return null;
        index = close + 1;
      } else if (char == 0x3E) {
        return (
          name: name,
          nameEnd: nameEnd,
          end: index + 1,
          selfClosing: false,
        );
      } else {
        while (index < s.length) {
          char = s.codeUnitAt(index);
          if (_isSpace(char) || char == 0x3E) break;
          index++;
        }
      }
    }
    return null;
  }

  /// Where the text of a raw text element ends and where its end tag ends.
  ({int contentEnd, int end}) _rawTextEnd(String name, int from) {
    final s = source;
    var index = from;
    while (true) {
      final lt = s.indexOf('</', index);
      if (lt < 0) break;
      final nameEnd = lt + 2 + name.length;
      if (nameEnd < s.length &&
          _asciiLowerCase(s.substring(lt + 2, nameEnd)) == name) {
        final char = s.codeUnitAt(nameEnd);
        if (_isSpace(char) || char == 0x2F || char == 0x3E) {
          final tag = _readTag(lt + 2);
          return (contentEnd: lt, end: tag?.end ?? s.length);
        }
      }
      index = lt + 2;
    }
    return (contentEnd: s.length, end: s.length);
  }

  /// End of an element taken out with its content; SVG and MathML also end
  /// at HTML elements that break out of them.
  int _subtreeEnd(String name, int from) {
    final s = source;
    final foreign = name == 'svg' || name == 'math';
    var depth = 1;
    var index = from;
    while (true) {
      final lt = s.indexOf('<', index);
      if (lt < 0 || lt + 1 >= s.length) return s.length;
      final next = s.codeUnitAt(lt + 1);
      if (next == 0x21 && foreign && s.startsWith('<![CDATA[', lt)) {
        final close = s.indexOf(']]>', lt + 9);
        index = close < 0 ? s.length : close + 3;
      } else if (next == 0x21 || next == 0x3F) {
        index = _declarationEnd(lt);
      } else if (next == 0x2F &&
          lt + 2 < s.length &&
          _isLetter(s.codeUnitAt(lt + 2))) {
        final tag = _readTag(lt + 2);
        if (tag == null) return s.length;
        if (tag.name == name && --depth == 0) return tag.end;
        index = tag.end;
      } else if (_isLetter(next)) {
        final tag = _readTag(lt + 1);
        if (tag == null) return s.length;
        if (foreign && _breaksOut(tag.name)) return lt;
        if (tag.name == name && !tag.selfClosing) depth++;
        index = !foreign && _rawText.contains(tag.name)
            ? (tag.name == 'plaintext'
                  ? s.length
                  : _rawTextEnd(tag.name, tag.end).end)
            : tag.end;
      } else {
        index = lt + 1;
      }
    }
  }

  static bool _breaksOut(String name) => const {
    'b',
    'big',
    'blockquote',
    'body',
    'br',
    'center',
    'code',
    'dd',
    'div',
    'dl',
    'dt',
    'em',
    'embed',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'head',
    'hr',
    'i',
    'img',
    'li',
    'listing',
    'menu',
    'meta',
    'nobr',
    'ol',
    'p',
    'pre',
    'ruby',
    's',
    'small',
    'span',
    'strong',
    'strike',
    'sub',
    'sup',
    'table',
    'tt',
    'u',
    'ul',
    'var',
    'font',
  }.contains(name);

  static bool _isLetter(int char) =>
      (char >= 0x41 && char <= 0x5A) || (char >= 0x61 && char <= 0x7A);

  /// Lowercase as package:html makes tag names: only A to Z, so a name
  /// like `linK` (with a Kelvin sign) stays an unknown element for both.
  static String _asciiLowerCase(String name) {
    for (var index = 0; index < name.length; index++) {
      final char = name.codeUnitAt(index);
      if (char >= 0x41 && char <= 0x5A) {
        return String.fromCharCodes([
          for (final unit in name.codeUnits)
            unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit,
        ]);
      }
    }
    return name;
  }

  static bool _isSpace(int char) =>
      char == 0x20 ||
      char == 0x09 ||
      char == 0x0A ||
      char == 0x0C ||
      char == 0x0D;

  // Model of the parser's stack of open elements

  void _start(String name) {
    if (_void.contains(name)) {
      if (name == 'hr') _closeParagraph();
      // A column may come with the column group the parser makes for it.
      if (name == 'col') _count();
      _insert(name);
      return;
    }
    if (_fosterTargets.contains(_stack.last) && !_tableParts.contains(name)) {
      _foster();
    }
    if (_closesParagraph.contains(name)) {
      _closeParagraph();
      if (name == 'table' && _inTableMode()) _popThrough('table');
      _push(name);
      return;
    }
    if (_headings.contains(name)) {
      _closeParagraph();
      if (_headings.contains(_stack.last)) _pop();
      _push(name);
      return;
    }
    switch (name) {
      case 'li':
        _closeItem(const {'li'});
        _closeParagraph();
        _push(name);
      case 'dd' || 'dt':
        _closeItem(const {'dd', 'dt'});
        _closeParagraph();
        _push(name);
      case 'option' || 'optgroup':
        if (_stack.last == 'option') _pop();
        _push(name);
      case 'caption' ||
          'colgroup' ||
          'tbody' ||
          'thead' ||
          'tfoot' ||
          'tr' ||
          'td' ||
          'th':
        _tablePart(name);
      case 'html' || 'head' || 'body':
        break;
      default:
        _push(name);
    }
  }

  void _end(String name) {
    if (_headings.contains(name)) {
      if (_headings.any((heading) => _inScope(heading, _scope))) {
        while (_stack.length > 2 && !_headings.contains(_pop())) {}
      }
      return;
    }
    switch (name) {
      case 'p':
        if (_inScope('p', _buttonScope)) {
          _popThrough('p');
        } else {
          _insert(name);
        }
      case 'li':
        if (_inScope('li', _listScope)) _popThrough('li');
      case 'dd' || 'dt':
        if (_inScope(name, _scope)) _popThrough(name);
      case 'br':
        _insert(name);
      case 'html' || 'head' || 'body':
        break;
      case 'table' ||
          'tbody' ||
          'thead' ||
          'tfoot' ||
          'tr' ||
          'td' ||
          'th' ||
          'caption':
        if (_inScope(name, _tableScope)) _popThrough(name);
      case 'colgroup':
        if (_stack.last == 'colgroup') _pop();
      default:
        if (_blockEnds.contains(name)) {
          if (_inScope(name, _scope)) _popThrough(name);
        } else {
          _endOther(name);
        }
    }
  }

  void _endOther(String name) {
    if ((_open[name] ?? 0) == 0) return;
    for (var index = _stack.length - 1; index >= 2; index--) {
      final node = _stack[index];
      if (node == name) {
        _popTo(index);
        return;
      }
      if (_special.contains(node)) return;
    }
  }

  void _closeParagraph() {
    if (_inScope('p', _buttonScope)) _popThrough('p');
  }

  void _closeItem(Set<String> names) {
    for (var index = _stack.length - 1; index >= 2; index--) {
      final node = _stack[index];
      if (names.contains(node)) {
        _end(node);
        return;
      }
      if (_special.contains(node) &&
          node != 'address' &&
          node != 'div' &&
          node != 'p') {
        return;
      }
    }
  }

  String? _tableContext() {
    for (var index = _stack.length - 1; index >= 0; index--) {
      if (_tableContexts.contains(_stack[index])) return _stack[index];
    }
    return null;
  }

  bool _inTableMode() => const {
    'table',
    'tbody',
    'thead',
    'tfoot',
    'tr',
    'colgroup',
  }.contains(_tableContext());

  void _tablePart(String name) {
    // Each turn closes a cell, row, section, caption or column group.
    for (var turn = 0; turn < 6; turn++) {
      final context = _tableContext();
      switch (context) {
        case 'td' || 'th' || 'caption' || 'colgroup':
          _popThrough(context!);
        case 'tr':
          if (name == 'td' || name == 'th') {
            _popAbove('tr');
            _push(name);
            return;
          }
          _popThrough('tr');
        case 'tbody' || 'thead' || 'tfoot':
          if (name == 'tr' || name == 'td' || name == 'th') {
            _popAbove(context!);
            _push('tr');
            if (name != 'tr') _push(name);
            return;
          }
          _popThrough(context!);
        case 'table':
          _popAbove('table');
          if (name == 'tr' || name == 'td' || name == 'th') {
            _push('tbody');
            _push('tr');
            if (name != 'tr') _push(name);
          } else {
            _push(name);
          }
          return;
        default:
          // Outside tables the parser ignores these tags.
          return;
      }
    }
  }

  bool _inScope(String name, Set<String> limits) {
    if ((_open[name] ?? 0) == 0) return false;
    for (var index = _stack.length - 1; index >= 0; index--) {
      final node = _stack[index];
      if (node == name) return true;
      if (limits.contains(node)) return false;
    }
    return false;
  }

  void _push(String name) {
    _children.last++;
    _stack.add(name);
    _children.add(0);
    _open[name] = (_open[name] ?? 0) + 1;
    _count();
    if (_stack.length > maxDepth) {
      throw const FormatException('The page nests elements too deeply.');
    }
  }

  /// An element the parser inserts and closes at once.
  void _insert(String name) {
    if (_fosterTargets.contains(_stack.last) && !_tableParts.contains(name)) {
      _foster();
    } else {
      _children.last++;
    }
    _count();
  }

  void _count() {
    if (++_elements > maxElements) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
  }

  String _pop() {
    final name = _stack.removeLast();
    _children.removeLast();
    _open[name] = _open[name]! - 1;
    return name;
  }

  /// Pops elements down to [index], keeping `html` and `body`.
  void _popTo(int index) {
    while (_stack.length > index && _stack.length > 2) {
      _pop();
    }
  }

  void _popThrough(String name) {
    final index = _stack.lastIndexOf(name);
    if (index >= 2) _popTo(index);
  }

  void _popAbove(String name) {
    final index = _stack.lastIndexOf(name);
    if (index >= 0) _popTo(index + 1);
  }
}
