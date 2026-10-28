import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';

import 'document_look.dart';
import 'headers_footers.dart';

enum DocumentFormat {
  docx('docx'),
  plainText('txt');

  const DocumentFormat(this.extension);

  final String extension;

  static DocumentFormat? fromFileName(String name) {
    final lower = name.toLowerCase();
    for (final format in values) {
      if (lower.endsWith('.${format.extension}')) return format;
    }
    return null;
  }
}

/// Why a file could not be opened; the screen shows it in the user's language.
enum DocumentProblem {
  legacyDoc,
  unsupportedFormat,
  notWordDocument,
  tooLarge,
  damaged,
}

class DocumentProblemException extends FormatException {
  DocumentProblemException(this.problem) : super(problem.name);

  final DocumentProblem problem;
}

/// What was adjusted when the document was opened.
enum DocumentNotice { trackedChangesAccepted, commentsHidden }

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

  /// Context from the source format, used to save without losing content.
  final Object? source;

  final List<DocumentNotice> notices;
}

abstract interface class DocumentCodec {
  DocumentFormat get format;

  LoadedDocument decode(Uint8List bytes);

  /// [pageSetup] is only passed when the user changed the size, orientation
  /// or margins.
  Uint8List encode(
    Delta delta, {
    Object? source,
    DocumentLook? pageSetup,
    HeadersFooters? headersFooters,
  });
}
