import 'dart:async';

import 'dart:ui' show Color;

import '../models/emote_fetch_tier.dart';
import '../models/twitch_message.dart';
import '../util/duration_format.dart';
import '../util/log.dart';
import 'twitch_irc.dart' show IrcReadService;
import '../util/text_bypass.dart';
import 'chat_store.dart';
import 'emote_manager.dart';
import 'ignore_manager.dart';
import 'ping_manager.dart';
import 'twitch_auth.dart';
import 'twitch_badge_service.dart';
import 'twitch_irc.dart'
    show
        IrcChannelClearEvent,
        IrcMessage,
        IrcMessageDeletedEvent,
        IrcService,
        buildBanText,
        parseIrcChatMessage;
import 'user_store.dart';

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

/// The chat-content domain of the pipeline: turns incoming IRC traffic
/// (PRIVMSG, CLEARMSG, CLEARCHAT, channel clears, own-message echoes) into
/// [ChatStore] mutations and feature-sink calls. Pure translation: policy
/// lives behind the consulted predicates (pings, ignores, blocks) and every
/// state law lives in the store.
class ChatIngestion {
  ChatIngestion({
    required this.irc,
    required this.ircRead,
    required this.store,
    required this.userStore,
    required this.emoteManager,
    required this.badgeService,
    required this.twitchAuth,
    this.ignoreManager,
    this.pingManager,
    required this.mentionsChannel,
    required this.getMaxMessagesPerChannel,
    required this.getSelectedChannel,
    this.isChatReady,
    this.isBlocked,
    this.getSharedChatMode,
    required this.isModerationActive,
    required this.onSelfTimeoutArmed,
    required this.onSelfTimeoutCleared,
    required this.onSystemMessage,
    this.onAnalyticsMessage,
    this.onAnalyticsModeration,
    this.onChatMessage,
    this.onMention,
  });

  final IrcService irc;
  final IrcReadService ircRead;
  final ChatStore store;
  final UserStore userStore;
  final EmoteManager emoteManager;
  final TwitchBadgeService badgeService;
  final TwitchAuth twitchAuth;
  final IgnoreManager? ignoreManager;
  final PingManager? pingManager;

  final String mentionsChannel;
  final int Function() getMaxMessagesPerChannel;
  final String? Function() getSelectedChannel;
  final bool Function()? isChatReady;
  final bool Function(String login)? isBlocked;
  final String Function()? getSharedChatMode;

  /// Whether the EventSub channel.moderate subscription is active for a
  /// channel; when true, IRC moderation echoes are suppressed in favor of
  /// the richer EventSub copies.
  final bool Function(String channel) isModerationActive;

  /// Own timeouts arm the input-box cooldown.
  final void Function(String channel, DateTime until) onSelfTimeoutArmed;

  /// A successfully echoed own message proves the send was accepted; clear
  /// any stale self-timeout gate so the input box stops showing a countdown
  /// for a timeout Twitch already lifted (non-mods get no untimeout signal,
  /// so this echo is the only reliable heal).
  final void Function(String channel) onSelfTimeoutCleared;

  final void Function(
    String channel,
    String text, {
    Color? accent,
    String? messageId,
  })
  onSystemMessage;

  final void Function(String channel, TwitchMessage msg)? onAnalyticsMessage;
  final void Function(String channel, bool isTimeout)? onAnalyticsModeration;
  final void Function(String channel, TwitchMessage msg)? onChatMessage;
  final void Function(String channel, TwitchMessage msg)? onMention;

  bool _disposed = false;
  final _recentBanMeta = <String, List<_BanMeta>>{};
  static const _banDedupWindowSeconds = 10;
  final _inflightSourceData = <String, Future<void>>{};

  /// Subscribes to every content stream. Returns the subscriptions for the
  /// caller's dispose bookkeeping.
  List<StreamSubscription<void>> attach() {
    return [
      ircRead.onMessage.listen(onMessage),
      ircRead.onMessageDeleted.listen(_onMessageDeleted),
      ircRead.onBan.listen(
        (event) => _handleBanEvent(
          channel: event.channel,
          user: event.user,
          isTimeout: event.isTimeout,
          duration: event.duration,
        ),
      ),
      ircRead.onChannelClear.listen(_onChannelClear),
      ircRead.onOwnMessage.listen(onOwnIrcMessage),
    ];
  }

  void dispose() {
    _disposed = true;
  }

  // ---- PRIVMSG ------------------------------------------------------------

