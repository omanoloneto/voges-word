import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/editor/document_commands.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/editor/ribbon/font_picker.dart';
import 'package:voges_word/editor/ribbon/ribbon.dart';
import 'package:voges_word/editor/ribbon/ribbon_controls.dart';
import 'package:voges_word/editor/ribbon/ribbon_style.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';
import 'package:voges_word/l10n/l10n.dart';

// Each timing compares work done in the same run, so loaded machines pass.
const _timeout = Timeout(Duration(minutes: 4));

FontCatalog _offlineFonts() => FontCatalog(
  listSystemFonts: () async => const [],
  readGoogleCatalog: () async => '',
);

/// Counts the reads of the selection's style: each walks every selected
/// line.
class _CountingController extends QuillController {
  _CountingController(Delta delta)
    : super(
        document: Document.fromDelta(delta),
        selection: const TextSelection.collapsed(offset: 0),
      );

  var styleReads = 0;

  @override
  Style getSelectionStyle() {
    styleReads++;
    return super.getSelectionStyle();
  }
}

/// Counts the walks over the whole document for its fonts.
class _CountingSession extends EditorSession {
  _CountingSession({
    required super.docx,
    required super.plainText,
    required super.files,
    required super.tables,
  });

  var fontReads = 0;

  @override
  Set<String> fontsInUse() {
    fontReads++;
    return super.fontsInUse();
  }
}

_CountingSession _session() {
  final tables = TableStore();
  final docx = DocxCodec(tables);
  return _CountingSession(
    docx: docx,
    plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
    files: DocumentFiles(),
    tables: tables,
  );
}

/// The ribbon alone, showing [controller] as the text being edited.
Future<_CountingSession> _pumpRibbon(
  WidgetTester tester,
  QuillController controller,
) async {
  tester.view.physicalSize = const Size(1800, 400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final session = _session();
  session.activeController.value = controller;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Ribbon(
          session: session,
          fonts: _offlineFonts(),
          actions: RibbonActions(
            insertImage: () {},
            editLink: () {},
            insertTable: (_, _) {},
            removeTable: () {},
            editHeadersFooters: () {},
            refocus: () {},
            pagesView: true,
            onPagesView: (_) {},
            zoom: 1,
            onZoom: (_) {},
          ),
        ),
      ),
    ),
  );
  return session;
}

/// Runs, headings, lists, alignments, colors and spacing in every mix.
Delta _styledText() => Delta()
  ..insert('Bold red ', {
    Attribute.bold.key: true,
    Attribute.color.key: '#C00000',
    Attribute.font.key: 'Georgia',
    Attribute.size.key: '14',
  })
  ..insert('plain ')
  ..insert('marked', {
    Attribute.italic.key: true,
    Attribute.underline.key: true,
    Attribute.background.key: '#FFFF00',
  })
  ..insert('\n', {Attribute.header.key: 2})
  ..insert('Struck ', {Attribute.strikeThrough.key: true})
  ..insert('x2', {Attribute.script.key: Attribute.superscript.value})
  ..insert('\n', {Attribute.align.key: 'center', Attribute.lineHeight.key: 1.5})
  ..insert('First item', {Attribute.bold.key: true})
  ..insert('\n', {Attribute.list.key: 'bullet'})
  ..insert('Second item', {
    Attribute.bold.key: true,
    Attribute.font.key: 'Georgia',
  })
  ..insert('\n', {Attribute.list.key: 'bullet', Attribute.align.key: 'right'})
  ..insert('Counted', {Attribute.size.key: '9'})
  ..insert('\n', {Attribute.list.key: 'ordered'})
  ..insert('H')
  ..insert('2', {Attribute.script.key: Attribute.subscript.value})
  ..insert('O ends here', {Attribute.color.key: '#0070C0'})
  ..insert('\n', {Attribute.align.key: 'justify', Attribute.header.key: 1});

T _widget<T extends Widget>(WidgetTester tester, bool Function(T) test) =>
    tester.widget<T>(find.byWidgetPredicate((w) => w is T && test(w)));

bool _shown(WidgetTester tester, IconData icon) =>
    _widget<RibbonIconButton>(tester, (button) => button.icon == icon).selected;

/// The ribbon's state, read from its widgets.
Map<String, Object?> _ribbonState(WidgetTester tester) => {
  for (final icon in [
    Icons.format_bold,
    Icons.format_italic,
    Icons.format_underlined,
    Icons.strikethrough_s,
    Icons.superscript,
    Icons.subscript,
    Icons.format_align_left,
    Icons.format_align_center,
    Icons.format_align_right,
    Icons.format_align_justify,
    Icons.format_list_bulleted,
    Icons.format_list_numbered,
  ])
    '$icon': _shown(tester, icon),
  'font': tester.widget<FontPicker>(find.byType(FontPicker)).current,
  'size': tester.widget<SizeStepper>(find.byType(SizeStepper)).current,
  'color': _widget<ColorRow>(
    tester,
    (row) => row.icon == Icons.format_color_text,
  ).current,
  'highlight': _widget<ColorRow>(
    tester,
    (row) => row.icon == Icons.border_color,
  ).current,
  'style': [
    for (final name in ['Normal', 'Heading 1', 'Heading 2', 'Heading 3'])
      if (tester
              .widget<Material>(
                find
                    .ancestor(
                      of: find.text(name),
                      matching: find.byType(Material),
                    )
                    .first,
              )
              .color ==
          RibbonColors.selected)
        name,
  ],
};

