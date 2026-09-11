import 'dart:async';

import 'dart:ui' show Color;

import '../models/emote_fetch_tier.dart';
import '../models/twitch_message.dart';
import '../util/duration_format.dart';
import '../util/log.dart';
import '../irc/decode/codec.dart' show parseIrcChatMessage;
import '../irc/decode/copy.dart'
    show buildBanText, buildUserNoticeText, userNoticeAccent, userNoticeLabelId;
import '../irc/decode/decoder.dart' show IrcChatDecoder;
import '../irc/decode/events.dart'
    show IrcChannelClearEvent, IrcMessageDeletedEvent, UserNoticeEvent;
import '../irc/message.dart' show IrcMessage;
import '../irc/transport/read.dart' show IrcReadService;
import '../irc/transport/write.dart' show IrcService;
import '../chat/chat.dart';
import '../client/session.dart';
import 'chat_sender.dart';
import 'emote_manager.dart';
import 'ignore_manager.dart';
import 'ping_manager.dart';
import 'twitch_auth.dart';
import 'twitch_badge_service.dart';
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
/// [Chat] mutations and feature-sink calls. Pure translation: policy
/// lives behind the consulted predicates (pings, ignores, blocks) and every
/// state law lives in the channel.
class ChatIngestion {
  ChatIngestion({
    required this.irc,
    required this.ircRead,
    required this.readDecoder,
    required this.writeDecoder,
    required this.chat,
    required this.session,
    required this.userStore,
    required this.emoteManager,
    required this.badgeService,
    required this.twitchAuth,
    required this.sender,
    this.ignoreManager,
    this.pingManager,
    required this.mentionsChannel,
    required this.getMaxMessagesPerChannel,
    required this.getSelectedChannel,
    this.isChatReady,
    this.isBlocked,
    this.getSharedChatMode,
    required this.isModerationActive,
    required this.isJoinFailureNotified,
    required this.onSystemMessage,
    this.onAnalyticsMessage,
    this.onAnalyticsModeration,
    this.onChatMessage,
    this.onMention,
    this.onWhisper,
  });

  final IrcService irc;
  final IrcReadService ircRead;
  final IrcChatDecoder readDecoder;
  final IrcChatDecoder writeDecoder;
  final Session session;
  final Chat chat;
  final UserStore userStore;
  final EmoteManager emoteManager;
  final TwitchBadgeService badgeService;
  final TwitchAuth twitchAuth;
  final ChatSender sender;
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

  /// Whether a join-failure notice was already displayed for the channel;
  /// its raw refusal NOTICE is suppressed as a duplicate then.
  final bool Function(String channel) isJoinFailureNotified;

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
  final void Function(TwitchMessage msg)? onWhisper;

  bool _disposed = false;
  final _recentBanMeta = <String, List<_BanMeta>>{};
  static const _banDedupWindowSeconds = 10;
  static const _roomStateNoticeIds = {
    'followers_on_zero',
    'followers_on',
    'followers_off',
    'emote_only_on',
    'emote_only_off',
    'r9k_on',
    'r9k_off',
    'subs_on',
    'subs_off',
    'slow_on',
    'slow_off',
  };
  final _inflightSourceData = <String, Future<void>>{};

  /// Subscribes to every content stream. Returns the subscriptions for the
  /// caller's dispose bookkeeping.
  List<StreamSubscription<void>> attach() {
    return [
      readDecoder.onMessage.listen(onMessage),
      readDecoder.onMessageDeleted.listen(_onMessageDeleted),
      readDecoder.onBan.listen(
        (event) => _handleBanEvent(
          channel: event.channel,
          user: event.user,
          isTimeout: event.isTimeout,
          duration: event.duration,
        ),
      ),
      readDecoder.onChannelClear.listen(_onChannelClear),
      readDecoder.onOwnMessage.listen(onOwnIrcMessage),
      readDecoder.onNotice.listen((event) {
        if (_disposed) return;
        // With channel.moderate active, room-state changes come from EventSub
        // with structured data - suppress the redundant IRC NOTICE.
        if (isModerationActive(event.channel) &&
            _roomStateNoticeIds.contains(event.msgId)) {
          return;
        }
        // A join-refusal notice for a channel we tried to join is already
        // surfaced by the onJoinFailed listener with clearer wording; showing
        // Twitch's raw copy too would duplicate the message. Refusals for
        // channels we are not joining still display normally.
        if (event.msgId == 'msg_channel_suspended' &&
            isJoinFailureNotified(event.channel)) {
          return;
        }
        onSystemMessage(event.channel, event.message);
      }),
      readDecoder.onJtvMessage.listen((event) {
        if (_disposed) return;
        onSystemMessage(event.channel, event.message);
      }),
      // Send rejections (slow-mode, banned, msg-too-long, ...) come back on
      // the write socket; surface them as system messages instead of dropping.
      writeDecoder.onNotice.listen((event) {
        if (_disposed) return;
        onSystemMessage(event.channel, event.message);
      }),
      readDecoder.onWhisper.listen(_onWhisperEvent),
      readDecoder.onUserNotice.listen((event) {
        if (_disposed) return;
        onUserNotice(event);
      }),
    ];
  }

