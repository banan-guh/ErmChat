import 'dart:async';
import 'package:flutter/widgets.dart';
import '../models/generic_emote.dart';
import '../util/duration_format.dart';
import '../util/log.dart';
import '../models/twitch_message.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_eventsub.dart';
import '../services/twitch_irc.dart';
import '../services/emote_manager.dart';
import '../services/base_irc_connection.dart' show IrcSocketRole;
import '../services/join_rate_limiter.dart';
import '../services/emote_providers/seven_tv_emotes.dart';
import '../services/seven_tv_event_client.dart';
import '../services/twitch_badge_service.dart';
import '../services/user_store.dart';
import '../services/command_macros.dart';
import '../services/ping_manager.dart';
import '../services/ignore_manager.dart';
import '../services/chat_ingestion.dart';
import '../services/chat_channel_setup.dart';
import '../services/chat_store.dart';
import '../util/text_bypass.dart';

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
    this.joinBudget,
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

  /// The shared JOIN budget both sockets were wired with; null disables
  /// join-progress surfacing.
  final JoinRateLimiter? joinBudget;
}

/// Per-channel join-queue progress: the channel's position in the shared
/// JOIN FIFO and an estimated seconds-to-send. Null info means the wait is
/// over (confirmed, sent, or dropped) and any countdown line should go.
class JoinProgress {
  const JoinProgress(this.position, this.etaSeconds);
  final int position;
  final int etaSeconds;
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
    this.onJoinProgress,
  });

  final String mentionsChannel;
  final VoidCallback onRebuild;
  final void Function(String, String, {Color? accent, String? messageId})
  onSystemMessage;
  final String? Function() getSelectedChannel;
  final int Function() getMaxMessagesPerChannel;
  final void Function(String channel, JoinProgress? info)? onJoinProgress;
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
  final List<String> channels;
  final Set<String> historyLoaded;
  final Map<String, String> channelUserIds;
  final Map<String, String> lastSentWireText;
  final String mentionsChannel;
  final VoidCallback onRebuild;
  final void Function(String, String, {Color? accent, String? messageId})
  onSystemMessage;
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
  final JoinRateLimiter? joinBudget;
  final void Function(String channel, JoinProgress? info)? onJoinProgress;

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
  // Channels currently showing a join-countdown line; drives the clear emit
  // when the wait ends or the socket drops.
  final _joinWaitShown = <String>{};
  Timer? _joinProgressTimer;
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
    isModerationActive: (channel) => _channelSetup.isModerationActive(channel),
    onSelfTimeoutArmed: (channel, until) {
      _selfTimeoutUntil[channel] = until;
    },
    onSystemMessage: onSystemMessage,
    onAnalyticsMessage: onAnalyticsMessage,
    onAnalyticsModeration: onAnalyticsModeration,
    onChatMessage: onChatMessage,
    onMention: (channel, msg) => onMention?.call(channel, msg),
  );

  // Channel-domain wiring (joins, Helix/emote/badge resolution, EventSub
  // moderation + widget subscriptions, status composition).
  late final ChatChannelSetup _channelSetup = ChatChannelSetup(
    twitchApi: twitchApi,
    eventSub: eventSub,
    irc: irc,
    ircRead: ircRead,
    sevenTvClient: sevenTvClient,
    badgeService: badgeService,
    emoteManager: emoteManager,
    twitchAuth: twitchAuth,
    userStore: userStore,
    store: store,
    onSystemMessage: onSystemMessage,
    onRebuild: onRebuild,
    onUserEmoteSets: onUserEmoteSets,
    ensureCurrentUser: _ensureCurrentUser,
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
      channels = config.store.channels,
      historyLoaded = config.store.historyLoaded,
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
      onChatMessage = config.sinks.onChatMessage,
      joinBudget = config.services.joinBudget,
      onJoinProgress = config.bridge.onJoinProgress;

  void dispose() {
    isDisposed = true;
    _joinProgressTimer?.cancel();
    _joinProgressTimer = null;
    for (final sub in _ingestionSubs) {
      sub.cancel();
    }
    _ingestionSubs.clear();
    _ingestion.dispose();
    _channelSetup.dispose();
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
  }

  void stopChatStatusTimer(String channel) {
    _channelSetup.stopChatStatusTimer(channel);
    irc.selfBadges.remove(channel);
  }

  void maybeAddConnected(String channel) {
    if (irc.isConnected &&
        historyLoaded.contains(channel) &&
        _connectedAcked.add(channel)) {
      onSystemMessage(channel, 'Connected');
    }
  }

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
  int slowModeSeconds(String channel) => _channelSetup.slowModeSeconds(channel);

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

  Future<void> subscribeChannel(String channelName) =>
      _channelSetup.subscribeChannel(channelName);

  void subscribeAll() => _channelSetup.subscribeAll(channels);

  Future<Map<String, dynamic>?>? _currentUserFetch;

  Future<Map<String, dynamic>?> _ensureCurrentUser(TwitchAuth auth) {
    return _currentUserFetch ??= () {
      // Attribute the resolution to the credential it was made with so a
      // late result landing after an account switch is discarded (setUser).
      final tokenAtStart = auth.accessToken;
      return twitchApi
          .getCurrentUser(auth)
          .then((user) {
            if (user != null) {
              auth.setUser(
                user['login'],
                user['id'],
                profileImageUrl: user['profile_image_url'],
                resolvedWithToken: tokenAtStart,
              );
            }
            return user;
          })
          .whenComplete(() => _currentUserFetch = null);
    }();
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
      try {
        final broadcasterId =
            channelUserIds[channel] ?? await twitchApi.getUserId(auth, channel);
        if (broadcasterId == null) {
          onSystemMessage(
            channel,
            twitchApi.lastError ?? "Couldn't resolve the channel; try again",
          );
          return;
        }
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
      } catch (e) {
        // Network-level failures escape TwitchApi's HTTP-to-null conversion;
        // without this the message vanishes with an unhandled zone error.
        logDebug('Helix send fallback failed: $e');
        onSystemMessage(channel, 'Message failed to send');
      }
    }
  }

  /// Retires the channel's countdown line (if shown) via a null progress
  /// emit, so the UI removes the row.
  void _clearJoinWait(String channel) {
    if (!_joinWaitShown.remove(channel)) return;
    onJoinProgress?.call(channel, null);
  }

  /// Whether [channel]'s JOIN is confirmed on the write socket - the point
  /// at which a PRIVMSG actually lands there. Drives the chat input gate:
  /// between socket-connect and join-confirm, sends would vanish.
  bool isChannelChatReady(String channel) => _joinedChannels.contains(channel);

  /// Emits per-channel join-queue progress once per second while any write
  /// socket JOIN is still waiting in the shared budget: position plus an ETA
  /// derived from the bucket's refill rate. Channels that left the queue but
  /// have not confirmed yet get their countdown cleared (the ROOMSTATE
  /// "Connected" lands moments later).
  void _tickJoinProgress() {
    final budget = joinBudget;
    if (budget == null || isDisposed) return;
    final pending = budget.pendingFor(IrcSocketRole.write);
    final pendingByChannel = <String, int>{
      for (final entry in pending) entry.channel: entry.position,
    };
    for (final channel in channels) {
      final position = pendingByChannel[channel];
      if (position != null && !_joinedChannels.contains(channel)) {
        _joinWaitShown.add(channel);
        onJoinProgress?.call(
          channel,
          JoinProgress(position, budget.etaSecondsForPosition(position)),
        );
      } else {
        _clearJoinWait(channel);
      }
    }
  }

  /// Starts the one-second progress ticker for the manager's lifetime. It
  /// idles cheaply when nothing is queued; mid-session channel joins must
  /// surface too, so it never stops until [dispose].
  void _ensureJoinProgressTicker() {
    if (_joinProgressTimer != null || joinBudget == null || isDisposed) {
      return;
    }
    _joinProgressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _tickJoinProgress();
    });
    // First snapshot immediately so a cold start shows positions at once.
    _tickJoinProgress();
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
      _ensureJoinProgressTicker();

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
          _channelSetup.clearSessionState();
        } else if (status == EventSubStatus.connected) {
          _channelSetup.resubscribeEventSubChannels(channels);
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
            // Per-channel "Connected" now waits for that channel's own JOIN
            // confirmation (see the ROOMSTATE listener) - a socket being up
            // says nothing about whether the channel can receive PRIVMSG.
            subscribeAll();
          }
        }
        if (status == IrcConnectionStatus.disconnected && !_wasDisconnected) {
          _wasDisconnected = true;
          _wasConnected = false;
          _connectedAcked.clear();
          _lastSubscribeAll = null;
          _joinedChannels.clear();
          for (final channel in List.of(_joinWaitShown)) {
            _clearJoinWait(channel);
          }
          // Failure state is per socket lifetime: the fresh socket runs its
          // own fast sweep, so it may legitimately fail (and re-announce)
          // again.
          _channelSetup.resetJoinFailureState();
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

      // Account-switch fast path (runs before any await): a different account
      // was requested while the previous session's socket may still be up.
      // Drop its JOIN confirmations immediately so sends fall back to Helix
      // under the new credentials instead of riding the old account's socket
      // while this connect() is still validating.
      final pendingUsername = (session.login ?? auth.login)?.toLowerCase();
      final hadPreviousSession =
          _lastIrcUsername != null || _lastIrcToken != null;
      if (hadPreviousSession &&
          pendingUsername != null &&
          pendingUsername != _lastIrcUsername) {
        _joinedChannels.clear();
      }

      // EventSub needs no credentials - connect it in parallel with the
      // current-user lookup. Only IRC needs the login, so the sockets wait
      // for the lookup but not for each other.
      var hasToken = auth.accessToken != null;

      // Validate the token on startup / credential change, off the critical
      // path: the IRC sockets below must not wait an HTTPS round trip for
      // this answer before joining. Only HTTP 401 counts as definitively
      // dead; network errors leave the token alone so offline users aren't
      // punished. A dead token flips to anonymous via _handleExpiredToken's
      // listener chain (notifyListeners -> connect rerun) or the IRC
      // login-failure NOTICE.
      final validatedToken = auth.accessToken;
      if (hasToken && _lastValidatedToken != validatedToken) {
        unawaited(() async {
          try {
            final result = await twitchApi.validateToken(auth);
            if (result == null && twitchApi.lastErrorStatus == 401) {
              // Attribute the verdict to the credential being validated: if
              // the active account changed while the request was in flight,
              // the 401 says nothing about the new token.
              if (auth.accessToken == validatedToken) {
                _handleExpiredToken();
              }
            }
            // Only update _lastValidatedToken on definitive outcomes (success
            // or 401). Network errors re-trigger validation next time.
            if (result != null || twitchApi.lastErrorStatus == 401) {
              _lastValidatedToken = validatedToken;
            }
          } catch (_) {
            // Network error - proceed normally.
          }
        }());
      }

      final Future<void> eventSubFuture;
      if (hasToken) {
        // Replacing an existing EventSub session (account switch / re-auth):
        // its subscriptions are session-scoped and die with the socket, but
        // connect() suppresses the disconnected status that normally drops
        // this state. Clear it here so the new session's connected edge
        // resubscribes every channel instead of skipping "already
        // subscribed" ones.
        _channelSetup.clearSessionState();
        eventSubFuture = eventSub.connect();
      } else {
        // Leaving authenticated mode: any live EventSub session belongs to
        // the departed account and would keep delivering moderation/widget
        // events. disconnect() emits status, which clears session-scoped
        // state via the listener below.
        if (eventSub.sessionId != null || eventSub.isConnected) {
          eventSub.disconnect();
        }
        eventSubFuture = Future<void>.value();
      }
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
        _channelSetup.resetAccountScope();
        _channelSetup.resetJoinFailureState();
        // New credentials re-arm expiry handling; without this a second dead
        // token after a mid-session re-auth would fail silently forever.
        _expiryHandled = false;
        // The suppressed disconnect skips the status-listener cleanup, so the
        // switch drops per-session/per-account state here explicitly: old
        // JOIN confirmations must not gate sends, self badges and slow-mode/
        // timeout anchors belong to the old account, and duplicate-bypass
        // wire text must not carry across accounts.
        _joinedChannels.clear();
        _connectedAcked.clear();
        _lastSubscribeAll = null;
        irc.clearSelfBadges();
        _selfTimeoutUntil.clear();
        _lastOwnMessageAt.clear();
        store.lastSentWireText.clear();
        // Make the new socket take the full connect edge (history backfill,
        // Helix re-subscriptions, Connected lines) even though no user-facing
        // disconnected status was emitted for this deliberate swap. Only for
        // an established prior session: a virgin cold start must keep its
        // ordinary first-connect semantics (no backfill, no reconnect).
        if (_lastIrcToken != null) {
          _wasConnected = false;
          _wasDisconnected = true;
        }
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
    // connect() re-runs on every auth change; dropping the old subscriptions
    // without cancelling them would leave every IRC event handled N times.
    for (final sub in _ingestionSubs) {
      sub.cancel();
    }
    _ingestionSubs
      ..clear()
      ..addAll(_ingestion.attach());

    ircNoticeSub?.cancel();
    ircNoticeSub = irc.onNotice.listen((event) {
      if (isDisposed) return;
      // With channel.moderate active, room-state changes come from EventSub
      // with structured data - suppress the redundant IRC NOTICE.
      if (_channelSetup.isModerationActive(event.channel) &&
          _roomStateNoticeIds.contains(event.msgId)) {
        return;
      }
      // A join-refusal notice for a channel we tried to join is already
      // surfaced by the onJoinFailed listener with clearer wording; showing
      // Twitch's raw copy too would duplicate the message. Refusals for
      // channels we are not joining still display normally.
      if (event.msgId == 'msg_channel_suspended' &&
          _channelSetup.isJoinFailureNotified(event.channel)) {
        return;
      }
      onSystemMessage(event.channel, event.message);
    });

    ircJtvSub?.cancel();
    ircJtvSub = irc.onJtvMessage.listen((event) {
      if (isDisposed) return;
      onSystemMessage(event.channel, event.message);
    });

    // JOIN failures from the write socket are handled by the setup domain,
    // which also tracks the notified set for the NOTICE suppression above.
    ircJoinFailedSub?.cancel();
    ircJoinFailedSub = irc.onJoinFailed.listen(_channelSetup.handleJoinFailed);

    whisperSub?.cancel();
    whisperSub = irc.onWhisper.listen(onWhisperEvent);

    userNoticeSub?.cancel();
    userNoticeSub = irc.onUserNotice.listen((event) {
      if (isDisposed) return;
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
      // ready for PRIVMSG; record it so sends gate on the confirmed join.
      if (_channelSetup.handleRoomState(event)) {
        final isNewlyConfirmed = _joinedChannels.add(event.channel);
        // The channel can actually receive messages now: retire any countdown
        // and post the honest per-channel "Connected". The input gate keys
        // off this flip too, so rebuild the frame.
        if (isNewlyConfirmed) {
          _clearJoinWait(event.channel);
          if (_connectedAcked.add(event.channel)) {
            onSystemMessage(event.channel, 'Connected');
          }
          onRebuild();
        }
      }
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
      if (!_channelSetup.isWidgetActive(event.channel)) return;
      onHypeTrain?.call(event);
    });
    pollSub ??= eventSub.onPoll.listen((event) {
      if (isDisposed) return;
      if (!_channelSetup.isWidgetActive(event.channel)) return;
      onPoll?.call(event);
    });
    predictionSub ??= eventSub.onPrediction.listen((event) {
      if (isDisposed) return;
      if (!_channelSetup.isWidgetActive(event.channel)) return;
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
    if (!_channelSetup.isModerationActive(event.channel)) return;

    final mod = event.moderatorName;
    final target = event.targetName;
    final selfLogin = session.login?.toLowerCase();
    final isSelfTarget =
        target != null &&
        selfLogin != null &&
        target.toLowerCase() == selfLogin;

    switch (event.action) {
      case 'delete':
        if (event.messageId != null) {
          store.markMessageDeleted(event.channel, event.messageId!);
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
        store.markAllMessagesDeleted(event.channel);
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
            ? ' for ${formatSeconds(event.durationSeconds!)}'
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
