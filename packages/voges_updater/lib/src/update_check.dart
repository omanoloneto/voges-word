import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'catalog.dart';
import 'github_releases.dart';
import 'macos_updater_launcher.dart';
import 'release_version.dart';
import 'updater_launcher.dart';

sealed class UpdateStatus {
  const UpdateStatus();
}

/// No indicator: mobile, web and builds without a version.
final class UpdateHidden extends UpdateStatus {
  const UpdateHidden();
}

final class UpdateChecking extends UpdateStatus {
  const UpdateChecking();
}

final class UpToDate extends UpdateStatus {
  const UpToDate(this.version);

  final ReleaseVersion version;
}

final class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable(this.version, this.availability);

  final ReleaseVersion version;
  final LaunchAvailability availability;
}

/// The updater is being started; the app closes once it is.
final class UpdaterOpening extends UpdateStatus {
  const UpdaterOpening(this.version);

  final ReleaseVersion version;
}

final class UpdateCheckFailed extends UpdateStatus {
  const UpdateCheckFailed();
}

/// Checks, when the app opens, whether a newer version of [app] exists, and
/// opens the updater when the user asks for it.
class UpdateCheck extends ChangeNotifier {
  UpdateCheck({
    required this.app,
    required this.current,
    required ReleaseFeed feed,
    required UpdaterLauncher launcher,
    Future<bool> Function(Uri url)? openUrl,
  }) : _feed = feed,
       _launcher = launcher,
       _openUrl = openUrl ?? launchUrl,
       _status = current == null
           ? const UpdateHidden()
           : const UpdateChecking();

  /// The check for this system; hidden off the desktop and when the build
  /// has no `VOGES_VERSION`.
  factory UpdateCheck.forPlatform(
    SuiteApp app, {
    String version = const String.fromEnvironment('VOGES_VERSION'),
  }) {
    final desktop =
        !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
    final current = desktop ? ReleaseVersion.tryParse(version) : null;
    return UpdateCheck(
      app: app,
      current: current,
      feed: current == null ? const _NoFeed() : GitHubReleases.production(),
      launcher: current == null
          ? const _NoLauncher()
          : platformUpdaterLauncher(app),
    );
  }

  final SuiteApp app;

  /// The running version; null hides the indicator.
  final ReleaseVersion? current;

  final ReleaseFeed _feed;
  final UpdaterLauncher _launcher;
  final Future<bool> Function(Uri url) _openUrl;

  UpdateStatus _status;
  UpdateStatus get status => _status;
  var _checking = false;

  set _state(UpdateStatus value) {
    _status = value;
    notifyListeners();
  }

  Future<void> check() async {
    final current = this.current;
    if (current == null || _checking || _status is UpdaterOpening) return;
    _checking = true;
    _state = const UpdateChecking();
    try {
      final latest = await _feed.latest(app.repository);
      _state = latest.isNewerThan(current)
          ? UpdateAvailable(latest, _launcher.availability)
          : UpToDate(current);
    } catch (_) {
      _state = const UpdateCheckFailed();
    } finally {
      _checking = false;
    }
  }

  /// Opens the updater for an available update; the caller closes the app
  /// when this returns [LaunchResult.started].
  Future<LaunchResult> startUpdater() async {
    final status = _status;
    if (status is! UpdateAvailable ||
        status.availability != LaunchAvailability.here) {
      return LaunchResult.failed;
    }
    _state = UpdaterOpening(status.version);
    final LaunchResult result;
    try {
      result = await _launcher.launch();
    } catch (_) {
      _state = status;
      return LaunchResult.failed;
    }
    if (result != LaunchResult.started) _state = status;
    return result;
  }

  Future<void> openDownloadPage() async {
    try {
      await _openUrl(Uri.parse(app.downloadPage));
    } catch (_) {
      // no browser configured: nothing else to try
    }
  }

  Future<void> cleanUp() async {
    if (current == null) return;
    try {
      await _launcher.cleanUp();
    } catch (_) {
      // leftovers only: the next start tries again
    }
  }
}

final class _NoFeed implements ReleaseFeed {
  const _NoFeed();

  @override
  Future<ReleaseVersion> latest(String repository) =>
      throw UnsupportedError('no updates here');
}

final class _NoLauncher implements UpdaterLauncher {
  const _NoLauncher();

  @override
  LaunchAvailability get availability => LaunchAvailability.download;

  @override
  Future<LaunchResult> launch() async => LaunchResult.failed;

  @override
  Future<void> cleanUp() async {}
}
