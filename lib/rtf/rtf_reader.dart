import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart' show EdgeInsets;

import '../document/document_codec.dart';
import '../document/headers_footers.dart';
import '../document/picture_crop.dart';
import '../document/text_encodings.dart';
import '../docx/docx_builder.dart';
import '../docx/docx_numbering.dart' show wordListLevels;
import '../docx/image_formats.dart';
import 'rtf_languages.dart';
import 'rtf_pictures.dart';
import 'rtf_story.dart';
import 'rtf_tokenizer.dart';

/// A document read from RTF and what was adjusted to open it.
typedef RtfDocument = ({DocumentSpec spec, Set<DocumentNotice> notices});

/// Reads Rich Text Format up to 1.9.1, as Word, WordPad, LibreOffice,
/// TextEdit and Google Docs write it. Nothing outside the file is fetched,
/// and macros and embedded objects are never run.
class RtfReader {
  RtfReader(this._bytes);

  static const maxBytes = 256 * 1024 * 1024;
  static const _maxDepth = 1024;
  static const _maxGroups = 20000000;
  static const _maxEntries = 10000;
  static const _maxNameLength = 256;
  static const _maxInstruction = 4096;
  static const _maxPictureBytes = 64 * 1024 * 1024;
  static const _maxPicturesBytes = 160 * 1024 * 1024;

  /// Pixels of the cropped pictures cut to what shows, about ten seconds of
  /// decoding; later ones show whole.
  static const _maxCroppedPixels = 40000000;

  final Uint8List _bytes;
  final _budget = RtfBudget();
  final _notices = <DocumentNotice>{};
  final _spec = DocumentSpec();
  late final _body = RtfStory(_budget);
  final _stack = <_Group>[];
  var _groups = 0;

  /// Fallback characters of the last `\uN` still to skip.
  var _skip = 0;
  var _borderPending = false;
  var _pictureBytes = 0;
  var _croppedPixels = 0;

  /// The first byte of a double-byte character whose second byte is still to
  /// come, in the next token; -1 when there is none.
  var _leadByte = -1;
  var _leadCodePage = 0;

  var _codePage = 1252;
  int? _defaultFont;
  int? _defaultLanguage;
  _RunState? _defaultCharacter;
  _ParaState? _defaultParagraph;
  var _endnotesByDefault = false;
  var _defaultTab = 720;
  var _paperWidth = 12240;
  var _paperHeight = 15840;
  var _marginLeft = 1800;
  var _marginRight = 1800;
  var _marginTop = 1440;
  var _marginBottom = 1440;
  var _landscape = false;

  /// Written by TextEdit (Cocoa).
  var _cocoa = false;
  var _section = _Section();

  /// Whether the section the last `\sect` ended has a different first page.
  var _endedTitlePage = false;

  final _fonts = <int, _Font>{};
  final _colors = <String?>[];
  final _paragraphStyles = <int, _StyleDef>{};
  final _characterStyles = <int, _StyleDef>{};
  final _lists = <int, _ListEntry>{};
  final _overrides = <int, _Override>{};
  final _listIds = <int, int>{};

  /// The first list made of each list of the list table.
  final _firstLists = <_ListEntry, int>{};
  int? _pnBullets;

  RtfDocument read() {
    if (_bytes.length > maxBytes) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
    final tokenizer = RtfTokenizer(_bytes, start: _headerStart());
    _stack.add(_Group(_Text(_body), _RunState(), _ParaState()));
    loop:
    while (true) {
      switch (tokenizer.next()) {
        case RtfToken.end:
          break loop;
        case RtfToken.groupStart:
          _flushBytes();
          _skip = 0;
          if (_stack.length > _maxDepth) {
            throw DocumentProblemException(DocumentProblem.damaged);
          }
          if (++_groups > _maxGroups) {
            throw DocumentProblemException(DocumentProblem.tooLarge);
          }
          _stack.add(_stack.last.nested());
        case RtfToken.groupEnd:
          _flushBytes();
          _skip = 0;
          if (_stack.length <= 2) break loop;
          _endGroup();
        case RtfToken.word:
          _flushBytes();
          _word(tokenizer.word, tokenizer.parameter);
        case RtfToken.symbol:
          _symbol(tokenizer.value);
        case RtfToken.hex:
          _hex(tokenizer.value);
        case RtfToken.text:
          _text(tokenizer.start, tokenizer.end);
        case RtfToken.binary:
          _flushBytes();
          _binary(tokenizer.start, tokenizer.end);
      }
    }
    _flushBytes();
    while (_stack.length > 2) {
      _endGroup();
    }
    return _finish(_stack.last);
  }

  /// Where `{\rtf` starts, after a byte order mark and blank space.
  int _headerStart() {
    var start = 0;
    if (_bytes.length >= 3 &&
        _bytes[0] == 0xEF &&
        _bytes[1] == 0xBB &&
        _bytes[2] == 0xBF) {
      start = 3;
    }
    while (start < _bytes.length &&
        const {0x20, 0x09, 0x0A, 0x0D}.contains(_bytes[start])) {
      start++;
    }
    const header = [0x7B, 0x5C, 0x72, 0x74, 0x66];
    if (start + header.length > _bytes.length) {
      throw DocumentProblemException(DocumentProblem.notWordDocument);
    }
    for (var index = 0; index < header.length; index++) {
      if (_bytes[start + index] != header[index]) {
        throw DocumentProblemException(DocumentProblem.notWordDocument);
      }
    }
    return start;
  }

  _Group get _group => _stack.last;

  void _notice(DocumentNotice notice) => _notices.add(notice);

  void _endGroup() {
    final group = _stack.removeLast();
    if (group.owns) group.destination.close(this, group);
  }

  /// Makes [destination] the current group's, closing the one it had.
  void _begin(_Destination destination) {
    final group = _group;
    if (group.owns) group.destination.close(this, group);
    group
      ..destination = destination
      ..owns = true;
  }

  /// A new story starts with plain text and paragraph properties.
  void _beginStory(_Destination destination) {
    _group
      ..run = _RunState()
      ..para = _ParaState();
    _begin(destination);
  }

  // Tokens

  void _word(String word, int? parameter) {
    if (_skip > 0) {
      _skip--;
      return;
    }
    final group = _group;
    final ignorable = group.ignorable;
    group.ignorable = false;
    final destination = group.destination;
    if (destination.skips) {
      if (word == 'ud' && destination is _Upr) {
        group
          ..destination = destination.previous
          ..owns = false;
      }
      return;
    }
    if (destination.word(this, word, parameter)) return;
    if (_destinationWord(word, parameter, group)) return;
    if (_formattingWord(word, parameter, group)) return;
    if (_documentWord(word, parameter, group)) return;
    if (_structureWord(word, parameter, group)) return;
    if (ignorable) _begin(const _Skip());
  }

  void _symbol(int symbol) {
    if (_skip > 0) {
      _skip--;
      return;
    }
    // An escaped \, { or } can be the second byte of a double-byte character.
    if (_leadByte >= 0 &&
        (symbol == 0x5C || symbol == 0x7B || symbol == 0x7D)) {
      _doubleByteText(Uint8List.fromList([symbol]), _leadCodePage);
      return;
    }
    _flushBytes();
    final group = _group;
    if (symbol == 0x2A) {
      group.ignorable = true;
      return;
    }
    group.ignorable = false;
    if (group.destination.skips) return;
    switch (symbol) {
      case 0x7E:
        _emit(group, '\u{A0}');
      case 0x2D:
        _emit(group, '\u{AD}');
      case 0x5F:
        _emit(group, '\u{2011}');
      case 0x5C || 0x7B || 0x7D:
        _emit(group, String.fromCharCode(symbol));
      case 0x09:
        _emit(group, '\t');
      case 0x0A || 0x0D:
        _paragraphMark(group);
    }
  }

  void _hex(int byte) {
    if (_skip > 0) {
      _skip--;
      return;
    }
    final group = _group..ignorable = false;
    final destination = group.destination;
    if (destination.skips || destination is _Picture) return;
    final codePage = _textCodePage(group);
    if (_isDoubleByte(codePage)) {
      _doubleByteText(Uint8List.fromList([byte]), codePage);
      return;
    }
    destination.text(
      this,
      byte < 0x80
          ? String.fromCharCode(byte)
          : decodeCodePage([byte], codePage),
    );
  }

  void _text(int start, int end) {
    if (_skip > 0) {
      final skipped = math.min(_skip, end - start);
      _skip -= skipped;
      start += skipped;
      if (start >= end) return;
    }
    final group = _group..ignorable = false;
    final destination = group.destination;
    if (destination.skips) return;
    if (destination is _Picture) {
      destination.hex(_bytes, start, end);
      return;
    }
    final codePage = _textCodePage(group);
    if (_isDoubleByte(codePage)) {
      _doubleByteText(Uint8List.sublistView(_bytes, start, end), codePage);
      return;
    }
    var ascii = true;
    for (var index = start; index < end; index++) {
      if (_bytes[index] >= 0x80) {
        ascii = false;
        break;
      }
    }
    destination.text(
      this,
      ascii
          ? String.fromCharCodes(_bytes, start, end)
          : decodeCodePage(Uint8List.sublistView(_bytes, start, end), codePage),
    );
  }

  /// Text in a double-byte code page, whose characters can be split between
  /// tokens: Word writes `\'83A` for one character. A lead byte at the end
  /// waits for the next token.
  void _doubleByteText(Uint8List bytes, int codePage) {
    var start = 0;
    final lead = _leadByte;
    if (lead >= 0 && codePage == _leadCodePage && bytes.isNotEmpty) {
      _leadByte = -1;
      final paired = _isTrailByte(bytes[0], codePage);
      _emitDoubleByte(
        Uint8List.fromList([lead, if (paired) bytes[0]]),
        codePage,
      );
      if (paired) start = 1;
    }
    _flushBytes();
    var end = bytes.length;
    for (var index = start; index < end; index++) {
      if (!_isLeadByte(bytes[index], codePage)) continue;
      if (index + 1 == end) {
        _leadByte = bytes[index];
        _leadCodePage = codePage;
        end = index;
      } else if (_isTrailByte(bytes[index + 1], codePage)) {
        index++;
      }
    }
    if (end > start) {
      _emitDoubleByte(Uint8List.sublistView(bytes, start, end), codePage);
    }
  }

  /// Every token but text flushes a waiting lead byte, so its destination is
  /// still the current one.
  void _flushBytes() {
    final lead = _leadByte;
    if (lead < 0) return;
    _leadByte = -1;
    _emitDoubleByte(Uint8List.fromList([lead]), _leadCodePage);
  }

  void _emitDoubleByte(Uint8List bytes, int codePage) {
    final destination = _group.destination;
    final text = _decodeDoubleByte(bytes, codePage);
    if (destination.showsText && text.contains(_replacement)) {
      _notice(DocumentNotice.contentNotImported);
    }
    destination.text(this, text);
  }

  static const _replacement = '\u{FFFD}';

