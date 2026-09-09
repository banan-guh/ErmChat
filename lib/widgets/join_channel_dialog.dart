import 'package:flutter/material.dart';

void showJoinChannelDialog(
  BuildContext context, {
  required void Function(String channel) onJoin,
}) {
  showDialog(
    context: context,
    builder: (ctx) => _JoinChannelDialog(onJoin: onJoin),
  );
}

class _JoinChannelDialog extends StatefulWidget {
  final void Function(String channel) onJoin;

  const _JoinChannelDialog({required this.onJoin});

  @override
  State<_JoinChannelDialog> createState() => _JoinChannelDialogState();
}

class _JoinChannelDialogState extends State<_JoinChannelDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(BuildContext context) {
    final text = _controller.text;
    Navigator.pop(context);
    widget.onJoin(text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join channel'),
      content: TextField(
        controller: _controller,
        decoration: const InputDecoration(
          hintText: 'channel name',
          border: OutlineInputBorder(),
        ),
        autofocus: true,
        onSubmitted: (_) => _submit(context),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => _submit(context),
          child: const Text('Join'),
        ),
      ],
    );
  }
}
