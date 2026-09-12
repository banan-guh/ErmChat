import '../chat/channel/moderation.dart';
import '../chat/chat.dart';
import '../client/session.dart';
import '../eventsub/decode/events.dart';
import '../irc/decode/copy.dart' show buildBanText;
import '../util/duration_format.dart';
import '../util/log.dart';
import '../util/mod_activity_format.dart' show formatModActivity;

/// One IRC ban/timeout, tracked for stack folding: repeated identical
/// moderation events inside the dedup window collapse into one system line
/// with a "(N times)" suffix.
class _BanMeta {
  final String user;
  final bool isTimeout;
  int stackCount = 1;
  DateTime lastEvent;
  String? firstMessageId;

  _BanMeta({required this.user, required this.isTimeout})
    : lastEvent = DateTime.now();
}

/// Single ingest owner for moderation facts. IRC echoes and the EventSub
/// `channel.moderate` stream both route here, so the precedence rule (EventSub
/// when its subscription is live, IRC otherwise) is decided once, and the
/// kernel write, system line, feed row, and analytics report happen once per
/// real action.
class ModerationHub {
  ModerationHub({
    required this.chat,
    required this.session,
    required this.isModerationActive,
    required this.onSystemMessage,
    this.onAnalyticsModeration,
    required this.onSelfTimeoutArmed,
    required this.onSelfTimeoutCleared,
  });

  final Chat chat;
  final Session session;
  final bool Function(String channel) isModerationActive;
  final void Function(String channel, String text) onSystemMessage;
  final void Function(String channel, bool isTimeout)? onAnalyticsModeration;

  /// Arms the manager-owned send gate when our own timeout lands.
  final void Function(String channel, DateTime until) onSelfTimeoutArmed;

  /// Clears the manager-owned send gate on unban/untimeout.
  final void Function(String channel) onSelfTimeoutCleared;

  final _recentBanMeta = <String, List<_BanMeta>>{};
  static const _banDedupWindowSeconds = 10;

  // ---- IRC echoes ----------------------------------------------------------

  void onIrcDelete({
    required String channel,
    required String messageId,
    required String user,
    required String text,
  }) {
    final found =
        chat.channelFor(channel)?.messages.markDeleted(messageId) ?? false;
    // While channel.moderate v2 is active, deletions come from EventSub (with
    // moderator and body) - skip the IRC system line.
    if (found && !isModerationActive(channel)) {
      onSystemMessage(
        channel,
        'A message from $user was deleted saying: "$text".',
      );
    }
  }

  void onIrcClear(String channel) {
    // With channel.moderate active, clears come from EventSub with the
    // moderator's name - skip the IRC copy.
    if (isModerationActive(channel)) return;
    chat.channelFor(channel)?.messages.markAllDeleted();
    onSystemMessage(channel, 'Chat was cleared.');
  }

  void onIrcBan({
    required String channel,
    required String user,
    required bool isTimeout,
    required int? duration,
  }) {
    logDebug(
      '[Moderation] IRC ban received: user=$user channel=$channel isTimeout=$isTimeout',
    );
    chat.channelFor(channel)?.messages.markUserDeleted(user);
    _armSelfTimeout(channel, user, isTimeout, duration);
    // While channel.moderate v2 is active, the EventSub copy reports analytics
    // and renders the line, so the IRC copy stops here. This is the one place
    // the precedence is decided.
    if (isModerationActive(channel)) return;
    onAnalyticsModeration?.call(channel, isTimeout);
    final result = _processBanInChannel(channel, user, isTimeout);
    final isSelf = user.toLowerCase() == session.login?.toLowerCase();
    final base = isSelf
        ? (isTimeout
              ? 'You are timed out${duration != null ? ' for ${formatSeconds(duration)}' : ''}'
              : 'You were banned')
        : buildBanText(user: user, isTimeout: isTimeout, durationSec: duration);
    final stacked = result.stackCount > 1
        ? ' (${result.stackCount} times)'
        : '';
    // buildBanText already ends with a period.
    final trimmed = base.endsWith('.')
        ? base.substring(0, base.length - 1)
        : base;
    final text = '$trimmed$stacked.';
    logDebug('[Moderation] IRC ban system message: $text');

    if (result.stackCount > 1) {
      if (result.meta.firstMessageId != null) {
        chat
            .channelFor(channel)
            ?.messages
            .updateText(result.meta.firstMessageId!, text);
        return;
      }
    }
    onSystemMessage(channel, text);
    final msgs = chat.channelFor(channel)?.messages.items;
    result.meta.firstMessageId = msgs != null && msgs.isNotEmpty
        ? msgs.first.messageId
        : null;
  }

