// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show EdgeInsets, FocusNode, Locale;
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

import '../docx/docx_codec.dart';
import '../docx/docx_template.dart';
import '../docx/image_formats.dart';
import '../document/document_codec.dart';
import '../document/document_look.dart';
import '../document/embeds.dart';
import '../document/headers_footers.dart';
import '../document/plain_text_codec.dart';
import '../document/tables.dart';
import '../files/document_files.dart';
import '../files/recovery.dart';
import '../formats/background_open.dart';
import '../formats/document_codecs.dart';
import '../l10n/app_language.dart';
import '../l10n/l10n.dart';
import 'document_commands.dart';
import 'embeds/table_embed.dart';
import 'paste_sanitizer.dart';
import 'template_content.dart';

/// What the session shows or writes in the user's language.
class SessionLocale {
  const SessionLocale({
    required this.language,
    required this.untitledName,
    required this.untitledFileName,
    required this.resume,
  });

  factory SessionLocale.of(AppLocalizations l10n) => SessionLocale(
    language: documentLanguageTag(Locale(l10n.localeName)),
    untitledName: l10n.untitledDocument,
    untitledFileName: l10n.untitledFileName,
    resume: resumeContent(l10n),
  );

  /// Language tag of new documents, like `pt-BR`.
  final String language;
  final String untitledName;

  /// Suggested file name when an untitled document is saved.
  final String untitledFileName;

  /// Sample text of the résumé template.
  final Delta resume;
}

class EditorSession extends ChangeNotifier {
  EditorSession({
    required this.docx,
    required this.plainText,
    required this.files,
    required this.tables,
    SessionLocale? locale,
  }) : locale =
           locale ??
           SessionLocale.of(lookupAppLocalizations(appLanguages.first)),
       codecs = DocumentCodecs(docx: docx, plainText: plainText) {
    _tableEdits = tables.edits.listen((_) => _markDirty());
    _load(
      docx.create(DocumentTemplate.blank, language: this.locale.language),
      name: null,
      path: null,
      format: DocumentFormat.docx,
    );
  }

  /// Updated by the screen when the language changes.
  SessionLocale locale;

  final DocxCodec docx;
  final PlainTextCodec plainText;
  final DocumentFiles files;
  final TableStore tables;
  final DocumentCodecs codecs;

  late QuillController controller;
  late final ValueNotifier<QuillController> activeController = ValueNotifier(
    controller,
  );
  final activeCell = ValueNotifier<TableCellRef?>(null);

  late LoadedDocument _document;
  late StreamSubscription<void> _tableEdits;
  StreamSubscription<DocChange>? _changes;

  String? _name;
  String get name => _name ?? locale.untitledName;
  set name(String value) => _name = value;
  String? path;
  DocumentFormat format = DocumentFormat.docx;
  bool dirty = false;

  /// Grows with each loaded document, so the screen recreates the editor.
  int generation = 0;

  /// Grows with each change, to tell whether the recovery copy is up to date.
  int revision = 0;

  late DocumentLook _look;
  var _pageSetupChanged = false;

  DocumentLook get look => _look;

  HeadersFooters headersFooters = const HeadersFooters();

  /// New header, footer or first-page option.
  void setHeadersFooters(HeadersFooters value) {
    headersFooters = value;
    revision++;
    dirty = true;
    notifyListeners();
  }

  /// Size, orientation and margins (in points) chosen in the Layout tab.
  void setPageSetup({double? width, double? height, EdgeInsets? margins}) {
    _look = _look.copyWith(
      pageWidth: width,
      pageHeight: height,
      margins: margins,
    );
    _pageSetupChanged = true;
    revision++;
    dirty = true;
    notifyListeners();
  }

  List<DocumentNotice> get notices => _document.notices;

  bool get isUntitled => _name == null && path == null;

