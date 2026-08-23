import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import '../models/generic_emote.dart';
import '../util/log.dart';
import '../models/twitch_message.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_eventsub.dart';
import '../services/twitch_irc.dart';
import '../services/emote_manager.dart';
import '../services/emote_providers/seven_tv_emotes.dart';
import '../services/seven_tv_event_client.dart';
import '../services/twitch_badge_service.dart';
import '../services/user_store.dart';
import '../services/command_macros.dart';
import '../services/ping_manager.dart';
import '../services/ignore_manager.dart';
import '../services/chat_ingestion.dart';
import '../services/chat_store.dart';
import '../util/text_bypass.dart';
import '../color_utils.dart';
import '../util/constants.dart';

/// Services the chat pipeline depends on. Constructed once per screen and
/// injectable for tests.
class ChatServices {
  ChatServices({
    required this.twitchApi,
    required this.eventSub,
    required this.irc,
    required this.ircRead,
    this.sevenTvClient,
    required this.emoteManager,
    required this.badgeService,
    required this.userStore,
    required this.twitchAuth,
    this.pingManager,
    this.ignoreManager,
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
  final PingManager? pingManager;
  final IgnoreManager? ignoreManager;
}

/// Rendering and interaction signals flowing manager -> UI: buffer change
/// notifications, system messages, focus and snackbar requests, plus reads
/// of view-owned state the pipeline needs (selected channel, message cap).
class ChatViewBridge {
  ChatViewBridge({
    required this.mentionsChannel,
    required this.onRebuild,
    required this.onSystemMessage,
    required this.getSelectedChannel,
    required this.getMaxMessagesPerChannel,
  });

  final String mentionsChannel;
  final VoidCallback onRebuild;
  final void Function(String, String, {Color? accent}) onSystemMessage;
  final String? Function() getSelectedChannel;
  final int Function() getMaxMessagesPerChannel;
}

/// Feature integrations: commands, reply state, analytics, TTS, EventSub
/// widget events and account-scoped queries. Mostly optional; a missing
/// sink disables that integration.
class ChatSinks {
  ChatSinks({
    required this.onCommand,
    required this.getReplyToMsg,
    required this.setReplyToMsg,
    this.onUserEmoteSets,
    this.onReconnected,
    this.getMacros,
    this.isChatReady,
    this.isBlocked,
    this.getSharedChatMode,
    this.onAnalyticsMessage,
    this.onAnalyticsModeration,
    this.onHypeTrain,
    this.onPoll,
    this.onPrediction,
    this.onChatMessage,
  });

  final void Function(String, String, TwitchAuth) onCommand;
  final TwitchMessage? Function() getReplyToMsg;
  final void Function(TwitchMessage?) setReplyToMsg;
  final Future<void> Function(String?, List<String>)? onUserEmoteSets;
  final VoidCallback? onReconnected;
  final Map<String, String> Function()? getMacros;
  final bool Function()? isChatReady;
  final bool Function(String login)? isBlocked;
  final String Function()? getSharedChatMode;
  final void Function(String channel, TwitchMessage msg)? onAnalyticsMessage;
  final void Function(String channel, bool isTimeout)? onAnalyticsModeration;
  final void Function(HypeTrainEvent event)? onHypeTrain;
  final void Function(PollEvent event)? onPoll;
  final void Function(PredictionEvent event)? onPrediction;
  final void Function(String channel, TwitchMessage msg)? onChatMessage;
}

class ChatConnectionConfig {
  ChatConnectionConfig({
    required this.services,
    required this.store,
    required this.bridge,
    required this.sinks,
  });

  final ChatServices services;
  final ChatStore store;
  final ChatViewBridge bridge;
  final ChatSinks sinks;
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
  final ActiveSession session;
  final ChatStore store;
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
  final Map<String, String> lastSentWireText;
  final String mentionsChannel;
  final VoidCallback onRebuild;
  final void Function(String, String, {Color? accent}) onSystemMessage;
  void Function(String channel, TwitchMessage msg)? onMention;
  void Function(TwitchMessage msg)? onWhisper;
  final Future<void> Function(String?, List<String>)? onUserEmoteSets;
  final VoidCallback? onReconnected;
  final int Function() getMaxMessagesPerChannel;
  final String? Function() getSelectedChannel;
  final void Function(String, String, TwitchAuth) onCommand;
  final TwitchMessage? Function() getReplyToMsg;
  final void Function(TwitchMessage?) setReplyToMsg;
  final PingManager? pingManager;
  final IgnoreManager? ignoreManager;
  final Map<String, String> Function()? getMacros;
  final bool Function()? isChatReady;
  final bool Function(String login)? isBlocked;
  final String Function()? getSharedChatMode;
  final void Function(String channel, TwitchMessage msg)? onAnalyticsMessage;
  final void Function(String channel, bool isTimeout)? onAnalyticsModeration;
  final void Function(HypeTrainEvent event)? onHypeTrain;
  final void Function(PollEvent event)? onPoll;
  final void Function(PredictionEvent event)? onPrediction;
  final void Function(String channel, TwitchMessage msg)? onChatMessage;

  bool _wasConnected = false;
  bool _wasDisconnected = false;
  // Read-socket outage tracking: the read socket dying alone (e.g. a DNS
  // error) must still surface as a visible "Chat reconnecting..." instead of
  // silently freezing chat.
  bool _wasReadDisconnected = false;
  DateTime? _lastSubscribeAll;
  // Credentials the IRC sockets were last told to use. Compared against the
  // desired account on connect() so an account switch tears the sockets down
  // (an already-connected socket otherwise skips the reconnect).
  String? _lastIrcUsername;
  String? _lastIrcToken;
  final _connectedAcked = <String>{};
  // Channels whose JOIN has been confirmed by the server (ROOMSTATE for that
  // channel). isConnected only reflects the socket; a fresh/reconnected socket
  // hasn't necessarily processed the JOINs yet, so sends gate on this.
  final _joinedChannels = <String>{};
  // Channels a join-failure notice was displayed for. A later ROOMSTATE
  // confirmation clears the entry and announces the (late) success.
  final _joinFailureNotified = <String>{};
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
  // Channels with an active hype train / poll / prediction widget subscription
  // (broadcaster-only; see _subscribeWidgets). Same lifecycle as
  // _moderationChannels: cleared when the EventSub session dies.
  final _widgetChannels = <String>{};
  // Channels where the widget subscriptions were rejected with a 403 (not the
  // broadcaster). Persists so we don't re-attempt doomed subscriptions.
  final _widgetSkippedChannels = <String>{};
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
  // Set when a connect() call is dropped by the re-entrancy guard above (e.g.
  // a login landing while a startup connect is still in-flight). Drained at
  // the end of the in-flight connect so the dropped credentials are honored.
  bool _connectRetryRequested = false;
  // Expired-token handling: deduplicates the global expiry message and tracks
  // the last anonymous-vs-authed state so the sockets actually tear down when
  // expiry flips us from authed to anonymous mid-session.
  bool _expiryHandled = false;
  bool _lastIrcAnonymous = true;
  String? _lastValidatedToken;

  // Chat-content routing (PRIVMSG/CLEARMSG/CLEARCHAT/clears/own echo).
  late final ChatIngestion _ingestion = ChatIngestion(
    irc: irc,
    ircRead: ircRead,
    store: store,
    userStore: userStore,
    emoteManager: emoteManager,
    badgeService: badgeService,
    twitchAuth: twitchAuth,
    ignoreManager: ignoreManager,
    pingManager: pingManager,
    mentionsChannel: mentionsChannel,
    getMaxMessagesPerChannel: getMaxMessagesPerChannel,
    getSelectedChannel: getSelectedChannel,
    isChatReady: isChatReady,
    isBlocked: isBlocked,
    getSharedChatMode: getSharedChatMode,
    isModerationActive: (channel) => _moderationChannels.contains(channel),
    onSelfTimeoutArmed: (channel, until) {
      _selfTimeoutUntil[channel] = until;
    },
    onSystemMessage: onSystemMessage,
    onAnalyticsMessage: onAnalyticsMessage,
    onAnalyticsModeration: onAnalyticsModeration,
    onChatMessage: onChatMessage,
    onMention: (channel, msg) => onMention?.call(channel, msg),
  );
  final _ingestionSubs = <StreamSubscription<void>>[];

  StreamSubscription<EventSubStatus>? statusSub;
  StreamSubscription<IrcNoticeEvent>? ircNoticeSub;
  StreamSubscription<IrcNoticeEvent>? ircJtvSub;
  StreamSubscription<IrcJoinFailureEvent>? ircJoinFailedSub;
  StreamSubscription<TwitchMessage>? whisperSub;
  StreamSubscription<UserNoticeEvent>? userNoticeSub;
  StreamSubscription<IrcRoomStateEvent>? ircRoomStateSub;
  StreamSubscription<(String?, List<String>)>? emoteSetsSub;
  StreamSubscription<ModerationEvent>? moderationSub;
  StreamSubscription<HypeTrainEvent>? hypeTrainSub;
  StreamSubscription<PollEvent>? pollSub;
  StreamSubscription<PredictionEvent>? predictionSub;
  StreamSubscription<SevenTvEmoteUpdateEvent>? sevenTvEmoteSub;
  StreamSubscription<SevenTvUserUpdate>? sevenTvUserSub;
  StreamSubscription<IrcConnectionStatus>? ircStatusSub;
  StreamSubscription<IrcConnectionStatus>? ircReadStatusSub;
  StreamSubscription<void>? ircAuthFailedSub;
  final _httpClient = http.Client();

  // Truncation coalescing: the thread-aware pass is O(n) over the channel

  ChatConnectionManager(ChatConnectionConfig config)
    : twitchApi = config.services.twitchApi,
      eventSub = config.services.eventSub,
      irc = config.services.irc,
      ircRead = config.services.ircRead,
      sevenTvClient = config.services.sevenTvClient,
      emoteManager = config.services.emoteManager,
      badgeService = config.services.badgeService,
      userStore = config.services.userStore,
      twitchAuth = config.services.twitchAuth,
      session = config.store.session,
      store = config.store,
      channelMessages = config.store.channelMessages,
      messageKeys = config.store.messageKeys,
      chatStatus = config.store.chatStatus,
      channelsWithUnread = config.store.channelsWithUnread,
      channelsWithUnreadMentions = config.store.channelsWithUnreadMentions,
      unreadMentionsPerChannel = config.store.unreadMentionsPerChannel,
      channels = config.store.channels,
      historyLoaded = config.store.historyLoaded,
      channelsEmotesResolved = config.store.channelsEmotesResolved,
      channelUserIds = config.store.channelUserIds,
      lastSentWireText = config.store.lastSentWireText,
      mentionsChannel = config.bridge.mentionsChannel,
      onRebuild = config.bridge.onRebuild,
      onSystemMessage = config.bridge.onSystemMessage,
      onUserEmoteSets = config.sinks.onUserEmoteSets,
      onReconnected = config.sinks.onReconnected,
      getMaxMessagesPerChannel = config.bridge.getMaxMessagesPerChannel,
      getSelectedChannel = config.bridge.getSelectedChannel,
      onCommand = config.sinks.onCommand,
      getReplyToMsg = config.sinks.getReplyToMsg,
      setReplyToMsg = config.sinks.setReplyToMsg,
      pingManager = config.services.pingManager,
      ignoreManager = config.services.ignoreManager,
      getMacros = config.sinks.getMacros,
      isChatReady = config.sinks.isChatReady,
      isBlocked = config.sinks.isBlocked,
      getSharedChatMode = config.sinks.getSharedChatMode,
      onAnalyticsMessage = config.sinks.onAnalyticsMessage,
      onAnalyticsModeration = config.sinks.onAnalyticsModeration,
      onHypeTrain = config.sinks.onHypeTrain,
      onPoll = config.sinks.onPoll,
      onPrediction = config.sinks.onPrediction,
      onChatMessage = config.sinks.onChatMessage;

  void dispose() {
    isDisposed = true;
    for (final sub in _ingestionSubs) {
      sub.cancel();
    }
    _ingestionSubs.clear();
    _ingestion.dispose();
    statusSub?.cancel();
    ircNoticeSub?.cancel();
    ircJtvSub?.cancel();
    ircJoinFailedSub?.cancel();
    userNoticeSub?.cancel();
    ircRoomStateSub?.cancel();
    emoteSetsSub?.cancel();
    moderationSub?.cancel();
    hypeTrainSub?.cancel();
    pollSub?.cancel();
    predictionSub?.cancel();
    sevenTvEmoteSub?.cancel();
    sevenTvUserSub?.cancel();
    ircStatusSub?.cancel();
    ircReadStatusSub?.cancel();
    ircAuthFailedSub?.cancel();
    whisperSub?.cancel();
    _httpClient.close();
    for (final t in _chatStatusTimers.values) {
      t.cancel();
    }
    _chatStatusTimers.clear();
    // Release any anonymous channel-user-ID waiters so their timeout timers
    // don't outlive the manager (and don't trip widget-test teardown).
    for (final waiters in _roomIdWaiters.values) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.complete(null);
      }
    }
    _roomIdWaiters.clear();
  }