  /// Without the code page's table each character is replaced, never misread
  /// as Western text.
  static String _decodeDoubleByte(Uint8List bytes, int codePage) {
    if (isKnownCodePage(codePage)) return decodeCodePage(bytes, codePage);
    final out = StringBuffer();
    for (var index = 0; index < bytes.length; index++) {
      final byte = bytes[index];
      if (byte < 0x80) {
        out.writeCharCode(byte);
      } else if (codePage == 932 && byte >= 0xA1 && byte <= 0xDF) {
        out.writeCharCode(0xFF61 + byte - 0xA1);
      } else {
        if (_isLeadByte(byte, codePage) &&
            index + 1 < bytes.length &&
            _isTrailByte(bytes[index + 1], codePage)) {
          index++;
        }
        out.write(_replacement);
      }
    }
    return out.toString();
  }

  static bool _isDoubleByte(int codePage) =>
      const {932, 936, 949, 950, 1361}.contains(codePage);

  static bool _isLeadByte(int byte, int codePage) => switch (codePage) {
    932 => (byte >= 0x81 && byte <= 0x9F) || (byte >= 0xE0 && byte <= 0xFC),
    1361 =>
      (byte >= 0x84 && byte <= 0xD3) ||
          (byte >= 0xD8 && byte <= 0xDE) ||
          (byte >= 0xE0 && byte <= 0xF9),
    _ => byte >= 0x81 && byte <= 0xFE,
  };

  static bool _isTrailByte(int byte, int codePage) =>
      byte >= (codePage == 1361 ? 0x31 : 0x40) && byte <= 0xFE && byte != 0x7F;

  static bool _isReadableCodePage(int codePage) =>
      isKnownCodePage(codePage) || _isDoubleByte(codePage);

  /// The code page of a Windows font character set, double-byte ones too.
  static int? _codePageOfCharset(int charset) => switch (charset) {
    128 => 932,
    129 => 949,
    130 => 1361,
    134 => 936,
    136 => 950,
    _ => codePageOfCharset(charset),
  };

  void _binary(int start, int end) {
    if (_skip > 0) {
      _skip--;
      return;
    }
    final destination = _group.destination;
    if (destination is _Picture) destination.binary(_bytes, start, end);
  }

  /// Text of special characters, in the current destination.
  void _emit(_Group group, String text) => group.destination.text(this, text);

  int _codePageOf(_RunState run) =>
      _fonts[run.font ?? _defaultFont]?.codePage ?? _codePage;

  int _textCodePage(_Group group) =>
      group.destination.codePage(this) ?? _codePageOf(group.run);

  // Destinations

  bool _destinationWord(String word, int? parameter, _Group group) {
    final destination = group.destination;
    switch (word) {
      case 'fonttbl':
        _begin(_FontTable());
      case 'colortbl':
        _begin(_ColorTable());
      case 'stylesheet':
        group
          ..run = _RunState()
          ..para = _ParaState();
        _begin(_StyleSheet());
      case 'listtable':
        _begin(_ListTable());
      case 'listoverridetable':
        _begin(_OverrideTable());
      case 'defchp':
        group.run = _RunState();
        _begin(_Defaults(character: true));
      case 'defpap':
        group.para = _ParaState();
        _begin(_Defaults(character: false));
      case 'pict':
        _begin(_Picture(destination.pictureStory));
      case 'shppict' || 'shpinst':
        break;
      case 'field':
        final story = destination.story;
        if (story == null) break;
        final field = _Field(story, _stack.length);
        group.field = field;
        _begin(_FieldGroup(field));
      case 'fldinst' || 'fldrslt':
        final field = group.field;
        if (field == null || field.depth != _stack.length - 1) break;
        if (word == 'fldinst') {
          _begin(_FieldInstruction(field));
        } else {
          field.startResult();
          _begin(_Text(field.story));
        }
      case 'header' ||
          'headerr' ||
          'headerl' ||
          'headerf' ||
          'footer' ||
          'footerr' ||
          'footerl' ||
          'footerf':
        if (!identical(destination.story, _body)) {
          _begin(const _Skip());
          break;
        }
        final variant = switch (word.substring(word.length - 1)) {
          'l' => PageVariant.even,
          'f' => PageVariant.first,
          _ => PageVariant.normal,
        };
        _beginStory(
          _HeaderFooter(
            RtfStory(_budget),
            variant,
            footer: word.startsWith('footer'),
          ),
        );
      case 'footnote':
        if (!identical(destination.story, _body) || group.run.deleted) {
          _begin(const _Skip());
          break;
        }
        final format = _textFormat(group);
        _beginStory(_Note(RtfStory(_budget), _body, format));
      case 'bkmkstart':
        final story = destination.story;
        _begin(story == null ? const _Skip() : _Bookmark(story));
      case 'shp' || 'shpgrp':
        final shape = _Shape(
          // The shapes of a group are where the group is.
          destination is _ShapeGroup
              ? destination.shape.anchor
              : destination.story,
          isGroup: word == 'shpgrp',
        );
        group.shape = shape;
        _begin(_ShapeGroup(shape));
      case 'sp':
        final shape = group.shape;
        _begin(shape == null ? const _Skip() : _ShapeProperty(shape));
      case 'sn' || 'sv':
        if (destination is! _ShapeProperty) {
          _begin(const _Skip());
        } else if (word == 'sn') {
          _begin(_ShapeName(destination));
        } else {
          _begin(_ShapeValue(destination));
        }
      case 'shptxt':
        final shape = group.shape;
        if (shape == null) {
          _begin(const _Skip());
          break;
        }
        _beginStory(_TextBox(RtfStory(_budget), shape));
      case 'object':
        _notice(DocumentNotice.contentNotImported);
        _begin(_ObjectGroup(destination.story));
      case 'result':
        final story = destination is _ObjectGroup
            ? destination.resultStory
            : null;
        _begin(story == null ? const _Skip() : _Text(story));
      case 'nesttableprops':
        group.nestedTableProperties = true;
      case 'upr':
        group
          ..destination = _Upr(destination, closes: group.owns)
          ..owns = true;
      case 'pn':
        _begin(_Pn());
      case 'pntxta' || 'pntxtb':
        _begin(
          destination is _Pn
              ? _PnText(destination, after: word == 'pntxta')
              : const _Skip(),
        );
      case 'annotation':
        _notice(DocumentNotice.commentsHidden);
        _begin(const _Skip());
      case 'do' || 'mmath' || 'mmathPara':
        _notice(DocumentNotice.contentNotImported);
        _begin(const _Skip());
      default:
        if (!_skippedDestinations.contains(word)) return false;
        _begin(const _Skip());
    }
    return true;
  }

  static const _skippedDestinations = {
    'aftncn',
    'aftnsep',
    'aftnsepc',
    'atndate',
    'atnauthor',
    'atnicn',
    'atnid',
    'atnparent',
    'atnref',
    'atntime',
    'atrfend',
    'atrfstart',
    'background',
    'bkmkend',
    'blipuid',
    'colorschememapping',
    'datafield',
    'datastore',
    'docvar',
    'expandedcolortbl',
    'falt',
    'fchars',
    'filetbl',
    'fname',
    'formfield',
    'ftncn',
    'ftnsep',
    'ftnsepc',
    'generator',
    'info',
    'latentstyles',
    'lchars',
    'levelmarker',
    'listpicture',
    'listtext',
    'mmathPr',
    'nonesttables',
    'nonshppict',
    'objalias',
    'objclass',
    'objdata',
    'objname',
    'objsect',
    'panose',
    'password',
    'passwordhash',
    'pgdsctbl',
    'picprop',
    'pnseclvl',
    'pntext',
    'private',
    'protusertbl',
    'revtbl',
    'rsidtbl',
    'rxe',
    'shprslt',
    'tc',
    'tcn',
    'template',
    'themedata',
    'txe',
    'userprops',
    'wgrffmtfilter',
    'xe',
    'xmlnstbl',
  };

  // Character and paragraph formatting, sections and the document

  bool _formattingWord(String word, int? parameter, _Group group) {
    final run = group.run;
    final para = group.para;
    final on = parameter != 0;
    switch (word) {
      case 'plain':
        group.run = _RunState();
      case 'b':
        run.bold = on;
      case 'i':
        run.italic = on;
      case 'ul' ||
          'uld' ||
          'uldash' ||
          'uldashd' ||
          'uldashdd' ||
          'uldb' ||
          'ulhwave' ||
          'ulldash' ||
          'ulth' ||
          'ulthd' ||
          'ulthdash' ||
          'ulthdashd' ||
          'ulthdashdd' ||
          'ulthldash' ||
          'ululdbwave' ||
          'ulw' ||
          'ulwave':
        run.underline = on;
      case 'ulnone':
        run.underline = false;
      case 'strike' || 'striked':
        run.strike = on;
      case 'caps':
        run.caps = on;
      case 'scaps':
        run.smallCaps = on;
      case 'v':
        run.hidden = on;
      case 'fs':
        if (parameter != null && parameter > 0) run.halfPoints = parameter;
      case 'f':
        if (parameter != null) run.font = parameter;
      case 'cf':
        run.color = parameter ?? 0;
      case 'cb':
        run.cocoaBackground = parameter ?? 0;
      case 'highlight':
        run.highlight = parameter ?? 0;
      case 'chcbpat':
        run.shading = parameter ?? 0;
      case 'super':
        run.position = VerticalPosition.superscript;
      case 'sub':
        run.position = VerticalPosition.subscript;
      case 'nosupersub':
        run.position = null;
      case 'up':
        run.position = (parameter ?? 6) > 0
            ? VerticalPosition.superscript
            : null;
      case 'dn':
        run.position = (parameter ?? 6) > 0 ? VerticalPosition.subscript : null;
      case 'cs':
        run.characterStyle = parameter;
      case 'lang':
        run.language = parameter;
      case 'deleted':
        run.deleted = on;
        if (on) _notice(DocumentNotice.trackedChangesAccepted);
      case 'revised':
        if (on) _notice(DocumentNotice.trackedChangesAccepted);
      case 'pard':
        group.para = _ParaState();
      case 's':
        para.style = parameter ?? 0;
      case 'ql':
        para.align = ParagraphAlign.left;
      case 'qc':
        para.align = ParagraphAlign.center;
      case 'qr':
        para.align = ParagraphAlign.right;
      case 'qj' || 'qd' || 'qk' || 'qt':
        para.align = ParagraphAlign.justify;
      case 'li' || 'lin':
        para.left = parameter;
      case 'ri' || 'rin':
        para.right = parameter;
      case 'fi':
        para.firstLine = parameter;
      case 'sb':
        para.before = parameter;
      case 'sa':
        para.after = parameter;
      case 'sl':
        para.line = parameter ?? 0;
      case 'slmult':
        para.lineMultiple = parameter == 1;
      case 'keepn':
        para.keepNext = on;
      case 'keep':
        para.keepLines = on;
      case 'pagebb':
        para.pageBreakBefore = on;
      case 'contextualspace':
        para.contextual = on;
      case 'rtlpar':
        para.rightToLeft = true;
      case 'ltrpar':
        para.rightToLeft = null;
      case 'tqr':
        para.tabAlign = TabAlign.right;
      case 'tqc':
        para.tabAlign = TabAlign.center;
      case 'tqdec':
        para.tabAlign = TabAlign.decimal;
      case 'tldot' || 'tlmdot':
        para.tabLeader = TabLeader.dot;
      case 'tlhyph':
        para.tabLeader = TabLeader.hyphen;
      case 'tlul' || 'tlth':
        para.tabLeader = TabLeader.underscore;
      case 'tleq':
        para.tabLeader = TabLeader.none;
      case 'tx':
        para.addTab(parameter ?? 0);
      case 'tb':
        para.clearPendingTab();
      case 'intbl':
        para.inTable = true;
      case 'itap':
        para.nesting = (parameter ?? 0).clamp(0, RtfStory.maxTableDepth);
      case 'ls':
        para.listOverride = parameter;
      case 'ilvl':
        para.listLevel = math.max(parameter ?? 0, 0);
      case 'outlinelevel':
        para.outlineLevel = parameter;
      case 'dropcapli':
        para.dropCap = (parameter ?? 0) > 0;
      case 'uc':
        group.uc = (parameter ?? 1).clamp(0, 255);
      default:
        return false;
    }
    return true;
  }