  void _onWhisperEvent(TwitchMessage msg) {
    if (_disposed) return;
    if (!msg.isSystem && isBlocked?.call(msg.login) == true) return;
    // Ignored users' whispers are dropped like their channel messages.
    if (!msg.isSystem && ignoreManager?.isIgnored(msg.login) == true) return;
    onWhisper?.call(msg);
  }

  void dispose() {
    _disposed = true;
  }

  // ---- PRIVMSG ------------------------------------------------------------

  /// Translates one live chat message under the pipeline policies (blocks,
  /// ignores, pings, shared-chat mode) and hands it to the channel.
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

    final selected = getSelectedChannel();
    final result = chat
        .ensure(channel)
        .receive(
          msg,
          maxMessages: getMaxMessagesPerChannel(),
          isSelected: channel == selected,
          ownLogin: session.login,
        );
    if (!result.inserted) return;

    // Aggregates follow the verb's single decision; never re-decided here.
    if (result.mentioned) {
      chat.mentions.add([msg], maxMessages: getMaxMessagesPerChannel());
    }
    if (result.countMention) {
      chat.noteMention();
    } else if (result.countUnread) {
      chat.noteUnread();
    }

    // Feed the emote usage registry from live chat: the emotes people are
    // actually staring at get cache priority. History/backfill are skipped
    // (they would re-touch old messages on every reconnect and skew the
    // 24-hour histograms). Batched by id: spam repeats one emote dozens of
    // times per message but needs a single touch and flush schedule.
    if (!msg.isHistory && !msg.isSystem) {
      final positions = msg.emotePositions;
      if (positions != null && positions.isNotEmpty) {
        final seenIds = <String>{};
        for (final position in positions) {
          if (!seenIds.add(position.emoteId)) continue;
          final emote = emoteManager.emoteById(position.emoteId);
          if (emote != null) emoteManager.markEmoteViewed(emote);
        }
      }
    }

    onAnalyticsMessage?.call(channel, msg);

    if (msg.sourceBroadcasterId != null && !msg.isHistory) {
      unawaited(_ensureSourceChannelData(msg.sourceBroadcasterId!));
    }

