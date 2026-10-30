import 'package:flutter/material.dart' show IconData, Icons, Slider;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/editor/ribbon/ribbon_controls.dart';
import 'package:voges_word/editor/zoom.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';

Future<void> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tables = TableStore();
  final docx = DocxCodec(tables);
  final files = DocumentFiles();
  await tester.pumpWidget(
    VogesWordApp(
      session: EditorSession(
        docx: docx,
        plainText: PlainTextCodec(
          look: docx.createEmpty().look,
          tables: tables,
        ),
        files: files,
        tables: tables,
      ),
      systemOpen: SystemOpen(files),
      recents: RecentFiles(files),
      fonts: FontCatalog(
        listSystemFonts: () async => const [],
        readGoogleCatalog: () async => '',
      ),
      launchArguments: const [],
      language: AppLanguage(),
    ),
  );
  await tester.pumpAndSettle();
}

Slider _slider(WidgetTester tester) => tester.widget(find.byType(Slider));

double _zoom(WidgetTester tester) => _slider(tester).value;

/// Moves the status bar's slider to [zoom], which it sets in 5% steps.
Future<void> _slideTo(WidgetTester tester, double zoom) async {
  _slider(tester).onChanged!(zoom);
  await tester.pump();
}

RibbonIconButton _button(WidgetTester tester, IconData icon) => tester.widget(
  find.ancestor(of: find.byIcon(icon), matching: find.byType(RibbonIconButton)),
);

Future<void> _tapButton(WidgetTester tester, IconData icon) async {
  await tester.tap(find.byIcon(icon));
  await tester.pump();
}

Future<void> _pressControl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('nextZoomLevel', () {
    test('steps from a level to the one beside it', () {
      expect(nextZoomLevel(1.0, 1), 1.1);
      expect(nextZoomLevel(1.0, -1), 0.9);
      expect(nextZoomLevel(1.25, 1), 1.5);
      expect(nextZoomLevel(1.25, -1), 1.1);
    });

    test('steps from between levels to the nearest level that way', () {
      expect(nextZoomLevel(1.3, 1), 1.5);
      expect(nextZoomLevel(1.3, -1), 1.25);
      expect(nextZoomLevel(0.55, -1), smallestZoom);
      expect(nextZoomLevel(1.95, 1), largestZoom);
    });

    test('takes a level the slider is a hair off as that level', () {
      expect(nextZoomLevel(1.2499999999999998, 1), 1.5);
      expect(nextZoomLevel(1.2499999999999998, -1), 1.1);
      expect(nextZoomLevel(1.2500000000000002, 1), 1.5);
      expect(nextZoomLevel(1.2500000000000002, -1), 1.1);
    });

    test('is null past the ends', () {
      expect(nextZoomLevel(smallestZoom, -1), isNull);
      expect(nextZoomLevel(largestZoom, 1), isNull);
      expect(nextZoomLevel(0.3, -1), isNull);
      expect(nextZoomLevel(0.3, 1), smallestZoom);
      expect(nextZoomLevel(3, 1), isNull);
      expect(nextZoomLevel(3, -1), largestZoom);
    });
  });

  testWidgets('the ribbon steps from a zoom the slider set to the next '
      'level each way', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.text('View'));
    await tester.pump();

    await _slideTo(tester, 1.3);
    expect(_button(tester, Icons.zoom_out).onPressed, isNotNull);
    await _tapButton(tester, Icons.zoom_in);
    expect(_zoom(tester), 1.5);

    await _slideTo(tester, 1.3);
    await _tapButton(tester, Icons.zoom_out);
    expect(_zoom(tester), 1.25);

    await _slideTo(tester, 0.55);
    await _tapButton(tester, Icons.zoom_out);
    expect(_zoom(tester), 0.5);
    expect(_button(tester, Icons.zoom_out).onPressed, isNull);

    await _slideTo(tester, 1.95);
    await _tapButton(tester, Icons.zoom_in);
    expect(_zoom(tester), 2.0);
    expect(_button(tester, Icons.zoom_in).onPressed, isNull);
  });

  testWidgets('the zoom shortcuts step from a zoom the slider set to the '
      'next level each way', (tester) async {
    await _pumpApp(tester);

    await _slideTo(tester, 1.3);
    await _pressControl(tester, LogicalKeyboardKey.equal);
    expect(_zoom(tester), 1.5);

    await _slideTo(tester, 1.3);
    await _pressControl(tester, LogicalKeyboardKey.minus);
    expect(_zoom(tester), 1.25);

    await _slideTo(tester, 0.55);
    await _pressControl(tester, LogicalKeyboardKey.minus);
    expect(_zoom(tester), 0.5);
    await _pressControl(tester, LogicalKeyboardKey.minus);
    expect(_zoom(tester), 0.5);

    await _slideTo(tester, 1.95);
    await _pressControl(tester, LogicalKeyboardKey.equal);
    expect(_zoom(tester), 2.0);
    await _pressControl(tester, LogicalKeyboardKey.equal);
    expect(_zoom(tester), 2.0);

    await _slideTo(tester, 1.0);
    await _pressControl(tester, LogicalKeyboardKey.equal);
    expect(_zoom(tester), 1.1);
    await _pressControl(tester, LogicalKeyboardKey.minus);
    await _pressControl(tester, LogicalKeyboardKey.minus);
    expect(_zoom(tester), 0.9);
  });
}
