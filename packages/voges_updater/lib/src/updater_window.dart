import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/updater_localizations.dart';
import 'suite_platform.dart';
import 'update_failure.dart';
import 'updater_session.dart';

/// The Voges Updater window.
class UpdaterApp extends StatefulWidget {
  const UpdaterApp({
    required this.session,
    this.locale,
    this.settleTime = const Duration(milliseconds: 400),
    super.key,
  });

  final UpdaterSession session;

  /// The language of the app that opened the updater; null follows the
  /// system.
  final Locale? locale;

  /// How long the buttons ignore clicks after the screen changes, so the
  /// second click of a double click doesn't press the button that the new
  /// screen puts in the same place, such as Cancel right after Update.
  final Duration settleTime;

  @override
  State<UpdaterApp> createState() => _UpdaterAppState();
}

class _UpdaterAppState extends State<UpdaterApp> with WindowListener {
  late final AppLifecycleListener _lifecycle;

  UpdaterSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _lifecycle.dispose();
    super.dispose();
  }

  // quitting halfway through an install can leave an app half replaced
  Future<AppExitResponse> _onExitRequested() async {
    if (!session.canClose) return AppExitResponse.cancel;
    await session.leave();
    return AppExitResponse.exit;
  }

  @override
  Future<void> onWindowClose() async {
    if (session.canClose) await session.leave();
  }

  ThemeData _theme(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF3D6FD8),
      brightness: brightness,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 400),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voges Updater',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      locale: widget.locale,
      supportedLocales: UpdaterLocalizations.supportedLocales,
      localizationsDelegates: UpdaterLocalizations.localizationsDelegates,
      home: _UpdaterScreen(session: session, settleTime: widget.settleTime),
    );
  }
}

final class _Button {
  const _Button(this.label, this.onPressed, {this.main = false});

  final String label;
  final VoidCallback? onPressed;

  /// Filled, and pressed by Enter.
  final bool main;

  _Button get asMain => _Button(label, onPressed, main: true);
}

final class _Screen {
  const _Screen(this.body, {this.buttons = const [], this.onEscape});

  final Widget body;
  final List<_Button> buttons;

  /// Not now or Cancel.
  final VoidCallback? onEscape;
}

class _UpdaterScreen extends StatefulWidget {
  const _UpdaterScreen({required this.session, required this.settleTime});

  final UpdaterSession session;
  final Duration settleTime;

  @override
  State<_UpdaterScreen> createState() => _UpdaterScreenState();
}

class _UpdaterScreenState extends State<_UpdaterScreen> {
  UpdaterSession get session => widget.session;

  late UpdaterStage _stage;
  Timer? _settle;

  bool get _settling => _settle?.isActive ?? false;

  @override
  void initState() {
    super.initState();
    _stage = session.stage;
    session.addListener(_onSession);
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    _settle?.cancel();
    super.dispose();
  }

