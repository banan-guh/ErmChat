import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/mod_actions.dart';
import '../app_snack.dart';

/// Snackbar copy for a failed mod action.
String modErrorText(ModResult result, AppLocalizations l) =>
    switch (result.failure) {
      ModFailure.unknownUser => l.modErrorUnknownUser,
      ModFailure.selfTarget => l.modErrorSelfTarget,
      ModFailure.broadcasterTarget => l.modErrorBroadcasterTarget,
      ModFailure.notJoined => l.modErrorNotJoined,
      _ => result.reason ?? l.modErrorUnknown,
    };

void showModError(BuildContext context, ModResult result) {
  if (result.ok) return;
  AppSnack.showError(context, modErrorText(result, context.l10n));
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
          title: Text(ctx.l10n.timeoutUser(login)),
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
                decoration: InputDecoration(labelText: ctx.l10n.customSeconds),
                onChanged: (_) => setLocal(() => error = ''),
              ),
              TextField(
                controller: reasonCtrl,
                decoration: InputDecoration(labelText: ctx.l10n.reasonOptional),
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
              child: Text(ctx.l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                var picked = seconds;
                final custom = customCtrl.text.trim();
                if (custom.isNotEmpty) {
                  final parsed = int.tryParse(custom);
                  if (parsed == null || parsed <= 0 || parsed > maxSeconds) {
                    setLocal(
                      () => error = ctx.l10n.enterSecondsRange(maxSeconds),
                    );
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
              child: Text(ctx.l10n.timeout),
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
                    setLocal(() => error = ctx.l10n.enterValue);
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
              child: Text(ctx.l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                final value = ctrl.text.trim();
                if (value.isEmpty && !allowEmpty) {
                  setLocal(() => error = ctx.l10n.enterValue);
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

/// Picks one of [options] (label, value). Null means dismissed.
Future<T?> showModChoiceDialog<T>(
  BuildContext context, {
  required String title,
  required List<(String, T)> options,
}) {
  return showDialog<T>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(title),
      children: [
        for (final (label, value) in options)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, value),
            child: Text(label),
          ),
      ],
    ),
  );
}

/// Whole-number entry within [min]..[max]. Null means cancelled.
Future<int?> showModNumberDialog(
  BuildContext context, {
  required String title,
  required String label,
  required int min,
  required int max,
}) {
  final ctrl = TextEditingController();
  final pending = showDialog<int>(
    context: context,
    builder: (ctx) {
      var error = '';
      return StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              labelText: label,
              errorText: error.isEmpty ? null : error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(ctx.l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                final parsed = int.tryParse(ctrl.text.trim());
                if (parsed == null || parsed < min || parsed > max) {
                  setLocal(() => error = ctx.l10n.enterRange(min, max));
                  return;
                }
                Navigator.pop(ctx, parsed);
              },
              child: Text(ctx.l10n.useValue),
            ),
          ],
        ),
      );
    },
  );
  pending.whenComplete(ctrl.dispose);
  return pending;
}