    if (result.mentioned) {
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
      senderTwitchId: msg.userId,
    );
    if (found.isNotEmpty) {
      emoteManager.enqueueSeenEmotes(found);
    }
  }

  // ---- USERNOTICE ---------------------------------------------------------

  /// Renders a USERNOTICE: announcements as a label plus body, every other
  /// notice as an accented system line, with sub/resub messages echoed as a
  /// child chat message.
  void onUserNotice(UserNoticeEvent event) {
    if (_disposed) return;
    final isAnnouncement = event.msgId == 'announcement';
    if (!isAnnouncement) {
      // Every non-announcement notice (subs, gift subs, watch streaks,
      // bits badge tiers, raids, pay forwards, ...) highlights like a
      // default (PRIMARY) purple announcement: the notice stays a system
      // message but carries the accent.
      final accent = userNoticeAccent(event.msgId);
      onSystemMessage(
        event.channel,
        buildUserNoticeText(
          msgId: event.msgId,
          displayName: event.displayName,
          systemMsg: event.systemMsg,
        ),
        accent: accent,
        messageId: userNoticeLabelId(event.messageId),
      );
      // Sub/resub with a user message render like announcements: the notice
      // stays the label and the user's text becomes a child chat message so
      // emotes and badges render. The IRC `emotes` tag positions are
      // relative to the untrimmed body, so shift them by trimmed leading
      // whitespace and drop any that fall out of range.
      if ((event.msgId == 'sub' || event.msgId == 'resub') &&
          (event.text?.trim().isNotEmpty ?? false)) {
        final raw = event.text!;
        final body = raw.trim();
        final shift = raw.length - raw.trimLeft().length;
        onMessage(
          TwitchMessage(
            login: event.login,
            displayName: event.displayName,
            text: body,
            color: event.color,
            userId: event.userId,
            badges: event.badges,
            emotePositions: _shiftEmotePositions(
              event.emotePositions,
              shift,
              body.length,
            ),
            messageId: event.messageId,
            channel: event.channel,
            systemAccent: accent,
          ),
        );
      }
      onChatMessage?.call(
        event.channel,
        TwitchMessage(
          login: event.login,
          displayName: event.displayName,
          text: buildUserNoticeText(
            msgId: event.msgId,
            displayName: event.displayName,
            systemMsg: event.systemMsg,
          ),
          channel: event.channel,
          isSystem: true,
        ),
      );
      return;
    }
    // DankChat-style: the "Announcement" label plus the announcement text
    // rendered as a normal chat message, both on the announcement color.
    final accent = userNoticeAccent(
      'announcement',
      announcementColorParam: event.announcementColor,
    );
    onSystemMessage(
      event.channel,
      'Announcement',
      accent: accent,
      messageId: userNoticeLabelId(event.messageId),
    );
    final rawText = event.text ?? '';
    final text = rawText.trim();
    if (text.isEmpty) return;
    final shift = rawText.length - rawText.trimLeft().length;
    onMessage(
      TwitchMessage(
        login: event.login,
        displayName: event.displayName,
        text: text,
        color: event.color,
        userId: event.userId,
        badges: event.badges,
        emotePositions: _shiftEmotePositions(
          event.emotePositions,
          shift,
          text.length,
        ),
        messageId: event.messageId,
        channel: event.channel,
        systemAccent: accent,
      ),
    );
  }

  // ---- Moderation echoes --------------------------------------------------

  void _onMessageDeleted(IrcMessageDeletedEvent event) {
    if (_disposed) return;
    final channel = chat.channelFor(event.channel);
    final found = channel?.messages.markDeleted(event.messageId) ?? false;
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
    chat.channelFor(channel)?.messages.markUserDeleted(user);
    // Track own timeouts for the input-box countdown. Runs before the
    // moderation-channel early return so the IRC and EventSub sources can't
    // double-count: both just re-arm the same expiry.
    final selfLogin = session.login?.toLowerCase();
    if (selfLogin != null && user.toLowerCase() == selfLogin) {
      // Zero-length timeouts are already spent - don't arm a gate for them.
      if (isTimeout && duration != null && duration > 0) {
        sender.armTimeout(
          channel,
          DateTime.now().add(Duration(seconds: duration)),
        );
      }
    }
    // While the channel.moderate v2 subscription is active, moderation
    // messages come from EventSub (with reason/duration) - skip the IRC copy.
    if (isModerationActive(channel)) return;
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
    logDebug('[Ingestion] IRC ban system message: $text');

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
    chat.channelFor(event.channel)?.messages.markAllDeleted();
    onSystemMessage(event.channel, 'Chat was cleared.');
  }

  // ---- Own-message echo ---------------------------------------------------

  void onOwnIrcMessage(IrcMessage ircMsg) {
    if (_disposed) return;
    final channel = ircMsg.params.isNotEmpty
        ? ircMsg.params[0].substring(1)
        : null;
    if (channel == null || ircMsg.trailing == null) return;

    // Re-sync the bypass memory from the echo so it doesn't drift if the
    // server modified the message (truncation, etc.).
    sender.resyncWireText(channel, ircMsg.trailing!);

    // A successful echo means Twitch accepted the send - any self-timeout
    // gate still armed was for a timeout Twitch has since lifted. Clear it.
    sender.clearTimeout(channel);

    final msg = parseIrcChatMessage(
      ircMsg,
      channel: channel,
      defaultLogin: session.login,
      defaultUserId: session.userId,
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

    onAnalyticsMessage?.call(channel, msg);

    final result = chat
        .ensure(channel)
        .receive(
          msg,
          maxMessages: getMaxMessagesPerChannel(),
          isSelected: channel == getSelectedChannel(),
          ownLogin: session.login,
        );
    if (!result.inserted) return;
    precacheMessageEmotes(msg, channel);
    // Own messages arrive on the read socket (not the channel echo), so they
    // would otherwise never be read aloud; surface them like any other chat
    // message so TTS can speak them too.
    onChatMessage?.call(channel, msg);
  }
}

/// Shifts IRC `emotes` tag positions after trimming leading whitespace.
/// Positions outside the trimmed body are dropped.
List<EmotePosition>? _shiftEmotePositions(
  List<EmotePosition>? positions,
  int shift,
  int textLength,
) {
  if (positions == null || positions.isEmpty) return positions;
  if (shift <= 0) return positions;
  final kept = <EmotePosition>[];
  for (final p in positions) {
    final start = p.startIndex - shift;
    final end = p.endIndex - shift;
    if (start < 0 || end > textLength || start >= end) continue;
    kept.add(
      EmotePosition(
        emoteId: p.emoteId,
        startIndex: start,
        endIndex: end,
        emoteCode: p.emoteCode,
      ),
    );
  }
  return kept;
}
