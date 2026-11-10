// Measures how the editor copes with a long book: the real window with the
// whole interface, the book opened the way the system hands a file over and
// the typing sent as the messages of the system's text input.
//
//   flutter build macos --profile -t benchmark/long_document.dart
//   open -g -n "build/macos/Build/Products/Profile/Voges Word.app" \
//     --env BENCH=quiet --stdout /tmp/long.txt --stderr /tmp/long-errors.txt
//
// The BENCH environment variable takes options separated by commas:
//
// * `quiet` leaves the window where the system put it, without the focus;
// * `chapters=N` sets the size of the book (72 chapters, about 850 pages,
//   when left out);
// * `nospell` leaves the spell checker out;
// * `repeat=N` makes every group of steps N times longer, to sample it;
// * the names of the groups of steps (`type`, `keys`, `pointer`, `scroll`,
//   `shell`) run only those groups after the opening.
//
// The app is sandboxed and shares its container with the installed one, so
// the recovery copy and the recent files are left out of a run.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:voges_word/app.dart';
import 'package:voges_word/document/plain_text_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_builder.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/editor/editor_session.dart';
import 'package:voges_word/editor/paper_view.dart';
import 'package:voges_word/editor/status_bar.dart';
import 'package:voges_word/editor/title_bar.dart';
import 'package:voges_word/editor/window_buttons.dart';
import 'package:voges_word/files/document_files.dart';
import 'package:voges_word/files/recent_files.dart';
import 'package:voges_word/files/system_open.dart';
import 'package:voges_word/fonts/font_catalog.dart';
import 'package:voges_word/l10n/app_language.dart';
import 'package:voges_word/l10n/l10n.dart';
import 'package:voges_word/spell/spell_checker.dart';
import 'package:window_manager/window_manager.dart';

const _groups = ['type', 'keys', 'pointer', 'scroll', 'shell'];

const _textInput = 'flutter/textinput';
const _codec = JSONMethodCodec();

late final _InputTap _input;

class _BenchBinding extends WidgetsFlutterBinding {
  /// Keeps the frames coming and the editor focused while the window is
  /// covered, so a run never stalls halfway.
  @override
  void handleAppLifecycleStateChanged(AppLifecycleState state) =>
      super.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

  @override
  BinaryMessenger createBinaryMessenger() =>
      _input = _InputTap(super.createBinaryMessenger());
}

/// Watches what the app sends to the system's text input: its size is what
/// the system has to read after a key.
class _InputTap extends BinaryMessenger {
  _InputTap(this._inner);

  final BinaryMessenger _inner;

  /// The client the system names in its messages.
  int? client;
  var bytes = 0;
  ByteData? _editingState;

  @override
  // ignore: deprecated_member_use
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    ui.PlatformMessageResponseCallback? callback,
  ) =>
      // ignore: deprecated_member_use
      _inner.handlePlatformMessage(channel, data, callback);

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    if (channel == _textInput && message != null) {
      bytes += message.lengthInBytes;
      final head = ascii.decode(
        message.buffer.asUint8List(
          message.offsetInBytes,
          math.min(64, message.lengthInBytes),
        ),
        allowInvalid: true,
      );
      if (head.contains('TextInput.setEditingState')) {
        _editingState = message;
      } else if (head.contains('TextInput.setClient')) {
        final arguments = _codec.decodeMethodCall(message).arguments as List;
        client = arguments.first as int;
      }
    }
    return _inner.send(channel, message);
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      _inner.setMessageHandler(channel, handler);

  /// The value the app set since the last call, if it set one. Decoded only
  /// here, outside of what a step measures.
  TextEditingValue? takeEditingState() {
    final message = _editingState;
    if (message == null) return null;
    _editingState = null;
    final arguments = _codec.decodeMethodCall(message).arguments as Map;
    return TextEditingValue.fromJSON(arguments.cast<String, dynamic>());
  }
}

