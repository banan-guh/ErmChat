import 'package:flutter/material.dart';

Future<void> showWelcomeDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Welcome to ErmChat'),
      content: const Text(
        'Mention notifications are off by default. Turn on Mentions in '
        'Settings > Highlights to get a ping when someone mentions you in '
        'chat.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}
