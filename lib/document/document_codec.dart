import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';

import 'document_look.dart';
import 'headers_footers.dart';

enum DocumentFormat {
  docx('docx', 'Documento do Word'),
  plainText('txt', 'Texto simples');

  const DocumentFormat(this.extension, this.label);

  final String extension;
  final String label;

  static DocumentFormat? fromFileName(String name) {
    final lower = name.toLowerCase();
    for (final format in values) {
      if (lower.endsWith('.${format.extension}')) return format;
    }
    return null;
  }
}

class LoadedDocument {
  const LoadedDocument({
    required this.delta,
    required this.look,
    this.source,
    this.notices = const [],
    this.headersFooters = const HeadersFooters(),
  });

  final Delta delta;
  final DocumentLook look;
  final HeadersFooters headersFooters;

  /// Contexto do formato de origem, usado para salvar sem perder conteúdo.
  final Object? source;

  /// Avisos para o usuário sobre o que foi ajustado ao abrir.
  final List<String> notices;
}

abstract interface class DocumentCodec {
  DocumentFormat get format;

  LoadedDocument decode(Uint8List bytes);

  /// [pageSetup] só vem quando o usuário mudou tamanho, orientação ou margens.
  Uint8List encode(
    Delta delta, {
    Object? source,
    DocumentLook? pageSetup,
    HeadersFooters? headersFooters,
  });
}