  void _onSession() {
    if (session.stage == _stage) return;
    _stage = session.stage;
    _settle?.cancel();
    if (widget.settleTime == Duration.zero) return;
    _settle = Timer(widget.settleTime, () {
      if (mounted) setState(() {});
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event, _Screen screen) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_settling) return KeyEventResult.handled;
    final key = event.logicalKey;
    final escape = screen.onEscape;
    if (key == LogicalKeyboardKey.escape && escape != null) {
      escape();
      return KeyEventResult.handled;
    }
    final enter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    final main = screen.buttons.where((button) => button.main).firstOrNull;
    // a focused button or checkbox handles Enter itself
    if (enter && node.hasPrimaryFocus && main?.onPressed != null) {
      main!.onPressed!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  _Screen _screen(UpdaterLocalizations l10n) {
    final host = session.hostApp.name;
    final leave = _Button(
      session.reopensHost ? l10n.updaterOpenApp(host) : l10n.updaterClose,
      session.leave,
    );
    switch (session.stage) {
      case UpdaterStage.starting:
      case UpdaterStage.checking:
        return _Screen(
          _Status(
            message: l10n.updaterChecking,
            detail: l10n.updaterHostClosed(host),
          ),
        );
      case UpdaterStage.alreadyRunning:
        return _Screen(
          _Status(
            icon: Icons.info_outline,
            message: l10n.updaterAlreadyRunning,
          ),
          buttons: [leave.asMain],
        );
      case UpdaterStage.startFailed:
        return _Screen(
          _Status(
            icon: Icons.error_outline,
            message: l10n.updaterStartFailed(host),
          ),
          buttons: [
            leave,
            _Button(
              l10n.updateDownloadPage,
              session.openDownloadPage,
              main: true,
            ),
          ],
        );
      case UpdaterStage.offline:
        return _Screen(
          _Status(icon: Icons.cloud_off, message: l10n.updaterOffline),
          buttons: [
            leave,
            _Button(l10n.updaterTryAgain, session.retry, main: true),
          ],
        );
      case UpdaterStage.hostNotFound:
        return _Screen(
          _Status(
            icon: Icons.search_off,
            message: l10n.updaterHostNotFound(host),
          ),
          buttons: [
            leave,
            _Button(
              l10n.updateDownloadPage,
              session.openDownloadPage,
              main: true,
            ),
          ],
        );
      case UpdaterStage.upToDate:
        return _Screen(
          _Status(
            icon: Icons.check_circle_outline,
            message: l10n.updaterAllUpToDate,
          ),
          buttons: [leave.asMain],
        );
      case UpdaterStage.choosing:
        final count = session.selectedCount;
        return _Screen(
          _UpdateList(session: session),
          buttons: [
            _Button(l10n.updaterNotNow, session.leave),
            _Button(
              l10n.updaterUpdateButton(count),
              count == 0 ? null : session.update,
              main: true,
            ),
          ],
          onEscape: session.leave,
        );
      case UpdaterStage.downloading:
        return _Screen(
          _UpdateList(session: session),
          buttons: [_Button(l10n.updaterCancel, session.cancel)],
          onEscape: session.cancel,
        );
      case UpdaterStage.waitingForApps:
        return _Screen(
          _OpenApps(session: session),
          buttons: [_Button(l10n.updaterCancel, session.cancel)],
          onEscape: session.cancel,
        );
      case UpdaterStage.installing:
        return _Screen(_UpdateList(session: session));
      case UpdaterStage.finished:
        final failed = session.rows.any(
          (row) => row.phase == UpdateRowPhase.failed,
        );
        return _Screen(
          _UpdateList(session: session),
          buttons: [
            if (failed) _Button(l10n.updaterTryAgain, session.retry),
            leave.asMain,
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = UpdaterLocalizations.of(context);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final screen = _screen(l10n);
        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) => _onKey(node, event, screen),
          child: Scaffold(
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: screen.body),
                    if (screen.buttons.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      IgnorePointer(
                        ignoring: _settling,
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final button in screen.buttons)
                              button.main
                                  ? FilledButton(
                                      onPressed: button.onPressed,
                                      child: Text(button.label),
                                    )
                                  : TextButton(
                                      onPressed: button.onPressed,
                                      child: Text(button.label),
                                    ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A screen with one message: checking, up to date and the dead ends.
class _Status extends StatelessWidget {
  const _Status({required this.message, this.icon, this.detail});

  /// Null shows a spinner.
  final IconData? icon;
  final String message;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = this.detail;
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon case final icon?)
                Icon(icon, size: 48, color: theme.colorScheme.primary)
              else
                const SizedBox.square(
                  dimension: 40,
                  child: CircularProgressIndicator(),
                ),
              const SizedBox(height: 20),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              if (detail != null) ...[
                const SizedBox(height: 8),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // on Linux this also loads the icon font before the package manager
    // replaces it with the new version's
    return Row(
      children: [
        Icon(Icons.system_update_alt, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: theme.textTheme.titleLarge)),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: scheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: scheme.onSecondaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The updates: to choose, while downloading and installing, and the result.
class _UpdateList extends StatelessWidget {
  const _UpdateList({required this.session});

  final UpdaterSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = UpdaterLocalizations.of(context);
    final choosing = session.stage == UpdaterStage.choosing;
    final rows = choosing
        ? session.rows
        : session.rows.where(
            (row) =>
                row.selected ||
                row.phase == UpdateRowPhase.updated ||
                row.phase == UpdateRowPhase.failed,
          );
    final selectable = session.rows.where((row) => row.selectable).length;
    final installing = session.rows.where(
      (row) => row.phase == UpdateRowPhase.installing,
    );
    final hints = [
      if (installing.any((row) => row.copy.scope == InstallScope.allUsers))
        l10n.updaterAdminHint,
      if (installing.any(
        (row) =>
            row.copy.scope == InstallScope.user &&
            row.step == InstallStep.waitingForPermission,
      ))
        l10n.updaterPasswordHint,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(l10n.updaterHeading),
        if (choosing) ...[
          const SizedBox(height: 16),
          _Note(
            icon: Icons.info_outline,
            text: l10n.updaterHostClosed(session.hostApp.name),
          ),
        ],
        const SizedBox(height: 8),
        if (choosing && selectable >= 2)
          CheckboxListTile(
            tristate: true,
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            value: session.allSelected,
            onChanged: (_) => session.selectAll(session.allSelected != true),
            title: Text(l10n.updaterSelectAll),
          ),
        Expanded(
          child: ListView(
            children: [
              for (final row in rows) _RowTile(session: session, row: row),
            ],
          ),
        ),
        for (final hint in hints) ...[
          const SizedBox(height: 8),
          _Note(icon: Icons.lock_outline, text: hint),
        ],
      ],
    );
  }
}

class _RowTile extends StatelessWidget {
  const _RowTile({required this.session, required this.row});

  final UpdaterSession session;
  final UpdateRow row;

  /// Tells copies of the same app apart; also warns about the administrator
  /// prompt of an install for all users.
  String? _place(UpdaterLocalizations l10n) {
    final copies = session.rows.where(
      (other) => other.app.repository == row.app.repository,
    );
    final scope = row.copy.scope == InstallScope.allUsers
        ? l10n.updaterForAllUsers
        : l10n.updaterForThisUser;
    if (copies.length > 1) {
      return copies.every((other) => other.copy.scope == row.copy.scope)
          ? row.copy.location
          : scope;
    }
    return row.copy.scope == InstallScope.allUsers ? scope : null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = UpdaterLocalizations.of(context);
    final theme = Theme.of(context);
    final latest = row.latest;
    final change = latest == null
        ? null
        : l10n.updaterVersionChange('${row.copy.version}', '$latest');
    final place = _place(l10n);

    if (latest == null) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        titleAlignment: ListTileTitleAlignment.top,
        leading: _RowIcon(
          Icons.cloud_off,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(row.app.name),
        subtitle: Text(
          [l10n.updaterRowCheckFailed, ?place].join('\n'),
          style: TextStyle(color: theme.colorScheme.error),
        ),
      );
    }
    if (session.stage == UpdaterStage.choosing && row.selectable) {
      return CheckboxListTile(
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        titleAlignment: ListTileTitleAlignment.top,
        value: row.selected,
        onChanged: (value) => session.select(row, value ?? false),
        title: Text(row.app.name),
        subtitle: Text([?change, ?place].join('\n')),
        secondary: TextButton(
          onPressed: () => session.openReleaseNotes(row),
          child: Text(l10n.updaterWhatsNew),
        ),
      );
    }

    final muted = theme.colorScheme.onSurfaceVariant;
    final (icon, color) = switch (row.phase) {
      UpdateRowPhase.idle => (Icons.schedule, muted),
      UpdateRowPhase.downloading ||
      UpdateRowPhase.verifying => (Icons.download, null),
      UpdateRowPhase.downloaded => (Icons.download_done, null),
      UpdateRowPhase.installing => (Icons.install_desktop, null),
      UpdateRowPhase.updated => (Icons.check_circle, theme.colorScheme.primary),
      UpdateRowPhase.failed => (Icons.error_outline, theme.colorScheme.error),
    };
    final status = switch (row.phase) {
      UpdateRowPhase.downloading => l10n.updaterDownloading(
        ((row.progress ?? 0) * 100).floor(),
      ),
      UpdateRowPhase.verifying => l10n.updaterVerifying,
      UpdateRowPhase.installing => l10n.updaterInstalling,
      _ => null,
    };
    final busy = switch (row.phase) {
      UpdateRowPhase.downloading ||
      UpdateRowPhase.verifying ||
      UpdateRowPhase.installing => true,
      _ => false,
    };

    return ListTile(
      contentPadding: EdgeInsets.zero,
      titleAlignment: ListTileTitleAlignment.top,
      leading: _RowIcon(icon, color: color),
      title: Text(row.app.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (row.phase == UpdateRowPhase.updated)
            Text(l10n.updaterUpdated('${row.installedVersion ?? latest}'))
          else
            Text([?change, ?place].join('\n')),
          if (status != null) Text(status),
          if (busy) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: row.phase == UpdateRowPhase.downloading
                  ? row.progress
                  : null,
            ),
          ],
          if (row.failure case final failure?)
            _Failure(session: session, row: row, failure: failure),
        ],
      ),
    );
  }
}

/// As wide as a checkbox, so names line up in every row.
class _RowIcon extends StatelessWidget {
  const _RowIcon(this.icon, {this.color});

  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: 40, child: Icon(icon, color: color));
}

class _Failure extends StatelessWidget {
  const _Failure({
    required this.session,
    required this.row,
    required this.failure,
  });

  final UpdaterSession session;
  final UpdateRow row;
  final UpdateFailure failure;

  String _message(UpdaterLocalizations l10n) {
    final app = row.app.name;
    return switch (failure.kind) {
      UpdateFailureKind.network => l10n.updaterErrorNetwork,
      UpdateFailureKind.verification => l10n.updaterErrorVerification,
      UpdateFailureKind.unavailable => l10n.updaterErrorUnavailable(
        '${row.latest}',
      ),
      UpdateFailureKind.permission => l10n.updaterErrorPermission(app),
      UpdateFailureKind.inUse => l10n.updaterErrorInUse(app),
      UpdateFailureKind.declined => l10n.updaterErrorDeclined,
      UpdateFailureKind.noPasswordWindow => l10n.updaterErrorNoPasswordWindow,
      UpdateFailureKind.notAuthorized => l10n.updaterErrorNotAuthorized,
      UpdateFailureKind.packageManager => l10n.updaterErrorPackageManager,
      UpdateFailureKind.failed => switch (failure.code) {
        final code? => l10n.updaterErrorFailed(code),
        null => l10n.updaterErrorUnknown,
      },
    };
  }

  static String _label(UpdaterLocalizations l10n, RowAction action) =>
      switch (action) {
        RowAction.openInstaller => l10n.updaterOpenInstaller,
        RowAction.showLog => l10n.updaterShowLog,
        RowAction.downloadPage => l10n.updateDownloadPage,
        RowAction.copyCommand => l10n.updaterCopyCommand,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = UpdaterLocalizations.of(context);
    final theme = Theme.of(context);
    final actions = session.actionsOf(row);
    final command = failure.command;
    final output = failure.kind == UpdateFailureKind.packageManager
        ? failure.detail
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 4),
        Text(_message(l10n), style: TextStyle(color: theme.colorScheme.error)),
        if (output != null) _Code(output),
        if (command != null) ...[_Code(command), Text(l10n.updaterKeepOpen)],
        if (actions.isNotEmpty)
          Wrap(
            spacing: 8,
            children: [
              for (final action in actions)
                TextButton(
                  onPressed: () => session.perform(row, action),
                  child: Text(_label(l10n, action)),
                ),
            ],
          ),
      ],
    );
  }
}

/// A command or a tool's output, selectable so it can be copied.
class _Code extends StatelessWidget {
  const _Code(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        text,
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
    );
  }
}

/// The apps that must close before installing.
class _OpenApps extends StatelessWidget {
  const _OpenApps({required this.session});

  final UpdaterSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = UpdaterLocalizations.of(context);
    final windows = <String, int>{};
    final elsewhere = <String>{};
    for (final open in session.blockers) {
      final name = open.app.name;
      if (open.otherAccount) {
        elsewhere.add(name);
      } else {
        windows[name] = (windows[name] ?? 0) + 1;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(l10n.updaterHeading),
        const SizedBox(height: 16),
        _Note(icon: Icons.save_outlined, text: l10n.updaterCloseApps),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            children: [
              for (final MapEntry(key: name, value: count) in windows.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.web_asset),
                  title: Text(l10n.updaterOpenWindows(name, count)),
                ),
              for (final name in elsewhere)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.supervisor_account_outlined),
                  title: Text(l10n.updaterOtherAccount(name)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
