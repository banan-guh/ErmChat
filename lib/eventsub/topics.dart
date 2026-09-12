import 'dart:async';

import '../chat/chat.dart';
import '../client/session.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../util/log.dart';
import 'transport/connection.dart';

/// Owns the EventSub subscription lifecycle: the per-family active/skip sets,
/// the seven subscribe paths, resubscribe, and the gate predicates.
class EventSubTopics {
  EventSubTopics({
    required this.twitchApi,
    required this.twitchAuth,
    required this.session,
    required this.chat,
    required this.eventSub,
  });

  final TwitchApi twitchApi;
  final TwitchAuth twitchAuth;
  final Session session;
  final Chat chat;
  final EventSubService eventSub;

  // Channels with an active channel.moderate v2 subscription. While present,
  // moderation system messages come from EventSub (richer data) instead of
  // IRC CLEARCHAT/CLEARMSG.
  final _moderationChannels = <String>{};
  // Channels where the channel.moderate v2 subscription was rejected with a 403
  // (not a moderator). Persists across EventSub session reconnects so we don't
  // re-attempt (and re-log) the subscription on every reconnect for the current
  // account.
  final _moderationSkippedChannels = <String>{};
  // Same pair for the AutoMod queue (automod.message.hold/update v2): the
  // 403 skip persists per account, the active set dies with the session.
  final _automodChannels = <String>{};
  final _automodSkippedChannels = <String>{};
  // Same pair for the mod feed (shield begin/end, shoutout create/receive,
  // warning send/acknowledge): moderator-scoped complements to
  // channel.moderate that carry genuinely new information.
  final _feedChannels = <String>{};
  final _feedSkippedChannels = <String>{};
  // Same pair for the inbox (unban request create/resolve, public AutoMod
  // term updates): drives inbox/terms tab reloads.
  final _inboxChannels = <String>{};
  final _inboxSkippedChannels = <String>{};
  // Same pair for trust (AutoMod settings updates, suspicious user
  // message/update): drives the Setup tab and the flagged-user context.
  final _trustChannels = <String>{};
  final _trustSkippedChannels = <String>{};
  // Same pair for points (custom reward add/update/remove, redemption
  // add/update): drives the Channel tab queue. Broadcaster-only and isolated
  // from the widget subs: a non-monetized channel fails these without
  // affecting hype train/poll/prediction.
  final _pointsChannels = <String>{};
  final _pointsSkippedChannels = <String>{};
  // Channels with an active hype train / poll / prediction widget subscription
  // (broadcaster-only widgets row). Same lifecycle as
  // _moderationChannels: cleared when the EventSub session dies.
  final _widgetChannels = <String>{};
  // Channels where the widget subscriptions were rejected with a 403 (not the
  // broadcaster). Persists so we don't re-attempt doomed subscriptions.
  final _widgetSkippedChannels = <String>{};

  /// Whether the EventSub channel.moderate v2 subscription is active for a
  /// channel; while it is, IRC moderation echoes and room-mode NOTICEs are
  /// suppressed in favor of the richer EventSub copies.
  bool isModerationActive(String channel) =>
      _moderationChannels.contains(channel);

  /// Whether the AutoMod queue subscriptions are active for a channel.
  bool isAutomodActive(String channel) => _automodChannels.contains(channel);

  /// Whether the mod-feed subscriptions are active for a channel.
  bool isFeedActive(String channel) => _feedChannels.contains(channel);

  /// Whether the inbox subscriptions are active for a channel.
  bool isInboxActive(String channel) => _inboxChannels.contains(channel);

  /// Whether the trust subscriptions are active for a channel.
  bool isTrustActive(String channel) => _trustChannels.contains(channel);

  /// Whether the points subscriptions are active for a channel.
  bool isPointsActive(String channel) => _pointsChannels.contains(channel);

  /// Whether the broadcaster-only widget subscriptions are active for a
  /// channel; while they are, EventSub hype train/poll/prediction events are
  /// surfaced instead of being dropped as unsolicited.
  bool isWidgetActive(String channel) => _widgetChannels.contains(channel);

  /// Whether the session user owns this channel. Broadcaster-only widgets
  /// and the Channel tab gate on this, not on moderator status.
  bool isBroadcaster(String channel) =>
      session.userId != null &&
      session.userId == chat.channelFor(channel)?.info.broadcasterId;

  /// Session-scoped subscription state dies with the EventSub session; IRC
  /// fallback resumes until [resubscribeEventSubChannels] runs again.
  void clearSessionState() {
    _moderationChannels.clear();
    _automodChannels.clear();
    _feedChannels.clear();
    _inboxChannels.clear();
    _trustChannels.clear();
    _pointsChannels.clear();
    _widgetChannels.clear();
  }