  /// Translates one live chat message under the pipeline policies (blocks,
  /// ignores, pings, shared-chat mode) and hands it to the store.
  void onMessage(TwitchMessage msg) {
    if (_disposed) return;

    // Chat content is hidden until the blocked-users list has been applied,
    // and blocked users' messages never appear at all.
    if (isChatReady?.call() == false) return;
    if (!msg.isSystem && isBlocked?.call(msg.login) == true) return;

    final channel = msg.channel;
    if (channel == null) return;

    // Local ignores: ignored users' messages are dropped outright; keyword
    // rules in block mode drop the whole message, other keyword rules
    // rewrite the text (with emote position realignment) before ping
    // evaluation so rewritten messages can still highlight.
    final ignores = ignoreManager;
    if (!msg.isSystem && ignores != null) {
      if (ignores.isIgnored(msg.login)) return;
      if (ignores.isBlockedPhrase(msg.text)) return;
      rewriteMessageKeywords(msg, ignores);
    }

    // Ping evaluation runs before the shared-chat 'hide' check so a fresh
    // mirrored mention survives hide mode (the native copy dedups later).
    final highlightState = pingManager?.evaluate(msg);
    if (highlightState != null) {
      msg.highlight = highlightState;
    }

    // Shared-chat 'hide' mode: drop foreign messages entirely. Mentions and
    // system messages still flow through so the user doesn't miss pings.
    final sharedMode = getSharedChatMode?.call() ?? 'spotlight';
    if (sharedMode == 'hide' &&
        !msg.isSystem &&
        !msg.isHighlighted &&
        msg.sourceBroadcasterId != null) {
      return;
    }

    if (!msg.isSystem && msg.login.isNotEmpty) {
      final preferredName =
          msg.displayName.toLowerCase() == msg.login.toLowerCase()
          ? msg.displayName
          : msg.login;
      userStore.addUser(channel, preferredName);
    }

    if (!store.ingestMessage(
      msg,
      maxMessages: getMaxMessagesPerChannel(),
      selectedChannel: getSelectedChannel(),
      mentionsChannel: mentionsChannel,
    )) {
      return;
    }

    // Feed the emote usage registry from live chat: the emotes people are
    // actually staring at get cache priority. History/backfill are skipped
    // (they would re-touch old messages on every reconnect and skew the
    // 24-hour histograms).
    if (!msg.isHistory && !msg.isSystem) {
      final positions = msg.emotePositions;
      if (positions != null && positions.isNotEmpty) {
        for (final position in positions) {
          final emote = emoteManager.emoteById(position.emoteId);
          if (emote != null) emoteManager.markEmoteViewed(emote);
        }
      }
    }

    onAnalyticsMessage?.call(channel, msg);

    if (msg.sourceBroadcasterId != null && !msg.isHistory) {
      unawaited(_ensureSourceChannelData(msg.sourceBroadcasterId!));
    }

    final login = store.session.login?.toLowerCase();
    final state = msg.highlight;
    if (state != null && state.hasMention && msg.login != login) {
      onMention?.call(channel, msg);
    }

    precacheMessageEmotes(msg, channel);
    onChatMessage?.call(channel, msg);
  }

  /// Resolves a shared-chat source channel's identity and lazily loads its
  /// emote set on the first mirrored message (DankChat resolves emotes
  /// against the source channel but never fetches unjoined sets; loading
  /// here lets foreign third-party emotes render). The avatar fetch is
  /// in-flight deduplicated and cheap once cached. Concurrent mirrored
  /// messages for the same source coalesce onto one fetch via
  /// [_inflightSourceData] so the emote half is not duplicated.
  Future<void> _ensureSourceChannelData(String broadcasterId) async {
    final existing = _inflightSourceData[broadcasterId];
    if (existing != null) return existing;
    final future = _doEnsureSourceChannelData(broadcasterId);
    _inflightSourceData[broadcasterId] = future;
    try {
      await future;
    } finally {
      _inflightSourceData.remove(broadcasterId);
    }
  }

  Future<void> _doEnsureSourceChannelData(String broadcasterId) async {
    await badgeService.fetchChannelAvatar(twitchAuth, broadcasterId);
    if (_disposed) return;
    final login = badgeService.resolveChannelLogin(broadcasterId);
    if (login == null || login.isEmpty) return;
    if (!emoteManager.hasChannelCache(login)) {
      await emoteManager.resolveEmotes(login, broadcasterId);
    }
  }

  /// Pre-warms image decode for emotes the user is staring at right now.
  void precacheMessageEmotes(TwitchMessage msg, String channel) {
    if (emoteManager.tier == EmoteFetchTier.nothing) return;
    if (msg.isSystem || msg.isHistory) return;
    final lookupChannel = msg.sourceBroadcasterId != null
        ? badgeService.resolveChannelLogin(msg.sourceBroadcasterId!) ?? channel
        : channel;
    final found = emoteManager.matchEmotes(
      channel: lookupChannel,
      text: msg.text,
      positions: msg.emotePositions,
    );
    if (found.isNotEmpty) {
      emoteManager.enqueueSeenEmotes(found);
    }
  }

  // ---- Moderation echoes --------------------------------------------------

  void _onMessageDeleted(IrcMessageDeletedEvent event) {
    if (_disposed) return;
    final found = store.markMessageDeleted(event.channel, event.messageId);
    // While the channel.moderate v2 subscription is active, deletions come
    // from EventSub (with moderator + message body) - skip the IRC copy.
    if (found && !isModerationActive(event.channel)) {
      onSystemMessage(
        event.channel,
        'A message from ${event.user} was deleted saying: "${event.deletedMessageText}".',
      );
    }
  }

