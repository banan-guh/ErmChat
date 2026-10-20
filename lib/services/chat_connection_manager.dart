import 'dart:async';
import 'package:flutter/foundation.dart';
import '../color_utils.dart' show Color;
import '../l10n/l10n.dart';
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
import '../services/seven_tv_presence.dart';
import '../services/twitch_badge_service.dart';
import '../services/user_store.dart';
import '../services/ping_manager.dart';
import '../services/ignore_manager.dart';
import '../services/chat_ingestion.dart';
import '../services/chat_channel_setup.dart';
import '../services/chat_sender.dart';
import '../services/eventsub_consumer.dart';
import '../services/moderation_hub.dart';
import '../services/pubsub_points_consumer.dart';
import '../services/pubsub_service.dart';
import '../services/seven_tv_consumer.dart';
import '../services/chat_readiness.dart';
import '../services/chat_lifecycle.dart';
import '../services/chat_liveness.dart';
import '../chat/channel/messages.dart' show SystemLine;
import '../chat/chat.dart';
import '../client/session.dart';

/// App-scope services the chat pipeline depends on, built by
/// `chatPipelineProvider` and injectable for tests.
class ChatServices {
  ChatServices({
    required this.twitchApi,
    required this.eventSub,
    this.pubSub,
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
    this.sevenTvPresence,
  });

  final TwitchApi twitchApi;
  final EventSubService eventSub;

  /// Null disables redemption headers; the IRC highlight path still works.
  final PubSubService? pubSub;
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

  /// Announces the viewer to 7TV when they chat; null skips it (tests).
  final SevenTvPresence? sevenTvPresence;
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
    required this.onConnStatus,
    required this.getSelectedChannel,
    required this.getMaxMessagesPerChannel,
    this.onBanner,
    this.onLoginExpired,
    this.onFocusComposer,
    this.strings = englishStrings,
  });

  final String mentionsChannel;

  /// Writes a system row. [keep] archives it too: moderation, notices and
  /// set changes stay in history, connection and send status do not.
  final void Function(
    String,
    String, {
    Color? accent,
    String? messageId,
    bool keep,
  })
  onSystemMessage;

  /// Connect-state rows; the kernel folds them and supplies their text.
  final void Function(String channel, SystemLine status) onConnStatus;
  final String? Function() getSelectedChannel;
  final int Function() getMaxMessagesPerChannel;
  final void Function(String message)? onBanner;
  final VoidCallback? onLoginExpired;
  final void Function()? onFocusComposer;

  /// Current-language strings for system messages the pipeline composes.
  final AppLocalizations Function() strings;
}

/// Feature integrations: commands, reply state, analytics, TTS, EventSub
/// widget events and account-scoped queries. Mostly optional; a missing
/// sink disables that integration.
class ChatSinks {
  ChatSinks({
    required this.onCommand,
    required this.getReplyToMsg,
    required this.setReplyToMsg,
    this.onReconnected,
    this.onMention,
    this.onWhisper,
    this.getMacros,
    this.isChatReady,
    this.isBlocked,
    this.getSharedChatMode,
    this.onAnalyticsMessage,
    this.onArchiveMessage,
    this.onArchiveStreamSeen,
    this.onArchiveStreamEnded,
    this.onArchiveModeration,
    this.onAnalyticsModeration,
    this.onHypeTrain,
    this.onPoll,
    this.onPrediction,
    this.onPinned,
    this.onChatMessage,
  });