Future<void> main() async {
  _BenchBinding();
  final options = (Platform.environment['BENCH'] ?? '').split(',');
  print('pid $pid options $options');
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'Voges Word',
      size: Size(1240, 880),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: true,
    ),
    () async {
      await placeNativeWindowButtons(titleBarHeight);
      if (options.contains('quiet')) return;
      await windowManager.show();
      await windowManager.focus();
    },
  );

  const locale = Locale('en');
  final tables = TableStore();
  final docx = DocxCodec(tables);
  final files = DocumentFiles();
  final session = EditorSession(
    docx: docx,
    plainText: PlainTextCodec(look: docx.createEmpty().look, tables: tables),
    files: files,
    tables: tables,
    locale: SessionLocale.of(lookupAppLocalizations(locale)),
  );
  final backend = options.contains('nospell') ? null : platformSpellBackend();
  final spelling = backend == null
      ? null
      : (SpellChecker(backend)
          ..language = spellingLanguage(locale)
          ..load());
  runApp(
    VogesWordApp(
      session: session,
      systemOpen: SystemOpen(files),
      recents: RecentFiles(files),
      fonts: FontCatalog()..load().ignore(),
      launchArguments: const [],
      language: AppLanguage(locale),
      windowButtons: await WindowButtonsLayout.forPlatform(),
      spelling: spelling,
    ),
  );
  try {
    await _Bench(session, options).run();
  } catch (error, stack) {
    print('failed: $error\n$stack');
    exit(1);
  }
  exit(0);
}

int _option(List<String> options, String name, int fallback) {
  for (final option in options) {
    if (option.startsWith('$name=')) {
      return int.parse(option.substring(name.length + 1));
    }
  }
  return fallback;
}

const _words = [
  'time',
  'ship',
  'star',
  'light',
  'door',
  'year',
  'hand',
  'voice',
  'night',
  'engine',
  'window',
  'orbit',
  'signal',
  'garden',
  'letter',
  'clock',
  'river',
  'the',
  'a',
  'of',
  'and',
  'to',
  'in',
  'that',
  'was',
  'she',
  'he',
  'it',
  'had',
  'with',
  'for',
  'her',
  'his',
  'not',
  'but',
  'from',
  'they',
  'were',
  'when',
  'there',
  'would',
  'could',
  'before',
  'after',
  'again',
  'never',
  'always',
  'looked',
  'turned',
  'opened',
  'waited',
  'remembered',
  'whispered',
  'crossed',
  'followed',
  'answered',
  'promised',
  'returned',
  'silent',
  'distant',
  'bright',
  'ancient',
  'broken',
  'quiet',
  'endless',
  'familiar',
  'impossible',
  'slowly',
  'together',
  'somewhere',
  'tomorrow',
  'yesterday',
  'century',
  'moment',
  'memory',
  'future',
  'station',
  'corridor',
  'captain',
  'stranger',
  'promise',
];

/// Invented names, which the spell checker marks as a real book's are.
const _names = ['Lyra', 'Kaelen', 'Vossk', 'Tessaly', 'Orrin'];

String _prose(math.Random random, int length) {
  final text = StringBuffer();
  var starts = true;
  var untilStop = 6 + random.nextInt(14);
  while (text.length < length) {
    var word = random.nextInt(40) == 0
        ? _names[random.nextInt(_names.length)]
        : _words[random.nextInt(_words.length)];
    if (starts) word = word[0].toUpperCase() + word.substring(1);
    text.write(word);
    starts = --untilStop == 0;
    if (starts) {
      text.write('. ');
      untilStop = 6 + random.nextInt(14);
    } else {
      text.write(random.nextInt(12) == 0 ? ', ' : ' ');
    }
  }
  final trimmed = text.toString().trimRight();
  return '${trimmed.replaceFirst(RegExp(r'[,.]$'), '')}.';
}

/// A novel: chapters that start on a new page, each with a heading and a
/// mix of short lines of dialog, paragraphs and a few long ones.
List<int> _book(int chapters) {
  final random = math.Random(7);
  final spec = DocumentSpec(
    page: const PageSpec(
      width: 612,
      height: 792,
      margins: EdgeInsets.fromLTRB(90, 72, 90, 72),
    ),
    defaultRun: const RunFormat(font: 'Arial', size: 11),
    defaultParagraph: const ParagraphFormat(
      spaceAfter: 10,
      lineSpacing: LineSpacing.multiple(1.15),
    ),
  );
  const centered = ParagraphFormat(align: ParagraphAlign.center);
  spec.body
    ..add(
      const ParagraphSpec([
        TextSpec('The Echoes of Lyra', RunFormat(bold: true, size: 28)),
      ], format: centered),
    )
    ..add(
      const ParagraphSpec([
        TextSpec('A long book for the benchmark'),
      ], format: centered),
    );
  for (var chapter = 1; chapter <= chapters; chapter++) {
    spec.body
      ..add(const ParagraphSpec([BreakSpec(BreakKind.page)]))
      ..add(
        ParagraphSpec([
          TextSpec('Chapter $chapter: ${_prose(random, 24)}'),
        ], heading: 1),
      );
    for (var paragraph = 0; paragraph < 112; paragraph++) {
      final roll = random.nextInt(100);
      final length = switch (roll) {
        < 35 => 30 + random.nextInt(91),
        < 85 => 170 + random.nextInt(251),
        _ => 450 + random.nextInt(341),
      };
      final text = _prose(random, length);
      final cut = random.nextInt(100) < 7
          ? text.lastIndexOf(' ', text.length ~/ 2)
          : -1;
      spec.body.add(
        ParagraphSpec([
          if (cut > 0) ...[
            TextSpec(text.substring(0, cut)),
            TextSpec(text.substring(cut), const RunFormat(italic: true)),
          ] else
            TextSpec(text),
        ], format: const ParagraphFormat(firstLine: 18)),
      );
    }
  }
  return DocxBuilder(spec).build().encode();
}

