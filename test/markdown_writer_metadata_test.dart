import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/html/markdown_codec.dart';

/// [markdown] opened and saved again as Markdown.
String _saveAgain(String markdown) {
  final codec = MarkdownCodec(DocxCodec(TableStore()));
  final loaded = codec.decode(Uint8List.fromList(utf8.encode(markdown)));
  return utf8.decode(codec.encode(loaded.delta, source: loaded.source));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('front matter is written back as it was', () {
    for (final (keys, markdown) in [
      (
        'a key that starts with an accented letter',
        '---\ntitle: Olá\nárea: Norte\n---\n\nTexto.\n',
      ),
      ('Chinese keys', '---\n标题: 你好\n---\n\n正文。\n'),
      (
        'a key that starts with an accented capital',
        '---\nÉtat: brouillon\n---\n\nTexte.\n',
      ),
      ('an accent after the first letter', '---\ntítulo: Olá\n---\n\nTexto.\n'),
      ('a key of full-width digits', '---\n２０２６: ano\n---\n\nTexto.\n'),
      (
        'a TOML key that starts with an accented letter',
        '+++\nÁrea = "Norte"\n+++\n\nTexto.\n',
      ),
    ]) {
      test('with $keys', () => expect(_saveAgain(markdown), markdown));
    }
  });

  test('lines that are no keys still go in a fence', () {
    for (final lines in [
      ['---', 'Olá mundo', '---'],
      ['---', 'área: <img src=x onerror=alert(1)>', '---'],
    ]) {
      expect(
        _saveAgain('${lines.join('\n')}\n\nTexto.\n'),
        '```\n${lines.join('\n')}\n```\n\nTexto.\n',
        reason: lines[1],
      );
    }
  });
}
