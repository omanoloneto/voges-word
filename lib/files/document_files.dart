import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show Rect;
import 'package:share_plus/share_plus.dart';

import '../docx/image_formats.dart';
import '../document/document_codec.dart';

class OpenedFile {
  const OpenedFile({required this.name, required this.bytes, this.path});

  final String name;
  final Uint8List bytes;

  /// Writable path; it only exists on desktop (on phones and the web the file
  /// comes as a copy).
  final String? path;
}

class PickedImage {
  const PickedImage({required this.bytes, required this.mime});

  final Uint8List bytes;
  final String mime;
}

/// Titles of the system file dialogs, set by the screen in the user's language.
class FileDialogTitles {
  const FileDialogTitles({
    this.open = 'Open document',
    this.insertPicture = 'Insert picture',
    this.saveAs = 'Save as',
    this.export = 'Export',
  });

  final String open;
  final String insertPicture;
  final String saveAs;
  final String export;
}

/// Opens and saves files the way each platform allows.
class DocumentFiles {
  FileDialogTitles titles = const FileDialogTitles();

  bool get canSaveInPlace =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  static final _extensions = [
    for (final format in DocumentFormat.values) format.extension,
  ];

  Future<OpenedFile?> pickDocument() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: titles.open,
      type: FileType.custom,
      allowedExtensions: _extensions,
      withData: !canSaveInPlace,
    );
    final file = result?.files.single;
    if (file == null) return null;
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    return OpenedFile(
      name: file.name,
      bytes: bytes,
      path: canSaveInPlace ? file.path : null,
    );
  }

  Future<OpenedFile> read(String path) async => OpenedFile(
    name: path.split(Platform.pathSeparator).last,
    bytes: await File(path).readAsBytes(),
    path: canSaveInPlace ? path : null,
  );

  Future<PickedImage?> pickImage() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: titles.insertPicture,
      type: FileType.custom,
      allowedExtensions: insertableImageExtensions,
      withData: true,
    );
    final file = result?.files.single;
    if (file == null) return null;
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    return PickedImage(bytes: bytes, mime: mimeForPath(file.name));
  }

  /// On desktop it only picks the path; [write] does the writing.
  Future<String?> chooseSaveLocation(
    String suggestedName,
    DocumentFormat format,
  ) => FilePicker.saveFile(
    dialogTitle: titles.saveAs,
    fileName: suggestedName,
    type: FileType.custom,
    allowedExtensions: [format.extension],
  );

  Future<void> write(String path, Uint8List bytes) =>
      File(path).writeAsBytes(bytes, flush: true);

  /// On Linux, share_plus only sends text by email, not files.
  bool get canShare => kIsWeb || !Platform.isLinux;

  Future<void> share(
    Uint8List bytes, {
    required String name,
    required String mime,
    required Rect origin,
  }) => SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(bytes, mimeType: mime, name: name)],
      fileNameOverrides: [name],
      sharePositionOrigin: origin,
    ),
  );

  /// Saves a copy in another format (PDF); false if the user cancels.
  Future<bool> export(Uint8List bytes, String name, String extension) async {
    if (!canSaveInPlace) {
      final path = await FilePicker.saveFile(
        dialogTitle: titles.export,
        fileName: name,
        type: FileType.custom,
        allowedExtensions: [extension],
        bytes: bytes,
      );
      return kIsWeb || path != null;
    }
    var path = await FilePicker.saveFile(
      dialogTitle: titles.export,
      fileName: name,
      type: FileType.custom,
      allowedExtensions: [extension],
    );
    if (path == null) return false;
    if (!path.toLowerCase().endsWith('.$extension')) path = '$path.$extension';
    await write(path, bytes);
    return true;
  }

  /// Phones and the web: the system saves (or downloads) the file.
  Future<bool> saveCopy(
    String fileName,
    Uint8List bytes,
    DocumentFormat format,
  ) async {
    final path = await FilePicker.saveFile(
      dialogTitle: titles.saveAs,
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: [format.extension],
      bytes: bytes,
    );
    return kIsWeb || path != null;
  }
}
