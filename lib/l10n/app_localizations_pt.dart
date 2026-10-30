// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get tabHome => 'Início';

  @override
  String get tabInsert => 'Inserir';

  @override
  String get tabLayout => 'Layout';

  @override
  String get tabView => 'Exibir';

  @override
  String get tabTable => 'Tabela';

  @override
  String get groupFont => 'Fonte';

  @override
  String get groupColor => 'Cor';

  @override
  String get groupParagraph => 'Parágrafo';

  @override
  String get groupStyles => 'Estilos';

  @override
  String get groupIllustrations => 'Ilustrações';

  @override
  String get groupTables => 'Tabelas';

  @override
  String get groupLinks => 'Links';

  @override
  String get groupPages => 'Páginas';

  @override
  String get groupHeaderFooter => 'Cabeçalho e rodapé';

  @override
  String get groupPageSetup => 'Configurar página';

  @override
  String get groupViews => 'Modo de exibição';

  @override
  String get groupZoom => 'Zoom';

  @override
  String get groupProofing => 'Revisão';

  @override
  String get groupRowsColumns => 'Linhas e colunas';

  @override
  String get groupDelete => 'Excluir';

  @override
  String get bold => 'Negrito';

  @override
  String get italic => 'Itálico';

  @override
  String get underline => 'Sublinhado';

  @override
  String get strikethrough => 'Tachado';

  @override
  String get superscript => 'Sobrescrito';

  @override
  String get subscript => 'Subscrito';

  @override
  String get clearFormatting => 'Limpar formatação';

  @override
  String get decreaseFontSize => 'Diminuir fonte';

  @override
  String get increaseFontSize => 'Aumentar fonte';

  @override
  String get fontColor => 'Cor da fonte';

  @override
  String get automaticColor => 'Automática';

  @override
  String get highlightColor => 'Cor de realce';

  @override
  String get noHighlight => 'Sem realce';

  @override
  String get moreColors => 'Mais cores';

  @override
  String get alignLeft => 'Alinhar à esquerda';

  @override
  String get alignCenter => 'Centralizar';

  @override
  String get alignRight => 'Alinhar à direita';

  @override
  String get justify => 'Justificar';

  @override
  String get decreaseIndent => 'Diminuir recuo';

  @override
  String get increaseIndent => 'Aumentar recuo';

  @override
  String get bullets => 'Marcadores';

  @override
  String get numbering => 'Numeração';

  @override
  String get lineSpacing => 'Espaçamento entre linhas';

  @override
  String get pageBreak => 'Quebra de página';

  @override
  String get pageBreakTooltip => 'Começa uma página nova';

  @override
  String get picture => 'Imagem';

  @override
  String get insertPicture => 'Inserir imagem';

  @override
  String get table => 'Tabela';

  @override
  String tableSize(int rows, int columns) {
    return 'Tabela $rows × $columns';
  }

  @override
  String get link => 'Link';

  @override
  String get insertLink => 'Inserir link';

  @override
  String get headerFooter => 'Cabeçalho e rodapé';

  @override
  String get headerFooterTooltip =>
      'Editar o texto do topo e da base das páginas';

  @override
  String get pageNumber => 'Número de página';

  @override
  String get pageNumberTopRight => 'No topo, à direita';

  @override
  String get pageNumberTopCenter => 'No topo, centralizado';

  @override
  String get pageNumberBottomRight => 'No rodapé, à direita';

  @override
  String get pageNumberBottomCenter => 'No rodapé, centralizado';

  @override
  String get firstPageWithoutNumber => 'Primeira página sem número';

  @override
  String get forCoverPage => 'Para capa';

  @override
  String get removePageNumbers => 'Remover números';

  @override
  String get margins => 'Margens';

  @override
  String get marginsNormal => 'Normal';

  @override
  String get marginsAbnt => 'ABNT';

  @override
  String get marginsNarrow => 'Estreita';

  @override
  String get marginsModerate => 'Moderada';

  @override
  String get marginsWide => 'Larga';

  @override
  String marginsAllSides(String size) {
    return '$size cm em todos os lados';
  }

  @override
  String marginsTopBottomSides(String vertical, String horizontal) {
    return 'Superior e inferior $vertical cm · laterais $horizontal cm';
  }

  @override
  String marginsTopLeftBottomRight(String topLeft, String bottomRight) {
    return 'Superior e esquerda $topLeft cm · inferior e direita $bottomRight cm';
  }

  @override
  String marginsEachSide(String top, String bottom, String left, String right) {
    return 'Superior $top · inferior $bottom · esquerda $left · direita $right cm';
  }

  @override
  String get orientation => 'Orientação';

  @override
  String get portrait => 'Retrato';

  @override
  String get landscape => 'Paisagem';

  @override
  String get paperSize => 'Tamanho';

  @override
  String get paperLetter => 'Carta';

  @override
  String get paperLegal => 'Ofício';

  @override
  String get viewPages => 'Páginas';

  @override
  String get viewPagesTooltip =>
      'Mostra o documento em páginas, como vai imprimir';

  @override
  String get viewContinuous => 'Contínuo';

  @override
  String get viewContinuousTooltip => 'Texto corrido, sem divisão de páginas';

  @override
  String get zoomOut => 'Diminuir zoom';

  @override
  String get zoomIn => 'Aumentar zoom';

  @override
  String get spelling => 'Ortografia';

  @override
  String get spellingTooltip => 'Sublinha em vermelho as palavras com erro';

  @override
  String get rowAbove => 'Acima';

  @override
  String get insertRowAbove => 'Inserir linha acima';

  @override
  String get rowBelow => 'Abaixo';

  @override
  String get insertRowBelow => 'Inserir linha abaixo';

  @override
  String get columnLeft => 'À esquerda';

  @override
  String get insertColumnLeft => 'Inserir coluna à esquerda';

  @override
  String get columnRight => 'À direita';

  @override
  String get insertColumnRight => 'Inserir coluna à direita';

  @override
  String get unavailableWithMergedCells =>
      'Indisponível em tabela com células mescladas';

  @override
  String get row => 'Linha';

  @override
  String get column => 'Coluna';

  @override
  String get styleNormal => 'Normal';

  @override
  String styleHeading(int level) {
    return 'Título $level';
  }

  @override
  String fontDownloadFailed(String family) {
    return 'Não foi possível baixar a fonte “$family”. Verifique a internet.';
  }

  @override
  String get colorBlack => 'Preto';

  @override
  String get colorDarkGray => 'Cinza escuro';

  @override
  String get colorLightGray => 'Cinza claro';

  @override
  String get colorGray => 'Cinza';

  @override
  String get colorDarkRed => 'Vermelho escuro';

  @override
  String get colorRed => 'Vermelho';

  @override
  String get colorOrange => 'Laranja';

  @override
  String get colorGold => 'Dourado';

  @override
  String get colorYellow => 'Amarelo';

  @override
  String get colorBrightGreen => 'Verde-limão';

  @override
  String get colorGreen => 'Verde';

  @override
  String get colorOlive => 'Oliva';

  @override
  String get colorTurquoise => 'Turquesa';

  @override
  String get colorLightBlue => 'Azul claro';

  @override
  String get colorBlue => 'Azul';

  @override
  String get colorDarkBlue => 'Azul escuro';

  @override
  String get colorPurple => 'Roxo';

  @override
  String get colorViolet => 'Violeta';

  @override
  String get colorPink => 'Rosa';

  @override
  String get saveChangesTitle => 'Salvar alterações?';

  @override
  String saveChangesMessage(String name) {
    return 'Deseja salvar as alterações em “$name”?';
  }

  @override
  String get cancel => 'Cancelar';

  @override
  String get dontSave => 'Não salvar';

  @override
  String get save => 'Salvar';

  @override
  String get recoverTitle => 'Recuperar documento?';

  @override
  String recoverMessage(String name, String date, String time) {
    return '“$name” foi fechado sem salvar. Há uma cópia de $date às $time. Deseja recuperá-la?';
  }

  @override
  String get discard => 'Descartar';

  @override
  String get recover => 'Recuperar';

  @override
  String get shareAs => 'Compartilhar como';

  @override
  String get shareWordDocumentHint => 'Quem receber pode editar';

  @override
  String get shareCurrentFormatHint => 'No mesmo formato do arquivo';

  @override
  String get sharePdf => 'PDF';

  @override
  String get sharePdfHint => 'Fica igual em qualquer aparelho';

  @override
  String get preparingPdf => 'Preparando o PDF…';

  @override
  String buildingPdfPage(int page, int total) {
    return 'Montando o PDF: página $page de $total';
  }

  @override
  String get editLink => 'Editar link';

  @override
  String get linkText => 'Texto exibido';

  @override
  String get linkAddress => 'Endereço (site ou e-mail)';

  @override
  String get removeLink => 'Remover link';

  @override
  String get ok => 'OK';

  @override
  String unsupportedImage(String format) {
    return 'Imagem $format: aparece no Word, mas não aqui. É mantida ao salvar.';
  }

  @override
  String get sectionBreak => 'Quebra de seção';

  @override
  String get protectedContentTooltip =>
      'Conteúdo do Word mantido como está ao salvar';

  @override
  String keptAsIs(String label) {
    return '$label · mantido como está ao salvar';
  }

  @override
  String get unsupportedPastedContent =>
      'Conteúdo colado que o Voges Word não salva';

  @override
  String get contentSpecial => 'Conteúdo especial';

  @override
  String get contentTableOfContents => 'Sumário';

  @override
  String get contentCoverPage => 'Capa';

  @override
  String get contentBibliography => 'Bibliografia';

  @override
  String get contentNote => 'nota';

  @override
  String get contentChart => 'gráfico';

  @override
  String get contentDiagram => 'diagrama';

  @override
  String get contentTextBox => 'caixa de texto';

  @override
  String get contentEquation => 'equação';

  @override
  String get contentObject => 'objeto';

  @override
  String get tableUnavailable => '[tabela indisponível]';

  @override
  String get startWriting => 'Comece a escrever…';

  @override
  String get untitledDocument => 'Documento sem título';

  @override
  String get untitledFileName => 'Documento';

  @override
  String get openDocument => 'Abrir documento';

  @override
  String get saveAs => 'Salvar como';

  @override
  String get export => 'Exportar';

  @override
  String get problemLegacyDoc =>
      'Arquivos do Word 95 ou anteriores não são suportados. Abra no Word e salve como .docx.';

  @override
  String get problemUnsupportedFormat =>
      'O Voges Word abre arquivos .docx, .doc, .odt, .rtf, .html, .md e .txt.';

  @override
  String get problemNotWordDocument => 'O arquivo não é um documento válido.';

  @override
  String get problemPasswordProtected =>
      'O arquivo está protegido por senha. Tire a senha no programa que o criou e tente de novo.';

  @override
  String get problemTooLarge => 'O arquivo é grande demais para abrir.';

  @override
  String problemDamaged(String name) {
    return 'Não foi possível abrir “$name”. O arquivo pode estar danificado.';
  }

  @override
  String get noticeTrackedChangesAccepted =>
      'As alterações controladas do documento foram aceitas.';

  @override
  String get noticeCommentsHidden =>
      'Os comentários do documento não aparecem no Voges Word.';

  @override
  String get noticeContentNotImported =>
      'Algumas partes deste arquivo não aparecem no Voges Word e ficam de fora ao salvar.';

  @override
  String get noticeSavesAsDocx =>
      'Este é um arquivo do Word 97–2003. Ao salvar, é criada uma cópia .docx e o original fica intacto.';

  @override
  String get recoverFailed => 'Não foi possível recuperar o documento.';

  @override
  String get openFailed => 'Não foi possível abrir o arquivo.';

  @override
  String recentNotFound(String name) {
    return '“$name” não foi encontrado. Ele pode ter sido movido ou apagado.';
  }

  @override
  String savedAs(String name) {
    return 'Salvo como $name';
  }

  @override
  String get saveFailed =>
      'Não foi possível salvar. Verifique se o arquivo está aberto em outro programa.';

  @override
  String get pictureOpenFailed => 'Não foi possível abrir a imagem.';

  @override
  String get pictureFormatUnknown =>
      'Formato de imagem não reconhecido. Use PNG, JPG, GIF ou BMP.';

  @override
  String get pdfFailed => 'Não foi possível montar o PDF.';

  @override
  String pdfSaved(String name) {
    return 'PDF salvo: $name';
  }

  @override
  String get pdfSaveFailed => 'Não foi possível salvar o PDF.';

  @override
  String get printFailed => 'Não foi possível abrir a impressão.';

  @override
  String get shareFailed => 'Não foi possível compartilhar.';

  @override
  String replacedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ocorrências substituídas',
      one: '1 ocorrência substituída',
    );
    return '$_temp0';
  }

  @override
  String get noResults => 'Nenhum resultado';

  @override
  String matchPosition(int current, int total) {
    return '$current de $total';
  }

  @override
  String get hideReplace => 'Ocultar substituição';

  @override
  String get replace => 'Substituir';

  @override
  String get find => 'Localizar';

  @override
  String get previous => 'Anterior';

  @override
  String get next => 'Próximo';

  @override
  String get closeEsc => 'Fechar (Esc)';

  @override
  String get replaceWith => 'Substituir por';

  @override
  String get replaceAll => 'Todas';

  @override
  String get otherPages => 'Demais páginas';

  @override
  String get firstPage => 'Primeira página';

  @override
  String get header => 'Cabeçalho';

  @override
  String get footer => 'Rodapé';

  @override
  String get differentFirstPage => 'Primeira página diferente';

  @override
  String get differentFirstPageHint =>
      'Para capa: a primeira página fica com cabeçalho e rodapé próprios, que podem ficar vazios.';

  @override
  String get apply => 'Aplicar';

  @override
  String get empty => 'Vazio';

  @override
  String get insertPageNumber => 'Inserir número da página';

  @override
  String get defaultFont => 'Padrão';

  @override
  String get fontsInDocument => 'Neste documento';

  @override
  String get fontsOnComputer => 'No computador';

  @override
  String get fontsOnDevice => 'No aparelho';

  @override
  String get addFromGoogleFonts => 'Adicionar do Google Fonts';

  @override
  String get searchFont => 'Buscar fonte';

  @override
  String get noFontsFound => 'Nenhuma fonte encontrada';

  @override
  String get fontMissing => 'Não instalada: aparece com outra fonte';

  @override
  String get fontDownloadsOnUse => 'Baixa do Google Fonts ao usar';

  @override
  String get addToList => 'Adicionar à lista';

  @override
  String get undo => 'Desfazer';

  @override
  String get redo => 'Refazer';

  @override
  String get copy => 'Copiar';

  @override
  String get cut => 'Recortar';

  @override
  String get paste => 'Colar';

  @override
  String get fileMenu => 'Arquivo';

  @override
  String get unsavedChanges => 'Alterações não salvas';

  @override
  String pageOf(int current, int total) {
    return 'Página $current de $total';
  }

  @override
  String wordCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString palavras',
      one: '1 palavra',
    );
    return '$_temp0';
  }

  @override
  String characterCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString caracteres',
      one: '1 caractere',
    );
    return '$_temp0';
  }

  @override
  String get plainTextWarning =>
      'Arquivos .txt guardam só o texto. Use “Salvar como” para manter a formatação.';

  @override
  String get plainText => 'Texto simples';

  @override
  String get markdownWarning =>
      'Arquivos .md guardam só a formatação básica. Use “Salvar como” para manter toda a formatação.';

  @override
  String get markdown => 'Markdown';

  @override
  String get webPageWarning =>
      'Páginas da web não guardam a configuração da página, o cabeçalho nem o rodapé. Use “Salvar como” para mantê-los.';

  @override
  String get webPage => 'Página da web';

  @override
  String get word97Warning =>
      'O Voges Word não grava arquivos do Word 97–2003: ao salvar, é criada uma cópia .docx e o original fica intacto.';

  @override
  String get word97 => 'Word 97–2003';

  @override
  String get wordMacrosWarning =>
      'As macros são mantidas ao salvar, mas o Voges Word nunca as executa. “Salvar como” cria um .docx sem elas.';

  @override
  String get wordMacros => 'Word com macros';

  @override
  String get minimize => 'Minimizar';

  @override
  String get maximize => 'Maximizar';

  @override
  String get restore => 'Restaurar';

  @override
  String get close => 'Fechar';

  @override
  String ignoreWord(String word) {
    return 'Ignorar “$word”';
  }

  @override
  String get templateBlank => 'Em branco';

  @override
  String get templateSingleSpaced => 'Espaçamento simples';

  @override
  String get templateSchoolWork => 'Trabalho escolar';

  @override
  String get templateResume => 'Currículo';

  @override
  String get open => 'Abrir';

  @override
  String get otherFormats => 'Outros formatos';

  @override
  String get formatDocx => 'Documento do Word (.docx)';

  @override
  String get formatDocm => 'Documento do Word com macros (.docm)';

  @override
  String get formatDoc => 'Documento do Word 97–2003 (.doc)';

  @override
  String get formatOdt => 'Texto OpenDocument (.odt)';

  @override
  String get formatRtf => 'Formato Rich Text (.rtf)';

  @override
  String get formatHtml => 'Página da web (.html)';

  @override
  String get formatMarkdown => 'Markdown (.md)';

  @override
  String get formatPlainText => 'Texto simples (.txt)';

  @override
  String get print => 'Imprimir';

  @override
  String get share => 'Compartilhar';

  @override
  String get newDocument => 'Novo documento';

  @override
  String get recentlyOpened => 'Abertos recentemente';

  @override
  String get openAnother => 'Abrir outro…';

  @override
  String get language => 'Idioma';

  @override
  String get languageSystem => 'Igual ao sistema';

  @override
  String get resumeName => 'Seu Nome Completo';

  @override
  String get resumeContact =>
      'Cidade (UF) · (00) 00000-0000 · seuemail@exemplo.com';

  @override
  String get resumeObjective => 'Objetivo';

  @override
  String get resumeObjectiveText =>
      'Descreva em uma ou duas frases a vaga ou a área em que você quer atuar.';

  @override
  String get resumeExperience => 'Experiência';

  @override
  String get resumeRole => 'Cargo — Empresa';

  @override
  String get resumePeriod => 'Mês/Ano – Mês/Ano';

  @override
  String get resumeAchievement => 'Principal resultado ou responsabilidade.';

  @override
  String get resumeOtherAchievement =>
      'Outra conquista, de preferência com números.';

  @override
  String get resumeEducation => 'Formação';

  @override
  String get resumeCourse => 'Curso — Instituição';

  @override
  String get resumeGraduation => 'Ano de conclusão';

  @override
  String get resumeSkills => 'Habilidades';

  @override
  String get resumeSkill => 'Habilidade técnica ou ferramenta';

  @override
  String get resumeLanguage => 'Idioma e nível';
}
