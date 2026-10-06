import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../util/date_format.dart';
import '../../util/mod_activity_format.dart';
import 'scope.dart';
import 'widgets.dart';

IconData _activityIcon(String action) => switch (action) {
  'ban' || 'timeout' => Icons.gavel,
  'unban' || 'untimeout' => Icons.undo,
  'delete' || 'clear' => Icons.delete_outline,
  'warn' || 'warn_ack' => Icons.warning_amber,
  'approve_unban_request' => Icons.check_circle_outline,
  'deny_unban_request' => Icons.cancel_outlined,
  'unban_resolved' => Icons.mark_email_read_outlined,
  'mod' || 'vip' => Icons.person_add,
  'unmod' || 'unvip' => Icons.person_remove,
  'shield_on' || 'shield_off' || 'suspicious_flag' => Icons.shield,
  'automod_settings' => Icons.auto_fix_high,
  'shoutout' => Icons.campaign,
  'raid' || 'unraid' => Icons.flight_takeoff,
  'add_blocked_term' ||
  'remove_blocked_term' ||
  'add_permitted_term' ||
  'remove_permitted_term' => Icons.block,
  'slow' ||
  'slowoff' ||
  'followers' ||
  'followersoff' ||
  'emoteonly' ||
  'emoteonlyoff' ||
  'subscribers' ||
  'subscribersoff' ||
  'uniquechat' ||
  'uniquechatoff' => Icons.tune,
  _ => Icons.info_outline,
};

/// Live moderation feed for the channel.
class ActivityTab extends StatelessWidget {
  const ActivityTab({super.key, required this.mod});

  final ModContext mod;

  @override
  Widget build(BuildContext context) {
    final empty = ModEmpty(
      icon: Icons.auto_awesome_outlined,
      title: mod.l10n.noModActivity,
      subtitle: mod.l10n.noModActivityHint,
    );
    final moderation = mod.moderation;
    if (moderation == null) return empty;
    return ValueListenableBuilder<int>(
      valueListenable: moderation.modFeedVersion,
      builder: (context, _, _) {
        final feed = moderation.feed;
        if (feed.isEmpty) return empty;
        final scheme = Theme.of(context).colorScheme;
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
          itemCount: feed.length,
          itemBuilder: (context, i) {
            final entry = feed[i];
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: CircleAvatar(
                radius: 20,
                backgroundColor: scheme.surfaceContainerHighest,
                child: Icon(
                  _activityIcon(entry.action),
                  size: 22,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              title: Text(formatModActivity(entry, l: context.l10n)),
              subtitle: Text(
                '${entry.moderator} · ${formatAgo(entry.at, l: context.l10n)}',
              ),
            );
          },
        );
      },
    );
  }
}
