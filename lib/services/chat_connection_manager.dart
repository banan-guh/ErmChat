import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import '../models/generic_emote.dart';
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

class ChatConnectionManager {
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
  final Map<String, PendingLocal> pendingLocals;
  final _pendingLocalsByNorm = <String, String>{};
  final Map<String, String> lastTypedText;
  final Map<String, String> lastSentWireText;
  final Set<String> ownMessageIds;
  final ValueNotifier<int> chatVersion;
  final String mentionsChannel;

  String? lastSentText;
  int localCounter = 0;
  EventSubStatus connectionStatus = EventSubStatus.disconnected;
  bool wasConnected = false;
  bool wasDisconnected = false;
  bool userTwitchEmotesLoaded = false;
  bool mounted = true;
  bool _isConnecting = false;

  StreamSubscription<TwitchMessage>? messageSub;
  StreamSubscription<EventSubStatus>? statusSub;
  StreamSubscription<({String messageId, String targetUser, String channel})>?
  deleteSub;
  StreamSubscription<IrcBanEvent>? ircBanSub;
  StreamSubscription<({String user, String? reason, bool isTimeout, String? duration, String channel})>? eventSubBanSub;
  StreamSubscription<IrcNoticeEvent>? ircNoticeSub;
  StreamSubscription<IrcNoticeEvent>? ircJtvSub;
  StreamSubscription<IrcMessage>? ircOwnMsgSub;
  StreamSubscription<String>? userColorSub;
  StreamSubscription<SevenTvEmoteUpdateEvent>? sevenTvEmoteSub;
  StreamSubscription<SevenTvUserUpdate>? sevenTvUserSub;

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
  final String? Function() getCurrentUserColor;
  final void Function(String?) setCurrentUserColor;
  final void Function(String, String, TwitchAuth) onCommand;
  final TwitchMessage? Function() getReplyToMsg;
  final void Function(TwitchMessage?) setReplyToMsg;
  final void Function() onRequestFocus;
  final void Function(String) onShowSnackBar;

  ChatConnectionManager({
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
    required this.pendingLocals,
    required this.lastTypedText,
    required this.lastSentWireText,
    required this.ownMessageIds,
    required this.chatVersion,
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
    required this.getCurrentUserColor,
    required this.setCurrentUserColor,
    required this.onCommand,
    required this.getReplyToMsg,
    required this.setReplyToMsg,
    required this.onRequestFocus,
    required this.onShowSnackBar,
  });

  void dispose() {
    mounted = false;
    messageSub?.cancel();
    statusSub?.cancel();
    deleteSub?.cancel();
    eventSubBanSub?.cancel();
    ircBanSub?.cancel();
    ircNoticeSub?.cancel();
    ircJtvSub?.cancel();
    ircOwnMsgSub?.cancel();
    userColorSub?.cancel();
    sevenTvEmoteSub?.cancel();
    sevenTvUserSub?.cancel();
  }

  String? _unescapeIrcTag(String? raw) {
    if (raw == null) return null;
    return raw
        .replaceAll('\\s', ' ')
        .replaceAll('\\\\', '\\')
        .replaceAll('\\:', ';')
        .replaceAll('\\r', '\r')
        .replaceAll('\\n', '\n');
  }

