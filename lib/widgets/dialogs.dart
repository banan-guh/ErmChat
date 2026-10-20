import 'package:flutter/material.dart';
import '../l10n/l10n.dart';

/// Confirmation dialog with cancel and confirm actions. Returns true only when
/// the user confirms; cancel and dismiss return false.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  String? cancelLabel,
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel ?? ctx.l10n.cancel),
        ),
        if (destructive)
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          )
        else
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
      ],
    ),
  );
  return ok == true;
}

/// Radio-list choice dialog. Returns the chosen value, or null on dismiss.
Future<T?> showChoiceDialog<T>(
  BuildContext context, {
  required String title,
  T? value,
  required List<(T, String, String)> options,
  double? height,
}) {
  return showDialog<T>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: 360,
        height: height,
        child: RadioGroup<T>(
          groupValue: value,
          onChanged: (v) {
            if (v != null) Navigator.pop(ctx, v);
          },
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final (val, label, sub) in options)
                RadioListTile<T>(
                  value: val,
                  title: Text(label),
                  subtitle: sub.isEmpty ? null : Text(sub),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Single text field dialog (reasons, usernames). Null means cancelled.
Future<String?> showTextDialog(
  BuildContext context, {
  required String title,
  String? label,
  String? helper,
  required String confirmLabel,
  bool allowEmpty = false,
  String? Function(String value)? validate,
}) {
  final ctrl = TextEditingController();
  final pending = showDialog<String>(
    context: context,
    builder: (ctx) {
      var error = '';
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          void submit() {
            final value = ctrl.text.trim();
            final problem = value.isEmpty && !allowEmpty
                ? ctx.l10n.enterValue
                : validate?.call(value);
            if (problem != null) {
              setLocal(() => error = problem);
              return;
            }
            Navigator.pop(ctx, value);
          }

          return AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: label,
                    helperText: helper,
                    errorText: error.isEmpty ? null : error,
                  ),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(ctx.l10n.cancel),
              ),
              FilledButton(onPressed: submit, child: Text(confirmLabel)),
            ],
          );
        },
      );
    },
  );
  pending.whenComplete(ctrl.dispose);
  return pending;
}

/// Whole-number entry within [min]..[max]. Null means cancelled.
Future<int?> showNumberDialog(
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
