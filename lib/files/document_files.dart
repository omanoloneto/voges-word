import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../docx/image_formats.dart';
import '../document/document_codec.dart';

class OpenedFile {
  const OpenedFile({required this.name, required this.bytes, this.path});

  final String name;
  final Uint8List bytes;

  /// Caminho gravável; só existe no computador (no celular e na web o arquivo
  /// chega como cópia).
  final String? path;
}

class PickedImage {
  const PickedImage({required this.bytes, required this.mime});

  final Uint8List bytes;
  final String mime;
}

/// Abre e salva arquivos conforme o que cada sistema permite.
class DocumentFiles {
  bool get canSaveInPlace =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  static final _extensions = [
    for (final format in DocumentFormat.values) format.extension,
  ];

  Future<OpenedFile?> pickDocument() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Abrir documento',
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
      dialogTitle: 'Inserir imagem',
      type: FileType.custom,
      allowedExtensions: insertableImageExtensions,
      withData: true,
    );
    final file = result?.files.single;
    if (file == null) return null;
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    return PickedImage(bytes: bytes, mime: mimeForPath(file.name));
  }

  /// No computador só escolhe o caminho; quem grava é [write].
  Future<String?> chooseSaveLocation(
    String suggestedName,
    DocumentFormat format,
  ) => FilePicker.saveFile(
    dialogTitle: 'Salvar como',
    fileName: suggestedName,
    type: FileType.custom,
    allowedExtensions: [format.extension],
  );

  Future<void> write(String path, Uint8List bytes) =>
      File(path).writeAsBytes(bytes, flush: true);

  /// Celular e web: o sistema grava (ou baixa) o arquivo.
  Future<bool> saveCopy(
    String fileName,
    Uint8List bytes,
    DocumentFormat format,
  ) async {
    final path = await FilePicker.saveFile(
      dialogTitle: 'Salvar como',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: [format.extension],
      bytes: bytes,
    );
    return kIsWeb || path != null;
  }
}
