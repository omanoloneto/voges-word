import 'package:flutter_quill/quill_delta.dart';

/// Variantes do Word: todas as páginas, primeira página e páginas pares.
enum PageVariant { normal, first, even }

/// Texto de um cabeçalho ou rodapé e a parte do pacote de onde veio.
class HeaderFooterStory {
  HeaderFooterStory({required this.delta, this.partPath, this.edited = false});

  final Delta delta;

  /// Parte original (ex.: word/header1.xml); nula quando foi criado aqui.
  final String? partPath;

  /// Só as partes editadas são regravadas; as outras voltam como vieram.
  final bool edited;

  bool get isEmpty => delta.toList().every(
    (op) => op.data is String && (op.data as String).trim().isEmpty,
  );
}

/// Cabeçalhos e rodapés da última seção do documento.
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

  /// Distância em pontos da borda da folha até o cabeçalho e o rodapé.
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
