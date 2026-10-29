import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'process_runner.dart';
import 'release_downloader.dart';
import 'release_version.dart';
import 'suite_platform.dart';
import 'update_failure.dart';

/// Whether [bundle] runs from a mounted volume, such as the disk image, or
/// from a translocated copy: read-only places that cannot be updated.
bool isTranslocatedOrOnVolume(String bundle) =>
    bundle.contains('/AppTranslocation/') || bundle.startsWith('/Volumes/');

typedef _Process = ({int pid, int uid, String command});

/// macOS: the Voges Updater helper embedded in a suite app. It finds the
/// suite apps in the Applications folders and replaces whole bundles.
final class MacosPlatform implements SuitePlatform {
  MacosPlatform({
    this.runner = const SystemProcessRunner(),
    this.catalog = vogesSuite,
    String? executable,
    int? ownPid,
    Map<String, String>? environment,
    this.applications = '/Applications',
    Directory? temp,
  }) : executable = executable ?? Platform.resolvedExecutable,
       ownPid = ownPid ?? pid,
       home = (environment ?? Platform.environment)['HOME'],
       temp = temp ?? Directory.systemTemp;

  final ProcessRunner runner;

  /// The apps that may embed this helper.
  final List<SuiteApp> catalog;

  /// This helper's executable, inside the bundle of the app that embeds it.
  final String executable;
  final int ownPid;
  final String? home;

  /// The system's Applications folder.
  final String applications;

  /// The user's private temporary folder (`$TMPDIR`).
  final Directory temp;

  static const _plutil = '/usr/bin/plutil';
  static const _ps = '/bin/ps';
  static const _env = '/usr/bin/env';
  static const _stat = '/usr/bin/stat';
  static const _id = '/usr/bin/id';
  static const _hdiutil = '/usr/bin/hdiutil';
  static const _ditto = '/usr/bin/ditto';
  static const _codesign = '/usr/bin/codesign';
  static const _xattr = '/usr/bin/xattr';
  static const _open = '/usr/bin/open';

  static const _helperPath =
      '/Contents/Helpers/Voges Updater.app/Contents/MacOS/Voges Updater';
  static final _processLine = RegExp(r'^\s*(\d+)\s+(\d+)\s+(.+)$');
  static final _staleStaging = RegExp(r'^\.voges-update-[A-Za-z0-9]+(\.old)?$');
  static final _staleWork = RegExp(r'^voges-update-[A-Za-z0-9]+$');
  static const _eperm = 1;
  static const _eacces = 13;

  /// The main executable of each bundle found, as `ps` shows it.
  final _executables = <String, String>{};

  /// Folders holding this helper's old bundle, deleted by [finishSync].
  final _deferred = <String>[];
  final _work = <Directory>[];
  var _mounts = 0;
  int? _userId;

  /// The suite app around this helper, from the helper's own path.
  String? get _hostBundle {
    if (!executable.endsWith(_helperPath)) return null;
    final bundle = executable.substring(
      0,
      executable.length - _helperPath.length,
    );
    return bundle.endsWith('.app') ? bundle : null;
  }

  @override
  String assetOf(SuiteApp app) => app.macos.asset;

  @override
  Future<UpdaterHost?> host() async {
    final bundle = _hostBundle;
    if (bundle == null || !_isRealDirectory(bundle)) return null;
    final plist = await _infoPlist(bundle);
    for (final app in catalog) {
      if (plist?['CFBundleIdentifier'] == app.macos.bundleId) {
        return UpdaterHost(app: app, reopenPath: bundle);
      }
    }
    return null;
  }

  @override
  Future<Directory> workDirectory() async {
    final work = await temp.createTemp('voges-update-');
    _work.add(work);
    return work;
  }

  @override
  Future<void> cleanStale(Directory current) async {
    for (final entry in _entries(temp.path)) {
      if (_staleWork.hasMatch(p.basename(entry)) &&
          !p.equals(entry, current.path)) {
        _deleteTree(entry);
      }
    }
    final List<_Process> processes;
    try {
      processes = await _processes();
    } on UpdateFailure {
      return;
    }
    final home = this.home;
    final hostBundle = _hostBundle;
    final folders = {
      applications,
      if (home != null) p.join(home, 'Applications'),
      if (hostBundle != null) p.dirname(hostBundle),
    };
    for (final folder in folders) {
      for (final entry in _entries(_resolve(folder) ?? folder)) {
        final inUse = processes.any(
          (process) => p.isWithin(entry, process.command),
        );
        if (_staleStaging.hasMatch(p.basename(entry)) && !inUse) {
          _deleteTree(entry);
        }
      }
    }
  }