/// What the ribbon showed when it asked the controller once per value.
Map<String, Object?> _expectedState(
  QuillController controller,
  EditorSession session,
) {
  final look = session.look;
  final header = controller.valueOf<int>(Attribute.header.key) ?? 0;
  final base = header == 0 ? look.body : look.heading(header);
  final sizeValue = controller
      .getSelectionStyle()
      .attributes[Attribute.size.key]
      ?.value;
  final align = controller.valueOf<String>(Attribute.align.key) ?? 'left';
  final list = controller.valueOf<String>(Attribute.list.key);
  return {
    for (final (icon, attribute) in <(IconData, Attribute)>[
      (Icons.format_bold, Attribute.bold),
      (Icons.format_italic, Attribute.italic),
      (Icons.format_underlined, Attribute.underline),
      (Icons.strikethrough_s, Attribute.strikeThrough),
      (Icons.superscript, Attribute.superscript),
      (Icons.subscript, Attribute.subscript),
    ])
      '$icon': controller.isActive(attribute),
    for (final (icon, value) in [
      (Icons.format_align_left, 'left'),
      (Icons.format_align_center, 'center'),
      (Icons.format_align_right, 'right'),
      (Icons.format_align_justify, 'justify'),
    ])
      '$icon': align == value,
    '${Icons.format_list_bulleted}': list == 'bullet',
    '${Icons.format_list_numbered}': list == 'ordered',
    'font': controller.valueOf<String>(Attribute.font.key) ?? base.fontFamily,
    'size': num.tryParse('${sizeValue ?? ''}') ?? base.fontSize,
    'color': controller.valueOf<String>(Attribute.color.key),
    'highlight': controller.valueOf<String>(Attribute.background.key),
    'style': [
      ['Normal', 'Heading 1', 'Heading 2', 'Heading 3'][header],
    ],
  };
}

/// Paragraphs as the readers make them, with runs, lists and headings.
Delta _formattedLines(int count) {
  final delta = Delta();
  for (var index = 0; index < count; index++) {
    delta
      ..insert('Line $index ', {Attribute.bold.key: true})
      ..insert('of the document')
      ..insert('\n', switch (index % 6) {
        0 || 1 => {Attribute.list.key: 'bullet'},
        2 => {Attribute.header.key: 2},
        3 => {Attribute.align.key: 'center'},
        _ => null,
      });
  }
  return delta;
}

