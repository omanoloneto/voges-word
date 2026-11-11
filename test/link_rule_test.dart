// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'dart:convert';
import 'dart:math';

import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_quill/src/rules/insert.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rule as Quill 11.5.0 wrote it, reading the words around the insertion
/// from the whole text of the document.
Delta? _quillRule(Document document, int index, String data) {
  final entireText = document.toPlainText();
  final leftWordPart = entireText
      .substring(0, index)
      .split('\n')
      .last
      .split(' ')
      .last
      .trimLeft();
  final rightWordPart = entireText
      .substring(index)
      .split('\n')
      .first
      .split(' ')
      .first
      .trimRight();
  final affectedWords = '$leftWordPart$data$rightWordPart';
  final matches = AutoFormatMultipleLinksRule.urlInTextRegExp.allMatches(
    affectedWords,
  );
  if (matches.isEmpty) return null;
  final baseDelta = Delta()
    ..retain(index)
    ..insert(data);
  final unmodifiedLength = index - leftWordPart.length;
  final formatterDelta = Delta()..retain(unmodifiedLength);
  var previousLinkEndRelativeIndex = 0;
  for (final match in matches) {
    final separationLength = match.start - previousLinkEndRelativeIndex;
    final link = affectedWords.substring(match.start, match.end);
    formatterDelta
      ..retain(separationLength, Attribute.link.toJson())
      ..retain(link.length, LinkAttribute(link).toJson());
    previousLinkEndRelativeIndex = match.end;
  }
  final remainingLength = affectedWords.length - previousLinkEndRelativeIndex;
  formatterDelta.retain(remainingLength, Attribute.link.toJson());
  return baseDelta.compose(formatterDelta);
}

const _words = [
  'word',
  'https://example.com/a?b=c',
  'http://x.org',
  'www',
  '',
  'a.com',
  'https://',
  '\t',
  'text.',
];

const _inserted = [
  'x',
  ' ',
  'https://',
  'example.com',
  'word ',
  '\n',
  'two\nlines',
  'https://a.io b',
];

/// A document of short paragraphs of [_words], some with links, pictures and
/// block styles.
Delta _document(Random random) {
  final delta = Delta();
  final paragraphs = 1 + random.nextInt(8);
  for (var paragraph = 0; paragraph < paragraphs; paragraph++) {
    final words = random.nextInt(6);
    for (var word = 0; word < words; word++) {
      if (random.nextInt(8) == 0) {
        delta.insert({'image': 'a.png'});
      }
      final text = _words[random.nextInt(_words.length)];
      if (text.isEmpty) continue;
      delta.insert(
        word == words - 1 ? text : '$text ',
        random.nextInt(4) == 0 ? {'link': 'https://old.example'} : null,
      );
    }
    delta.insert('\n', switch (random.nextInt(4)) {
      0 => {'list': 'bullet'},
      1 => {'align': 'justify'},
      _ => null,
    });
  }
  return delta;
}

void main() {
  test('formats links as Quill did, reading only the paragraph', () {
    const rule = AutoFormatMultipleLinksRule();
    var formatted = 0;
    for (var seed = 0; seed < 3000; seed++) {
      final random = Random(seed);
      final document = Document.fromDelta(_document(random));
      final index = random.nextInt(document.length);
      final data = _inserted[random.nextInt(_inserted.length)];

      final expected = _quillRule(document, index, data);
      final actual = rule.applyRule(document, index, data: data);

      expect(
        jsonEncode(actual?.toJson()),
        jsonEncode(expected?.toJson()),
        reason:
            'seed $seed: "$data" at $index of '
            '${jsonEncode(document.toDelta().toJson())}',
      );
      if (expected != null) formatted++;
    }
    expect(formatted, greaterThan(300), reason: 'links were made');
  });
}
