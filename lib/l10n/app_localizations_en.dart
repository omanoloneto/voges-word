// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get tabHome => 'Home';

  @override
  String get tabInsert => 'Insert';

  @override
  String get tabLayout => 'Layout';

  @override
  String get tabView => 'View';

  @override
  String get tabTable => 'Table';

  @override
  String get groupFont => 'Font';

  @override
  String get groupColor => 'Color';

  @override
  String get groupParagraph => 'Paragraph';

  @override
  String get groupStyles => 'Styles';

  @override
  String get groupIllustrations => 'Illustrations';

  @override
  String get groupTables => 'Tables';

  @override
  String get groupLinks => 'Links';

  @override
  String get groupPages => 'Pages';

  @override
  String get groupHeaderFooter => 'Header & Footer';

  @override
  String get groupPageSetup => 'Page Setup';

  @override
  String get groupViews => 'Views';

  @override
  String get groupZoom => 'Zoom';

  @override
  String get groupProofing => 'Proofing';

  @override
  String get groupRowsColumns => 'Rows & Columns';

  @override
  String get groupDelete => 'Delete';

  @override
  String get bold => 'Bold';

  @override
  String get italic => 'Italic';

  @override
  String get underline => 'Underline';

  @override
  String get strikethrough => 'Strikethrough';

  @override
  String get superscript => 'Superscript';

  @override
  String get subscript => 'Subscript';

  @override
  String get clearFormatting => 'Clear formatting';

  @override
  String get decreaseFontSize => 'Decrease font size';

  @override
  String get increaseFontSize => 'Increase font size';

  @override
  String get fontColor => 'Font color';

  @override
  String get automaticColor => 'Automatic';

  @override
  String get highlightColor => 'Highlight color';

  @override
  String get noHighlight => 'No highlight';

  @override
  String get moreColors => 'More colors';

  @override
  String get alignLeft => 'Align left';

  @override
  String get alignCenter => 'Center';

  @override
  String get alignRight => 'Align right';

  @override
  String get justify => 'Justify';

  @override
  String get decreaseIndent => 'Decrease indent';

  @override
  String get increaseIndent => 'Increase indent';

  @override
  String get bullets => 'Bullets';

  @override
  String get numbering => 'Numbering';

  @override
  String get lineSpacing => 'Line spacing';

  @override
  String get pageBreak => 'Page break';

  @override
  String get pageBreakTooltip => 'Start a new page';

  @override
  String get picture => 'Picture';

  @override
  String get insertPicture => 'Insert picture';

  @override
  String get table => 'Table';

  @override
  String tableSize(int rows, int columns) {
    return 'Table $rows × $columns';
  }

  @override
  String get link => 'Link';

  @override
  String get insertLink => 'Insert link';

  @override
  String get headerFooter => 'Header & Footer';

  @override
  String get headerFooterTooltip =>
      'Edit the text at the top and bottom of the pages';

  @override
  String get pageNumber => 'Page number';

  @override
  String get pageNumberTopRight => 'Top, right';

  @override
  String get pageNumberTopCenter => 'Top, centered';

  @override
  String get pageNumberBottomRight => 'Bottom, right';

  @override
  String get pageNumberBottomCenter => 'Bottom, centered';

  @override
  String get firstPageWithoutNumber => 'First page without number';

  @override
  String get forCoverPage => 'For a cover page';

  @override
  String get removePageNumbers => 'Remove page numbers';

  @override
  String get margins => 'Margins';

  @override
  String get marginsNormal => 'Normal';

  @override
  String get marginsAbnt => 'ABNT';

  @override
  String get marginsNarrow => 'Narrow';

  @override
  String get marginsModerate => 'Moderate';

  @override
  String get marginsWide => 'Wide';

  @override
  String marginsAllSides(String size) {
    return '$size cm on all sides';
  }

  @override
  String marginsTopBottomSides(String vertical, String horizontal) {
    return 'Top and bottom $vertical cm · left and right $horizontal cm';
  }

  @override
  String marginsTopLeftBottomRight(String topLeft, String bottomRight) {
    return 'Top and left $topLeft cm · bottom and right $bottomRight cm';
  }

  @override
  String marginsEachSide(String top, String bottom, String left, String right) {
    return 'Top $top · bottom $bottom · left $left · right $right cm';
  }

  @override
  String get orientation => 'Orientation';

  @override
  String get portrait => 'Portrait';

  @override
  String get landscape => 'Landscape';

  @override
  String get paperSize => 'Size';

  @override
  String get paperLetter => 'Letter';

  @override
  String get paperLegal => 'Legal';

  @override
  String get viewPages => 'Pages';

  @override
  String get viewPagesTooltip => 'Show the document in pages, as it will print';

  @override
  String get viewContinuous => 'Continuous';

  @override
  String get viewContinuousTooltip => 'Flowing text, without page breaks';

  @override
  String get zoomOut => 'Zoom out';

  @override
  String get zoomIn => 'Zoom in';

  @override
  String get spelling => 'Spelling';

  @override
  String get spellingTooltip => 'Underline misspelled words in red';

  @override
  String get rowAbove => 'Above';

  @override
  String get insertRowAbove => 'Insert row above';

  @override
  String get rowBelow => 'Below';

  @override
  String get insertRowBelow => 'Insert row below';

  @override
  String get columnLeft => 'Left';

  @override
  String get insertColumnLeft => 'Insert column to the left';

  @override
  String get columnRight => 'Right';

  @override
  String get insertColumnRight => 'Insert column to the right';

  @override
  String get unavailableWithMergedCells =>
      'Not available in tables with merged cells';

  @override
  String get row => 'Row';

  @override
  String get column => 'Column';

  @override
  String get styleNormal => 'Normal';

  @override
  String styleHeading(int level) {
    return 'Heading $level';
  }

  @override
  String fontDownloadFailed(String family) {
    return 'Couldn’t download the font “$family”. Check your internet connection.';
  }

  @override
  String get colorBlack => 'Black';

  @override
  String get colorDarkGray => 'Dark gray';

  @override
  String get colorLightGray => 'Light gray';

  @override
  String get colorGray => 'Gray';

  @override
  String get colorDarkRed => 'Dark red';

  @override
  String get colorRed => 'Red';

  @override
  String get colorOrange => 'Orange';

  @override
  String get colorGold => 'Gold';

  @override
  String get colorYellow => 'Yellow';

  @override
  String get colorBrightGreen => 'Bright green';

  @override
  String get colorGreen => 'Green';

  @override
  String get colorOlive => 'Olive';

  @override
  String get colorTurquoise => 'Turquoise';

  @override
  String get colorLightBlue => 'Light blue';

  @override
  String get colorBlue => 'Blue';

  @override
  String get colorDarkBlue => 'Dark blue';

  @override
  String get colorPurple => 'Purple';

  @override
  String get colorViolet => 'Violet';

  @override
  String get colorPink => 'Pink';

  @override
  String get saveChangesTitle => 'Save changes?';

  @override
  String saveChangesMessage(String name) {
    return 'Do you want to save the changes to “$name”?';
  }

  @override
  String get cancel => 'Cancel';

  @override
  String get dontSave => 'Don’t save';

  @override
  String get save => 'Save';

  @override
  String get recoverTitle => 'Recover document?';

  @override
  String recoverMessage(String name, String date, String time) {
    return '“$name” was closed without saving. There is a copy from $date at $time. Do you want to recover it?';
  }

  @override
  String get discard => 'Discard';

  @override
  String get recover => 'Recover';

  @override
  String get shareAs => 'Share as';

  @override
  String get shareWordDocumentHint => 'Whoever receives it can edit it';

  @override
  String get shareCurrentFormatHint => 'Same format as the file';

  @override
  String get sharePdf => 'PDF';

  @override
  String get sharePdfHint => 'Looks the same on any device';

  @override
  String get preparingPdf => 'Preparing the PDF…';

  @override
  String buildingPdfPage(int page, int total) {
    return 'Building the PDF: page $page of $total';
  }

  @override
  String get editLink => 'Edit link';

  @override
  String get linkText => 'Text to display';

  @override
  String get linkAddress => 'Address (website or email)';

  @override
  String get removeLink => 'Remove link';

  @override
  String get ok => 'OK';

  @override
  String unsupportedImage(String format) {
    return '$format picture: it shows in Word but not here. It is kept when you save.';
  }

  @override
  String get sectionBreak => 'Section break';

  @override
  String get protectedContentTooltip => 'Word content kept as is when you save';

  @override
  String keptAsIs(String label) {
    return '$label · kept as is when you save';
  }

  @override
  String get unsupportedPastedContent =>
      'Pasted content that Voges Word doesn’t save';

  @override
  String get contentSpecial => 'Special content';

  @override
  String get contentTableOfContents => 'Table of contents';

  @override
  String get contentCoverPage => 'Cover page';

  @override
  String get contentBibliography => 'Bibliography';

  @override
  String get contentNote => 'note';

  @override
  String get contentChart => 'chart';

  @override
  String get contentDiagram => 'diagram';

  @override
  String get contentTextBox => 'text box';

  @override
  String get contentEquation => 'equation';

  @override
  String get contentObject => 'object';

  @override
  String get tableUnavailable => '[table unavailable]';

  @override
  String get startWriting => 'Start writing…';

  @override
  String get untitledDocument => 'Untitled document';

  @override
  String get untitledFileName => 'Document';

  @override
  String get openDocument => 'Open document';

  @override
  String get saveAs => 'Save as';

  @override
  String get export => 'Export';

  @override
  String get problemLegacyDoc =>
      'Files from Word 95 and older aren’t supported. Open the file in Word and save it as .docx.';

  @override
  String get problemUnsupportedFormat =>
      'Voges Word opens .docx, .doc, .odt, .rtf, .html, .md and .txt files.';

  @override
  String get problemNotWordDocument => 'The file isn’t a valid Word document.';

  @override
  String get problemPasswordProtected =>
      'The file is protected with a password. Remove the password in the app that created it and try again.';

  @override
  String get problemTooLarge => 'The file is too large to open.';

  @override
  String problemDamaged(String name) {
    return 'Couldn’t open “$name”. The file may be damaged.';
  }

  @override
  String get noticeTrackedChangesAccepted =>
      'The document’s tracked changes were accepted.';

  @override
  String get noticeCommentsHidden =>
      'The document’s comments don’t show in Voges Word.';

  @override
  String get noticeContentNotImported =>
      'Some parts of this file can’t be shown in Voges Word and will be left out when you save it.';

  @override
  String get noticeSavesAsDocx =>
      'This is a Word 97–2003 file. Saving creates a .docx copy and leaves the original untouched.';

  @override
  String get recoverFailed => 'Couldn’t recover the document.';

  @override
  String get openFailed => 'Couldn’t open the file.';

  @override
  String recentNotFound(String name) {
    return '“$name” wasn’t found. It may have been moved or deleted.';
  }

  @override
  String savedAs(String name) {
    return 'Saved as $name';
  }

  @override
  String get saveFailed =>
      'Couldn’t save. Check whether the file is open in another program.';

  @override
  String get pictureOpenFailed => 'Couldn’t open the picture.';

  @override
  String get pictureFormatUnknown =>
      'Unrecognized picture format. Use PNG, JPG, GIF or BMP.';

  @override
  String get pdfFailed => 'Couldn’t create the PDF.';

  @override
  String pdfSaved(String name) {
    return 'PDF saved: $name';
  }

  @override
  String get pdfSaveFailed => 'Couldn’t save the PDF.';

  @override
  String get printFailed => 'Couldn’t open printing.';

  @override
  String get shareFailed => 'Couldn’t share.';

  @override
  String replacedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count occurrences replaced',
      one: '1 occurrence replaced',
    );
    return '$_temp0';
  }

  @override
  String get noResults => 'No results';

  @override
  String matchPosition(int current, int total) {
    return '$current of $total';
  }

  @override
  String get hideReplace => 'Hide replace';

  @override
  String get replace => 'Replace';

  @override
  String get find => 'Find';

  @override
  String get previous => 'Previous';

  @override
  String get next => 'Next';

  @override
  String get closeEsc => 'Close (Esc)';

  @override
  String get replaceWith => 'Replace with';

  @override
  String get replaceAll => 'All';

  @override
  String get otherPages => 'Other pages';

  @override
  String get firstPage => 'First page';

  @override
  String get header => 'Header';

  @override
  String get footer => 'Footer';

  @override
  String get differentFirstPage => 'Different first page';

  @override
  String get differentFirstPageHint =>
      'For a cover page: the first page gets its own header and footer, which can stay empty.';

  @override
  String get apply => 'Apply';

  @override
  String get empty => 'Empty';

  @override
  String get insertPageNumber => 'Insert page number';

  @override
  String get defaultFont => 'Default';

  @override
  String get fontsInDocument => 'In this document';

  @override
  String get fontsOnComputer => 'On this computer';

  @override
  String get fontsOnDevice => 'On this device';

  @override
  String get addFromGoogleFonts => 'Add from Google Fonts';

  @override
  String get searchFont => 'Search fonts';

  @override
  String get noFontsFound => 'No fonts found';

  @override
  String get fontMissing => 'Not installed: shown with another font';

  @override
  String get fontDownloadsOnUse => 'Downloads from Google Fonts when used';

  @override
  String get addToList => 'Add to the list';

  @override
  String get undo => 'Undo';

  @override
  String get redo => 'Redo';

  @override
  String get copy => 'Copy';

  @override
  String get cut => 'Cut';

  @override
  String get paste => 'Paste';

  @override
  String get fileMenu => 'File';

  @override
  String get unsavedChanges => 'Unsaved changes';

  @override
  String pageOf(int current, int total) {
    return 'Page $current of $total';
  }

  @override
  String wordCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString words',
      one: '1 word',
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
      other: '$countString characters',
      one: '1 character',
    );
    return '$_temp0';
  }

  @override
  String get plainTextWarning =>
      '.txt files keep only the text. Use “Save as” to keep the formatting.';

  @override
  String get plainText => 'Plain text';

  @override
  String get markdownWarning =>
      '.md files keep only basic formatting. Use “Save as” to keep all of it.';

  @override
  String get markdown => 'Markdown';

  @override
  String get webPageWarning =>
      'Web pages don’t keep the page setup, headers or footers. Use “Save as” to keep them.';

  @override
  String get webPage => 'Web page';

  @override
  String get word97Warning =>
      'Voges Word doesn’t write Word 97–2003 files: saving creates a .docx copy and leaves the original untouched.';

  @override
  String get word97 => 'Word 97–2003';

  @override
  String get wordMacrosWarning =>
      'Macros are kept when you save, but Voges Word never runs them. “Save as” creates a .docx without them.';

  @override
  String get wordMacros => 'Word with macros';

  @override
  String get minimize => 'Minimize';

  @override
  String get maximize => 'Maximize';

  @override
  String get restore => 'Restore';

  @override
  String get close => 'Close';

  @override
  String ignoreWord(String word) {
    return 'Ignore “$word”';
  }

  @override
  String get templateBlank => 'Blank document';

  @override
  String get templateSingleSpaced => 'Single spaced';

  @override
  String get templateSchoolWork => 'School paper (ABNT)';

  @override
  String get templateResume => 'Résumé';

  @override
  String get open => 'Open';

  @override
  String get otherFormats => 'Other formats';

  @override
  String get formatDocx => 'Word document (.docx)';

  @override
  String get formatDocm => 'Word document with macros (.docm)';

  @override
  String get formatDoc => 'Word 97–2003 document (.doc)';

  @override
  String get formatOdt => 'OpenDocument Text (.odt)';

  @override
  String get formatRtf => 'Rich Text Format (.rtf)';

  @override
  String get formatHtml => 'Web page (.html)';

  @override
  String get formatMarkdown => 'Markdown (.md)';

  @override
  String get formatPlainText => 'Plain text (.txt)';

  @override
  String get print => 'Print';

  @override
  String get share => 'Share';

  @override
  String get newDocument => 'New document';

  @override
  String get recentlyOpened => 'Recently opened';

  @override
  String get openAnother => 'Open another…';

  @override
  String get language => 'Language';

  @override
  String get languageSystem => 'Same as the system';

  @override
  String get resumeName => 'Your Full Name';

  @override
  String get resumeContact =>
      'City, State · (000) 000-0000 · youremail@example.com';

  @override
  String get resumeObjective => 'Objective';

  @override
  String get resumeObjectiveText =>
      'Describe in one or two sentences the job or the field you want to work in.';

  @override
  String get resumeExperience => 'Experience';

  @override
  String get resumeRole => 'Job title — Company';

  @override
  String get resumePeriod => 'Month/Year – Month/Year';

  @override
  String get resumeAchievement => 'Main result or responsibility.';

  @override
  String get resumeOtherAchievement =>
      'Another achievement, ideally with numbers.';

  @override
  String get resumeEducation => 'Education';

  @override
  String get resumeCourse => 'Degree — School';

  @override
  String get resumeGraduation => 'Year of completion';

  @override
  String get resumeSkills => 'Skills';

  @override
  String get resumeSkill => 'Technical skill or tool';

  @override
  String get resumeLanguage => 'Language and level';
}
