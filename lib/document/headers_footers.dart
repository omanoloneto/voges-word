import 'package:flutter_quill/quill_delta.dart';

/// Word's variants: all pages, first page and even pages.
enum PageVariant { normal, first, even }

/// Text of a header or footer and the package part it came from.
class HeaderFooterStory {
  HeaderFooterStory({required this.delta, this.partPath, this.edited = false});

  final Delta delta;

  /// Original part (e.g. word/header1.xml); null when it was created here.
  final String? partPath;

  /// Only edited parts are rewritten; the others are saved as they came.
  final bool edited;

  bool get isEmpty => delta.toList().every(
    (op) => op.data is String && (op.data as String).trim().isEmpty,
  );
}

/// Headers and footers of the document's last section.
class HeadersFooters {
  const HeadersFooters({
    this.headers = const {},
    this.footers = const {},
    this.differentFirstPage = false,
    this.differentOddEven = false,
    this.headerDistance = 35.4,
    this.footerDistance = 35.4,
  });

  final Map<PageVariant, HeaderFooterStory> headers;
  final Map<PageVariant, HeaderFooterStory> footers;
  final bool differentFirstPage;
  final bool differentOddEven;

  /// Distance in points from the page edge to the header and the footer.
  final double headerDistance;
  final double footerDistance;

  bool get isEmpty =>
      headers.values.every((story) => story.isEmpty) &&
      footers.values.every((story) => story.isEmpty);

  HeaderFooterStory? headerFor(int pageIndex) => _pick(headers, pageIndex);

  HeaderFooterStory? footerFor(int pageIndex) => _pick(footers, pageIndex);

  HeaderFooterStory? _pick(
    Map<PageVariant, HeaderFooterStory> stories,
    int pageIndex,
  ) {
    if (pageIndex == 0 && differentFirstPage) return stories[PageVariant.first];
    if (differentOddEven && pageIndex.isOdd) return stories[PageVariant.even];
    return stories[PageVariant.normal];
  }

  HeadersFooters copyWith({
    Map<PageVariant, HeaderFooterStory>? headers,
    Map<PageVariant, HeaderFooterStory>? footers,
    bool? differentFirstPage,
  }) => HeadersFooters(
    headers: headers ?? this.headers,
    footers: footers ?? this.footers,
    differentFirstPage: differentFirstPage ?? this.differentFirstPage,
    differentOddEven: differentOddEven,
    headerDistance: headerDistance,
    footerDistance: footerDistance,
  );
}
