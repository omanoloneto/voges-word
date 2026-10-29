import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'updater_localizations_en.dart';
import 'updater_localizations_es.dart';
import 'updater_localizations_pt.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of UpdaterLocalizations
/// returned by `UpdaterLocalizations.of(context)`.
///
/// Applications need to include `UpdaterLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/updater_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: UpdaterLocalizations.localizationsDelegates,
///   supportedLocales: UpdaterLocalizations.supportedLocales,
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
/// be consistent with the languages listed in the UpdaterLocalizations.supportedLocales
/// property.
abstract class UpdaterLocalizations {
  UpdaterLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static UpdaterLocalizations of(BuildContext context) {
    return Localizations.of<UpdaterLocalizations>(
      context,
      UpdaterLocalizations,
    )!;
  }

  static const LocalizationsDelegate<UpdaterLocalizations> delegate =
      _UpdaterLocalizationsDelegate();

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

  /// Status bar, while the app checks for a new version.
  ///
  /// In en, this message translates to:
  /// **'Checking for updates…'**
  String get updateChecking;

  /// Status bar, when the app runs the latest version.
  ///
  /// In en, this message translates to:
  /// **'Up to date'**
  String get updateUpToDate;

  /// Tooltip of the status bar when the app runs the latest version.
  ///
  /// In en, this message translates to:
  /// **'{app} {version} is the latest version. Click to check again.'**
  String updateUpToDateTooltip(String app, String version);

  /// Status bar button that closes the app and opens Voges Updater.
  ///
  /// In en, this message translates to:
  /// **'Update to {version}'**
  String updateAvailable(String version);

  /// Tooltip of the status bar button that opens Voges Updater.
  ///
  /// In en, this message translates to:
  /// **'{app} closes and Voges Updater installs version {version}.'**
  String updateAvailableTooltip(String app, String version);

  /// Status bar, while the app starts Voges Updater.
  ///
  /// In en, this message translates to:
  /// **'Opening the updater…'**
  String get updateOpening;

  /// Status bar, when a new version exists but this copy can't update itself. Opens the download page.
  ///
  /// In en, this message translates to:
  /// **'Version {version} available'**
  String updateDownloadAvailable(String version);

  /// Tooltip when this copy wasn't installed with the suite's installers.
  ///
  /// In en, this message translates to:
  /// **'Download the new version from the website.'**
  String get updateDownloadTooltip;

  /// macOS tooltip, when the app runs from a disk image or from a translocated folder.
  ///
  /// In en, this message translates to:
  /// **'To update {app} from here, move it to the Applications folder and open it again.'**
  String updateMoveToApplications(String app);

  /// Status bar, when the version check failed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t check for updates'**
  String get updateCheckFailed;

  /// Tooltip of the status bar when the version check failed.
  ///
  /// In en, this message translates to:
  /// **'Click to try again.'**
  String get updateCheckFailedTooltip;

  /// Message when Voges Updater didn't start.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open the updater.'**
  String get updateLaunchFailed;

  /// Button that opens the app's download page on the website.
  ///
  /// In en, this message translates to:
  /// **'Download page'**
  String get updateDownloadPage;

  /// Voges Updater: title of the list of updates.
  ///
  /// In en, this message translates to:
  /// **'Updates for your Voges apps'**
  String get updaterHeading;

  /// Voges Updater: the app that opened the updater was closed.
  ///
  /// In en, this message translates to:
  /// **'{app} was closed to install updates. It opens again when you\'re done.'**
  String updaterHostClosed(String app);

  /// Voges Updater: while it checks for new versions.
  ///
  /// In en, this message translates to:
  /// **'Looking for updates…'**
  String get updaterChecking;

  /// Voges Updater: checkbox that selects every update of the list.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get updaterSelectAll;

  /// Voges Updater: the installed version and the new version of an app.
  ///
  /// In en, this message translates to:
  /// **'{from} → {to}'**
  String updaterVersionChange(String from, String to);

  /// Voges Updater: link to the release notes of the new version.
  ///
  /// In en, this message translates to:
  /// **'What\'s new'**
  String get updaterWhatsNew;

  /// Windows: a copy installed only for the current user.
  ///
  /// In en, this message translates to:
  /// **'For this user'**
  String get updaterForThisUser;

  /// Windows: a copy installed for every user of the computer.
  ///
  /// In en, this message translates to:
  /// **'For all users · asks for administrator permission'**
  String get updaterForAllUsers;

  /// Voges Updater: closes without updating.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get updaterNotNow;

  /// Voges Updater: installs the selected updates.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Update 1 app} other{Update {count} apps}}'**
  String updaterUpdateButton(int count);

  /// Voges Updater: no app has a new version.
  ///
  /// In en, this message translates to:
  /// **'All your Voges apps are up to date.'**
  String get updaterAllUpToDate;

  /// Voges Updater: every version check failed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t check for updates. Check your internet connection.'**
  String get updaterOffline;

  /// Voges Updater: the app that opened the updater isn't among the installed apps.
  ///
  /// In en, this message translates to:
  /// **'Voges Updater couldn\'t find where {app} is installed. Download the new version from the website.'**
  String updaterHostNotFound(String app);

  /// Voges Updater: an app whose version check failed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t check for updates'**
  String get updaterRowCheckFailed;

  /// Voges Updater: repeats what failed.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get updaterTryAgain;

  /// Voges Updater: shown while the apps to update are still open.
  ///
  /// In en, this message translates to:
  /// **'Save your work and close these apps. The update continues by itself once they\'re closed.'**
  String get updaterCloseApps;

