import 'package:flutter/material.dart';
import '../l10n/l10n.dart';

Future<void> showWelcomeDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.l10n.welcomeTitle),
      content: Text(ctx.l10n.welcomeBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(ctx.l10n.gotIt),
        ),
      ],
    ),
  );
}
