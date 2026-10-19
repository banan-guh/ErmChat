import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// Bottom sheet for a tapped history marker or day: [title] over the actions
/// for a stream row ([stream] true) or a day. [vod] resolves the stream's
/// video on demand, null when it has none; [onWatchVod] opens it. [kept] is
/// whether the day is kept past retention; [onKeep] sets it. [onJumpToStart]
/// scrolls an ended stream back to its first row.
Future<void> showHistoryMarkerSheet(
  BuildContext context, {
  required String title,
  required bool stream,
  Future<String?>? vod,
  ValueChanged<String>? onWatchVod,
  VoidCallback? onJumpToStart,
  bool? kept,
  ValueChanged<bool>? onKeep,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) {
      final l10n = ctx.l10n;
      Widget action(
        IconData icon,
        String label,
        VoidCallback? onTap, {
        String? subtitle,
      }) => ListTile(
        leading: Icon(icon),
        title: Text(label),
        subtitle: subtitle == null ? null : Text(subtitle),
        enabled: onTap != null,
        onTap: onTap == null
            ? null
            : () {
                Navigator.pop(ctx);
                onTap();
              },
      );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
            ),
            if (stream) ...[
              if (onJumpToStart != null)
                action(
                  Icons.vertical_align_top,
                  l10n.historyJumpToStart,
                  onJumpToStart,
                ),
              if (vod != null && onWatchVod != null)
                FutureBuilder<String?>(
                  future: vod,
                  builder: (_, snap) {
                    final id = snap.data;
                    return action(
                      Icons.play_circle_outline,
                      l10n.historyWatchVod,
                      id == null ? null : () => onWatchVod(id),
                      subtitle:
                          snap.connectionState == ConnectionState.done &&
                              id == null
                          ? l10n.historyNoVod
                          : null,
                    );
                  },
                ),
              action(Icons.map_outlined, l10n.historyOpenStreamMap, () {
                // TODO: open the Streams screen at this stream.
              }),
            ],
            if (kept != null && onKeep != null)
              action(
                kept ? Icons.bookmark_remove_outlined : Icons.bookmark_border,
                kept ? l10n.historyUnkeepDay : l10n.historyKeepDay,
                () => onKeep(!kept),
              ),
          ],
        ),
      );
    },
  );
}
