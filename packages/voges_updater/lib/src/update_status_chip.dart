import 'package:flutter/material.dart';

import 'update_check.dart';

/// The update indicator of an app's status bar.
class UpdateStatusChip extends StatelessWidget {
  const UpdateStatusChip({
    required this.check,
    required this.onUpdate,
    super.key,
  });

  final UpdateCheck check;

  /// Closes the app and opens the updater; the app decides how to close.
  final Future<void> Function() onUpdate;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}
