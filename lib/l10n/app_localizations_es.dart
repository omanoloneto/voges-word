// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get tabHome => 'Inicio';

  @override
  String get tabInsert => 'Insertar';

  @override
  String get tabLayout => 'Disposición';

  @override
  String get tabView => 'Vista';

  @override
  String get tabTable => 'Tabla';

  @override
  String get groupFont => 'Fuente';

  @override
  String get groupColor => 'Color';

  @override
  String get groupParagraph => 'Párrafo';

  @override
  String get groupStyles => 'Estilos';

  @override
  String get groupIllustrations => 'Ilustraciones';

  @override
  String get groupTables => 'Tablas';

  @override
  String get groupLinks => 'Vínculos';

  @override
  String get groupPages => 'Páginas';

  @override
  String get groupHeaderFooter => 'Encabezado y pie de página';

  @override
  String get groupPageSetup => 'Configurar página';

  @override
  String get groupViews => 'Vistas';

  @override
  String get groupZoom => 'Zoom';

  @override
  String get groupProofing => 'Revisión';

  @override
  String get groupRowsColumns => 'Filas y columnas';

  @override
  String get groupDelete => 'Eliminar';

  @override
  String get bold => 'Negrita';

  @override
  String get italic => 'Cursiva';

  @override
  String get underline => 'Subrayado';

  @override
  String get strikethrough => 'Tachado';

  @override
  String get superscript => 'Superíndice';

  @override
  String get subscript => 'Subíndice';

  @override
  String get clearFormatting => 'Borrar formato';

  @override
  String get decreaseFontSize => 'Reducir fuente';

  @override
  String get increaseFontSize => 'Aumentar fuente';

  @override
  String get fontColor => 'Color de fuente';

  @override
  String get automaticColor => 'Automático';

  @override
  String get highlightColor => 'Color de resaltado';

  @override
  String get noHighlight => 'Sin resaltado';

  @override
  String get moreColors => 'Más colores';

  @override
  String get alignLeft => 'Alinear a la izquierda';

  @override
  String get alignCenter => 'Centrar';

  @override
  String get alignRight => 'Alinear a la derecha';

  @override
  String get justify => 'Justificar';

  @override
  String get decreaseIndent => 'Disminuir sangría';

  @override
  String get increaseIndent => 'Aumentar sangría';

  @override
  String get bullets => 'Viñetas';

  @override
  String get numbering => 'Numeración';

  @override
  String get lineSpacing => 'Interlineado';

  @override
  String get pageBreak => 'Salto de página';

  @override
  String get pageBreakTooltip => 'Empieza una página nueva';

  @override
  String get picture => 'Imagen';

  @override
  String get insertPicture => 'Insertar imagen';

  @override
  String get table => 'Tabla';

  @override
  String tableSize(int rows, int columns) {
    return 'Tabla $rows × $columns';
  }

  @override
  String get link => 'Vínculo';

  @override
  String get insertLink => 'Insertar vínculo';

  @override
  String get headerFooter => 'Encabezado y pie';

  @override
  String get headerFooterTooltip =>
      'Editar el texto de arriba y de abajo de las páginas';

  @override
  String get pageNumber => 'Número de página';

  @override
  String get pageNumberTopRight => 'Arriba, a la derecha';

  @override
  String get pageNumberTopCenter => 'Arriba, centrado';

  @override
  String get pageNumberBottomRight => 'Abajo, a la derecha';

  @override
  String get pageNumberBottomCenter => 'Abajo, centrado';

  @override
  String get firstPageWithoutNumber => 'Primera página sin número';

  @override
  String get forCoverPage => 'Para portada';

  @override
  String get removePageNumbers => 'Quitar números';

  @override
  String get margins => 'Márgenes';

  @override
  String get marginsNormal => 'Normal';

  @override
  String get marginsAbnt => 'ABNT';

  @override
  String get marginsNarrow => 'Estrecho';

  @override
  String get marginsModerate => 'Moderado';

  @override
  String get marginsWide => 'Ancho';

  @override
  String marginsAllSides(String size) {
    return '$size cm en todos los lados';
  }

  @override
  String marginsTopBottomSides(String vertical, String horizontal) {
    return 'Superior e inferior $vertical cm · laterales $horizontal cm';
  }

  @override
  String marginsTopLeftBottomRight(String topLeft, String bottomRight) {
    return 'Superior e izquierdo $topLeft cm · inferior y derecho $bottomRight cm';
  }

  @override
  String marginsEachSide(String top, String bottom, String left, String right) {
    return 'Superior $top · inferior $bottom · izquierdo $left · derecho $right cm';
  }

  @override
  String get orientation => 'Orientación';

  @override
  String get portrait => 'Vertical';

  @override
  String get landscape => 'Horizontal';

  @override
  String get paperSize => 'Tamaño';

  @override
  String get paperLetter => 'Carta';

  @override
  String get paperLegal => 'Oficio';

  @override
  String get viewPages => 'Páginas';

  @override
  String get viewPagesTooltip =>
      'Muestra el documento en páginas, como se imprimirá';

  @override
  String get viewContinuous => 'Continuo';

  @override
  String get viewContinuousTooltip => 'Texto corrido, sin división en páginas';

  @override
  String get zoomOut => 'Alejar';

  @override
  String get zoomIn => 'Acercar';

  @override
  String get spelling => 'Ortografía';

  @override
  String get spellingTooltip => 'Subraya en rojo las palabras con errores';

  @override
  String get rowAbove => 'Arriba';

  @override
  String get insertRowAbove => 'Insertar fila arriba';

  @override
  String get rowBelow => 'Abajo';

  @override
  String get insertRowBelow => 'Insertar fila abajo';

  @override
  String get columnLeft => 'A la izquierda';

  @override
  String get insertColumnLeft => 'Insertar columna a la izquierda';

  @override
  String get columnRight => 'A la derecha';

  @override
  String get insertColumnRight => 'Insertar columna a la derecha';

  @override
  String get unavailableWithMergedCells =>
      'No disponible en tablas con celdas combinadas';

  @override
  String get row => 'Fila';

  @override
  String get column => 'Columna';

  @override
  String get styleNormal => 'Normal';

  @override
  String styleHeading(int level) {
    return 'Título $level';
  }

  @override
  String fontDownloadFailed(String family) {
    return 'No se pudo descargar la fuente “$family”. Revisa tu conexión a internet.';
  }

  @override
  String get colorBlack => 'Negro';

  @override
  String get colorDarkGray => 'Gris oscuro';

  @override
  String get colorLightGray => 'Gris claro';

  @override
  String get colorGray => 'Gris';

  @override
  String get colorDarkRed => 'Rojo oscuro';

  @override
  String get colorRed => 'Rojo';

  @override
  String get colorOrange => 'Naranja';

  @override
  String get colorGold => 'Dorado';

  @override
  String get colorYellow => 'Amarillo';

  @override
  String get colorBrightGreen => 'Verde brillante';

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
  String get colorDarkBlue => 'Azul oscuro';

  @override
  String get colorPurple => 'Morado';

  @override
  String get colorViolet => 'Violeta';

  @override
  String get colorPink => 'Rosa';

  @override
  String get saveChangesTitle => '¿Guardar los cambios?';

  @override
  String saveChangesMessage(String name) {
    return '¿Quieres guardar los cambios de “$name”?';
  }

  @override
  String get cancel => 'Cancelar';

  @override
  String get dontSave => 'No guardar';

  @override
  String get save => 'Guardar';

  @override
  String get recoverTitle => '¿Recuperar el documento?';

  @override
  String recoverMessage(String name, String date, String time) {
    return '“$name” se cerró sin guardar. Hay una copia del $date a las $time. ¿Quieres recuperarla?';
  }

  @override
  String get discard => 'Descartar';

  @override
  String get recover => 'Recuperar';

  @override
  String get shareAs => 'Compartir como';

  @override
  String get shareWordDocumentHint => 'Quien lo reciba puede editarlo';

  @override
  String get shareCurrentFormatHint => 'En el mismo formato que el archivo';

  @override
  String get sharePdf => 'PDF';

  @override
  String get sharePdfHint => 'Se ve igual en cualquier dispositivo';

  @override
  String get preparingPdf => 'Preparando el PDF…';

  @override
  String buildingPdfPage(int page, int total) {
    return 'Generando el PDF: página $page de $total';
  }

  @override
  String get editLink => 'Editar vínculo';

  @override
  String get linkText => 'Texto que se muestra';

  @override
  String get linkAddress => 'Dirección (sitio web o correo)';

  @override
  String get removeLink => 'Quitar vínculo';

  @override
  String get ok => 'Aceptar';

  @override
  String unsupportedImage(String format) {
    return 'Imagen $format: se ve en Word, pero no aquí. Se conserva al guardar.';
  }

  @override
  String get sectionBreak => 'Salto de sección';

  @override
  String get protectedContentTooltip =>
      'Contenido de Word que se conserva tal cual al guardar';

  @override
  String keptAsIs(String label) {
    return '$label · se conserva tal cual al guardar';
  }

  @override
  String get unsupportedPastedContent =>
      'Contenido pegado que Voges Word no guarda';

  @override
  String get contentSpecial => 'Contenido especial';

  @override
  String get contentTableOfContents => 'Tabla de contenido';

  @override
  String get contentCoverPage => 'Portada';

  @override
  String get contentBibliography => 'Bibliografía';

  @override
  String get contentNote => 'nota';

  @override
  String get contentChart => 'gráfico';

  @override
  String get contentDiagram => 'diagrama';

  @override
  String get contentTextBox => 'cuadro de texto';

  @override
  String get contentEquation => 'ecuación';

  @override
  String get contentObject => 'objeto';

  @override
  String get tableUnavailable => '[tabla no disponible]';

  @override
  String get startWriting => 'Empieza a escribir…';

  @override
  String get untitledDocument => 'Documento sin título';

  @override
  String get untitledFileName => 'Documento';

  @override
  String get openDocument => 'Abrir documento';

  @override
  String get saveAs => 'Guardar como';

  @override
  String get export => 'Exportar';

  @override
  String get problemLegacyDoc =>
      'Los archivos de Word 95 o anteriores no son compatibles. Ábrelo en Word y guárdalo como .docx.';

  @override
  String get problemUnsupportedFormat =>
      'Voges Word abre archivos .docx, .doc, .odt, .rtf, .html, .md y .txt.';

  @override
  String get problemNotWordDocument => 'El archivo no es un documento válido.';

  @override
  String get problemPasswordProtected =>
      'El archivo está protegido con contraseña. Quita la contraseña en el programa que lo creó e inténtalo de nuevo.';

  @override
  String get problemTooLarge => 'El archivo es demasiado grande para abrirlo.';

  @override
  String problemDamaged(String name) {
    return 'No se pudo abrir “$name”. Puede que el archivo esté dañado.';
  }

  @override
  String get noticeTrackedChangesAccepted =>
      'Se aceptaron los cambios controlados del documento.';

  @override
  String get noticeCommentsHidden =>
      'Los comentarios del documento no se muestran en Voges Word.';

  @override
  String get noticeContentNotImported =>
      'Algunas partes de este archivo no se muestran en Voges Word y se omiten al guardar.';

  @override
  String get noticeSavesAsDocx =>
      'Este es un archivo de Word 97–2003. Al guardar se crea una copia .docx y el original queda intacto.';

  @override
  String get recoverFailed => 'No se pudo recuperar el documento.';

  @override
  String get openFailed => 'No se pudo abrir el archivo.';

  @override
  String recentNotFound(String name) {
    return 'No se encontró “$name”. Puede que se haya movido o eliminado.';
  }

  @override
  String savedAs(String name) {
    return 'Guardado como $name';
  }

  @override
  String get saveFailed =>
      'No se pudo guardar. Comprueba si el archivo está abierto en otro programa.';

  @override
  String get pictureOpenFailed => 'No se pudo abrir la imagen.';

  @override
  String get pictureFormatUnknown =>
      'Formato de imagen no reconocido. Usa PNG, JPG, GIF o BMP.';

  @override
  String get pdfFailed => 'No se pudo generar el PDF.';

  @override
  String pdfSaved(String name) {
    return 'PDF guardado: $name';
  }

  @override
  String get pdfSaveFailed => 'No se pudo guardar el PDF.';

  @override
  String get printFailed => 'No se pudo abrir la impresión.';

  @override
  String get shareFailed => 'No se pudo compartir.';

  @override
  String replacedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count coincidencias reemplazadas',
      one: '1 coincidencia reemplazada',
    );
    return '$_temp0';
  }

  @override
  String get noResults => 'Sin resultados';

  @override
  String matchPosition(int current, int total) {
    return '$current de $total';
  }

  @override
  String get hideReplace => 'Ocultar reemplazo';

  @override
  String get replace => 'Reemplazar';

  @override
  String get find => 'Buscar';

  @override
  String get previous => 'Anterior';

  @override
  String get next => 'Siguiente';

  @override
  String get closeEsc => 'Cerrar (Esc)';

  @override
  String get replaceWith => 'Reemplazar con';

  @override
  String get replaceAll => 'Todas';

  @override
  String get otherPages => 'Demás páginas';

  @override
  String get firstPage => 'Primera página';

  @override
  String get header => 'Encabezado';

  @override
  String get footer => 'Pie de página';

  @override
  String get differentFirstPage => 'Primera página diferente';

  @override
  String get differentFirstPageHint =>
      'Para una portada: la primera página tiene su propio encabezado y pie de página, que pueden quedar vacíos.';

  @override
  String get apply => 'Aplicar';

  @override
  String get empty => 'Vacío';

  @override
  String get insertPageNumber => 'Insertar número de página';

  @override
  String get defaultFont => 'Predeterminada';

  @override
  String get fontsInDocument => 'En este documento';

  @override
  String get fontsOnComputer => 'En este equipo';

  @override
  String get fontsOnDevice => 'En este dispositivo';

  @override
  String get addFromGoogleFonts => 'Agregar de Google Fonts';

  @override
  String get searchFont => 'Buscar fuente';

  @override
  String get noFontsFound => 'No se encontraron fuentes';

  @override
  String get fontMissing => 'No instalada: se muestra con otra fuente';

  @override
  String get fontDownloadsOnUse => 'Se descarga de Google Fonts al usarla';

  @override
  String get addToList => 'Agregar a la lista';

  @override
  String get undo => 'Deshacer';

  @override
  String get redo => 'Rehacer';

  @override
  String get copy => 'Copiar';

  @override
  String get cut => 'Cortar';

  @override
  String get paste => 'Pegar';

  @override
  String get fileMenu => 'Archivo';

  @override
  String get unsavedChanges => 'Cambios sin guardar';

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
      other: '$countString palabras',
      one: '1 palabra',
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
      one: '1 carácter',
    );
    return '$_temp0';
  }

  @override
  String get plainTextWarning =>
      'Los archivos .txt guardan solo el texto. Usa “Guardar como” para conservar el formato.';

  @override
  String get plainText => 'Texto sin formato';

  @override
  String get markdownWarning =>
      'Los archivos .md guardan solo el formato básico. Usa “Guardar como” para conservar todo el formato.';

  @override
  String get markdown => 'Markdown';

  @override
  String get webPageWarning =>
      'Las páginas web no guardan la configuración de página, el encabezado ni el pie de página. Usa “Guardar como” para conservarlos.';

  @override
  String get webPage => 'Página web';

  @override
  String get word97Warning =>
      'Voges Word no escribe archivos de Word 97–2003: al guardar se crea una copia .docx y el original queda intacto.';

  @override
  String get word97 => 'Word 97–2003';

  @override
  String get wordMacrosWarning =>
      'Las macros se conservan al guardar, pero Voges Word nunca las ejecuta. “Guardar como” crea un .docx sin ellas.';

  @override
  String get wordMacros => 'Word con macros';

  @override
  String get openDocumentTextWarning =>
      'Los archivos .odt no guardan las ecuaciones, los gráficos ni otros contenidos de Word tal como están. Usa “Guardar como” para conservarlos.';

  @override
  String get openDocumentText => 'OpenDocument';

  @override
  String get richTextWarning =>
      'Los archivos .rtf no guardan las ecuaciones, los gráficos ni otros contenidos de Word tal como están. Usa “Guardar como” para conservarlos.';

  @override
  String get richText => 'RTF';

  @override
  String get minimize => 'Minimizar';

  @override
  String get maximize => 'Maximizar';

  @override
  String get restore => 'Restaurar';

  @override
  String get close => 'Cerrar';

  @override
  String ignoreWord(String word) {
    return 'Omitir “$word”';
  }

  @override
  String get templateBlank => 'En blanco';

  @override
  String get templateSingleSpaced => 'Espaciado sencillo';

  @override
  String get templateSchoolWork => 'Trabajo escolar (ABNT)';

  @override
  String get templateResume => 'Currículum';

  @override
  String get open => 'Abrir';

  @override
  String get otherFormats => 'Otros formatos';

  @override
  String get formatDocx => 'Documento de Word (.docx)';

  @override
  String get formatDocm => 'Documento de Word con macros (.docm)';

  @override
  String get formatDoc => 'Documento de Word 97–2003 (.doc)';

  @override
  String get formatOdt => 'Texto de OpenDocument (.odt)';

  @override
  String get formatRtf => 'Formato de texto enriquecido (.rtf)';

  @override
  String get formatHtml => 'Página web (.html)';

  @override
  String get formatMarkdown => 'Markdown (.md)';

  @override
  String get formatPlainText => 'Texto sin formato (.txt)';

  @override
  String get print => 'Imprimir';

  @override
  String get share => 'Compartir';

  @override
  String get newDocument => 'Documento nuevo';

  @override
  String get recentlyOpened => 'Abiertos recientemente';

  @override
  String get openAnother => 'Abrir otro…';

  @override
  String get language => 'Idioma';

  @override
  String get languageSystem => 'Igual que el sistema';

  @override
  String get resumeName => 'Tu Nombre Completo';

  @override
  String get resumeContact =>
      'Ciudad, País · (000) 000 000 · tucorreo@ejemplo.com';

  @override
  String get resumeObjective => 'Objetivo';

  @override
  String get resumeObjectiveText =>
      'Describe en una o dos frases el puesto o el área en que quieres trabajar.';

  @override
  String get resumeExperience => 'Experiencia';

  @override
  String get resumeRole => 'Puesto — Empresa';

  @override
  String get resumePeriod => 'Mes/Año – Mes/Año';

  @override
  String get resumeAchievement => 'Principal resultado o responsabilidad.';

  @override
  String get resumeOtherAchievement =>
      'Otro logro, de preferencia con números.';

  @override
  String get resumeEducation => 'Formación';

  @override
  String get resumeCourse => 'Carrera — Institución';

  @override
  String get resumeGraduation => 'Año de finalización';

  @override
  String get resumeSkills => 'Habilidades';

  @override
  String get resumeSkill => 'Habilidad técnica o herramienta';

  @override
  String get resumeLanguage => 'Idioma y nivel';
}
