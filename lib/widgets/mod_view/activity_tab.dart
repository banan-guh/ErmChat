import 'package:flutter/material.dart';
import '../../chat/chat.dart';
import '../../util/mod_activity_format.dart';
import 'common.dart';

IconData _activityIcon(String action) {
  switch (action) {
    case 'ban':
    case 'timeout':
      return Icons.gavel;
    case 'unban':
    case 'untimeout':
      return Icons.undo;
    case 'delete':
    case 'clear':
      return Icons.delete_outline;
    case 'warn':
    case 'warn_ack':
      return Icons.warning_amber;
    case 'approve_unban_request':
      return Icons.check_circle_outline;
    case 'deny_unban_request':
      return Icons.cancel_outlined;
    case 'unban_resolved':
      return Icons.mark_email_read_outlined;
    case 'mod':
    case 'vip':
      return Icons.person_add;
    case 'unmod':
    case 'unvip':
      return Icons.person_remove;
    case 'shield_on':
    case 'shield_off':
    case 'suspicious_flag':
      return Icons.shield;
    case 'automod_settings':
      return Icons.auto_fix_high;
    case 'shoutout':
      return Icons.campaign;
    case 'raid':
    case 'unraid':
      return Icons.flight_takeoff;
    case 'add_blocked_term':
    case 'remove_blocked_term':
    case 'add_permitted_term':
    case 'remove_permitted_term':
      return Icons.block;
    case 'slow':
    case 'slowoff':
    case 'followers':
    case 'followersoff':
    case 'emoteonly':
    case 'emoteonlyoff':
    case 'subscribers':
    case 'subscribersoff':
    case 'uniquechat':
    case 'uniquechatoff':
      return Icons.tune;
    default:
      return Icons.info_outline;
  }
}

class ActivityTab extends StatelessWidget {
  const ActivityTab({super.key, required this.channel, required this.chat});

  final String channel;
  final Chat chat;

  @override
  Widget build(BuildContext context) {
    final mod = chat.channelFor(channel)?.moderation;
    if (mod == null) {
      return const ModEmpty(
        icon: Icons.auto_awesome_outlined,
        title: 'No moderation activity yet.',
        subtitle: 'Bans, timeouts and mod actions will show here.',
      );
    }
    return ValueListenableBuilder<int>(
      valueListenable: mod.modFeedVersion,
      builder: (_, _, _) {
        final feed = mod.feed;
        if (feed.isEmpty) {
          return const ModEmpty(
            icon: Icons.auto_awesome_outlined,
            title: 'No moderation activity yet.',
            subtitle: 'Bans, timeouts and mod actions will show here.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
          itemCount: feed.length,
          itemBuilder: (context, i) {
            final entry = feed[i];
            final scheme = Theme.of(context).colorScheme;
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _activityIcon(entry.action),
                  size: 22,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              title: Text(formatModActivity(entry)),
              subtitle: Text(
                '${entry.moderator} · ${modRelativeAgo(entry.at)}',
              ),
            );
          },
        );
      },
    );
  }
}
