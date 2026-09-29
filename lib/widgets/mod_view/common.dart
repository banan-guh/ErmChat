import 'dart:async';

import 'package:flutter/material.dart';
import '../../services/mod_actions.dart';
import '../../util/date_format.dart';
import '../app_snack.dart';

/// Snackbar copy for a failed mod action.
String modErrorText(ModResult result) => switch (result.failure) {
  ModFailure.unknownUser => 'No user matching that username.',
  ModFailure.selfTarget => 'You cannot target yourself.',
  ModFailure.broadcasterTarget => 'You cannot target the broadcaster.',
  ModFailure.notJoined => 'Channel not joined.',
  _ => result.reason ?? 'An unknown error has occurred.',
};

void showModError(BuildContext context, ModResult result) {
  if (result.ok) return;
  AppSnack.showError(context, modErrorText(result));
}

/// Timeout picker: preset chips plus custom seconds and an optional reason.
Future<({int seconds, String? reason})?> showTimeoutDialog(
  BuildContext context,
  String login,
) {
  const presets = <(String, int)>[
    ('10s', 10),
    ('1m', 60),
    ('10m', 600),
    ('1h', 3600),
    ('1d', 86400),
    ('1w', 604800),
  ];
  // Twitch caps timeouts at 2 weeks.
  const maxSeconds = 1209600;
  var seconds = 600;
  final customCtrl = TextEditingController();
  final reasonCtrl = TextEditingController();
  final pending = showDialog<({int seconds, String? reason})>(
    context: context,
    builder: (ctx) {
      var error = '';
      return StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Timeout $login'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final (label, value) in presets)
                    ChoiceChip(
                      label: Text(label),
                      selected: seconds == value && customCtrl.text.isEmpty,
                      onSelected: (_) {
                        customCtrl.clear();
                        setLocal(() {
                          seconds = value;
                          error = '';
                        });
                      },
                    ),
                ],
              ),
              TextField(
                controller: customCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Custom seconds (max 2 weeks)',
                ),
                onChanged: (_) => setLocal(() => error = ''),
              ),
              TextField(
                controller: reasonCtrl,
                decoration: const InputDecoration(
                  labelText: 'Reason (optional)',
                ),
              ),
              if (error.isNotEmpty)
                Text(
                  error,
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                var picked = seconds;
                final custom = customCtrl.text.trim();
                if (custom.isNotEmpty) {
                  final parsed = int.tryParse(custom);
                  if (parsed == null || parsed <= 0 || parsed > maxSeconds) {
                    setLocal(() => error = 'Enter 1-$maxSeconds seconds.');
                    return;
                  }
                  picked = parsed;
                }
                final reason = reasonCtrl.text.trim();
                Navigator.pop(ctx, (
                  seconds: picked,
                  reason: reason.isEmpty ? null : reason,
                ));
              },
              child: const Text('Timeout'),
            ),
          ],
        ),
      );
    },
  );
  pending.whenComplete(() {
    customCtrl.dispose();
    reasonCtrl.dispose();
  });
  return pending;
}

/// Single text field dialog (reasons, usernames). Null means cancelled.
Future<String?> showModTextDialog(
  BuildContext context, {
  required String title,
  String? label,
  required String confirmLabel,
  bool allowEmpty = false,
}) {
  final ctrl = TextEditingController();
  final pending = showDialog<String>(
    context: context,
    builder: (ctx) {
      var error = '';
      return StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: label,
                  errorText: error.isEmpty ? null : error,
                ),
                onSubmitted: (_) {
                  final value = ctrl.text.trim();
                  if (value.isEmpty && !allowEmpty) {
                    setLocal(() => error = 'Enter a value.');
                    return;
                  }
                  Navigator.pop(ctx, value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = ctrl.text.trim();
                if (value.isEmpty && !allowEmpty) {
                  setLocal(() => error = 'Enter a value.');
                  return;
                }
                Navigator.pop(ctx, value);
              },
              child: Text(confirmLabel),
            ),
          ],
        ),
      );
    },
  );
  pending.whenComplete(ctrl.dispose);
  return pending;
}

String modFeedTime(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

String modFeedDateTime(DateTime at) => '${formatYmd(at)} ${modFeedTime(at)}';

String modRelativeAgo(DateTime at) {
  final diff = DateTime.now().difference(at);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  return formatYmd(at);
}

String modRelativeShortDate(String iso) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  return modRelativeAgo(dt.toLocal());
}

String modCapitalizeToken(String token) {
  final words = token.replaceAll('_', ' ').split(' ');
  return [
    for (final w in words)
      if (w.isNotEmpty) '${w[0].toUpperCase()}${w.substring(1)}',
  ].join(' ');
}

class ModSectionHeader extends StatelessWidget {
  const ModSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 12,
          letterSpacing: 0.8,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Centered empty state: large icon plus bold title and grey subtitle.
class ModEmpty extends StatelessWidget {
  const ModEmpty({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Centered error state with retry.
class ModError extends StatelessWidget {
  const ModError({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// Shared async load scaffold for the Mod View tabs: last Helix status to
/// error copy, generation guard, and backgrounded-failure notices.
mixin ModTabLoad<T extends StatefulWidget> on State<T> {
  ModActions get modActions;
  ValueChanged<String> get onNotice;

  /// Runs [request] behind the tab load guards. Null means the caller must
  /// stop: either a newer load won the generation, or a failed background
  /// refresh was already surfaced as a notice.
  Future<({V? value, String? error})?> guardedLoad<V>({
    required int gen,
    required int Function() currentGen,
    required bool background,
    required Future<V> Function() request,
    required String fallbackError,
    String? Function(int status)? statusError,
  }) async {
    final api = modActions.twitchApi;
    final (value, error) = await api.isolateErrors<(V?, String?)>(() async {
      try {
        final value = await request();
        final status = api.lastErrorStatus;
        if (status == null) return (value, null);
        return (null, statusError?.call(status) ?? modActions.failureReason());
      } catch (_) {
        return (null, fallbackError);
      }
    });
    if (!mounted || gen != currentGen()) return null;
    if (error != null && background) {
      onNotice(error);
      return null;
    }
    return (value: value, error: error);
  }
}
