import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';

import 'document_look.dart';
import 'headers_footers.dart';

/// File formats the editor opens; the [writable] ones it also saves.
enum DocumentFormat {
  docx('docx', templates: {'dotx', 'dotm'}),

  /// .docx with macros: they are kept but never run.
  docm('docm'),

  /// Word 97–2003. Saving one creates a .docx.
  doc('doc', templates: {'dot'}, writable: false),
  odt('odt', templates: {'ott'}),
  rtf('rtf'),
  html('html', aliases: {'htm', 'xhtml'}),
  markdown('md', aliases: {'markdown'}),
  plainText('txt');

  const DocumentFormat(
    this.extension, {
    this.aliases = const {},
    this.templates = const {},
    this.writable = true,
  });

  /// Extension of the files this app saves.
  final String extension;
  final Set<String> aliases;

  /// Extensions of the format's templates, which open as new documents.
  final Set<String> templates;
  final bool writable;

  Iterable<String> get extensions => [extension, ...aliases, ...templates];

  static DocumentFormat? fromFileName(String name) =>
      matchFileName(name)?.format;

  static ({DocumentFormat format, bool template})? matchFileName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return null;
    final extension = name.substring(dot + 1).toLowerCase();
    for (final format in values) {
      if (format.extension == extension || format.aliases.contains(extension)) {
        return (format: format, template: false);
      }
      if (format.templates.contains(extension)) {
        return (format: format, template: true);
      }
    }
    return null;
  }
}

/// Why a file could not be opened; the screen shows it in the user's language.
enum DocumentProblem {
  /// Word 6 or 95 and older binary files.
  legacyDoc,
  unsupportedFormat,
  notWordDocument,
  passwordProtected,
  tooLarge,
  damaged,
}

class DocumentProblemException extends FormatException {
  DocumentProblemException(this.problem) : super(problem.name);

  final DocumentProblem problem;
}

/// What was adjusted when the document was opened.
enum DocumentNotice {
  trackedChangesAccepted,
  commentsHidden,

  /// Parts of the file this app doesn't read; saving in the same format
  /// leaves them out.
  contentNotImported,

  /// The format opens but isn't saved; saving creates a .docx.
  savesAsDocx,
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

  /// Context from the source format, used to save without losing content.
  final Object? source;

  final List<DocumentNotice> notices;

  LoadedDocument withNotices(Iterable<DocumentNotice> more) => LoadedDocument(
    delta: delta,
    look: look,
    source: source,
    notices: {...notices, ...more}.toList(),
    headersFooters: headersFooters,
  );
}

/// What a reader makes of a file before the editor's document is built: plain
/// data, so it can be made on another isolate.
sealed class PreparedDocument {
  const PreparedDocument();
}

/// The .docx package the editor's document is read from.
final class PreparedPackage extends PreparedDocument {
  const PreparedPackage(this.parts, {this.notices = const []});

  final Map<String, Uint8List> parts;

  /// What the format's reader adjusted, before the package's reader adds its
  /// own.
  final List<DocumentNotice> notices;
}

/// The text of a plain text file.
final class PreparedText extends PreparedDocument {
  const PreparedText(this.text);

  final String text;
}

abstract interface class DocumentDecoder {
  /// Throws [DocumentProblemException] or [FormatException] for files it
  /// can't read. It is [load] of what the codec's static `prepare` makes of
  /// [bytes]; `prepare` runs on any isolate.
  LoadedDocument decode(Uint8List bytes);

  /// The editor's document from what `prepare` made of a file, on the isolate
  /// whose tables it fills.
  LoadedDocument load(PreparedDocument prepared);
}

abstract interface class DocumentCodec implements DocumentDecoder {
  /// [look] is the document's page and text look. [pageSetupChanged] is true
  /// when the user changed the size, orientation or margins, so formats that
  /// keep the original page setup (.docx) replace it.
  Uint8List encode(
    Delta delta, {
    Object? source,
    DocumentLook look = const DocumentLook(),
    bool pageSetupChanged = false,
    HeadersFooters? headersFooters,
  });
}
