import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../util/history_timeline.dart';

/// Every archived stream of a channel, newest first, with its thumbnail,
/// title, date and length. A tap opens the stream at its start.
class HistoryStreamsPage extends StatelessWidget {
  const HistoryStreamsPage({
    super.key,
    required this.streams,
    required this.thumbnails,
    required this.onOpen,
  });

  /// Newest first.
  final List<HistoryStream> streams;

  /// Thumbnail URLs by stream id, or null when there is no way to look them
  /// up. A stream past its video's expiry has none.
  final Future<Map<String, String>>? thumbnails;

  final ValueChanged<HistoryStream> onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.historyAllStreams)),
      body: streams.isEmpty
          ? Center(child: Text(l10n.historyNoStreams))
          : FutureBuilder<Map<String, String>>(
              future: thumbnails,
              builder: (context, snap) {
                final thumbs = snap.data ?? const {};
                return ListView.builder(
                  padding: EdgeInsets.only(
                    top: 4,
                    bottom: 4 + MediaQuery.paddingOf(context).bottom,
                  ),
                  itemCount: streams.length,
                  itemBuilder: (context, i) =>
                      _row(context, streams[i], thumbs[streams[i].id]),
                );
              },
            ),
    );
  }

  Widget _row(BuildContext context, HistoryStream stream, String? thumb) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    final start = stream.start.toLocal();
    final date =
        '${DateFormat.yMMMd(locale).format(start)}, '
        '${DateFormat.Hm(locale).format(start)}';
    final length = stream.end.difference(stream.start);
    final hours = length.inHours;
    final minutes = length.inMinutes % 60;
    final span = hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m';
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHigh,
      child: Icon(Icons.videocam_outlined, color: scheme.onSurfaceVariant),
    );
    return InkWell(
      onTap: () => onOpen(stream),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 128,
                height: 72,
                child: thumb == null
                    ? placeholder
                    : CachedNetworkImage(
                        imageUrl: thumb,
                        fit: BoxFit.cover,
                        placeholder: (_, _) => placeholder,
                        errorWidget: (_, _, _) => placeholder,
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stream.title.isEmpty
                        ? l10n.historyUntitledStream
                        : stream.title,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    stream.live
                        ? '$date · ${l10n.historyLiveNow}'
                        : '$date · $span',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (stream.game.isNotEmpty)
                    Text(
                      stream.game,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