  @override
  Future<List<InstalledCopy>> installed(
    List<SuiteApp> catalog,
    UpdaterHost? host,
  ) async {
    final home = this.home;
    final hostBundle = host == null ? null : _resolve(host.reopenPath);
    final seen = <String>{};
    final copies = <InstalledCopy>[];
    for (final app in catalog) {
      final candidates = [
        if (host != null && host.app.macos.bundleId == app.macos.bundleId)
          host.reopenPath,
        p.join(applications, app.macos.bundleName),
        if (home != null) p.join(home, 'Applications', app.macos.bundleName),
      ];
      for (final candidate in candidates) {
        final bundle = _isRealDirectory(candidate) ? _resolve(candidate) : null;
        if (bundle == null ||
            isTranslocatedOrOnVolume(bundle) ||
            !seen.add(bundle)) {
          continue;
        }
        final info = await _readBundle(bundle, app);
        if (info == null) continue;
        _executables[bundle] = info.executable;
        copies.add(
          InstalledCopy(
            app: app,
            version: info.version,
            location: bundle,
            isHost: bundle == hostBundle,
          ),
        );
      }
    }
    return copies;
  }

  @override
  Future<List<RunningApp>> running(List<InstalledCopy> copies) async {
    final processes = await _processes();
    final userId = await _ownUserId();
    final found = <RunningApp>[];
    for (final copy in copies) {
      final executable = await _mainExecutable(copy);
      for (final process in processes) {
        if (process.pid != ownPid && process.command == executable) {
          found.add(
            RunningApp(
              app: copy.app,
              pid: process.pid,
              otherAccount: process.uid != userId,
            ),
          );
        }
      }
    }
    return found;
  }

  @override
  Future<List<InstallOutcome>> install(
    List<PendingInstall> items,
    void Function(PendingInstall item, InstallStep step) onStep,
  ) async {
    final outcomes = <InstallOutcome>[];
    for (final item in items) {
      onStep(item, InstallStep.installing);
      try {
        outcomes.add(Installed(item, await _install(item)));
      } on UpdateFailure catch (failure) {
        outcomes.add(NotInstalled(item, failure));
      } on Exception catch (error) {
        final failure = UpdateFailure(
          UpdateFailureKind.failed,
          detail: '$error',
        );
        outcomes.add(NotInstalled(item, failure));
      }
    }
    return outcomes;
  }

  @override
  Future<void> openFallback(UpdateFailure failure) async {
    final installer = failure.installer;
    final home = this.home;
    if (installer == null) return;
    var opened = installer;
    try {
      if (home == null) throw const FileSystemException('no home folder');
      final downloads = await Directory(
        p.join(home, 'Downloads'),
      ).create(recursive: true);
      final copy = await File(
        installer,
      ).copy(_freePath(downloads.path, p.basename(installer)));
      opened = copy.path;
    } on FileSystemException {
      // the user may deny access to Downloads: the disk image still opens
      // from the work folder, and stays mounted after that folder is gone
    }
    await _run(_open, [opened]);
  }

  @override
  void finishSync(UpdaterHost? host) {
    if (host != null) {
      try {
        runner.runSync(_open, [host.reopenPath]);
      } catch (_) {
        // the update is over either way; the user can open the app
      }
    }
    for (final path in [..._deferred, for (final work in _work) work.path]) {
      _deleteTree(path);
    }
  }