  /// IRC-only ban/stack tracking within a 10s window (IRC is the single ban
  /// source since EventSub channel.ban subscriptions were dropped).
  ({int stackCount, _BanMeta meta}) _processBanInChannel(
    String channel,
    String user,
    bool isTimeout,
  ) {
    final now = DateTime.now();
    final metas = _recentBanMeta.putIfAbsent(channel, () => []);

    metas.removeWhere(
      (m) => now.difference(m.lastEvent).inSeconds >= _banDedupWindowSeconds,
    );

    final existing = metas.cast<_BanMeta?>().firstWhere(
      (m) => m!.user == user && m.isTimeout == isTimeout,
      orElse: () => null,
    );

    if (existing != null) {
      existing.stackCount++;
      existing.lastEvent = now;
      return (stackCount: existing.stackCount, meta: existing);
    }

    final meta = _BanMeta(user: user, isTimeout: isTimeout);
    metas.add(meta);
    return (stackCount: 1, meta: meta);
  }

  void _armSelfTimeout(
    String channel,
    String user,
    bool isTimeout,
    int? duration,
  ) {
    final selfLogin = session.login?.toLowerCase();
    if (selfLogin == null || user.toLowerCase() != selfLogin) return;
    // Zero-length timeouts are already spent - don't arm a gate for them.
    if (isTimeout && duration != null && duration > 0) {
      onSelfTimeoutArmed(
        channel,
        DateTime.now().add(Duration(seconds: duration)),
      );
    }
  }

  // ---- EventSub channel.moderate ------------------------------------------

