// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_quill/src/controller/clipboard/paste_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voges_word/editor/paste_sanitizer.dart';

/// What pasting [html] into an empty document leaves there, as the editor
/// pastes from other apps.
Document _pasted(String html) => Document.fromDelta(Delta()..insert('\n'))
  ..compose(sanitizePastedDelta(pastedHtmlToDelta(html)), ChangeSource.local);

void main() {
  test('an answer copied from a chat keeps its paragraphs', () {
    const html = '''
<meta charset='utf-8'><h1 data-start="0" data-end="40">GABARITO COMENTADO</h1>
<h2 data-start="42" data-end="70">Questão 1 — Alternativa E</h2>
<p data-start="72" data-end="99"><strong data-start="72" data-end="97">Resposta: {1, 4, 5, 9}.</strong></p>
<p data-start="101" data-end="122">Temos duas equações.</p>
<p data-start="124" data-end="133">Primeira:</p>
<p data-start="135" data-end="150">x² − 6x + 5 = 0</p>
<hr data-start="300" data-end="303">
<ol data-start="400" data-end="500">
<li data-start="400" data-end="450">
<p data-start="403" data-end="450">A partida termina empatada.</p>
</li>
<li data-start="451" data-end="500">
<p data-start="454" data-end="500">A partida tem um vencedor.</p>
</li>
</ol>
<p data-start="502" data-end="540"><strong data-start="502" data-end="512">MACETE:</strong> OU significa união.</p>''';

    final document = _pasted(html);

    expect(
      document.toPlainText(),
      'GABARITO COMENTADO\n'
      'Questão 1 — Alternativa E\n'
      'Resposta: {1, 4, 5, 9}.\n'
      'Temos duas equações.\n'
      'Primeira:\n'
      'x² − 6x + 5 = 0\n'
      // The rule between parts.
      '\n'
      'A partida termina empatada.\n'
      'A partida tem um vencedor.\n'
      'MACETE: OU significa união.\n'
      '\n',
    );
    final lines = document.toDelta().toList();
    expect(
      lines.where((op) => op.attributes?['list'] == 'ordered'),
      hasLength(2),
      reason: 'each list item is one line',
    );
    expect(
      lines.firstWhere((op) => op.data == 'Resposta: {1, 4, 5, 9}.').attributes,
      {'bold': true},
    );
  });

  test('an aligned paragraph ends once', () {
    expect(
      _pasted(
        '<p style="text-align: center">Title</p><p>Body</p>',
      ).toPlainText(),
      'Title\nBody\n\n',
    );
  });

  test('a paragraph that ends with a line break ends once', () {
    expect(_pasted('<p>One<br></p><p>Two</p>').toPlainText(), 'One\nTwo\n\n');
  });

  test('a heading or a list at the end leaves no empty line', () {
    // The empty paragraph is the one the document had.
    expect(_pasted('<p>One</p><h2>Two</h2>').toPlainText(), 'One\nTwo\n\n');
    expect(_pasted('<ul><li>One</li></ul>').toPlainText(), 'One\n\n');
  });

  test('an empty paragraph at the end stays', () {
    expect(_pasted('<p>One</p><p></p>').toPlainText(), 'One\n\n\n');
  });

  test('paragraphs in a block are ended by it', () {
    expect(
      _pasted('<div><p>One</p><p>Two</p></div>').toPlainText(),
      'One\nTwo\n\n',
    );
  });

  test('code keeps its lines and its indentation', () {
    expect(
      _pasted(
        '<p>Code:</p><pre><code>if (a) {\n  b();\n}</code></pre>',
      ).toPlainText(),
      contains('if (a) {\n  b();\n}'),
    );
  });
}
