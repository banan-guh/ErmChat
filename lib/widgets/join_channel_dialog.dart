import 'package:flutter/material.dart';
import '../l10n/l10n.dart';

/// Asks for a channel's new name.
void showEditChannelDialog(
  BuildContext context, {
  required String channel,
  required void Function(String channel) onSave,
}) {
  showDialog(
    context: context,
    builder: (ctx) => _EditChannelDialog(channel: channel, onSave: onSave),
  );
}

/// Asks for one or more channels, separated by commas or spaces. Names
/// already joined are skipped; adding none of them is an error.
void showAddChannelsDialog(
  BuildContext context, {
  required void Function(String channel) onAdd,
  required bool Function(String channel) isJoined,
}) {
  showDialog(
    context: context,
    builder: (ctx) => _AddChannelsDialog(onAdd: onAdd, isJoined: isJoined),
  );
}

/// Splits [input] on commas and whitespace, trims, lowercases and dedups.
List<String> parseChannelNames(String input) {
  final names = <String>[];
  for (final part in input.split(_channelSeparator)) {
    final name = part.trim().toLowerCase();
    if (name.isNotEmpty && !names.contains(name)) names.add(name);
  }
  return names;
}

final _channelSeparator = RegExp(r'[,\s]+');

class _EditChannelDialog extends StatefulWidget {
  final void Function(String channel) onSave;
  final String channel;

  const _EditChannelDialog({required this.onSave, required this.channel});

  @override
  State<_EditChannelDialog> createState() => _EditChannelDialogState();
}

class _EditChannelDialogState extends State<_EditChannelDialog> {
  late final _controller = TextEditingController(text: widget.channel)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.channel.length,
    );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(BuildContext context) {
    final text = _controller.text;
    Navigator.pop(context);
    widget.onSave(text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.editChannel),
      content: TextField(
        controller: _controller,
        decoration: InputDecoration(
          hintText: context.l10n.channelNameHint,
          border: OutlineInputBorder(),
        ),
        autofocus: true,
        onSubmitted: (_) => _submit(context),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: () => _submit(context),
          child: Text(context.l10n.save),
        ),
      ],
    );
  }
}

class _AddChannelsDialog extends StatefulWidget {
  final void Function(String channel) onAdd;
  final bool Function(String channel) isJoined;

  const _AddChannelsDialog({required this.onAdd, required this.isJoined});

  @override
  State<_AddChannelsDialog> createState() => _AddChannelsDialogState();
}

class _AddChannelsDialogState extends State<_AddChannelsDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(BuildContext context) {
    final names = parseChannelNames(_controller.text);
    if (names.isEmpty) {
      setState(() => _error = context.l10n.addChannelsEmpty);
      return;
    }
    final fresh = [
      for (final name in names)
        if (!widget.isJoined(name)) name,
    ];
    if (fresh.isEmpty) {
      setState(() => _error = context.l10n.channelsAlreadyAdded);
      return;
    }
    Navigator.pop(context);
    for (final name in fresh) {
      widget.onAdd(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.addChannels),
      content: TextField(
        controller: _controller,
        decoration: InputDecoration(
          hintText: context.l10n.addChannelsHint,
          errorText: _error,
          border: OutlineInputBorder(),
        ),
        minLines: 1,
        maxLines: 3,
        autofocus: true,
        onSubmitted: (_) => _submit(context),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: () => _submit(context),
          child: Text(context.l10n.add),
        ),
      ],
    );
  }
}
