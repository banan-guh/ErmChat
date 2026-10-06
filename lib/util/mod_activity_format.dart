// One-line summaries for moderation feed entries. Pure data-to-text.

import '../l10n/l10n.dart';
import '../models/moderation_entries.dart' show ModActivityEntry;
import 'duration_format.dart';

String formatModActivity(ModActivityEntry entry, {AppLocalizations? l}) {
  l ??= englishStrings();
  final mod = entry.moderator;
  final target = entry.target ?? l.modActSomeone;
  final reason = (entry.reason != null && entry.reason!.isNotEmpty)
      ? l.modActReasonSuffix(entry.reason!)
      : '';
  final duration = entry.durationSeconds != null
      ? l.modActDurationSuffix(formatSeconds(entry.durationSeconds!))
      : '';
  switch (entry.action) {
    case 'ban':
      return l.modActBan(mod, target, reason);
    case 'timeout':
      return l.modActTimeout(mod, target, duration, reason);
    case 'unban':
    case 'untimeout':
      return l.modActUnban(mod, target);
    case 'delete':
      return l.modActDelete(mod, target);
    case 'clear':
      return l.modActClear(mod);
    case 'mod':
      return l.modActMod(mod, target);
    case 'unmod':
      return l.modActUnmod(mod, target);
    case 'vip':
      return l.modActVip(mod, target);
    case 'unvip':
      return l.modActUnvip(mod, target);
    case 'warn':
      return l.modActWarn(mod, target, reason);
    case 'warn_ack':
      return l.modActWarnAck(target);
    case 'slow':
      return l.modActSlowOn(mod);
    case 'slowoff':
      return l.modActSlowOff(mod);
    case 'followers':
      return l.modActFollowersOn(mod);
    case 'followersoff':
      return l.modActFollowersOff(mod);
    case 'emoteonly':
      return l.modActEmoteOnlyOn(mod);
    case 'emoteonlyoff':
      return l.modActEmoteOnlyOff(mod);
    case 'subscribers':
      return l.modActSubsOnlyOn(mod);
    case 'subscribersoff':
      return l.modActSubsOnlyOff(mod);
    case 'uniquechat':
      return l.modActUniqueOn(mod);
    case 'uniquechatoff':
      return l.modActUniqueOff(mod);
    case 'raid':
      return l.modActRaid(mod);
    case 'unraid':
      return l.modActUnraid(mod);
    case 'shield_on':
      return l.modActShieldOn(mod);
    case 'shield_off':
      return l.modActShieldOff(mod);
    case 'shoutout':
      return l.modActShoutout(mod, target);
    case 'approve_unban_request':
      return l.modActApproveUnban(mod, target, reason);
    case 'deny_unban_request':
      return l.modActDenyUnban(mod, target, reason);
    case 'unban_resolved':
      return l.modActResolveUnban(mod, target, reason);
    case 'automod_settings':
      return l.modActAutomod(mod);
    case 'suspicious_flag':
      return l.modActSuspicious(mod, target, reason);
    case 'add_blocked_term':
    case 'remove_blocked_term':
    case 'add_permitted_term':
    case 'remove_permitted_term':
      return formatTermAction(mod, entry.action, entry.terms, l);
    default:
      return l.modActOther(mod, entry.action.replaceAll('_', ' '));
  }
}

String formatTermAction(
  String mod,
  String action,
  List<String> terms,
  AppLocalizations l,
) {
  final permitted = action.contains('permitted');
  final added = action.startsWith('add');
  if (terms.length == 1) {
    final t = terms.first;
    return permitted
        ? (added
              ? l.modActAddedPermittedOne(mod, t)
              : l.modActRemovedPermittedOne(mod, t))
        : (added
              ? l.modActAddedBlockedOne(mod, t)
              : l.modActRemovedBlockedOne(mod, t));
  }
  if (terms.length > 1) {
    final n = terms.length;
    return permitted
        ? (added
              ? l.modActAddedPermittedMany(mod, n)
              : l.modActRemovedPermittedMany(mod, n))
        : (added
              ? l.modActAddedBlockedMany(mod, n)
              : l.modActRemovedBlockedMany(mod, n));
  }
  return permitted
      ? (added
            ? l.modActAddedPermittedUnnamed(mod)
            : l.modActRemovedPermittedUnnamed(mod))
      : (added
            ? l.modActAddedBlockedUnnamed(mod)
            : l.modActRemovedBlockedUnnamed(mod));
}

/// Ban or timeout line without its closing period, for IRC CLEARCHAT rows.
/// [self] reads in the second person.
String banNoticeText(
  AppLocalizations l, {
  required String user,
  required bool isTimeout,
  int? durationSec,
  bool self = false,
}) {
  if (!isTimeout) return self ? l.selfBanned : l.userWasBanned(user);
  final duration = durationSec == null ? null : formatSeconds(durationSec);
  if (self) {
    return duration == null ? l.selfTimedOut : l.selfTimedOutFor(duration);
  }
  return duration == null
      ? l.userWasTimedOut(user)
      : l.userWasTimedOutFor(user, duration);
}
