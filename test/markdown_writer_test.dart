import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/document/document_codec.dart';
import 'package:voges_word/document/tables.dart';
import 'package:voges_word/docx/docx_codec.dart';
import 'package:voges_word/docx/docx_package.dart';
import 'package:voges_word/docx/docx_template.dart';
import 'package:voges_word/docx/word_xml.dart';
import 'package:voges_word/html/markdown_codec.dart';

/// A .docx whose body is [body] and whose numbering part holds
/// [numbering].
LoadedDocument _openWord(DocxCodec docx, String body, String numbering) =>
    docx.read(
      newDocumentPackage()
        ..setText(
          'word/document.xml',
          '<w:document xmlns:w="${Namespaces.w}"><w:body>$body<w:sectPr/>'
              '</w:body></w:document>',
        )
        ..addRelationships('word/document.xml', const [
          Relationship(
            id: 'rIdNumbering',
            type: RelationshipTypes.numbering,
            target: 'numbering.xml',
          ),
        ])
        ..setText(
          'word/numbering.xml',
          '<w:numbering xmlns:w="${Namespaces.w}">$numbering</w:numbering>',
        ),
    );

/// A paragraph of Word list [numId], or a plain one without it.
String _item(String text, [int? numId, int level = 0]) =>
    '<w:p>${numId == null ? '' : '<w:pPr><w:numPr><w:ilvl w:val="$level"/>'
              '<w:numId w:val="$numId"/></w:numPr></w:pPr>'}'
    '<w:r><w:t>$text</w:t></w:r></w:p>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('lists of one abstract list count together, as in Word', () {
    final docx = DocxCodec(TableStore());
    final loaded = _openWord(
      docx,
      [
        _item('A1', 1),
        _item('A2', 1),
        _item('Between'),
        _item('B1', 2),
        _item('B1 sub', 2, 1),
        _item('B2', 2),
        _item('R1', 3),
        _item('R2', 3),
        _item('R3', 3),
        _item('A3', 1),
      ].join(),
      '<w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start '
      'w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/>'
      '</w:lvl><w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt '
      'w:val="lowerLetter"/><w:lvlText w:val="%2)"/></w:lvl></w:abstractNum>'
      '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
      '<w:num w:numId="2"><w:abstractNumId w:val="0"/></w:num>'
      '<w:num w:numId="3"><w:abstractNumId w:val="0"/><w:lvlOverride '
      'w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride></w:num>',
    );
    final markdown = utf8.decode(
      MarkdownCodec(docx).encode(loaded.delta, source: loaded.source),
    );

    // B goes on from A; R restarts at its first item only, and A goes on
    // from R.
    expect(
      markdown,
      '1. A1\n2. A2\n\nBetween\n\n'
      '3. B1\n   1. B1 sub\n4. B2\n\n'
      '1) R1\n2) R2\n3) R3\n\n'
      '4. A3\n',
    );
  });

  test('items of one level stay side by side, however deep the list '
      'starts', () {
    String level(int level) =>
        '<w:lvl w:ilvl="$level"><w:start w:val="1"/><w:numFmt '
        'w:val="decimal"/><w:lvlText w:val="%${level + 1}."/></w:lvl>';
    final docx = DocxCodec(TableStore());
    final loaded = _openWord(
      docx,
      [
        _item('first', 1, 2),
        _item('second', 1, 2),
        _item('third', 1, 2),
        _item('deeper', 1, 3),
        _item('fourth', 1, 2),
        _item('top', 1),
        _item('Between'),
        _item('again', 1, 1),
        _item('more', 1, 1),
      ].join(),
      '<w:abstractNum w:abstractNumId="0">'
      '${level(0)}${level(1)}${level(2)}${level(3)}</w:abstractNum>'
      '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>',
    );
    final markdown = utf8.decode(
      MarkdownCodec(docx).encode(loaded.delta, source: loaded.source),
    );

    // Word counted the first level once at the list's start, so the item
    // there is 2, a list of its own.
    expect(
      markdown,
      '1. first\n2. second\n3. third\n   1. deeper\n4. fourth\n\n'
      '2) top\n\nBetween\n\n1. again\n2. more\n',
    );
  });

  test('lists in tables count on with the text around them, as in Word', () {
    final docx = DocxCodec(TableStore());
    final loaded = _openWord(
      docx,
      '${_item('First', 1)}${_item('Second', 1)}'
          '<w:tbl><w:tblGrid><w:gridCol w:w="4000"/></w:tblGrid><w:tr><w:tc>'
          '${_item('Third', 2)}${_item('Fourth', 2)}</w:tc></w:tr></w:tbl>'
          '${_item('Fifth', 1)}',
      '<w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start '
          'w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/>'
          '</w:lvl></w:abstractNum>'
          '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
          '<w:num w:numId="2"><w:abstractNumId w:val="0"/></w:num>',
    );
    final markdown = utf8.decode(
      MarkdownCodec(docx).encode(loaded.delta, source: loaded.source),
    );

    expect(markdown, startsWith('1. First\n2. Second\n\n<table'));
    expect(markdown, contains('<ol start="3"><li>Third</li>'));
    expect(markdown, endsWith('</table>\n\n5. Fifth\n'));
  });
}
