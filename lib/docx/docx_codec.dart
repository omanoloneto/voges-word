import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';

import '../document/document_codec.dart';
import '../document/document_look.dart';
import '../document/headers_footers.dart';
import '../document/tables.dart';
import 'docx_package.dart';
import 'docx_reader.dart';
import 'docx_template.dart';
import 'docx_writer.dart';

class DocxCodec implements DocumentCodec {
  DocxCodec(this.tables);

  final TableStore tables;

  @override
  DocumentFormat get format => DocumentFormat.docx;

  @override
  LoadedDocument decode(Uint8List bytes) =>
      DocxReader(DocxPackage.decode(bytes), tables).read();

  LoadedDocument createEmpty() => create(DocumentTemplate.blank);

  LoadedDocument create(DocumentTemplate template) {
    final package = newDocumentPackage(TemplateOptions.of(template));
    if (template != DocumentTemplate.resume) {
      return DocxReader(package, tables).read();
    }
    return decode(encode(_resume(), source: package));
  }

  static Delta _resume() {
    const gray = '#595959';
    return Delta()
      ..insert('Seu Nome Completo', {'bold': true, 'size': '24'})
      ..insert('\n', {'align': 'center'})
      ..insert('Cidade (UF) · (00) 00000-0000 · seuemail@exemplo.com', {
        'color': gray,
      })
      ..insert('\n', {'align': 'center'})
      ..insert('Objetivo')
      ..insert('\n', {'header': 2})
      ..insert(
        'Descreva em uma ou duas frases a vaga ou a área em que você quer atuar.\n',
      )
      ..insert('Experiência')
      ..insert('\n', {'header': 2})
      ..insert('Cargo — Empresa', {'bold': true})
      ..insert('\n')
      ..insert('Mês/Ano – Mês/Ano', {'italic': true, 'color': gray})
      ..insert('\n')
      ..insert('Principal resultado ou responsabilidade.')
      ..insert('\n', {'list': 'bullet'})
      ..insert('Outra conquista, de preferência com números.')
      ..insert('\n', {'list': 'bullet'})
      ..insert('Formação')
      ..insert('\n', {'header': 2})
      ..insert('Curso — Instituição', {'bold': true})
      ..insert('\n')
      ..insert('Ano de conclusão', {'italic': true, 'color': gray})
      ..insert('\n')
      ..insert('Habilidades')
      ..insert('\n', {'header': 2})
      ..insert('Habilidade técnica ou ferramenta')
      ..insert('\n', {'list': 'bullet'})
      ..insert('Idioma e nível')
      ..insert('\n', {'list': 'bullet'});
  }

  @override
  Uint8List encode(
    Delta delta, {
    Object? source,
    DocumentLook? pageSetup,
    HeadersFooters? headersFooters,
  }) => DocxWriter(tables).write(
    delta,
    source is DocxPackage ? source : newDocumentPackage(),
    pageSetup: pageSetup,
    headersFooters: headersFooters,
  );
}