  /// Stages the new bundle beside the target and swaps the two by renaming,
  /// which needs write access to the parent folder only.
  Future<ReleaseVersion> _install(PendingInstall item) async {
    final app = item.copy.app;
    final target = item.copy.location;
    await _requireOwnBundle(target, item.asset);
    final staging = await _stagingFolder(p.dirname(target), item.asset);
    final staged = p.join(staging.path, app.macos.bundleName);
    final old = '${staging.path}.old';
    try {
      await _stage(item, staged);
      if (await _isRunning(item.copy)) {
        throw const UpdateFailure(UpdateFailureKind.inUse);
      }
      _swap(target, staged, old, item.asset);
    } catch (_) {
      _deleteTree(staging.path);
      rethrow;
    }
    if (p.isWithin(target, executable)) {
      // the engine survives its bundle being renamed, not being deleted
      _deferred.addAll([staging.path, old]);
    } else {
      _deleteTree(staging.path);
      _deleteTree(old);
    }
    _executables.remove(target);
    final info = await _readBundle(target, app);
    if (info == null || info.version != item.version) {
      throw UpdateFailure(
        UpdateFailureKind.failed,
        detail: 'version after install: ${info?.version}',
      );
    }
    _executables[target] = info.executable;
    return info.version;
  }

  /// The old bundle could be renamed aside but not deleted when another
  /// account owns it; Finder asks for that account's permission instead.
  Future<void> _requireOwnBundle(String target, VerifiedAsset asset) async {
    final owner = int.tryParse(
      '${(await _run(_stat, ['-f', '%u', target])).stdout}'.trim(),
    );
    if (owner != await _ownUserId()) {
      throw UpdateFailure(
        UpdateFailureKind.permission,
        detail: '$target belongs to user $owner',
        installer: asset.file.path,
      );
    }
  }

  Future<Directory> _stagingFolder(String parent, VerifiedAsset asset) async {
    try {
      return await Directory(parent).createTemp('.voges-update-');
    } on FileSystemException catch (error) {
      throw _fileFailure(error, asset);
    }
  }

  Future<void> _stage(PendingInstall item, String staged) async {
    await item.asset.recheck();
    final mount = await _mountPoint();
    await _run(_hdiutil, [
      'attach',
      '-nobrowse',
      '-readonly',
      '-noautoopen',
      '-mountpoint',
      mount,
      item.asset.file.path,
    ]);
    try {
      final source = p.join(mount, item.copy.app.macos.bundleName);
      if (!_isRealDirectory(source)) {
        throw const UpdateFailure(
          UpdateFailureKind.verification,
          detail: 'the disk image has no app folder',
        );
      }
      await _run(_ditto, [source, staged]);
    } finally {
      await _detach(mount);
    }
    await _verify(item, staged);
  }

  /// The staged copy must be the catalog app at the released version, with a
  /// valid signature and without quarantine, so it opens with no prompt.
  Future<void> _verify(PendingInstall item, String staged) async {
    final info = await _readBundle(staged, item.copy.app);
    if (info == null || info.version != item.version) {
      throw const UpdateFailure(
        UpdateFailureKind.verification,
        detail: 'the app in the disk image is not the expected version',
      );
    }
    await _run(_codesign, [
      '--verify',
      '--deep',
      '--strict',
      staged,
    ], kind: UpdateFailureKind.verification);
    final quarantine = await runner.run(_xattr, [
      '-p',
      'com.apple.quarantine',
      staged,
    ]);
    if (quarantine.exitCode == 0) {
      throw const UpdateFailure(
        UpdateFailureKind.verification,
        detail: 'the app is quarantined',
      );
    }
  }

  Future<String> _mountPoint() async {
    final work = _work.isEmpty ? await workDirectory() : _work.last;
    _mounts++;
    final mount = await Directory(p.join(work.path, 'mnt-$_mounts')).create();
    return mount.path;
  }

  Future<void> _detach(String mount) async {
    for (final arguments in [
      ['detach', mount],
      ['detach', '-force', mount],
    ]) {
      try {
        if ((await runner.run(_hdiutil, arguments)).exitCode == 0) return;
      } on ProcessException {
        return;
      }
    }
  }

  void _swap(String target, String staged, String old, VerifiedAsset asset) {
    try {
      Directory(target).renameSync(old);
    } on FileSystemException catch (error) {
      throw _fileFailure(error, asset);
    }
    try {
      Directory(staged).renameSync(target);
    } on FileSystemException catch (error) {
      try {
        Directory(old).renameSync(target);
      } on FileSystemException {
        // the failure below is all that can be reported
      }
      throw _fileFailure(error, asset);
    }
  }

  Future<bool> _isRunning(InstalledCopy copy) async {
    final executable = await _mainExecutable(copy);
    final processes = await _processes();
    return processes.any(
      (process) => process.pid != ownPid && process.command == executable,
    );
  }

