import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'design_tokens.dart';

/// Native popup menu for sent-message history.
class SentHistoryButton extends StatefulWidget {
  const SentHistoryButton({
    super.key,
    required this.history,
    required this.onSelect,
  });

  final ValueListenable<List<String>> history;
  final ValueChanged<String> onSelect;

  @override
  State<SentHistoryButton> createState() => _SentHistoryButtonState();
}

class _SentHistoryButtonState extends State<SentHistoryButton> {
  final _latestKey = GlobalKey();

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _latestKey.currentContext;
      if (context == null) return;
      final position = Scrollable.maybeOf(context)?.position;
      if (position != null && position.hasContentDimensions) {
        position.jumpTo(position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: context.l10n.sentHistoryTitle,
    position: PopupMenuPosition.over,
    popUpAnimationStyle: const AnimationStyle(duration: Motion.fast),
    constraints: const BoxConstraints(
      minWidth: 200,
      maxWidth: 240,
      maxHeight: 360,
    ),
    style: IconButton.styleFrom(
      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      minimumSize: const Size.square(40),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ).merge(IconButtonTheme.of(context).style),
    icon: const Icon(Icons.history),
    onOpened: _scrollToLatest,
    itemBuilder: (_) {
      final items = widget.history.value;
      if (items.isEmpty) {
        return [
          PopupMenuItem<String>(
            enabled: false,
            child: Text(context.l10n.sentHistoryEmpty),
          ),
        ];
      }
      return [
        for (var i = 0; i < items.length; i++)
          PopupMenuItem<String>(
            key: i == items.length - 1 ? _latestKey : null,
            value: items[items.length - 1 - i],
            child: Text(
              items[items.length - 1 - i],
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ];
    },
    onSelected: widget.onSelect,
  );
}
