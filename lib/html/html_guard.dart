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
/// deeper than [maxDepth] or make more than [maxElements] elements.
GuardedHtml guardHtml(
  String html, {
  int maxDepth = 256,
  int maxElements = 200000,
}) => _Guard(html, maxDepth, maxElements).run();

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

typedef _Tag = ({String name, int nameEnd, int end});

class _Guard {
  _Guard(this.source, this.maxDepth, this.maxElements);

  final String source;
  final int maxDepth;
  final int maxElements;
  final _out = StringBuffer();
  final _styles = <String>[];
  var _dropped = false;

  /// How far the input has been copied to [_out] or skipped.
  var _copied = 0;
  final _stack = <String>['html', 'body'];
  final _open = <String, int>{'html': 1, 'body': 1};
  var _elements = 3;

  GuardedHtml run() {
    _out.write('<!DOCTYPE html>');
    final s = source;
    var index = 0;
    while (true) {
      final lt = s.indexOf('<', index);
      if (lt < 0 || lt + 1 >= s.length) break;
      final next = s.codeUnitAt(lt + 1);
      if (next == 0x21 || next == 0x3F) {
        index = _skip(lt, _declarationEnd(lt));
      } else if (next == 0x2F) {
        index = _endTag(lt);
      } else if (_isLetter(next)) {
        index = _startTag(lt);
      } else {
        index = lt + 1;
      }
    }
    _out.write(s.substring(_copied));
    return GuardedHtml(_out.toString(), _styles, dropped: _dropped);
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
    if (_rawText.contains(name)) {
      final (:contentEnd, :end) = name == 'plaintext'
          ? (contentEnd: source.length, end: source.length)
          : _rawTextEnd(name, tag.end);
      final content = source.substring(tag.end, contentEnd);
      _skip(lt, end);
      switch (name) {
        case 'style':
          _styles.add(content);
        case 'xmp' || 'plaintext':
          _out.write('<pre>${const HtmlEscape().convert(content)}</pre>');
          _start('pre');
          _end('pre');
        case 'iframe':
          _dropped = true;
      }
      return end;
    }
    if (_subtrees.contains(name)) {
      if (name == 'svg' || name == 'math') _dropped = true;
      return _skip(lt, _subtreeEnd(name, tag.end));
    }
    if (_droppedTags.contains(name)) return _skip(lt, tag.end);
    if (formattingTags.contains(name)) {
      if (name == 'a') _closeLink(lt);
      _out.write(source.substring(_copied, lt));
      _out.write('<$renamedPrefix$name');
      _copied = tag.nameEnd;
      _start('$renamedPrefix$name');
    } else {
      _start(name);
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
    if (formattingTags.contains(name)) {
      _out.write(s.substring(_copied, lt));
      _out.write('</$renamedPrefix$name');
      _copied = tag.nameEnd;
      _end('$renamedPrefix$name');
    } else {
      _end(name);
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
    final name = s.substring(start, index).toLowerCase();
    final nameEnd = index;
    while (index < s.length) {
      var char = s.codeUnitAt(index);
      if (_isSpace(char) || char == 0x2F) {
        index++;
        continue;
      }
      if (char == 0x3E) return (name: name, nameEnd: nameEnd, end: index + 1);
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
        return (name: name, nameEnd: nameEnd, end: index + 1);
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
          s.substring(lt + 2, nameEnd).toLowerCase() == name) {
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
        if (tag.name == name && s.codeUnitAt(tag.end - 2) != 0x2F) depth++;
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
      _count();
      return;
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
          _count();
        }
      case 'li':
        if (_inScope('li', _listScope)) _popThrough('li');
      case 'dd' || 'dt':
        if (_inScope(name, _scope)) _popThrough(name);
      case 'br':
        _count();
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
    _stack.add(name);
    _open[name] = (_open[name] ?? 0) + 1;
    _count();
    if (_stack.length > maxDepth) {
      throw const FormatException('The page nests elements too deeply.');
    }
  }

  void _count() {
    if (++_elements > maxElements) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
  }

  String _pop() {
    final name = _stack.removeLast();
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
