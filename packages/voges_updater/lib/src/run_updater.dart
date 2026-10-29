import 'package:flutter/widgets.dart';

import 'catalog.dart';

/// Runs Voges Updater in this process: the macOS helper's `main`, and the
/// app's `main` on Windows and Linux when started with `--voges-updater`.
/// [host] is the app compiled into this process (Windows and Linux).
Future<void> runUpdater({
  required List<String> arguments,
  SuiteApp? host,
  Locale? locale,
}) => throw UnimplementedError();