  void stopChatStatusTimer(String channel) {
    _chatStatusTimers.remove(channel)?.cancel();
    _roomStateTags.remove(channel);
    _streamStatusParts.remove(channel);
    irc.selfBadges.remove(channel);
  }

  void maybeAddConnected(String channel) {
    if (irc.isConnected &&
        historyLoaded.contains(channel) &&
        _connectedAcked.add(channel)) {
      onSystemMessage(channel, 'Connected');
    }
  }

  // Room-mode tags per channel from ROOMSTATE (merged across partial
  // updates); feeds the chat status splash. Stream info from the periodic
  // Helix fetch is kept separately so ROOMSTATE recomposes don't lose it.
  final _roomStateTags = <String, Map<String, String>>{};
  final _streamStatusParts = <String, List<String>>{};

  // Self send-gates per channel: when your latest timeout there expires and
  // when you last sent a message (the slow-mode cooldown anchor).
  final _selfTimeoutUntil = <String, DateTime>{};
  final _lastOwnMessageAt = <String, DateTime>{};

  // Badge set-ids that bypass slow mode on Twitch.
  static const _slowExemptBadges = {
    'broadcaster',
    'moderator',
    'vip',
    'subscriber',
    'founder',
    'staff',
    'admin',
    'global_mod',
  };

