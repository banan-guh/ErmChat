import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import '../models/generic_emote.dart';
import 'base_irc_connection.dart';
import '../models/twitch_message.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_eventsub.dart';
import '../services/twitch_irc.dart';
import '../services/twitch_irc_read.dart';
import '../services/emote_manager.dart';
import '../services/emote_providers/seven_tv_emotes.dart';
import '../services/seven_tv_event_client.dart';
import '../services/twitch_badge_service.dart';
import '../services/user_store.dart';
import '../util/text_bypass.dart';
import '../color_utils.dart';
import '../util/constants.dart';
import '../util/mention.dart';
import '../util/thread_utils.dart';

class _BanMeta {
  final String user;
  final bool isTimeout;
  int stackCount = 1;
  DateTime lastEvent;
  String? firstMessageId;

  _BanMeta({required this.user, required this.isTimeout, DateTime? lastEvent})
    : lastEvent = lastEvent ?? DateTime.now();
}

class ChatConnectionConfig {
  ChatConnectionConfig({
    required this.twitchApi,
    required this.eventSub,
    required this.irc,
    required this.ircRead,
    this.sevenTvClient,
    required this.emoteManager,
    required this.badgeService,
    required this.userStore,
    required this.twitchAuth,
    required this.channelMessages,
    required this.messageKeys,
    required this.chatStatus,
    required this.channelsWithUnread,
    required this.channelsWithUnreadMentions,
    required this.unreadMentionsPerChannel,
    required this.channels,
    required this.historyLoaded,
    required this.channelsEmotesResolved,
    required this.channelUserIds,
    required this.lastTypedText,
    required this.lastSentWireText,
    required this.bumpChannel,
    required this.invalidateChannel,
    required this.invalidateMessage,
    required this.mentionsChannel,
    required this.onRebuild,
    required this.onSystemMessage,
    required this.loadUserTwitchEmotes,
    this.onReconnected,
    required this.getMaxMessagesPerChannel,
    required this.getSelectedChannel,
    required this.getUnreadMentions,
    required this.setUnreadMentions,
    required this.getCurrentUserLogin,
    required this.setCurrentUserLogin,
    required this.getCurrentUserId,
    required this.setCurrentUserId,
    required this.onCommand,
    required this.getReplyToMsg,
    required this.setReplyToMsg,
    required this.onRequestFocus,
    required this.onShowSnackBar,
    this.getAltPings,
    this.isChatReady,
    this.isBlocked,
  });

  final TwitchApi twitchApi;
  final EventSubService eventSub;
  final IrcService irc;
  final IrcReadService ircRead;
  final SevenTvEventClient? sevenTvClient;
  final TwitchBadgeService badgeService;
  final UserStore userStore;
  final TwitchAuth twitchAuth;
  final EmoteManager emoteManager;
  final Map<String, List<TwitchMessage>> channelMessages;
  final Set<String> messageKeys;
  final Map<String, String> chatStatus;
  final Set<String> channelsWithUnread;
  final Set<String> channelsWithUnreadMentions;
  final Map<String, int> unreadMentionsPerChannel;
  final List<String> channels;
  final Set<String> historyLoaded;
  final Set<String> channelsEmotesResolved;
  final Map<String, String> channelUserIds;
  final Map<String, String> lastTypedText;
  final Map<String, String> lastSentWireText;
  final void Function(String channel) bumpChannel;
  final void Function(String channel) invalidateChannel;
  final void Function(String channel, String? messageId) invalidateMessage;
  final String mentionsChannel;
  final VoidCallback onRebuild;
  final void Function(String, String, {Color? accent}) onSystemMessage;
  final Future<void> Function() loadUserTwitchEmotes;
  final VoidCallback? onReconnected;
  final int Function() getMaxMessagesPerChannel;
  final String? Function() getSelectedChannel;
  final int Function() getUnreadMentions;
  final void Function(int) setUnreadMentions;
  final String? Function() getCurrentUserLogin;
  final void Function(String?) setCurrentUserLogin;
  final String? Function() getCurrentUserId;
  final void Function(String?) setCurrentUserId;
  final void Function(String, String, TwitchAuth) onCommand;
  final TwitchMessage? Function() getReplyToMsg;
  final void Function(TwitchMessage?) setReplyToMsg;
  final VoidCallback onRequestFocus;
  final void Function(String) onShowSnackBar;
  final List<String> Function()? getAltPings;
  final bool Function()? isChatReady;
  final bool Function(String login)? isBlocked;
}

class ChatConnectionManager {
  final TwitchApi twitchApi;
  final EventSubService eventSub;
  final IrcService irc;
  final IrcReadService ircRead;
  final SevenTvEventClient? sevenTvClient;
  final TwitchBadgeService badgeService;
  final UserStore userStore;
  final TwitchAuth twitchAuth;
  final EmoteManager emoteManager;
  final Map<String, List<TwitchMessage>> channelMessages;
  final Set<String> messageKeys;
  final Map<String, String> chatStatus;
  final Set<String> channelsWithUnread;
  final Set<String> channelsWithUnreadMentions;
  final Map<String, int> unreadMentionsPerChannel;
  final List<String> channels;
  final Set<String> historyLoaded;
  final Set<String> channelsEmotesResolved;
  final Map<String, String> channelUserIds;
  final Map<String, String> lastTypedText;
  final Map<String, String> lastSentWireText;
  final void Function(String channel) bumpChannel;
  final void Function(String channel) invalidateChannel;
  final void Function(String channel, String? messageId) invalidateMessage;
  final String mentionsChannel;
  final VoidCallback onRebuild;
  final void Function(String, String, {Color? accent}) onSystemMessage;
  void Function(String channel, TwitchMessage msg)? onMention;
  final Future<void> Function() loadUserTwitchEmotes;
  final VoidCallback? onReconnected;
  final int Function() getMaxMessagesPerChannel;
  final String? Function() getSelectedChannel;
  final int Function() getUnreadMentions;
  final void Function(int) setUnreadMentions;
  final String? Function() getCurrentUserLogin;
  final void Function(String?) setCurrentUserLogin;
  final String? Function() getCurrentUserId;
  final void Function(String?) setCurrentUserId;
  final void Function(String, String, TwitchAuth) onCommand;
  final TwitchMessage? Function() getReplyToMsg;
  final void Function(TwitchMessage?) setReplyToMsg;
  final VoidCallback onRequestFocus;
  final void Function(String) onShowSnackBar;
  final List<String> Function()? getAltPings;
  final bool Function()? isChatReady;
  final bool Function(String login)? isBlocked;

