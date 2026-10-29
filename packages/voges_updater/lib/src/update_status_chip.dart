import 'package:flutter/material.dart';

import '../l10n/updater_localizations.dart';
import 'update_check.dart';
import 'updater_launcher.dart';

/// The update indicator of an app's status bar.
class UpdateStatusChip extends StatelessWidget {
  const UpdateStatusChip({
    required this.check,
    required this.onUpdate,
    super.key,
  });

  /// Below this window width the chip shows only its icon.
  static const compactWidth = 640.0;

  final UpdateCheck check;

  /// Closes the app and opens the updater; the app decides how to close.
  final Future<void> Function() onUpdate;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: check,
      builder: (context, _) {
        final l10n = UpdaterLocalizations.of(context);
        final app = check.app.name;
        final compact = MediaQuery.sizeOf(context).width < compactWidth;
        return switch (check.status) {
          UpdateHidden() => const SizedBox.shrink(),
          UpdateChecking() => _Busy(
            label: l10n.updateChecking,
            compact: compact,
          ),
          UpdaterOpening() => _Busy(
            label: l10n.updateOpening,
            compact: compact,
          ),
          UpToDate(:final version) => _Chip(
            icon: Icons.check_circle_outline,
            label: l10n.updateUpToDate,
            tooltip: l10n.updateUpToDateTooltip(app, '$version'),
            compact: compact,
            muted: true,
            onPressed: check.check,
          ),
          UpdateAvailable(
            :final version,
            availability: LaunchAvailability.here,
          ) =>
            _Chip(
              icon: Icons.system_update_alt,
              label: l10n.updateAvailable('$version'),
              tooltip: l10n.updateAvailableTooltip(app, '$version'),
              compact: compact,
              tonal: true,
              onPressed: onUpdate,
            ),
          UpdateAvailable(:final version, :final availability) => _Chip(
            icon: Icons.open_in_new,
            label: l10n.updateDownloadAvailable('$version'),
            tooltip: availability == LaunchAvailability.moveToApplications
                ? l10n.updateMoveToApplications(app)
                : l10n.updateDownloadTooltip,
            compact: compact,
            onPressed: check.openDownloadPage,
          ),
          UpdateCheckFailed() => _Chip(
            icon: Icons.cloud_off,
            label: l10n.updateCheckFailed,
            tooltip: l10n.updateCheckFailedTooltip,
            compact: compact,
            muted: true,
            onPressed: check.check,
          ),
        };
      },
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.compact,
    required this.onPressed,
    this.tonal = false,
    this.muted = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final bool compact;
  final VoidCallback onPressed;
  final bool tonal;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = muted ? theme.colorScheme.onSurfaceVariant : null;
    if (compact) {
      final style = IconButton.styleFrom(
        foregroundColor: foreground,
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        iconSize: 16,
      );
      return tonal
          ? IconButton.filledTonal(
              onPressed: onPressed,
              tooltip: '$label\n$tooltip',
              style: style,
              icon: Icon(icon),
            )
          : IconButton(
              onPressed: onPressed,
              tooltip: '$label\n$tooltip',
              style: style,
              icon: Icon(icon),
            );
    }

    final style = TextButton.styleFrom(
      foregroundColor: foreground,
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      textStyle: theme.textTheme.bodySmall,
      iconSize: 16,
    );
    return Tooltip(
      message: tooltip,
      child: tonal
          ? FilledButton.tonalIcon(
              onPressed: onPressed,
              style: style,
              icon: Icon(icon),
              label: _Label(label),
            )
          : TextButton.icon(
              onPressed: onPressed,
              style: style,
              icon: Icon(icon),
              label: _Label(label),
            ),
    );
  }
}

/// A state that the user can't act on, such as a running check.
class _Busy extends StatelessWidget {
  const _Busy({required this.label, required this.compact});

  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    final spinner = SizedBox.square(
      dimension: 12,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    );
    if (compact) {
      return Tooltip(
        message: label,
        child: Padding(padding: const EdgeInsets.all(8), child: spinner),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          spinner,
          const SizedBox(width: 8),
          Flexible(
            child: _Label(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// One line that ends in an ellipsis when the status bar is short of room;
/// the tooltip still has the whole text.
class _Label extends StatelessWidget {
  const _Label(this.text, {this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: style,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
  );
}