  bool _bypassesSlowMode(String channel) {
    final badges =
        irc.selfBadges[channel] ?? irc.selfBadges[null] ?? const <String>{};
    return badges.intersection(_slowExemptBadges).isNotEmpty;
  }

  /// Seconds of the channel's current slow mode from the merged ROOMSTATE
  /// tags; 0 when off (missing/empty/0 all mean off).
  int slowModeSeconds(String channel) =>
      int.tryParse(_roomStateTags[channel]?['slow'] ?? '') ?? 0;

  /// Seconds left on your timeout in [channel], null when none is active.
  int? remainingSelfTimeout(String channel) {
    final until = _selfTimeoutUntil[channel];
    if (until == null) return null;
    final left = until.difference(DateTime.now()).inSeconds;
    if (left <= 0) {
      _selfTimeoutUntil.remove(channel);
      return null;
    }
    return left;
  }

  /// Seconds left before you may send again in [channel] under slow mode,
  /// measured from your own last message. Null when slow mode is off, your
  /// badges bypass it, or the window has elapsed.
  int? remainingSlowCooldown(String channel) {
    final slow = slowModeSeconds(channel);
    if (slow <= 0 || _bypassesSlowMode(channel)) return null;
    final sentAt = _lastOwnMessageAt[channel];
    if (sentAt == null) return null;
    final elapsed = DateTime.now().difference(sentAt).inSeconds;
    final left = slow - elapsed;
    return left > 0 ? left : null;
  }

