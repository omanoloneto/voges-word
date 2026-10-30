import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voges_word/spell/spell_checker.dart';

/// Flags every "hause"; [onCheck] runs while a batch is being checked.
class _Backend implements SpellBackend {
  _Backend({this.onCheck});

  final void Function()? onCheck;
  var batches = 0;
  var texts = 0;

  @override
  Future<List<List<Misspelling>>> check(
    List<String> texts,
    String language,
  ) async {
    batches++;
    this.texts += texts.length;
    onCheck?.call();
    await Future<void>.delayed(Duration.zero);
    return [
      for (final text in texts)
        [
          for (final match in RegExp('hause').allMatches(text))
            Misspelling(match.start, match.end, const ['house']),
        ],
    ];
  }
}

/// Waits until the checker has drained its queue and checks nothing more.
Future<void> _settle(_Backend backend) async {
  var batches = -1;
  for (var round = 0; round < 10 && batches != backend.batches; round++) {
    batches = backend.batches;
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'a long check is announced a few times, not after every batch',
    () async {
      final backend = _Backend();
      final checker = SpellChecker(backend);
      addTearDown(checker.dispose);
      var announcements = 0;
      checker.addListener(() => announcements++);
      final texts = [
        for (var index = 0; index < 2000; index++) 'Text $index has a hause',
      ];
      for (final text in texts) {
        checker.misspellingsOf(text);
      }
      await _settle(backend);

      expect(backend.batches, 100);
      // Each announcement rebuilds the editor; it was one per batch.
      expect(announcements, lessThanOrEqualTo(10));
      for (final text in texts) {
        expect(checker.misspellingsOf(text), hasLength(1));
      }
    },
  );

  test('each batch is announced while a paragraph is being typed', () async {
    late final SpellChecker checker;
    var typed = 0;
    final backend = _Backend(
      onCheck: () {
        if (typed < 5) checker.misspellingsOf('My hause ${++typed}');
      },
    );
    checker = SpellChecker(backend);
    addTearDown(checker.dispose);
    var announcements = 0;
    checker.addListener(() => announcements++);
    checker.misspellingsOf('My hause');
    await _settle(backend);

    expect(backend.batches, 6);
    expect(announcements, 6);
    expect(checker.misspellingsOf('My hause 5'), hasLength(1));
  });

  test(
    'keeps every paragraph the editor shows, even beyond the cache',
    () async {
      final backend = _Backend();
      final checker = SpellChecker(backend);
      addTearDown(checker.dispose);
      final texts = [for (var index = 0; index < 5000; index++) 'Text $index'];
      void showAll() {
        for (final text in texts) {
          checker.misspellingsOf(text);
        }
      }

      // Like the editor, which asks for every paragraph after each rebuild.
      checker.addListener(showAll);
      showAll();
      await _settle(backend);

      // Dropping one would queue it again on the next rebuild.
      expect(backend.texts, 5000);
      for (final text in texts) {
        expect(checker.misspellingsOf(text), isEmpty);
      }
    },
  );

  test(
    'drops the oldest results nobody asks for once the cache is full',
    () async {
      final backend = _Backend();
      final checker = SpellChecker(backend);
      addTearDown(checker.dispose);
      final old = [for (var index = 0; index < 4000; index++) 'Old $index'];
      for (final text in old) {
        checker.misspellingsOf(text);
      }
      await _settle(backend);
      for (var index = 0; index < 400; index++) {
        checker.misspellingsOf('New $index');
      }
      await _settle(backend);

      // The 400 oldest go, not one per batch of 20.
      expect(checker.misspellingsOf(old[399]), isNull);
      expect(checker.misspellingsOf(old[400]), isEmpty);
    },
  );
}