  void _handleBanEvent({
    required String channel,
    required String user,
    required bool isTimeout,
    required int? duration,
  }) {
    logDebug(
      '[Ingestion] IRC ban received: user=$user channel=$channel isTimeout=$isTimeout',
    );
    if (_disposed) return;
    onAnalyticsModeration?.call(channel, isTimeout);
    store.markUserMessagesDeleted(channel, user);
    // Track own timeouts for the input-box countdown. Runs before the
    // moderation-channel early return so the IRC and EventSub sources can't
    // double-count: both just re-arm the same expiry.
    final selfLogin = store.session.login?.toLowerCase();
    if (selfLogin != null && user.toLowerCase() == selfLogin) {
      // Zero-length timeouts are already spent - don't arm a gate for them.
      if (isTimeout && duration != null && duration > 0) {
        onSelfTimeoutArmed(
          channel,
          DateTime.now().add(Duration(seconds: duration)),
        );
      }
    }
    // While the channel.moderate v2 subscription is active, moderation
    // messages come from EventSub (with reason/duration) - skip the IRC copy.
    if (isModerationActive(channel)) return;
    final result = _processBanInChannel(channel, user, isTimeout);
    final isSelf = user.toLowerCase() == store.session.login?.toLowerCase();
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
    logDebug('[Ingestion] IRC ban system message: $text');

    if (result.stackCount > 1) {
      if (result.meta.firstMessageId != null) {
        store.updateMessageText(channel, result.meta.firstMessageId!, text);
        return;
      }
    }
    onSystemMessage(channel, text);
    final msgs = store.channelMessages[channel];
    result.meta.firstMessageId = msgs != null && msgs.isNotEmpty
        ? msgs.first.messageId
        : null;
  }

  // IRC-only ban/stack tracking within a 10s window (IRC is the single ban
  // source since EventSub channel.ban subscriptions were dropped).
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

  void _onChannelClear(IrcChannelClearEvent event) {
    if (_disposed) return;
    // With channel.moderate active, clears come from EventSub with the
    // moderator's name - skip the IRC copy.
    if (isModerationActive(event.channel)) return;
    store.markAllMessagesDeleted(event.channel);
    store.touchChannel(event.channel);
    onSystemMessage(event.channel, 'Chat was cleared.');
  }

  // ---- Own-message echo ---------------------------------------------------

  void onOwnIrcMessage(IrcMessage ircMsg) {
    if (_disposed) return;
    final channel = ircMsg.params.isNotEmpty
        ? ircMsg.params[0].substring(1)
        : null;
    if (channel == null || ircMsg.trailing == null) return;

    // Re-sync lastSentWireText from the echo so it doesn't drift if the
    // server modified the message (truncation, etc.). Skip commands since
    // they are never compared by the bypass logic.
    final original = ircMsg.trailing!;
    final previous = store.lastSentWireText[channel];
    if (previous != null &&
        !previous.startsWith('.') &&
        !previous.startsWith('/')) {
      if (stripInvisibleSuffix(previous) != stripInvisibleSuffix(original)) {
        store.lastSentWireText[channel] = original;
      }
    }

    // A successful echo means Twitch accepted the send - any self-timeout
    // gate still armed was for a timeout Twitch has since lifted. Clear it.
    onSelfTimeoutCleared(channel);

    final msg = parseIrcChatMessage(
      ircMsg,
      channel: channel,
      defaultLogin: store.session.login,
      defaultUserId: store.session.userId,
    );

    // Track our own message ids so replies chained onto them ping via
    // participation (DankChat-style reply highlights), and learn the
    // account's display name from the echo.
    if (msg.messageId != null) {
      pingManager?.registerOwnMessage(
        channel,
        msg.messageId!,
        threadRootId: msg.replyThreadRootId ?? msg.messageId,
      );
    }
    pingManager?.setOwnDisplayName(msg.displayName);

    final preferredName =
        msg.displayName.toLowerCase() == msg.login.toLowerCase()
        ? msg.displayName
        : msg.login;
    if (preferredName.isNotEmpty) {
      userStore.addUser(channel, preferredName);
    }

    if (msg.messageId != null &&
        store.messageKeys.contains('$channel:${msg.messageId}')) {
      return;
    }

    onAnalyticsMessage?.call(channel, msg);

    store.channelMessages.putIfAbsent(channel, () => []);
    store.channelMessages[channel]!.insert(0, msg);
    store.truncateWithCoalesce(
      channel,
      maxMessages: getMaxMessagesPerChannel(),
    );

    if (msg.messageId != null) {
      store.messageKeys.add('$channel:${msg.messageId}');
    }
    store.indexMessages(channel, [msg]);

    store.noteNewMessage(channel);
    precacheMessageEmotes(msg, channel);
    // Own messages arrive on the read socket (not the channel echo), so they
    // would otherwise never be read aloud; surface them like any other chat
    // message so TTS can speak them too.
    onChatMessage?.call(channel, msg);
  }
}
