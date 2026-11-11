import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/document/embeds.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/editor/ruler.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';

/// Pixels per point at 100%.
const _scale = 96 / 72;
const _cm = 72 / 2.54;

final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

Future<EditorSession> _pumpApp(
  WidgetTester tester, {
  Size size = const Size(1240, 900),
}) async {
  tester.view.physicalSize = size;
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
  final table = tables.createEmpty(rows: 1, columns: 2, totalWidth: 9000);
  final bytes = docx.encode(
    Delta()
      ..insert('Plain paragraph\n')
      ..insert('Indented paragraph')
      ..insert('\n', {HiddenAttributes.firstLine: 5 * _cm / 4})
      ..insert('A list item')
      ..insert('\n', {'list': 'bullet'})
      ..insert({EmbedTypes.table: encodeTableId(table.id)})
      ..insert('\nLast paragraph\n'),
  );
  session.open(OpenedFile(name: 'ruler.docx', bytes: bytes));

  await tester.pumpWidget(
    VogesWordApp(
      session: session,
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
  return session;
}

/// Puts the caret at the start of the paragraph with [text].
Future<void> _caretAt(
  WidgetTester tester,
  EditorSession session,
  String text,
) async {
  final offset = session.controller.document.toPlainText().indexOf(text);
  expect(offset, isNot(-1));
  session.controller.updateSelection(
    TextSelection.collapsed(offset: offset),
    ChangeSource.local,
  );
  await tester.pumpAndSettle();
}

Map<String, Object?> _attributesOf(EditorSession session, String text) {
  final document = session.controller.document;
  final offset = document.toPlainText().indexOf(text);
  final line = document.queryChild(offset).node! as Line;
  return {
    for (final entry in line.style.attributes.entries)
      entry.key: entry.value.value,
  };
}

/// Drags the mark with [tooltip] by [offset], as a mouse does.
Future<void> _drag(WidgetTester tester, String tooltip, Offset offset) async {
  final mark = find.byTooltip(tooltip);
  expect(mark, findsOneWidget);
  final gesture = await tester.startGesture(
    tester.getCenter(mark),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveBy(offset / 2);
  await tester.pump();
  await gesture.moveBy(offset / 2);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

double _quarters(double points) => (points / (_cm / 4)).round() * (_cm / 4);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the rulers show with the pages and hide from the View tab', (
    tester,
  ) async {
    await _pumpApp(tester);
    expect(find.byType(HorizontalRuler), findsOneWidget);
    expect(find.byType(VerticalRuler), findsOneWidget);

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continuous'));
    await tester.pumpAndSettle();
    // Without pages there is no page to measure on the side, as in Word.
    expect(find.byType(HorizontalRuler), findsOneWidget);
    expect(find.byType(VerticalRuler), findsNothing);

    await tester.tap(find.text('Pages'));
    await tester.pumpAndSettle();
    final editor = tester.state(find.byType(QuillEditor).first);
    await tester.tap(find.text('Ruler'));
    await tester.pumpAndSettle();
    expect(find.byType(HorizontalRuler), findsNothing);
    expect(find.byType(VerticalRuler), findsNothing);
    // The editor stays the same, with its scroll and selection.
    expect(tester.state(find.byType(QuillEditor).first), same(editor));

    await tester.tap(find.text('Ruler'));
    await tester.pumpAndSettle();
    expect(find.byType(HorizontalRuler), findsOneWidget);
    expect(tester.state(find.byType(QuillEditor).first), same(editor));
  }, variant: _desktop);

  testWidgets('a window narrower than the page has no rulers', (tester) async {
    await _pumpApp(tester, size: const Size(600, 900));
    expect(find.byType(HorizontalRuler), findsNothing);
    expect(find.byType(VerticalRuler), findsNothing);
  }, variant: _desktop);

  testWidgets('the horizontal ruler lines up with the page', (tester) async {
    final session = await _pumpApp(tester);
    final look = session.look;
    final paper = tester.getRect(find.byType(QuillEditor).first);
    final pageLeft = paper.left + (paper.width - look.pageWidth * _scale) / 2;
    final margin = tester.getRect(find.byTooltip('Left margin'));
    expect(
      margin.right - 4,
      closeTo(pageLeft + look.margins.left * _scale, 0.01),
    );
    expect(margin.left, closeTo(pageLeft, 0.01));
  }, variant: _desktop);

  testWidgets('the indents follow the paragraph with the caret', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    await _caretAt(tester, session, 'Plain paragraph');
    final hanging = tester.getCenter(find.byTooltip('Hanging indent')).dx;
    expect(tester.getCenter(find.byTooltip('First line indent')).dx, hanging);

    await _caretAt(tester, session, 'Indented paragraph');
    // The file keeps twips: 1.25 cm comes back as 35.45 points.
    expect(
      tester.getCenter(find.byTooltip('First line indent')).dx,
      closeTo(hanging + 35.45 * _scale, 0.01),
    );

    // Lists follow their levels and tables have no indents to drag.
    await _caretAt(tester, session, 'A list item');
    expect(find.byTooltip('First line indent'), findsNothing);
    expect(find.byTooltip('Left margin'), findsOneWidget);
    final tableLine = session.controller.document.toPlainText().indexOf(
      'Last paragraph',
    );
    session.controller.updateSelection(
      TextSelection.collapsed(offset: tableLine - 2),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('First line indent'), findsNothing);
  }, variant: _desktop);

  testWidgets('dragging the first line indent sets it on the paragraph', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    await _caretAt(tester, session, 'Plain paragraph');

    await _drag(
      tester,
      'First line indent',
      const Offset(1.25 * _cm * _scale, 0),
    );

    expect(
      _attributesOf(session, 'Plain paragraph')[HiddenAttributes.firstLine],
      closeTo(1.25 * _cm, 0.01),
    );
    expect(
      _attributesOf(session, 'Plain paragraph'),
      isNot(contains('indent')),
    );

    session.controller.undo();
    await tester.pumpAndSettle();
    expect(
      _attributesOf(session, 'Plain paragraph'),
      isNot(contains(HiddenAttributes.firstLine)),
    );
  }, variant: _desktop);

  testWidgets('the left indent moves in the steps of the indent buttons', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    await _caretAt(tester, session, 'Indented paragraph');

    // A little past one step lands on it.
    await _drag(tester, 'Left indent', const Offset(40 * _scale, 0));

    final attributes = _attributesOf(session, 'Indented paragraph');
    expect(attributes['indent'], 1);
    expect(attributes[HiddenAttributes.firstLine], 35.45);
  }, variant: _desktop);

  testWidgets('the hanging indent moves the other lines, not the first', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    await _caretAt(tester, session, 'Plain paragraph');

    await _drag(tester, 'Hanging indent', const Offset(36 * _scale, 0));

    final attributes = _attributesOf(session, 'Plain paragraph');
    expect(attributes['indent'], 1);
    expect(attributes[HiddenAttributes.firstLine], -36);
  }, variant: _desktop);

  testWidgets('dragging the right indent sets it from the right margin', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    await _caretAt(tester, session, 'Last paragraph');

    await _drag(tester, 'Right indent', const Offset(-_cm * _scale, 0));

    expect(
      _attributesOf(session, 'Last paragraph')[HiddenAttributes.indentRight],
      closeTo(_cm, 0.01),
    );
  }, variant: _desktop);

  testWidgets('dragging a margin on either ruler changes the page', (
    tester,
  ) async {
    final session = await _pumpApp(tester);
    final before = session.look.margins;

    await _drag(tester, 'Left margin', const Offset(_cm * _scale, 0));
    expect(
      session.look.margins.left,
      closeTo(_quarters(before.left + _cm), 0.01),
    );
    expect(session.look.margins.right, before.right);
    expect(session.dirty, isTrue);

    await _drag(tester, 'Top margin', const Offset(0, _cm * _scale));
    expect(
      session.look.margins.top,
      closeTo(_quarters(before.top + _cm), 0.01),
    );
    expect(session.look.margins.bottom, before.bottom);
  }, variant: _desktop);
}