  final void Function(String, String, TwitchAuth) onCommand;
  final TwitchMessage? Function() getReplyToMsg;
  final void Function(TwitchMessage?) setReplyToMsg;
  final VoidCallback? onReconnected;
  final void Function(String channel, TwitchMessage msg)? onMention;
  final void Function(TwitchMessage msg)? onWhisper;
  final Map<String, String> Function()? getMacros;
  final bool Function()? isChatReady;
  final bool Function(String login)? isBlocked;
  final String Function()? getSharedChatMode;
  final void Function(String channel, TwitchMessage msg)? onAnalyticsMessage;
  final void Function(String channel, TwitchMessage msg)? onArchiveMessage;
  final void Function(
    String channel,
    String id,
    DateTime startedAt,
    String? title,
    String? game,
  )?
  onArchiveStreamSeen;
  final void Function(String id, DateTime endedAt)? onArchiveStreamEnded;
  final void Function(
    String channel,
    String? login,
    DateTime from,
    DateTime to,
  )?
  onArchiveModeration;
  final void Function(String channel, bool isTimeout)? onAnalyticsModeration;
  final void Function(HypeTrainEvent event)? onHypeTrain;
  final void Function(PollEvent event)? onPoll;
  final void Function(PredictionEvent event)? onPrediction;
  final void Function(PinnedMessageEvent event)? onPinned;
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
    isReadSocket: true,
  );
  late final IrcChatDecoder writeDecoder = IrcChatDecoder(
    config.services.irc.onIrcMessage,
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
    strings: config.bridge.strings,
    onSendStateChanged: () => connectionStateNotifier.value++,
    onMessageSent: (channel) {
      final channelId = config.chat.channelFor(channel)?.info.broadcasterId;
      final viewerId = config.session.userId;
      if (channelId == null || viewerId == null) return;
      unawaited(
        config.services.sevenTvPresence?.announce(
          channelTwitchId: channelId,
          viewerTwitchId: viewerId,
        ),
      );
    },
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

  /// [ChatViewBridge.onSystemMessage] for rows history keeps.
  void _keptSystemMessage(
    String channel,
    String text, {
    Color? accent,
    String? messageId,
  }) => config.bridge.onSystemMessage(
    channel,
    text,
    accent: accent,
    messageId: messageId,
    keep: true,
  );

  // Single moderation ingest owner: IRC echoes and the EventSub
  // channel.moderate stream both route here, so precedence and the analytics,
  // feed, and system-line emission happen once per real action.
  late final ModerationHub _moderation = ModerationHub(
    chat: config.chat,
    session: config.session,
    isModerationActive: eventSubTopics.isModerationActive,
    onSystemMessage: _keptSystemMessage,
    onAnalyticsModeration: config.sinks.onAnalyticsModeration,
    onArchiveModeration: config.sinks.onArchiveModeration,
    onSelfTimeoutArmed: _sender.armTimeout,
    onSelfTimeoutCleared: _sender.clearTimeout,
    strings: config.bridge.strings,
  );

  // PubSub redemption consumption: staged partners for IRC correlation
  // plus standalone banners. Owns no socket; the service does.
  late final PubSubPointsConsumer pubSubPointsConsumer = PubSubPointsConsumer(
    chat: config.chat,
    getMaxMessages: () => config.bridge.getMaxMessagesPerChannel(),
    isHiddenUser: (login) =>
        config.sinks.isBlocked?.call(login) == true ||
        config.services.ignoreManager?.isIgnored(login) == true,
    onArchive: config.sinks.onArchiveMessage,
    strings: config.bridge.strings,
  );

  // EventSub consumption: typed decoder events applied to the chat kernel.
  late final EventSubConsumer eventSubConsumer = EventSubConsumer(
    chat: config.chat,
    topics: eventSubTopics,
    moderation: _moderation,
    onSystemMessage: _keptSystemMessage,
    onHypeTrain: config.sinks.onHypeTrain,
    onPoll: config.sinks.onPoll,
    onPrediction: config.sinks.onPrediction,
    strings: config.bridge.strings,
  );

  // 7TV event consumption: socket events applied to the emote manager.
  late final SevenTvConsumer _sevenTvConsumer = SevenTvConsumer(
    emoteManager: config.services.emoteManager,
    sevenTvClient: config.services.sevenTvClient,
    onSystemMessage: _keptSystemMessage,
    strings: config.bridge.strings,
  );

  // Join-confirmation and read-socket-health state behind the readiness
  // queries.
  late final ChatReadiness _readiness = ChatReadiness(
    writeConnected: () => config.services.irc.isConnected,
    readConnected: () => config.services.ircRead.isConnected,
    readExpected: () => _lifecycle.readExpected,
  );

  // Socket liveness: the foreground watchdog plus manual and automatic
  // reconnect paths.
  late final ChatLiveness _liveness = ChatLiveness(
    irc: config.services.irc,
    ircRead: config.services.ircRead,
    eventSub: config.services.eventSub,
    pubSub: config.services.pubSub,
    sevenTvClient: config.services.sevenTvClient,
    session: config.session,
    twitchAuth: config.services.twitchAuth,
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
    eventSubTopics: eventSubTopics,
    sender: _sender,
    channelSetup: _channelSetup,
    liveness: _liveness,
    connectionStateNotifier: connectionStateNotifier,
    setupSubscriptions: _setupSubscriptions,
    subscribeAll: _subscribeAll,
    clearSelfBadges: readDecoder.clearSelfBadges,
    onSystemMessage: config.bridge.onSystemMessage,
    onConnStatus: config.bridge.onConnStatus,
    onLoginExpired: config.bridge.onLoginExpired,
    onReconnected: config.sinks.onReconnected,
    strings: config.bridge.strings,
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
    onSystemMessage: _keptSystemMessage,
    strings: config.bridge.strings,
    onAnalyticsMessage: config.sinks.onAnalyticsMessage,
    onArchiveMessage: config.sinks.onArchiveMessage,
    onChatMessage: config.sinks.onChatMessage,
    onMention: config.sinks.onMention,
    onWhisper: config.sinks.onWhisper,
    pubSubPoints: pubSubPointsConsumer,
  );

  // Channel-domain wiring (joins, Helix/emote/badge resolution, EventSub
  // topic subscriptions, status composition).
  late final ChatChannelSetup _channelSetup = ChatChannelSetup(
    twitchApi: config.services.twitchApi,
    eventSubDecoder: eventSubDecoder,
    eventSubTopics: eventSubTopics,
    pubSub: config.services.pubSub,
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
    ensureCurrentUser: (auth) => _lifecycle.ensureCurrentUser(auth),
    strings: config.bridge.strings,
    getMaxMessages: config.bridge.getMaxMessagesPerChannel,
    onStreamSeen: config.sinks.onArchiveStreamSeen,
    onStreamEnded: config.sinks.onArchiveStreamEnded,
    onSubscribed: syncPin,
  );
  final _ingestionSubs = <StreamSubscription<void>>[];

  /// Latest pin request per channel, so a slow response never overwrites a
  /// newer one.
  final _pinRequests = <String, int>{};

  /// Reads [channel]'s current pin from Helix and shows it, or clears the
  /// card when there is none. PubSub never replays a pin made before it
  /// listened, so this runs on every join and resubscribe, and again on
  /// each pin event. Needs a login; a failed read changes nothing.
  Future<void> syncPin(String channel) async {
    final auth = config.services.twitchAuth;
    final broadcasterId = config.chat.channelFor(channel)?.info.broadcasterId;
    final userId = config.session.userId;
    final onPinned = config.sinks.onPinned;
    if (auth.accessToken == null ||
        broadcasterId == null ||
        broadcasterId.isEmpty ||
        userId == null ||
        onPinned == null) {
      return;
    }
    final request = (_pinRequests[channel] ?? 0) + 1;
    _pinRequests[channel] = request;
    final Map<String, dynamic>? pin;
    try {
      pin = await config.services.twitchApi.getPinnedChatMessage(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: userId,
      );
    } catch (_) {
      return;
    }
    if (_pinRequests[channel] != request) return;
    if (pin == null) {
      onPinned(PinnedMessageEvent(channel: channel, id: '', removed: true));
      return;
    }
    // Helix pins carry no sender color, and the pinned message is often
    // older than the buffer, so ask for it.
    var event = PinnedMessageEvent.fromHelix(channel, pin);
    if (event.senderId.isNotEmpty) {
      final color = await config.services.twitchApi.getUserChatColor(
        auth,
        userId: event.senderId,
      );
      if (_pinRequests[channel] != request) return;
      if (color != null) event = event.withSenderColor(color);
    }
    onPinned(event);
  }

  void dispose() {
    _lifecycle.dispose();
    _liveness.dispose();
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
    pubSubPointsConsumer.dispose();
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
    config.services.pubSub?.forgetChannel(channel);
    _channelSetup.forgetChannel(channel);
  }

  /// Matches the 7TV socket to the 7TV emote and cosmetics settings.
  void applySevenTvSettings({required bool emotes, required bool cosmetics}) =>
      _channelSetup.applySevenTvSettings(emotes: emotes, cosmetics: cosmetics);

  /// Outbound send owner, exposed for tests.
  @visibleForTesting
  ChatSender get sender => _sender;

  /// Chat kernel root, exposed for tests.
  @visibleForTesting
  Chat get chat => config.chat;

  /// Posts Connected once history is in and the channel is usable: on the
  /// read socket, its JOIN confirmed. The write socket is up near instantly,
  /// so it alone would announce a channel that isn't reading chat yet.
  void maybeAddConnected(String channel) {
    if (_readiness.isChannelReady(channel) &&
        (config.chat.channelFor(channel)?.info.historyLoaded ?? false) &&
        _readiness.acknowledgeConnected(channel)) {
      config.bridge.onConnStatus(channel, SystemLine.connected);
    }
  }

  /// Whether event-driven moderation (and its Mod View rows) is up.
  bool isModerationActive(String channel) =>
      eventSubTopics.isModerationActive(channel);

  /// Whether the AutoMod queue subscriptions are up.
  bool isAutomodActive(String channel) =>
      eventSubTopics.isAutomodActive(channel);

  /// Whether Twitch refused or revoked the user's moderation in [channel].
  bool isModerationDenied(String channel) =>
      eventSubTopics.isModerationDenied(channel);

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

  /// Wait before a repeated send to [channel] stays under Twitch's limits.
  Duration repeatDelay(String channel) => _sender.repeatDelay(channel);

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

  /// Whether the channel's JOIN went unconfirmed past the timeout (or was
  /// refused) and is still retrying; the view stops spinning for it.
  bool isChannelJoinFailed(String channel) => _readiness.isJoinFailed(channel);

  Future<void> connect() => _lifecycle.connect();

  void _setupSubscriptions() {
    // connect() re-runs on every auth change; dropping the old subscriptions
    // without cancelling them would leave every IRC event handled N times.
    for (final sub in _ingestionSubs) {
      sub.cancel();
    }
    _ingestionSubs
      ..clear()
      ..addAll(_ingestion.attach())
      ..add(eventSubDecoder.onWhisper.listen(_ingestion.receiveWhisper));

    final pubSub = config.services.pubSub;
    if (pubSub != null) {
      pubSubPointsConsumer.attach(pubSub.onRedemption);
      // Viewer-side chat widgets; EventSub feeds the same sinks for the
      // broadcaster.
      final sinks = config.sinks;
      _ingestionSubs.addAll([
        pubSub.onHypeTrain.listen((e) => sinks.onHypeTrain?.call(e)),
        pubSub.onPoll.listen((e) => sinks.onPoll?.call(e)),
        pubSub.onPrediction.listen((e) => sinks.onPrediction?.call(e)),
        // The event shows at once; Helix then confirms it, which also
        // settles an unpin whose id belongs to a pin read from Helix.
        pubSub.onPinned.listen((e) {
          sinks.onPinned?.call(e);
          unawaited(syncPin(e.channel));
        }),
      ]);
    }
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
  void forceReconnect() => _liveness.forceReconnect();

  void reconnectIfNecessary() => _liveness.reconnectIfNecessary();

  /// Re-runs the per-channel data loads that failed earlier. Delegates to
  /// [ChatChannelSetup], which owns the badge and emote retry path.
  void retryChannelData(String channel) =>
      _channelSetup.retryChannelData(channel);
}
