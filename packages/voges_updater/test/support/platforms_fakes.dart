import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:voges_updater/core.dart';

/// One call made through a [FakeProcessRunner].
final class RecordedCall {
  RecordedCall(
    this.executable,
    this.arguments, {
    this.workingDirectory,
    this.mode,
    this.sync = false,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  /// Null for `run` and `runSync`.
  final ProcessStartMode? mode;
  final bool sync;

  List<String> get argv => [executable, ...arguments];

  /// The tool's file name; for `/usr/bin/env VAR=value tool ...`, that tool.
  String get tool {
    final name = executable.split(RegExp(r'[/\\]')).last;
    if (name != 'env') return name;
    final command = arguments.firstWhere(
      (argument) => !argument.contains('='),
      orElse: () => name,
    );
    return command.split(RegExp(r'[/\\]')).last;
  }
}

/// Records every call and answers with scripted results.
final class FakeProcessRunner implements ProcessRunner {
  FakeProcessRunner({this.onRun, this.onStart});

  /// The result of `run` and `runSync`: exit code 0 and no output when null.
  ProcessResult Function(RecordedCall call)? onRun;

  /// The process of `start`: one that exits with code 0 when null.
  FakeProcess Function(RecordedCall call)? onStart;

  final calls = <RecordedCall>[];

  List<List<String>> get argvs => [for (final call in calls) call.argv];

  /// The calls to the tool named [name], such as `hdiutil`.
  List<RecordedCall> callsTo(String name) => [
    for (final call in calls)
      if (call.tool == name) call,
  ];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final call = RecordedCall(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    calls.add(call);
    return onRun?.call(call) ?? processResult(0);
  }

  @override
  ProcessResult runSync(String executable, List<String> arguments) {
    final call = RecordedCall(executable, arguments, sync: true);
    calls.add(call);
    return onRun?.call(call) ?? processResult(0);
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final call = RecordedCall(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      mode: mode,
    );
    calls.add(call);
    return onStart?.call(call) ?? FakeProcess();
  }
}

ProcessResult processResult(
  int exitCode, {
  String stdout = '',
  String stderr = '',
}) => ProcessResult(1, exitCode, stdout, stderr);

/// A process with scripted output that ends with [exitCode].
final class FakeProcess implements Process {
  FakeProcess({
    int exitCode = 0,
    List<String> stdout = const [],
    List<String> stderr = const [],
  }) : exitCode = Future.value(exitCode),
       stdout = _lines(stdout),
       stderr = _lines(stderr) {
    _input.stream.listen((_) {}, onDone: () => stdinClosed = true);
  }

  final _input = StreamController<List<int>>();
  var stdinClosed = false;

  @override
  late final IOSink stdin = IOSink(_input);

  @override
  final Future<int> exitCode;

  @override
  final Stream<List<int>> stdout;

  @override
  final Stream<List<int>> stderr;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;

  static Stream<List<int>> _lines(List<String> lines) =>
      Stream.fromIterable([for (final line in lines) utf8.encode('$line\n')]);
}

/// A new folder for one test, by its real path: on macOS the system temp
/// folder is reached through the /var link.
Directory platformsTempRoot() {
  final folder = Directory.systemTemp.createTempSync('platforms-test-');
  return Directory(folder.resolveSymbolicLinksSync());
}

/// A file with [content] and its matching SHA-256, as the downloader leaves it.
VerifiedAsset verifiedFile(String path, [String content = 'installer']) {
  final file = File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
  return VerifiedAsset(
    file: file,
    sha256: sha256.convert(utf8.encode(content)).toString(),
  );
}
