// One-line summaries for moderation feed entries. Pure data-to-text.
import '../models/moderation_entries.dart' show ModActivityEntry;
import 'duration_format.dart';

String formatModActivity(ModActivityEntry entry) {
  final mod = entry.moderator;
  final target = entry.target ?? 'someone';
  final reason = (entry.reason != null && entry.reason!.isNotEmpty)
      ? ': "${entry.reason}"'
      : '';
  final duration = entry.durationSeconds != null
      ? ' for ${formatSeconds(entry.durationSeconds!)}'
      : '';
  switch (entry.action) {
    case 'ban':
      return '$mod banned $target$reason.';
    case 'timeout':
      return '$mod timed out $target$duration$reason.';
    case 'unban':
    case 'untimeout':
      return '$mod unbanned $target.';
    case 'delete':
      return '$mod deleted a message from $target.';
    case 'clear':
      return '$mod cleared the chat.';
    case 'mod':
      return '$mod modded $target.';
    case 'unmod':
      return '$mod unmodded $target.';
    case 'vip':
      return '$mod added $target as a VIP.';
    case 'unvip':
      return '$mod removed $target as a VIP.';
    case 'warn':
      return '$mod warned $target$reason.';
    case 'warn_ack':
      return '$target acknowledged a warning.';
    case 'slow':
      return '$mod enabled slow mode.';
    case 'slowoff':
      return '$mod disabled slow mode.';
    case 'followers':
      return '$mod enabled followers-only mode.';
    case 'followersoff':
      return '$mod disabled followers-only mode.';
    case 'emoteonly':
      return '$mod enabled emote-only mode.';
    case 'emoteonlyoff':
      return '$mod disabled emote-only mode.';
    case 'subscribers':
      return '$mod enabled subscribers-only mode.';
    case 'subscribersoff':
      return '$mod disabled subscribers-only mode.';
    case 'uniquechat':
      return '$mod enabled unique chat.';
    case 'uniquechatoff':
      return '$mod disabled unique chat.';
    case 'raid':
      return '$mod started a raid.';
    case 'unraid':
      return '$mod cancelled the raid.';
    case 'shield_on':
      return '$mod enabled Shield Mode.';
    case 'shield_off':
      return '$mod disabled Shield Mode.';
    case 'shoutout':
      return '$mod shouted out $target.';
    case 'approve_unban_request':
      return '$mod approved $target\'s unban request$reason.';
    case 'deny_unban_request':
      return '$mod denied $target\'s unban request$reason.';
    case 'unban_resolved':
      return '$mod resolved $target\'s unban request$reason.';
    case 'automod_settings':
      return '$mod updated AutoMod settings.';
    case 'suspicious_flag':
      return '$mod flagged $target$reason.';
    case 'add_blocked_term':
    case 'remove_blocked_term':
    case 'add_permitted_term':
    case 'remove_permitted_term':
      return formatTermAction(mod, entry.action, entry.terms);
    default:
      return '$mod did ${entry.action.replaceAll('_', ' ')}.';
  }
}

String formatTermAction(String mod, String action, List<String> terms) {
  final kind = action.contains('permitted') ? 'permitted term' : 'blocked term';
  final verb = action.startsWith('add') ? 'added' : 'removed';
  if (terms.length == 1) return '$mod $verb $kind "${terms.first}".';
  if (terms.length > 1) return '$mod $verb ${terms.length} ${kind}s.';
  return '$mod $verb a $kind.';
}
