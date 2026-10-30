import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart' show EdgeInsets;

import '../document/document_codec.dart';
import '../docx/docx_builder.dart';
import 'doc_file.dart';
import 'doc_lists.dart';
import 'doc_pictures.dart';
import 'doc_properties.dart';
import 'doc_styles.dart';

/// Turns the file's properties into the builder's formats, and keeps what
/// all stories share: style ids, lists, pictures and notices.
class DocContext {
  DocContext(this.file, this.spec) {
    _styleIds = _assignStyleIds();
  }

  final DocFile file;
  final DocumentSpec spec;
  final notices = <DocumentNotice>{};

  late final Map<int, String> _styleIds;
  final _runFormats = <(CharProps, CharProps), RunFormat>{};
  final _fontVariants = <(RunFormat, String?), RunFormat>{};
  final _paragraphFormats = <(ParaProps, ParaProps), ParagraphFormat>{};
  final _listIds = <Object, int>{};
  final _pictures = <int, DocPicture?>{};
  final _floating = <(bool, int), ({Uint8List bytes, String mime})?>{};

  /// Pictures share this budget, so a picture repeated many times can't
  /// exhaust memory.
  var _pictureBudget = 256 * 1024 * 1024;

  /// Paragraphs, runs and other elements made so far.
  var _elements = 0;

  /// Far beyond real documents; formatting that changes at every character
  /// of a huge file stops here instead of exhausting memory.
  static const maxElements = 4000000;

  /// Counts an element of the document being built.
  void addElement() {
    if (++_elements > maxElements) {
      throw DocumentProblemException(DocumentProblem.tooLarge);
    }
  }

  DocStyles get styles => file.styles;

  String? fontName(int index) =>
      index >= 0 && index < file.fonts.length ? file.fonts[index] : null;

  /// Builder styles for the file's paragraph and character styles.
  List<StyleSpec> styleSpecs() {
    final result = <StyleSpec>[];
    for (final MapEntry(key: index, value: id) in _styleIds.entries) {
      final style = styles[index]!;
      final base =
          _styleIds.containsKey(style.base) &&
              styles[style.base]?.kind == style.kind
          ? style.base
          : null;
      final next = _styleIds[style.next];
      if (style.kind == DocStyleKind.paragraph) {
        result.add(
          StyleSpec.paragraph(
            id,
            style.name.isEmpty ? id : style.name,
            basedOn: base == null ? null : _styleIds[base],
            next: next,
            headingLevel: style.builtIn >= 1 && style.builtIn <= 9
                ? style.builtIn
                : null,
            run: runDiff(
              base == null ? styles.baseCharProps : styles.charProps(base),
              styles.charProps(index),
            ),
            paragraph: paragraphDiff(
              base == null ? ParaProps() : styles.paragraphProps(base),
              styles.paragraphProps(index),
            ),
          ),
        );
      } else {
        final plain = styles.baseCharProps;
        result.add(
          StyleSpec.character(
            id,
            style.name.isEmpty ? id : style.name,
            basedOn: base == null ? null : _styleIds[base],
            run: runDiff(
              base == null ? plain : styles.withCharacterStyle(plain, base),
              styles.withCharacterStyle(plain, index),
            ),
          ),
        );
      }
    }
    return result;
  }

  /// Direct formatting: what [props] changes from [base], the styles'.
  RunFormat runFormat(CharProps base, CharProps props) =>
      _runFormats[(base, props)] ??= runDiff(
        base,
        props,
        styleId: props.style == 10 ? null : _styleIds[props.style],
      );

  RunFormat runDiff(CharProps from, CharProps to, {String? styleId}) {
    bool? changed(bool a, bool b) => a == b ? null : b;
    final fromStrike = from.strike || from.doubleStrike;
    final toStrike = to.strike || to.doubleStrike;
    final fromBackground = from.highlight ?? from.shading;
    final toBackground = to.highlight ?? to.shading;
    return RunFormat(
      styleId: styleId,
      font: to.font == from.font ? null : fontName(to.font),
      size: to.halfPoints == from.halfPoints ? null : to.halfPoints / 2,
      bold: changed(from.bold, to.bold),
      italic: changed(from.italic, to.italic),
      underline: changed(from.underline != 0, to.underline != 0),
      strike: changed(fromStrike, toStrike),
      allCaps: changed(from.caps, to.caps),
      smallCaps: changed(from.smallCaps, to.smallCaps),
      hidden: changed(from.hidden, to.hidden),
      color: to.color == from.color ? null : to.color ?? 'auto',
      background: toBackground == fromBackground
          ? null
          : toBackground ?? 'auto',
      position: to.script == from.script
          ? null
          : switch (to.script) {
              1 => VerticalPosition.superscript,
              2 => VerticalPosition.subscript,
              _ => null,
            },
    );
  }

