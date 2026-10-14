import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// Bottom sheet for a tapped history marker: [title] over the actions for a
/// stream row ([stream] true) or a day row.
Future<void> showHistoryMarkerSheet(
  BuildContext context, {
  required String title,
  required bool stream,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) {
      final l10n = ctx.l10n;
      Widget action(IconData icon, String label, VoidCallback onTap) =>
          ListTile(
            leading: Icon(icon),
            title: Text(label),
            onTap: () {
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
              action(Icons.play_circle_outline, l10n.historyWatchVod, () {
                // TODO: open the VOD at this time.
              }),
              action(Icons.map_outlined, l10n.historyOpenStreamMap, () {
                // TODO: open the Streams screen at this stream.
              }),
            ],
            action(Icons.bookmark_border, l10n.historySaveDay, () {
              // TODO: pin the day in the archive.
            }),
          ],
        ),
      );
    },
  );
}
