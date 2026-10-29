import 'package:path/path.dart' as p;

/// How Voges Word starts itself as the updater on Windows and Linux. The
/// arguments are checked strictly: anything unexpected means the process was
/// not started by the app, and the updater does not run.
final class UpdaterRequest {
  const UpdaterRequest._({this.relaunch});

  static const flag = '--voges-updater';
  static const _relaunch = '--relaunch=';

  /// Windows: the installed executable to open again when the update ends.
  final String? relaunch;

  /// Whether [arguments] ask for the updater instead of the editor. Only on
  /// Windows and Linux: on macOS the updater is its own app.
  static bool isUpdaterLaunch(List<String> arguments, String operatingSystem) =>
      (operatingSystem == 'windows' || operatingSystem == 'linux') &&
      arguments.isNotEmpty &&
      arguments.first == flag;

  /// Windows takes exactly `--voges-updater --relaunch=<absolute path>`;
  /// Linux exactly `--voges-updater`. Null for anything else.
  static UpdaterRequest? parse(List<String> arguments, String operatingSystem) {
    switch (operatingSystem) {
      case 'linux':
        return arguments.length == 1 && arguments.first == flag
            ? const UpdaterRequest._()
            : null;
      case 'windows':
        if (arguments.length != 2 ||
            arguments.first != flag ||
            !arguments.last.startsWith(_relaunch)) {
          return null;
        }
        final path = arguments.last.substring(_relaunch.length);
        if (!p.windows.isAbsolute(path) || p.windows.normalize(path) != path) {
          return null;
        }
        return UpdaterRequest._(relaunch: path);
      default:
        return null;
    }
  }

  /// The arguments that [parse] accepts, for the app that starts the updater.
  static List<String> argumentsFor({String? relaunch}) => [
    flag,
    if (relaunch != null) '$_relaunch$relaunch',
  ];
}
