import 'dart:async';
import 'package:flutter/widgets.dart';
import '../util/log.dart';
import '../models/twitch_message.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_oauth.dart';
import '../eventsub/decode/decoder.dart';
import '../eventsub/decode/events.dart';
import '../eventsub/topics.dart';
import '../eventsub/transport/connection.dart';
import '../eventsub/transport/events.dart';
import '../irc/decode/copy.dart'
    show buildUserNoticeText, userNoticeAccent, userNoticeLabelId;
import '../irc/decode/decoder.dart' show IrcChatDecoder;
import '../irc/decode/events.dart'
    show IrcNoticeEvent, IrcRoomStateEvent, UserNoticeEvent;
import '../irc/message.dart' show IrcMessage;
import '../irc/transport/events.dart'
    show IrcConnectionStatus, IrcJoinFailureEvent;
import '../irc/transport/read.dart' show IrcReadService;
import '../irc/transport/write.dart' show IrcService;
import '../services/emote_manager.dart';
import '../services/join_rate_limiter.dart';
import '../services/seven_tv_event_client.dart';
import '../services/twitch_badge_service.dart';
import '../services/user_store.dart';
import '../services/ping_manager.dart';
import '../services/ignore_manager.dart';
import '../services/chat_ingestion.dart';
import '../services/chat_channel_setup.dart';
import '../services/chat_sender.dart';
import '../services/eventsub_consumer.dart';
import '../services/seven_tv_consumer.dart';
import '../services/join_progress_tracker.dart';
import '../services/chat_readiness.dart';
import '../chat/chat.dart';
import '../client/session.dart';

export '../services/join_progress_tracker.dart' show JoinProgress;

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

/// Coarse connect phase for UI copy. Single source of truth for anything
/// that needs to distinguish "never connected", "lost connection" and "up":
/// the input hint consumes this instead of owning its own connect flags.
enum ChatPhase { connecting, reconnecting, online }

/// Rendering and interaction signals flowing manager -> UI: buffer change
/// notifications, system messages, focus and snackbar requests, plus reads
/// of view-owned state the pipeline needs (selected channel, message cap).
class ChatViewBridge {
  ChatViewBridge({
    required this.mentionsChannel,
    required this.onSystemMessage,
    required this.getSelectedChannel,
    required this.getMaxMessagesPerChannel,
    this.onJoinProgress,
    this.onBanner,
    this.onFocusComposer,
  });