  /// Page, section and document properties; headers and notes repeat
  /// some of them (Word writes `\sectd` in headers), which don't count.
  bool _documentWord(String word, int? parameter, _Group group) {
    if (!_documentWords.contains(word)) return false;
    if (!identical(group.destination.story, _body)) return true;
    final on = parameter != 0;
    switch (word) {
      case 'sectd':
        _section = _Section();
      case 'sbknone' || 'sbkcol':
        _section.kind = SectionKind.continuous;
      case 'sbkpage':
        _section.kind = SectionKind.nextPage;
      case 'sbkeven':
        _section.kind = SectionKind.evenPage;
      case 'sbkodd':
        _section.kind = SectionKind.oddPage;
      case 'pgwsxn':
        _section.width = parameter;
      case 'pghsxn':
        _section.height = parameter;
      case 'marglsxn':
        _section.left = parameter;
      case 'margrsxn':
        _section.right = parameter;
      case 'margtsxn':
        _section.top = parameter;
      case 'margbsxn':
        _section.bottom = parameter;
      case 'lndscpsxn':
        _section.landscape = on;
      case 'headery':
        _section.header = parameter;
      case 'footery':
        _section.footer = parameter;
      case 'titlepg':
        _section.titlePage = on;
      case 'cols':
        _section.columns = parameter;
      case 'colsx':
        _section.columnSpacing = parameter;
      case 'pgnrestart':
        _section.restartPages = on;
      case 'pgncont':
        _section.restartPages = false;
      case 'pgnstarts':
        _section.firstPage = parameter ?? 1;
      case 'pgndec':
        _section.pageNumbers = null;
      case 'pgnucrm':
        _section.pageNumbers = NumberFormat.upperRoman;
      case 'pgnlcrm':
        _section.pageNumbers = NumberFormat.lowerRoman;
      case 'pgnucltr':
        _section.pageNumbers = NumberFormat.upperLetter;
      case 'pgnlcltr':
        _section.pageNumbers = NumberFormat.lowerLetter;
      case 'paperw':
        _paperWidth = parameter ?? _paperWidth;
      case 'paperh':
        _paperHeight = parameter ?? _paperHeight;
      case 'margl':
        _marginLeft = parameter ?? _marginLeft;
      case 'margr':
        _marginRight = parameter ?? _marginRight;
      case 'margt':
        _marginTop = parameter ?? _marginTop;
      case 'margb':
        _marginBottom = parameter ?? _marginBottom;
      case 'landscape':
        _landscape = on;
      case 'facingp':
        _spec.differentOddEven = on;
      case 'deftab':
        if (parameter != null && parameter > 0) _defaultTab = parameter;
      case 'deflang':
        _defaultLanguage = parameter;
      case 'ansicpg':
        if (parameter != null && _isReadableCodePage(parameter)) {
          _codePage = parameter;
        }
      case 'ansi':
        _codePage = 1252;
      case 'mac':
        _codePage = 10000;
      case 'pc':
        _codePage = 437;
      case 'pca':
        _codePage = 850;
      case 'deff':
        _defaultFont = parameter;
      case 'cocoartf':
        _cocoa = true;
      case 'fet':
        _endnotesByDefault = parameter == 1;
    }
    return true;
  }

  static const _documentWords = {
    'ansi',
    'ansicpg',
    'cocoartf',
    'cols',
    'colsx',
    'deff',
    'deflang',
    'deftab',
    'facingp',
    'fet',
    'footery',
    'headery',
    'landscape',
    'lndscpsxn',
    'mac',
    'margb',
    'margbsxn',
    'margl',
    'marglsxn',
    'margr',
    'margrsxn',
    'margt',
    'margtsxn',
    'paperh',
    'paperw',
    'pc',
    'pca',
    'pghsxn',
    'pgncont',
    'pgndec',
    'pgnlcltr',
    'pgnlcrm',
    'pgnrestart',
    'pgnstarts',
    'pgnucltr',
    'pgnucrm',
    'pgwsxn',
    'sbkcol',
    'sbkeven',
    'sbknone',
    'sbkodd',
    'sbkpage',
    'sectd',
    'titlepg',
  };

  // Text structure: paragraphs, tables, breaks and special characters

  bool _structureWord(String word, int? parameter, _Group group) {
    switch (word) {
      case 'par':
        _paragraphMark(group);
      case 'cell' || 'nestcell':
        final story = group.destination.story;
        if (story == null || group.run.deleted) break;
        final level = _tableLevel(group.para);
        story.endCell(
          (inlines) => _paragraphSpec(inlines, group, story),
          word == 'cell' ? 1 : math.max(level, 2),
        );
      case 'row' || 'nestrow':
        final story = group.destination.story;
        if (story == null || group.run.deleted) break;
        final level = _tableLevel(group.para);
        story.endRow(
          (inlines) => _paragraphSpec(inlines, group, story),
          word == 'row' ? 1 : math.max(level, 2),
        );
      case 'sect':
        _sectionMark(group);
      case 'page':
        _inline(group, const BreakSpec(BreakKind.page));
      case 'column':
        _inline(group, const BreakSpec(BreakKind.column));
      case 'line' || 'lbr':
        _inline(group, const BreakSpec(BreakKind.line));
      case 'chpgn':
        _inline(
          group,
          FieldSpec('PAGE', result: '1', format: _textFormat(group)),
        );
      case 'chdate' || 'chdpl' || 'chdpa':
        _inline(group, FieldSpec('DATE', format: _textFormat(group)));
      case 'chtime':
        _inline(group, FieldSpec('TIME', format: _textFormat(group)));
      case 'sectnum':
        _inline(group, FieldSpec('SECTION', format: _textFormat(group)));
      case 'tab':
        _emit(group, '\t');
      case 'emdash':
        _emit(group, '\u{2014}');
      case 'endash':
        _emit(group, '\u{2013}');
      case 'emspace':
        _emit(group, '\u{2003}');
      case 'enspace':
        _emit(group, '\u{2002}');
      case 'qmspace':
        _emit(group, '\u{2005}');
      case 'bullet':
        _emit(group, '\u{2022}');
      case 'lquote':
        _emit(group, '\u{2018}');
      case 'rquote':
        _emit(group, '\u{2019}');
      case 'ldblquote':
        _emit(group, '\u{201C}');
      case 'rdblquote':
        _emit(group, '\u{201D}');
      case 'zwj':
        _emit(group, '\u{200D}');
      case 'zwnj':
        _emit(group, '\u{200C}');
      case 'zwbo':
        _emit(group, '\u{200B}');
      case 'ltrmark':
        _emit(group, '\u{200E}');
      case 'rtlmark':
        _emit(group, '\u{200F}');
      case 'u':
        if (parameter == null) break;
        final unit = (parameter < 0 ? parameter + 0x10000 : parameter) & 0xFFFF;
        if (unit != 0) _emit(group, String.fromCharCode(unit));
        _skip = group.uc;
      case 'trowd':
        _borderPending = false;
        group.destination.story?.startRow(_definitionLevel(group));
      case 'trleft':
        _row(group)?.left = parameter ?? 0;
      case 'trgaph':
        _row(group)?.gap = parameter ?? 0;
      case 'trhdr':
        _row(group)?.header = true;
      case 'trrh':
        _row(group)?.height = parameter;
      case 'trbrdrt' ||
          'trbrdrl' ||
          'trbrdrb' ||
          'trbrdrr' ||
          'trbrdrh' ||
          'trbrdrv' ||
          'clbrdrt' ||
          'clbrdrl' ||
          'clbrdrb' ||
          'clbrdrr':
        _borderPending = true;
      case 'brdrt' ||
          'brdrb' ||
          'brdrl' ||
          'brdrr' ||
          'box' ||
          'brdrbtw' ||
          'brdrbar' ||
          'brdrnone' ||
          'brdrnil' ||
          'brdrtbl':
        _borderPending = false;
      case 'clmrg':
        _row(group)?.pending.mergesWithPrevious = true;
      case 'clvmgf':
        _row(group)?.pending.vertical = CellMerge.restart;
      case 'clvmrg':
        _row(group)?.pending.vertical = CellMerge.continuation;
      case 'clcbpat' || 'clcbpatraw':
        _row(group)?.pending.fill = _colorAt(parameter);
      case 'clvertalt':
        _row(group)?.pending.align = CellAlign.top;
      case 'clvertalc':
        _row(group)?.pending.align = CellAlign.center;
      case 'clvertalb':
        _row(group)?.pending.align = CellAlign.bottom;
      case 'cellx':
        _row(group)?.closeCell(parameter ?? 0);
      case 'chftn' || 'chatn' || 'chftnsep' || 'chftnsepc':
        break;
      default:
        if (!word.startsWith('brdr') || _borderProperties.contains(word)) {
          return false;
        }
        if (_borderPending) _row(group)?.bordered = true;
    }
    return true;
  }

  static const _borderProperties = {'brdrw', 'brdrcf', 'brdrsp', 'brdrart'};

  /// Table nesting level of the paragraph: 0 outside tables.
  static int _tableLevel(_ParaState para) =>
      para.nesting > 0 ? para.nesting : (para.inTable ? 1 : 0);

  int _definitionLevel(_Group group) {
    final level = _tableLevel(group.para);
    return group.nestedTableProperties
        ? math.max(level, 2)
        : math.max(level, 1);
  }

  RtfRowDefinition? _row(_Group group) =>
      group.destination.story?.definition(_definitionLevel(group));

  void _inline(_Group group, InlineSpec inline) {
    final story = group.destination.story;
    if (story == null || group.run.deleted) return;
    story.paragraph.add(inline);
  }

  void _paragraphMark(_Group group) {
    final story = group.destination.story;
    if (story == null) return;
    // A deleted paragraph mark joins the paragraph with the next one, and
    // Word writes a drop cap as a paragraph of its own before the rest.
    if (group.run.deleted || group.para.dropCap) return;
    story.endParagraph(
      (inlines) => _paragraphSpec(inlines, group, story),
      _tableLevel(group.para),
    );
  }

