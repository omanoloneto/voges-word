import 'dart:io';

/// Runs system tools. Every call names the tool by its absolute path and
/// passes the arguments as a list, so nothing goes through a shell.
abstract interface class ProcessRunner {
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  });

  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    ProcessStartMode mode = ProcessStartMode.normal,
  });
}

final class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) {
    _requireAbsolute(executable);
    return Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: false,
    );
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    _requireAbsolute(executable);
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: false,
      mode: mode,
    );
  }

  // a bare name would be looked up in PATH, which the user's environment
  // controls
  static void _requireAbsolute(String executable) {
    if (!File(executable).isAbsolute) {
      throw ArgumentError.value(executable, 'executable', 'must be absolute');
    }
  }
}