  Future<void> fetchChatStatus(String channel) async {
    final auth = twitchAuth;
    if (!auth.isConfigured) return;

    final userId = channelUserIds[channel];
    if (userId == null || session.userId == null) return;

    // Timer-driven: a network blip (or the client being closed in dispose)
    // must not surface as an unhandled async exception every 60s per channel.
    final Map<String, dynamic>? stream;
    try {
      stream = await twitchApi.getStreamInfo(auth, userId);
    } catch (e) {
      logDebug('[ChatConn] fetchChatStatus failed for $channel: $e');
      return;
    }

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
    final newStatus = parts.isNotEmpty ? parts.join(' · ') : '';
    if (chatStatus[channel] == newStatus) return;
    chatStatus[channel] = newStatus;
    store.touchChannel(channel);
  }

  Future<void> subscribeChannel(String channelName) async {
    irc.join(channelName);
    ircRead.join(channelName);

    try {
      final auth = twitchAuth;
      var channelUserId = auth.accessToken != null
          ? await twitchApi.getUserId(auth, channelName)
          : null;
      // Anonymous: Helix 401s without a token, so the channel user ID comes
      // from the IRC ROOMSTATE room-id tag instead (powers the third-party
      // emote providers and badge fetches).
      channelUserId ??= await _waitForRoomId(channelName);
      if (channelUserId == null) return;
      channelUserIds[channelName] = channelUserId;
      badgeService.fetchChannelBadges(auth, channelUserId, channelName);

      emoteManager.accessToken = auth.accessToken;
      logDebug(
        'subscribeChannel $channelName userId=$channelUserId '
        'hasToken=${auth.accessToken != null} resolved=${channelsEmotesResolved.contains(channelName)}',
      );
      if (!channelsEmotesResolved.contains(channelName)) {
        channelsEmotesResolved.add(channelName);
        unawaited(
          emoteManager
              .resolveEmotes(channelName, channelUserId)
              .catchError(
                (e) => logDebug(
                  '[ChatConn] resolveEmotes failed for $channelName: $e',
                ),
              ),
        );
      }

      unawaited(_resolveSevenTvAndSubscribe(channelName, channelUserId));

      if (session.login == null && auth.accessToken != null) {
        final currentUser = await _ensureCurrentUser(auth);
        if (currentUser != null) {
          store.applyLogin(currentUser['login']);
          session.userId = currentUser['id'];
        }
      }

      if (session.login != null && session.userId != null) {
        eventSub.setChannelMapping(channelUserId, channelName);
        unawaited(_subscribeModeration(channelName, channelUserId));
        unawaited(_subscribeWidgets(channelName, channelUserId));
      }
    } catch (_) {
      logDebug('[ChatConn] subscribeChannel failed for $channelName');
    }
    onRebuild();
    fetchChatStatus(channelName);
    _chatStatusTimers[channelName]?.cancel();
    _chatStatusTimers[channelName] = Timer.periodic(
      const Duration(seconds: 60),
      (_) => fetchChatStatus(channelName),
    );
  }

  // Anonymous fallback for the channel user ID: ROOMSTATE carries a room-id
  // tag right after JOIN, which Helix normally provides. Waits (bounded) for
  // the ROOMSTATE if it hasn't arrived yet.
  final _roomIdWaiters = <String, List<Completer<String?>>>{};

  Future<String?> _waitForRoomId(
    String channel, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final existing = _roomStateTags[channel]?['room-id'];
    if (existing != null && existing.isNotEmpty) return existing;
    final completer = Completer<String?>();
    _roomIdWaiters.putIfAbsent(channel, () => []).add(completer);
    try {
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      _roomIdWaiters[channel]?.remove(completer);
      if (_roomIdWaiters[channel]?.isEmpty ?? true) {
        _roomIdWaiters.remove(channel);
      }
    }
  }

  Future<Map<String, dynamic>?>? _currentUserFetch;