/// The shortest of a few runs, which load on the machine only lengthens.
Future<Duration> _fastest(Future<void> Function() work, {int runs = 3}) async {
  var best = const Duration(days: 1);
  for (var run = 0; run < runs; run++) {
    final watch = Stopwatch()..start();
    await work();
    if (watch.elapsed < best) best = watch.elapsed;
  }
  return best;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the ribbon', () {
    testWidgets('reads the selection style once per rebuild', (tester) async {
      final controller = _CountingController(_styledText());
      await _pumpRibbon(tester, controller);
      final length = controller.document.length;

      for (final selection in [
        const TextSelection.collapsed(offset: 3),
        const TextSelection(baseOffset: 2, extentOffset: 40),
        TextSelection(baseOffset: 0, extentOffset: length - 1),
      ]) {
        controller.styleReads = 0;
        controller.updateSelection(selection, ChangeSource.local);
        await tester.pump();
        expect(controller.styleReads, 1, reason: '$selection');
      }

      controller.styleReads = 0;
      controller.replaceText(
        0,
        0,
        'A',
        const TextSelection.collapsed(offset: 1),
      );
      await tester.pump();
      expect(controller.styleReads, 1);
    });

    testWidgets('shows the style of every selection as before', (tester) async {
      final controller = _CountingController(_styledText());
      final session = await _pumpRibbon(tester, controller);
      final length = controller.document.length;
      final selections = [
        for (var offset = 0; offset < length; offset++)
          TextSelection.collapsed(offset: offset),
        for (var start = 0; start < length - 1; start += 3)
          for (final end in [start + 1, start + 5, start + 17, length - 1])
            if (end <= length - 1)
              TextSelection(baseOffset: start, extentOffset: end),
      ];
      var bold = 0;
      var headings = 0;
      for (final selection in selections) {
        controller.updateSelection(selection, ChangeSource.local);
        await tester.pump();
        final state = _ribbonState(tester);
        expect(
          state,
          _expectedState(controller, session),
          reason: '$selection',
        );
        if (state['${Icons.format_bold}'] == true) bold++;
        if ('${state['style']}' != '[Normal]') headings++;
      }
      // Both states appear, so the comparison covers each of them.
      expect(bold, inInclusiveRange(1, selections.length - 1));
      expect(headings, inInclusiveRange(1, selections.length - 1));

      // A format chosen with nothing selected shows before it is typed.
      controller.updateSelection(
        const TextSelection.collapsed(offset: 12),
        ChangeSource.local,
      );
      controller.formatSelection(Attribute.subscript);
      await tester.pump();
      expect(_shown(tester, Icons.subscript), isTrue);
      expect(_ribbonState(tester), _expectedState(controller, session));

      // The spacing shows as the check in its menu.
      final spacings = <String?>[];
      for (final offset in [3, 30, length - 2]) {
        controller.updateSelection(
          TextSelection.collapsed(offset: offset),
          ChangeSource.local,
        );
        await tester.pump();
        await tester.tap(find.byTooltip('Line spacing'));
        await tester.pumpAndSettle();
        final spacing =
            (controller
                        .getSelectionStyle()
                        .attributes[Attribute.lineHeight.key]
                        ?.value
                    as num?)
                ?.toDouble() ??
            session.look.lineSpacing;
        final checked = [
          for (final item in tester.widgetList<MenuItemButton>(
            find.byType(MenuItemButton),
          ))
            if ((item.leadingIcon! as Icon).color != Colors.transparent)
              (item.child! as Text).data,
        ];
        expect(checked, [
          NumberFormat('0.0#', 'en').format(spacing),
        ], reason: 'offset $offset');
        spacings.add(checked.single);
        await tester.tap(find.byTooltip('Line spacing'));
        await tester.pumpAndSettle();
      }
      expect(spacings.toSet(), hasLength(2));
    });

    testWidgets(
      'with 100k lines selected, a rebuild costs about one style read',
      (tester) async {
        final controller = _CountingController(_formattedLines(100000));
        await _pumpRibbon(tester, controller);
        final end = controller.document.length - 1;
        final all = TextSelection(baseOffset: 0, extentOffset: end);
        final almostAll = TextSelection(baseOffset: 1, extentOffset: end);

        controller.updateSelection(all, ChangeSource.local);
        await tester.pump();
        final read = await _fastest(() async => controller.getSelectionStyle());

        var next = almostAll;
        final rebuild = await _fastest(() async {
          controller.updateSelection(next, ChangeSource.local);
          next = next == all ? almostAll : all;
          await tester.pump();
        });
        // Fourteen reads, as before, took about 14 times one read.
        expect(rebuild, lessThan(read * 5), reason: 'one read took $read');
        expect(_shown(tester, Icons.format_bold), isFalse);
      },
      timeout: _timeout,
    );
  });

  group('the font list', () {
    Future<_CountingSession> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = _session();
      final bytes = session.docx.encode(
        Delta()
          ..insert('Hello ', {Attribute.font.key: 'Georgia'})
          ..insert('world', {Attribute.font.key: 'Lato'})
          ..insert('\nMore text\n'),
      );
      session.open(OpenedFile(name: 'fonts.docx', bytes: bytes));
      await tester.pumpWidget(
        VogesWordApp(
          session: session,
          systemOpen: SystemOpen(session.files),
          recents: RecentFiles(session.files),
          fonts: _offlineFonts(),
          launchArguments: const [],
          language: AppLanguage(),
        ),
      );
      await tester.pumpAndSettle();
      return session;
    }

    List<String?> listedFonts(WidgetTester tester) => [
      for (final text in tester.widgetList<Text>(
        find.descendant(of: find.byType(ListView), matching: find.byType(Text)),
      ))
        text.data,
    ];

    testWidgets('is read from the document only when the menu opens', (
      tester,
    ) async {
      final session = await pumpApp(tester);
      final controller = session.controller;
      session.fontReads = 0;

      controller.replaceText(
        6,
        0,
        'big ',
        const TextSelection.collapsed(offset: 10),
      );
      await tester.pump();
      controller.updateSelection(
        const TextSelection(baseOffset: 2, extentOffset: 12),
        ChangeSource.local,
      );
      await tester.pump();
      controller.formatSelection(const FontAttribute('Pacifico'));
      await tester.pumpAndSettle();
      expect(session.fontReads, 0);

      await tester.tap(find.byTooltip('Font'));
      await tester.pumpAndSettle();
      expect(session.fontReads, 1);
      final inUse = session.fontsInUse().toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      expect(inUse, containsAll(['Georgia', 'Lato', 'Pacifico']));
      expect(listedFonts(tester), ['IN THIS DOCUMENT', ...inUse]);

      // Closing and opening again reads the fonts the text has now.
      await tester.tap(find.byTooltip('Font'));
      await tester.pumpAndSettle();
      expect(find.text('IN THIS DOCUMENT'), findsNothing);
      controller.formatText(
        0,
        controller.document.length - 1,
        const FontAttribute('Lato'),
      );
      await tester.pumpAndSettle();
      session.fontReads = 0;
      await tester.tap(find.byTooltip('Font'));
      await tester.pumpAndSettle();
      expect(session.fontReads, 1);
      final now = session.fontsInUse().toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      expect(now, isNot(contains('Pacifico')));
      expect(listedFonts(tester), ['IN THIS DOCUMENT', ...now]);
    });
  });
}
