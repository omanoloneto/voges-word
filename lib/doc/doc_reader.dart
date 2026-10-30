import 'dart:math' as math;

import '../document/document_codec.dart';
import '../document/headers_footers.dart';
import '../docx/docx_builder.dart';
import 'doc_context.dart';
import 'doc_file.dart';
import 'doc_properties.dart';
import 'doc_story.dart';
import 'doc_symbols.dart';

/// Builds the document a Word 97–2003 file describes.
class DocReader {
  DocReader(this.file)
    : spec = DocumentSpec(
        defaultParagraph: const ParagraphFormat(
          spaceBefore: 0,
          spaceAfter: 0,
          lineSpacing: LineSpacing.multiple(1),
        ),
      ) {
    context = DocContext(file, spec);
  }

  final DocFile file;
  final DocumentSpec spec;
  late final DocContext context;

  Set<DocumentNotice> get notices => context.notices;

  DocumentSpec read() {
    final styles = file.styles;
    final sections = file.sections;
    final last = sections.isEmpty ? SectionProps() : sections.last.props;
    final tabStop = file.settings.tabStop;
    spec
      ..defaultRun = RunFormat(
        font: context.fontName(styles.defaultFont) ?? 'Times New Roman',
        size: styles.baseCharProps.halfPoints / 2,
      )
      ..defaultTabStop = tabStop > 0 && tabStop <= 31680 ? tabStop / 20 : 36
      ..language =
          languageTag(styles.charProps(0).language) ??
          languageTag(file.fib.language)
      ..page = context.page(last)
      ..lastSectionKind = DocContext.sectionKind(last)
      ..differentFirstPage = last.titlePage
      ..differentOddEven = file.settings.facingPages;
    spec.styles.addAll(context.styleSpecs());
    spec.body.addAll(
      StoryReader(
        context,
        readNote: _note,
        sections: true,
      ).read(0, file.fib.lengths.text),
    );
    _headersFooters();

    if (_hasTextBoxText() ||
        file.compound.contains('Macros') ||
        file.skippedParts) {
      notices.add(DocumentNotice.contentNotImported);
    }
    if (file.hasComments) notices.add(DocumentNotice.commentsHidden);
    return spec;
  }

  /// Text boxes aren't read; empty ones lose nothing.
  bool _hasTextBoxText() {
    final fib = file.fib;
    final start = fib.textBoxesStart;
    final end = math.min(fib.end, file.pieces.length);
    final text = file.pieces.text;
    for (var position = start; position < end; position++) {
      if (text[position] > 0x20 && text[position] != 0xA0) return true;
    }
    return false;
  }

  /// The document has one set of headers and footers: the last section's,
  /// where an absent story is the previous section's. Earlier sections that
  /// show other ones leave a notice.
  void _headersFooters() {
    final sections = file.sections;
    final sectionCount = math.max(1, sections.length);
    // Each section has six stories after the six note separators: even and
    // odd headers, even and odd footers, first page header and footer.
    const places = [
      (true, PageVariant.even),
      (true, PageVariant.normal),
      (false, PageVariant.even),
      (false, PageVariant.normal),
      (true, PageVariant.first),
      (false, PageVariant.first),
    ];
    final kept = List<int?>.filled(places.length, null);
    final shownBefore = <(int, int)>{};
    for (var section = 0; section < sectionCount; section++) {
      for (var place = 0; place < places.length; place++) {
        final story = 6 + section * 6 + place;
        if (_headerStory(story) != null) kept[place] = story;
      }
      if (section == sectionCount - 1) break;
      final titlePage = sections[section].props.titlePage;
      for (final (place, (_, variant)) in places.indexed) {
        final shown = switch (variant) {
          PageVariant.normal => true,
          PageVariant.first => titlePage,
          PageVariant.even => file.settings.facingPages,
        };
        if (kept[place] case final story? when shown) {
          shownBefore.add((place, story));
        }
      }
    }
    for (final (place, (header, variant)) in places.indexed) {
      final range = kept[place] == null ? null : _headerStory(kept[place]!);
      if (range == null) continue;
      (header ? spec.headers : spec.footers)[variant] = StoryReader(
        context,
        header: true,
      ).read(range.start, range.end);
    }
    final texts = <int, String>{};
    String textOf(int story) =>
        texts[story] ??= _storyText(_headerStory(story)!);
    for (final (place, story) in shownBefore) {
      final last = kept[place]!;
      if (story != last && textOf(story) != textOf(last)) {
        notices.add(DocumentNotice.contentNotImported);
        break;
      }
    }
  }

  /// Header story [index] without the extra paragraph mark Word ends each
  /// one with; null when the story is absent, which one of less than two
  /// characters is too.
  ({int start, int end})? _headerStory(int index) {
    final bounds = file.headerStories;
    if (index + 1 >= bounds.length) return null;
    final from = bounds[index];
    final to = bounds[index + 1];
    if (from < 0 || to - from < 2 || to > file.fib.lengths.headers) {
      return null;
    }
    final start = file.fib.headersStart;
    return (start: start + from, end: start + to - 1);
  }

  /// The characters of a story without field results, which differ from
  /// page to page.
  String _storyText(({int start, int end}) range) {
    final text = file.pieces.text;
    final out = StringBuffer();
    var depth = 0;
    var resultDepth = -1;
    for (var at = range.start; at < math.min(range.end, text.length); at++) {
      final unit = text[at];
      if (unit == 0x13) {
        depth++;
      } else if (unit == 0x14 && depth > 0 && resultDepth < 0) {
        resultDepth = depth;
      } else if (unit == 0x15 && depth > 0) {
        if (resultDepth == depth) resultDepth = -1;
        depth--;
      }
      if (resultDepth < 0) out.writeCharCode(unit);
    }
    return out.toString();
  }

  List<BlockSpec> _note(DocNote note) {
    final blocks = StoryReader(context).read(note.start, note.end);
    // The builder writes the reference mark and the space after it.
    if (blocks.firstOrNull case ParagraphSpec(
      :final inlines,
      :final format,
      :final mark,
    ) when inlines.firstOrNull is TextSpec) {
      final first = inlines.first as TextSpec;
      if (first.text.startsWith(' ')) {
        blocks[0] = ParagraphSpec(
          [TextSpec(first.text.substring(1), first.format), ...inlines.skip(1)],
          format: format,
          mark: mark,
        );
      }
    }
    return blocks;
  }
}