  void _sectionMark(_Group group) {
    final story = group.destination.story;
    if (!identical(story, _body)) return;
    if (!_body.paragraph.isEmpty) {
      _body.endParagraph(
        (inlines) => _paragraphSpec(inlines, group, _body),
        _tableLevel(group.para),
      );
    }
    _body.add(SectionBreakSpec(_page(_section), kind: _section.kind));
    _endedTitlePage = _section.titlePage;
  }

  void _storyText(RtfStory story, String text) {
    final run = _group.run;
    if (run.deleted) return;
    var clean = text;
    for (var index = 0; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      if ((unit < 0x20 && unit != 0x09) || unit == 0x7F) {
        clean = text.replaceAll(_controlCharacters, '');
        break;
      }
    }
    story.paragraph.addText(clean, _textFormat(_group));
  }

  static final _controlCharacters = RegExp(
    r'[\u0000-\u0008\u000A-\u001F\u007F]',
  );

  // Conversions

  String? _colorAt(int? index) =>
      index == null || index < 0 || index >= _colors.length
      ? null
      : _colors[index];

  /// Without `\deff`, readers take the first font.
  String get _documentFont =>
      _fontName(_defaultCharacter?.font ?? _defaultFont ?? 0) ??
      'Times New Roman';

  String? _fontName(int? index) {
    final name = _fonts[index]?.name;
    return name == null || name.isEmpty ? null : name;
  }

  RunFormat _runFormat(_RunState run) {
    final half = run.halfPoints;
    return RunFormat(
      styleId: _characterStyles[run.characterStyle]?.id,
      font: _fontName(run.font),
      size: half == null ? null : half / 2,
      bold: run.bold,
      italic: run.italic,
      underline: run.underline,
      strike: run.strike,
      allCaps: run.caps,
      smallCaps: run.smallCaps,
      hidden: run.hidden,
      color: run.color == null ? null : (_colorAt(run.color) ?? 'auto'),
      background: _background(run),
      position: run.position,
    );
  }

  String? _background(_RunState run) {
    for (final index in [run.highlight, run.shading]) {
      if (index != null && index > 0) {
        final color = _colorAt(index);
        if (color != null) return color;
      }
    }
    // TextEdit turns the background off by painting it white.
    final cocoa = _colorAt(run.cocoaBackground);
    return cocoa == 'FFFFFF' ? null : cocoa;
  }

  static double? _points(int? twips) => twips == null ? null : twips / 20;

  static LineSpacing? _lineSpacing(_ParaState para) {
    final line = para.line;
    if (line == null) return null;
    if (line == 0) return const LineSpacing.multiple(1);
    if (para.lineMultiple) return LineSpacing.multiple(line.abs() / 240);
    return line > 0
        ? LineSpacing.atLeast(line / 20)
        : LineSpacing.exactly(-line / 20);
  }

  ParagraphFormat _paragraphFormat(_ParaState para, {ListRef? list}) =>
      ParagraphFormat(
        styleId: switch (_paragraphStyles[para.style]?.id) {
          'Normal' => null,
          final id => id,
        },
        align: para.align,
        indentLeft: _points(para.left),
        indentRight: _points(para.right),
        firstLine: _points(para.firstLine),
        spaceBefore: _points(para.before),
        spaceAfter: _points(para.after),
        lineSpacing: _lineSpacing(para),
        keepNext: para.keepNext,
        keepLines: para.keepLines,
        pageBreakBefore: para.pageBreakBefore,
        contextualSpacing: para.contextual,
        rightToLeft: para.rightToLeft,
        list: list,
        tabs: para.tabs,
      );

  ParagraphSpec _paragraphSpec(
    List<InlineSpec> inlines,
    _Group group,
    RtfStory story,
  ) {
    final para = group.para;
    final outline = para.outlineLevel;
    final styled = _paragraphStyles[para.style]?.headingLevel != null;
    final run = _textFormat(group);
    final format = _unlikeParagraph(
      _paragraphFormat(para, list: _listRef(para, story)),
      _inheritedParagraph(para.style),
    );
    _budget.spend(
      elements: format.tabs.length,
      text: RtfBudget.fontCost(run.font),
    );
    return ParagraphSpec(
      inlines,
      format: format,
      heading: !styled && outline != null && outline >= 0 && outline < 6
          ? outline + 1
          : null,
      // The mark only sets the height of an empty line.
      mark: RunFormat(font: run.font, size: run.size),
    );
  }

  // Writers repeat the style's formatting on every paragraph and run (Word
  // does); what the style already gives is left to it.

  /// The character formatting of text in [group], without what its styles
  /// give.
  RunFormat _textFormat(_Group group) => _unlikeRun(
    _runFormat(group.run),
    _inheritedRun(group.para.style, group.run.characterStyle),
  );

  final _paragraphCache = <int, ParagraphFormat>{};
  final _runCache = <(int, int?), RunFormat>{};

  void _stylesChanged() {
    _paragraphCache.clear();
    _runCache.clear();
  }

  List<_StyleDef> _chain(Map<int, _StyleDef> styles, int? number) {
    final chain = <_StyleDef>[];
    final seen = <int>{};
    var current = number;
    while (current != null && seen.add(current) && chain.length < 64) {
      final style = styles[current];
      if (style == null) break;
      chain.add(style);
      current = style.basedOn;
    }
    return chain.reversed.toList();
  }

  ParagraphFormat _inheritedParagraph(int style) =>
      _paragraphCache[style] ??= () {
        final defaults = _defaultParagraph;
        var format = const ParagraphFormat(
          align: ParagraphAlign.left,
          indentLeft: 0,
          indentRight: 0,
          firstLine: 0,
          spaceBefore: 0,
          spaceAfter: 0,
          lineSpacing: LineSpacing.multiple(1),
          keepNext: false,
          keepLines: false,
          pageBreakBefore: false,
          contextualSpacing: false,
          rightToLeft: false,
        );
        if (defaults != null) format = format.merge(_paragraphFormat(defaults));
        for (final definition in _chain(_paragraphStyles, style)) {
          format = format.merge(_paragraphFormat(definition.para));
        }
        return format;
      }();

  RunFormat _inheritedRun(int paragraphStyle, int? characterStyle) =>
      _runCache[(paragraphStyle, characterStyle)] ??= () {
        final defaults = _defaultCharacter;
        var format = RunFormat(
          font: _documentFont,
          size: 12,
          bold: false,
          italic: false,
          underline: false,
          strike: false,
          allCaps: false,
          smallCaps: false,
          hidden: false,
        );
        if (defaults != null) format = format.merge(_runFormat(defaults));
        for (final definition in [
          ..._chain(_paragraphStyles, paragraphStyle),
          ..._chain(_characterStyles, characterStyle),
        ]) {
          format = format.merge(_runFormat(definition.run));
        }
        return format;
      }();

  static ParagraphFormat _unlikeParagraph(
    ParagraphFormat format,
    ParagraphFormat inherited,
  ) {
    double? points(double? value, double? base) =>
        value != null && base != null && (value - base).abs() < 0.01
        ? null
        : value;
    T? other<T>(T? value, T? base) => value == base ? null : value;
    final line = format.lineSpacing;
    final baseLine = inherited.lineSpacing;
    final sameLine =
        line != null &&
        baseLine != null &&
        line.rule == baseLine.rule &&
        (line.value - baseLine.value).abs() < 0.001;
    final tabs = format.tabs;
    final sameTabs =
        tabs.length == inherited.tabs.length &&
        [
          for (final (index, tab) in tabs.indexed)
            tab.align == inherited.tabs[index].align &&
                tab.leader == inherited.tabs[index].leader &&
                (tab.position - inherited.tabs[index].position).abs() < 0.01,
        ].every((same) => same);
    return ParagraphFormat(
      styleId: format.styleId,
      align: other(format.align, inherited.align),
      indentLeft: points(format.indentLeft, inherited.indentLeft),
      indentRight: points(format.indentRight, inherited.indentRight),
      firstLine: points(format.firstLine, inherited.firstLine),
      spaceBefore: points(format.spaceBefore, inherited.spaceBefore),
      spaceAfter: points(format.spaceAfter, inherited.spaceAfter),
      lineSpacing: sameLine ? null : line,
      keepNext: other(format.keepNext, inherited.keepNext),
      keepLines: other(format.keepLines, inherited.keepLines),
      pageBreakBefore: other(format.pageBreakBefore, inherited.pageBreakBefore),
      contextualSpacing: other(
        format.contextualSpacing,
        inherited.contextualSpacing,
      ),
      rightToLeft: other(format.rightToLeft, inherited.rightToLeft),
      list: format.list,
      tabs: sameTabs ? const [] : tabs,
    );
  }

  static RunFormat _unlikeRun(RunFormat format, RunFormat inherited) {
    T? other<T>(T? value, T? base) => value == base ? null : value;
    String? color(String? value) => value == 'auto' ? null : value;
    final size = format.size;
    final baseSize = inherited.size;
    return RunFormat(
      styleId: format.styleId,
      font: other(format.font, inherited.font),
      size: size != null && baseSize != null && (size - baseSize).abs() < 0.01
          ? null
          : size,
      bold: other(format.bold, inherited.bold),
      italic: other(format.italic, inherited.italic),
      underline: other(format.underline, inherited.underline),
      strike: other(format.strike, inherited.strike),
      allCaps: other(format.allCaps, inherited.allCaps),
      smallCaps: other(format.smallCaps, inherited.smallCaps),
      hidden: other(format.hidden, inherited.hidden),
      color:
          format.color == null || color(format.color) == color(inherited.color)
          ? null
          : format.color,
      background: other(format.background, inherited.background),
      position: other(format.position, inherited.position),
    );
  }

  ListRef? _listRef(_ParaState para, RtfStory? story) {
    final override = para.listOverride;
    final pn = para.pn;
    // Some writers put \ls next to \pn without a list table: \pn says more.
    if (override != null &&
        override > 0 &&
        (pn == null || _hasList(override))) {
      story?.numbering = null;
      // Word's body text level: in no list, not even its style's.
      if (para.listLevel >= wordListLevels) return ListRef.none;
      final id = _listIds[override] ??= _wordList(override);
      return ListRef(id, para.listLevel);
    }
    // \pnlvlcont shows no number but keeps the list going.
    if (pn?.kind == _PnKind.none) return null;
    if (pn == null || story == null) {
      story?.numbering = null;
      return null;
    }
    if (pn.kind == _PnKind.bullet) {
      story.numbering = null;
      return ListRef(_pnBullets ??= _addList(ListSpec.bullets), 0);
    }
    final key = '${pn.format.name}|${pn.before}|${pn.after}';
    final current = story.numbering;
    if (current != null && current.key == key) {
      return ListRef(current.id, pn.level);
    }
    final id = _addList(
      () => ListSpec([
        for (var level = 0; level < 9; level++)
          ListLevelSpec(
            format: pn.format,
            text: '${pn.before}%${level + 1}${pn.after}',
            start: level == pn.level ? pn.start : 1,
          ),
      ]),
    );
    story.numbering = (key: key, id: id);
    return ListRef(id, pn.level);
  }