  final String mentionsChannel;
  final void Function(String, String, {Color? accent, String? messageId})
  onSystemMessage;
  final String? Function() getSelectedChannel;
  final int Function() getMaxMessagesPerChannel;
  final void Function(String channel, JoinProgress? info)? onJoinProgress;
  final void Function(String message)? onBanner;
  final void Function()? onFocusComposer;
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
    required this.chat,
    required this.session,
    required this.bridge,
    required this.sinks,
  });

  final ChatServices services;
  final Chat chat;
  final Session session;
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
  final Session session;
  final Chat chat;
  final String mentionsChannel;

  /// Bumped on connection-phase / channel-ready / reply-clear changes so the
  /// composer can rebuild without forcing a full HomeScreen setState.
  final ValueNotifier<int> connectionStateNotifier = ValueNotifier(0);

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
  final void Function(String message)? onBanner;
  final void Function()? onFocusComposer;

  bool _wasConnected = false;
  bool _wasDisconnected = false;
  // Guards the one-shot read-connect waiter below: connect() re-runs on
  // every auth change, and each call must not stack another broadcast
  // listener while the read socket stays down.
  bool _readConnectWaiterArmed = false;
  DateTime? _lastSubscribeAll;
  // Credentials the IRC sockets were last told to use. Compared against the
  // desired account on connect() so an account switch tears the sockets down
  // (an already-connected socket otherwise skips the reconnect).
  String? _lastIrcUsername;
  String? _lastIrcToken;
  StreamSubscription<IrcRoomStateEvent>? ircReadRoomStateSub;
  StreamSubscription<IrcRoomStateEvent>? ircWriteRoomStateSub;

  /// Whether the read socket participates in readiness gating: yes for
  /// authenticated sessions (both sockets are part of the deal from the
  /// start, including their handshake windows), no for anonymous read-only
  /// sessions where there is nothing to echo.
  bool get _readExpected => !_lastIrcAnonymous;
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

  // Decode layer: lifts typed events out of each socket's raw frames. The
  // read decoder watches own echoes via the read socket's nick.
  late final IrcChatDecoder readDecoder = IrcChatDecoder(
    ircRead.onIrcMessage,
    nickProvider: () => ircRead.username,
    debugPrefix: 'IRC read',
    isReadSocket: true,
  );
  late final IrcChatDecoder writeDecoder = IrcChatDecoder(
    irc.onIrcMessage,
    debugPrefix: 'IRC',
    isReadSocket: false,
  );

  // EventSub decode layer: lifts typed events out of notification frames.
  late final EventSubDecoder eventSubDecoder = EventSubDecoder(
    eventSub.onNotification,
  );

  // Outbound send path and its send gates.
  late final ChatSender _sender = ChatSender(
    irc: irc,
    session: session,
    twitchAuth: twitchAuth,
    onCommand: onCommand,
    getReplyToMsg: getReplyToMsg,
    setReplyToMsg: setReplyToMsg,
    onSystemMessage: (channel, text) => onSystemMessage(channel, text),
    slowModeSeconds: (channel) => _channelSetup.slowModeSeconds(channel),
    selfBadges: (channel) =>
        readDecoder.selfBadges[channel] ??
        readDecoder.selfBadges[null] ??
        const <String>{},
    getMacros: getMacros,
    onBanner: onBanner,
    onFocusComposer: onFocusComposer,
    onSendStateChanged: () => connectionStateNotifier.value++,
  );

  // EventSub subscription lifecycle: active/skip sets, subscribe paths,
  // resubscribe, and the gate predicates.
  late final EventSubTopics eventSubTopics = EventSubTopics(
    twitchApi: twitchApi,
    twitchAuth: twitchAuth,
    session: session,
    chat: chat,
    eventSub: eventSub,
  );

  // EventSub consumption: typed decoder events applied to the chat kernel.
  late final EventSubConsumer eventSubConsumer = EventSubConsumer(
    chat: chat,
    session: session,
    topics: eventSubTopics,
    onSystemMessage: onSystemMessage,
    onAnalyticsModeration: onAnalyticsModeration,
    onHypeTrain: onHypeTrain,
    onPoll: onPoll,
    onPrediction: onPrediction,
    onSelfTimeoutArmed: _sender.armTimeout,
    onSelfTimeoutCleared: _sender.clearTimeout,
  );

  // 7TV event consumption: socket events applied to the emote manager.
  late final SevenTvConsumer _sevenTvConsumer = SevenTvConsumer(
    emoteManager: emoteManager,
    sevenTvClient: sevenTvClient,
    onSystemMessage: onSystemMessage,
  );

  // Join-confirmation and read-socket-health state behind the readiness
  // queries.
  late final ChatReadiness _readiness = ChatReadiness(
    writeConnected: () => irc.isConnected,
    readConnected: () => ircRead.isConnected,
    readExpected: () => _readExpected,
  );

  // Join-queue progress surfaced to the UI while channels wait in the budget.
  late final JoinProgressTracker _joinProgress = JoinProgressTracker(
    joinBudget: joinBudget,
    channelNames: () => chat.names,
    isReady: isChannelChatReady,
    isFailed: (channel) => _readiness.isJoinFailed(channel),
    onProgress: (channel, info) => onJoinProgress?.call(channel, info),
  );

  // Chat-content routing (PRIVMSG/CLEARMSG/CLEARCHAT/clears/own echo).
  late final ChatIngestion _ingestion = ChatIngestion(
    irc: irc,
    ircRead: ircRead,
    readDecoder: readDecoder,
    chat: chat,
    session: session,
    userStore: userStore,
    emoteManager: emoteManager,
    badgeService: badgeService,
    twitchAuth: twitchAuth,
    sender: _sender,
    ignoreManager: ignoreManager,
    pingManager: pingManager,
    mentionsChannel: mentionsChannel,
    getMaxMessagesPerChannel: getMaxMessagesPerChannel,
    getSelectedChannel: getSelectedChannel,
    isChatReady: isChatReady,
    isBlocked: isBlocked,
    getSharedChatMode: getSharedChatMode,
    isModerationActive: (channel) => eventSubTopics.isModerationActive(channel),
    onSystemMessage: onSystemMessage,
    onAnalyticsMessage: onAnalyticsMessage,
    onAnalyticsModeration: onAnalyticsModeration,
    onChatMessage: onChatMessage,
    onMention: (channel, msg) => onMention?.call(channel, msg),
  );

  // Channel-domain wiring (joins, Helix/emote/badge resolution, EventSub
  // topic subscriptions, status composition).
  late final ChatChannelSetup _channelSetup = ChatChannelSetup(
    twitchApi: twitchApi,
    eventSubDecoder: eventSubDecoder,
    eventSubTopics: eventSubTopics,
    irc: irc,
    ircRead: ircRead,
    sevenTvClient: sevenTvClient,
    badgeService: badgeService,
    emoteManager: emoteManager,
    twitchAuth: twitchAuth,
    userStore: userStore,
    chat: chat,
    session: session,
    onSystemMessage: onSystemMessage,
    connectionStateNotifier: connectionStateNotifier,
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
  StreamSubscription<(String?, List<String>)>? emoteSetsSub;
  StreamSubscription<IrcConnectionStatus>? ircStatusSub;
  StreamSubscription<IrcConnectionStatus>? ircReadStatusSub;
  StreamSubscription<void>? ircAuthFailedSub;
  StreamSubscription<void>? ircReadAuthFailedSub;
  StreamSubscription<IrcNoticeEvent>? ircWriteNoticeSub;
  Timer? _watchdogTimer;

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
      session = config.session,
      chat = config.chat,
      mentionsChannel = config.bridge.mentionsChannel,
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
      onJoinProgress = config.bridge.onJoinProgress,
      onBanner = config.bridge.onBanner,
      onFocusComposer = config.bridge.onFocusComposer;

  void dispose() {
    isDisposed = true;
    _joinProgress.dispose();
    // This manager owned the session's join demand; drop its queued units so
    // the shared bucket's pump timer can wind down instead of ticking on
    // dead sockets forever.
    joinBudget?.clear();
    for (final sub in _ingestionSubs) {
      sub.cancel();
    }
    _ingestionSubs.clear();
    _ingestion.dispose();
    _channelSetup.dispose();
    _sender.dispose();
    readDecoder.dispose();
    writeDecoder.dispose();
    eventSubConsumer.dispose();
    _sevenTvConsumer.dispose();
    eventSubDecoder.dispose();
    statusSub?.cancel();
    ircNoticeSub?.cancel();
    ircJtvSub?.cancel();
    ircJoinFailedSub?.cancel();
    emoteSetsSub?.cancel();
    ircStatusSub?.cancel();
    ircReadStatusSub?.cancel();
    ircReadRoomStateSub?.cancel();
    ircWriteRoomStateSub?.cancel();
    ircAuthFailedSub?.cancel();
    userNoticeSub?.cancel();
    ircReadAuthFailedSub?.cancel();
    ircWriteNoticeSub?.cancel();
    whisperSub?.cancel();
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    connectionStateNotifier.dispose();
  }

  void stopChatStatusTimer(String channel) {
    _channelSetup.stopChatStatusTimer(channel);
    readDecoder.selfBadges.remove(channel);
  }

  /// Drops per-channel subscription state (channel left); the next join
  /// re-subscribes from scratch.
  void forgetChannel(String channel) {
    _sender.forgetChannel(channel);
    _channelSetup.forgetChannel(channel);
  }

  /// Outbound send owner. Exposed for tests and for callers that need the
  /// send verbs without going through the manager's delegators.
  @visibleForTesting
  ChatSender get sender => _sender;

  void maybeAddConnected(String channel) {
    if (irc.isConnected &&
        (chat.channelFor(channel)?.info.historyLoaded ?? false) &&
        _readiness.acknowledgeConnected(channel)) {
      onSystemMessage(channel, 'Connected');
    }
  }

  /// Seconds of the channel's current slow mode from the merged ROOMSTATE
  /// tags; 0 when off (missing/empty/0 all mean off).
  int slowModeSeconds(String channel) => _channelSetup.slowModeSeconds(channel);

  /// Whether event-driven moderation (and its Mod View rows) is up.
  bool isModerationActive(String channel) =>
      eventSubTopics.isModerationActive(channel);

  /// Whether the AutoMod queue subscriptions are up.
  bool isAutomodActive(String channel) =>
      eventSubTopics.isAutomodActive(channel);

  /// Whether the session user owns [channel] (Channel tab gate).
  bool isBroadcaster(String channel) => eventSubTopics.isBroadcaster(channel);

  /// Merged ROOMSTATE tags for the mode toggles.
  Map<String, String> roomStateTags(String channel) =>
      _channelSetup.roomStateTags(channel);

  /// Seconds left on your timeout in [channel], null when none is active.
  int? remainingSelfTimeout(String channel) =>
      _sender.remainingSelfTimeout(channel);

  /// Seconds left before you may send again in [channel] under slow mode,
  /// null when none is active.
  int? remainingSlowCooldown(String channel) =>
      _sender.remainingSlowCooldown(channel);

  Future<void> subscribeChannel(String channelName) async {
    // Clear stale readiness so a re-subscribe re-earns its JOIN confirm.
    _readiness.forgetChannel(channelName);
    connectionStateNotifier.value++;
    await _channelSetup.subscribeChannel(channelName);
  }

  void subscribeAll() => _channelSetup.subscribeAll(chat.names);

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

  Future<void> doSendMessage(
    String text,
    String channel, {
    TwitchMessage? replyTo,
  }) => _sender.send(text, channel, replyTo: replyTo);

  /// Whether both IRC sockets are up. The write socket alone can deliver a
  /// PRIVMSG, but without the read socket the local echo has no ride. The
  /// read side only counts once it has connected at least once this session,
  /// so environments without a read socket keep working.
  bool get isChatPipeConnected => _readiness.pipeUp;

  /// [ChatPhase] for the current session: connecting on a first boot,
  /// reconnecting after any successful connect dropped, online otherwise.
  /// Per-channel readiness ([isChannelChatReady]) layers on top in the view.
  ChatPhase get connectPhase {
    if (!_readiness.pipeUp) {
      return _readiness.everConnected
          ? ChatPhase.reconnecting
          : ChatPhase.connecting;
    }
    return ChatPhase.online;
  }

  /// Whether [channel]'s JOIN is confirmed on every participating socket -
  /// the point at which a PRIVMSG lands AND echoes back locally. Drives the
  /// chat input gate: between socket-connect and join-confirm, sends would
  /// vanish. The read side gates whenever it is expected (authenticated
  /// session, including its handshake window) or currently live; sessions
  /// that genuinely have no read socket never block on it.
  bool isChannelChatReady(String channel) => _readiness.isChannelReady(channel);

  /// Posts the per-channel "Connected" once, when the channel becomes fully
  /// usable. Called from whichever JOIN confirmation completes readiness.
  void _announceConnected(String channel) {
    if (!isChannelChatReady(channel)) return;
    if (_readiness.acknowledgeConnected(channel)) {
      onSystemMessage(channel, 'Connected');
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
      _joinProgress.ensureTicker();
      _startWatchdog();

      sevenTvClient?.connect();

      // EventSub session lifecycle: subscriptions are session-scoped, so drop
      // moderation-channel state when the session dies (IRC fallback resumes)
      // and re-subscribe when a new session comes up (session_reconnect or
      // keepalive reconnect) - otherwise moderation and the broadcaster
      // widgets stay dead until the next IRC reconnect.
      statusSub?.cancel();
      statusSub = eventSub.onStatus.listen((status) {
        if (isDisposed) return;
        if (status == EventSubStatus.disconnected ||
            status == EventSubStatus.connecting) {
          // Connecting clears too: session_reconnect/keepalive paths replace
          // the session inside connect() without emitting disconnected, so
          // without this the stale active sets would skip every resubscribe
          // on the new session (subs are session-scoped and die with it).
          eventSubTopics.clearSessionState();
        } else if (status == EventSubStatus.connected) {
          eventSubTopics.resubscribeEventSubChannels(chat.names);
        }
      });

      ircStatusSub?.cancel();
      ircStatusSub = irc.onStatus.listen((status) async {
        if (isDisposed) return;
        connectionStateNotifier.value++;
        if (status == IrcConnectionStatus.connected && irc.isConnected) {
          _readiness.noteWriteSocketConnected();
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
          _readiness.resetForWriteDisconnect();
          _lastSubscribeAll = null;
          _joinProgress.clearAllWaits();
          // Failure state is per socket lifetime: the fresh socket runs its
          // own fast sweep, so it may legitimately fail (and re-announce)
          // again.
          _channelSetup.resetJoinFailureState();
          for (final channel in chat.names) {
            onSystemMessage(channel, 'Disconnected');
          }
        }
      });

      // The read-only socket reconnects independently of the write socket. A
      // read-socket outage alone (DNS failure, server move) would otherwise be
      // invisible: chat freezes with no "Disconnected" (the write socket is
      // still fine) and no recovery notice. Surface it as an explicit status.
      // Its JOIN confirmations die with the socket, so the input gate must
      // re-lock and the frame must rebuild.
      ircReadStatusSub?.cancel();
      ircReadStatusSub = ircRead.onStatus.listen((status) {
        if (isDisposed) return;
        if (status == IrcConnectionStatus.connected &&
            _readiness.noteReadSocketRecovered()) {
          for (final channel in chat.names) {
            // Same ack as the JOIN-confirm path below: a flapping write
            // socket reports the same recovery, keep one line.
            if (_readiness.acknowledgeConnected(channel)) {
              onSystemMessage(channel, 'Reconnected');
            }
          }
          connectionStateNotifier.value++;
        } else if (status == IrcConnectionStatus.disconnected &&
            _readiness.noteReadSocketDisconnected()) {
          connectionStateNotifier.value++;
          for (final channel in chat.names) {
            onSystemMessage(channel, 'Chat reconnecting...');
          }
        }
      });

      // Arm the read requirement on its very first connect (not just
      // recoveries), so the pipe gate covers this session from the start.
      // Armed once: connect() re-runs on every auth change and must not
      // stack another waiter while the read socket stays down. The
      // controller closing on dispose completes with an error; ignore.
      if (!_readiness.readEverConnected && !_readConnectWaiterArmed) {
        _readConnectWaiterArmed = true;
        unawaited(
          ircRead.onStatus
              .firstWhere((s) => s == IrcConnectionStatus.connected)
              .then((_) {
                _readConnectWaiterArmed = false;
                if (!isDisposed && !_readiness.readEverConnected) {
                  _readiness.noteReadSocketEverConnected();
                  connectionStateNotifier.value++;
                }
              })
              .catchError((_) {
                _readConnectWaiterArmed = false;
              }),
        );
      }

      ircAuthFailedSub?.cancel();
      ircAuthFailedSub = irc.onAuthFailed.listen((_) {
        if (isDisposed) return;
        _handleExpiredToken();
      });

      ircReadAuthFailedSub?.cancel();
      ircReadAuthFailedSub = ircRead.onAuthFailed.listen((_) {
        if (isDisposed) return;
        _handleExpiredToken();
      });

      // Use the cached account if available so cold start skips the Helix
      // user lookup entirely.
      if (session.login == null && auth.login != null && auth.userId != null) {
        session.apply(auth.login, userId: auth.userId);
      }

      // Account-switch fast path (runs before any await): a different account
      // was requested while the previous session's socket may still be up, so
      // the new credentials take over instead of riding the old account's
      // socket while this connect() is still validating.
      final pendingUsername = (session.login ?? auth.login)?.toLowerCase();
      final hadPreviousSession =
          _lastIrcUsername != null || _lastIrcToken != null;
      if (hadPreviousSession &&
          pendingUsername != null &&
          pendingUsername != _lastIrcUsername) {
        // The write socket never JOINs, so there are no per-channel JOIN
        // confirmations to drop; sends simply use whatever write socket is up.
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
            if (result != null && auth.accessToken == validatedToken) {
              // Grant predates scopes added after login: prompt re-login
              // instead of failing Tier 3 calls with 403s.
              if (TwitchOAuth.missingScopes(result.scopes).isNotEmpty) {
                auth.markScopeStale();
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
        eventSubTopics.clearSessionState();
        // Skip sets reset here too when the identity already differs: the
        // post-lookup reset below runs after awaits, and a fast handshake
        // would otherwise resubscribe against the old account's rejections.
        // Best-effort (login may resolve below); the later reset re-checks.
        final preUsername = (session.login ?? auth.login)?.toLowerCase();
        if (_lastIrcUsername != preUsername ||
            _lastIrcToken != (auth.accessToken ?? 'anonymous')) {
          eventSubTopics.resetAccountScope();
        }
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
        session.apply(currentUser['login'], userId: currentUser['id']);
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
        eventSubTopics.resetAccountScope();
        _channelSetup.resetJoinFailureState();
        // New credentials re-arm expiry handling; without this a second dead
        // token after a mid-session re-auth would fail silently forever.
        _expiryHandled = false;
        // The suppressed disconnect skips the status-listener cleanup, so the
        // switch drops per-session/per-account state here explicitly: old
        // JOIN confirmations must not gate sends, self badges and slow-mode/
        // timeout anchors belong to the old account, and duplicate-bypass
        // wire text must not carry across accounts.
        _readiness.resetForAccountSwitch();
        _lastSubscribeAll = null;
        readDecoder.clearSelfBadges();
        _sender.clearAccountScope();
        // The queue belongs to the old account's moderation scope.
        for (final name in chat.names) {
          chat.channelFor(name)?.moderation.clearHeld();
        }
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
        // An authenticated session gets BOTH sockets; arming happens via
        // _lastIrcAnonymous below (_readExpected = !anonymous), so the
        // handshake window counts as "read pending" instead of "read
        // absent" - no premature Connected, no early input unlock.
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
    session.apply(null);
    // Logged-out identity keeps no queue, and the dead token's subs will
    // not resolve it; IRC fallback resumes moderation echoes.
    for (final name in chat.names) {
      chat.channelFor(name)?.moderation.clearHeld();
    }
    eventSubTopics.clearSessionState();
    for (final channel in chat.names) {
      onSystemMessage(
        channel,
        'Login expired - reconnect your account in Settings',
      );
    }
    onBanner?.call('Login expired');
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
    ircNoticeSub = readDecoder.onNotice.listen((event) {
      if (isDisposed) return;
      // With channel.moderate active, room-state changes come from EventSub
      // with structured data - suppress the redundant IRC NOTICE.
      if (eventSubTopics.isModerationActive(event.channel) &&
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
    ircJtvSub = readDecoder.onJtvMessage.listen((event) {
      if (isDisposed) return;
      onSystemMessage(event.channel, event.message);
    });

    // Send rejections (slow-mode, banned, msg-too-long, ...) come back on the
    // write socket; surface them as system messages instead of dropping them.
    ircWriteNoticeSub?.cancel();
    ircWriteNoticeSub = writeDecoder.onNotice.listen((event) {
      if (isDisposed) return;
      onSystemMessage(event.channel, event.message);
    });

    // JOIN failures from the read socket are handled by the setup domain,
    // which also tracks the notified set for the NOTICE suppression above.
    ircJoinFailedSub?.cancel();
    ircJoinFailedSub = ircRead.onJoinFailed.listen((event) {
      if (isDisposed) return;
      _channelSetup.handleJoinFailed(event);
      // Stop the perpetual "still joining" marker; the channel is not ready
      // and the failure was already surfaced as a system message.
      _readiness.noteJoinFailed(event.channel);
      _joinProgress.clearWait(event.channel);
    });

    whisperSub?.cancel();
    whisperSub = readDecoder.onWhisper.listen(onWhisperEvent);

    userNoticeSub?.cancel();
    userNoticeSub = readDecoder.onUserNotice.listen((event) {
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
    });

    // The read socket is the sole JOINer: its ROOMSTATE resolves room status
    // (slow mode, followers-only, ...), confirms the JOIN, and drives
    // readiness.
    ircReadRoomStateSub?.cancel();
    ircReadRoomStateSub = readDecoder.onRoomState.listen((event) {
      if (isDisposed) return;
      if (_channelSetup.handleRoomState(event)) {
        final isNew = _readiness.noteReadRoomState(event.channel);
        if (isNew) {
          PerfLog.I.record('JOINQ', 'read-confirm ${event.channel}');
          _joinProgress.clearWait(event.channel);
          if (isChannelChatReady(event.channel)) {
            _announceConnected(event.channel);
            connectionStateNotifier.value++;
          }
        }
      }
    });

    // The write socket also echoes ROOMSTATE after its own JOIN. Its JOIN
    // confirmations let anonymous sessions resolve readiness without a read
    // socket, and complete the both-sockets check for authenticated ones.
    ircWriteRoomStateSub?.cancel();
    ircWriteRoomStateSub = writeDecoder.onRoomState.listen((event) {
      if (isDisposed) return;
      _channelSetup.handleRoomState(event);
      final isNew = _readiness.noteWriteRoomState(event.channel);
      if (isNew) {
        if (isChannelChatReady(event.channel)) {
          _announceConnected(event.channel);
          connectionStateNotifier.value++;
        }
      }
    });

    emoteSetsSub?.cancel();
    emoteSetsSub = readDecoder.onUserEmoteSets.listen((event) {
      if (isDisposed || onUserEmoteSets == null) return;
      final (channel, ids) = event;
      unawaited(onUserEmoteSets!(channel, ids));
    });

    eventSubConsumer.attach(eventSubDecoder);

    _sevenTvConsumer.attach();
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

  /// Bumps [channel] to the front of the JOIN queue so the next pump tick
  /// dispatches it first. No-op if not queued.
  void focusChannel(String channel) {
    joinBudget?.bumpToFront(channel);
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

  /// Foreground liveness watchdog: periodically re-arms any socket whose
  /// reconnect loop died without a pending connect (e.g. a fatal-auth break
  /// or a generation bump that wasn't followed by a fresh connect). The
  /// in-socket loop already retries forever on ordinary network drops, so
  /// this only needs to run while the app is in the foreground.
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (isDisposed) return;
      reconnectIfNecessary();
    });
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

  /// Re-runs the per-channel data loads (emotes, badges) that failed earlier,
  /// updating the retryable failure state. Driven by the UI retry affordance.
  void retryChannelData(String channel) {
    final userId = chat.channelFor(channel)?.info.broadcasterId;
    if (userId == null) return;
    final auth = twitchAuth;
    unawaited(
      badgeService
          .fetchChannelBadges(auth, userId, channel)
          .then((_) => chat.clearLoadFailure(channel, 'badges'))
          .catchError((_) => chat.recordLoadFailure(channel, 'badges')),
    );
    emoteManager.accessToken = auth.accessToken;
    unawaited(
      emoteManager
          .resolveEmotes(channel, userId)
          .then((_) => chat.clearLoadFailure(channel, 'emotes'))
          .catchError((_) => chat.recordLoadFailure(channel, 'emotes')),
    );
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