  /// 403 skip sets are account-scoped: a non-mod account's rejection must not
  /// permanently disable moderation/widgets for a mod account on the same
  /// channel after a switch.
  void resetAccountScope() {
    _moderationSkippedChannels.clear();
    _automodSkippedChannels.clear();
    _feedSkippedChannels.clear();
    _inboxSkippedChannels.clear();
    _trustSkippedChannels.clear();
    _pointsSkippedChannels.clear();
    _widgetSkippedChannels.clear();
  }

  /// Drops per-channel subscription state (channel left). Skip sets survive:
  /// they record the account's rejection, which a rejoin would hit again.
  void forgetChannel(String channel) {
    _moderationChannels.remove(channel);
    _automodChannels.remove(channel);
    _feedChannels.remove(channel);
    _inboxChannels.remove(channel);
    _trustChannels.remove(channel);
    _pointsChannels.remove(channel);
    _widgetChannels.remove(channel);
  }

  /// Subscribes the EventSub families for a joined channel.
  void subscribeChannel(String channelName, String channelUserId) {
    if (session.login == null || session.userId == null) return;
    // Guard like resubscribeEventSubChannels: a connected-edge resubscribe
    // racing this join must not double-subscribe (409s dedupe, but each
    // attempt costs Helix calls and a redundant noteSubscribed). Widgets skip
    // the already-subscribed guard, preserving the join-path behavior.
    for (final family in _families) {
      if (family.skipIfActive && family.activeSet.contains(channelName)) {
        continue;
      }
      unawaited(_subscribeFamily(channelName, channelUserId, family));
    }
  }

  /// One row per family: types, condition scope, success rule, and the sets
  /// it touches. The rows keep each family's exact success rule and skip
  /// behavior.
  late final _families = <_TopicFamily>[
    _TopicFamily(
      name: 'subscribeModeration',
      types: const [('channel.moderate', '2')],
      success: _TopicSuccess.single,
      skipSet: _moderationSkippedChannels,
      activeSet: _moderationChannels,
    ),
    _TopicFamily(
      name: 'subscribeAutomod',
      types: const [
        ('automod.message.hold', '2'),
        ('automod.message.update', '2'),
      ],
      success: _TopicSuccess.all,
      skipSet: _automodSkippedChannels,
      activeSet: _automodChannels,
    ),
    _TopicFamily(
      name: 'subscribeFeed',
      types: const [
        ('channel.shield_mode.begin', '1'),
        ('channel.shield_mode.end', '1'),
        ('channel.shoutout.create', '1'),
        ('channel.shoutout.receive', '1'),
        ('channel.warning.send', '1'),
        ('channel.warning.acknowledge', '1'),
      ],
      success: _TopicSuccess.any,
      skipSet: _feedSkippedChannels,
      activeSet: _feedChannels,
    ),
    _TopicFamily(
      name: 'subscribeInbox',
      types: const [
        ('channel.unban_request.create', '1'),
        ('channel.unban_request.resolve', '1'),
        ('automod.terms.update', '1'),
      ],
      success: _TopicSuccess.any,
      skipSet: _inboxSkippedChannels,
      activeSet: _inboxChannels,
    ),
    _TopicFamily(
      name: 'subscribeTrust',
      types: const [
        ('automod.settings.update', '1'),
        ('channel.suspicious_user.message', '1'),
        ('channel.suspicious_user.update', '1'),
      ],
      success: _TopicSuccess.any,
      skipSet: _trustSkippedChannels,
      activeSet: _trustChannels,
    ),
    _TopicFamily(
      name: 'subscribePoints',
      types: const [
        ('channel.channel_points_custom_reward.add', '1'),
        ('channel.channel_points_custom_reward.update', '1'),
        ('channel.channel_points_custom_reward.remove', '1'),
        ('channel.channel_points_custom_reward_redemption.add', '1'),
        ('channel.channel_points_custom_reward_redemption.update', '1'),
      ],
      success: _TopicSuccess.any,
      skipSet: _pointsSkippedChannels,
      activeSet: _pointsChannels,
      broadcasterOnly: true,
    ),
    _TopicFamily(
      name: 'subscribeWidgets',
      types: const [
        ('channel.hype_train.begin', '2'),
        ('channel.hype_train.progress', '2'),
        ('channel.hype_train.end', '2'),
        ('channel.poll.begin', '1'),
        ('channel.poll.progress', '1'),
        ('channel.poll.end', '1'),
        ('channel.prediction.begin', '1'),
        ('channel.prediction.progress', '1'),
        ('channel.prediction.lock', '1'),
        ('channel.prediction.end', '1'),
      ],
      success: _TopicSuccess.all,
      skipSet: _widgetSkippedChannels,
      activeSet: _widgetChannels,
      broadcasterOnly: true,
      notify: false,
      failFast: true,
      skipIfActive: false,
    ),
  ];

