import 'dart:async';
import 'package:flutter/widgets.dart';
import '../models/twitch_message.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../eventsub/decode/decoder.dart';
import '../eventsub/decode/events.dart';
import '../eventsub/topics.dart';
import '../eventsub/transport/connection.dart';
import '../irc/decode/decoder.dart' show IrcChatDecoder;
import '../irc/message.dart' show IrcMessage;
import '../irc/transport/read.dart' show IrcReadService;
import '../irc/transport/write.dart' show IrcService;
import '../services/emote_manager.dart';
import '../irc/join_rate_limiter.dart';
import '../services/seven_tv_event_client.dart';
import '../services/twitch_badge_service.dart';
import '../services/user_store.dart';
import '../services/ping_manager.dart';
import '../services/ignore_manager.dart';
import '../services/chat_ingestion.dart';
import '../services/chat_channel_setup.dart';
import '../services/chat_sender.dart';
import '../services/eventsub_consumer.dart';
import '../services/moderation_hub.dart';
import '../services/seven_tv_consumer.dart';
import '../services/join_progress_tracker.dart';
import '../services/chat_readiness.dart';
import '../services/chat_lifecycle.dart';
import '../chat/chat.dart';
import '../client/session.dart';

export '../services/join_progress_tracker.dart' show JoinProgress;

/// App-scope services the chat pipeline depends on, built by
/// `chatPipelineProvider` and injectable for tests.
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

