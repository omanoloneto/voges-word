import 'dart:io';

import 'catalog.dart';
import 'process_runner.dart';
import 'suite_platform.dart';
import 'update_failure.dart';

final class MacosPlatform implements SuitePlatform {
  MacosPlatform({this.runner = const SystemProcessRunner()});

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
