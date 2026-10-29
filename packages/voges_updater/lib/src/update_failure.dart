enum UpdateFailureKind {
  /// The download or the version check failed.
  network,

  /// The signature, a checksum or the identity of the download did not match.
  verification,

  /// The release has no file for this system.
  unavailable,

  /// The system did not allow replacing the app.
  permission,

  /// The app, or one of its files, was still in use.
  inUse,

  /// The user dismissed the administrator or password prompt.
  declined,

  /// Linux: no polkit agent to show a password window.
  noPasswordWindow,

  /// Linux: the account may not install software.
  notAuthorized,

  /// Linux: apt refused the package.
  packageManager,

  /// Anything else; [UpdateFailure.code] has the exit code when there is one.
  failed,
}

final class UpdateFailure implements Exception {
  const UpdateFailure(
    this.kind, {
    this.code,
    this.detail,
    this.logPath,
    this.command,
    this.installer,
  });

  final UpdateFailureKind kind;

  /// Exit code of the installer or package manager.
  final int? code;

  /// Technical detail for logs; never shown as the main message.
  final String? detail;

  /// Windows: the installer's log file.
  final String? logPath;

  /// Linux: the command that installs the update from a terminal.
  final String? command;

  /// macOS: the verified .dmg, for installing by hand.
  final String? installer;

  @override
  String toString() {
    final parts = [kind.name, if (code != null) 'code $code', ?detail];
    return 'UpdateFailure(${parts.join(', ')})';
  }
}
