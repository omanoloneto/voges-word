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
import '../document/headers_footers.dart';
import '../document/plain_text_codec.dart';
import '../document/tables.dart';
import '../files/document_files.dart';
import '../files/recovery.dart';
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
           SessionLocale.of(lookupAppLocalizations(appLanguages.first)) {
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

  void open(OpenedFile file) {
    final format = DocumentFormat.fromFileName(file.name);
    if (format == null) {
      throw DocumentProblemException(
        file.name.toLowerCase().endsWith('.doc')
            ? DocumentProblem.legacyDoc
            : DocumentProblem.unsupportedFormat,
      );
    }
    final LoadedDocument loaded;
    try {
      loaded = format == DocumentFormat.docx
          ? docx.decode(file.bytes)
          : plainText.decode(file.bytes);
    } on DocumentProblemException {
      rethrow;
    } on FormatException {
      throw DocumentProblemException(DocumentProblem.damaged);
    }
    _load(loaded, name: file.name, path: file.path, format: format);
  }

  RecoverySnapshot snapshot() => RecoverySnapshot(
    name: _name ?? '',
    path: path,
    format: format,
    bytes: encode(format),
    savedAt: DateTime.now(),
  );

  /// Reopens the recovery copy as a document that is not saved yet.
  void restore(RecoverySnapshot snapshot, {required bool keepPath}) {
    final loaded = snapshot.format == DocumentFormat.docx
        ? docx.decode(snapshot.bytes)
        : plainText.decode(snapshot.bytes);
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
    final chosenFormat = DocumentFormat.fromFileName(chosen);
    if (chosenFormat == null) chosen = '$chosen.${target.extension}';
    final finalFormat = chosenFormat ?? target;
    await files.write(chosen, encode(finalFormat));
    path = chosen;
    name = chosen.split(RegExp(r'[\\/]')).last;
    format = finalFormat;
    _saved();
    return true;
  }

  Uint8List encode(DocumentFormat target) {
    final delta = controller.document.toDelta();
    return target == DocumentFormat.docx
        ? docx.encode(
            delta,
            source: _document.source,
            pageSetup: _pageSetupChanged ? _look : null,
            headersFooters: headersFooters,
          )
        : plainText.encode(delta);
  }

  String plainTextContent() =>
      plainText.plainTextOf(controller.document.toDelta());

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