  Future<String?> _mainExecutable(InstalledCopy copy) async {
    final known = _executables[copy.location];
    if (known != null) return known;
    final info = await _readBundle(copy.location, copy.app);
    if (info != null) _executables[copy.location] = info.executable;
    return info?.executable;
  }

  Future<List<_Process>> _processes() async {
    // apps opened by LaunchServices have no locale, and ps then escapes
    // every byte of a non-ASCII path
    final result = await _run(_env, const [
      'LC_ALL=en_US.UTF-8',
      _ps,
      '-axo',
      'pid=,uid=,comm=',
    ]);
    return [
      for (final line in const LineSplitter().convert('${result.stdout}'))
        if (_processLine.firstMatch(line) case final match?)
          (
            pid: int.parse(match[1]!),
            uid: int.parse(match[2]!),
            command: match[3]!,
          ),
    ];
  }

  Future<int> _ownUserId() async {
    if (_userId case final known?) return known;
    final result = await _run(_id, const ['-u']);
    final userId = int.tryParse('${result.stdout}'.trim());
    if (userId == null) {
      throw UpdateFailure(
        UpdateFailureKind.failed,
        detail: 'id printed "${result.stdout}"',
      );
    }
    return _userId = userId;
  }

  /// The bundle's version and main executable when it is [app].
  Future<({ReleaseVersion version, String executable})?> _readBundle(
    String bundle,
    SuiteApp app,
  ) async {
    final plist = await _infoPlist(bundle);
    final version = plist?['CFBundleShortVersionString'];
    final name = plist?['CFBundleExecutable'];
    if (plist?['CFBundleIdentifier'] != app.macos.bundleId ||
        version is! String ||
        name is! String) {
      return null;
    }
    final parsed = ReleaseVersion.tryParse(version);
    if (parsed == null) return null;
    return (
      version: parsed,
      executable: p.join(bundle, 'Contents', 'MacOS', name),
    );
  }

  Future<Map<String, Object?>?> _infoPlist(String bundle) async {
    try {
      final result = await runner.run(_plutil, [
        '-convert',
        'json',
        '-o',
        '-',
        p.join(bundle, 'Contents', 'Info.plist'),
      ]);
      if (result.exitCode != 0) return null;
      final json = jsonDecode('${result.stdout}');
      return json is Map<String, Object?> ? json : null;
    } on ProcessException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Runs [tool] and throws an [UpdateFailure] of [kind] unless it succeeds.
  Future<ProcessResult> _run(
    String tool,
    List<String> arguments, {
    UpdateFailureKind kind = UpdateFailureKind.failed,
  }) async {
    final ProcessResult result;
    try {
      result = await runner.run(tool, arguments);
    } on ProcessException catch (error) {
      throw UpdateFailure(UpdateFailureKind.failed, detail: '$error');
    }
    if (result.exitCode != 0) {
      throw UpdateFailure(
        kind,
        code: result.exitCode,
        detail: '${p.basename(tool)}: ${result.stderr}'.trim(),
      );
    }
    return result;
  }

  static UpdateFailure _fileFailure(
    FileSystemException error,
    VerifiedAsset asset,
  ) {
    final code = error.osError?.errorCode;
    if (code == _eperm || code == _eacces) {
      return UpdateFailure(
        UpdateFailureKind.permission,
        detail: '$error',
        installer: asset.file.path,
      );
    }
    return UpdateFailure(UpdateFailureKind.failed, detail: '$error');
  }

  /// [name] in [folder], or `name (2).ext` and so on when it is taken.
  static String _freePath(String folder, String name) {
    final stem = p.basenameWithoutExtension(name);
    final extension = p.extension(name);
    for (var number = 1; ; number++) {
      final path = p.join(
        folder,
        number == 1 ? name : '$stem ($number)$extension',
      );
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return path;
      }
    }
  }

  static String? _resolve(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }

  static List<String> _entries(String folder) {
    try {
      return [
        for (final entity in Directory(folder).listSync(followLinks: false))
          entity.path,
      ];
    } on FileSystemException {
      return const [];
    }
  }

  static bool _isRealDirectory(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.directory;

  /// Deletes the folder at [path] and everything in it, never through a link.
  static void _deleteTree(String path) {
    try {
      if (_isRealDirectory(path)) Directory(path).deleteSync(recursive: true);
    } on FileSystemException {
      // the next run's cleanup tries again
    }
  }
}
