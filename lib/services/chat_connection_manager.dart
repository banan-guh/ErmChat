import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import '../models/generic_emote.dart';
import '../models/twitch_badge.dart';
import 'base_irc_connection.dart';
import '../models/twitch_message.dart';
import '../color_utils.dart';
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
import '../util/constants.dart';
import '../util/mention.dart';
import '../util/irc_utils.dart';
import '../util/thread_utils.dart';

class _BanMeta {
  final String user;
  final bool isTimeout;
  bool fromEventSource;
  int stackCount = 1;
  DateTime lastEvent;
  String? firstMessageId;

  _BanMeta({
    required this.user,
    required this.isTimeout,
    required this.fromEventSource,
    DateTime? lastEvent,
  }) : lastEvent = lastEvent ?? DateTime.now();
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
    required this.ownMessageIds,
    required this.bumpChannel,
    required this.invalidateChannel,
    required this.mentionsChannel,
    required this.onRebuild,
    required this.onSystemMessage,
    required this.loadUserTwitchEmotes,
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
  final Map<String, GlobalKey> messageKeys;
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
  final Set<String> ownMessageIds;
  final void Function(String channel) bumpChannel;
  final void Function(String channel) invalidateChannel;
  final String mentionsChannel;
  final VoidCallback onRebuild;
  final void Function(String, String) onSystemMessage;
  final Future<void> Function() loadUserTwitchEmotes;
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
  final Map<String, GlobalKey> messageKeys;
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
  final Set<String> ownMessageIds;
  final void Function(String channel) bumpChannel;
  final void Function(String channel) invalidateChannel;
  final String mentionsChannel;
  final VoidCallback onRebuild;
  final void Function(String, String) onSystemMessage;
  void Function(String channel, TwitchMessage msg)? onMention;
  final Future<void> Function() loadUserTwitchEmotes;
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

  EventSubStatus connectionStatus = EventSubStatus.disconnected;
  bool wasConnected = false;
  bool wasDisconnected = false;
  DateTime? _lastSubscribeAll;
  bool userTwitchEmotesLoaded = false;
  final _connectedAcked = <String>{};
  bool isDisposed = false;
  bool _isConnecting = false;
  final _recentBanMeta = <String, List<_BanMeta>>{};
  static const _banDedupWindowSeconds = 10;

  StreamSubscription<TwitchMessage>? messageSub;
  StreamSubscription<EventSubStatus>? statusSub;
  StreamSubscription<({String messageId, String targetUser, String channel})>?
  deleteSub;
  StreamSubscription<IrcBanEvent>? ircBanSub;
  StreamSubscription<
    ({
      String user,
      String? reason,
      bool isTimeout,
      String? duration,
      int? durationSeconds,
      String channel,
    })
  >?
  eventSubBanSub;
  StreamSubscription<IrcNoticeEvent>? ircNoticeSub;
  StreamSubscription<IrcNoticeEvent>? ircJtvSub;
  StreamSubscription<IrcMessage>? ircOwnMsgSub;
  StreamSubscription<SevenTvEmoteUpdateEvent>? sevenTvEmoteSub;
  StreamSubscription<SevenTvUserUpdate>? sevenTvUserSub;
  StreamSubscription<IrcConnectionStatus>? ircStatusSub;
  StreamSubscription<IrcConnectionStatus>? ircReadStatusSub;

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
      ownMessageIds = config.ownMessageIds,
      bumpChannel = config.bumpChannel,
      invalidateChannel = config.invalidateChannel,
      mentionsChannel = config.mentionsChannel,
      onRebuild = config.onRebuild,
      onSystemMessage = config.onSystemMessage,
      loadUserTwitchEmotes = config.loadUserTwitchEmotes,
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
      onShowSnackBar = config.onShowSnackBar;

