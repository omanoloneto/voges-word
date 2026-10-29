import 'voges_updater.dart';

/// The macOS helper embedded in each suite app. It finds its host from its
/// own location, so it takes no arguments.
Future<void> main() => runUpdater(arguments: const []);
