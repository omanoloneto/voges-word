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

  /// The last section's stories; an empty one is the previous section's.
  void _headersFooters() {
    final bounds = file.headerStories;
    final start = file.fib.headersStart;
    final length = file.fib.lengths.headers;
    final sectionCount = math.max(1, file.sections.length);
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
    for (final (kind, (header, variant)) in places.indexed) {
      for (var section = sectionCount - 1; section >= 0; section--) {
        final story = 6 + section * 6 + kind;
        if (story + 1 >= bounds.length) continue;
        final from = bounds[story];
        final to = bounds[story + 1];
        if (from < 0 || to <= from || to > length) continue;
        final blocks = StoryReader(
          context,
          header: true,
        ).read(start + from, start + to);
        (header ? spec.headers : spec.footers)[variant] = blocks;
        break;
      }
    }
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
