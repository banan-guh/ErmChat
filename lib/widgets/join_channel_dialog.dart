import 'package:flutter/material.dart';

/// Asks for a channel name. [initial] prefills the field for an edit.
void showJoinChannelDialog(
  BuildContext context, {
  required void Function(String channel) onJoin,
  String? initial,
}) {
  showDialog(
    context: context,
    builder: (ctx) => _JoinChannelDialog(onJoin: onJoin, initial: initial),
  );
}

class _JoinChannelDialog extends StatefulWidget {
  final void Function(String channel) onJoin;
  final String? initial;

  const _JoinChannelDialog({required this.onJoin, this.initial});

  @override
  State<_JoinChannelDialog> createState() => _JoinChannelDialogState();
}

class _JoinChannelDialogState extends State<_JoinChannelDialog> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial?.length ?? 0,
    );

  bool get _editing => widget.initial != null;

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
      title: Text(_editing ? 'Edit channel' : 'Join channel'),
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
          child: Text(_editing ? 'Save' : 'Join'),
        ),
      ],
    );
  }
}
