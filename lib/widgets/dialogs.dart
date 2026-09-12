import 'package:flutter/material.dart';

/// Confirmation dialog with cancel and confirm actions. Returns true only when
/// the user confirms; cancel and dismiss return false.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel),
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
  required T? value,
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
                  subtitle: Text(sub),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
