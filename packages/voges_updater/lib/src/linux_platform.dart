import 'dart:io';

import 'catalog.dart';
import 'process_runner.dart';
import 'suite_platform.dart';
import 'update_failure.dart';

final class LinuxPlatform implements SuitePlatform {
  LinuxPlatform({this.hostApp, this.runner = const SystemProcessRunner()});

  /// The app compiled into this updater.
  final SuiteApp? hostApp;

  final ProcessRunner runner;

  @override
  String assetOf(SuiteApp app) => throw UnimplementedError();

  @override
  Future<UpdaterHost?> host() => throw UnimplementedError();

  @override
  Future<Directory> workDirectory() => throw UnimplementedError();

  @override
  Future<void> cleanStale(Directory current) => throw UnimplementedError();

  @override
  Future<List<InstalledCopy>> installed(
    List<SuiteApp> catalog,
    UpdaterHost? host,
  ) => throw UnimplementedError();

  @override
  Future<List<RunningApp>> running(List<InstalledCopy> copies) =>
      throw UnimplementedError();

  @override
  Future<List<InstallOutcome>> install(
    List<PendingInstall> items,
    void Function(PendingInstall item, InstallStep step) onStep,
  ) => throw UnimplementedError();

  @override
  Future<void> openFallback(UpdateFailure failure) =>
      throw UnimplementedError();

  @override
  void finishSync(UpdaterHost? host) => throw UnimplementedError();
}
