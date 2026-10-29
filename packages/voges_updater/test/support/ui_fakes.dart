import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:voges_updater/voges_updater.dart';

/// A second suite app, so lists can hold more than one app.
const vogesSheets = SuiteApp(
  name: 'Voges Sheets',
  repository: 'omanoloneto/voges-sheets',
  downloadPage: 'https://omanoloneto.pro/voges/sheets/',
  macos: MacosTarget(
    bundleId: 'com.omanoloneto.vogesSheets',
    bundleName: 'Voges Sheets.app',
    asset: 'VogesSheets-macos.dmg',
  ),
  windows: WindowsTarget(
    appId: '{00000000-0000-0000-0000-000000000001}',
    executable: 'voges_sheets.exe',
    asset: 'VogesSheets-windows-setup.exe',
  ),
  linux: LinuxTarget(
    package: 'voges-sheets',
    binary: '/usr/lib/voges-sheets/voges_sheets',
    launcher: '/usr/bin/voges-sheets',
    asset: 'voges-sheets-linux-amd64.deb',
  ),
);

const wordHost = UpdaterHost(
  app: vogesWord,
  reopenPath: '/Applications/Voges Word.app',
);

ReleaseVersion version(String text) => ReleaseVersion.tryParse(text)!;

InstalledCopy installedCopy(
  SuiteApp app,
  String installed, {
  InstallScope scope = InstallScope.user,
  String? location,
}) => InstalledCopy(
  app: app,
  version: version(installed),
  location: location ?? '/Applications/${app.macos.bundleName}',
  scope: scope,
  isHost: app == vogesWord,
);

typedef InstallHandler =
    Future<List<InstallOutcome>> Function(
      List<PendingInstall> items,
      void Function(PendingInstall item, InstallStep step) onStep,
    );

class FakePlatform implements SuitePlatform {
  FakePlatform(this.copies);

  List<InstalledCopy> copies;
  UpdaterHost? hostResult = wordHost;
  Object? installedError;

  /// Each check of the open apps takes the next answer; the last one repeats.
  List<List<RunningApp>> runningAnswers = [const []];
  var runningChecks = 0;
  var hostChecks = 0;

  /// Installs everything when null.
  InstallHandler? onInstall;

  final installs = <List<PendingInstall>>[];
  final finished = <UpdaterHost?>[];
  final fallbacks = <UpdateFailure>[];
  final cleaned = <Directory>[];
  final work = Directory('/nonexistent/voges-update-test');

  @override
  String assetOf(SuiteApp app) => app.macos.asset;

  @override
  Future<UpdaterHost?> host() async {
    hostChecks++;
    return hostResult;
  }

  @override
  Future<Directory> workDirectory() async => work;

  @override
  Future<void> cleanStale(Directory current) async => cleaned.add(current);

  @override
  Future<List<InstalledCopy>> installed(
    List<SuiteApp> catalog,
    UpdaterHost? host,
  ) async {
    if (installedError case final error?) throw error;
    return copies;
  }

  @override
  Future<List<RunningApp>> running(List<InstalledCopy> copies) async {
    final answer =
        runningAnswers[math.min(runningChecks, runningAnswers.length - 1)];
    runningChecks++;
    return answer;
  }

  @override
  Future<List<InstallOutcome>> install(
    List<PendingInstall> items,
    void Function(PendingInstall item, InstallStep step) onStep,
  ) {
    installs.add(items);
    return onInstall?.call(items, onStep) ??
        Future.value([for (final item in items) Installed(item, item.version)]);
  }

  @override
  Future<void> openFallback(UpdateFailure failure) async =>
      fallbacks.add(failure);

  @override
  void finishSync(UpdaterHost? host) => finished.add(host);
}

class FakeFeed implements ReleaseFeed {
  FakeFeed(this.versions);

  /// Repository to its latest version; a missing one fails like the network.
  final Map<String, ReleaseVersion> versions;
  final checks = <String>[];

  @override
  Future<ReleaseVersion> latest(String repository) async {
    checks.add(repository);
    final latest = versions[repository];
    if (latest == null) throw const UpdateFailure(UpdateFailureKind.network);
    return latest;
  }
}

final class FetchCall {
  FetchCall(this.app, this.version, this.onProgress, this.isCancelled);

  final SuiteApp app;
  final ReleaseVersion version;
  final void Function(double progress)? onProgress;
  final bool Function()? isCancelled;
  final _result = Completer<VerifiedAsset>();

  late final asset = VerifiedAsset(
    file: File('/nonexistent/${app.macos.asset}'),
    sha256: '0' * 64,
  );

  void succeed() => _result.complete(asset);

  void fail(Object error) => _result.completeError(error);
}

class FakeDownloader implements UpdateDownloader {
  FakeDownloader({this.manual = false});

  /// When true, each download waits for [FetchCall.succeed] or
  /// [FetchCall.fail]; otherwise it ends at once.
  final bool manual;

  /// Repository to the error its downloads end with, when not manual.
  final errors = <String, Object>{};
  final calls = <FetchCall>[];

  @override
  Future<VerifiedAsset> fetch(
    SuiteApp app,
    ReleaseVersion version,
    String asset,
    Directory into, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) {
    final call = FetchCall(app, version, onProgress, isCancelled);
    calls.add(call);
    if (!manual) {
      final error = errors[app.repository];
      error == null ? call.succeed() : call.fail(error);
    }
    return call._result.future;
  }
}

class FakeLauncher implements UpdaterLauncher {
  FakeLauncher([this.availability = LaunchAvailability.here]);

  @override
  final LaunchAvailability availability;

  /// Launches never end, so the indicator stays on "opening".
  final launches = <Completer<LaunchResult>>[];

  @override
  Future<LaunchResult> launch() {
    final launch = Completer<LaunchResult>();
    launches.add(launch);
    return launch.future;
  }

  @override
  Future<void> cleanUp() async {}
}

/// An updater session over fakes, with what it did on the way out.
class UiHarness {
  UiHarness({
    List<InstalledCopy>? copies,
    Map<SuiteApp, String> latest = const {vogesWord: '1.2.0'},
    bool locked = false,
    String operatingSystem = 'macos',
    bool manualDownloads = false,
  }) : platform = FakePlatform(copies ?? [installedCopy(vogesWord, '1.1.0')]),
       feed = FakeFeed({
         for (final MapEntry(key: app, value: text) in latest.entries)
           app.repository: version(text),
       }),
       downloader = FakeDownloader(manual: manualDownloads) {
    session = UpdaterSession(
      platform: platform,
      feed: feed,
      downloader: downloader,
      catalog: const [vogesWord, vogesSheets],
      operatingSystem: operatingSystem,
      acquireLock: () async => locked ? null : Object(),
      openUrl: (url) async {
        opened.add(url);
        return true;
      },
      exit: exits.add,
    );
  }

  final FakePlatform platform;
  final FakeFeed feed;
  final FakeDownloader downloader;
  final exits = <int>[];
  final opened = <Uri>[];
  late final UpdaterSession session;

  UpdateRow row(SuiteApp app, [InstallScope scope = InstallScope.user]) =>
      session.rows.singleWhere(
        (row) => row.app == app && row.copy.scope == scope,
      );
}