  int _addList(ListSpec Function() build) {
    if (_spec.lists.length >= _maxEntries) return _spec.lists.length;
    final list = build();
    _budget.spend(
      elements: list.levels.length,
      text: list.levels.fold(
        0,
        (cost, level) => cost + RtfBudget.fontCost(level.font),
      ),
    );
    return _spec.addList(list);
  }

  bool _hasList(int override) =>
      _lists[_overrides[override]?.listId]?.levels.isNotEmpty ?? false;

  /// The list of `\ls` [number]. As in Word, the `\ls` of one list of the
  /// list table count as one list, each starting again the levels it
  /// overrides. One that redefines what a level shows numbers on its own,
  /// since a list of the .docx that goes on counting another takes its
  /// levels.
  int _wordList(int number) {
    final override = _overrides[number];
    final list = _lists[override?.listId];
    if (override == null || list == null || list.levels.isEmpty) {
      return _addList(ListSpec.bullets);
    }
    final own = override.formats.entries.any(
      (entry) => !_showsAlike(
        entry.value,
        list.levels.elementAtOrNull(entry.key),
        restarted: override.starts.containsKey(entry.key),
      ),
    );
    final id = _addList(
      () => _listSpec(list, override, own ? null : _firstLists[list]),
    );
    if (!own) _firstLists.putIfAbsent(list, () => id);
    return id;
  }

  /// Whether [redefined] shows what [level] shows, wherever it places it.
  static bool _showsAlike(
    _LevelDef redefined,
    _LevelDef? level, {
    required bool restarted,
  }) =>
      level != null &&
      redefined.format == level.format &&
      redefined.text == level.text &&
      redefined.legal == level.legal &&
      (restarted || redefined.start == level.start) &&
      (redefined.format != NumberFormat.bullet || redefined.font == level.font);

  ListSpec _listSpec(_ListEntry list, _Override override, int? continues) {
    final bullets = list.levels.first.format == NumberFormat.bullet;
    final fallback = bullets ? ListSpec.bullets() : ListSpec.numbered();
    return ListSpec(
      [
        for (var index = 0; index < 9; index++)
          switch (override.formats[index] ??
              list.levels.elementAtOrNull(index)) {
            final level? => _levelSpec(level),
            null => fallback.levels[index],
          },
      ],
      continues: continues,
      restarts: override.starts,
    );
  }

  ListLevelSpec _levelSpec(_LevelDef level) {
    final firstLine = level.firstLine;
    return ListLevelSpec(
      format: level.format,
      text: level.format == NumberFormat.bullet && level.text.isEmpty
          ? '\u{2022}'
          : level.text,
      start: level.start.clamp(0, 32767),
      indentLeft: _points(level.left),
      hanging: firstLine == null ? 18 : math.max(-firstLine, 0) / 20,
      font: level.font,
      suffix: level.suffix,
      align: switch (level.directionalAlignment ?? level.alignment) {
        1 => NumberAlign.center,
        2 => NumberAlign.right,
        _ => NumberAlign.left,
      },
      legal: level.legal,
    );
  }

  // Pictures, fields, notes, shapes

  void _finishPicture(_Picture picture, _Group group) {
    final story = picture.story;
    if (group.run.deleted) return;
    if (story == null) {
      if (picture.lost) _notice(DocumentNotice.contentNotImported);
      return;
    }
    final data = picture.bytes;
    if (data.isEmpty && !picture.oversize) return;
    var file = picture.oversize ? null : _pictureFile(picture, data);
    if (file == null || _pictureBytes + file.bytes.length > _maxPicturesBytes) {
      _notice(DocumentNotice.contentNotImported);
      return;
    }
    var size = _pictureTwips(picture);
    if (size != null) {
      final cropped = _cropped(picture, file, size);
      if (cropped != null) {
        file = cropped;
        size = (
          width: size.width - picture.cropLeft - picture.cropRight,
          height: size.height - picture.cropTop - picture.cropBottom,
        );
      }
    }
    _pictureBytes += file.bytes.length;
    story.paragraph.add(
      ImageSpec(
        file.bytes,
        file.mime,
        width: size == null ? null : size.width * picture.scaleX / 2000,
        height: size == null ? null : size.height * picture.scaleY / 2000,
      ),
    );
  }

  /// What shows of a cropped picture; null shows it whole, at the size it
  /// has uncropped, when it can't be cut (metafiles) or the time set aside
  /// for cutting pictures is spent.
  ({Uint8List bytes, String mime})? _cropped(
    _Picture picture,
    ({Uint8List bytes, String mime}) file,
    ({double width, double height}) size,
  ) {
    final (left, top, right, bottom) = (
      picture.cropLeft,
      picture.cropTop,
      picture.cropRight,
      picture.cropBottom,
    );
    if (left + top + right + bottom == 0) return null;
    final pixels = imagePixelSize(file.bytes);
    if (pixels == null ||
        pixels.width > _maxCroppedPixels ||
        pixels.height > _maxCroppedPixels) {
      return null;
    }
    final count = pixels.width * pixels.height;
    if (_croppedPixels + count > _maxCroppedPixels) return null;
    _croppedPixels += count;
    return cropPicture(
      file.bytes,
      file.mime,
      left: left / size.width,
      top: top / size.height,
      right: right / size.width,
      bottom: bottom / size.height,
    );
  }

  ({Uint8List bytes, String mime})? _pictureFile(
    _Picture picture,
    Uint8List data,
  ) {
    if (isPng(data)) return (bytes: data, mime: 'image/png');
    if (isJpeg(data)) return (bytes: data, mime: 'image/jpeg');
    if (isGif(data)) return (bytes: data, mime: 'image/gif');
    if (isEmf(data)) return (bytes: data, mime: 'image/x-emf');
    final file = switch (picture.type) {
      _PictureType.wmf => placeableWmf(
        data,
        width: picture.width ?? 0,
        height: picture.height ?? 0,
      ),
      _PictureType.dib => bitmapFromDib(data),
      _PictureType.ddb => bitmapFromDdb(
        data,
        width: picture.width ?? 0,
        height: picture.height ?? 0,
        bitsPerPixel: picture.bitsPerPixel,
        widthBytes: picture.widthBytes,
      ),
      _ => null,
    };
    if (file == null) return null;
    return (
      bytes: file,
      mime: picture.type == _PictureType.wmf ? 'image/x-wmf' : 'image/bmp',
    );
  }

  /// Twips of the whole picture before scaling, from the goal size or the
  /// picture's own size: pixels at 96 dpi, or hundredths of a millimeter for
  /// metafiles.
  ({double width, double height})? _pictureTwips(_Picture picture) {
    final metafile =
        picture.type == _PictureType.wmf || picture.type == _PictureType.emf;
    double? twips(int? goal, int? own) {
      if (goal != null && goal > 0) return goal.toDouble();
      if (own == null || own <= 0) return null;
      return metafile ? own * 1440 / 2540 : own * 15.0;
    }

    final width = twips(picture.goalWidth, picture.width);
    final height = twips(picture.goalHeight, picture.height);
    if (width == null || height == null) return null;
    return (width: width, height: height);
  }

  void _finishField(_Field field, _Group group) {
    final instruction = field.instruction.toString().trim();
    final name = instruction.split(RegExp(r'\s+')).first.toUpperCase();
    final paragraph = field.story.paragraph;
    if (!field.hasResult) {
      if (instruction.isNotEmpty && name != 'HYPERLINK') {
        paragraph.add(FieldSpec(instruction, format: _textFormat(group)));
      }
      return;
    }
    // A result that spans paragraphs stays as it was read.
    if (!identical(paragraph, field.paragraph)) return;
    paragraph.flush();
    final inlines = paragraph.inlines;
    if (field.start > inlines.length) return;
    final children = inlines.sublist(field.start);
    final InlineSpec replacement;
    if (name == 'HYPERLINK') {
      final target = _hyperlinkTarget(instruction);
      if (target == null || children.isEmpty) return;
      replacement = LinkSpec(target, [
        for (final child in children)
          if (child is LinkSpec) ...child.children else child,
      ], hyperlinkStyle: false);
    } else if (children.every((child) => child is TextSpec)) {
      final texts = children.cast<TextSpec>();
      replacement = FieldSpec(
        instruction,
        result: texts.map((text) => text.text).join(),
        format: texts.isEmpty ? _textFormat(group) : texts.first.format,
      );
    } else {
      return;
    }
    inlines
      ..removeRange(field.start, inlines.length)
      ..add(replacement);
  }

