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
  });

  final String mentionsChannel;
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

  bool _wasConnected = false;
  // Session latch backing [connectPhase]: true once any connect succeeded,
  // never reset. NOT the same question as [_wasConnected] (edge tracking for
  // reconnect backfill) or the read-arm latch in [isChatPipeConnected]
  // (whether the read socket participates at all).
  bool _everConnected = false;
  bool _wasDisconnected = false;
  // Read-socket outage tracking: the read socket dying alone (e.g. a DNS
  // error) must still surface as a visible "Chat reconnecting..." instead of
  // silently freezing chat.
  bool _wasReadDisconnected = false;
  // Arms the first time the read socket connects: from then on the pipe
  // (and the input gate) requires it to stay up. Sessions where the read
  // socket never comes up are not blocked by it.
  bool _readEverConnected = false;
  DateTime? _lastSubscribeAll;
  // Credentials the IRC sockets were last told to use. Compared against the
  // desired account on connect() so an account switch tears the sockets down
  // (an already-connected socket otherwise skips the reconnect).
  String? _lastIrcUsername;
  String? _lastIrcToken;
  final _connectedAcked = <String>{};
  // Write-socket JOIN confirmations. In production the write socket never
  // JOINs, so this stays empty; it exists so tests that drive ROOMSTATE
  // through the write socket still resolve readiness. The read socket's JOIN
  // (below) is the real production signal.
  final _joinedChannels = <String>{};
  // Channels the read socket has JOINed (confirmed by ROOMSTATE). The write
  // socket never JOINs, so this is the authoritative readiness source: a
  // fresh or reconnected read socket may not have processed its JOINs yet,
  // and the local echo of our own messages rides it.
  final _readJoinedChannels = <String>{};
  StreamSubscription<IrcRoomStateEvent>? ircReadRoomStateSub;
  StreamSubscription<IrcRoomStateEvent>? ircWriteRoomStateSub;

  /// Whether the read socket participates in readiness gating: yes for
  /// authenticated sessions (both sockets are part of the deal from the
  /// start, including their handshake windows), no for anonymous read-only
  /// sessions where there is nothing to echo.
  bool get _readExpected => !_lastIrcAnonymous;
  // Channels currently showing a join-countdown line; drives the clear emit
  // when the wait ends or the socket drops.
  final _joinWaitShown = <String>{};
  final _joinFailed = <String>{};
  // Last countdown values shown per channel, so the displayed position never
  // regresses when the rejoin sweep re-queues an in-flight channel.
  final _lastJoinProgress = <String, JoinProgress>{};
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
    onSelfTimeoutCleared: (channel) {
      _selfTimeoutUntil.remove(channel);
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
  StreamSubscription<ModerationEvent>? moderationSub;
  StreamSubscription<AutomodHeldEvent>? automodHeldSub;
  StreamSubscription<HypeTrainEvent>? hypeTrainSub;
  StreamSubscription<PollEvent>? pollSub;
  StreamSubscription<PredictionEvent>? predictionSub;
  StreamSubscription<SevenTvEmoteUpdateEvent>? sevenTvEmoteSub;
  StreamSubscription<SevenTvUserUpdate>? sevenTvUserSub;
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
      session = config.store.session,
      store = config.store,
      channels = config.store.channels,
      historyLoaded = config.store.historyLoaded,
      channelUserIds = config.store.channelUserIds,
      lastSentWireText = config.store.lastSentWireText,
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
      onJoinProgress = config.bridge.onJoinProgress;

  void dispose() {
    isDisposed = true;
    _joinProgressTimer?.cancel();
    _joinProgressTimer = null;
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
    statusSub?.cancel();
    ircNoticeSub?.cancel();
    ircJtvSub?.cancel();
    ircJoinFailedSub?.cancel();
    emoteSetsSub?.cancel();
    moderationSub?.cancel();
    automodHeldSub?.cancel();
    hypeTrainSub?.cancel();
    pollSub?.cancel();
    predictionSub?.cancel();
    sevenTvEmoteSub?.cancel();
    sevenTvUserSub?.cancel();
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
  }

  void stopChatStatusTimer(String channel) {
    _channelSetup.stopChatStatusTimer(channel);
    ircRead.selfBadges.remove(channel);
  }

  /// Drops per-channel subscription state (channel left); the next join
  /// re-subscribes from scratch.
  void forgetChannel(String channel) => _channelSetup.forgetChannel(channel);

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

  // Extra window padded onto both send-gates so a send never slips out while
  // Twitch still considers you blocked: second-granularity countdowns plus
  // local/server clock drift can otherwise expire the gate early.
  static const _sendGrace = Duration(milliseconds: 500);

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
        ircRead.selfBadges[channel] ??
        ircRead.selfBadges[null] ??
        const <String>{};
    return badges.intersection(_slowExemptBadges).isNotEmpty;
  }

  /// Seconds of the channel's current slow mode from the merged ROOMSTATE
  /// tags; 0 when off (missing/empty/0 all mean off).
  int slowModeSeconds(String channel) => _channelSetup.slowModeSeconds(channel);

  /// Whether event-driven moderation (and its Mod View rows) is up.
  bool isModerationActive(String channel) =>
      _channelSetup.isModerationActive(channel);

  /// Whether the AutoMod queue subscriptions are up.
  bool isAutomodActive(String channel) =>
      _channelSetup.isAutomodActive(channel);

  /// Merged ROOMSTATE tags for the mode toggles.
  Map<String, String> roomStateTags(String channel) =>
      _channelSetup.roomStateTags(channel);

  /// Seconds left on your timeout in [channel], null when none is active.
  /// Ceil-rounded over the padded window, so the display starts one second
  /// high and the gate outlives the raw expiry by the send grace.
  int? remainingSelfTimeout(String channel) {
    final until = _selfTimeoutUntil[channel];
    if (until == null) return null;
    final left = until.add(_sendGrace).difference(DateTime.now());
    if (left <= Duration.zero) {
      _selfTimeoutUntil.remove(channel);
      return null;
    }
    return (left.inMilliseconds / 1000).ceil();
  }

  /// Seconds left before you may send again in [channel] under slow mode,
  /// measured from your own last message. Null when slow mode is off, your
  /// badges bypass it, or the window has elapsed. Ceil-rounded like
  /// [remainingSelfTimeout].
  int? remainingSlowCooldown(String channel) {
    final slow = slowModeSeconds(channel);
    if (slow <= 0 || _bypassesSlowMode(channel)) return null;
    final sentAt = _lastOwnMessageAt[channel];
    if (sentAt == null) return null;
    final left = sentAt
        .add(Duration(seconds: slow))
        .add(_sendGrace)
        .difference(DateTime.now());
    if (left <= Duration.zero) return null;
    return (left.inMilliseconds / 1000).ceil();
  }

  Future<void> subscribeChannel(String channelName) async {
    // Clear stale readiness so a re-subscribe re-earns its JOIN confirm.
    _joinedChannels.remove(channelName);
    _readJoinedChannels.remove(channelName);
    connectionStateNotifier.value++;
    await _channelSetup.subscribeChannel(channelName);
  }

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
    connectionStateNotifier.value++;
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

    // Send via the write IRC socket (mirror DankChat). The write socket also
    // JOINs its channels (required to receive their traffic), but a PRIVMSG is
    // valid the moment the socket is up, so there is no join window to gate
    // sends on. The echo of our own message arrives on the read socket, not
    // here. No Helix fallback: if the write socket is down the message cannot
    // be sent, so we surface a notice instead of silently dropping it.
    _lastOwnMessageAt[channel] = DateTime.now();
    if (irc.isConnected) {
      irc.sendMessage(
        channel,
        wireText,
        replyParentMessageId: reply?.messageId,
      );
    } else {
      onSystemMessage(channel, 'Not connected: message not sent');
    }
  }

  /// Retires the channel's countdown line (if shown) via a null progress
  /// emit, so the UI removes the row.
  void _clearJoinWait(String channel) {
    _lastJoinProgress.remove(channel);
    if (!_joinWaitShown.remove(channel)) return;
    onJoinProgress?.call(channel, null);
  }

  /// Whether both IRC sockets are up. The write socket alone can deliver a
  /// PRIVMSG, but without the read socket the local echo has no ride. The
  /// read side only counts once it has connected at least once this session,
  /// so environments without a read socket keep working.
  bool get isChatPipeConnected =>
      irc.isConnected && (!_readEverConnected || ircRead.isConnected);

  /// [ChatPhase] for the current session: connecting on a first boot,
  /// reconnecting after any successful connect dropped, online otherwise.
  /// Per-channel readiness ([isChannelChatReady]) layers on top in the view.
  ChatPhase get connectPhase {
    if (!isChatPipeConnected) {
      return _everConnected ? ChatPhase.reconnecting : ChatPhase.connecting;
    }
    return ChatPhase.online;
  }

  /// Whether [channel]'s JOIN is confirmed on every participating socket -
  /// the point at which a PRIVMSG lands AND echoes back locally. Drives the
  /// chat input gate: between socket-connect and join-confirm, sends would
  /// vanish. The read side gates whenever it is expected (authenticated
  /// session, including its handshake window) or currently live; sessions
  /// that genuinely have no read socket never block on it.
  bool isChannelChatReady(String channel) {
    // Readiness gates the input (send) side. Authenticated sessions have a
    // live read socket whose JOIN confirms the channel is usable; anonymous
    // sessions have no read socket, so readiness there is the write socket
    // being up AND having received the channel's ROOMSTATE (the write socket
    // JOINs and gets ROOMSTATE too).
    if (!_readExpected && !ircRead.isConnected) {
      return irc.isConnected && _joinedChannels.contains(channel);
    }
    return _readJoinedChannels.contains(channel);
  }

  /// Posts the per-channel "Connected" once, when the channel becomes fully
  /// usable. Called from whichever JOIN confirmation completes readiness.
  void _announceConnected(String channel) {
    if (!isChannelChatReady(channel)) return;
    if (_connectedAcked.add(channel)) {
      onSystemMessage(channel, 'Connected');
    }
  }

  /// Emits per-channel join-queue progress once per second while any JOIN is
  /// still waiting in the shared budget (either socket): position plus an ETA
  /// derived from the bucket's refill rate. Channels that left the queue but
  /// have not confirmed on every live socket yet keep or drop their countdown
  /// accordingly (the "Connected" line lands when the write side confirms).
  void _tickJoinProgress() {
    final budget = joinBudget;
    if (budget == null || isDisposed) return;
    for (final channel in channels) {
      if (_joinFailed.contains(channel)) continue;
      if (isChannelChatReady(channel)) {
        _clearJoinWait(channel);
        continue;
      }
      final position = budget.positionOf(channel);
      if (position != null && position > 0) {
        // Monotonic clamp: a rejoin sweep can re-queue an in-flight channel
        // behind newer joins, which would make the countdown jump back up.
        // Once shown, the numbers only move down until the channel is ready.
        final last = _lastJoinProgress[channel];
        final shown = (last != null && last.position < position)
            ? last.position
            : position;
        if (last != null && shown < position) {
          PerfLog.I.record(
            'JOINQ',
            'wait $channel clamped pos=$position -> $shown',
          );
        }
        final rawEta = budget.etaSecondsForChannel(channel);
        final eta = (last != null && last.etaSeconds < rawEta)
            ? last.etaSeconds
            : rawEta;
        final numbersDone = position <= 1 && eta <= 0;
        if (numbersDone) {
          // Head-of-queue with banked tokens: dispatches this instant, and
          // "position 1 · ~0s" would just repeat every tick. Degrade to the
          // numberless marker until the echo lands.
          _lastJoinProgress.remove(channel);
          _emitPlainJoining(channel);
          continue;
        }
        final progress = JoinProgress(shown, eta);
        _lastJoinProgress[channel] = progress;
        _joinWaitShown.add(channel);
        onJoinProgress?.call(channel, progress);
      } else {
        // Unit fully sent (or imminent): no honest numbers exist anymore.
        // Keep a numberless marker so the channel still reads as joining
        // until its "Connected" lands.
        _emitPlainJoining(channel);
      }
    }
  }

  /// Emits the numberless "still joining" state for [channel].
  void _emitPlainJoining(String channel) {
    _joinWaitShown.add(channel);
    onJoinProgress?.call(channel, const JoinProgress(0, 0));
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
          _channelSetup.clearSessionState();
        } else if (status == EventSubStatus.connected) {
          _channelSetup.resubscribeEventSubChannels(channels);
        }
      });

      ircStatusSub?.cancel();
      ircStatusSub = irc.onStatus.listen((status) async {
        if (isDisposed) return;
        connectionStateNotifier.value++;
        if (status == IrcConnectionStatus.connected && irc.isConnected) {
          _everConnected = true;
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
      // Its JOIN confirmations die with the socket, so the input gate must
      // re-lock and the frame must rebuild.
      ircReadStatusSub?.cancel();
      ircReadStatusSub = ircRead.onStatus.listen((status) {
        if (isDisposed) return;
        if (status == IrcConnectionStatus.connected && _wasReadDisconnected) {
          _wasReadDisconnected = false;
          for (final channel in channels) {
            onSystemMessage(channel, 'Reconnected');
          }
          connectionStateNotifier.value++;
        } else if (status == IrcConnectionStatus.disconnected &&
            !_wasReadDisconnected) {
          _wasReadDisconnected = true;
          _readJoinedChannels.clear();
          _joinFailed.clear();
          connectionStateNotifier.value++;
          for (final channel in channels) {
            onSystemMessage(channel, 'Chat reconnecting...');
          }
        }
      });

      // Arm the read requirement on its very first connect (not just
      // recoveries), so the pipe gate covers this session from the start.
      // The controller closing on dispose completes with an error; ignore.
      unawaited(
        ircRead.onStatus
            .firstWhere((s) => s == IrcConnectionStatus.connected)
            .then((_) {
              if (!isDisposed && !_readEverConnected) {
                _readEverConnected = true;
                connectionStateNotifier.value++;
              }
            })
            .catchError((_) {}),
      );

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
        store.applyLogin(auth.login);
        session.userId = auth.userId;
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
        // Skip sets reset here too when the identity already differs: the
        // post-lookup reset below runs after awaits, and a fast handshake
        // would otherwise resubscribe against the old account's rejections.
        // Best-effort (login may resolve below); the later reset re-checks.
        final preUsername = (session.login ?? auth.login)?.toLowerCase();
        if (_lastIrcUsername != preUsername ||
            _lastIrcToken != (auth.accessToken ?? 'anonymous')) {
          _channelSetup.resetAccountScope();
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
        ircRead.clearSelfBadges();
        _selfTimeoutUntil.clear();
        // The queue belongs to the old account's moderation scope.
        store.clearAllHeldMessages();
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
    store.applyLogin(null);
    session.userId = null;
    // Logged-out identity keeps no queue, and the dead token's subs will
    // not resolve it; IRC fallback resumes moderation echoes.
    store.clearAllHeldMessages();
    _channelSetup.clearSessionState();
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
    ircNoticeSub = ircRead.onNotice.listen((event) {
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
    ircJtvSub = ircRead.onJtvMessage.listen((event) {
      if (isDisposed) return;
      onSystemMessage(event.channel, event.message);
    });

    // Send rejections (slow-mode, banned, msg-too-long, ...) come back on the
    // write socket; surface them as system messages instead of dropping them.
    ircWriteNoticeSub?.cancel();
    ircWriteNoticeSub = irc.onNotice.listen((event) {
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
      _joinFailed.add(event.channel);
      _clearJoinWait(event.channel);
    });

    whisperSub?.cancel();
    whisperSub = ircRead.onWhisper.listen(onWhisperEvent);

    userNoticeSub?.cancel();
    userNoticeSub = ircRead.onUserNotice.listen((event) {
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

    // The read socket is the sole JOINer: its ROOMSTATE resolves room status
    // (slow mode, followers-only, ...), confirms the JOIN, and drives
    // readiness.
    ircReadRoomStateSub?.cancel();
    ircReadRoomStateSub = ircRead.onRoomState.listen((event) {
      if (isDisposed) return;
      if (_channelSetup.handleRoomState(event)) {
        final isNew = _readJoinedChannels.add(event.channel);
        if (isNew) {
          PerfLog.I.record('JOINQ', 'read-confirm ${event.channel}');
          _joinFailed.remove(event.channel);
          _clearJoinWait(event.channel);
          if (isChannelChatReady(event.channel)) {
            _announceConnected(event.channel);
            connectionStateNotifier.value++;
          }
        }
      }
    });

    // The write socket also echoes ROOMSTATE after its own JOIN. Populate
    // _joinedChannels so anonymous sessions (where the read socket is dead)
    // can still resolve readiness via the fallback path. For authenticated
    // sessions this also triggers the second half of the "both sockets
    // confirmed" check.
    ircWriteRoomStateSub?.cancel();
    ircWriteRoomStateSub = irc.onRoomState.listen((event) {
      if (isDisposed) return;
      _channelSetup.handleRoomState(event);
      final isNew = _joinedChannels.add(event.channel);
      if (isNew) {
        if (isChannelChatReady(event.channel)) {
          _announceConnected(event.channel);
          connectionStateNotifier.value++;
        }
      }
    });

    emoteSetsSub?.cancel();
    emoteSetsSub = ircRead.onUserEmoteSets.listen((event) {
      if (isDisposed || onUserEmoteSets == null) return;
      final (channel, ids) = event;
      unawaited(onUserEmoteSets!(channel, ids));
    });

    moderationSub ??= eventSub.onModeration.listen(_onModerationEvent);

    automodHeldSub ??= eventSub.onAutomodHeld.listen(_onAutomodHeld);

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
            event.durationSeconds != null &&
            // Zero-length timeouts are already spent - no gate to arm.
            event.durationSeconds! > 0) {
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

  // automod.message.hold/update v2 events: hold queues, any resolution
  // (approved/denied/expired, here or by another mod) dequeues. Resolves
  // apply ungated: the idempotent drop is always safe to honor.
  void _onAutomodHeld(AutomodHeldEvent event) {
    if (isDisposed) return;
    if (event.status != 'held') {
      store.resolveHeldMessage(event.channel, event.messageId);
      return;
    }
    if (!_channelSetup.isAutomodActive(event.channel)) return;
    store.addHeldMessage(
      HeldMessage(
        messageId: event.messageId,
        channel: event.channel,
        userLogin: event.userLogin,
        text: event.text,
        category: event.category,
      ),
    );
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
    final userId = store.channelUserIds[channel];
    if (userId == null) return;
    final auth = twitchAuth;
    unawaited(
      badgeService
          .fetchChannelBadges(auth, userId, channel)
          .then((_) => store.clearLoadFailure(channel, 'badges'))
          .catchError((_) => store.recordLoadFailure(channel, 'badges')),
    );
    emoteManager.accessToken = auth.accessToken;
    unawaited(
      emoteManager
          .resolveEmotes(channel, userId)
          .then((_) => store.clearLoadFailure(channel, 'emotes'))
          .catchError((_) => store.recordLoadFailure(channel, 'emotes')),
    );
  }
}
