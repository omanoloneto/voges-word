// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'updater_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class UpdaterLocalizationsEn extends UpdaterLocalizations {
  UpdaterLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get updateChecking => 'Checking for updates…';

  @override
  String get updateUpToDate => 'Up to date';

  @override
  String updateUpToDateTooltip(String app, String version) {
    return '$app $version is the latest version. Click to check again.';
  }

  @override
  String updateAvailable(String version) {
    return 'Update to $version';
  }

  @override
  String updateAvailableTooltip(String app, String version) {
    return '$app closes and Voges Updater installs version $version.';
  }

  @override
  String get updateOpening => 'Opening the updater…';

  @override
  String updateDownloadAvailable(String version) {
    return 'Version $version available';
  }

  @override
  String get updateDownloadTooltip =>
      'Download the new version from the website.';

  @override
  String updateMoveToApplications(String app) {
    return 'To update $app from here, move it to the Applications folder and open it again.';
  }

  @override
  String get updateCheckFailed => 'Couldn\'t check for updates';

  @override
  String get updateCheckFailedTooltip => 'Click to try again.';

  @override
  String get updateLaunchFailed => 'Couldn\'t open the updater.';

  @override
  String get updateDownloadPage => 'Download page';

  @override
  String get updaterHeading => 'Updates for your Voges apps';

  @override
  String updaterHostClosed(String app) {
    return '$app was closed to install updates. It opens again when you\'re done.';
  }

  @override
  String get updaterChecking => 'Looking for updates…';

  @override
  String get updaterSelectAll => 'Select all';

  @override
  String updaterVersionChange(String from, String to) {
    return '$from → $to';
  }

  @override
  String get updaterWhatsNew => 'What\'s new';

  @override
  String get updaterForThisUser => 'For this user';

  @override
  String get updaterForAllUsers =>
      'For all users · asks for administrator permission';

  @override
  String get updaterNotNow => 'Not now';

  @override
  String updaterUpdateButton(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Update $count apps',
      one: 'Update 1 app',
    );
    return '$_temp0';
  }

  @override
  String get updaterAllUpToDate => 'All your Voges apps are up to date.';

  @override
  String get updaterOffline =>
      'Couldn\'t check for updates. Check your internet connection.';

  @override
  String updaterHostNotFound(String app) {
    return 'Voges Updater couldn\'t find where $app is installed. Download the new version from the website.';
  }

  @override
  String get updaterRowCheckFailed => 'Couldn\'t check for updates';

  @override
  String get updaterTryAgain => 'Try again';

  @override
  String get updaterCloseApps =>
      'Save your work and close these apps. The update continues by itself once they\'re closed.';

  @override
  String updaterOpenWindows(String app, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count windows',
      one: '1 window',
    );
    return '$app · $_temp0';
  }

  @override
  String updaterOtherAccount(String app) {
    return '$app · open in another user account';
  }

  @override
  String updaterDownloading(int percent) {
    return 'Downloading… $percent%';
  }

  @override
  String get updaterVerifying => 'Checking the download…';

  @override
  String get updaterInstalling => 'Installing…';

  @override
  String get updaterAdminHint =>
      'Confirm the administrator prompt. If you don\'t see it, look for it on the taskbar.';

  @override
  String get updaterPasswordHint =>
      'Type your password in the window that opened.';

  @override
  String updaterUpdated(String version) {
    return 'Updated to $version';
  }

  @override
  String get updaterCancel => 'Cancel';

  @override
  String get updaterClose => 'Close';

  @override
  String updaterOpenApp(String app) {
    return 'Open $app';
  }

  @override
  String get updaterAlreadyRunning =>
      'Voges Updater is already open in another window.';

  @override
  String get updaterErrorNetwork =>
      'The download failed. Check your internet connection and try again.';

  @override
  String get updaterErrorVerification =>
      'The download couldn\'t be verified, so nothing was installed. Try again later.';

  @override
  String updaterErrorUnavailable(String version) {
    return 'Version $version isn\'t available for this system yet.';
  }

  @override
  String updaterErrorPermission(String app) {
    return 'macOS didn\'t allow replacing $app. Install it with the installer.';
  }

  @override
  String updaterErrorInUse(String app) {
    return '$app or one of its files was still in use. Close it and try again.';
  }

  @override
  String get updaterErrorDeclined =>
      'Permission wasn\'t given, so nothing was installed.';

  @override
  String get updaterErrorNoPasswordWindow =>
      'This system can\'t show a password window. Install the update from a terminal:';

  @override
  String get updaterErrorNotAuthorized =>
      'Your account can\'t install apps. Ask an administrator to run:';

  @override
  String get updaterErrorPackageManager =>
      'The package manager couldn\'t install the update:';

  @override
  String updaterErrorFailed(int code) {
    return 'The update failed (code $code).';
  }

  @override
  String get updaterErrorUnknown => 'The update failed.';

  @override
  String get updaterKeepOpen =>
      'Keep this window open until the command finishes.';

  @override
  String get updaterCopyCommand => 'Copy command';

  @override
  String get updaterOpenInstaller => 'Open the installer';

  @override
  String get updaterShowLog => 'Show log';
}