  void _markUserMessagesDeleted(String channel, String username) {
    final msgs = channelMessages[channel];
    if (msgs == null) {
      debugPrint('[ChatConn] _markUserMessagesDeleted: no messages for channel=$channel');
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
    debugPrint('[ChatConn] _markUserMessagesDeleted: marked $count messages deleted for user=$username in channel=$channel (total msgs in channel=${msgs.length})');
  }

  void maybeAddConnected(String channel) {
    if (connectionStatus == EventSubStatus.connected &&
        historyLoaded.contains(channel)) {
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

    final settings = await TwitchApi.getChatSettings(
      auth,
      userId,
      getCurrentUserId()!,
    );
    final stream = await TwitchApi.getStreamInfo(auth, userId);

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
    chatVersion.value++;
  }

  void insertLocalMessage(
    String text,
    String channel,
    String? messageId,
    TwitchMessage? replyTo,
  ) {
    final login = getCurrentUserLogin();
    if (login == null) return;

    final useTempId = messageId == null;
    final effectiveId = useTempId ? 'local_${localCounter++}' : messageId;

    if (!useTempId && messageKeys.containsKey('$channel:$effectiveId')) {
      return;
    }

    final msg = TwitchMessage(
      login: login,
      text: text,
      channel: channel,
      messageId: effectiveId,
      color: getCurrentUserColor() ?? pickColor(login.toLowerCase()),
      userId: getCurrentUserId(),
      replyToParentId: replyTo?.messageId,
      replyToUser: replyTo?.displayName,
      replyToText: replyTo?.text,
    );
    channelMessages.putIfAbsent(channel, () => []);
    channelMessages[channel]!.insert(0, msg);
    if (useTempId) {
      pendingLocals[effectiveId] = PendingLocal(channel, text);
      _pendingLocalsByNorm['$channel:${normalizeForReconciliation(text)}'] =
          effectiveId;
    }
    truncateChannelMessages(channel);
    if (!useTempId) {
      messageKeys.putIfAbsent('$channel:$messageId', () => GlobalKey());
    }
    chatVersion.value++;
  }

  void truncateChannelMessages(String channel) {
    final maxMessages = getMaxMessagesPerChannel();
    if (maxMessages <= 0) return;
    final msgs = channelMessages[channel];
    if (msgs == null || msgs.length <= maxMessages) return;

    // Build reply graph: parentOf maps childId -> parentId,
    // children maps parentId -> set of childIds.
    final parentOf = <String, String>{};
    final children = <String, Set<String>>{};
    for (final m in msgs) {
      if (m.replyToParentId != null && m.messageId != null) {
        parentOf[m.messageId!] = m.replyToParentId!;
        children.putIfAbsent(m.replyToParentId!, () => {});
        children[m.replyToParentId!]!.add(m.messageId!);
      }
    }

    String findRoot(String id) {
      var cur = id;
      while (parentOf.containsKey(cur)) {
        cur = parentOf[cur]!;
      }
      return cur;
    }

    // Phase 1: find active thread roots — roots that have at least one
    // message in the visible window (first maxMessages non-system messages).
    final activeRoots = <String>{};
    int visibleCount = 0;
    for (final m in msgs) {
      if (m.isSystem) continue;
      if (visibleCount >= maxMessages) break;
      visibleCount++;
      if (m.messageId == null) continue;
      if (children.containsKey(m.messageId!)) {
        activeRoots.add(m.messageId!);
      }
      if (parentOf.containsKey(m.messageId!)) {
        activeRoots.add(findRoot(m.messageId!));
      }
    }

    // Phase 2: BFS from active roots to collect all thread message IDs
    // across the entire thread (root + all descendants).
    final threadIds = <String>{};
    if (activeRoots.isNotEmpty) {
      final queue = <String>[...activeRoots];
      while (queue.isNotEmpty) {
        final id = queue.removeAt(0);
        if (!threadIds.add(id)) continue;
        final kids = children[id];
        if (kids != null) {
          for (final child in kids) {
            if (!threadIds.contains(child)) queue.add(child);
          }
        }
      }
    }

    // Phase 3: collect indices to keep. Keep all active thread messages plus
    // the first maxMessages non-thread non-system messages. Orphan thread
    // messages (thread-adjacent but not in an active thread) are removed.
    final keepIndices = <int>{};
    int nonThreadKept = 0;
    int systemKept = 0;
    for (int i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      final isActiveThread =
          m.messageId != null && threadIds.contains(m.messageId!);
      if (isActiveThread) {
        keepIndices.add(i);
      } else if (m.isSystem) {
        // system messages past the limit are removed
        if (systemKept < maxMessages) {
          keepIndices.add(i);
          systemKept++;
        }
      } else {
        final isOrphanThread = m.messageId != null && !isActiveThread && (
            parentOf.containsKey(m.messageId!) ||
            children.containsKey(m.messageId!));
        if (!isOrphanThread && nonThreadKept < maxMessages) {
          keepIndices.add(i);
          nonThreadKept++;
        }
      }
    }

    // Phase 4: remove messages not in keepIndices.
    // Remove from high to low index so indices stay stable.
    for (int i = msgs.length - 1; i >= 0; i--) {
      if (!keepIndices.contains(i)) {
        msgs.removeAt(i);
      }
    }
  }

  Future<void> subscribeChannel(String channelName) async {
    irc.join(channelName);
    ircRead.join(channelName);

    try {
      final auth = twitchAuth;
      final channelUserId = await TwitchApi.getUserId(auth, channelName);
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
        final currentUser = await TwitchApi.getCurrentUser(auth);
        if (currentUser == null) return;
        setCurrentUserLogin(currentUser['login']);
        setCurrentUserId(currentUser['id']);
      }

      if (!userTwitchEmotesLoaded) {
        userTwitchEmotesLoaded = true;
        unawaited(loadUserTwitchEmotes());
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

        final ok = await TwitchApi.createSubscription(
          auth: auth,
          sessionId: sessionId,
          broadcasterUserId: channelUserId,
          userId: getCurrentUserId()!,
        );
        if (ok) {
          final okDel = await TwitchApi.createDeleteSubscription(
            auth: auth,
            sessionId: sessionId,
            broadcasterUserId: channelUserId,
            userId: getCurrentUserId()!,
          );
          if (!okDel) {
            onSystemMessage(
              channelName,
              'Warning: delete subscription failed (${TwitchApi.lastError ?? "unknown"})',
            );
          }
          break;
        }
        if (attempt == 2) {
          onSystemMessage(
            channelName,
            'Warning: chat subscription failed (${TwitchApi.lastError ?? "unknown"})',
          );
        }
      }
    } catch (_) {}

    onRebuild();
    fetchChatStatus(channelName);
  }

  Future<void> _resolveSevenTvAndSubscribe(
    String channelName,
    String twitchChannelId,
  ) async {
    if (sevenTvClient == null) return;
    try {
      final uri = Uri.parse('https://7tv.io/v3/users/twitch/$twitchChannelId');
      final res = await http.get(uri);
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final userId = (data['user'] as Map<String, dynamic>?)?['id'] as String?;
      final emoteSet =
          data['emote_set'] as Map<String, dynamic>?;
      final emoteSetId = emoteSet?['id'] as String?;
      if (userId == null || emoteSetId == null) return;
      emoteManager.setSevenTvEmoteSetId(channelName, emoteSetId);
      sevenTvClient!.subscribeEmoteSet(emoteSetId);
      sevenTvClient!.subscribeUser(userId);
      debugPrint(
        '[7TV] subscribed channel=$channelName emoteSetId=$emoteSetId userId=$userId',
      );
    } catch (_) {}
  }

  void _onSevenTvEmoteSetUpdate(SevenTvEmoteUpdateEvent event) {
    final channel = emoteManager.getChannelForSevenTvEmoteSet(event.emoteSetId);
    if (channel == null) return;

    final added = event.added
        .map((e) => SevenTvEmoteProvider.parseSingleEmote(e.raw, channel: true))
        .whereType<GenericEmote>()
        .toList();
    final removedIds =
        event.removed.map((e) => e.id).toList();
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
    onSystemMessage(
      channel,
      '$actor switched the active 7TV Emote Set.',
    );
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

    if (!mounted) return;
    setReplyToMsg(null);
    onRebuild();
    onRequestFocus();

    final userLogin = getCurrentUserLogin();
    if (userLogin == null) {
      onShowSnackBar('Connect an account to chat');
      return;
    }

    final String wireText;
    if (text == lastTypedText[channel]) {
      final lastWire = lastSentWireText[channel] ?? text;
      wireText = bypassTextDuplicate(lastWire);
    } else {
      wireText = text;
    }
    lastTypedText[channel] = text;
    lastSentWireText[channel] = wireText;

    if (getCurrentUserId() != null && auth.isConfigured) {
      final broadcasterId =
          channelUserIds[channel] ?? await TwitchApi.getUserId(auth, channel);
      if (broadcasterId != null) {
        try {
          final messageId = await TwitchApi.sendChatMessage(
            auth,
            broadcasterId: broadcasterId,
            senderId: getCurrentUserId()!,
            message: wireText,
            replyParentMessageId: reply?.messageId,
          );
          if (messageId != null && mounted) {
            ownMessageIds.add(messageId);
            insertLocalMessage(text, channel, messageId, reply);
          }
        } catch (_) {}
        return;
      }
    }

    insertLocalMessage(text, channel, null, reply);
    irc.sendMessage(channel, wireText, replyParentMessageId: reply?.messageId);
  }

  Future<void> connect() async {
    if (_isConnecting || !mounted) return;
    _isConnecting = true;
    try {
    final auth = twitchAuth;

    messageSub ??= eventSub.onMessage.listen(onMessage);
    deleteSub ??= eventSub.onMessageDeleted.listen((event) {
      if (!mounted) return;
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
      debugPrint('[ChatConn] IRC ban received: user=${event.user} channel=${event.channel} isTimeout=${event.isTimeout}');
      if (!mounted) return;
      _markUserMessagesDeleted(event.channel, event.user);
      final text = event.isTimeout
          ? '${event.user} was timed out${event.duration != null ? ' for ${event.duration}s' : ''}.'
          : '${event.user} was banned.';
      debugPrint('[ChatConn] IRC ban system message: $text');
      onSystemMessage(event.channel, text);
    });

    eventSubBanSub?.cancel();
    eventSubBanSub = eventSub.onBan.listen((event) {
      debugPrint('[ChatConn] EventSub ban received: user=${event.user} channel=${event.channel} isTimeout=${event.isTimeout}');
      if (!mounted) return;
      _markUserMessagesDeleted(event.channel, event.user);
      final text = event.isTimeout
          ? '${event.user} was timed out${event.duration != null ? ' for ${event.duration}s' : ''}.'
          : '${event.user} was banned.';
      debugPrint('[ChatConn] EventSub ban system message: $text');
      onSystemMessage(event.channel, text);
    });

    ircNoticeSub?.cancel();
    ircNoticeSub = irc.onNotice.listen((event) {
      if (!mounted) return;
      onSystemMessage(event.channel, event.message);
    });

    ircJtvSub?.cancel();
    ircJtvSub = irc.onJtvMessage.listen((event) {
      if (!mounted) return;
      onSystemMessage(event.channel, event.message);
    });

    ircOwnMsgSub?.cancel();
    ircOwnMsgSub = ircRead.onOwnMessage.listen(onOwnIrcMessage);

    userColorSub?.cancel();
    userColorSub = ircRead.onUserColor.listen((color) {
      setCurrentUserColor(color);
      final login = getCurrentUserLogin();
      if (login != null) {
        final lowerLogin = login.toLowerCase();
        for (final entry in channelMessages.entries) {
          for (final msg in entry.value) {
            if (msg.login == lowerLogin && !msg.isSystem) {
              msg.color = color;
            }
          }
        }
      }
      chatVersion.value++;
    });

    if (!auth.isConfigured) return;

    if (sevenTvClient != null) {
      sevenTvEmoteSub?.cancel();
      sevenTvEmoteSub = sevenTvClient!.onEmoteSetUpdate.listen(_onSevenTvEmoteSetUpdate);
      sevenTvUserSub?.cancel();
      sevenTvUserSub = sevenTvClient!.onUserUpdate.listen(_onSevenTvUserUpdate);
      sevenTvClient!.connect();
    }

    statusSub?.cancel();
    statusSub = eventSub.onStatus.listen((status) async {
      if (!mounted) return;
      connectionStatus = status;
      if (status == EventSubStatus.connected && !wasConnected) {
        wasConnected = true;
        wasDisconnected = false;
        await Future.delayed(const Duration(milliseconds: 500));
        try {
          await subscribeAll();
          if (!userTwitchEmotesLoaded) {
            userTwitchEmotesLoaded = true;
            unawaited(loadUserTwitchEmotes());
          }
        } catch (_) {}
        for (final channel in channels) {
          if (historyLoaded.contains(channel)) {
            onSystemMessage(channel, 'Connected');
          }
        }
      }
      if (status == EventSubStatus.disconnected && !wasDisconnected) {
        wasDisconnected = true;
        wasConnected = false;
        for (final channel in channels) {
          onSystemMessage(channel, 'Disconnected');
        }
      }
    });

    if (getCurrentUserLogin() == null) {
      try {
        final currentUser = await TwitchApi.getCurrentUser(auth);
        if (currentUser != null) {
          setCurrentUserLogin(currentUser['login']);
          setCurrentUserId(currentUser['id']);
        }
      } catch (_) {}
    }

    if (getCurrentUserLogin() != null && auth.accessToken != null) {
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

  void onMessage(TwitchMessage msg) {
    if (!mounted) return;

    if (!msg.isSystem && msg.login.isNotEmpty && msg.channel != null) {
      userStore.addUser(msg.channel!, msg.displayName);
    }

    final channel = msg.channel;
    if (channel == null) return;

    if (msg.messageId != null &&
        messageKeys.containsKey('$channel:${msg.messageId}')) {
      final existing = channelMessages[channel];
      if (msg.emotePositions != null && existing != null) {
        final idx = existing.indexWhere(
          (m) => m.messageId == msg.messageId,
        );
        if (idx != -1) {
          existing[idx] = msg;
          chatVersion.value++;
        }
      }
      return;
    }

    if (msg.messageId != null &&
        getCurrentUserLogin() != null &&
        msg.login == getCurrentUserLogin()!.toLowerCase()) {
      final normKey = '$channel:${normalizeForReconciliation(msg.text)}';
      final pendingKey = _pendingLocalsByNorm.remove(normKey);
      if (pendingKey != null) {
        pendingLocals.remove(pendingKey);
        channelMessages[channel]?.removeWhere(
          (m) => m.messageId == pendingKey,
        );
      }
      ownMessageIds.add(msg.messageId!);
    }

    if (msg.sourceBroadcasterId != null &&
        badgeService.resolveChannelAvatar(msg.sourceBroadcasterId!) == null) {
      badgeService.fetchChannelAvatar(
        twitchAuth,
        msg.sourceBroadcasterId!,
      );
    }

    final login = getCurrentUserLogin()?.toLowerCase();

    final isReplyToMe =
        login != null &&
        !msg.isSystem &&
        msg.replyToUser != null &&
        msg.replyToUser!.toLowerCase() == login;
    final isMentioned =
        (login != null &&
            !msg.isSystem &&
            _isMention(msg, login)) ||
        isReplyToMe;

    if (isMentioned) {
      if (!msg.isHighlighted && !msg.isHistory && channel != getSelectedChannel()) {
        setUnreadMentions(getUnreadMentions() + 1);
        channelsWithUnreadMentions.add(channel);
        unreadMentionsPerChannel[channel] =
            (unreadMentionsPerChannel[channel] ?? 0) + 1;
      }
      msg.isHighlighted = true;
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
    }

    if (channel != getSelectedChannel() && !msg.isHistory && !msg.isSystem) {
      channelsWithUnread.add(channel);
    }
    chatVersion.value++;
    precacheMessageEmotes(msg, channel);
  }

  bool _isMention(TwitchMessage msg, String login) {
    return isMention(msg.text, login);
  }

  void onOwnIrcMessage(IrcMessage ircMsg) {
    if (!mounted) return;
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

    final colorTag = ircMsg.tags['color'];
    if (colorTag != null && colorTag.isNotEmpty) {
      setCurrentUserColor(colorTag);
    }

    final messageId = ircMsg.tags['id'];
    final text = ircMsg.trailing!;
    final ircReplyParentId = ircMsg.tags['reply-parent-msg-id'];

    // Twitch's IRC gateway prepends @username to reply echoes only.
    // Only strip the prefix when this is an actual reply.
    String strippedText = text;
    var prefixLen = 0;
    if (ircReplyParentId != null) {
      final prefixMatch = RegExp(r'^\s*@\S+\s+').firstMatch(text);
      if (prefixMatch != null) {
        prefixLen = prefixMatch.end;
        strippedText = text.substring(prefixLen);
      }
    }
    final ircReplyUser = _unescapeIrcTag(
      ircMsg.tags['reply-parent-display-name'],
    );
    final ircReplyText = _unescapeIrcTag(
      ircMsg.tags['reply-parent-msg-body'],
    );

    if (messageId != null && messageKeys.containsKey('$channel:$messageId')) {
      return;
    }

    final normKey = '$channel:${normalizeForReconciliation(strippedText)}';
    final pendingKey = _pendingLocalsByNorm.remove(normKey);
    TwitchMessage? pendingMsg;
    if (pendingKey != null) {
      final existing = channelMessages[channel];
      if (existing != null) {
        final idx = existing.indexWhere((m) => m.messageId == pendingKey);
        if (idx != -1) {
          pendingMsg = existing[idx];
        }
      }
      pendingLocals.remove(pendingKey);
      channelMessages[channel]?.removeWhere((m) => m.messageId == pendingKey);
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

    final msg = TwitchMessage(
      login: user.login,
      displayName: user.displayName,
      text: strippedText,
      channel: channel,
      messageId: messageId,
      timestamp: timestamp,
      userId: userId,
      color: color,
      replyToParentId: pendingMsg?.replyToParentId ?? ircReplyParentId,
      replyToUser: pendingMsg?.replyToUser ?? ircReplyUser,
      replyToText: pendingMsg?.replyToText ?? ircReplyText,
      emotePositions: emotePositions,
    );

    channelMessages.putIfAbsent(channel, () => []);
    channelMessages[channel]!.insert(0, msg);
    truncateChannelMessages(channel);

    if (messageId != null) {
      messageKeys.putIfAbsent('$channel:$messageId', () => GlobalKey());
    }

    chatVersion.value++;
    precacheMessageEmotes(msg, channel);
  }
}

bool isMention(String text, String login) {
  final words = text.split(RegExp(r'[\s,;:.!?()\[\]{}<>"/\\|@#$%^&*+=~`]+'));
  for (final w in words) {
    final lower = w.toLowerCase();
    if (lower == '@$login' || lower == login) return true;
  }
  return false;
}

class PendingLocal {
  final String channel;
  final String text;
  PendingLocal(this.channel, this.text);
}