  /// [format] drawn in [font] instead; null keeps the style's font.
  RunFormat withFont(RunFormat format, String? font) =>
      _fontVariants[(format, font)] ??= RunFormat(
        styleId: format.styleId,
        font: font,
        size: format.size,
        bold: format.bold,
        italic: format.italic,
        underline: format.underline,
        strike: format.strike,
        allCaps: format.allCaps,
        smallCaps: format.smallCaps,
        hidden: format.hidden,
        color: format.color,
        background: format.background,
        position: format.position,
      );

  /// Direct paragraph formatting over the paragraph's style.
  ParagraphFormat paragraphFormat(ParaProps props) {
    final style = styles.paragraphProps(props.style);
    return _paragraphFormats[(style, props)] ??= paragraphDiff(
      style,
      props,
      styleId: props.style == 0 ? null : _styleIds[props.style],
    );
  }

  ParagraphFormat paragraphDiff(
    ParaProps from,
    ParaProps to, {
    String? styleId,
  }) {
    bool? changed(bool a, bool b) => a == b ? null : b;
    double? points(int a, int b) => a == b ? null : b / 20;
    final sameList =
        from.listOverride == to.listOverride && from.listLevel == to.listLevel;
    final sameTabs =
        from.tabs.length == to.tabs.length &&
        [
          for (var i = 0; i < to.tabs.length; i++) from.tabs[i] == to.tabs[i],
        ].every((same) => same);
    return ParagraphFormat(
      styleId: styleId,
      align: from.justification == to.justification
          ? null
          : switch (to.justification) {
              0 => ParagraphAlign.left,
              1 => ParagraphAlign.center,
              2 => ParagraphAlign.right,
              _ => ParagraphAlign.justify,
            },
      indentLeft: points(from.left, to.left),
      indentRight: points(from.right, to.right),
      firstLine: points(from.firstLine, to.firstLine),
      spaceBefore: points(from.before, to.before),
      spaceAfter: points(from.after, to.after),
      lineSpacing: from.line == to.line && from.lineMultiple == to.lineMultiple
          ? null
          : _lineSpacing(to),
      keepNext: changed(from.keepNext, to.keepNext),
      keepLines: changed(from.keep, to.keep),
      pageBreakBefore: changed(from.pageBreakBefore, to.pageBreakBefore),
      contextualSpacing: changed(from.contextualSpacing, to.contextualSpacing),
      rightToLeft: changed(from.rightToLeft, to.rightToLeft),
      list: sameList ? null : _listRef(to),
      tabs: sameTabs
          ? const []
          : [
              for (final tab in to.tabs)
                TabStop(
                  tab.position / 20,
                  align: switch (tab.align) {
                    1 => TabAlign.center,
                    2 => TabAlign.right,
                    3 => TabAlign.decimal,
                    _ => TabAlign.left,
                  },
                  leader: switch (tab.leader) {
                    1 || 5 => TabLeader.dot,
                    2 => TabLeader.hyphen,
                    3 || 4 => TabLeader.underscore,
                    _ => TabLeader.none,
                  },
                ),
            ],
    );
  }

  static LineSpacing _lineSpacing(ParaProps props) {
    if (props.lineMultiple) {
      return LineSpacing.multiple(props.line > 0 ? props.line / 240 : 1);
    }
    if (props.line == 0) return const LineSpacing.multiple(1);
    return props.line > 0
        ? LineSpacing.atLeast(props.line / 20)
        : LineSpacing.exactly(-props.line / 20);
  }

  ListRef? _listRef(ParaProps props) {
    final list = file.lists[props.listOverride];
    if (list == null) return null;
    final key = list.overridden ? ('override', props.listOverride) : list.id;
    final id = _listIds[key] ??= spec.addList(
      ListSpec([for (final level in list.levels) _listLevel(level)]),
    );
    return ListRef(id, props.listLevel);
  }

  ListLevelSpec _listLevel(DocListLevel level) => ListLevelSpec(
    format: switch (level.format) {
      0 || 5 || 6 || 7 => NumberFormat.decimal,
      1 => NumberFormat.upperRoman,
      2 => NumberFormat.lowerRoman,
      3 => NumberFormat.upperLetter,
      4 => NumberFormat.lowerLetter,
      22 => NumberFormat.decimalZero,
      23 => NumberFormat.bullet,
      255 => NumberFormat.none,
      _ => NumberFormat.decimal,
    },
    text: level.text,
    start: level.start,
    indentLeft: level.left == null ? null : level.left! / 20,
    hanging: level.firstLine == null ? 18 : math.max(0, -level.firstLine!) / 20,
    font: level.font == null ? null : fontName(level.font!),
  );

