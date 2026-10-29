import 'package:flutter/material.dart';

import 'updater_session.dart';

/// The Voges Updater window.
class UpdaterApp extends StatelessWidget {
  const UpdaterApp({required this.session, this.locale, super.key});

  final UpdaterSession session;
  final Locale? locale;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}