  /// Runs one family's subscriptions: moderator- or broadcaster-scoped Helix
  /// calls, attempted at most once. A 403 on one type dooms the rest.
  Future<void> _subscribeFamily(
    String channelName,
    String channelUserId,
    _TopicFamily family,
  ) async {
    try {
      final auth = twitchAuth;
      if (!auth.isConfigured || session.userId == null) return;
      if (family.broadcasterOnly && session.userId != channelUserId) return;
      if (family.skipSet.contains(channelName)) return;
      // Not a retry loop: the subscription is attempted at most once. The
      // loop only bounds the wait (~3s) for the EventSub websocket session
      // to appear; a session that never shows up just skips this channel.
      for (int attempt = 0; attempt < 3; attempt++) {
        final sessionId = eventSub.sessionId;
        if (sessionId == null) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        if (attempt > 0) await Future.delayed(const Duration(seconds: 1));
        var subscribed = 0;
        var failed = false;
        for (final (type, version) in family.types) {
          // A 403 on one dooms the rest; skip the doomed calls.
          if (family.skipSet.contains(channelName)) break;
          final ok = await twitchApi.createEventSubSubscription(
            auth: auth,
            sessionId: sessionId,
            type: type,
            version: version,
            condition: family.broadcasterOnly
                ? {'broadcaster_user_id': channelUserId}
                : {
                    'broadcaster_user_id': channelUserId,
                    'moderator_user_id': session.userId!,
                  },
          );
          if (ok) {
            subscribed++;
            continue;
          }
          if (twitchApi.lastErrorStatus == 403) {
            family.skipSet.add(channelName);
            break;
          }
          logDebug(
            '[ChatConn] $type subscription failed for $channelName (${twitchApi.lastError ?? "unknown"})',
          );
          if (family.failFast) {
            failed = true;
            break;
          }
        }
        final complete =
            !failed &&
            (family.success == _TopicSuccess.all
                ? subscribed == family.types.length
                : subscribed > 0);
        if (complete) {
          family.activeSet.add(channelName);
          // The Mod View snapshots mod state at build; wake it so the new
          // rows appear without waiting for the next chat event.
          if (family.notify) {
            chat.channelFor(channelName)?.moderation.noteSubscribed();
          }
        }
        return;
      }
    } catch (_) {
      logDebug('[ChatConn] ${family.name} failed for $channelName');
    }
  }

  /// Re-creates the session-scoped EventSub subscriptions after a new session
  /// comes up (session_reconnect / keepalive reconnect). Skip sets and the
  /// already-subscribed sets are respected by the per-channel methods.
  void resubscribeEventSubChannels(List<String> channels) {
    final uid = session.userId;
    if (uid == null) return;
    for (final channel in channels) {
      final channelUserId = chat.channelFor(channel)?.info.broadcasterId;
      if (channelUserId == null) continue;
      for (final family in _families) {
        if (family.broadcasterOnly && uid != channelUserId) continue;
        if (family.activeSet.contains(channel)) continue;
        unawaited(_subscribeFamily(channel, channelUserId, family));
      }
    }
  }
}

/// When a topic family counts as subscribed.
enum _TopicSuccess {
  /// One subscription; success activates the family.
  single,

  /// Every type must succeed.
  all,

  /// At least one type must succeed.
  any,
}

/// One row of the subscription table: the Helix types, the condition scope,
/// the rule that activates the family, and the sets it touches.
class _TopicFamily {
  const _TopicFamily({
    required this.name,
    required this.types,
    required this.success,
    required this.skipSet,
    required this.activeSet,
    this.broadcasterOnly = false,
    this.notify = true,
    this.failFast = false,
    this.skipIfActive = true,
  });

  /// Log label for the catch line (subscribeModeration, ...).
  final String name;
  final List<(String, String)> types;
  final _TopicSuccess success;
  final Set<String> skipSet;
  final Set<String> activeSet;

  /// True for points/widgets: broadcaster-only condition plus an upfront
  /// broadcaster gate so other channels fire no Helix calls.
  final bool broadcasterOnly;

  /// Whether success wakes the Mod View. False for widgets.
  final bool notify;

  /// Whether any failure aborts the family. True for widgets.
  final bool failFast;

  /// Whether the join path skips already-covered channels. False for
  /// widgets, preserving the join-path behavior.
  final bool skipIfActive;
}