  // channel.moderate v2 events in channels with an active subscription:
  // renders moderation system messages, applies message deletions, tracks the
  // ban roster and warn log, and logs every action to the feed.
  void onModeration(ModerationEvent event) {
    if (!isModerationActive(event.channel)) return;

    final mod = event.moderatorName;
    final target = event.targetName;
    final selfLogin = session.login?.toLowerCase();
    final isSelfTarget =
        target != null &&
        selfLogin != null &&
        target.toLowerCase() == selfLogin;
    final reason = (event.reason != null && event.reason!.isNotEmpty)
        ? ': "${event.reason}"'
        : '';

    final entry = ModActivityEntry(
      at: DateTime.now(),
      channel: event.channel,
      action: event.rawAction,
      moderator: mod,
      target: target,
      reason: event.reason,
      durationSeconds: event.durationSeconds,
      terms: event.terms,
    );
    final line = formatModActivity(entry);
    // A malformed event can omit the target; the formatter's 'someone'
    // fallback would replace the old literal "null", so keep that case.
    String lineOr(String raw) => target == null ? raw : line;
    void feed() => chat.channelFor(event.channel)?.moderation.addFeed(entry);

    switch (event.action) {
      case ModerationAction.delete:
        if (event.messageId != null) {
          chat
              .channelFor(event.channel)
              ?.messages
              .markDeleted(event.messageId!);
        }
        final body =
            (event.messageBody != null && event.messageBody!.isNotEmpty)
            ? ': "${event.messageBody}"'
            : '';
        onSystemMessage(
          event.channel,
          '$mod deleted a message from $target$body.',
        );
        feed();
        break;
      case ModerationAction.clear:
        chat.channelFor(event.channel)?.messages.markAllDeleted();
        onSystemMessage(event.channel, line);
        feed();
        break;
      case ModerationAction.ban:
      case ModerationAction.timeout:
        onAnalyticsModeration?.call(
          event.channel,
          event.action == ModerationAction.timeout,
        );
        if (target != null) {
          chat.channelFor(event.channel)?.messages.markUserDeleted(target);
          chat
              .channelFor(event.channel)
              ?.moderation
              .putBan(
                BanEntry(
                  at: DateTime.now(),
                  channel: event.channel,
                  login: target,
                  expiresAt:
                      event.action == ModerationAction.timeout &&
                          event.durationSeconds != null
                      ? DateTime.now().add(
                          Duration(seconds: event.durationSeconds!),
                        )
                      : null,
                  reason: event.reason,
                  moderator: mod,
                ),
              );
        }
        final duration = event.durationSeconds != null
            ? ' for ${formatSeconds(event.durationSeconds!)}'
            : '';
        if (isSelfTarget &&
            event.action == ModerationAction.timeout &&
            event.durationSeconds != null &&
            // Zero-length timeouts are already spent - no gate to arm.
            event.durationSeconds! > 0) {
          onSelfTimeoutArmed(
            event.channel,
            DateTime.now().add(Duration(seconds: event.durationSeconds!)),
          );
        }
        onSystemMessage(
          event.channel,
          isSelfTarget
              ? 'You were ${event.action == ModerationAction.timeout ? 'timed out$duration' : 'banned'}$reason by $mod.'
              : lineOr(
                  '$mod ${event.action == ModerationAction.timeout ? 'timed out' : 'banned'} $target$duration$reason.',
                ),
        );
        feed();
        break;
      case ModerationAction.unban:
      case ModerationAction.untimeout:
        if (isSelfTarget) onSelfTimeoutCleared(event.channel);
        if (target != null) {
          chat.channelFor(event.channel)?.moderation.removeBan(target);
        }
        onSystemMessage(
          event.channel,
          isSelfTarget
              ? 'You were unbanned by $mod.'
              : lineOr('$mod unbanned $target.'),
        );
        feed();
        break;
      case ModerationAction.mod:
        onSystemMessage(event.channel, lineOr('$mod modded $target.'));
        feed();
        break;
      case ModerationAction.unmod:
        onSystemMessage(event.channel, lineOr('$mod unmodded $target.'));
        feed();
        break;
      case ModerationAction.vip:
        onSystemMessage(event.channel, lineOr('$mod added $target as a VIP.'));
        feed();
        break;
      case ModerationAction.unvip:
        onSystemMessage(
          event.channel,
          lineOr('$mod removed $target as a VIP.'),
        );
        feed();
        break;
      case ModerationAction.warn:
        if (target != null && target.isNotEmpty) {
          chat
              .channelFor(event.channel)
              ?.moderation
              .addWarning(
                WarnEntry(
                  at: DateTime.now(),
                  channel: event.channel,
                  target: target,
                  moderator: mod,
                  reason: event.reason,
                ),
              );
        }
        onSystemMessage(event.channel, lineOr('$mod warned $target$reason.'));
        feed();
        break;
      case ModerationAction.slow:
      case ModerationAction.slowOff:
      case ModerationAction.followers:
      case ModerationAction.followersOff:
      case ModerationAction.emoteOnly:
      case ModerationAction.emoteOnlyOff:
      case ModerationAction.subscribers:
      case ModerationAction.subscribersOff:
      case ModerationAction.uniqueChat:
      case ModerationAction.uniqueChatOff:
      case ModerationAction.raid:
      case ModerationAction.unraid:
        feed();
        onSystemMessage(event.channel, line);
        break;
      case ModerationAction.addBlockedTerm:
      case ModerationAction.removeBlockedTerm:
      case ModerationAction.addPermittedTerm:
      case ModerationAction.removePermittedTerm:
        feed();
        onSystemMessage(event.channel, line);
        break;
      case ModerationAction.approveUnbanRequest:
      case ModerationAction.denyUnbanRequest:
        feed();
        onSystemMessage(
          event.channel,
          target != null && target.isNotEmpty
              ? line
              : '$mod ${event.action == ModerationAction.approveUnbanRequest ? 'approved' : 'denied'} an unban request$reason.',
        );
        break;
      case ModerationAction.unknown:
        // Future actions still land in the feed under their wire name.
        feed();
        break;
    }
  }
}