class _Bench {
  _Bench(this.session, this.options)
    : repeat = _option(options, 'repeat', 1),
      groups = switch (options.where(_groups.contains).toSet()) {
        final chosen when chosen.isNotEmpty => chosen,
        _ => _groups.toSet(),
      } {
    SchedulerBinding.instance.addTimingsCallback(_timings.addAll);
  }

  final EditorSession session;
  final List<String> options;
  final int repeat;
  final Set<String> groups;
  final _timings = <FrameTiming>[];
  final _notes = <String>[];

  /// The frames a step asked for. The blinking caret draws frames of its
  /// own, which would water the numbers of a step down.
  final _asked = <int>{};
  var _pointer = 0;

  /// What the system's text input holds: the last value either side sent.
  TextEditingValue? _model;

  QuillController get controller => session.controller;
  Document get document => controller.document;

  Future<void> run() async {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final window = view.physicalSize;
    print(
      'window ${window.width.round()}x${window.height.round()} at '
      '${view.devicePixelRatio}x, ${view.display.refreshRate} Hz, '
      'groups $groups, repeat $repeat',
    );
    await step('first frames', () => frame(5));

    final clock = Stopwatch()..start();
    final bytes = _book(_option(options, 'chapters', 72));
    print(
      'book of ${bytes.length} bytes made in ${clock.elapsedMilliseconds} ms',
    );
    await step('open the book', () => _open(bytes));
    final text = document.toPlainText();
    print(
      '  ${document.root.childCount} top nodes, ${text.length} characters, '
      '${_editor.renderEditor.pageCount} pages, text input client '
      '${_input.client}',
    );
    await step('until the app is quiet', _quiet);
    await step('idle, 30 frames', () => frame(30));

    if (_input.client == null) {
      print('no text input connection: the typing steps are left out');
      groups.removeAll(['type', 'keys']);
    }
    final length = document.length;
    final places = {'start': 400, 'middle': length ~/ 2, 'end': length - 40};
    if (groups.contains('type')) {
      for (final MapEntry(key: place, value: offset) in places.entries) {
        await step('caret to the $place', () => _caretTo(offset));
        await _typing(
          'type 20 characters at the $place',
          'time and again there',
        );
        await step('idle 1.5 s after typing', _idle);
      }
    }
    if (groups.contains('keys')) {
      await step('caret to the middle', () => _caretTo(length ~/ 2));
      await _typing('Enter x3 in the middle', '\n\n\n');
      await _selectors('Backspace x3 in the middle', 'deleteBackward:', 3);
      await _selectors('arrow right x10', 'moveRight:', 10);
      await _selectors('arrow down x10', 'moveDown:', 10);
      await _selectors('arrow up x10', 'moveUp:', 10);
      await _each('select all', repeat, (_) async {
        Actions.invoke(
          primaryFocus!.context!,
          const SelectAllTextIntent(SelectionChangedCause.keyboard),
        );
      });
      await _selectors('arrow left, drops the selection', 'moveLeft:', 1);
      await step('caret to the middle', () => _caretTo(length ~/ 2));
      await _each('Cmd down and up x3', 3 * repeat, (_) async {
        _meta(down: true);
        await frame();
        _meta(down: false);
      });
    }
    if (groups.contains('pointer')) {
      await step('caret to the middle', () => _caretTo(length ~/ 2));
      final area = _viewport;
      GestureBinding.instance.handlePointerEvent(
        PointerAddedEvent(position: area.center, kind: PointerDeviceKind.mouse),
      );
      await _each('mouse move over the text x60', 60 * repeat, (i) async {
        GestureBinding.instance.handlePointerEvent(
          PointerHoverEvent(
            position:
                area.center + Offset(i % 60 * 2.0 - 60, i % 60 * 3.0 - 90),
            kind: PointerDeviceKind.mouse,
          ),
        );
      });
      await _each(
        'click on the text x6',
        6 * repeat,
        (i) =>
            _click(area.center + Offset(i % 6 * 11.0 - 30, i % 6 * 37.0 - 90)),
        // Far enough apart in time not to count as a double click.
        before: (_) => Future<void>.delayed(const Duration(milliseconds: 450)),
      );
    }
    if (groups.contains('scroll')) {
      await step('caret to the start', () => _caretTo(400));
      final area = _viewport;
      await _each('wheel down x60', 60 * repeat, (_) async {
        GestureBinding.instance.handlePointerEvent(
          PointerScrollEvent(
            position: area.center,
            kind: PointerDeviceKind.mouse,
            scrollDelta: const Offset(0, 90),
          ),
        );
      });
      final position = _editor.scrollController.position;
      await _each('jump a twentieth of the book x20', 20 * repeat, (i) async {
        position.jumpTo(position.maxScrollExtent * ((i + 1) % 21) / 20);
      });
      await _each('zoom 100% to 110% and back', 2 * repeat, (i) async {
        _widget<StatusBar>().onZoomChanged(i.isEven ? 1.1 : 1);
      });
    }
    if (groups.contains('shell')) await _shell();
    await step('idle after everything', () => frame(3));
  }