  Future<Map<String, dynamic>?> _ensureCurrentUser(TwitchAuth auth) {
    return _currentUserFetch ??= twitchApi
        .getCurrentUser(auth)
        .then((user) {
          if (user != null) {
            auth.setUser(
              user['login'],
              user['id'],
              profileImageUrl: user['profile_image_url'],
            );
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
      if (!auth.isConfigured || session.userId == null) return;
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
            'moderator_user_id': session.userId!,
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
        logDebug(
          '[ChatConn] channel.moderate subscription failed for $channelName (${twitchApi.lastError ?? "unknown"})',
        );
        return;
      }
    } catch (_) {
      logDebug('[ChatConn] subscribeModeration failed for $channelName');
    }
  }

  // Hype train / poll / prediction widgets are broadcaster-only: the EventSub
  // subscription types require channel:read:hype_train/polls/predictions, which
  // Twitch only issues to the channel owner. Skip every other channel up front
  // so we don't fire a dozen doomed Helix calls per join.
  Future<void> _subscribeWidgets(
    String channelName,
    String channelUserId,
  ) async {
    try {
      final auth = twitchAuth;
      if (!auth.isConfigured || session.userId == null) return;
      if (session.userId != channelUserId) return;
      if (_widgetSkippedChannels.contains(channelName)) return;
      for (int attempt = 0; attempt < 3; attempt++) {
        final sessionId = eventSub.sessionId;
        if (sessionId == null) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        if (attempt > 0) await Future.delayed(const Duration(seconds: 1));
        const types = [
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
        ];
        var failed = false;
        for (final (type, version) in types) {
          final ok = await twitchApi.createEventSubSubscription(
            auth: auth,
            sessionId: sessionId,
            type: type,
            version: version,
            condition: {'broadcaster_user_id': channelUserId},
          );
          if (!ok) {
            if (twitchApi.lastErrorStatus == 403) {
              // Expected when the user isn't the broadcaster; skip silently.
              _widgetSkippedChannels.add(channelName);
            } else {
              logDebug(
                '[ChatConn] $type subscription failed for $channelName (${twitchApi.lastError ?? "unknown"})',
              );
            }
            failed = true;
            break;
          }
        }
        if (!failed) {
          _widgetChannels.add(channelName);
        }
        return;
      }
    } catch (_) {
      logDebug('[ChatConn] subscribeWidgets failed for $channelName');
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
    sevenTvClient!.subscribeTwitchChannel(twitchChannelId);
    logDebug(
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

  /// Re-creates the session-scoped EventSub subscriptions after a new session
  /// comes up (session_reconnect / keepalive reconnect). Skip sets and the
  /// already-subscribed sets are respected by the per-channel methods.
  void _resubscribeEventSubChannels() {
    final uid = session.userId;
    if (uid == null) return;
    for (final channel in channels) {
      final channelUserId = channelUserIds[channel];
      if (channelUserId == null) continue;
      if (!_moderationChannels.contains(channel)) {
        unawaited(_subscribeModeration(channel, channelUserId));
      }
      if (uid == channelUserId && !_widgetChannels.contains(channel)) {
        unawaited(_subscribeWidgets(channel, channelUserId));
      }
    }
  }

  Future<void> doSendMessage(
    String text,
    String channel, {
    TwitchMessage? replyTo,
  }) async {
    final auth = twitchAuth;
    final reply = replyTo ?? getReplyToMsg();

    // Local macro triggers expand before anything else: a macro may resolve
    // to a slash command or plain chat text alike.
    final macros = getMacros?.call();
    if (macros != null && macros.isNotEmpty) {
      final expanded = expandMacro(text, macros);
      if (expanded != null) {
        text = expanded;
        store.requestComposerFocus();
      }
    }

    if (text.startsWith('/')) {
      onCommand(text, channel, auth);
      store.requestComposerFocus();
      return;
    }

    if (isDisposed) return;
    setReplyToMsg(null);
    onRebuild();
    store.requestComposerFocus();

    final userLogin = session.login;
    if (userLogin == null) {
      store.notifyInfo('Connect an account to chat');
      return;
    }

    // Twitch rejects duplicate messages. Mirror DankChat: when the text equals
    // the last wire text we actually sent, toggle a trailing invisible-char
    // suffix on/off so consecutive sends differ on the wire yet look identical.
    // The suffix never accumulates.
    final wireText = bypassTextDuplicate(text, lastSentWireText[channel]);
    lastSentWireText[channel] = wireText;

    // Primary: send via IRC once the channel's JOIN is confirmed (ROOMSTATE
    // for that channel). isConnected alone only means the socket is up; right
    // after a (re)connect Twitch may not have processed the JOIN yet, and a
    // PRIVMSG sent in that window can be dropped with no error and no local
    // echo. Fall back to Helix until the channel is confirmed joined.
    _lastOwnMessageAt[channel] = DateTime.now();
    final canHelix = session.userId != null && auth.isConfigured;
    if (irc.isConnected && (_joinedChannels.contains(channel) || !canHelix)) {
      irc.sendMessage(
        channel,
        wireText,
        replyParentMessageId: reply?.messageId,
      );
    } else if (canHelix) {
      final broadcasterId =
          channelUserIds[channel] ?? await twitchApi.getUserId(auth, channel);
      if (broadcasterId != null) {
        final result = await twitchApi.sendChatMessage(
          auth,
          broadcasterId: broadcasterId,
          senderId: session.userId!,
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
    if (isDisposed) return;
    if (_isConnecting) {
      _connectRetryRequested = true;
      return;
    }
    _isConnecting = true;
    try {
      final auth = twitchAuth;

      _setupSubscriptions();

      sevenTvClient?.connect();

      // EventSub session lifecycle: subscriptions are session-scoped, so drop
      // moderation-channel state when the session dies (IRC fallback resumes)
      // and re-subscribe when a new session comes up (session_reconnect or
      // keepalive reconnect) - otherwise moderation and the broadcaster
      // widgets stay dead until the next IRC reconnect.
      statusSub?.cancel();
      statusSub = eventSub.onStatus.listen((status) {
        if (isDisposed) return;
        if (status == EventSubStatus.disconnected) {
          _moderationChannels.clear();
          _widgetChannels.clear();
        } else if (status == EventSubStatus.connected) {
          _resubscribeEventSubChannels();
        }
      });

      ircStatusSub?.cancel();
      ircStatusSub = irc.onStatus.listen((status) async {
        if (isDisposed) return;
        onRebuild();
        if (status == IrcConnectionStatus.connected && irc.isConnected) {
          // Edge-triggered: subscribeAll once per connect with 30s throttle.
          // The 500ms settle delay only applies on reconnect - the sockets
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
            // "Connected" is emitted before subscriptions are created - the
            // user sees it as soon as the socket is up, not after Helix calls.
            for (final channel in channels) {
              if (_connectedAcked.add(channel)) {
                onSystemMessage(channel, 'Connected');
              }
            }
            subscribeAll();
          }
        }
        if (status == IrcConnectionStatus.disconnected && !_wasDisconnected) {
          _wasDisconnected = true;
          _wasConnected = false;
          _connectedAcked.clear();
          _lastSubscribeAll = null;
          _joinedChannels.clear();
          // Failure state is per socket lifetime: the fresh socket runs its
          // own fast sweep, so it may legitimately fail (and re-announce)
          // again.
          _joinFailureNotified.clear();
          for (final channel in channels) {
            onSystemMessage(channel, 'Disconnected');
          }
        }
      });

      // The read-only socket reconnects independently of the write socket. A
      // read-socket outage alone (DNS failure, server move) would otherwise be
      // invisible: chat freezes with no "Disconnected" (the write socket is
      // still fine) and no recovery notice. Surface it as an explicit status.
      ircReadStatusSub?.cancel();
      ircReadStatusSub = ircRead.onStatus.listen((status) {
        if (isDisposed) return;
        if (status == IrcConnectionStatus.connected && _wasReadDisconnected) {
          _wasReadDisconnected = false;
          for (final channel in channels) {
            onSystemMessage(channel, 'Reconnected');
          }
        } else if (status == IrcConnectionStatus.disconnected &&
            !_wasReadDisconnected) {
          _wasReadDisconnected = true;
          for (final channel in channels) {
            onSystemMessage(channel, 'Chat reconnecting...');
          }
        }
      });

      ircAuthFailedSub?.cancel();
      ircAuthFailedSub = irc.onAuthFailed.listen((_) {
        if (isDisposed) return;
        _handleExpiredToken();
      });

      // Use the cached account if available so cold start skips the Helix
      // user lookup entirely.
      if (session.login == null && auth.login != null && auth.userId != null) {
        store.applyLogin(auth.login);
        session.userId = auth.userId;
      }

      // EventSub needs no credentials - connect it in parallel with the
      // current-user lookup. Only IRC needs the login, so the sockets wait
      // for the lookup but not for each other.
      var hasToken = auth.accessToken != null;

      // Validate the token on startup / credential change. Only HTTP 401
      // counts as definitively dead; network errors leave the token alone
      // so offline users aren't punished.
      if (hasToken && _lastValidatedToken != auth.accessToken) {
        try {
          final result = await twitchApi.validateToken(auth);
          if (result == null && twitchApi.lastErrorStatus == 401) {
            _handleExpiredToken();
            hasToken = false;
          }
          // Only update _lastValidatedToken on definitive outcomes (success
          // or 401). Network errors re-trigger validation next time.
          if (result != null || twitchApi.lastErrorStatus == 401) {
            _lastValidatedToken = auth.accessToken;
          }
        } catch (_) {
          // Network error - proceed normally.
        }
      }

      final eventSubFuture = hasToken
          ? eventSub.connect()
          : Future<void>.value();
      Future<Map<String, dynamic>?>? userFuture;
      if (session.login == null && hasToken) {
        userFuture = _ensureCurrentUser(auth);
      }

      Map<String, dynamic>? currentUser;
      if (userFuture != null) {
        try {
          currentUser = await userFuture;
        } catch (_) {
          logDebug('[ChatConn] getCurrentUser failed');
        }
      }
      if (currentUser != null) {
        store.applyLogin(currentUser['login']);
        session.userId = currentUser['id'];
      }

      // Account switch: an already-connected socket would skip the reconnect
      // and stay on the previous account. Tear the sockets down when the
      // desired account differs from what they were last told to use. Login
      // alone distinguishes accounts (the token always follows it); anonymous
      // mode is a distinct, stable state (null) so it doesn't flap.
      final desiredAnonymous = session.login == null || !hasToken;
      final desiredUsername = desiredAnonymous
          ? null
          : (session.login ?? auth.login)?.toLowerCase();
      final desiredToken = hasToken
          ? (auth.accessToken ?? 'anonymous')
          : 'anonymous';
      if (_lastIrcUsername != desiredUsername ||
          _lastIrcToken != desiredToken ||
          _lastIrcAnonymous != desiredAnonymous) {
        irc.disconnect(emitStatus: false);
        ircRead.disconnect(emitStatus: false);
        // 403 skip sets are account-scoped: a non-mod account's rejection
        // must not permanently disable moderation/widgets for a mod account
        // on the same channel after a switch.
        _moderationSkippedChannels.clear();
        _widgetSkippedChannels.clear();
      }

      if (session.login != null && hasToken) {
        try {
          await Future.wait([
            irc.connect(
              username: session.login!,
              accessToken: auth.accessToken!,
            ),
            ircRead.connect(
              username: session.login!,
              accessToken: auth.accessToken!,
            ),
          ]);
        } catch (e) {
          logDebug('IRC connect failed: $e');
        }
        _lastIrcUsername = session.login?.toLowerCase();
        _lastIrcToken = auth.accessToken;
        _lastIrcAnonymous = false;
      } else {
        // Read-only anonymous mode: Twitch accepts a justinfan NICK without
        // credentials, which still delivers chat (with the emotes tag) but
        // can't send messages or call Helix.
        try {
          await Future.wait([
            irc.connect(username: _anonymousNick(1), accessToken: 'anonymous'),
            ircRead.connect(
              username: _anonymousNick(2),
              accessToken: 'anonymous',
            ),
          ]);
        } catch (e) {
          logDebug('Anonymous IRC connect failed: $e');
        }
        _lastIrcUsername = null;
        _lastIrcToken = 'anonymous';
        _lastIrcAnonymous = true;
      }

      await eventSubFuture;
    } finally {
      _isConnecting = false;
      // A connect dropped by the re-entrancy guard (e.g. a login landing
      // while a startup connect is still in-flight) is re-run now that the
      // current connect finished, so the dropped credentials are honored
      // instead of the app staying on the previous (or anonymous) account
      // until a restart.
      if (!isDisposed && _connectRetryRequested) {
        _connectRetryRequested = false;
        unawaited(connect());
      }
    }
  }

  /// Central handler for an expired/dead access token. Marks the active
  /// account expired, broadcasts a message to every open channel, and
  /// signals the snackbar. Subsequent calls are no-ops until the
  /// credentials change (which resets [_expiryHandled]).
  void _handleExpiredToken() {
    if (_expiryHandled) return;
    _expiryHandled = true;
    twitchAuth.markActiveExpired();
    store.applyLogin(null);
    session.userId = null;
    for (final channel in channels) {
      onSystemMessage(
        channel,
        'Login expired - reconnect your account in Settings',
      );
    }
    store.notifyInfo('Login expired');
  }

  String _anonymousNick(int seed) {
    return 'justinfan${(DateTime.now().millisecondsSinceEpoch + seed) % 80000 + 1000}';
  }

  void _setupSubscriptions() {
    _ingestionSubs
      ..clear()
      ..addAll(_ingestion.attach());

    ircNoticeSub?.cancel();
    ircNoticeSub = irc.onNotice.listen((event) {
      if (isDisposed) return;
      // With channel.moderate active, room-state changes come from EventSub
      // with structured data - suppress the redundant IRC NOTICE.
      if (_moderationChannels.contains(event.channel) &&
          _roomStateNoticeIds.contains(event.msgId)) {
        return;
      }
      // A join-refusal notice for a channel we tried to join is already
      // surfaced by the onJoinFailed listener with clearer wording; showing
      // Twitch's raw copy too would duplicate the message. Refusals for
      // channels we are not joining still display normally.
      if (event.msgId == 'msg_channel_suspended' &&
          _joinFailureNotified.contains(event.channel)) {
        return;
      }
      onSystemMessage(event.channel, event.message);
    });

    ircJtvSub?.cancel();
    ircJtvSub = irc.onJtvMessage.listen((event) {
      if (isDisposed) return;
      onSystemMessage(event.channel, event.message);
    });

    // JOIN failures from the write socket (the one ROOMSTATE gates sends on):
    // suspended/deleted channels get an explicit refusal notice; everything
    // else surfaces after the fast rejoin sweep gave up. The base connection
    // keeps retrying either way, so the message says what happened and that
    // it keeps trying.
    ircJoinFailedSub?.cancel();
    ircJoinFailedSub = irc.onJoinFailed.listen((event) {
      if (isDisposed) return;
      final detail = switch (event.reason) {
        JoinFailureReason.suspended => 'the channel is suspended or deleted',
        JoinFailureReason.noResponse => 'the server never confirmed the join',
      };
      final suffix = event.reason == JoinFailureReason.noResponse
          ? ' Retrying.'
          : '';
      _joinFailureNotified.add(event.channel);
      onSystemMessage(
        event.channel,
        'Could not join #${event.channel}: $detail.$suffix',
      );
    });

    whisperSub?.cancel();
    whisperSub = irc.onWhisper.listen(onWhisperEvent);

    userNoticeSub?.cancel();
    userNoticeSub = irc.onUserNotice.listen((event) {
      if (isDisposed) return;
      final isAnnouncement = event.msgId == 'announcement';
      if (!isAnnouncement) {
        // Subscriptions / gift subs / watch streaks highlight like a default
        // (PRIMARY) purple announcement: the notice stays a system message
        // but carries the accent (DankChat-style). Other notices keep no
        // accent.
        final accent = subNoticeMsgIds.contains(event.msgId)
            ? announcementColors['PRIMARY']
            : null;
        onSystemMessage(
          event.channel,
          buildUserNoticeText(
            msgId: event.msgId,
            displayName: event.displayName,
            systemMsg: event.systemMsg,
          ),
          accent: accent,
        );
        // Sub/resub with a user message render like announcements: the notice
        // stays the label and the user's text becomes a child chat message so
        // emotes and badges render. The IRC `emotes` tag positions are
        // relative to that body text, so they pass through as-is.
        if ((event.msgId == 'sub' || event.msgId == 'resub') &&
            (event.text?.trim().isNotEmpty ?? false)) {
          onMessage(
            TwitchMessage(
              login: event.login,
              displayName: event.displayName,
              text: event.text!.trim(),
              color: event.color,
              userId: event.userId,
              badges: event.badges,
              emotePositions: event.emotePositions,
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

    ircRoomStateSub?.cancel();
    ircRoomStateSub = irc.onRoomState.listen((event) {
      if (isDisposed) return;
      // ROOMSTATE arrives after a successful JOIN, confirming this channel is
      // ready for PRIVMSG.
      _joinedChannels.add(event.channel);
      // A channel whose join previously failed (and announced "Retrying.")
      // just got in: announce the late success and clear the failure state.
      if (_joinFailureNotified.remove(event.channel)) {
        onSystemMessage(event.channel, 'Joined #${event.channel}.');
      }
      // ROOMSTATE updates are partial (only the changed tags): merge with
      // the previous state before recomposing the status splash.
      _roomStateTags[event.channel] = {
        ...?_roomStateTags[event.channel],
        ...event.tags,
      };
      final roomId = event.tags['room-id'];
      if (roomId != null && roomId.isNotEmpty) {
        final waiters = _roomIdWaiters.remove(event.channel);
        if (waiters != null) {
          for (final w in waiters) {
            if (!w.isCompleted) w.complete(roomId);
          }
        }
      }
      _composeChatStatus(event.channel);
    });

    emoteSetsSub?.cancel();
    emoteSetsSub = irc.onUserEmoteSets.listen((event) {
      if (isDisposed || onUserEmoteSets == null) return;
      final (channel, ids) = event;
      unawaited(onUserEmoteSets!(channel, ids));
    });

    moderationSub ??= eventSub.onModeration.listen(_onModerationEvent);

    hypeTrainSub ??= eventSub.onHypeTrain.listen((event) {
      if (isDisposed) return;
      if (!_widgetChannels.contains(event.channel)) return;
      onHypeTrain?.call(event);
    });
    pollSub ??= eventSub.onPoll.listen((event) {
      if (isDisposed) return;
      if (!_widgetChannels.contains(event.channel)) return;
      onPoll?.call(event);
    });
    predictionSub ??= eventSub.onPrediction.listen((event) {
      if (isDisposed) return;
      if (!_widgetChannels.contains(event.channel)) return;
      onPrediction?.call(event);
    });

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
    final selfLogin = session.login?.toLowerCase();
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
              store.messageMutated(event.channel, m.messageId);
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
        store.touchChannel(event.channel);
        onSystemMessage(event.channel, '$mod cleared the chat.');
        break;
      case 'ban':
      case 'timeout':
        onAnalyticsModeration?.call(event.channel, event.action == 'timeout');
        if (target != null) {
          store.markUserMessagesDeleted(event.channel, target);
        }
        final duration = event.durationSeconds != null
            ? ' for ${event.durationSeconds}s'
            : '';
        if (isSelfTarget &&
            event.action == 'timeout' &&
            event.durationSeconds != null) {
          _selfTimeoutUntil[event.channel] = DateTime.now().add(
            Duration(seconds: event.durationSeconds!),
          );
        }
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
        if (isSelfTarget) _selfTimeoutUntil.remove(event.channel);
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

  // Chat-content routing lives in [ChatIngestion]; kept as delegators so
  // the USERNOTICE path and tests can feed synthetic messages through the
  // same policy gates.
  void onMessage(TwitchMessage msg) => _ingestion.onMessage(msg);

  void onOwnIrcMessage(IrcMessage ircMsg) => _ingestion.onOwnIrcMessage(ircMsg);

  void precacheMessageEmotes(TwitchMessage msg, String channel) =>
      _ingestion.precacheMessageEmotes(msg, channel);

  void onWhisperEvent(TwitchMessage msg) {
    if (isDisposed) return;
    if (!msg.isSystem && isBlocked?.call(msg.login) == true) return;
    // Ignored users' whispers are dropped like their channel messages.
    if (!msg.isSystem && ignoreManager?.isIgnored(msg.login) == true) return;
    onWhisper?.call(msg);
  }

  /// Brute-force teardown + reconnect of every socket (manual "Reconnect"
  /// button). Unlike [reconnectIfNecessary], it never checks liveness - it
  /// always disconnects and re-establishes the IRC/EventSub/7TV connections.
  void forceReconnect() {
    irc.forceReconnect();
    ircRead.forceReconnect();
    unawaited(eventSub.forceReconnect());
    unawaited(sevenTvClient?.forceReconnect());
  }

  void reconnectIfNecessary() {
    final login = session.login;
    final token = twitchAuth.accessToken;
    final anonymous = login == null || token == null;
    final username = login ?? _anonymousNick(1);
    final accessToken = token ?? 'anonymous';

    // A socket can exist while being dead (frozen by the OS during
    // backgrounding). When it looks connected, verify with a PING/PONG
    // round-trip instead of trusting isConnected; force a reconnect if the
    // PONG never comes back.
    if (irc.isConnected) {
      unawaited(
        irc.checkAlive().then((alive) {
          if (!alive) {
            logDebug('[ChatConn] IRC zombie detected - forcing reconnect');
            irc.forceReconnect();
          }
        }),
      );
    } else {
      unawaited(irc.connect(username: username, accessToken: accessToken));
    }
    if (ircRead.isConnected) {
      unawaited(
        ircRead.checkAlive().then((alive) {
          if (!alive) {
            logDebug('[ChatConn] IRC read zombie detected - forcing reconnect');
            ircRead.forceReconnect();
          }
        }),
      );
    } else {
      unawaited(
        ircRead.connect(
          username: anonymous ? _anonymousNick(2) : username,
          accessToken: accessToken,
        ),
      );
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
