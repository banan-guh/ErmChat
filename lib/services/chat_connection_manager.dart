import 'dart:async';
import 'package:flutter/widgets.dart';
import '../util/log.dart';
import '../models/twitch_message.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../eventsub/decode/decoder.dart';
import '../eventsub/decode/events.dart';
import '../eventsub/topics.dart';
import '../eventsub/transport/connection.dart';
import '../irc/decode/decoder.dart' show IrcChatDecoder;
import '../irc/decode/events.dart'
    show IrcNoticeEvent, IrcRoomStateEvent, UserNoticeEvent;
import '../irc/message.dart' show IrcMessage;
import '../irc/transport/events.dart' show IrcJoinFailureEvent;
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
import '../services/chat_lifecycle.dart';
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

  StreamSubscription<IrcRoomStateEvent>? ircReadRoomStateSub;
  StreamSubscription<IrcRoomStateEvent>? ircWriteRoomStateSub;
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
    readExpected: () => _lifecycle.readExpected,
  );

  // Join-queue progress surfaced to the UI while channels wait in the budget.
  late final JoinProgressTracker _joinProgress = JoinProgressTracker(
    joinBudget: joinBudget,
    channelNames: () => chat.names,
    isReady: isChannelChatReady,
    isFailed: (channel) => _readiness.isJoinFailed(channel),
    onProgress: (channel, info) => onJoinProgress?.call(channel, info),
  );

  // Connection lifecycle: connect orchestration, socket status listeners,
  // watchdog, reconnect, token expiry and identity resolution.
  late final ChatLifecycle _lifecycle = ChatLifecycle(
    irc: irc,
    ircRead: ircRead,
    eventSub: eventSub,
    sevenTvClient: sevenTvClient,
    twitchApi: twitchApi,
    twitchAuth: twitchAuth,
    session: session,
    chat: chat,
    readiness: _readiness,
    joinProgress: _joinProgress,
    eventSubTopics: eventSubTopics,
    sender: _sender,
    channelSetup: _channelSetup,
    connectionStateNotifier: connectionStateNotifier,
    setupSubscriptions: _setupSubscriptions,
    subscribeAll: subscribeAll,
    clearSelfBadges: readDecoder.clearSelfBadges,
    onSystemMessage: onSystemMessage,
    onBanner: onBanner,
    onReconnected: onReconnected,
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
    ensureCurrentUser: (auth) => _lifecycle.ensureCurrentUser(auth),
  );
  final _ingestionSubs = <StreamSubscription<void>>[];

  StreamSubscription<IrcNoticeEvent>? ircNoticeSub;
  StreamSubscription<IrcNoticeEvent>? ircJtvSub;
  StreamSubscription<IrcJoinFailureEvent>? ircJoinFailedSub;
  StreamSubscription<TwitchMessage>? whisperSub;
  StreamSubscription<UserNoticeEvent>? userNoticeSub;
  StreamSubscription<(String?, List<String>)>? emoteSetsSub;
  StreamSubscription<IrcNoticeEvent>? ircWriteNoticeSub;

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
    _lifecycle.dispose();
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
    ircNoticeSub?.cancel();
    ircJtvSub?.cancel();
    ircJoinFailedSub?.cancel();
    emoteSetsSub?.cancel();
    ircReadRoomStateSub?.cancel();
    ircWriteRoomStateSub?.cancel();
    userNoticeSub?.cancel();
    ircWriteNoticeSub?.cancel();
    whisperSub?.cancel();
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
      _ingestion.onUserNotice(event);
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
  void forceReconnect() => _lifecycle.forceReconnect();

  void reconnectIfNecessary() => _lifecycle.reconnectIfNecessary();

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