  /// Hands the book over as the system does when a file is opened with the
  /// app, without a path: the recent files stay as they are.
  Future<void> _open(List<int> bytes) async {
    final generation = session.generation;
    final loaded = Completer<void>();
    void listen() {
      if (session.generation != generation && !loaded.isCompleted) {
        loaded.complete();
      }
    }

    session.addListener(listen);
    final clock = Stopwatch()..start();
    ui.channelBuffers.push(
      'voges_word/open',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('open', [
          {'name': 'Long book.docx', 'bytes': Uint8List.fromList(bytes)},
        ]),
      ),
      (_) {},
    );
    await loaded.future;
    session.removeListener(listen);
    final ready = clock.elapsedMilliseconds;
    await frame();
    final shown = clock.elapsedMilliseconds;
    await frame(3);
    _notes.add('document ready after $ready ms, first frame after $shown ms');
  }

  /// Waits until a whole second passes without the app holding the screen
  /// for more than a frame or two: the checks that run after the opening.
  Future<void> _quiet() async {
    final clock = Stopwatch()..start();
    var worst = 0;
    var quietSince = 0;
    while (clock.elapsed < const Duration(seconds: 120)) {
      final beat = Stopwatch()..start();
      var stall = 0;
      final monitor = Timer.periodic(const Duration(milliseconds: 1), (_) {
        stall = math.max(stall, beat.elapsedMicroseconds);
        beat.reset();
      });
      await Future<void>.delayed(const Duration(seconds: 1));
      monitor.cancel();
      worst = math.max(worst, stall);
      if (stall > 34000) quietSince = clock.elapsedMilliseconds;
      if (clock.elapsedMilliseconds - quietSince >= 3000) break;
    }
    _notes.add(
      'quiet after ${quietSince / 1000} s, worst hold '
      '${(worst / 1000).round()} ms',
    );
  }

  Future<void> _idle() =>
      Future<void>.delayed(const Duration(milliseconds: 1500));

  /// Moves the caret as a click would and waits for the view to follow it.
  Future<void> _caretTo(int offset) async {
    controller.updateSelection(
      TextSelection.collapsed(offset: offset),
      ChangeSource.local,
    );
    await frame(2);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await frame(2);
  }

  /// Types [text] one character per frame, as the system's text input does:
  /// each key arrives with the whole text the system holds.
  Future<void> _typing(String name, String text) {
    late ByteData message;
    final keys = text * repeat;
    return _each(
      name,
      keys.length,
      (_) => _fromSystem(message),
      before: (i) async => message = _typed(keys[i]),
    );
  }

  /// Keys the system turns into commands, such as Backspace and the arrows.
  Future<void> _selectors(String name, String selector, int count) {
    final message = _codec.encodeMethodCall(
      MethodCall('TextInputClient.performSelectors', [
        _input.client,
        [selector],
      ]),
    );
    return _each(name, count * repeat, (_) => _fromSystem(message));
  }

  ByteData _typed(String character) {
    final remote = _input.takeEditingState() ?? _model!;
    final selection = remote.selection;
    final next = TextEditingValue(
      text: remote.text.replaceRange(selection.start, selection.end, character),
      selection: TextSelection.collapsed(
        offset: selection.start + character.length,
      ),
    );
    _model = next;
    return _codec.encodeMethodCall(
      MethodCall('TextInputClient.updateEditingState', [
        _input.client,
        next.toJSON(),
      ]),
    );
  }

  Future<void> _fromSystem(ByteData message) {
    final done = Completer<void>();
    ui.channelBuffers.push(_textInput, message, (_) => done.complete());
    return done.future;
  }

  Future<void> _click(Offset at) async {
    final pointer = ++_pointer;
    GestureBinding.instance
      ..handlePointerEvent(
        PointerHoverEvent(position: at, kind: PointerDeviceKind.mouse),
      )
      ..handlePointerEvent(
        PointerDownEvent(
          pointer: pointer,
          position: at,
          kind: PointerDeviceKind.mouse,
          buttons: kPrimaryMouseButton,
        ),
      )
      ..handlePointerEvent(
        PointerUpEvent(
          pointer: pointer,
          position: at,
          kind: PointerDeviceKind.mouse,
        ),
      );
  }

  void _meta({required bool down}) {
    // ignore: deprecated_member_use
    ServicesBinding.instance.keyEventManager.handleKeyData(
      ui.KeyData(
        timeStamp: SchedulerBinding.instance.currentSystemFrameTimeStamp,
        type: down ? ui.KeyEventType.down : ui.KeyEventType.up,
        physical: PhysicalKeyboardKey.metaLeft.usbHidUsage,
        logical: LogicalKeyboardKey.metaLeft.keyId,
        character: null,
        synthesized: true,
      ),
    );
  }

  /// What the parts of the app around the editor cost on this document.
  Future<void> _shell() async {
    await step('caret to the middle', () => _caretTo(document.length ~/ 2));
    final text = document.toPlainText();
    final value = _editor.textEditingValue;
    _time('plain text, cached', document.toPlainText);
    _time('plain text after an edit', document.toPlainText, before: _edit);
    _time('delta of the document', document.toDelta);
    _time('document tree from the delta', () {
      Document.fromDelta(document.toDelta());
    });
    _time('status bar: text of the document', session.plainTextContent);
    _time('status bar: words', () {
      RegExp(
        r'[\p{L}\p{N}]+(?:[-’\x27][\p{L}\p{N}]+)*',
        unicode: true,
      ).allMatches(text).length;
    });
    _time('status bar: characters', () {
      text.replaceAll(RegExp(r'[\n\uFFFC]'), '').length;
    });
    _time('fonts in use', session.fontsInUse);
    _time('editing state as a message', () {
      _codec.encodeMethodCall(
        MethodCall('TextInput.setEditingState', value.toJSON()),
      );
    });
    final message = _codec.encodeMethodCall(
      MethodCall('TextInputClient.updateEditingState', [1, value.toJSON()]),
    );
    _time('editing state from a message', () {
      final arguments = _codec.decodeMethodCall(message).arguments as List;
      TextEditingValue.fromJSON(arguments[1] as Map<String, dynamic>);
    });
    var saved = 0;
    _time('recovery copy (.docx of the document)', () {
      saved = session.snapshot().bytes.length;
    }, times: 2);
    print('  $saved bytes in the copy');
    await step('idle 1.5 s after the edits', _idle);
  }

  void _edit() {
    final offset = controller.selection.baseOffset;
    controller.replaceText(
      offset,
      0,
      'x',
      TextSelection.collapsed(offset: offset + 1),
    );
  }

  /// Prints the best of [times] runs: a step with no frames of its own.
  void _time(
    String name,
    void Function() run, {
    VoidCallback? before,
    int times = 3,
  }) {
    var best = double.infinity;
    for (var i = 0; i < times; i++) {
      before?.call();
      final clock = Stopwatch()..start();
      run();
      best = math.min(best, clock.elapsedMicroseconds / 1000);
    }
    print('${name.padRight(46)} ${_ms(best)} ms');
  }

  /// Runs [act] [count] times, a frame after each, and notes what each one
  /// cost: until the app answered and until the frame with it was built.
  /// [before] prepares a turn outside of what is measured.
  Future<void> _each(
    String name,
    int count,
    Future<void> Function(int index) act, {
    Future<void> Function(int index)? before,
  }) => step(name, () async {
    final answered = <double>[];
    final built = <double>[];
    final sent = _input.bytes;
    for (var i = 0; i < count; i++) {
      await before?.call(i);
      final clock = Stopwatch()..start();
      await act(i);
      answered.add(clock.elapsedMicroseconds / 1000);
      await frame();
      built.add(clock.elapsedMicroseconds / 1000);
    }
    _notes.add(
      'each: answered in ${_spreadOf(answered)}, frame built after '
      '${_spreadOf(built)}, ${((_input.bytes - sent) / count / 1024).round()} '
      'KB to the text input',
    );
  });

  EditorState get _editor {
    EditorState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is EditorState) {
        found = element.state as EditorState;
      } else {
        element.visitChildren(visit);
      }
    }

    _element<PaperView>().visitChildren(visit);
    return found!;
  }

  /// The part of the window that shows the pages.
  Rect get _viewport {
    final box = _element<PaperView>().renderObject! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  T _widget<T extends Widget>() => _element<T>().widget as T;

  Element _element<T extends Widget>() {
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      if (element.widget is T) {
        found = element;
      } else {
        element.visitChildren(visit);
      }
    }

    WidgetsBinding.instance.rootElement!.visitChildren(visit);
    return found!;
  }

  Future<void> frame([int count = 1]) async {
    for (var i = 0; i < count; i++) {
      await SchedulerBinding.instance.endOfFrame;
      _asked.add(ui.PlatformDispatcher.instance.frameData.frameNumber);
    }
  }

  /// Runs [run] and prints how its frames went, the longest time the app
  /// held the screen and the memory.
  Future<void> step(String name, Future<void> Function() run) async {
    _timings.clear();
    _notes.clear();
    _asked.clear();
    var peak = ProcessInfo.currentRss;
    final sampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
      peak = math.max(peak, ProcessInfo.currentRss);
    });
    var hold = 0;
    final beat = Stopwatch()..start();
    final monitor = Timer.periodic(const Duration(milliseconds: 1), (_) {
      hold = math.max(hold, beat.elapsedMicroseconds);
      beat.reset();
    });
    final clock = Stopwatch()..start();
    await run();
    final took = clock.elapsedMicroseconds / 1000;
    hold = math.max(hold, beat.elapsedMicroseconds);
    monitor.cancel();
    await _drain();
    sampler.cancel();
    peak = math.max(peak, ProcessInfo.currentRss);

    final line = StringBuffer(name.padRight(46))
      ..write(' ${took.toStringAsFixed(0).padLeft(7)} ms')
      ..write(' | held ${(hold / 1000).toStringAsFixed(0).padLeft(6)} ms');
    final asked = [
      for (final timing in _timings)
        if (_asked.contains(timing.frameNumber)) timing,
    ];
    final frames = asked.isEmpty ? _timings : asked;
    if (frames.isNotEmpty) {
      line
        ..write(' | ${frames.length.toString().padLeft(3)} frames')
        ..write(' | build ${_spreadOf(_phase(frames, (t) => t.buildDuration))}')
        ..write(
          ' | raster ${_spreadOf(_phase(frames, (t) => t.rasterDuration))}',
        );
    }
    line.write(' | rss ${ProcessInfo.currentRss >> 20} MB, peak ${peak >> 20}');
    print(line);
    for (final note in _notes) {
      print('  $note');
    }
  }

  List<double> _phase(
    List<FrameTiming> frames,
    Duration Function(FrameTiming timing) phase,
  ) => [for (final timing in frames) phase(timing).inMicroseconds / 1000];

  /// Average, 90th percentile and worst, in milliseconds.
  static String _spreadOf(List<double> values) {
    final times = [...values]..sort();
    final average = times.reduce((a, b) => a + b) / times.length;
    final high = times[((times.length - 1) * 0.9).round()];
    return '${_ms(average)} ${_ms(high)} ${_ms(times.last)}';
  }

  static String _ms(double value) => value.toStringAsFixed(1).padLeft(7);

  /// Waits for the timings of the frames the step asked for: the engine
  /// reports them in batches, some time after they were drawn.
  Future<void> _drain() async {
    final last = _asked.fold(-1, math.max);
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 30)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (last < 0 && clock.elapsedMilliseconds >= 300) return;
      if (last >= 0 && _timings.any((t) => t.frameNumber >= last)) return;
    }
  }
}