  /// `HYPERLINK "address" \l "bookmark"`, as a link target.
  static String? _hyperlinkTarget(String instruction) {
    final arguments = _fieldArguments(instruction);
    String? address;
    String? anchor;
    for (var index = 1; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument.isSwitch) {
        final name = argument.text.toLowerCase();
        if (const {r'\l', r'\o', r'\t'}.contains(name) &&
            index + 1 < arguments.length) {
          index++;
          if (name == r'\l') anchor = arguments[index].text;
        }
        continue;
      }
      address ??= argument.text;
    }
    if (anchor != null && anchor.isNotEmpty) {
      return address == null || address.isEmpty
          ? '#$anchor'
          : '$address#$anchor';
    }
    return address == null || address.isEmpty ? null : address;
  }

  static List<({String text, bool isSwitch})> _fieldArguments(String text) {
    final arguments = <({String text, bool isSwitch})>[];
    var index = 0;
    bool blank(int index) => text[index].trim().isEmpty;
    while (index < text.length) {
      if (blank(index)) {
        index++;
        continue;
      }
      if (text[index] == '"') {
        final quoted = StringBuffer();
        index++;
        while (index < text.length && text[index] != '"') {
          if (text[index] == r'\' && index + 1 < text.length) index++;
          quoted.write(text[index]);
          index++;
        }
        index++;
        arguments.add((text: quoted.toString(), isSwitch: false));
        continue;
      }
      final start = index;
      while (index < text.length && !blank(index)) {
        index++;
      }
      final word = text.substring(start, index);
      arguments.add((text: word, isSwitch: word.startsWith(r'\')));
    }
    return arguments;
  }

  List<BlockSpec> _finishStory(RtfStory story, _Group group) {
    if (!story.paragraph.isEmpty) {
      story.endParagraph(
        (inlines) => _paragraphSpec(inlines, group, story),
        _tableLevel(group.para),
      );
    }
    return story.finish();
  }

  void _finishShape(_Shape shape) {
    if (shape.isGroup || shape.picture) return;
    final blocks = shape.text;
    final anchor = shape.anchor;
    final simple =
        blocks != null &&
        blocks.every(
          (block) =>
              block is ParagraphSpec &&
              block.inlines.every(
                (inline) => inline is TextSpec || inline is BreakSpec,
              ),
        );
    final hasText =
        blocks != null &&
        blocks.any(
          (block) =>
              block is ParagraphSpec &&
              block.inlines.any(
                (inline) => inline is TextSpec && inline.text.trim().isNotEmpty,
              ),
        );
    if (simple && hasText && anchor != null) {
      anchor.defer(blocks);
      return;
    }
    _notice(DocumentNotice.contentNotImported);
  }

  // Tables of the document's header

  void _addStyle(_StyleEntry entry, _Group group) {
    if (entry.kind == _StyleKind.other) return;
    final character = entry.kind == _StyleKind.character;
    final styles = character ? _characterStyles : _paragraphStyles;
    if (styles.length >= _maxEntries) return;
    _budget.spend(
      elements: 1 + group.para.tabs.length,
      text: RtfBudget.fontCost(_fontName(group.run.font)),
    );
    final name = entry.name.toString().replaceAll(';', '').trim();
    final lower = name.toLowerCase();
    if (character && lower == 'default paragraph font') return;
    final number = entry.number;
    final id = !character && number == 0
        ? 'Normal'
        : switch ((lower, character)) {
            ('hyperlink', true) => 'Hyperlink',
            ('footnote text', false) => 'FootnoteText',
            ('footnote reference', true) => 'FootnoteReference',
            ('endnote text', false) => 'EndnoteText',
            ('endnote reference', true) => 'EndnoteReference',
            _ => character ? 'RtfChar$number' : 'RtfPara$number',
          };
    _stylesChanged();
    styles[number] = _StyleDef(
      id: id,
      name: name.isEmpty ? id : name,
      character: character,
      basedOn: entry.basedOn,
      next: entry.next,
      run: group.run,
      para: group.para,
    );
  }

  /// Heading levels: styles named `heading N` first, then outline levels.
  void _assignHeadingLevels() {
    final taken = <int>{};
    for (final style in _paragraphStyles.values) {
      final match = RegExp(
        r'^heading\s*([1-9])$',
      ).firstMatch(style.name.split(',').first.trim().toLowerCase());
      if (match == null) continue;
      final level = int.parse(match.group(1)!);
      if (taken.add(level)) style.headingLevel = level;
    }
    for (final style in _paragraphStyles.values) {
      final outline = style.para.outlineLevel;
      if (style.headingLevel != null || outline == null) continue;
      if (outline >= 0 && outline <= 8 && taken.add(outline + 1)) {
        style.headingLevel = outline + 1;
      }
    }
  }

  List<StyleSpec> _styleSpecs() => [
    for (final style in _paragraphStyles.values)
      StyleSpec.paragraph(
        style.id,
        style.name,
        basedOn: _paragraphStyles[style.basedOn]?.id,
        next: _paragraphStyles[style.next]?.id,
        run: _runFormat(style.run),
        paragraph: _paragraphFormat(
          style.para,
          list: _listRef(style.para, null),
        ),
        headingLevel: style.headingLevel,
      ),
    for (final style in _characterStyles.values)
      StyleSpec.character(
        style.id,
        style.name,
        basedOn: _characterStyles[style.basedOn]?.id,
        run: _runFormat(style.run),
      ),
  ];

  void _addFont(int number, String name, int? codePage) {
    _stylesChanged();
    if (_fonts.length < _maxEntries || _fonts.containsKey(number)) {
      _fonts[number] = _Font(
        _cocoa ? _familyOfPostScriptName(name) : name,
        codePage,
      );
    }
  }

  /// TextEdit names fonts the PostScript way (`TimesNewRomanPSMT`,
  /// `Helvetica-Bold`); other programs know them by family.
  static String _familyOfPostScriptName(String name) {
    if (name.isEmpty || name.contains(' ') || name.startsWith('.')) {
      return name;
    }
    final dash = name.indexOf('-');
    final family = (dash > 0 ? name.substring(0, dash) : name)
        .replaceFirst(RegExp(r'(PSMT|PS|MT)$'), '')
        .replaceAllMapped(
          RegExp('([a-z])([A-Z])'),
          (match) => '${match[1]} ${match[2]}',
        );
    return family.isEmpty ? name : family;
  }

  void _addColor(String? color) {
    if (_colors.length < _maxEntries) _colors.add(color);
  }

  // Page and document

  PageSpec _page(_Section section) {
    var width = (section.width ?? _paperWidth).clamp(1440, 31680);
    var height = (section.height ?? _paperHeight).clamp(1440, 31680);
    final landscape =
        section.landscape || (section.width == null && _landscape);
    if (landscape && width < height) (width, height) = (height, width);
    var left = (section.left ?? _marginLeft).clamp(0, 31680);
    var right = (section.right ?? _marginRight).clamp(0, 31680);
    var top = (section.top ?? _marginTop).abs().clamp(0, 31680);
    var bottom = (section.bottom ?? _marginBottom).abs().clamp(0, 31680);
    if (left + right > width - 720) left = right = math.min(1440, width ~/ 4);
    if (top + bottom > height - 720) top = bottom = math.min(1440, height ~/ 4);
    return PageSpec(
      width: width / 20,
      height: height / 20,
      margins: EdgeInsets.fromLTRB(
        left / 20,
        top / 20,
        right / 20,
        bottom / 20,
      ),
      headerDistance: (section.header ?? 720).clamp(0, height ~/ 2) / 20,
      footerDistance: (section.footer ?? 720).clamp(0, height ~/ 2) / 20,
      columns: (section.columns ?? 1).clamp(1, 45),
      columnSpacing: (section.columnSpacing ?? 720).clamp(0, 31680) / 20,
      numberFormat: section.pageNumbers,
      firstNumber: section.restartPages
          ? section.firstPage.clamp(0, 32767)
          : null,
    );
  }

  RtfDocument _finish(_Group group) {
    final blocks = _finishStory(_body, group);
    var page = _page(_section);
    var kind = _section.kind;
    var titlePage = _section.titlePage;
    // Word ignores a \sect that nothing follows, as some writers end with.
    if (blocks.lastOrNull case final SectionBreakSpec last) {
      blocks.removeLast();
      (page, kind, titlePage) = (last.page, last.kind, _endedTitlePage);
    }
    final defaults = _defaultCharacter;
    final paragraph = _defaultParagraph;
    final size = defaults?.halfPoints;
    _spec
      ..page = page
      ..lastSectionKind = kind
      ..differentFirstPage = titlePage
      ..defaultRun = RunFormat(
        font: _documentFont,
        size: size == null ? 12 : size / 2,
      )
      ..defaultParagraph = ParagraphFormat(
        align: paragraph?.align,
        indentLeft: _points(paragraph?.left),
        indentRight: _points(paragraph?.right),
        firstLine: _points(paragraph?.firstLine),
        spaceBefore: _points(paragraph?.before) ?? 0,
        spaceAfter: _points(paragraph?.after) ?? 0,
        lineSpacing:
            (paragraph == null ? null : _lineSpacing(paragraph)) ??
            const LineSpacing.multiple(1),
      )
      ..defaultTabStop = _defaultTab / 20
      ..language = [
        defaults?.language,
        _paragraphStyles[0]?.run.language,
        _defaultLanguage,
      ].map((id) => id == null ? null : languageTagOf(id)).nonNulls.firstOrNull;
    _spec.styles.addAll(_styleSpecs());
    _spec.body.addAll(blocks);
    return (spec: _spec, notices: _notices);
  }
}

class _RunState {
  int? font;
  int? halfPoints;
  bool? bold;
  bool? italic;
  bool? underline;
  bool? strike;
  bool? caps;
  bool? smallCaps;
  bool? hidden;
  int? color;
  int? highlight;
  int? shading;
  int? cocoaBackground;
  VerticalPosition? position;
  int? characterStyle;
  int? language;
  var deleted = false;

  _RunState copy() => _RunState()
    ..font = font
    ..halfPoints = halfPoints
    ..bold = bold
    ..italic = italic
    ..underline = underline
    ..strike = strike
    ..caps = caps
    ..smallCaps = smallCaps
    ..hidden = hidden
    ..color = color
    ..highlight = highlight
    ..shading = shading
    ..cocoaBackground = cocoaBackground
    ..position = position
    ..characterStyle = characterStyle
    ..language = language
    ..deleted = deleted;
}

enum _PnKind { bullet, numbered, none }

/// Old-style paragraph numbering (`\pn`).
class _PnDef {
  var kind = _PnKind.numbered;
  var format = NumberFormat.decimal;
  var start = 1;
  var level = 0;
  var before = '';
  var after = '';
}

class _ParaState {
  var style = 0;
  ParagraphAlign? align;
  int? left;
  int? right;
  int? firstLine;
  int? before;
  int? after;
  int? line;
  var lineMultiple = false;
  bool? keepNext;
  bool? keepLines;
  bool? pageBreakBefore;
  bool? contextual;
  bool? rightToLeft;
  var tabs = const <TabStop>[];
  var tabAlign = TabAlign.left;
  var tabLeader = TabLeader.none;
  var inTable = false;
  var nesting = 0;
  int? listOverride;
  var listLevel = 0;
  _PnDef? pn;
  int? outlineLevel;
  var dropCap = false;

  void addTab(int position) {
    if (tabs.length < 64) {
      tabs = [
        ...tabs,
        TabStop(position / 20, align: tabAlign, leader: tabLeader),
      ];
    }
    clearPendingTab();
  }

  void clearPendingTab() {
    tabAlign = TabAlign.left;
    tabLeader = TabLeader.none;
  }

  _ParaState copy() => _ParaState()
    ..style = style
    ..align = align
    ..left = left
    ..right = right
    ..firstLine = firstLine
    ..before = before
    ..after = after
    ..line = line
    ..lineMultiple = lineMultiple
    ..keepNext = keepNext
    ..keepLines = keepLines
    ..pageBreakBefore = pageBreakBefore
    ..contextual = contextual
    ..rightToLeft = rightToLeft
    ..tabs = tabs
    ..tabAlign = tabAlign
    ..tabLeader = tabLeader
    ..inTable = inTable
    ..nesting = nesting
    ..listOverride = listOverride
    ..listLevel = listLevel
    ..pn = pn
    ..outlineLevel = outlineLevel
    ..dropCap = dropCap;
}

class _Section {
  int? width;
  int? height;
  int? left;
  int? right;
  int? top;
  int? bottom;
  int? header;
  int? footer;
  int? columns;
  int? columnSpacing;
  var landscape = false;
  var titlePage = false;
  var kind = SectionKind.nextPage;

  /// Null numbers the pages 1, 2, 3.
  NumberFormat? pageNumbers;

  /// Without it, the pages go on from the previous section's numbers.
  var restartPages = false;
  var firstPage = 1;
}

class _Font {
  const _Font(this.name, this.codePage);

  final String name;
  final int? codePage;
}

enum _StyleKind { paragraph, character, other }

class _StyleDef {
  _StyleDef({
    required this.id,
    required this.name,
    required this.character,
    required this.basedOn,
    required this.next,
    required this.run,
    required this.para,
  });

  final String id;
  final String name;
  final bool character;
  final int? basedOn;
  final int? next;
  final _RunState run;
  final _ParaState para;
  int? headingLevel;
}

/// State of an RTF group; a nested group starts with a copy of it.
class _Group {
  _Group(this.destination, this.run, this.para);

  _Destination destination;

  /// The destination started in this group, which closes it.
  var owns = false;
  _RunState run;
  _ParaState para;
  var uc = 1;

  /// `\*` came before the next control word.
  var ignorable = false;
  var nestedTableProperties = false;
  _Field? field;
  _Shape? shape;

  _Group nested() {
    final inner = destination.nested();
    return _Group(inner, run.copy(), para.copy())
      ..owns = !identical(inner, destination)
      ..uc = uc
      ..nestedTableProperties = nestedTableProperties
      ..field = field
      ..shape = shape;
  }
}

/// Adds what fits of [text] to [buffer], which never grows past [max]: one
/// token can be as long as the file.
void _appendUpTo(StringBuffer buffer, String text, int max) {
  final room = max - buffer.length;
  if (room <= 0) return;
  buffer.write(text.length <= room ? text : text.substring(0, room));
}

/// Where the text and control words of a group go.
abstract class _Destination {
  const _Destination();

  /// Everything in it is ignored.
  bool get skips => false;

  /// The story that receives its text.
  RtfStory? get story => null;

  /// The story that receives its pictures.
  RtfStory? get pictureStory => story;

  /// The code page of its text, when the current font's isn't it.
  int? codePage(RtfReader reader) => null;

  /// Its text shows in the document, unlike names of fonts or styles.
  bool get showsText => false;

  void text(RtfReader reader, String text) {}

  /// Handles a control word that means something here.
  bool word(RtfReader reader, String word, int? parameter) => false;

  /// The group that started it ended.
  void close(RtfReader reader, _Group group) {}

  /// The destination of the groups nested in it.
  _Destination nested() => this;
}

class _Skip extends _Destination {
  const _Skip();

  @override
  bool get skips => true;
}

/// `\upr`: the text before `\ud` repeats the Unicode text without it.
class _Upr extends _Destination {
  _Upr(this.previous, {required this.closes});

  final _Destination previous;

  /// The group owned [previous], which still ends with it.
  final bool closes;

  @override
  bool get skips => true;

  @override
  void close(RtfReader reader, _Group group) {
    if (closes) previous.close(reader, group);
  }
}

class _Text extends _Destination {
  _Text(this.story);

  @override
  final RtfStory story;

  @override
  bool get showsText => true;

  @override
  void text(RtfReader reader, String text) => reader._storyText(story, text);
}

class _HeaderFooter extends _Text {
  _HeaderFooter(super.story, this.variant, {required this.footer});

  final PageVariant variant;
  final bool footer;

  /// The editor has one set of headers and footers: each section's replaces
  /// the one before, and a later section without one keeps it.
  @override
  void close(RtfReader reader, _Group group) {
    final blocks = reader._finishStory(story, group);
    final stories = footer ? reader._spec.footers : reader._spec.headers;
    final earlier = stories[variant];
    if (earlier != null && !sameBlocks(earlier, blocks)) {
      reader._notice(DocumentNotice.contentNotImported);
    }
    stories[variant] = blocks;
  }
}

class _Note extends _Text {
  _Note(super.story, this.anchor, this.format);

  final RtfStory anchor;
  final RunFormat format;
  var alternate = false;

  @override
  bool word(RtfReader reader, String word, int? parameter) {
    if (word != 'ftnalt') return false;
    alternate = true;
    return true;
  }

  @override
  void close(RtfReader reader, _Group group) {
    final blocks = reader._finishStory(story, group);
    // \fet1 means every note is an endnote; \ftnalt marks one in any case.
    final endnote = alternate || reader._endnotesByDefault;
    anchor.paragraph.add(
      NoteSpec(
        endnote ? NoteKind.endnote : NoteKind.footnote,
        blocks,
        format: format,
      ),
    );
  }
}

class _TextBox extends _Text {
  _TextBox(super.story, this.shape);

  final _Shape shape;

  @override
  void close(RtfReader reader, _Group group) {
    shape.text = reader._finishStory(story, group);
  }
}

class _Bookmark extends _Destination {
  _Bookmark(this._story);

  final RtfStory _story;
  final _name = StringBuffer();

  @override
  void text(RtfReader reader, String text) =>
      _appendUpTo(_name, text, RtfReader._maxNameLength);

  @override
  void close(RtfReader reader, _Group group) {
    final name = _name.toString().trim();
    if (name.isNotEmpty && name != '_GoBack') {
      _story.paragraph.add(BookmarkSpec(name));
    }
  }
}

class _FontTable extends _Destination {
  int? _number;
  int? _charset;
  int? _codePage;
  final _name = StringBuffer();

  /// `\falt`: another name of the font, often in English.
  final _alternate = StringBuffer();

  @override
  bool word(RtfReader reader, String word, int? parameter) {
    switch (word) {
      case 'f':
        _commit(reader);
        _number = parameter;
      case 'fcharset':
        _charset = parameter;
      case 'cpg':
        _codePage = parameter;
      case 'falt':
        reader._begin(_FontAlternate(this));
      default:
        return false;
    }
    return true;
  }

  /// The code page of the font being defined, which its name is written in.
  int? get _entryCodePage {
    final codePage = _codePage;
    if (codePage != null && RtfReader._isReadableCodePage(codePage)) {
      return codePage;
    }
    final charset = _charset;
    return charset == null ? null : RtfReader._codePageOfCharset(charset);
  }

  @override
  int? codePage(RtfReader reader) => _entryCodePage ?? reader._codePage;

  @override
  void text(RtfReader reader, String text) {
    for (final part in text.split(';').indexed) {
      if (part.$1 > 0) _commit(reader);
      _appendUpTo(_name, part.$2, RtfReader._maxNameLength);
    }
  }

  void _commit(RtfReader reader) {
    final number = _number;
    if (number != null) {
      var name = _name.toString().trim();
      final alternate = _alternate.toString().trim();
      if (name.contains(RtfReader._replacement) &&
          alternate.isNotEmpty &&
          !alternate.contains(RtfReader._replacement)) {
        name = alternate;
      }
      reader._addFont(number, name, _entryCodePage);
    }
    _number = null;
    _charset = null;
    _codePage = null;
    _name.clear();
    _alternate.clear();
  }

  @override
  void close(RtfReader reader, _Group group) => _commit(reader);
}

class _FontAlternate extends _Destination {
  _FontAlternate(this._table);

  final _FontTable _table;

  @override
  int? codePage(RtfReader reader) => _table.codePage(reader);

  @override
  void text(RtfReader reader, String text) =>
      _appendUpTo(_table._alternate, text, RtfReader._maxNameLength);
}

class _ColorTable extends _Destination {
  int? _red;
  int? _green;
  int? _blue;

  @override
  bool word(RtfReader reader, String word, int? parameter) {
    final value = (parameter ?? 0).clamp(0, 255);
    switch (word) {
      case 'red':
        _red = value;
      case 'green':
        _green = value;
      case 'blue':
        _blue = value;
      default:
        return false;
    }
    return true;
  }

  @override
  void text(RtfReader reader, String text) {
    for (var index = 0; index < text.length; index++) {
      if (text.codeUnitAt(index) != 0x3B) continue;
      if (_red == null && _green == null && _blue == null) {
        reader._addColor(null);
      } else {
        reader._addColor(
          [_red, _green, _blue]
              .map((value) => (value ?? 0).toRadixString(16).padLeft(2, '0'))
              .join()
              .toUpperCase(),
        );
      }
      _red = _green = _blue = null;
    }
  }
}

class _StyleSheet extends _Destination {
  @override
  _Destination nested() => _StyleEntry();

  @override
  void close(RtfReader reader, _Group group) => reader._assignHeadingLevels();
}

class _StyleEntry extends _Destination {
  var kind = _StyleKind.paragraph;
  var number = 0;
  int? basedOn;
  int? next;
  final name = StringBuffer();

  /// Where the style's formatting is: the entry itself, or the Unicode copy
  /// inside `\ud`.
  _Group? formatting;

  @override
  bool word(RtfReader reader, String word, int? parameter) {
    switch (word) {
      case 's':
        kind = _StyleKind.paragraph;
        number = parameter ?? 0;
        formatting = reader._group;
      case 'cs':
        kind = _StyleKind.character;
        number = parameter ?? 0;
        formatting = reader._group;
      case 'ds' || 'ts':
        kind = _StyleKind.other;
      case 'sbasedon':
        basedOn = parameter;
      case 'snext':
        next = parameter;
      default:
        return false;
    }
    return true;
  }

  @override
  void text(RtfReader reader, String text) =>
      _appendUpTo(name, text, RtfReader._maxNameLength);

  @override
  void close(RtfReader reader, _Group group) =>
      reader._addStyle(this, formatting ?? group);
}

class _ListTable extends _Destination {
  @override
  bool word(RtfReader reader, String word, int? parameter) {
    if (word != 'list') return false;
    reader._begin(_ListEntry());
    return true;
  }
}

class _LevelDef {
  var format = NumberFormat.decimal;
  var text = '';
  var start = 1;
  int? left;
  int? firstLine;
  String? font;
  var suffix = ListSuffix.tab;
  var legal = false;

  /// `\leveljc`; `\leveljcn`, which follows the paragraph's direction as
  /// w:lvlJc does, wins over it.
  int? alignment;
  int? directionalAlignment;
}

class _ListEntry extends _Destination {
  int? id;
  final levels = <_LevelDef>[];

  @override
  bool word(RtfReader reader, String word, int? parameter) {
    switch (word) {
      case 'listlevel':
        reader._beginStory(_ListLevel(_add));
      case 'listid':
        id = parameter;
      case 'listname':
        reader._begin(const _Skip());
      default:
        return false;
    }
    return true;
  }

  void _add(_LevelDef level) {
    if (levels.length < 9) levels.add(level);
  }

  @override
  void close(RtfReader reader, _Group group) {
    final id = this.id;
    if (id != null && reader._lists.length < RtfReader._maxEntries) {
      reader._lists[id] = this;
    }
  }
}

class _ListLevel extends _Destination {
  _ListLevel(this._done);

  /// Takes the level once its group ends.
  final void Function(_LevelDef level) _done;
  final _level = _LevelDef();

  @override
  bool word(RtfReader reader, String word, int? parameter) {
    switch (word) {
      case 'levelnfc' || 'levelnfcn':
        _level.format = switch (parameter) {
          1 => NumberFormat.upperRoman,
          2 => NumberFormat.lowerRoman,
          3 => NumberFormat.upperLetter,
          4 => NumberFormat.lowerLetter,
          22 => NumberFormat.decimalZero,
          23 => NumberFormat.bullet,
          255 => NumberFormat.none,
          _ => NumberFormat.decimal,
        };
      case 'levelstartat':
        _level.start = parameter ?? 1;
      case 'levelfollow':
        _level.suffix = switch (parameter) {
          1 => ListSuffix.space,
          2 => ListSuffix.nothing,
          _ => ListSuffix.tab,
        };
      case 'levellegal':
        _level.legal = (parameter ?? 1) != 0;
      case 'leveljc':
        _level.alignment = parameter;
      case 'leveljcn':
        _level.directionalAlignment = parameter;
      case 'leveltext':
        reader._begin(_LevelText(_level));
      case 'levelnumbers':
        reader._begin(const _Skip());
      default:
        return false;
    }
    return true;
  }

  @override
  void close(RtfReader reader, _Group group) {
    _level
      ..left = group.para.left
      ..firstLine = group.para.firstLine
      ..font = reader._fontName(group.run.font);
    _done(_level);
  }
}

/// The level's text: its length, then the characters, where 0 to 8 stand
/// for the numbers of those levels.
class _LevelText extends _Destination {
  _LevelText(this._level);

  final _LevelDef _level;
  final _text = StringBuffer();

  @override
  bool get showsText => true;

  /// Word writes it in the document's code page whatever the level's font,
  /// as LibreOffice reads it.
  @override
  int? codePage(RtfReader reader) => reader._codePage;

  @override
  void text(RtfReader reader, String text) =>
      _appendUpTo(_text, text, RtfReader._maxNameLength);

  @override
  void close(RtfReader reader, _Group group) {
    final text = _text.toString();
    if (text.isEmpty) return;
    final length = math.min(text.codeUnitAt(0), text.length - 1);
    final out = StringBuffer();
    for (final unit in text.substring(1, 1 + length).codeUnits) {
      if (unit < 9) {
        out.write('%${unit + 1}');
      } else {
        out.writeCharCode(unit);
      }
    }
    _level.text = out.toString();
  }
}

class _OverrideTable extends _Destination {
  @override
  bool word(RtfReader reader, String word, int? parameter) {
    if (word != 'listoverride') return false;
    reader._begin(_Override());
    return true;
  }
}

class _Override extends _Destination {
  int? listId;
  int? number;
  final starts = <int, int>{};

  /// The levels it redefines (`\listoverrideformat`).
  final formats = <int, _LevelDef>{};
  var _levels = 0;

  @override
  bool word(RtfReader reader, String word, int? parameter) {
    switch (word) {
      case 'listid':
        listId = parameter;
      case 'ls':
        number = parameter;
      case 'lfolevel':
        reader._begin(_LfoLevel(this, _levels++));
      default:
        return false;
    }
    return true;
  }

  @override
  void close(RtfReader reader, _Group group) {
    final number = this.number;
    if (number != null && reader._overrides.length < RtfReader._maxEntries) {
      reader._overrides[number] = this;
    }
  }
}

class _LfoLevel extends _Destination {
  _LfoLevel(this._override, this._level);

  final _Override _override;
  final int _level;
  var _restart = false;
  int? _start;
  _LevelDef? _format;

  @override
  bool word(RtfReader reader, String word, int? parameter) {
    switch (word) {
      case 'listoverridestartat':
        _restart = true;
      case 'levelstartat':
        _start = parameter;
      case 'listlevel':
        reader._beginStory(_ListLevel((level) => _format = level));
      default:
        return false;
    }
    return true;
  }

  @override
  void close(RtfReader reader, _Group group) {
    if (_level >= 9) return;
    final format = _format;
    if (format != null) _override.formats[_level] = format;
    // Without a start of its own it starts again where its new level does.
    final start = _start ?? format?.start;
    if (_restart && start != null) _override.starts[_level] = start;
  }
}

class _Defaults extends _Destination {
  _Defaults({required this.character});

  final bool character;

  @override
  void close(RtfReader reader, _Group group) {
    reader._stylesChanged();
    if (character) {
      reader._defaultCharacter = group.run;
    } else {
      reader._defaultParagraph = group.para;
    }
  }
}

class _Pn extends _Destination {
  final def = _PnDef();

  @override
  bool word(RtfReader reader, String word, int? parameter) {
    switch (word) {
      case 'pnlvlblt':
        def.kind = _PnKind.bullet;
      case 'pnlvlbody':
        def
          ..kind = _PnKind.numbered
          ..level = 0;
      case 'pnlvlcont':
        def.kind = _PnKind.none;
      case 'pnlvl':
        def
          ..kind = _PnKind.numbered
          ..level = ((parameter ?? 1) - 1).clamp(0, 8);
      case 'pndec' || 'pnord' || 'pnordt' || 'pncard':
        def.format = NumberFormat.decimal;
      case 'pnucltr':
        def.format = NumberFormat.upperLetter;
      case 'pnlcltr':
        def.format = NumberFormat.lowerLetter;
      case 'pnucrm':
        def.format = NumberFormat.upperRoman;
      case 'pnlcrm':
        def.format = NumberFormat.lowerRoman;
      case 'pnstart':
        def.start = (parameter ?? 1).clamp(0, 32767);
      default:
        return false;
    }
    return true;
  }

  @override
  void close(RtfReader reader, _Group group) => reader._group.para.pn = def;
}

class _PnText extends _Destination {
  _PnText(this._pn, {required this.after});

  final _Pn _pn;
  final bool after;

  @override
  bool get showsText => true;

  @override
  void text(RtfReader reader, String text) {
    final def = _pn.def;
    final kept = StringBuffer(after ? def.after : def.before);
    _appendUpTo(kept, text, 16);
    if (after) {
      def.after = kept.toString();
    } else {
      def.before = kept.toString();
    }
  }
}

enum _PictureType { png, jpeg, emf, wmf, dib, ddb, unsupported }

class _Picture extends _Destination {
  _Picture(this.story);

  @override
  final RtfStory? story;

  _PictureType? type;
  int? width;
  int? height;
  int? goalWidth;
  int? goalHeight;
  var scaleX = 100;
  var scaleY = 100;

  /// Twips cut off each side; negative ones (a margin) are ignored.
  var cropLeft = 0;
  var cropTop = 0;
  var cropRight = 0;
  var cropBottom = 0;
  var bitsPerPixel = 1;
  int? widthBytes;
  var oversize = false;

  /// Data came for a picture that has nowhere to go.
  var lost = false;

  var _data = Uint8List(0);
  var _length = 0;
  var _nibble = -1;

  Uint8List get bytes => Uint8List.sublistView(_data, 0, _length);

  @override
  RtfStory? get pictureStory => null;

  @override
  bool word(RtfReader reader, String word, int? parameter) {
    switch (word) {
      case 'pngblip':
        type = _PictureType.png;
      case 'jpegblip':
        type = _PictureType.jpeg;
      case 'emfblip':
        type = _PictureType.emf;
      case 'wmetafile':
        type = _PictureType.wmf;
      case 'dibitmap':
        type = _PictureType.dib;
      case 'wbitmap':
        type = _PictureType.ddb;
      case 'macpict' || 'pmmetafile':
        type = _PictureType.unsupported;
      case 'picw':
        width = parameter;
      case 'pich':
        height = parameter;
      case 'picwgoal':
        goalWidth = parameter;
      case 'pichgoal':
        goalHeight = parameter;
      case 'picscalex':
        scaleX = (parameter ?? 100).clamp(1, 10000);
      case 'picscaley':
        scaleY = (parameter ?? 100).clamp(1, 10000);
      case 'piccropl':
        cropLeft = math.max(parameter ?? 0, 0);
      case 'piccropt':
        cropTop = math.max(parameter ?? 0, 0);
      case 'piccropr':
        cropRight = math.max(parameter ?? 0, 0);
      case 'piccropb':
        cropBottom = math.max(parameter ?? 0, 0);
      case 'wbmbitspixel':
        bitsPerPixel = parameter ?? 1;
      case 'wbmwidthbytes':
        widthBytes = parameter;
      default:
        return false;
    }
    return true;
  }

  void hex(Uint8List source, int start, int end) {
    if (oversize || (story == null && lost)) return;
    for (var index = start; index < end; index++) {
      final byte = source[index];
      final int digit;
      if (byte >= 0x30 && byte <= 0x39) {
        digit = byte - 0x30;
      } else if (byte >= 0x61 && byte <= 0x66) {
        digit = byte - 0x57;
      } else if (byte >= 0x41 && byte <= 0x46) {
        digit = byte - 0x37;
      } else {
        continue;
      }
      if (story == null) {
        lost = true;
        return;
      }
      if (_nibble < 0) {
        _nibble = digit;
      } else {
        _append(_nibble << 4 | digit);
        _nibble = -1;
        if (oversize) return;
      }
    }
  }

  void binary(Uint8List source, int start, int end) {
    if (story == null) lost = lost || end > start;
    if (story == null || oversize) return;
    for (var index = start; index < end && !oversize; index++) {
      _append(source[index]);
    }
  }

  void _append(int byte) {
    if (_length == _data.length) {
      if (_length >= RtfReader._maxPictureBytes) {
        oversize = true;
        return;
      }
      final grown = Uint8List(
        math.min(math.max(_data.length * 2, 4096), RtfReader._maxPictureBytes),
      )..setRange(0, _length, _data);
      _data = grown;
    }
    _data[_length++] = byte;
  }

  @override
  void close(RtfReader reader, _Group group) =>
      reader._finishPicture(this, group);
}

class _Field {
  _Field(this.story, this.depth);

  final RtfStory story;

  /// Stack depth of the field's group: its instruction and result are the
  /// groups right inside it.
  final int depth;
  final instruction = StringBuffer();
  RtfParagraph? paragraph;
  var start = 0;
  var hasResult = false;

  void startResult() {
    story.paragraph.flush();
    paragraph = story.paragraph;
    start = story.paragraph.inlines.length;
    hasResult = true;
  }
}

class _FieldGroup extends _Destination {
  _FieldGroup(this._field);

  final _Field _field;

  @override
  void close(RtfReader reader, _Group group) =>
      reader._finishField(_field, group);
}

class _FieldInstruction extends _Destination {
  _FieldInstruction(this._field);

  final _Field _field;

  @override
  bool get showsText => true;

  @override
  void text(RtfReader reader, String text) =>
      _appendUpTo(_field.instruction, text, RtfReader._maxInstruction);
}

class _Shape {
  _Shape(this.anchor, {required this.isGroup});

  /// The story the shape is in.
  final RtfStory? anchor;
  final bool isGroup;
  var picture = false;
  List<BlockSpec>? text;
}

class _ShapeGroup extends _Destination {
  _ShapeGroup(this.shape);

  final _Shape shape;

  @override
  void close(RtfReader reader, _Group group) => reader._finishShape(shape);
}

class _ShapeProperty extends _Destination {
  _ShapeProperty(this.shape);

  final _Shape shape;
  final name = StringBuffer();
}

class _ShapeName extends _Destination {
  _ShapeName(this._property);

  final _ShapeProperty _property;

  @override
  void text(RtfReader reader, String text) =>
      _appendUpTo(_property.name, text.trim(), 64);
}

/// A shape property's value; the picture of a picture shape (`pib`) goes
/// where the shape is.
class _ShapeValue extends _Destination {
  _ShapeValue(this._property) {
    if (_isPicture) _property.shape.picture = true;
  }

  final _ShapeProperty _property;

  bool get _isPicture => _property.name.toString() == 'pib';

  @override
  RtfStory? get pictureStory => _isPicture ? _property.shape.anchor : null;
}

/// An embedded object: only the picture or text of its result is kept.
class _ObjectGroup extends _Destination {
  _ObjectGroup(this.resultStory);

  final RtfStory? resultStory;
}