  /// Page size, margins and columns of a section, with Word's defaults for
  /// values that make no sense.
  PageSpec page(SectionProps section) {
    final defaults = SectionProps();
    final valid =
        section.width >= 144 &&
        section.width <= 31680 &&
        section.height >= 144 &&
        section.height <= 31680 &&
        section.left + section.right < section.width &&
        section.top + section.bottom < section.height;
    final page = valid ? section : defaults;
    return PageSpec(
      width: page.width / 20,
      height: page.height / 20,
      margins: EdgeInsets.fromLTRB(
        page.left / 20,
        page.top / 20,
        page.right / 20,
        page.bottom / 20,
      ),
      headerDistance: math.min(section.headerDistance, 31680) / 20,
      footerDistance: math.min(section.footerDistance, 31680) / 20,
      columns: section.columns.clamp(1, 45),
      columnSpacing: math.min(section.columnSpacing, 31680) / 20,
    );
  }

  static SectionKind sectionKind(SectionProps section) =>
      switch (section.breakKind) {
        0 || 1 => SectionKind.continuous,
        3 => SectionKind.evenPage,
        4 => SectionKind.oddPage,
        _ => SectionKind.nextPage,
      };

  /// The inline picture at [offset] of the Data stream; null when it can't
  /// be shown, which leaves a notice unless [quiet].
  ImageSpec? picture(int offset, {bool quiet = false}) {
    final data = file.data;
    final picture = data == null || offset < 0
        ? null
        : _pictures.containsKey(offset)
        ? _pictures[offset]
        : _pictures[offset] = _guarded(() => inlinePicture(data, offset));
    if (picture == null || picture.bytes.length > _pictureBudget) {
      if (!quiet) notices.add(DocumentNotice.contentNotImported);
      return null;
    }
    _pictureBudget -= picture.bytes.length;
    return ImageSpec(
      picture.bytes,
      picture.mime,
      width: picture.width,
      height: picture.height,
    );
  }

  /// The floating picture anchored at [position], placed inline; null when
  /// the shape isn't a picture, which leaves a notice.
  ImageSpec? floatingPicture(int position, {required bool header}) {
    final anchor = (header ? file.headerShapes : file.mainShapes)[position];
    final pictures = header ? file.headerPictures : file.mainPictures;
    final picture = anchor == null || pictures == null
        ? null
        : _floating.putIfAbsent((
            header,
            anchor.shape,
          ), () => _guarded(() => pictures[anchor.shape]));
    if (anchor == null ||
        picture == null ||
        picture.bytes.length > _pictureBudget) {
      notices.add(DocumentNotice.contentNotImported);
      return null;
    }
    _pictureBudget -= picture.bytes.length;
    return ImageSpec(
      picture.bytes,
      picture.mime,
      width: anchor.width > 0 ? anchor.width / 20 : null,
      height: anchor.height > 0 ? anchor.height / 20 : null,
    );
  }

  /// A damaged picture is left out; the rest of the document still opens.
  static T? _guarded<T>(T? Function() read) {
    try {
      return read();
    } on FormatException {
      return null;
    }
  }

  /// Ids like Word's: the name's words without spaces; `Normal` for the
  /// default style.
  Map<int, String> _assignStyleIds() {
    const reserved = {'Normal', 'DefaultParagraphFont', 'TableNormal'};
    final ids = <int, String>{};
    final used = <String>{};
    for (var index = 0; index < styles.styles.length; index++) {
      final style = styles[index];
      if (style == null || style.kind == DocStyleKind.other) continue;
      // Default Paragraph Font is the builder's own.
      if (style.builtIn == 65 && style.kind == DocStyleKind.character) continue;
      if (index == 0 && style.kind == DocStyleKind.paragraph) {
        ids[0] = 'Normal';
        continue;
      }
      var id = style.builtIn >= 1 && style.builtIn <= 9
          ? 'Heading${style.builtIn}'
          : _idOf(style.name);
      if (id.isEmpty) id = 'Style$index';
      if (reserved.contains(id) || used.contains(id)) id = '$id$index';
      used.add(id);
      ids[index] = id;
    }
    return ids;
  }

  static String _idOf(String name) {
    final words = name
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((word) => word.isNotEmpty)
        .map((word) => word[0].toUpperCase() + word.substring(1));
    final id = words.join();
    return id.isNotEmpty && RegExp(r'^\p{N}', unicode: true).hasMatch(id)
        ? 'S$id'
        : id;
  }
}