/// Rendering and interaction signals flowing manager -> UI: system messages,
/// focus and snackbar requests, plus reads of view-owned state the pipeline
/// needs (selected channel, message cap).
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
    this.onMention,
    this.onWhisper,
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
  final void Function(String channel, TwitchMessage msg)? onMention;
  final void Function(TwitchMessage msg)? onWhisper;
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
  ChatConnectionManager(this.config);

  final ChatConnectionConfig config;

  /// Bumped on connection-phase / channel-ready / reply-clear changes so the
  /// composer can rebuild without forcing a full HomeScreen setState.
  final ValueNotifier<int> connectionStateNotifier = ValueNotifier(0);

  // Decode layer: lifts typed events out of each socket's raw frames. The
  // read decoder watches own echoes via the read socket's nick.
  @visibleForTesting
  late final IrcChatDecoder readDecoder = IrcChatDecoder(
    config.services.ircRead.onIrcMessage,
    nickProvider: () => config.services.ircRead.username,
    debugPrefix: 'IRC read',
    isReadSocket: true,
  );
  late final IrcChatDecoder writeDecoder = IrcChatDecoder(
    config.services.irc.onIrcMessage,
    debugPrefix: 'IRC',
    isReadSocket: false,
  );

  // EventSub decode layer: lifts typed events out of notification frames.
  late final EventSubDecoder eventSubDecoder = EventSubDecoder(
    config.services.eventSub.onNotification,
  );

  // Outbound send path and its send gates.
  late final ChatSender _sender = ChatSender(
    irc: config.services.irc,
    session: config.session,
    twitchAuth: config.services.twitchAuth,
    onCommand: config.sinks.onCommand,
    getReplyToMsg: config.sinks.getReplyToMsg,
    setReplyToMsg: config.sinks.setReplyToMsg,
    onSystemMessage: config.bridge.onSystemMessage,
    slowModeSeconds: (channel) => _channelSetup.slowModeSeconds(channel),
    selfBadges: (channel) =>
        readDecoder.selfBadges[channel] ??
        readDecoder.selfBadges[null] ??
        const <String>{},
    getMacros: config.sinks.getMacros,
    onBanner: config.bridge.onBanner,
    onFocusComposer: config.bridge.onFocusComposer,
    onSendStateChanged: () => connectionStateNotifier.value++,
  );

  // EventSub subscription lifecycle: active/skip sets, subscribe paths,
  // resubscribe, and the gate predicates.
  late final EventSubTopics eventSubTopics = EventSubTopics(
    twitchApi: config.services.twitchApi,
    twitchAuth: config.services.twitchAuth,
    session: config.session,
    chat: config.chat,
    eventSub: config.services.eventSub,
  );

  // Single moderation ingest owner: IRC echoes and the EventSub
  // channel.moderate stream both route here, so precedence and the analytics,
  // feed, and system-line emission happen once per real action.
  late final ModerationHub _moderation = ModerationHub(
    chat: config.chat,
    session: config.session,
    isModerationActive: eventSubTopics.isModerationActive,
    onSystemMessage: config.bridge.onSystemMessage,
    onAnalyticsModeration: config.sinks.onAnalyticsModeration,
    onSelfTimeoutArmed: _sender.armTimeout,
    onSelfTimeoutCleared: _sender.clearTimeout,
  );

  // EventSub consumption: typed decoder events applied to the chat kernel.
  late final EventSubConsumer eventSubConsumer = EventSubConsumer(
    chat: config.chat,
    topics: eventSubTopics,
    moderation: _moderation,
    onSystemMessage: config.bridge.onSystemMessage,
    onHypeTrain: config.sinks.onHypeTrain,
    onPoll: config.sinks.onPoll,
    onPrediction: config.sinks.onPrediction,
  );

  // 7TV event consumption: socket events applied to the emote manager.
  late final SevenTvConsumer _sevenTvConsumer = SevenTvConsumer(
    emoteManager: config.services.emoteManager,
    sevenTvClient: config.services.sevenTvClient,
    onSystemMessage: config.bridge.onSystemMessage,
  );

  // Join-confirmation and read-socket-health state behind the readiness
  // queries.
  late final ChatReadiness _readiness = ChatReadiness(
    writeConnected: () => config.services.irc.isConnected,
    readConnected: () => config.services.ircRead.isConnected,
    readExpected: () => _lifecycle.readExpected,
  );

  // Join-queue progress surfaced to the UI while channels wait in the budget.
  late final JoinProgressTracker _joinProgress = JoinProgressTracker(
    joinBudget: config.services.joinBudget,
    channelNames: () => config.chat.names,
    isReady: isChannelChatReady,
    isFailed: (channel) => _readiness.isJoinFailed(channel),
    onProgress: (channel, info) =>
        config.bridge.onJoinProgress?.call(channel, info),
  );

  // Connection lifecycle: connect orchestration, socket status listeners,
  // watchdog, reconnect, token expiry and identity resolution.
  late final ChatLifecycle _lifecycle = ChatLifecycle(
    irc: config.services.irc,
    ircRead: config.services.ircRead,
    readDecoder: readDecoder,
    writeDecoder: writeDecoder,
    eventSub: config.services.eventSub,
    sevenTvClient: config.services.sevenTvClient,
    twitchApi: config.services.twitchApi,
    twitchAuth: config.services.twitchAuth,
    session: config.session,
    chat: config.chat,
    readiness: _readiness,
    joinProgress: _joinProgress,
    eventSubTopics: eventSubTopics,
    sender: _sender,
    channelSetup: _channelSetup,
    connectionStateNotifier: connectionStateNotifier,
    setupSubscriptions: _setupSubscriptions,
    subscribeAll: _subscribeAll,
    clearSelfBadges: readDecoder.clearSelfBadges,
    onSystemMessage: config.bridge.onSystemMessage,
    onBanner: config.bridge.onBanner,
    onReconnected: config.sinks.onReconnected,
  );

  // Chat-content routing (PRIVMSG/CLEARMSG/CLEARCHAT/clears/own echo).
  late final ChatIngestion _ingestion = ChatIngestion(
    irc: config.services.irc,
    ircRead: config.services.ircRead,
    readDecoder: readDecoder,
    writeDecoder: writeDecoder,
    chat: config.chat,
    session: config.session,
    userStore: config.services.userStore,
    emoteManager: config.services.emoteManager,
    badgeService: config.services.badgeService,
    twitchAuth: config.services.twitchAuth,
    sender: _sender,
    moderation: _moderation,
    ignoreManager: config.services.ignoreManager,
    pingManager: config.services.pingManager,
    mentionsChannel: config.bridge.mentionsChannel,
    getMaxMessagesPerChannel: config.bridge.getMaxMessagesPerChannel,
    getSelectedChannel: config.bridge.getSelectedChannel,
    isChatReady: config.sinks.isChatReady,
    isBlocked: config.sinks.isBlocked,
    getSharedChatMode: config.sinks.getSharedChatMode,
    isModerationActive: (channel) => eventSubTopics.isModerationActive(channel),
    isJoinFailureNotified: _channelSetup.isJoinFailureNotified,
    onSystemMessage: config.bridge.onSystemMessage,
    onAnalyticsMessage: config.sinks.onAnalyticsMessage,
    onChatMessage: config.sinks.onChatMessage,
    onMention: config.sinks.onMention,
    onWhisper: config.sinks.onWhisper,
  );

  // Channel-domain wiring (joins, Helix/emote/badge resolution, EventSub
  // topic subscriptions, status composition).
  late final ChatChannelSetup _channelSetup = ChatChannelSetup(
    twitchApi: config.services.twitchApi,
    eventSubDecoder: eventSubDecoder,
    eventSubTopics: eventSubTopics,
    irc: config.services.irc,
    ircRead: config.services.ircRead,
    readDecoder: readDecoder,
    sevenTvClient: config.services.sevenTvClient,
    badgeService: config.services.badgeService,
    emoteManager: config.services.emoteManager,
    twitchAuth: config.services.twitchAuth,
    userStore: config.services.userStore,
    chat: config.chat,
    session: config.session,
    onSystemMessage: config.bridge.onSystemMessage,
    connectionStateNotifier: connectionStateNotifier,
    onUserEmoteSets: config.sinks.onUserEmoteSets,
    ensureCurrentUser: (auth) => _lifecycle.ensureCurrentUser(auth),
  );
  final _ingestionSubs = <StreamSubscription<void>>[];

  void dispose() {
    _joinProgress.dispose();
    _lifecycle.dispose();
    // This manager owned the session's join demand; drop its queued units so
    // the shared bucket's pump timer can wind down instead of ticking on
    // dead sockets forever.
    config.services.joinBudget?.clear();
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

  /// Outbound send owner, exposed for tests.
  @visibleForTesting
  ChatSender get sender => _sender;

  /// Chat kernel root, exposed for tests.
  @visibleForTesting
  Chat get chat => config.chat;

  void maybeAddConnected(String channel) {
    if (config.services.irc.isConnected &&
        (config.chat.channelFor(channel)?.info.historyLoaded ?? false) &&
        _readiness.acknowledgeConnected(channel)) {
      config.bridge.onSystemMessage(channel, 'Connected');
    }
  }

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

  void _subscribeAll() => _channelSetup.subscribeAll(config.chat.names);

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

  Future<void> connect() => _lifecycle.connect();

  void _setupSubscriptions() {
    // connect() re-runs on every auth change; dropping the old subscriptions
    // without cancelling them would leave every IRC event handled N times.
    for (final sub in _ingestionSubs) {
      sub.cancel();
    }
    _ingestionSubs
      ..clear()
      ..addAll(_ingestion.attach());

    _channelSetup.attach();

    eventSubConsumer.attach(eventSubDecoder);

    _sevenTvConsumer.attach();
  }

  // Chat-content routing lives in [ChatIngestion]; kept as delegators so
  // tests can feed synthetic messages through the same policy gates.
  @visibleForTesting
  void onMessage(TwitchMessage msg) => _ingestion.onMessage(msg);

  @visibleForTesting
  void onOwnIrcMessage(IrcMessage ircMsg) => _ingestion.onOwnIrcMessage(ircMsg);

  /// Bumps [channel] to the front of the JOIN queue so the next pump tick
  /// dispatches it first. No-op if not queued.
  void focusChannel(String channel) {
    config.services.joinBudget?.bumpToFront(channel);
  }

  /// Brute-force teardown + reconnect of every socket (manual "Reconnect"
  /// button). Unlike [reconnectIfNecessary], it never checks liveness - it
  /// always disconnects and re-establishes the IRC/EventSub/7TV connections.
  void forceReconnect() => _lifecycle.forceReconnect();

  void reconnectIfNecessary() => _lifecycle.reconnectIfNecessary();

  /// Re-runs the per-channel data loads that failed earlier. Delegates to
  /// [ChatChannelSetup], which owns the badge and emote retry path.
  void retryChannelData(String channel) =>
      _channelSetup.retryChannelData(channel);
}