  void dispose() {
    isDisposed = true;
    messageSub?.cancel();
    statusSub?.cancel();
    deleteSub?.cancel();
    eventSubBanSub?.cancel();
    ircBanSub?.cancel();
    ircNoticeSub?.cancel();
    ircJtvSub?.cancel();
    ircOwnMsgSub?.cancel();
    sevenTvEmoteSub?.cancel();
    sevenTvUserSub?.cancel();
    ircStatusSub?.cancel();
    ircReadStatusSub?.cancel();
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
        count++;
      }
    }
    debugPrint(
      '[ChatConn] _markUserMessagesDeleted: marked $count messages deleted for user=$username in channel=$channel (total msgs in channel=${msgs.length})',
    );
  }

  // Dual-source (IRC + EventSub) ban dedup within a 10s window.
  // EventSub overrides IRC when arriving second (resets stackCount to 1);
  // IRC after EventSub is suppressed to avoid duplicates.
  ({bool show, int stackCount, _BanMeta? meta}) _processBanInChannel(
    String channel,
    String user,
    bool isTimeout,
    bool fromEventSource,
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
      if (fromEventSource == existing.fromEventSource) {
        existing.stackCount++;
        existing.lastEvent = now;
        return (show: true, stackCount: existing.stackCount, meta: existing);
      } else if (fromEventSource && !existing.fromEventSource) {
        existing.fromEventSource = true;
        existing.lastEvent = now;
        return (show: true, stackCount: 1, meta: existing);
      } else {
        existing.lastEvent = now;
        return (show: false, stackCount: 0, meta: null);
      }
    }

    final meta = _BanMeta(
      user: user,
      isTimeout: isTimeout,
      fromEventSource: fromEventSource,
    );
    metas.add(meta);
    return (show: true, stackCount: 1, meta: meta);
  }

  void _handleBanEvent({
    required String channel,
    required String user,
    required bool isTimeout,
    required String selfDurationStr,
    required String otherDurationStr,
    required bool fromEventSource,
    required String sourceName,
  }) {
    debugPrint(
      '[ChatConn] $sourceName ban received: user=$user channel=$channel isTimeout=$isTimeout',
    );
    if (isDisposed) return;
    _markUserMessagesDeleted(channel, user);
    final result = _processBanInChannel(
      channel,
      user,
      isTimeout,
      fromEventSource,
    );
    if (!result.show) return;
    final isSelf = user.toLowerCase() == getCurrentUserLogin()?.toLowerCase();
    final base = isTimeout
        ? (isSelf
              ? 'You are timed out$selfDurationStr'
              : '$user was timed out$otherDurationStr')
        : (isSelf ? 'You were banned' : '$user was banned');
    final stacked = result.stackCount > 1
        ? ' (${result.stackCount} times)'
        : '';
    final text = '$base$stacked.';
    debugPrint('[ChatConn] $sourceName ban system message: $text');

    if (result.stackCount > 1) {
      if (result.meta?.firstMessageId != null) {
        _updateMessageText(channel, result.meta!.firstMessageId!, text);
        return;
      }
    }
    onSystemMessage(channel, text);
    result.meta?.firstMessageId = channelMessages[channel]?.first.messageId;
  }

  void _updateMessageText(String channel, String messageId, String newText) {
    final msgs = channelMessages[channel];
    if (msgs == null) return;
    for (final m in msgs) {
      if (m.messageId == messageId) {
        m.text = newText;
        invalidateChannel(channel);
        return;
      }
    }
  }

  void maybeAddConnected(String channel) {
    if (connectionStatus == EventSubStatus.connected &&
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

  Future<void> fetchChatStatus(String channel) async {
    final auth = twitchAuth;
    if (!auth.isConfigured) return;

    final userId = channelUserIds[channel];
    if (userId == null || getCurrentUserId() == null) return;

    final settings = await twitchApi.getChatSettings(
      auth,
      userId,
      getCurrentUserId()!,
    );
    final stream = await twitchApi.getStreamInfo(auth, userId);

    final parts = <String>[];
    if (settings != null) {
      if (settings['follower_mode'] == true) parts.add('Followers-only');
      if (settings['subscriber_mode'] == true) parts.add('Subscribers-only');
      if (settings['emote_mode'] == true) parts.add('Emote-only');
      if (settings['slow_mode'] == true) {
        final wait = settings['slow_mode_wait_time'] ?? '?';
        parts.add('Slow ($wait${wait == '?' ? '' : 's'})');
      }
    }
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
        await emoteManager.resolveEmotes(channelName, channelUserId);
        channelsEmotesResolved.add(channelName);
      }

      unawaited(_resolveSevenTvAndSubscribe(channelName, channelUserId));

      if (getCurrentUserLogin() == null) {
        final currentUser = await twitchApi.getCurrentUser(auth);
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

      for (int attempt = 0; attempt < 3; attempt++) {
        final sessionId = eventSub.sessionId;
        if (sessionId == null) {
          if (attempt == 2) {
            onSystemMessage(channelName, 'Warning: EventSub session lost');
          }
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        if (attempt > 0) await Future.delayed(const Duration(seconds: 1));

        final ok = await twitchApi.createSubscription(
          auth: auth,
          sessionId: sessionId,
          broadcasterUserId: channelUserId,
          userId: getCurrentUserId()!,
        );
        if (ok) {
          final okDel = await twitchApi.createDeleteSubscription(
            auth: auth,
            sessionId: sessionId,
            broadcasterUserId: channelUserId,
            userId: getCurrentUserId()!,
          );
          if (!okDel) {
            onSystemMessage(
              channelName,
              'Warning: delete subscription failed (${twitchApi.lastError ?? "unknown"})',
            );
          }
          break;
        }
        if (attempt == 2) {
          onSystemMessage(
            channelName,
            'Warning: chat subscription failed (${twitchApi.lastError ?? "unknown"})',
          );
        }
      }

      final currentUserId = getCurrentUserId();
      if (currentUserId != null) {
        final banSessionId = eventSub.sessionId;
        if (banSessionId != null) {
          await twitchApi.createBanSubscription(
            auth: auth,
            sessionId: banSessionId,
            broadcasterUserId: channelUserId,
            moderatorUserId: currentUserId,
          );
        }
      }
    } catch (_) {
      debugPrint('[ChatConn] subscribeChannel failed for $channelName');
    }

    onRebuild();
    fetchChatStatus(channelName);
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
        final res = await http.get(uri).timeout(httpTimeout);
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

  Future<void> subscribeAll() async {
    for (final channel in channels) {
      await subscribeChannel(channel);
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

      statusSub?.cancel();
      statusSub = eventSub.onStatus.listen((status) async {
        if (isDisposed) return;
        connectionStatus = status;
        onRebuild();
        // Edge-triggered: subscribeAll once per connect with 30s throttle and
        // 500ms settle delay to let the EventSub session stabilize after reconnect.
        if (status == EventSubStatus.connected && !wasConnected) {
          wasConnected = true;
          wasDisconnected = false;
          final now = DateTime.now();
          if (_lastSubscribeAll != null &&
              now.difference(_lastSubscribeAll!).inSeconds < 30) {
            return;
          }
          _lastSubscribeAll = now;
          await Future.delayed(const Duration(milliseconds: 500));
          try {
            await subscribeAll();
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
          } catch (_) {
            debugPrint('[ChatConn] subscribeAll failed on reconnect');
          }
          for (final channel in channels) {
            if (historyLoaded.contains(channel) &&
                _connectedAcked.add(channel)) {
              onSystemMessage(channel, 'Connected');
            }
          }
        }
        if (status == EventSubStatus.disconnected && !wasDisconnected) {
          wasDisconnected = true;
          wasConnected = false;
          _connectedAcked.clear();
          _lastSubscribeAll = null;
          for (final channel in channels) {
            onSystemMessage(channel, 'Disconnected');
          }
        }
      });

      if (getCurrentUserLogin() == null) {
        try {
          final currentUser = await twitchApi.getCurrentUser(auth);
          if (currentUser != null) {
            setCurrentUserLogin(currentUser['login']);
            setCurrentUserId(currentUser['id']);
          }
        } catch (_) {
          debugPrint('[ChatConn] getCurrentUser failed');
        }
      }

      if (getCurrentUserLogin() != null && auth.accessToken != null) {
        ircStatusSub?.cancel();
        ircStatusSub = irc.onStatus.listen((status) {
          if (isDisposed) return;
          if (status == IrcConnectionStatus.connected && irc.isConnected) {
            for (final channel in channels) {
              onSystemMessage(channel, 'Connected to IRC');
            }
          }
        });

        ircReadStatusSub?.cancel();
        ircReadStatusSub = ircRead.onStatus.listen((status) {
          if (isDisposed) return;
        });

        try {
          await irc.connect(
            username: getCurrentUserLogin()!,
            accessToken: auth.accessToken!,
          );
        } catch (_) {}
        try {
          await ircRead.connect(
            username: getCurrentUserLogin()!,
            accessToken: auth.accessToken!,
          );
        } catch (_) {}
      }

      await eventSub.connect();
    } finally {
      _isConnecting = false;
    }
  }

  void _setupSubscriptions() {
    messageSub ??= eventSub.onMessage.listen(onMessage);
    deleteSub ??= eventSub.onMessageDeleted.listen((event) {
      if (isDisposed) return;
      final msgs = channelMessages[event.channel];
      if (msgs == null) return;
      String? deletedUser;
      String? deletedText;
      for (final msg in msgs) {
        if (msg.messageId == event.messageId && !msg.isSystem) {
          msg.deleted = true;
          deletedUser = msg.login;
          deletedText = msg.text;
          break;
        }
      }
      if (deletedUser != null && deletedText != null) {
        onSystemMessage(
          event.channel,
          'A message from $deletedUser was deleted saying: "$deletedText".',
        );
      }
    });

    ircBanSub?.cancel();
    ircBanSub = irc.onBan.listen((event) {
      final durationStr = event.duration != null
          ? ' for ${event.duration}s'
          : '';
      _handleBanEvent(
        channel: event.channel,
        user: event.user,
        isTimeout: event.isTimeout,
        selfDurationStr: durationStr,
        otherDurationStr: durationStr,
        fromEventSource: false,
        sourceName: 'IRC',
      );
    });

    eventSubBanSub?.cancel();
    eventSubBanSub = eventSub.onBan.listen((event) {
      _handleBanEvent(
        channel: event.channel,
        user: event.user,
        isTimeout: event.isTimeout,
        selfDurationStr: event.durationSeconds != null
            ? ' for ${event.durationSeconds}s'
            : '',
        otherDurationStr: event.duration != null
            ? ' for ${event.duration}s'
            : '',
        fromEventSource: true,
        sourceName: 'EventSub',
      );
    });

    ircNoticeSub?.cancel();
    ircNoticeSub = irc.onNotice.listen((event) {
      if (isDisposed) return;
      onSystemMessage(event.channel, event.message);
    });

    ircJtvSub?.cancel();
    ircJtvSub = irc.onJtvMessage.listen((event) {
      if (isDisposed) return;
      onSystemMessage(event.channel, event.message);
    });

    ircOwnMsgSub?.cancel();
    ircOwnMsgSub = ircRead.onOwnMessage.listen(onOwnIrcMessage);

    if (sevenTvClient != null) {
      sevenTvEmoteSub?.cancel();
      sevenTvEmoteSub = sevenTvClient!.onEmoteSetUpdate.listen(
        _onSevenTvEmoteSetUpdate,
      );
      sevenTvUserSub?.cancel();
      sevenTvUserSub = sevenTvClient!.onUserUpdate.listen(
        _onSevenTvUserUpdate,
      );
    }
  }

  void onMessage(TwitchMessage msg) {
    if (isDisposed) return;

    if (!msg.isSystem && msg.login.isNotEmpty && msg.channel != null) {
      userStore.addUser(msg.channel!, msg.displayName);
    }

    final channel = msg.channel;
    if (channel == null) return;

    if (msg.messageId != null &&
        messageKeys.containsKey('$channel:${msg.messageId}')) {
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
    final isMentioned =
        (login != null && !msg.isSystem && isMention(msg.text, login)) ||
        isReplyToMe;

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
      messageKeys.putIfAbsent('$channel:${msg.messageId}', () => GlobalKey());
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

    final displayName =
        ircMsg.tags['display-name']?.trim() ?? getCurrentUserLogin() ?? '';
    if (displayName.isNotEmpty) {
      userStore.addUser(channel, displayName);
    }

    final ircPrefLogin = ircMsg.prefix != null && ircMsg.prefix!.contains('!')
        ? ircMsg.prefix!.substring(0, ircMsg.prefix!.indexOf('!'))
        : null;
    final user = TwitchMessage.resolveUser(
      login: ircPrefLogin ?? getCurrentUserLogin() ?? displayName,
      displayName: displayName.isNotEmpty ? displayName : null,
    );

    final messageId = ircMsg.tags['id'];
    final text = ircMsg.trailing!;
    final ircReplyParentId = ircMsg.tags['reply-parent-msg-id'];
    final ircReplyThreadRootId =
        ircMsg.tags['reply-thread-parent-msg-id'] ?? ircReplyParentId;

    // Twitch's IRC gateway prepends @username to reply echoes only.
    // Twitch IRC prepends "@username " to reply echoes. Strip this prefix
    // so the stored text matches what the user sees; emote positions from IRC
    // tags use original-text coordinates and must be adjusted by prefixLen below.
    String strippedText = text;
    var prefixLen = 0;
    if (ircReplyParentId != null) {
      final prefixMatch = RegExp(r'^\s*@\S+\s+').firstMatch(text);
      if (prefixMatch != null) {
        prefixLen = prefixMatch.end;
        strippedText = text.substring(prefixLen);
      }
    }
    final ircReplyUser = unescapeIrcTagNullable(
      ircMsg.tags['reply-parent-display-name'],
    );
    final ircReplyText = unescapeIrcTagNullable(
      ircMsg.tags['reply-parent-msg-body'],
    );

    if (messageId != null && messageKeys.containsKey('$channel:$messageId')) {
      return;
    }

    final tsMs = ircMsg.tags['tmi-sent-ts'];
    final timestamp = tsMs != null
        ? DateTime.fromMillisecondsSinceEpoch(int.parse(tsMs), isUtc: true)
        : DateTime.now().toUtc();

    final userId = ircMsg.tags['user-id'] ?? getCurrentUserId();
    final color =
        ircMsg.tags['color'] != null && ircMsg.tags['color']!.isNotEmpty
        ? ircMsg.tags['color']!
        : pickColor(user.login);

    List<EmotePosition>? emotePositions;
    final emotesTag = ircMsg.tags['emotes'];
    if (emotesTag != null && emotesTag.isNotEmpty) {
      emotePositions = [];
      for (final emoteEntry in emotesTag.split('/')) {
        final colonIdx = emoteEntry.indexOf(':');
        if (colonIdx == -1) continue;
        final emoteId = emoteEntry.substring(0, colonIdx);
        final positionsStr = emoteEntry.substring(colonIdx + 1);
        for (final posStr in positionsStr.split(',')) {
          final dashIdx = posStr.indexOf('-');
          if (dashIdx == -1) continue;
          final start = int.tryParse(posStr.substring(0, dashIdx));
          final end = int.tryParse(posStr.substring(dashIdx + 1));
          if (start == null || end == null) continue;
          if (start < 0 || end >= text.length) continue;
          final emoteCode = text.substring(start, end + 1);
          final adjStart = start - prefixLen;
          final adjEnd = (end + 1) - prefixLen;
          if (adjStart < 0 || adjEnd > strippedText.length) continue;
          emotePositions.add(
            EmotePosition(
              emoteId: emoteId,
              startIndex: adjStart,
              endIndex: adjEnd,
              emoteCode: emoteCode,
            ),
          );
        }
      }
      if (emotePositions.isEmpty) emotePositions = null;
    }

    // Parse badges from IRC tags
    List<MessageBadge>? badges;
    final badgesTag = ircMsg.tags['badges'];
    if (badgesTag != null && badgesTag.isNotEmpty) {
      badges = [];
      for (final entry in badgesTag.split(',')) {
        final slashIdx = entry.indexOf('/');
        if (slashIdx == -1) continue;
        final setId = entry.substring(0, slashIdx);
        final versionId = entry.substring(slashIdx + 1);
        if (setId.isNotEmpty && versionId.isNotEmpty) {
          badges.add(MessageBadge(setId: setId, versionId: versionId));
        }
      }
      if (badges.isEmpty) badges = null;
    }

    final msg = TwitchMessage(
      login: user.login,
      displayName: user.displayName,
      text: strippedText,
      channel: channel,
      messageId: messageId,
      timestamp: timestamp,
      userId: userId,
      color: color,
      replyToParentId: ircReplyParentId,
      replyToUser: ircReplyUser,
      replyToText: ircReplyText,
      replyThreadRootId: ircReplyThreadRootId,
      emotePositions: emotePositions,
      badges: badges,
    );

    channelMessages.putIfAbsent(channel, () => []);
    channelMessages[channel]!.insert(0, msg);
    truncateChannelMessages(channel);

    if (messageId != null) {
      messageKeys.putIfAbsent('$channel:$messageId', () => GlobalKey());
    }

    bumpChannel(channel);
    precacheMessageEmotes(msg, channel);
  }

  void reconnectIfNecessary() {
    final login = getCurrentUserLogin();
    final token = twitchAuth.accessToken;
    if (login == null || token == null) return;

    if (!irc.isConnected) {
      unawaited(irc.connect(username: login, accessToken: token));
    }
    if (!ircRead.isConnected) {
      unawaited(ircRead.connect(username: login, accessToken: token));
    }
    if (!eventSub.isConnected) {
      unawaited(eventSub.connect());
    }
    if (sevenTvClient != null && !sevenTvClient!.isConnected) {
      unawaited(sevenTvClient!.connect());
    }
  }
}
