import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/system_open.dart';

/// Gera imagens da tela para conferência visual; só roda com VW_SCREENSHOTS.
/// `VW_SCREENSHOTS=pasta-de-saida VW_SAMPLES=pasta-com-docx flutter test test/screenshots_test.dart`
void main() {
  final output = Platform.environment['VW_SCREENSHOTS'];
  final samples = Platform.environment['VW_SAMPLES'];

  Future<void> loadFonts() async {
    final flutterRoot =
        Platform.environment['FLUTTER_ROOT'] ?? '/opt/homebrew/share/flutter';
    final material = '$flutterRoot/bin/cache/artifacts/material_fonts';
    const supplemental = '/System/Library/Fonts/Supplemental';
    final families = <String, List<String>>{
      'Roboto': [
        for (final style in [
          'Regular',
          'Medium',
          'Bold',
          'Italic',
          'BoldItalic',
        ])
          '$material/Roboto-$style.ttf',
      ],
      'MaterialIcons': ['$material/MaterialIcons-Regular.otf'],
      for (final family in ['Arial', 'Calibri', 'Aptos'])
        family: [
          for (final style in ['', ' Bold', ' Italic', ' Bold Italic'])
            '$supplemental/Arial$style.ttf',
        ],
      'Times New Roman': [
        for (final style in ['', ' Bold', ' Italic', ' Bold Italic'])
          '$supplemental/Times New Roman$style.ttf',
      ],
    };
    for (final entry in families.entries) {
      final loader = FontLoader(entry.key);
      for (final path in entry.value) {
        final file = File(path);
        if (file.existsSync()) {
          loader.addFont(
            Future.value(ByteData.sublistView(file.readAsBytesSync())),
          );
        }
      }
      await loader.load();
    }
  }

  Future<void> capture(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('shot')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$output/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('telas', (tester) async {
    if (output == null) return;
    await tester.runAsync(loadFonts);
    tester.view.physicalSize = const Size(1180, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final tables = TableStore();
    final docx = DocxCodec(tables);
    final files = DocumentFiles();
    final session = EditorSession(
      docx: docx,
      plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
      files: files,
      tables: tables,
    );
    final sample = samples == null
        ? null
        : File('$samples/${Platform.environment['VW_SAMPLE'] ?? 's2.docx'}');
    if (sample != null && sample.existsSync()) {
      session.open(
        OpenedFile(name: 'documento.docx', bytes: sample.readAsBytesSync()),
      );
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('shot'),
        child: VogesWordApp(
          session: session,
          systemOpen: SystemOpen(files),
          launchArguments: const [],
        ),
      ),
    );
    await capture(tester, '1-inicio');

    final scrollable = find
        .descendant(
          of: find.byType(QuillEditor),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    final offsets = (Platform.environment['VW_OFFSETS'] ?? '700')
        .split(',')
        .map(double.parse);
    for (final offset in offsets) {
      position.jumpTo(offset.clamp(0, position.maxScrollExtent));
      await capture(tester, '2-rolagem-${offset.round()}');
    }
  });
}