  String get baseName {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  void newDocument([DocumentTemplate template = DocumentTemplate.blank]) =>
      _load(
        docx.create(
          template,
          language: locale.language,
          content: template == DocumentTemplate.resume ? locale.resume : null,
        ),
        name: null,
        path: null,
        format: DocumentFormat.docx,
      );

  /// How long [openInBackground] and [restoreInBackground] may take to
  /// prepare a file before refusing it as too large or too complex.
  @visibleForTesting
  Duration openTimeLimit = const Duration(seconds: 60);

  /// Templates open as new documents; formats that aren't saved will be
  /// saved as .docx. A file named in one of them, like a .doc that is really
  /// RTF, is never written either. The whole file is read on this isolate:
  /// the app uses [openInBackground].
  @visibleForTesting
  void open(OpenedFile file) {
    final detected = detectFormat(file.name, file.bytes);
    if (detected == null) {
      throw DocumentProblemException(DocumentProblem.unsupportedFormat);
    }
    final decoder = codecs.decoder(detected.format);
    _openAs(
      file,
      _damagedOnFormatError(() => decoder.decode(file.bytes)),
      format: detected.format,
      template: detected.template,
    );
  }

  /// [open] with the format's work on another isolate, so the window stays
  /// responsive; only reading the prepared package into the editor happens
  /// here. A file that takes longer than [openTimeLimit] to prepare is
  /// refused as [DocumentProblem.tooLarge].
  Future<void> openInBackground(OpenedFile file) async {
    final prepared = await prepareFileInBackground(
      file.name,
      file.bytes,
      timeLimit: openTimeLimit,
    );
    final decoder = codecs.decoder(prepared.format);
    _openAs(
      file,
      _damagedOnFormatError(() => decoder.load(prepared.document)),
      format: prepared.format,
      template: prepared.template,
    );
  }

  static LoadedDocument _damagedOnFormatError(LoadedDocument Function() read) {
    try {
      return read();
    } on DocumentProblemException {
      rethrow;
    } on FormatException {
      throw DocumentProblemException(DocumentProblem.damaged);
    }
  }

  void _openAs(
    OpenedFile file,
    LoadedDocument loaded, {
    required DocumentFormat format,
    required bool template,
  }) {
    if (template) {
      _load(
        loaded,
        name: null,
        path: null,
        format: format.writable ? format : DocumentFormat.docx,
      );
      return;
    }
    final named = DocumentFormat.fromFileName(file.name) ?? format;
    final saved = named.writable ? format : named;
    _load(
      saved.writable
          ? loaded
          : loaded.withNotices([DocumentNotice.savesAsDocx]),
      name: file.name,
      path: file.path,
      format: saved,
    );
  }

  /// The copy is always a .docx (.docm for .docm files), which keeps
  /// everything the editor has.
  RecoverySnapshot snapshot() {
    final content = format == DocumentFormat.docm
        ? DocumentFormat.docm
        : DocumentFormat.docx;
    return RecoverySnapshot(
      name: _name ?? '',
      path: path,
      format: format,
      content: content,
      bytes: encode(content),
      savedAt: DateTime.now(),
    );
  }

  /// Reopens the recovery copy as a document that is not saved yet, reading
  /// it on this isolate: the app uses [restoreInBackground].
  @visibleForTesting
  void restore(RecoverySnapshot snapshot, {required bool keepPath}) => _restore(
    snapshot,
    codecs.decoder(snapshot.content).decode(snapshot.bytes),
    keepPath: keepPath,
  );

  /// [restore] with the format's work on another isolate, as in
  /// [openInBackground].
  Future<void> restoreInBackground(
    RecoverySnapshot snapshot, {
    required bool keepPath,
  }) async {
    final prepared = await prepareInBackground(
      snapshot.content,
      snapshot.bytes,
      timeLimit: openTimeLimit,
    );
    _restore(
      snapshot,
      codecs.decoder(snapshot.content).load(prepared),
      keepPath: keepPath,
    );
  }

  void _restore(
    RecoverySnapshot snapshot,
    LoadedDocument loaded, {
    required bool keepPath,
  }) {
    _load(
      loaded,
      name: snapshot.name.isEmpty ? null : snapshot.name,
      path: keepPath ? snapshot.path : null,
      format: snapshot.format,
    );
    revision++;
    dirty = true;
    notifyListeners();
  }

  /// Returns false if the user canceled.
  Future<bool> save() async {
    if (!format.writable) return saveAs(DocumentFormat.docx);
    final target = path;
    if (target != null && files.canSaveInPlace) {
      await files.write(target, encode(format));
      _saved();
      return true;
    }
    return saveAs(format);
  }

  Future<bool> saveAs(DocumentFormat target) async {
    final suggested =
        '${isUntitled ? locale.untitledFileName : baseName}.${target.extension}';
    if (!files.canSaveInPlace) {
      if (!await files.saveCopy(suggested, encode(target), target)) {
        return false;
      }
      name = suggested;
      format = target;
      _saved();
      return true;
    }
    var chosen = await files.chooseSaveLocation(suggested, target);
    if (chosen == null) return false;
    final typed = DocumentFormat.matchFileName(chosen);
    final DocumentFormat finalFormat;
    if (typed != null && !typed.template && typed.format.writable) {
      finalFormat = typed.format;
    } else {
      finalFormat = target;
      chosen = '$chosen.${target.extension}';
    }
    await files.write(chosen, encode(finalFormat));
    path = chosen;
    name = chosen.split(RegExp(r'[\\/]')).last;
    format = finalFormat;
    _saved();
    return true;
  }

  Uint8List encode(DocumentFormat target) => codecs
      .encoder(target)
      .encode(
        controller.document.toDelta(),
        source: _document.source,
        look: _look,
        pageSetupChanged: _pageSetupChanged,
        headersFooters: headersFooters,
      );

  String plainTextContent() =>
      plainText.plainTextOf(controller.document.toDelta());

  /// Whether the document, with its tables, headers and footers, has
  /// equations, charts or other protected Word content that only .docx and
  /// .docm keep as it is.
  bool hasProtectedContent() {
    final tablesSeen = <String>{};
    return [
      controller.document.toDelta(),
      for (final story in [
        ...headersFooters.headers.values,
        ...headersFooters.footers.values,
      ])
        story.delta,
    ].any((delta) => _hasProtectedContent(delta, tablesSeen));
  }

  bool _hasProtectedContent(Delta delta, Set<String> tablesSeen) =>
      delta.operations.any(
        (operation) => switch (operation.data) {
          {EmbedTypes.opaqueBlock: final Object value} => _isProtected(
            value,
            block: true,
          ),
          {EmbedTypes.opaqueInline: final Object value} => _isProtected(
            value,
            block: false,
          ),
          {EmbedTypes.table: final Object value} => _tableHasProtectedContent(
            value,
            tablesSeen,
          ),
          _ => false,
        },
      );

  bool _tableHasProtectedContent(Object value, Set<String> tablesSeen) {
    final TableModel? table;
    try {
      table = tables[tableIdOf(value)];
    } catch (_) {
      return false;
    }
    if (table == null || !tablesSeen.add(table.id)) return false;
    return table.rows.any(
      (row) => row.cells.any(
        (cell) => _hasProtectedContent(
          cell.controller.document.toDelta(),
          tablesSeen,
        ),
      ),
    );
  }

  /// Notes and fields don't count: .odt and .rtf write them as their own.
  static bool _isProtected(Object value, {required bool block}) {
    final OpaqueContent content;
    try {
      content = OpaqueContent.decode(value);
    } catch (_) {
      return false;
    }
    if (content.hidden || content.label == OpaqueLabels.note) return false;
    return block || content.label != null || fieldNameOf(content.xml) == null;
  }

  Set<String> fontsInUse() => {
    ?_look.body.fontFamily,
    for (final heading in _look.headings.values) ?heading.fontFamily,
    for (final editor in [
      controller,
      for (final table in tables.all)
        for (final row in table.rows)
          for (final cell in row.cells) cell.controller,
    ])
      for (final operation in editor.document.toDelta().operations)
        if (operation.attributes?[Attribute.font.key] case final String font)
          font,
  };

  FocusNode? activeCellFocus;

  void focusCell(TableCellRef cell, FocusNode focusNode) {
    activeCellFocus = focusNode;
    activeController.value = cell.cell.controller;
    activeCell.value = cell;
  }

  void focusMain() {
    activeCellFocus = null;
    activeController.value = controller;
    activeCell.value = null;
  }

  /// Looks for the table in the main text and inside other tables.
  void removeTable(TableModel table) {
    controller.removeTable(table.id);
    for (final other in tables.all) {
      for (final row in other.rows) {
        for (final cell in row.cells) {
          cell.controller.removeTable(table.id);
        }
      }
    }
    focusMain();
  }

  void _load(
    LoadedDocument loaded, {
    required String? name,
    required String? path,
    required DocumentFormat format,
  }) {
    final previous = generation == 0 ? null : controller;
    _document = loaded;
    _look = loaded.look;
    headersFooters = loaded.headersFooters;
    _pageSetupChanged = false;
    controller = QuillController(
      document: Document.fromDelta(loaded.delta),
      selection: const TextSelection.collapsed(offset: 0),
      config: QuillControllerConfig(
        clipboardConfig: QuillClipboardConfig(
          onRichTextPaste: (delta, isExternal) async =>
              isExternal ? sanitizePastedDelta(delta) : delta,
          onImagePaste: (bytes) async => dataUriFromMime(bytes, 'image/png'),
        ),
      ),
    );
    _changes?.cancel();
    _changes = controller.document.changes.listen((change) {
      if (change.source == ChangeSource.local) _markDirty();
    });
    _name = name;
    this.path = path;
    this.format = format;
    dirty = false;
    generation++;
    focusMain();
    notifyListeners();
    if (previous != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  void _markDirty() {
    revision++;
    if (dirty) return;
    dirty = true;
    notifyListeners();
  }

  void _saved() {
    dirty = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _changes?.cancel();
    _tableEdits.cancel();
    controller.dispose();
    activeController.dispose();
    activeCell.dispose();
    super.dispose();
  }
}