  bool _wasConnected = false;
  bool _wasDisconnected = false;
  DateTime? _lastSubscribeAll;
  bool userTwitchEmotesLoaded = false;
  final _connectedAcked = <String>{};
  final _chatStatusTimers = <String, Timer>{};
  // Channels with an active channel.moderate v2 subscription. While present,
  // moderation system messages come from EventSub (richer data) instead of
  // IRC CLEARCHAT/CLEARMSG.
  final _moderationChannels = <String>{};
  // Channels where the channel.moderate v2 subscription was rejected with a 403
  // (not a moderator). Persists across EventSub session reconnects so we don't
  // re-attempt (and re-log) the subscription on every reconnect for the current
  // account.
  final _moderationSkippedChannels = <String>{};
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
  bool isDisposed = false;
  bool _isConnecting = false;
  final _recentBanMeta = <String, List<_BanMeta>>{};
  static const _banDedupWindowSeconds = 10;

  StreamSubscription<TwitchMessage>? messageSub;
  StreamSubscription<EventSubStatus>? statusSub;
  StreamSubscription<IrcBanEvent>? ircBanSub;
  StreamSubscription<IrcMessageDeletedEvent>? ircDeleteSub;
  StreamSubscription<IrcNoticeEvent>? ircNoticeSub;
  StreamSubscription<IrcNoticeEvent>? ircJtvSub;
  StreamSubscription<IrcMessage>? ircOwnMsgSub;
  StreamSubscription<UserNoticeEvent>? userNoticeSub;
  StreamSubscription<IrcChannelClearEvent>? ircClearSub;
  StreamSubscription<IrcRoomStateEvent>? ircRoomStateSub;
  StreamSubscription<ModerationEvent>? moderationSub;
  StreamSubscription<SevenTvEmoteUpdateEvent>? sevenTvEmoteSub;
  StreamSubscription<SevenTvUserUpdate>? sevenTvUserSub;
  StreamSubscription<IrcConnectionStatus>? ircStatusSub;
  final _httpClient = http.Client();

  ChatConnectionManager(ChatConnectionConfig config)
    : twitchApi = config.twitchApi,
      eventSub = config.eventSub,
      irc = config.irc,
      ircRead = config.ircRead,
      sevenTvClient = config.sevenTvClient,
      emoteManager = config.emoteManager,
      badgeService = config.badgeService,
      userStore = config.userStore,
      twitchAuth = config.twitchAuth,
      channelMessages = config.channelMessages,
      messageKeys = config.messageKeys,
      chatStatus = config.chatStatus,
      channelsWithUnread = config.channelsWithUnread,
      channelsWithUnreadMentions = config.channelsWithUnreadMentions,
      unreadMentionsPerChannel = config.unreadMentionsPerChannel,
      channels = config.channels,
      historyLoaded = config.historyLoaded,
      channelsEmotesResolved = config.channelsEmotesResolved,
      channelUserIds = config.channelUserIds,
      lastTypedText = config.lastTypedText,
      lastSentWireText = config.lastSentWireText,
      bumpChannel = config.bumpChannel,
      invalidateChannel = config.invalidateChannel,
      invalidateMessage = config.invalidateMessage,
      mentionsChannel = config.mentionsChannel,
      onRebuild = config.onRebuild,
      onSystemMessage = config.onSystemMessage,
      loadUserTwitchEmotes = config.loadUserTwitchEmotes,
      onReconnected = config.onReconnected,
      getMaxMessagesPerChannel = config.getMaxMessagesPerChannel,
      getSelectedChannel = config.getSelectedChannel,
      getUnreadMentions = config.getUnreadMentions,
      setUnreadMentions = config.setUnreadMentions,
      getCurrentUserLogin = config.getCurrentUserLogin,
      setCurrentUserLogin = config.setCurrentUserLogin,
      getCurrentUserId = config.getCurrentUserId,
      setCurrentUserId = config.setCurrentUserId,
      onCommand = config.onCommand,
      getReplyToMsg = config.getReplyToMsg,
      setReplyToMsg = config.setReplyToMsg,
      onRequestFocus = config.onRequestFocus,
      onShowSnackBar = config.onShowSnackBar,
      getAltPings = config.getAltPings,
      isChatReady = config.isChatReady,
      isBlocked = config.isBlocked;

  void dispose() {
    isDisposed = true;
    messageSub?.cancel();
    statusSub?.cancel();
    ircBanSub?.cancel();
    ircDeleteSub?.cancel();
    ircNoticeSub?.cancel();
    ircJtvSub?.cancel();
    ircOwnMsgSub?.cancel();
    userNoticeSub?.cancel();
    ircClearSub?.cancel();
    ircRoomStateSub?.cancel();
    moderationSub?.cancel();
    sevenTvEmoteSub?.cancel();
    sevenTvUserSub?.cancel();
    ircStatusSub?.cancel();
    _httpClient.close();
    for (final t in _chatStatusTimers.values) {
      t.cancel();
    }
    _chatStatusTimers.clear();
  }

  void stopChatStatusTimer(String channel) {
    _chatStatusTimers.remove(channel)?.cancel();
    _roomStateTags.remove(channel);
    _streamStatusParts.remove(channel);
  }