  /// Voges Updater: an app that is still open, and how many windows it has.
  ///
  /// In en, this message translates to:
  /// **'{app} · {count, plural, =1{1 window} other{{count} windows}}'**
  String updaterOpenWindows(String app, int count);

  /// Voges Updater: an app that is open in another user account of the computer.
  ///
  /// In en, this message translates to:
  /// **'{app} · open in another user account'**
  String updaterOtherAccount(String app);

  /// Voges Updater: download progress of an app.
  ///
  /// In en, this message translates to:
  /// **'Downloading… {percent}%'**
  String updaterDownloading(int percent);

  /// Voges Updater: while it checks the signature and the checksum of a download.
  ///
  /// In en, this message translates to:
  /// **'Checking the download…'**
  String get updaterVerifying;

  /// Voges Updater: while an app is installed.
  ///
  /// In en, this message translates to:
  /// **'Installing…'**
  String get updaterInstalling;

  /// Windows: while the installer waits for the administrator prompt.
  ///
  /// In en, this message translates to:
  /// **'Confirm the administrator prompt. If you don\'t see it, look for it on the taskbar.'**
  String get updaterAdminHint;

  /// Linux: while the system asks for the password.
  ///
  /// In en, this message translates to:
  /// **'Type your password in the window that opened.'**
  String get updaterPasswordHint;

  /// Voges Updater: an app that was updated.
  ///
  /// In en, this message translates to:
  /// **'Updated to {version}'**
  String updaterUpdated(String version);

  /// Voges Updater: stops the download or the wait and goes back to the list.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get updaterCancel;

  /// Voges Updater: closes the updater.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get updaterClose;

  /// Voges Updater: closes the updater and opens the app that opened it.
  ///
  /// In en, this message translates to:
  /// **'Open {app}'**
  String updaterOpenApp(String app);

  /// Voges Updater: another updater is running.
  ///
  /// In en, this message translates to:
  /// **'Voges Updater is already open in another window.'**
  String get updaterAlreadyRunning;

  /// Voges Updater: a download failed.
  ///
  /// In en, this message translates to:
  /// **'The download failed. Check your internet connection and try again.'**
  String get updaterErrorNetwork;

  /// Voges Updater: the signature, the checksum or the identity of a download didn't match.
  ///
  /// In en, this message translates to:
  /// **'The download couldn\'t be verified, so nothing was installed. Try again later.'**
  String get updaterErrorVerification;

  /// Voges Updater: the release has no installer for this system.
  ///
  /// In en, this message translates to:
  /// **'Version {version} isn\'t available for this system yet.'**
  String updaterErrorUnavailable(String version);

  /// macOS: the app's folder can't be changed by this user.
  ///
  /// In en, this message translates to:
  /// **'macOS didn\'t allow replacing {app}. Install it with the installer.'**
  String updaterErrorPermission(String app);

  /// Voges Updater: the app was still open when it had to be replaced.
  ///
  /// In en, this message translates to:
  /// **'{app} or one of its files was still in use. Close it and try again.'**
  String updaterErrorInUse(String app);

  /// Voges Updater: the administrator or password prompt was dismissed.
  ///
  /// In en, this message translates to:
  /// **'Permission wasn\'t given, so nothing was installed.'**
  String get updaterErrorDeclined;

  /// Linux: no password window is available; a command follows.
  ///
  /// In en, this message translates to:
  /// **'This system can\'t show a password window. Install the update from a terminal:'**
  String get updaterErrorNoPasswordWindow;

  /// Linux: the account may not install software; a command follows.
  ///
  /// In en, this message translates to:
  /// **'Your account can\'t install apps. Ask an administrator to run:'**
  String get updaterErrorNotAuthorized;

  /// Linux: apt refused the package; its error follows.
  ///
  /// In en, this message translates to:
  /// **'The package manager couldn\'t install the update:'**
  String get updaterErrorPackageManager;

  /// Voges Updater: the installer failed with this exit code.
  ///
  /// In en, this message translates to:
  /// **'The update failed (code {code}).'**
  String updaterErrorFailed(int code);

  /// Voges Updater: the update failed with no exit code.
  ///
  /// In en, this message translates to:
  /// **'The update failed.'**
  String get updaterErrorUnknown;

  /// Linux: the downloaded files are deleted when the window closes.
  ///
  /// In en, this message translates to:
  /// **'Keep this window open until the command finishes.'**
  String get updaterKeepOpen;

  /// Linux: copies the install command.
  ///
  /// In en, this message translates to:
  /// **'Copy command'**
  String get updaterCopyCommand;

  /// macOS: copies the verified disk image to Downloads and opens it.
  ///
  /// In en, this message translates to:
  /// **'Open the installer'**
  String get updaterOpenInstaller;

  /// Windows: opens the installer's log.
  ///
  /// In en, this message translates to:
  /// **'Show log'**
  String get updaterShowLog;
}

class _UpdaterLocalizationsDelegate
    extends LocalizationsDelegate<UpdaterLocalizations> {
  const _UpdaterLocalizationsDelegate();

  @override
  Future<UpdaterLocalizations> load(Locale locale) {
    return SynchronousFuture<UpdaterLocalizations>(
      lookupUpdaterLocalizations(locale),
    );
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_UpdaterLocalizationsDelegate old) => false;
}

UpdaterLocalizations lookupUpdaterLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return UpdaterLocalizationsEn();
    case 'es':
      return UpdaterLocalizationsEs();
    case 'pt':
      return UpdaterLocalizationsPt();
  }

  throw FlutterError(
    'UpdaterLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
