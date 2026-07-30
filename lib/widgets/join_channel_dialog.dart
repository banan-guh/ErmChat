import 'package:flutter/material.dart';

void showJoinChannelDialog(
  BuildContext context, {
  required void Function(String channel) onJoin,
}) {
  final controller = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Join channel'),
      content: TextField(
        controller: controller,
        decoration: const InputDecoration(
          hintText: 'channel name',
          border: OutlineInputBorder(),
        ),
        autofocus: true,
        onSubmitted: (_) {
          final text = controller.text;
          Navigator.pop(ctx);
          onJoin(text);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final text = controller.text;
            Navigator.pop(ctx);
            onJoin(text);
          },
          child: const Text('Join'),
        ),
      ],
    ),
  );
}