  void _markUserMessagesDeleted(String channel, String username) {
    final msgs = channelMessages[channel];
    if (msgs == null) {
      debugPrint(
        '[ChatConn] _markUserMessagesDeleted: no messages for channel=$channel',
      );
      return;
    }
    var count = 0;
    for (final msg in msgs) {
      if (msg.login == username.toLowerCase() &&
          !msg.isSystem &&
          !msg.deleted) {
        msg.deleted = true;
        invalidateMessage(channel, msg.messageId);
        count++;
      }
    }
    debugPrint(
      '[ChatConn] _markUserMessagesDeleted: marked $count messages deleted for user=$username in channel=$channel (total msgs in channel=${msgs.length})',
    );
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

  void _handleBanEvent({
    required String channel,
    required String user,
    required bool isTimeout,
    required int? duration,
  }) {
    debugPrint(
      '[ChatConn] IRC ban received: user=$user channel=$channel isTimeout=$isTimeout',
    );
    if (isDisposed) return;
    _markUserMessagesDeleted(channel, user);
    // While the channel.moderate v2 subscription is active, moderation
    // messages come from EventSub (with reason/duration) — skip the IRC copy.
    if (_moderationChannels.contains(channel)) return;
    final result = _processBanInChannel(channel, user, isTimeout);
    final isSelf = user.toLowerCase() == getCurrentUserLogin()?.toLowerCase();
    final base = isSelf
        ? (isTimeout
              ? 'You are timed out${duration != null ? ' for ${duration}s' : ''}'
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
    debugPrint('[ChatConn] IRC ban system message: $text');

    if (result.stackCount > 1) {
      if (result.meta.firstMessageId != null) {
        _updateMessageText(channel, result.meta.firstMessageId!, text);
        return;
      }
    }
    onSystemMessage(channel, text);
    result.meta.firstMessageId = channelMessages[channel]?.first.messageId;
  }

  void _updateMessageText(String channel, String messageId, String newText) {
    final msgs = channelMessages[channel];
    if (msgs == null) return;
    for (final m in msgs) {
      if (m.messageId == messageId) {
        m.text = newText;
        invalidateMessage(channel, messageId);
        return;
      }
    }
  }

  void maybeAddConnected(String channel) {
    if (irc.isConnected &&
        historyLoaded.contains(channel) &&
        _connectedAcked.add(channel)) {
      onSystemMessage(channel, 'Connected');
    }
  }

  void precacheMessageEmotes(TwitchMessage msg, String channel) {
    if (msg.isSystem || msg.isHistory) return;
    final channelEmotes = emoteManager.byCode(channel);
    if (channelEmotes == null) return;
    final found = <GenericEmote>[];
    final seen = <String>{};
    for (final word in msg.text.split(RegExp(r'\s+'))) {
      if (seen.contains(word)) continue;
      final emote = channelEmotes.byCode[word];
      if (emote != null) {
        found.add(emote);
        seen.add(word);
      }
    }
    if (found.isNotEmpty) {
      emoteManager.enqueueSeenEmotes(found);
    }
  }

  // Room-mode tags per channel from ROOMSTATE (merged across partial
  // updates); feeds the chat status splash. Stream info from the periodic
  // Helix fetch is kept separately so ROOMSTATE recomposes don't lose it.
  final _roomStateTags = <String, Map<String, String>>{};
  final _streamStatusParts = <String, List<String>>{};

  Future<void> fetchChatStatus(String channel) async {
    final auth = twitchAuth;
    if (!auth.isConfigured) return;

    final userId = channelUserIds[channel];
    if (userId == null || getCurrentUserId() == null) return;

    final stream = await twitchApi.getStreamInfo(auth, userId);

    final parts = <String>[];
    if (stream != null && stream['type'] == 'live') {
      final viewers = stream['viewer_count'] ?? 0;
      final started = stream['started_at'] as String?;
      if (started != null) {
        final dur = DateTime.now().difference(DateTime.parse(started));
        final h = dur.inHours;
        final m = dur.inMinutes.remainder(60);
        parts.add('Live with $viewers viewers for ${h}h ${m}m');
      } else {
        parts.add('Live with $viewers viewers');
      }
    }
    _streamStatusParts[channel] = parts;
    _composeChatStatus(channel);
  }

  // Room modes come from ROOMSTATE (instant, broadcast to everyone on IRC);
  // this replaces the old Helix getChatSettings polling.
  void _composeChatStatus(String channel) {
    final parts = <String>[];
    final tags = _roomStateTags[channel];
    if (tags != null) {
      final slow = int.tryParse(tags['slow'] ?? '') ?? 0;
      if (slow > 0) parts.add('Slow (${slow}s)');
      final followers = tags['followers-only'];
      if (followers != null && followers != '-1') {
        parts.add(
          followers == '0'
              ? 'Followers-only'
              : 'Followers-only (${followers}m)',
        );
      }
      if (tags['emote-only'] == '1') parts.add('Emote-only');
      if (tags['subs-only'] == '1') parts.add('Subscribers-only');
      if (tags['r9k'] == '1') parts.add('Unique chat');
    }
    parts.addAll(_streamStatusParts[channel] ?? const []);
    chatStatus[channel] = parts.isNotEmpty ? parts.join(' · ') : '';
    invalidateChannel(channel);
  }

  // 5-phase thread-aware truncation: keeps complete reply threads intact even
  // when most messages are pruned. Walks parent chains (no cycle detection),
  // identifies active/orphan threads, and removes orphan members as a group.
  void truncateChannelMessages(String channel) {
    final maxMessages = getMaxMessagesPerChannel();
    if (maxMessages <= 0) return;
    final msgs = channelMessages[channel];
    if (msgs == null || msgs.length <= maxMessages) return;

    // Phase 1: group messages by thread identity.
    // For messages with replyThreadRootId, the key is that value.
    // For messages with only replyToParentId (older style), walk the chain
    // to the root and use the root's messageId as the key.
    // Only groups with more than one message are actual threads.
    final parentOf = <String, String>{};
    for (final m in msgs) {
      if (m.replyToParentId != null && m.messageId != null) {
        parentOf[m.messageId!] = m.replyToParentId!;
      }
    }

    final threadGroups = <String, List<TwitchMessage>>{};
    for (final m in msgs) {
      String? key;
      if (m.replyThreadRootId != null) {
        key = m.replyThreadRootId;
      } else if (m.messageId != null && parentOf.containsKey(m.messageId)) {
        key = resolveThreadRootId(m.messageId!, parentOf);
      } else if (m.messageId != null) {
        key = m.messageId;
      }
      if (key != null) {
        threadGroups.putIfAbsent(key, () => <TwitchMessage>[]).add(m);
      }
    }
    threadGroups.removeWhere((_, ms) => ms.length <= 1);

    // Phase 2: determine which threads are active.
    // A thread is active if any of its messages is within the first
    // maxMessages non-system messages (newest-first).
    final activeThreadKeys = <String>{};
    int visibleCount = 0;
    for (final m in msgs) {
      if (m.isSystem) continue;
      if (visibleCount >= maxMessages) break;
      visibleCount++;
      String? key;
      if (m.replyThreadRootId != null) {
        key = m.replyThreadRootId;
      } else if (m.messageId != null && parentOf.containsKey(m.messageId)) {
        key = resolveThreadRootId(m.messageId!, parentOf);
      } else if (m.messageId != null) {
        key = m.messageId;
      }
      if (key != null && threadGroups.containsKey(key)) {
        activeThreadKeys.add(key);
      }
    }

    // Phase 3: collect every message ID belonging to an active thread.
    final threadIds = <String>{};
    for (final key in activeThreadKeys) {
      for (final m in threadGroups[key]!) {
        if (m.messageId != null) threadIds.add(m.messageId!);
      }
    }

    // Phase 4: collect indices to keep.
    final keepIndices = <int>{};
    int nonThreadKept = 0;
    for (int i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      final isActiveThread =
          m.messageId != null && threadIds.contains(m.messageId!);
      if (isActiveThread) {
        keepIndices.add(i);
      } else {
        String? key;
        if (m.replyThreadRootId != null) {
          key = m.replyThreadRootId;
        } else if (m.messageId != null && parentOf.containsKey(m.messageId)) {
          key = resolveThreadRootId(m.messageId!, parentOf);
        } else if (m.messageId != null) {
          key = m.messageId;
        }
        final isOrphanThread =
            m.messageId != null &&
            !isActiveThread &&
            key != null &&
            threadGroups.containsKey(key);
        if (!isOrphanThread && nonThreadKept < maxMessages) {
          keepIndices.add(i);
          nonThreadKept++;
        }
      }
    }

    // Phase 5: build retained list in O(n) (was O(n^2) removeAt loop).
    final retained = <TwitchMessage>[];
    for (int i = 0; i < msgs.length; i++) {
      if (keepIndices.contains(i)) {
        retained.add(msgs[i]);
      }
    }
    msgs
      ..clear()
      ..addAll(retained);
  }

  Future<void> subscribeChannel(String channelName) async {
    irc.join(channelName);
    ircRead.join(channelName);

    try {
      final auth = twitchAuth;
      final channelUserId = await twitchApi.getUserId(auth, channelName);
      if (channelUserId == null) return;
      channelUserIds[channelName] = channelUserId;
      badgeService.fetchChannelBadges(auth, channelUserId, channelName);

      emoteManager.accessToken = auth.accessToken;
      debugPrint(
        'subscribeChannel $channelName userId=$channelUserId '
        'hasToken=${auth.accessToken != null} resolved=${channelsEmotesResolved.contains(channelName)}',
      );
      if (!channelsEmotesResolved.contains(channelName)) {
        channelsEmotesResolved.add(channelName);
        unawaited(
          emoteManager
              .resolveEmotes(channelName, channelUserId)
              .catchError(
                (e) => debugPrint(
                  '[ChatConn] resolveEmotes failed for $channelName: $e',
                ),
              ),
        );
      }

      unawaited(_resolveSevenTvAndSubscribe(channelName, channelUserId));

      if (getCurrentUserLogin() == null) {
        final currentUser = await _ensureCurrentUser(auth);
        if (currentUser == null) return;
        setCurrentUserLogin(currentUser['login']);
        setCurrentUserId(currentUser['id']);
      }

      if (!userTwitchEmotesLoaded) {
        userTwitchEmotesLoaded = true;
        unawaited(
          loadUserTwitchEmotes().catchError(
            (e) => debugPrint('[ChatConn] loadUserTwitchEmotes failed: $e'),
          ),
        );
      }

      eventSub.setChannelMapping(channelUserId, channelName);

      unawaited(_subscribeModeration(channelName, channelUserId));
    } catch (_) {
      debugPrint('[ChatConn] subscribeChannel failed for $channelName');
    }
    onRebuild();
    fetchChatStatus(channelName);
    _chatStatusTimers[channelName]?.cancel();
    _chatStatusTimers[channelName] = Timer.periodic(
      const Duration(seconds: 60),
      (_) => fetchChatStatus(channelName),
    );
  }

  Future<Map<String, dynamic>?>? _currentUserFetch;

  Future<Map<String, dynamic>?> _ensureCurrentUser(TwitchAuth auth) {
    return _currentUserFetch ??= twitchApi
        .getCurrentUser(auth)
        .then((user) {
          if (user != null) {
            auth.setUser(user['login'], user['id']);
          }
          return user;
        })
        .whenComplete(() => _currentUserFetch = null);
  }

  // Chat messages come from IRC PRIVMSG; EventSub is only used for
  // channel.moderate v2 (moderation actions), subscribed per channel when the
  // session is up. Twitch rejects non-moderators (403), in which case IRC
  // CLEARCHAT/CLEARMSG remain the moderation source.
  Future<void> _subscribeModeration(
    String channelName,
    String channelUserId,
  ) async {
    try {
      final auth = twitchAuth;
      if (!auth.isConfigured || getCurrentUserId() == null) return;
      // Already known to be rejected with 403 (not a moderator); skip so we
      // don't re-attempt and re-log on every reconnect.
      if (_moderationSkippedChannels.contains(channelName)) return;
      for (int attempt = 0; attempt < 3; attempt++) {
        final sessionId = eventSub.sessionId;
        if (sessionId == null) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        if (attempt > 0) await Future.delayed(const Duration(seconds: 1));
        final ok = await twitchApi.createEventSubSubscription(
          auth: auth,
          sessionId: sessionId,
          type: 'channel.moderate',
          version: '2',
          condition: {
            'broadcaster_user_id': channelUserId,
            'moderator_user_id': getCurrentUserId()!,
          },
        );
        if (ok) {
          _moderationChannels.add(channelName);
          return;
        }
        if (twitchApi.lastErrorStatus == 403) {
          // Expected when the user isn't a moderator in this channel; not an
          // actionable error, so skip it silently and don't retry it.
          _moderationSkippedChannels.add(channelName);
          return;
        }
        debugPrint(
          '[ChatConn] channel.moderate subscription failed for $channelName (${twitchApi.lastError ?? "unknown"})',
        );
        return;
      }
    } catch (_) {
      debugPrint('[ChatConn] subscribeModeration failed for $channelName');
    }
  }

  Future<void> _resolveSevenTvAndSubscribe(
    String channelName,
    String twitchChannelId,
  ) async {
    if (sevenTvClient == null) return;

    // Check if EmoteManager already has the IDs from resolveEmotes.
    final cachedEmoteSetId = emoteManager.getSevenTvEmoteSetId(channelName);
    final cachedUserId = emoteManager.getSevenTvUserId(channelName);

    String finalEmoteSetId;
    String finalUserId;

    if (cachedEmoteSetId != null && cachedUserId != null) {
      finalEmoteSetId = cachedEmoteSetId;
      finalUserId = cachedUserId;
    } else {
      try {
        final uri = Uri.parse(
          'https://7tv.io/v3/users/twitch/$twitchChannelId',
        );
        final res = await _httpClient.get(uri).timeout(httpTimeout);
        if (res.statusCode != 200) return;
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final userId =
            (data['user'] as Map<String, dynamic>?)?['id'] as String?;
        final emoteSetId =
            (data['emote_set'] as Map<String, dynamic>?)?['id'] as String?;
        if (userId == null || emoteSetId == null) return;
        emoteManager.setSevenTvEmoteSetId(channelName, emoteSetId);
        finalUserId = userId;
        finalEmoteSetId = emoteSetId;
      } catch (_) {
        return;
      }
    }

    sevenTvClient!.subscribeEmoteSet(finalEmoteSetId);
    sevenTvClient!.subscribeUser(finalUserId);
    debugPrint(
      '[7TV] subscribed channel=$channelName emoteSetId=$finalEmoteSetId userId=$finalUserId',
    );
  }

  void _onSevenTvEmoteSetUpdate(SevenTvEmoteUpdateEvent event) {
    final channel = emoteManager.getChannelForSevenTvEmoteSet(event.emoteSetId);
    if (channel == null) return;

    final added = event.added
        .map((e) => SevenTvEmoteProvider.parseSingleEmote(e.raw, channel: true))
        .whereType<GenericEmote>()
        .toList();
    final removedIds = event.removed.map((e) => e.id).toList();
    final renamed = <String, ({String newName, String oldName})>{};
    for (final r in event.renamed) {
      renamed[r.id] = (newName: r.newName, oldName: r.oldName);
    }

    emoteManager.updateSevenTvEmotes(
      channel,
      added: added,
      removedIds: removedIds,
      renamed: renamed,
    );

    final actor = event.actor ?? 'A user';
    for (final e in event.added) {
      onSystemMessage(channel, '$actor added 7TV Emote ${e.name}.');
    }
    for (final e in event.removed) {
      onSystemMessage(channel, '$actor removed 7TV Emote ${e.name}.');
    }
    for (final e in event.renamed) {
      onSystemMessage(
        channel,
        '$actor renamed 7TV Emote ${e.oldName} to ${e.newName}.',
      );
    }
  }

  void _onSevenTvUserUpdate(SevenTvUserUpdate event) {
    final channel = emoteManager.getChannelForSevenTvEmoteSet(
      event.oldEmoteSetId,
    );
    if (channel == null) return;
    if (event.oldEmoteSetId.isNotEmpty) {
      sevenTvClient?.unsubscribeEmoteSet(event.oldEmoteSetId);
    }
    sevenTvClient?.subscribeEmoteSet(event.newEmoteSetId);
    emoteManager.setSevenTvEmoteSetId(channel, event.newEmoteSetId);

    final actor = event.actor ?? 'A user';
    onSystemMessage(channel, '$actor switched the active 7TV Emote Set.');
  }

  void subscribeAll() {
    for (final channel in channels) {
      unawaited(subscribeChannel(channel));
    }
  }

  Future<void> doSendMessage(
    String text,
    String channel, {
    TwitchMessage? replyTo,
  }) async {
    final auth = twitchAuth;
    final reply = replyTo ?? getReplyToMsg();

    if (text.startsWith('/')) {
      onCommand(text, channel, auth);
      onRequestFocus();
      return;
    }

    if (isDisposed) return;
    setReplyToMsg(null);
    onRebuild();
    onRequestFocus();

    final userLogin = getCurrentUserLogin();
    if (userLogin == null) {
      onShowSnackBar('Connect an account to chat');
      return;
    }

    // Twitch rejects duplicate messages. If user sends the same visible text
    // again, inject an invisible \u034F bypass so wire text differs while
    // appearing identical. Two tracks (typed vs sent) prevent cascading bypass.
    final String wireText;
    if (text == lastTypedText[channel]) {
      final lastWire = lastSentWireText[channel] ?? text;
      wireText = bypassTextDuplicate(lastWire);
    } else {
      wireText = text;
    }
    lastTypedText[channel] = text;
    lastSentWireText[channel] = wireText;

    // Primary: send via IRC for low latency over the persistent socket
    irc.sendMessage(channel, wireText, replyParentMessageId: reply?.messageId);

    // Fallback: Helix API when the IRC write socket isn't available
    if (!irc.isConnected && getCurrentUserId() != null && auth.isConfigured) {
      final broadcasterId =
          channelUserIds[channel] ?? await twitchApi.getUserId(auth, channel);
      if (broadcasterId != null) {
        final result = await twitchApi.sendChatMessage(
          auth,
          broadcasterId: broadcasterId,
          senderId: getCurrentUserId()!,
          message: wireText,
          replyParentMessageId: reply?.messageId,
        );
        if (result == null) {
          onSystemMessage(
            channel,
            twitchApi.lastError ?? 'Message failed to send',
          );
        }
      }
    }
  }

  Future<void> connect() async {
    if (_isConnecting || isDisposed) return;
    _isConnecting = true;
    try {
      final auth = twitchAuth;

      _setupSubscriptions();

      if (!auth.isConfigured) return;

      sevenTvClient?.connect();

      // EventSub session lifecycle: subscriptions are session-scoped, so drop
      // moderation-channel state when the session dies (IRC fallback resumes)
      // until the session comes back and subscriptions are re-created.
      statusSub?.cancel();
      statusSub = eventSub.onStatus.listen((status) {
        if (isDisposed) return;
        if (status == EventSubStatus.disconnected) {
          _moderationChannels.clear();
        }
      });

      ircStatusSub?.cancel();
      ircStatusSub = irc.onStatus.listen((status) async {
        if (isDisposed) return;
        onRebuild();
        if (status == IrcConnectionStatus.connected && irc.isConnected) {
          // Edge-triggered: subscribeAll once per connect with 30s throttle.
          // The 500ms settle delay only applies on reconnect — the sockets
          // rejoin channels themselves on reconnect.
          if (!_wasConnected) {
            final isReconnect = _wasDisconnected;
            _wasConnected = true;
            _wasDisconnected = false;
            // Re-fetch history after a reconnect (not on first connect) so
            // messages missed while disconnected are recovered. Fires before
            // the 30s throttle so reconnect flapping still re-fetches; the
            // throttle only gates Helix re-subscriptions.
            if (isReconnect) {
              onReconnected?.call();
            }
            final now = DateTime.now();
            if (_lastSubscribeAll != null &&
                now.difference(_lastSubscribeAll!).inSeconds < 30) {
              return;
            }
            final firstConnect = _lastSubscribeAll == null;
            _lastSubscribeAll = now;
            if (!firstConnect) {
              await Future.delayed(const Duration(milliseconds: 500));
            }
            // "Connected" is emitted before subscriptions are created — the
            // user sees it as soon as the socket is up, not after Helix calls.
            for (final channel in channels) {
              if (_connectedAcked.add(channel)) {
                onSystemMessage(channel, 'Connected');
              }
            }
            subscribeAll();
            if (!userTwitchEmotesLoaded) {
              userTwitchEmotesLoaded = true;
              unawaited(
                loadUserTwitchEmotes().catchError(
                  (e) => debugPrint(
                    '[ChatConn] loadUserTwitchEmotes failed on reconnect: $e',
                  ),
                ),
              );
            }
          }
        }
        if (status == IrcConnectionStatus.disconnected && !_wasDisconnected) {
          _wasDisconnected = true;
          _wasConnected = false;
          _connectedAcked.clear();
          _lastSubscribeAll = null;
          for (final channel in channels) {
            onSystemMessage(channel, 'Disconnected');
          }
        }
      });
      // Use the cached account if available so cold start skips the Helix
      // user lookup entirely.
      if (getCurrentUserLogin() == null &&
          auth.login != null &&
          auth.userId != null) {
        setCurrentUserLogin(auth.login);
        setCurrentUserId(auth.userId);
      }

      // EventSub needs no credentials — connect it in parallel with the
      // current-user lookup. Only IRC needs the login, so the sockets wait
      // for the lookup but not for each other.
      final eventSubFuture = eventSub.connect();
      Future<Map<String, dynamic>?>? userFuture;
      if (getCurrentUserLogin() == null) {
        userFuture = _ensureCurrentUser(auth);
      }

      Map<String, dynamic>? currentUser;
      if (userFuture != null) {
        try {
          currentUser = await userFuture;
        } catch (_) {
          debugPrint('[ChatConn] getCurrentUser failed');
        }
      }
      if (currentUser != null) {
        setCurrentUserLogin(currentUser['login']);
        setCurrentUserId(currentUser['id']);
      }

      if (getCurrentUserLogin() != null && auth.accessToken != null) {
        try {
          await Future.wait([
            irc.connect(
              username: getCurrentUserLogin()!,
              accessToken: auth.accessToken!,
            ),
            ircRead.connect(
              username: getCurrentUserLogin()!,
              accessToken: auth.accessToken!,
            ),
          ]);
        } catch (e) {
          debugPrint('IRC connect failed: $e');
        }
      }

      await eventSubFuture;
    } finally {
      _isConnecting = false;
    }
  }

  void _setupSubscriptions() {
    messageSub ??= irc.onMessage.listen(onMessage);
    ircDeleteSub ??= irc.onMessageDeleted.listen((event) {
      if (isDisposed) return;
      final msgs = channelMessages[event.channel];
      if (msgs == null) return;
      var found = false;
      for (final msg in msgs) {
        if (msg.messageId == event.messageId && !msg.isSystem) {
          msg.deleted = true;
          invalidateMessage(event.channel, msg.messageId);
          found = true;
          break;
        }
      }
      // While the channel.moderate v2 subscription is active, deletions come
      // from EventSub (with moderator + message body) — skip the IRC copy.
      if (found && !_moderationChannels.contains(event.channel)) {
        onSystemMessage(
          event.channel,
          'A message from ${event.user} was deleted saying: "${event.deletedMessageText}".',
        );
      }
    });

    ircBanSub?.cancel();
    ircBanSub = irc.onBan.listen((event) {
      _handleBanEvent(
        channel: event.channel,
        user: event.user,
        isTimeout: event.isTimeout,
        duration: event.duration,
      );
    });

    ircNoticeSub?.cancel();
    ircNoticeSub = irc.onNotice.listen((event) {
      if (isDisposed) return;
      // With channel.moderate active, room-state changes come from EventSub
      // with structured data — suppress the redundant IRC NOTICE.
      if (_moderationChannels.contains(event.channel) &&
          _roomStateNoticeIds.contains(event.msgId)) {
        return;
      }
      onSystemMessage(event.channel, event.message);
    });

    ircJtvSub?.cancel();
    ircJtvSub = irc.onJtvMessage.listen((event) {
      if (isDisposed) return;
      onSystemMessage(event.channel, event.message);
    });

    ircOwnMsgSub?.cancel();
    ircOwnMsgSub = ircRead.onOwnMessage.listen(onOwnIrcMessage);

    userNoticeSub?.cancel();
    userNoticeSub = irc.onUserNotice.listen((event) {
      if (isDisposed) return;
      final isAnnouncement = event.msgId == 'announcement';
      if (!isAnnouncement) {
        onSystemMessage(
          event.channel,
          buildUserNoticeText(
            msgId: event.msgId,
            displayName: event.displayName,
            systemMsg: event.systemMsg,
            text: event.text,
          ),
        );
        return;
      }
      // DankChat-style: the "Announcement" label plus the announcement text
      // rendered as a normal chat message, both on the announcement color.
      final accent =
          announcementColorFor(event.announcementColor) ??
          announcementColors['PRIMARY']!;
      onSystemMessage(event.channel, 'Announcement', accent: accent);
      final text = event.text?.trim();
      if (text == null || text.isEmpty) return;
      onMessage(
        TwitchMessage(
          login: event.login,
          displayName: event.displayName,
          text: text,
          color: event.color,
          userId: event.userId,
          badges: event.badges,
          emotePositions: event.emotePositions,
          messageId: event.messageId,
          channel: event.channel,
          systemAccent: accent,
        ),
      );
    });

    ircClearSub?.cancel();
    ircClearSub = irc.onChannelClear.listen((event) {
      if (isDisposed) return;
      // With channel.moderate active, clears come from EventSub with the
      // moderator's name — skip the IRC copy.
      if (_moderationChannels.contains(event.channel)) return;
      final msgs = channelMessages[event.channel];
      if (msgs != null) {
        for (final m in msgs) {
          if (!m.isSystem) m.deleted = true;
        }
      }
      invalidateChannel(event.channel);
      onSystemMessage(event.channel, 'Chat was cleared.');
    });

    ircRoomStateSub?.cancel();
    ircRoomStateSub = irc.onRoomState.listen((event) {
      if (isDisposed) return;
      // ROOMSTATE updates are partial (only the changed tags): merge with
      // the previous state before recomposing the status splash.
      _roomStateTags[event.channel] = {
        ...?_roomStateTags[event.channel],
        ...event.tags,
      };
      _composeChatStatus(event.channel);
    });

    moderationSub ??= eventSub.onModeration.listen(_onModerationEvent);

    if (sevenTvClient != null) {
      sevenTvEmoteSub?.cancel();
      sevenTvEmoteSub = sevenTvClient!.onEmoteSetUpdate.listen(
        _onSevenTvEmoteSetUpdate,
      );
      sevenTvUserSub?.cancel();
      sevenTvUserSub = sevenTvClient!.onUserUpdate.listen(_onSevenTvUserUpdate);
    }
  }

  // channel.moderate v2 events in channels with an active subscription:
  // renders moderation system messages and applies message deletions.
  void _onModerationEvent(ModerationEvent event) {
    if (isDisposed) return;
    if (!_moderationChannels.contains(event.channel)) return;

    final mod = event.moderatorName;
    final target = event.targetName;
    final selfLogin = getCurrentUserLogin()?.toLowerCase();
    final isSelfTarget =
        target != null &&
        selfLogin != null &&
        target.toLowerCase() == selfLogin;
    final msgs = channelMessages[event.channel];

    switch (event.action) {
      case 'delete':
        if (event.messageId != null && msgs != null) {
          for (final m in msgs) {
            if (m.messageId == event.messageId && !m.isSystem) {
              m.deleted = true;
              invalidateMessage(event.channel, m.messageId);
              break;
            }
          }
        }
        final body =
            (event.messageBody != null && event.messageBody!.isNotEmpty)
            ? ': "${event.messageBody}"'
            : '';
        onSystemMessage(
          event.channel,
          '$mod deleted a message from $target$body.',
        );
        break;
      case 'clear':
        if (msgs != null) {
          for (final m in msgs) {
            if (!m.isSystem) m.deleted = true;
          }
        }
        invalidateChannel(event.channel);
        onSystemMessage(event.channel, '$mod cleared the chat.');
        break;
      case 'ban':
      case 'timeout':
        if (target != null) _markUserMessagesDeleted(event.channel, target);
        final duration = event.durationSeconds != null
            ? ' for ${event.durationSeconds}s'
            : '';
        final reason = (event.reason != null && event.reason!.isNotEmpty)
            ? ': "${event.reason}"'
            : '';
        onSystemMessage(
          event.channel,
          isSelfTarget
              ? 'You were ${event.action == 'timeout' ? 'timed out$duration' : 'banned'}$reason by $mod.'
              : '$mod ${event.action == 'timeout' ? 'timed out' : 'banned'} $target$duration$reason.',
        );
        break;
      case 'unban':
      case 'untimeout':
        onSystemMessage(
          event.channel,
          isSelfTarget
              ? 'You were unbanned by $mod.'
              : '$mod unbanned $target.',
        );
        break;
      case 'mod':
        onSystemMessage(event.channel, '$mod modded $target.');
        break;
      case 'unmod':
        onSystemMessage(event.channel, '$mod unmodded $target.');
        break;
      case 'vip':
        onSystemMessage(event.channel, '$mod added $target as a VIP.');
        break;
      case 'unvip':
        onSystemMessage(event.channel, '$mod removed $target as a VIP.');
        break;
      case 'warn':
        final reason = (event.reason != null && event.reason!.isNotEmpty)
            ? ': "${event.reason}"'
            : '';
        onSystemMessage(event.channel, '$mod warned $target$reason.');
        break;
    }
  }

  void onMessage(TwitchMessage msg) {
    if (isDisposed) return;

    // Chat content is hidden until the blocked-users list has been applied,
    // and blocked users' messages never appear at all.
    if (isChatReady?.call() == false) return;
    if (!msg.isSystem && isBlocked?.call(msg.login) == true) return;

    if (!msg.isSystem && msg.login.isNotEmpty && msg.channel != null) {
      final preferredName =
          msg.displayName.toLowerCase() == msg.login.toLowerCase()
          ? msg.displayName
          : msg.login;
      userStore.addUser(msg.channel!, preferredName);
    }

    final channel = msg.channel;
    if (channel == null) return;

    if (msg.messageId != null &&
        messageKeys.contains('$channel:${msg.messageId}')) {
      return;
    }

    if (msg.sourceBroadcasterId != null &&
        badgeService.resolveChannelAvatar(msg.sourceBroadcasterId!) == null) {
      badgeService.fetchChannelAvatar(twitchAuth, msg.sourceBroadcasterId!);
    }

    final login = getCurrentUserLogin()?.toLowerCase();

    final isReplyToMe =
        login != null &&
        !msg.isSystem &&
        msg.replyToUser != null &&
        msg.replyToUser!.toLowerCase() == login;
    final altPings = getAltPings?.call() ?? const [];
    final hasAltPing =
        !msg.isSystem &&
        altPings.any((p) => msg.text.toLowerCase().contains(p.toLowerCase()));
    final isMentioned =
        (login != null && !msg.isSystem && isMention(msg.text, login)) ||
        isReplyToMe ||
        hasAltPing;

    if (isMentioned && msg.login != login) {
      if (!msg.isHighlighted &&
          !msg.isHistory &&
          channel != getSelectedChannel()) {
        setUnreadMentions(getUnreadMentions() + 1);
        channelsWithUnreadMentions.add(channel);
        unreadMentionsPerChannel[channel] =
            (unreadMentionsPerChannel[channel] ?? 0) + 1;
      }
      msg.isHighlighted = true;
      onMention?.call(channel, msg);
    }

    channelMessages.putIfAbsent(channel, () => []);
    channelMessages[channel]!.insert(0, msg);
    truncateChannelMessages(channel);

    if (msg.messageId != null) {
      messageKeys.add('$channel:${msg.messageId}');
    }

    if (msg.isHighlighted) {
      channelMessages.putIfAbsent(mentionsChannel, () => []);
      channelMessages[mentionsChannel]!.insert(0, msg);
      final mentionMsgs = channelMessages[mentionsChannel]!;
      final max = getMaxMessagesPerChannel();
      if (mentionMsgs.length > max) {
        mentionMsgs.removeRange(max, mentionMsgs.length);
      }
    }

    if (channel != getSelectedChannel() && !msg.isHistory && !msg.isSystem) {
      channelsWithUnread.add(channel);
    }
    bumpChannel(channel);
    precacheMessageEmotes(msg, channel);
  }

  void onOwnIrcMessage(IrcMessage ircMsg) {
    if (isDisposed) return;
    final channel = ircMsg.params.isNotEmpty
        ? ircMsg.params[0].substring(1)
        : null;
    if (channel == null || ircMsg.trailing == null) return;

    final msg = parseIrcChatMessage(
      ircMsg,
      channel: channel,
      defaultLogin: getCurrentUserLogin(),
      defaultUserId: getCurrentUserId(),
    );

    final preferredName =
        msg.displayName.toLowerCase() == msg.login.toLowerCase()
        ? msg.displayName
        : msg.login;
    if (preferredName.isNotEmpty) {
      userStore.addUser(channel, preferredName);
    }

    if (msg.messageId != null &&
        messageKeys.contains('$channel:${msg.messageId}')) {
      return;
    }

    channelMessages.putIfAbsent(channel, () => []);
    channelMessages[channel]!.insert(0, msg);
    truncateChannelMessages(channel);

    if (msg.messageId != null) {
      messageKeys.add('$channel:${msg.messageId}');
    }

    bumpChannel(channel);
    precacheMessageEmotes(msg, channel);
  }

  void reconnectIfNecessary() {
    final login = getCurrentUserLogin();
    final token = twitchAuth.accessToken;
    if (login == null || token == null) return;

    // A socket can exist while being dead (frozen by the OS during
    // backgrounding). When it looks connected, verify with a PING/PONG
    // round-trip instead of trusting isConnected; force a reconnect if the
    // PONG never comes back.
    if (irc.isConnected) {
      unawaited(
        irc.checkAlive().then((alive) {
          if (!alive) {
            debugPrint('[ChatConn] IRC zombie detected – forcing reconnect');
            irc.forceReconnect();
          }
        }),
      );
    } else {
      unawaited(irc.connect(username: login, accessToken: token));
    }
    if (ircRead.isConnected) {
      unawaited(
        ircRead.checkAlive().then((alive) {
          if (!alive) {
            debugPrint(
              '[ChatConn] IRC read zombie detected – forcing reconnect',
            );
            ircRead.forceReconnect();
          }
        }),
      );
    } else {
      unawaited(ircRead.connect(username: login, accessToken: token));
    }
    // EventSub/7TV have no PING/PONG equivalent, so `isConnected` alone can't
    // spot a zombie socket; a stale session is torn down and re-established.
    if (!eventSub.isConnected || eventSub.isStale) {
      unawaited(eventSub.forceReconnect());
    }
    if (sevenTvClient != null &&
        (!sevenTvClient!.isConnected || sevenTvClient!.isStale)) {
      unawaited(sevenTvClient!.forceReconnect());
    }
  }
}
