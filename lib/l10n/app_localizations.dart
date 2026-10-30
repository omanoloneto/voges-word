import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_pt.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
    Locale('pt'),
  ];

  /// No description provided for @tabHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get tabHome;

  /// No description provided for @tabInsert.
  ///
  /// In en, this message translates to:
  /// **'Insert'**
  String get tabInsert;

  /// No description provided for @tabLayout.
  ///
  /// In en, this message translates to:
  /// **'Layout'**
  String get tabLayout;

  /// No description provided for @tabView.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get tabView;

  /// No description provided for @tabTable.
  ///
  /// In en, this message translates to:
  /// **'Table'**
  String get tabTable;

  /// No description provided for @groupFont.
  ///
  /// In en, this message translates to:
  /// **'Font'**
  String get groupFont;

  /// No description provided for @groupColor.
  ///
  /// In en, this message translates to:
  /// **'Color'**
  String get groupColor;

  /// No description provided for @groupParagraph.
  ///
  /// In en, this message translates to:
  /// **'Paragraph'**
  String get groupParagraph;

  /// No description provided for @groupStyles.
  ///
  /// In en, this message translates to:
  /// **'Styles'**
  String get groupStyles;

  /// No description provided for @groupIllustrations.
  ///
  /// In en, this message translates to:
  /// **'Illustrations'**
  String get groupIllustrations;

  /// No description provided for @groupTables.
  ///
  /// In en, this message translates to:
  /// **'Tables'**
  String get groupTables;

  /// No description provided for @groupLinks.
  ///
  /// In en, this message translates to:
  /// **'Links'**
  String get groupLinks;

  /// No description provided for @groupPages.
  ///
  /// In en, this message translates to:
  /// **'Pages'**
  String get groupPages;

  /// No description provided for @groupHeaderFooter.
  ///
  /// In en, this message translates to:
  /// **'Header & Footer'**
  String get groupHeaderFooter;

  /// No description provided for @groupPageSetup.
  ///
  /// In en, this message translates to:
  /// **'Page Setup'**
  String get groupPageSetup;

  /// No description provided for @groupViews.
  ///
  /// In en, this message translates to:
  /// **'Views'**
  String get groupViews;

  /// No description provided for @groupZoom.
  ///
  /// In en, this message translates to:
  /// **'Zoom'**
  String get groupZoom;

  /// No description provided for @groupProofing.
  ///
  /// In en, this message translates to:
  /// **'Proofing'**
  String get groupProofing;

  /// No description provided for @groupRowsColumns.
  ///
  /// In en, this message translates to:
  /// **'Rows & Columns'**
  String get groupRowsColumns;

  /// No description provided for @groupDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get groupDelete;

  /// No description provided for @bold.
  ///
  /// In en, this message translates to:
  /// **'Bold'**
  String get bold;

  /// No description provided for @italic.
  ///
  /// In en, this message translates to:
  /// **'Italic'**
  String get italic;

  /// No description provided for @underline.
  ///
  /// In en, this message translates to:
  /// **'Underline'**
  String get underline;

  /// No description provided for @strikethrough.
  ///
  /// In en, this message translates to:
  /// **'Strikethrough'**
  String get strikethrough;

  /// No description provided for @superscript.
  ///
  /// In en, this message translates to:
  /// **'Superscript'**
  String get superscript;

  /// No description provided for @subscript.
  ///
  /// In en, this message translates to:
  /// **'Subscript'**
  String get subscript;

  /// No description provided for @clearFormatting.
  ///
  /// In en, this message translates to:
  /// **'Clear formatting'**
  String get clearFormatting;

  /// No description provided for @decreaseFontSize.
  ///
  /// In en, this message translates to:
  /// **'Decrease font size'**
  String get decreaseFontSize;

  /// No description provided for @increaseFontSize.
  ///
  /// In en, this message translates to:
  /// **'Increase font size'**
  String get increaseFontSize;

  /// No description provided for @fontColor.
  ///
  /// In en, this message translates to:
  /// **'Font color'**
  String get fontColor;

  /// No description provided for @automaticColor.
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get automaticColor;

  /// No description provided for @highlightColor.
  ///
  /// In en, this message translates to:
  /// **'Highlight color'**
  String get highlightColor;

  /// No description provided for @noHighlight.
  ///
  /// In en, this message translates to:
  /// **'No highlight'**
  String get noHighlight;

  /// No description provided for @moreColors.
  ///
  /// In en, this message translates to:
  /// **'More colors'**
  String get moreColors;

  /// No description provided for @alignLeft.
  ///
  /// In en, this message translates to:
  /// **'Align left'**
  String get alignLeft;

  /// No description provided for @alignCenter.
  ///
  /// In en, this message translates to:
  /// **'Center'**
  String get alignCenter;

  /// No description provided for @alignRight.
  ///
  /// In en, this message translates to:
  /// **'Align right'**
  String get alignRight;

  /// No description provided for @justify.
  ///
  /// In en, this message translates to:
  /// **'Justify'**
  String get justify;

  /// No description provided for @decreaseIndent.
  ///
  /// In en, this message translates to:
  /// **'Decrease indent'**
  String get decreaseIndent;

  /// No description provided for @increaseIndent.
  ///
  /// In en, this message translates to:
  /// **'Increase indent'**
  String get increaseIndent;

  /// No description provided for @bullets.
  ///
  /// In en, this message translates to:
  /// **'Bullets'**
  String get bullets;

  /// No description provided for @numbering.
  ///
  /// In en, this message translates to:
  /// **'Numbering'**
  String get numbering;

  /// No description provided for @lineSpacing.
  ///
  /// In en, this message translates to:
  /// **'Line spacing'**
  String get lineSpacing;

  /// No description provided for @pageBreak.
  ///
  /// In en, this message translates to:
  /// **'Page break'**
  String get pageBreak;

  /// No description provided for @pageBreakTooltip.
  ///
  /// In en, this message translates to:
  /// **'Start a new page'**
  String get pageBreakTooltip;

  /// No description provided for @picture.
  ///
  /// In en, this message translates to:
  /// **'Picture'**
  String get picture;

  /// No description provided for @insertPicture.
  ///
  /// In en, this message translates to:
  /// **'Insert picture'**
  String get insertPicture;

  /// No description provided for @table.
  ///
  /// In en, this message translates to:
  /// **'Table'**
  String get table;

  /// No description provided for @tableSize.
  ///
  /// In en, this message translates to:
  /// **'Table {rows} × {columns}'**
  String tableSize(int rows, int columns);

  /// No description provided for @link.
  ///
  /// In en, this message translates to:
  /// **'Link'**
  String get link;

  /// No description provided for @insertLink.
  ///
  /// In en, this message translates to:
  /// **'Insert link'**
  String get insertLink;

  /// No description provided for @headerFooter.
  ///
  /// In en, this message translates to:
  /// **'Header & Footer'**
  String get headerFooter;

  /// No description provided for @headerFooterTooltip.
  ///
  /// In en, this message translates to:
  /// **'Edit the text at the top and bottom of the pages'**
  String get headerFooterTooltip;

  /// No description provided for @pageNumber.
  ///
  /// In en, this message translates to:
  /// **'Page number'**
  String get pageNumber;

  /// No description provided for @pageNumberTopRight.
  ///
  /// In en, this message translates to:
  /// **'Top, right'**
  String get pageNumberTopRight;

  /// No description provided for @pageNumberTopCenter.
  ///
  /// In en, this message translates to:
  /// **'Top, centered'**
  String get pageNumberTopCenter;

  /// No description provided for @pageNumberBottomRight.
  ///
  /// In en, this message translates to:
  /// **'Bottom, right'**
  String get pageNumberBottomRight;

  /// No description provided for @pageNumberBottomCenter.
  ///
  /// In en, this message translates to:
  /// **'Bottom, centered'**
  String get pageNumberBottomCenter;

  /// No description provided for @firstPageWithoutNumber.
  ///
  /// In en, this message translates to:
  /// **'First page without number'**
  String get firstPageWithoutNumber;

  /// No description provided for @forCoverPage.
  ///
  /// In en, this message translates to:
  /// **'For a cover page'**
  String get forCoverPage;

  /// No description provided for @removePageNumbers.
  ///
  /// In en, this message translates to:
  /// **'Remove page numbers'**
  String get removePageNumbers;

  /// No description provided for @margins.
  ///
  /// In en, this message translates to:
  /// **'Margins'**
  String get margins;

  /// No description provided for @marginsNormal.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get marginsNormal;

  /// No description provided for @marginsAbnt.
  ///
  /// In en, this message translates to:
  /// **'ABNT'**
  String get marginsAbnt;

  /// No description provided for @marginsNarrow.
  ///
  /// In en, this message translates to:
  /// **'Narrow'**
  String get marginsNarrow;

  /// No description provided for @marginsModerate.
  ///
  /// In en, this message translates to:
  /// **'Moderate'**
  String get marginsModerate;

  /// No description provided for @marginsWide.
  ///
  /// In en, this message translates to:
  /// **'Wide'**
  String get marginsWide;

  /// No description provided for @marginsAllSides.
  ///
  /// In en, this message translates to:
  /// **'{size} cm on all sides'**
  String marginsAllSides(String size);

  /// No description provided for @marginsTopBottomSides.
  ///
  /// In en, this message translates to:
  /// **'Top and bottom {vertical} cm · left and right {horizontal} cm'**
  String marginsTopBottomSides(String vertical, String horizontal);

  /// No description provided for @marginsTopLeftBottomRight.
  ///
  /// In en, this message translates to:
  /// **'Top and left {topLeft} cm · bottom and right {bottomRight} cm'**
  String marginsTopLeftBottomRight(String topLeft, String bottomRight);

  /// No description provided for @marginsEachSide.
  ///
  /// In en, this message translates to:
  /// **'Top {top} · bottom {bottom} · left {left} · right {right} cm'**
  String marginsEachSide(String top, String bottom, String left, String right);

  /// No description provided for @orientation.
  ///
  /// In en, this message translates to:
  /// **'Orientation'**
  String get orientation;

  /// No description provided for @portrait.
  ///
  /// In en, this message translates to:
  /// **'Portrait'**
  String get portrait;

  /// No description provided for @landscape.
  ///
  /// In en, this message translates to:
  /// **'Landscape'**
  String get landscape;

  /// No description provided for @paperSize.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get paperSize;

  /// No description provided for @paperLetter.
  ///
  /// In en, this message translates to:
  /// **'Letter'**
  String get paperLetter;

  /// No description provided for @paperLegal.
  ///
  /// In en, this message translates to:
  /// **'Legal'**
  String get paperLegal;

  /// No description provided for @viewPages.
  ///
  /// In en, this message translates to:
  /// **'Pages'**
  String get viewPages;

  /// No description provided for @viewPagesTooltip.
  ///
  /// In en, this message translates to:
  /// **'Show the document in pages, as it will print'**
  String get viewPagesTooltip;

  /// No description provided for @viewContinuous.
  ///
  /// In en, this message translates to:
  /// **'Continuous'**
  String get viewContinuous;

  /// No description provided for @viewContinuousTooltip.
  ///
  /// In en, this message translates to:
  /// **'Flowing text, without page breaks'**
  String get viewContinuousTooltip;

  /// No description provided for @zoomOut.
  ///
  /// In en, this message translates to:
  /// **'Zoom out'**
  String get zoomOut;

  /// No description provided for @zoomIn.
  ///
  /// In en, this message translates to:
  /// **'Zoom in'**
  String get zoomIn;

  /// No description provided for @spelling.
  ///
  /// In en, this message translates to:
  /// **'Spelling'**
  String get spelling;

  /// No description provided for @spellingTooltip.
  ///
  /// In en, this message translates to:
  /// **'Underline misspelled words in red'**
  String get spellingTooltip;

  /// No description provided for @rowAbove.
  ///
  /// In en, this message translates to:
  /// **'Above'**
  String get rowAbove;

  /// No description provided for @insertRowAbove.
  ///
  /// In en, this message translates to:
  /// **'Insert row above'**
  String get insertRowAbove;

  /// No description provided for @rowBelow.
  ///
  /// In en, this message translates to:
  /// **'Below'**
  String get rowBelow;

  /// No description provided for @insertRowBelow.
  ///
  /// In en, this message translates to:
  /// **'Insert row below'**
  String get insertRowBelow;

  /// No description provided for @columnLeft.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get columnLeft;

  /// No description provided for @insertColumnLeft.
  ///
  /// In en, this message translates to:
  /// **'Insert column to the left'**
  String get insertColumnLeft;

  /// No description provided for @columnRight.
  ///
  /// In en, this message translates to:
  /// **'Right'**
  String get columnRight;

  /// No description provided for @insertColumnRight.
  ///
  /// In en, this message translates to:
  /// **'Insert column to the right'**
  String get insertColumnRight;

  /// No description provided for @unavailableWithMergedCells.
  ///
  /// In en, this message translates to:
  /// **'Not available in tables with merged cells'**
  String get unavailableWithMergedCells;

  /// No description provided for @row.
  ///
  /// In en, this message translates to:
  /// **'Row'**
  String get row;

  /// No description provided for @column.
  ///
  /// In en, this message translates to:
  /// **'Column'**
  String get column;

  /// No description provided for @styleNormal.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get styleNormal;

  /// No description provided for @styleHeading.
  ///
  /// In en, this message translates to:
  /// **'Heading {level}'**
  String styleHeading(int level);

  /// No description provided for @fontDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t download the font “{family}”. Check your internet connection.'**
  String fontDownloadFailed(String family);

  /// No description provided for @colorBlack.
  ///
  /// In en, this message translates to:
  /// **'Black'**
  String get colorBlack;

  /// No description provided for @colorDarkGray.
  ///
  /// In en, this message translates to:
  /// **'Dark gray'**
  String get colorDarkGray;

  /// No description provided for @colorLightGray.
  ///
  /// In en, this message translates to:
  /// **'Light gray'**
  String get colorLightGray;

  /// No description provided for @colorGray.
  ///
  /// In en, this message translates to:
  /// **'Gray'**
  String get colorGray;

  /// No description provided for @colorDarkRed.
  ///
  /// In en, this message translates to:
  /// **'Dark red'**
  String get colorDarkRed;

  /// No description provided for @colorRed.
  ///
  /// In en, this message translates to:
  /// **'Red'**
  String get colorRed;

  /// No description provided for @colorOrange.
  ///
  /// In en, this message translates to:
  /// **'Orange'**
  String get colorOrange;

  /// No description provided for @colorGold.
  ///
  /// In en, this message translates to:
  /// **'Gold'**
  String get colorGold;

  /// No description provided for @colorYellow.
  ///
  /// In en, this message translates to:
  /// **'Yellow'**
  String get colorYellow;

  /// No description provided for @colorBrightGreen.
  ///
  /// In en, this message translates to:
  /// **'Bright green'**
  String get colorBrightGreen;

  /// No description provided for @colorGreen.
  ///
  /// In en, this message translates to:
  /// **'Green'**
  String get colorGreen;

  /// No description provided for @colorOlive.
  ///
  /// In en, this message translates to:
  /// **'Olive'**
  String get colorOlive;

  /// No description provided for @colorTurquoise.
  ///
  /// In en, this message translates to:
  /// **'Turquoise'**
  String get colorTurquoise;

  /// No description provided for @colorLightBlue.
  ///
  /// In en, this message translates to:
  /// **'Light blue'**
  String get colorLightBlue;

  /// No description provided for @colorBlue.
  ///
  /// In en, this message translates to:
  /// **'Blue'**
  String get colorBlue;

  /// No description provided for @colorDarkBlue.
  ///
  /// In en, this message translates to:
  /// **'Dark blue'**
  String get colorDarkBlue;

  /// No description provided for @colorPurple.
  ///
  /// In en, this message translates to:
  /// **'Purple'**
  String get colorPurple;

  /// No description provided for @colorViolet.
  ///
  /// In en, this message translates to:
  /// **'Violet'**
  String get colorViolet;

  /// No description provided for @colorPink.
  ///
  /// In en, this message translates to:
  /// **'Pink'**
  String get colorPink;

  /// No description provided for @saveChangesTitle.
  ///
  /// In en, this message translates to:
  /// **'Save changes?'**
  String get saveChangesTitle;

  /// No description provided for @saveChangesMessage.
  ///
  /// In en, this message translates to:
  /// **'Do you want to save the changes to “{name}”?'**
  String saveChangesMessage(String name);

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @dontSave.
  ///
  /// In en, this message translates to:
  /// **'Don’t save'**
  String get dontSave;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @recoverTitle.
  ///
  /// In en, this message translates to:
  /// **'Recover document?'**
  String get recoverTitle;

  /// No description provided for @recoverMessage.
  ///
  /// In en, this message translates to:
  /// **'“{name}” was closed without saving. There is a copy from {date} at {time}. Do you want to recover it?'**
  String recoverMessage(String name, String date, String time);

  /// No description provided for @discard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get discard;

  /// No description provided for @recover.
  ///
  /// In en, this message translates to:
  /// **'Recover'**
  String get recover;

  /// No description provided for @shareAs.
  ///
  /// In en, this message translates to:
  /// **'Share as'**
  String get shareAs;

  /// No description provided for @shareWordDocumentHint.
  ///
  /// In en, this message translates to:
  /// **'Whoever receives it can edit it'**
  String get shareWordDocumentHint;

  /// No description provided for @shareCurrentFormatHint.
  ///
  /// In en, this message translates to:
  /// **'Same format as the file'**
  String get shareCurrentFormatHint;

  /// No description provided for @sharePdf.
  ///
  /// In en, this message translates to:
  /// **'PDF'**
  String get sharePdf;

  /// No description provided for @sharePdfHint.
  ///
  /// In en, this message translates to:
  /// **'Looks the same on any device'**
  String get sharePdfHint;

  /// No description provided for @preparingPdf.
  ///
  /// In en, this message translates to:
  /// **'Preparing the PDF…'**
  String get preparingPdf;

  /// No description provided for @buildingPdfPage.
  ///
  /// In en, this message translates to:
  /// **'Building the PDF: page {page} of {total}'**
  String buildingPdfPage(int page, int total);

  /// No description provided for @editLink.
  ///
  /// In en, this message translates to:
  /// **'Edit link'**
  String get editLink;

  /// No description provided for @linkText.
  ///
  /// In en, this message translates to:
  /// **'Text to display'**
  String get linkText;

  /// No description provided for @linkAddress.
  ///
  /// In en, this message translates to:
  /// **'Address (website or email)'**
  String get linkAddress;

  /// No description provided for @removeLink.
  ///
  /// In en, this message translates to:
  /// **'Remove link'**
  String get removeLink;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @unsupportedImage.
  ///
  /// In en, this message translates to:
  /// **'{format} picture: it shows in Word but not here. It is kept when you save.'**
  String unsupportedImage(String format);

  /// No description provided for @sectionBreak.
  ///
  /// In en, this message translates to:
  /// **'Section break'**
  String get sectionBreak;

  /// No description provided for @protectedContentTooltip.
  ///
  /// In en, this message translates to:
  /// **'Word content kept as is when you save'**
  String get protectedContentTooltip;

  /// No description provided for @keptAsIs.
  ///
  /// In en, this message translates to:
  /// **'{label} · kept as is when you save'**
  String keptAsIs(String label);

  /// No description provided for @unsupportedPastedContent.
  ///
  /// In en, this message translates to:
  /// **'Pasted content that Voges Word doesn’t save'**
  String get unsupportedPastedContent;

  /// No description provided for @contentSpecial.
  ///
  /// In en, this message translates to:
  /// **'Special content'**
  String get contentSpecial;

  /// No description provided for @contentTableOfContents.
  ///
  /// In en, this message translates to:
  /// **'Table of contents'**
  String get contentTableOfContents;

  /// No description provided for @contentCoverPage.
  ///
  /// In en, this message translates to:
  /// **'Cover page'**
  String get contentCoverPage;

  /// No description provided for @contentBibliography.
  ///
  /// In en, this message translates to:
  /// **'Bibliography'**
  String get contentBibliography;

  /// No description provided for @contentNote.
  ///
  /// In en, this message translates to:
  /// **'note'**
  String get contentNote;

  /// No description provided for @contentChart.
  ///
  /// In en, this message translates to:
  /// **'chart'**
  String get contentChart;

  /// No description provided for @contentDiagram.
  ///
  /// In en, this message translates to:
  /// **'diagram'**
  String get contentDiagram;

  /// No description provided for @contentTextBox.
  ///
  /// In en, this message translates to:
  /// **'text box'**
  String get contentTextBox;

  /// No description provided for @contentEquation.
  ///
  /// In en, this message translates to:
  /// **'equation'**
  String get contentEquation;

  /// No description provided for @contentObject.
  ///
  /// In en, this message translates to:
  /// **'object'**
  String get contentObject;

  /// No description provided for @tableUnavailable.
  ///
  /// In en, this message translates to:
  /// **'[table unavailable]'**
  String get tableUnavailable;

  /// No description provided for @startWriting.
  ///
  /// In en, this message translates to:
  /// **'Start writing…'**
  String get startWriting;

  /// No description provided for @untitledDocument.
  ///
  /// In en, this message translates to:
  /// **'Untitled document'**
  String get untitledDocument;

  /// No description provided for @untitledFileName.
  ///
  /// In en, this message translates to:
  /// **'Document'**
  String get untitledFileName;

  /// No description provided for @openDocument.
  ///
  /// In en, this message translates to:
  /// **'Open document'**
  String get openDocument;

  /// No description provided for @saveAs.
  ///
  /// In en, this message translates to:
  /// **'Save as'**
  String get saveAs;

  /// No description provided for @export.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get export;

  /// No description provided for @problemLegacyDoc.
  ///
  /// In en, this message translates to:
  /// **'Files from Word 95 and older aren’t supported. Open the file in Word and save it as .docx.'**
  String get problemLegacyDoc;

  /// No description provided for @problemUnsupportedFormat.
  ///
  /// In en, this message translates to:
  /// **'Voges Word opens .docx, .doc, .odt, .rtf, .html, .md and .txt files.'**
  String get problemUnsupportedFormat;

  /// No description provided for @problemNotWordDocument.
  ///
  /// In en, this message translates to:
  /// **'The file isn’t a valid document.'**
  String get problemNotWordDocument;

  /// No description provided for @problemPasswordProtected.
  ///
  /// In en, this message translates to:
  /// **'The file is protected with a password. Remove the password in the app that created it and try again.'**
  String get problemPasswordProtected;

  /// No description provided for @problemTooLarge.
  ///
  /// In en, this message translates to:
  /// **'The file is too large to open.'**
  String get problemTooLarge;

  /// No description provided for @problemDamaged.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t open “{name}”. The file may be damaged.'**
  String problemDamaged(String name);

  /// No description provided for @noticeTrackedChangesAccepted.
  ///
  /// In en, this message translates to:
  /// **'The document’s tracked changes were accepted.'**
  String get noticeTrackedChangesAccepted;

  /// No description provided for @noticeCommentsHidden.
  ///
  /// In en, this message translates to:
  /// **'The document’s comments don’t show in Voges Word.'**
  String get noticeCommentsHidden;

  /// No description provided for @noticeContentNotImported.
  ///
  /// In en, this message translates to:
  /// **'Some parts of this file can’t be shown in Voges Word and will be left out when you save it.'**
  String get noticeContentNotImported;

  /// No description provided for @noticeSavesAsDocx.
  ///
  /// In en, this message translates to:
  /// **'This is a Word 97–2003 file. Saving creates a .docx copy and leaves the original untouched.'**
  String get noticeSavesAsDocx;

  /// No description provided for @recoverFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t recover the document.'**
  String get recoverFailed;

  /// No description provided for @openFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t open the file.'**
  String get openFailed;

  /// No description provided for @recentNotFound.
  ///
  /// In en, this message translates to:
  /// **'“{name}” wasn’t found. It may have been moved or deleted.'**
  String recentNotFound(String name);

  /// No description provided for @savedAs.
  ///
  /// In en, this message translates to:
  /// **'Saved as {name}'**
  String savedAs(String name);

  /// No description provided for @saveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t save. Check whether the file is open in another program.'**
  String get saveFailed;

  /// No description provided for @pictureOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t open the picture.'**
  String get pictureOpenFailed;

  /// No description provided for @pictureFormatUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unrecognized picture format. Use PNG, JPG, GIF or BMP.'**
  String get pictureFormatUnknown;

  /// No description provided for @pdfFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t create the PDF.'**
  String get pdfFailed;

  /// No description provided for @pdfSaved.
  ///
  /// In en, this message translates to:
  /// **'PDF saved: {name}'**
  String pdfSaved(String name);

  /// No description provided for @pdfSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t save the PDF.'**
  String get pdfSaveFailed;

  /// No description provided for @printFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t open printing.'**
  String get printFailed;

  /// No description provided for @shareFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t share.'**
  String get shareFailed;

  /// No description provided for @replacedCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 occurrence replaced} other{{count} occurrences replaced}}'**
  String replacedCount(int count);

  /// No description provided for @noResults.
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get noResults;

  /// No description provided for @matchPosition.
  ///
  /// In en, this message translates to:
  /// **'{current} of {total}'**
  String matchPosition(int current, int total);

  /// No description provided for @hideReplace.
  ///
  /// In en, this message translates to:
  /// **'Hide replace'**
  String get hideReplace;

  /// No description provided for @replace.
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get replace;

  /// No description provided for @find.
  ///
  /// In en, this message translates to:
  /// **'Find'**
  String get find;

  /// No description provided for @previous.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get previous;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @closeEsc.
  ///
  /// In en, this message translates to:
  /// **'Close (Esc)'**
  String get closeEsc;

  /// No description provided for @replaceWith.
  ///
  /// In en, this message translates to:
  /// **'Replace with'**
  String get replaceWith;

  /// No description provided for @replaceAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get replaceAll;

  /// No description provided for @otherPages.
  ///
  /// In en, this message translates to:
  /// **'Other pages'**
  String get otherPages;

  /// No description provided for @firstPage.
  ///
  /// In en, this message translates to:
  /// **'First page'**
  String get firstPage;

  /// No description provided for @header.
  ///
  /// In en, this message translates to:
  /// **'Header'**
  String get header;

  /// No description provided for @footer.
  ///
  /// In en, this message translates to:
  /// **'Footer'**
  String get footer;

  /// No description provided for @differentFirstPage.
  ///
  /// In en, this message translates to:
  /// **'Different first page'**
  String get differentFirstPage;

  /// No description provided for @differentFirstPageHint.
  ///
  /// In en, this message translates to:
  /// **'For a cover page: the first page gets its own header and footer, which can stay empty.'**
  String get differentFirstPageHint;

  /// No description provided for @apply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get apply;

  /// No description provided for @empty.
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get empty;

  /// No description provided for @insertPageNumber.
  ///
  /// In en, this message translates to:
  /// **'Insert page number'**
  String get insertPageNumber;

  /// No description provided for @defaultFont.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get defaultFont;

  /// No description provided for @fontsInDocument.
  ///
  /// In en, this message translates to:
  /// **'In this document'**
  String get fontsInDocument;

  /// No description provided for @fontsOnComputer.
  ///
  /// In en, this message translates to:
  /// **'On this computer'**
  String get fontsOnComputer;

  /// No description provided for @fontsOnDevice.
  ///
  /// In en, this message translates to:
  /// **'On this device'**
  String get fontsOnDevice;

  /// No description provided for @addFromGoogleFonts.
  ///
  /// In en, this message translates to:
  /// **'Add from Google Fonts'**
  String get addFromGoogleFonts;

  /// No description provided for @searchFont.
  ///
  /// In en, this message translates to:
  /// **'Search fonts'**
  String get searchFont;

  /// No description provided for @noFontsFound.
  ///
  /// In en, this message translates to:
  /// **'No fonts found'**
  String get noFontsFound;

  /// No description provided for @fontMissing.
  ///
  /// In en, this message translates to:
  /// **'Not installed: shown with another font'**
  String get fontMissing;

  /// No description provided for @fontDownloadsOnUse.
  ///
  /// In en, this message translates to:
  /// **'Downloads from Google Fonts when used'**
  String get fontDownloadsOnUse;

  /// No description provided for @addToList.
  ///
  /// In en, this message translates to:
  /// **'Add to the list'**
  String get addToList;

  /// No description provided for @undo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undo;

  /// No description provided for @redo.
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get redo;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @cut.
  ///
  /// In en, this message translates to:
  /// **'Cut'**
  String get cut;

  /// No description provided for @paste.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get paste;

  /// No description provided for @fileMenu.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get fileMenu;

  /// No description provided for @unsavedChanges.
  ///
  /// In en, this message translates to:
  /// **'Unsaved changes'**
  String get unsavedChanges;

  /// No description provided for @pageOf.
  ///
  /// In en, this message translates to:
  /// **'Page {current} of {total}'**
  String pageOf(int current, int total);

  /// No description provided for @wordCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 word} other{{count} words}}'**
  String wordCount(int count);

  /// No description provided for @characterCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 character} other{{count} characters}}'**
  String characterCount(int count);

  /// No description provided for @plainTextWarning.
  ///
  /// In en, this message translates to:
  /// **'.txt files keep only the text. Use “Save as” to keep the formatting.'**
  String get plainTextWarning;

  /// No description provided for @plainText.
  ///
  /// In en, this message translates to:
  /// **'Plain text'**
  String get plainText;

  /// No description provided for @markdownWarning.
  ///
  /// In en, this message translates to:
  /// **'.md files keep only basic formatting. Use “Save as” to keep all of it.'**
  String get markdownWarning;

  /// No description provided for @markdown.
  ///
  /// In en, this message translates to:
  /// **'Markdown'**
  String get markdown;

  /// No description provided for @webPageWarning.
  ///
  /// In en, this message translates to:
  /// **'Web pages don’t keep the page setup, headers or footers. Use “Save as” to keep them.'**
  String get webPageWarning;

  /// No description provided for @webPage.
  ///
  /// In en, this message translates to:
  /// **'Web page'**
  String get webPage;

  /// No description provided for @word97Warning.
  ///
  /// In en, this message translates to:
  /// **'Voges Word doesn’t write Word 97–2003 files: saving creates a .docx copy and leaves the original untouched.'**
  String get word97Warning;

  /// No description provided for @word97.
  ///
  /// In en, this message translates to:
  /// **'Word 97–2003'**
  String get word97;

  /// No description provided for @wordMacrosWarning.
  ///
  /// In en, this message translates to:
  /// **'Macros are kept when you save, but Voges Word never runs them. “Save as” creates a .docx without them.'**
  String get wordMacrosWarning;

  /// No description provided for @wordMacros.
  ///
  /// In en, this message translates to:
  /// **'Word with macros'**
  String get wordMacros;

  /// No description provided for @openDocumentTextWarning.
  ///
  /// In en, this message translates to:
  /// **'.odt files don’t keep equations, charts and other Word content as they are. Use “Save as” to keep them.'**
  String get openDocumentTextWarning;

  /// No description provided for @openDocumentText.
  ///
  /// In en, this message translates to:
  /// **'OpenDocument'**
  String get openDocumentText;

  /// No description provided for @richTextWarning.
  ///
  /// In en, this message translates to:
  /// **'.rtf files don’t keep equations, charts and other Word content as they are. Use “Save as” to keep them.'**
  String get richTextWarning;

  /// No description provided for @richText.
  ///
  /// In en, this message translates to:
  /// **'RTF'**
  String get richText;

  /// No description provided for @minimize.
  ///
  /// In en, this message translates to:
  /// **'Minimize'**
  String get minimize;

  /// No description provided for @maximize.
  ///
  /// In en, this message translates to:
  /// **'Maximize'**
  String get maximize;

  /// No description provided for @restore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restore;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @ignoreWord.
  ///
  /// In en, this message translates to:
  /// **'Ignore “{word}”'**
  String ignoreWord(String word);

  /// No description provided for @templateBlank.
  ///
  /// In en, this message translates to:
  /// **'Blank document'**
  String get templateBlank;

  /// No description provided for @templateSingleSpaced.
  ///
  /// In en, this message translates to:
  /// **'Single spaced'**
  String get templateSingleSpaced;

  /// No description provided for @templateSchoolWork.
  ///
  /// In en, this message translates to:
  /// **'School paper (ABNT)'**
  String get templateSchoolWork;

  /// No description provided for @templateResume.
  ///
  /// In en, this message translates to:
  /// **'Résumé'**
  String get templateResume;

  /// No description provided for @open.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get open;

  /// No description provided for @otherFormats.
  ///
  /// In en, this message translates to:
  /// **'Other formats'**
  String get otherFormats;

  /// No description provided for @formatDocx.
  ///
  /// In en, this message translates to:
  /// **'Word document (.docx)'**
  String get formatDocx;

  /// No description provided for @formatDocm.
  ///
  /// In en, this message translates to:
  /// **'Word document with macros (.docm)'**
  String get formatDocm;

  /// No description provided for @formatDoc.
  ///
  /// In en, this message translates to:
  /// **'Word 97–2003 document (.doc)'**
  String get formatDoc;

  /// No description provided for @formatOdt.
  ///
  /// In en, this message translates to:
  /// **'OpenDocument Text (.odt)'**
  String get formatOdt;

  /// No description provided for @formatRtf.
  ///
  /// In en, this message translates to:
  /// **'Rich Text Format (.rtf)'**
  String get formatRtf;

  /// No description provided for @formatHtml.
  ///
  /// In en, this message translates to:
  /// **'Web page (.html)'**
  String get formatHtml;

  /// No description provided for @formatMarkdown.
  ///
  /// In en, this message translates to:
  /// **'Markdown (.md)'**
  String get formatMarkdown;

  /// No description provided for @formatPlainText.
  ///
  /// In en, this message translates to:
  /// **'Plain text (.txt)'**
  String get formatPlainText;

  /// No description provided for @print.
  ///
  /// In en, this message translates to:
  /// **'Print'**
  String get print;

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @newDocument.
  ///
  /// In en, this message translates to:
  /// **'New document'**
  String get newDocument;

  /// No description provided for @recentlyOpened.
  ///
  /// In en, this message translates to:
  /// **'Recently opened'**
  String get recentlyOpened;

  /// No description provided for @openAnother.
  ///
  /// In en, this message translates to:
  /// **'Open another…'**
  String get openAnother;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'Same as the system'**
  String get languageSystem;

  /// No description provided for @resumeName.
  ///
  /// In en, this message translates to:
  /// **'Your Full Name'**
  String get resumeName;

  /// No description provided for @resumeContact.
  ///
  /// In en, this message translates to:
  /// **'City, State · (000) 000-0000 · youremail@example.com'**
  String get resumeContact;

  /// No description provided for @resumeObjective.
  ///
  /// In en, this message translates to:
  /// **'Objective'**
  String get resumeObjective;

  /// No description provided for @resumeObjectiveText.
  ///
  /// In en, this message translates to:
  /// **'Describe in one or two sentences the job or the field you want to work in.'**
  String get resumeObjectiveText;

  /// No description provided for @resumeExperience.
  ///
  /// In en, this message translates to:
  /// **'Experience'**
  String get resumeExperience;

  /// No description provided for @resumeRole.
  ///
  /// In en, this message translates to:
  /// **'Job title — Company'**
  String get resumeRole;

  /// No description provided for @resumePeriod.
  ///
  /// In en, this message translates to:
  /// **'Month/Year – Month/Year'**
  String get resumePeriod;

  /// No description provided for @resumeAchievement.
  ///
  /// In en, this message translates to:
  /// **'Main result or responsibility.'**
  String get resumeAchievement;

  /// No description provided for @resumeOtherAchievement.
  ///
  /// In en, this message translates to:
  /// **'Another achievement, ideally with numbers.'**
  String get resumeOtherAchievement;

  /// No description provided for @resumeEducation.
  ///
  /// In en, this message translates to:
  /// **'Education'**
  String get resumeEducation;

  /// No description provided for @resumeCourse.
  ///
  /// In en, this message translates to:
  /// **'Degree — School'**
  String get resumeCourse;

  /// No description provided for @resumeGraduation.
  ///
  /// In en, this message translates to:
  /// **'Year of completion'**
  String get resumeGraduation;

  /// No description provided for @resumeSkills.
  ///
  /// In en, this message translates to:
  /// **'Skills'**
  String get resumeSkills;

  /// No description provided for @resumeSkill.
  ///
  /// In en, this message translates to:
  /// **'Technical skill or tool'**
  String get resumeSkill;

  /// No description provided for @resumeLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language and level'**
  String get resumeLanguage;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'pt':
      return AppLocalizationsPt();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
