import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show FramePhase;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/emote_fetch_tier.dart';
import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_eventsub.dart';
import '../services/twitch_irc.dart';
import '../services/connectivity_service.dart';
import '../services/recent_messages.dart';
import '../services/seven_tv_event_client.dart';
import '../services/command_handler.dart';
import '../services/chat_connection_manager.dart';
import '../services/emote_manager.dart';
import '../services/emote_cache_manager.dart';
import '../services/analytics_service.dart';
import '../services/twitch_badge_service.dart';
import '../services/emote_providers/twitch_emotes.dart';
import '../util/log.dart';
import '../util/mention.dart';
import '../util/sheet_drag.dart';
import '../util/thread_utils.dart';
import '../util/timestamp_formatter.dart';
import '../screens/settings/settings_screen.dart';
import '../widgets/tabbed_layout.dart';
import '../widgets/welcome_dialog.dart';
import '../services/user_store.dart';
import '../services/suggestion.dart';
import '../services/notification_service.dart';
import '../services/tts_controller.dart';
import '../widgets/autocomplete_dropdown.dart';
import '../widgets/user_profile_sheet.dart';
import '../widgets/emote_sheet.dart';
import '../widgets/message_input.dart';
import '../widgets/media_upload_controller.dart';
import '../widgets/thread_panel.dart';
import '../widgets/mentions_panel.dart';
import '../widgets/emote_menu_panel.dart';
import '../widgets/chat_view.dart';
import '../widgets/message_builder.dart';
import '../widgets/predictive_back_handler.dart';
import '../widgets/chat_widget_cutout.dart';
import '../widgets/join_channel_dialog.dart';
import '../services/foreground_task.dart';

enum OverlayPanel { closed, thread, mentions }

class HomeScreen extends StatefulWidget {
  final TwitchAuth twitchAuth;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool>? onKeepScreenOnChanged;
  final ValueChanged<bool>? onTrueDarkChanged;
  final ValueChanged<String>? onAccentColorChanged;
  final EventSubService? eventSubService;
  final IrcService? ircService;
  final IrcReadService? ircReadService;
  final RecentMessagesService? recentMessagesService;
  final ConnectivityService? connectivityService;
  final String? initialCurrentUserLogin;

  const HomeScreen({
    super.key,
    required this.twitchAuth,
    required this.onThemeChanged,
    this.onKeepScreenOnChanged,
    this.onTrueDarkChanged,
    this.onAccentColorChanged,
    this.eventSubService,
    this.ircService,
    this.ircReadService,
    this.recentMessagesService,
    this.connectivityService,
    this.initialCurrentUserLogin,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const _mentionsChannel = '@mentions';
  static const _defaultAltPings = <String>[];

  List<String> _altPings = _defaultAltPings;

  late final _connectivityService =
      widget.connectivityService ?? ConnectivityService();
  late final _eventSub =
      widget.eventSubService ??
      EventSubService(connectivityService: _connectivityService);
  late final _irc =
      widget.ircService ??
      IrcService(connectivityService: _connectivityService);
  late final _ircRead =
      widget.ircReadService ??
      IrcReadService(connectivityService: _connectivityService);
  late final _recentMessages =
      widget.recentMessagesService ?? RecentMessagesService();
  late final _sevenTvClient = SevenTvEventClient(
    connectivityService: _connectivityService,
  );
  late final _twitchApi = TwitchApi();
  late final _analytics = AnalyticsService(
    emoteLookup: (channel) => _emoteManager.byCode(channel),
  );
  final _ttsController = TtsController();

  late final _chatConn = ChatConnectionManager(
    ChatConnectionConfig(
      twitchApi: _twitchApi,
      eventSub: _eventSub,
      irc: _irc,
      ircRead: _ircRead,
      sevenTvClient: _sevenTvClient,
      emoteManager: _emoteManager,
      badgeService: _badgeService,
      userStore: _userStore,
      twitchAuth: widget.twitchAuth,
      channelMessages: _channelMessages,
      messageKeys: _messageKeys,
      chatStatus: _chatStatus,
      channelsWithUnread: _channelsWithUnread,
      channelsWithUnreadMentions: _channelsWithUnreadMentions,
      unreadMentionsPerChannel: _unreadMentionsPerChannel,
      channels: _channels,
      historyLoaded: _historyLoaded,
      channelsEmotesResolved: _channelsEmotesResolved,
      channelUserIds: _channelUserIds,
      lastSentWireText: _lastSentWireText,
      bumpChannel: _notifyNewMessage,
      invalidateChannel: _bumpChannel,
      invalidateMessage: _invalidateMessage,
      mentionsChannel: _mentionsChannel,
      onRebuild: () {
        if (mounted) setState(() {});
      },
      onSystemMessage: _addSystemMessage,
      onAnalyticsMessage: (channel, msg) =>
          _analytics.recordMessage(channel, msg),
      onAnalyticsModeration: (channel, isTimeout) =>
          _analytics.recordModeration(channel, isTimeout),
      onHypeTrain: _onHypeTrain,
      onPoll: _onPoll,
      onPrediction: _onPrediction,
      onUserEmoteSets: _loadUserEmoteSets,
      onReconnected: _onReconnected,
      getMaxMessagesPerChannel: () => _maxMessagesPerChannel,
      getSelectedChannel: () => _selectedChannel,
      onChatMessage: (channel, msg) =>
          _ttsController.handleMessage(channel, msg, _selectedChannel),
      getUnreadMentions: () => _unreadMentions,
      setUnreadMentions: (v) {
        _unreadMentions = v;
        _mentionsBump.value++;
      },
      getCurrentUserLogin: () => _currentUserLogin,
      setCurrentUserLogin: (v) {
        _currentUserLogin = v;
        _scanHistoryForMentions();
        unawaited(_ensureBlockedUsersLoaded());
      },
      getCurrentUserId: () => _currentUserId,
      setCurrentUserId: (v) => _currentUserId = v,
      onCommand: _handleCommand,
      getReplyToMsg: () => _replyToMsg,
      setReplyToMsg: (v) => _replyToMsg = v,
      isChatReady: () => _blocksReady,
      isBlocked: (login) => _blockedLogins.contains(login.toLowerCase()),
      onRequestFocus: () => _focusNode.requestFocus(),
      getAltPings: () => _altPings,
      onShowSnackBar: (msg) {
        if (mounted) {
          final messenger = ScaffoldMessenger.of(context);
          // Replace any current snackbar so identical/rapid info popups don't
          // queue up one after another.
          messenger.removeCurrentSnackBar();
          messenger.showSnackBar(SnackBar(content: Text(msg)));
        }
      },
    ),
  );
  late final _messageBuilder = MessageBuilder(
    emoteManager: _emoteManager,
    badgeService: _badgeService,
    onShowEmoteSheet: _showEmoteSheet,
  );
  late final _commandHandler = CommandHandler(
    twitchApi: _twitchApi,
    irc: _irc,
    getChannelUserIds: () => _channelUserIds,
    getCurrentUserId: () => _currentUserId,
    getCurrentUserLogin: () => _currentUserLogin,
    addSystemMessage: _addSystemMessage,
    whisperAddSystemMessage: _addWhisperSystemMessage,
    onWhisperSent: _onWhisperSent,
    onUserBlocked: _onUserBlocked,
    onUserUnblocked: _onUserUnblocked,
  );
  final _messageController = TextEditingController();
  final _focusNode = FocusNode();
  late final MediaUploadController _uploadController = MediaUploadController(
    input: _messageController,
    focusNode: _focusNode,
  );

  final _notificationService = NotificationService();
  StreamSubscription<String>? _notificationTapSub;
  bool _backgroundService = false;
  bool _mentionPush = false;
  var _isBackgrounded = false;

  int _manualEmoteTierIndex = EmoteFetchTier.high.index;
  EmoteFetchAutoMode _emoteAutoMode = defaultEmoteFetchAutoMode;
  final _isMobile = ValueNotifier<bool>(false);
  VoidCallback? _connectivityListener;

  late final _emoteManager = EmoteManager(
    probe: _connectivityService.checkConnectivity,
  );
  final _badgeService = TwitchBadgeService();
  final _userStore = UserStore();
  final _channels = <String>[];
  final _channelNotifier = ValueNotifier<List<String>>([]);
  final _chatVersions = <String, ValueNotifier<int>>{};
  final _messageNotifiers = <String, ValueNotifier<int>>{};
  final _tileCache = <String, Map<String?, Widget>>{};
  final _mentionsBump = ValueNotifier(0);
  String? _selectedChannel;
  final _channelMessages = <String, List<TwitchMessage>>{};
  final _blockedLogins = <String>{};
  bool _blocksReady = false;
  bool _blocksFetched = false;
  bool _channelsLoaded = false;
  final _scrollControllers = <String, ScrollController>{};
  final _atBottomNotifiers = <String, ValueNotifier<bool>>{};
  final _frozenSnapshot = <String, List<TwitchMessage>>{};
  final _historyLoaded = <String>{};
  final _refetchingChannels = <String>{};
  final _messageKeys = <String>{};
  final _chatStatus = <String, String>{};
  final _channelUserIds = <String, String>{};
  final _channelsEmotesResolved = <String>{};
  // Emote set IDs already fetched via the IRC emote-sets path, so repeated
  // USERSTATE (per channel join / message send) doesn't refetch them.
  final _fetchedEmoteSetIds = <String>{};
  // Emote set IDs currently being fetched. Added before the network call so
  // a concurrent USERSTATE/GLOBALUSERSTATE doesn't double-fetch the same
  // sets; removed on failure so a failed fetch is retried by the next event.
  final _inflightEmoteSetIds = <String>{};
  // Owner id -> login for sub-emote owners, resolved once per session (open
  // channels are derived from _channelUserIds; the rest via Helix /users).
  final _emoteOwnerLogins = <String, String>{};
  bool _emoteOwnerLookupDone = false;
  int _unreadMentions = 0;
  final _channelsWithUnread = <String>{};
  final _channelsWithUnreadMentions = <String>{};
  final _unreadMentionsPerChannel = <String, int>{};

  // Broadcaster-only chat widgets (hype train / poll / prediction).
  final _hypeTrains = <String, HypeTrainEvent>{};
  final _polls = <String, PollEvent>{};
  final _predictions = <String, PredictionEvent>{};
  final _widgetsMinimized = <String, bool>{};
  final _widgetPageCtrl = PageController();

  // Dev-only fake chat widgets (see DevSettingsScreen "Test chat widgets").
  Timer? _testWidgetsTimer;
  int _fakeLevel = 1;
  int _fakeProgress = 0;
  int _fakeGoal = 100;
  int _fakePollA = 120;
  int _fakePollB = 80;
  int _fakePollC = 40;
  int _fakePredYes = 900;
  int _fakePredNo = 450;
  DateTime? _fakeTrainEndsAt;

  TwitchMessage? _replyToMsg;
  TwitchMessage? _openThreadRoot;
  bool _replyToRoot = false;
  bool _preferEmotesFirst = false;
  OverlayPanel _activePanel = OverlayPanel.closed;
  bool _emoteSheetOpen = false;
  int _maxMessagesPerChannel = 200;
  int _recentMessagesLimit = 100;
  int _nextSystemMessageId = 0;
  bool _showTimestamps = true;
  String _timestampFormat = kDefaultTimestampFormat;
  double _chatFontSize = 14.0;
  bool _checkeredMessages = false;
  bool _lineSeparator = false;

  final _suggestionsNotifier = ValueNotifier<List<Suggestion>>([]);
  final _selectedTabIndex = ValueNotifier<int>(0);

  final _threadSheetRatio = ValueNotifier(0.0);
  final _mentionsSheetRatio = ValueNotifier(0.0);
  late final DraggableScrollableController _emoteSheetCtrl;
  late final TabController _mentionsTabCtrl;
  final _threadPanelScrollCtrl = ScrollController();
  final _mentionsPanelScrollCtrl = ScrollController();

  // Predictive back gesture: scales the open panel down (1.0 -> 0.90)
  // following the Android back gesture, driven by PanelPredictiveBackHandler.
  late final AnimationController _panelScaleCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 1.0,
  );
  late final PanelPredictiveBackHandler _predictiveBackHandler;
  double _panelDragStartRatio = 0.0;
  double _panelDragStartY = 0.0;
  static const _sheetAnimDuration = Duration(milliseconds: 250);
  static const _sheetCloseDuration = Duration(milliseconds: 180);
  static const _emoteMaxFraction = 0.6;
  static const _fullHeightFraction = 1.0;
  double? _emoteSheetBoxHeight;
  final _threadPanelData = ValueNotifier<ThreadPanelData?>(null);
  final _mentionsPanelData = ValueNotifier<List<TwitchMessage>?>(null);
  final _whispersPanelData = ValueNotifier<List<TwitchMessage>?>(null);
  final _whispersPanelScrollCtrl = ScrollController();
  final _whispers = <TwitchMessage>[];
  int _unreadWhispers = 0;
  String? _whisperTarget;

  String? _currentUserLogin;
  bool _mentionScanDone = false;
  String? _currentUserId;
  String? _lastSentText;
  final Map<String, String> _lastSentWireText = {};

  ({int start, String originalText, String replacementText})? _lastAutoUndo;
  String? _previousTextForUndo;
  String? _undoExpectedAfter;

  void _onSheetSizeChanged() {
    // When the user drags the emote sheet down to size 0, close only the
    // emote overlay; an open thread/mentions panel stays underneath.
    if (_emoteSheetOpen &&
        _emoteSheetCtrl.isAttached &&
        _emoteSheetCtrl.size <= 0.001) {
      setState(() {
        _emoteSheetOpen = false;
        _panelScaleCtrl.value = 1.0;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_ttsController.init());
    unawaited(PerfLog.I.init());
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    _currentUserLogin = widget.initialCurrentUserLogin;
    _loadEmotePrefs();
    _emoteSheetCtrl = DraggableScrollableController();
    _mentionsTabCtrl = TabController(length: 2, vsync: this);
    _mentionsTabCtrl.addListener(_onMentionsTabChanged);
    _emoteSheetCtrl.addListener(_onSheetSizeChanged);
    _loadMaxMessages();
    _ensureBlockedUsersLoaded();
    _loadAltPings();
    _loadNotificationSettings();
    _loadTestWidgets();
    _chatConn.connect();
    _chatConn.onWhisper = _onWhisper;
    _emoteManager.accessToken = widget.twitchAuth.accessToken;
    _emoteManager.preloadGlobalEmotes();
    _emoteManager.startCacheGc();
    _emoteManager.addListener(_onEmotesChanged);
    _connectivityService.init();
    _connectivityListener = () {
      final isMobile = _connectivityService.isMobile;
      if (isMobile == _isMobile.value) return;
      _isMobile.value = isMobile;
      _reconcileEmoteTier();
    };
    _connectivityService.addListener(_connectivityListener!);
    _badgeService.fetchGlobalBadges(widget.twitchAuth);
    widget.twitchAuth.addListener(_onAuthChanged);
    _focusNode.addListener(_onInputFocusChanged);
    _messageController.addListener(_onInputChanged);
    WidgetsBinding.instance.addObserver(this);
    _predictiveBackHandler = PanelPredictiveBackHandler(
      isPanelOpen: () => _activePanel != OverlayPanel.closed || _emoteSheetOpen,
      onProgress: (progress) {
        _panelScaleCtrl.value = 1.0 - 0.10 * progress;
      },
      onCancel: () {
        _panelScaleCtrl.animateTo(1.0);
      },
      onCommit: _handlePanelBack,
    );
    WidgetsBinding.instance.addObserver(_predictiveBackHandler);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeShowWelcomeDialog(),
    );
  }

  Future<void> _maybeShowWelcomeDialog() async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('welcome_seen') ?? false) return;
    await prefs.setBool('welcome_seen', true);
    if (!mounted) return;
    showWelcomeDialog(context);
  }

  Future<void> _loadNotificationSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final backgroundService = prefs.getBool('background_service') ?? false;
    final mentionPush = prefs.getBool('mention_push') ?? false;
    if (!mounted) return;
    setState(() {
      _backgroundService = backgroundService;
      _mentionPush = mentionPush;
    });
    if (!Platform.isAndroid) return;
    if (backgroundService) {
      initForegroundService();
    }
    if (mentionPush) {
      _initNotificationInfra();
    }
  }

  void _initNotificationInfra() {
    _notificationService.init();
    _notificationTapSub ??= _notificationService.onNotificationTap.listen(
      _onNotificationTap,
    );
    final pendingChannel = _notificationService.pendingLaunchChannel;
    if (pendingChannel != null) {
      _navigateToChannel(pendingChannel);
    }
    _notificationService.clearMentionNotifications();
    _chatConn.onMention = _onMentionNotification;
  }

  void _setBackgroundService(bool value) {
    if (_backgroundService == value) return;
    setState(() => _backgroundService = value);
    if (!Platform.isAndroid) return;
    if (value) {
      _initForegroundService();
      if (_channels.isNotEmpty) {
        startForegroundService(List.of(_channels));
      }
    } else {
      stopForegroundService();
    }
  }

  void _setMentionPush(bool value) {
    if (_mentionPush == value) return;
    setState(() => _mentionPush = value);
    if (!Platform.isAndroid) return;
    if (value) {
      requestForegroundPermissions();
      _initNotificationInfra();
    } else {
      _notificationService.clearMentionNotifications();
    }
  }

  void _setMaxMessagesPerChannel(int value) {
    if (_maxMessagesPerChannel == value) return;
    setState(() => _maxMessagesPerChannel = value);
    // Apply a lower cap immediately instead of waiting for the next incoming
    // message to hit the truncation path.
    for (final channel in List.of(_channels)) {
      _chatConn.truncateChannelMessages(channel);
      _bumpChannel(channel);
    }
  }

  void _setRecentMessagesLimit(int value) {
    if (_recentMessagesLimit == value) return;
    setState(() => _recentMessagesLimit = value);
  }

  void _setReplyToRoot(bool value) {
    if (_replyToRoot == value) return;
    setState(() => _replyToRoot = value);
  }

  void _setPreferEmotesFirst(bool value) {
    if (_preferEmotesFirst == value) return;
    setState(() => _preferEmotesFirst = value);
  }

  void _setShowTimestamps(bool value) {
    if (_showTimestamps == value) return;
    setState(() => _showTimestamps = value);
    // Rendered tiles bake the timestamp setting in; re-render all channels.
    for (final channel in List.of(_channels)) {
      _bumpChannel(channel);
    }
  }

  void _setTimestampFormat(String value) {
    if (_timestampFormat == value) return;
    setState(() => _timestampFormat = value);
    for (final channel in List.of(_channels)) {
      _bumpChannel(channel);
    }
  }

  void _setChatFontScale(double value) {
    if (_chatFontSize == value) return;
    setState(() => _chatFontSize = value);
    for (final channel in List.of(_channels)) {
      _bumpChannel(channel);
    }
  }

  void _setCheckeredMessages(bool value) {
    if (_checkeredMessages == value) return;
    setState(() => _checkeredMessages = value);
    for (final channel in List.of(_channels)) {
      _bumpChannel(channel);
    }
  }

  void _setLineSeparator(bool value) {
    if (_lineSeparator == value) return;
    setState(() => _lineSeparator = value);
    for (final channel in List.of(_channels)) {
      _bumpChannel(channel);
    }
  }

  Future<void> _initForegroundService() async {
    initForegroundService();
    await requestForegroundPermissions();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    PerfLog.I.record('LIFECYCLE', state.name);
    _isBackgrounded =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive;
    if (Platform.isAndroid) {
      if (state == AppLifecycleState.paused) {
        if (_backgroundService) {
          startForegroundService(List.of(_channels));
        }
      } else if (state == AppLifecycleState.resumed) {
        if (_backgroundService) {
          stopForegroundService();
        }
        if (_mentionPush) {
          _notificationService.clearMentionNotifications();
        }
      }
    }
    if (state == AppLifecycleState.resumed) {
      _chatConn.reconnectIfNecessary();
    }
  }

  static const _slowFrameThreshold = Duration(milliseconds: 100);
  static const _stallThreshold = Duration(milliseconds: 2000);
  int? _lastFrameBuildStartUs;

  /// Records slow builds and, more importantly, multi-second gaps between
  /// consecutive frame build starts: a hang shows up as a stall record
  /// followed by a burst of slow frames when the thread unblocks.
  void _onFrameTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final startUs = t.timestampInMicroseconds(FramePhase.buildStart);
      final last = _lastFrameBuildStartUs;
      if (last != null) {
        final gapMs = (startUs - last) ~/ 1000;
        if (gapMs > _stallThreshold.inMilliseconds) {
          PerfLog.I.record(
            'FRAME',
            'main-thread stall ${gapMs}ms before build',
          );
        }
      }
      _lastFrameBuildStartUs = startUs;
      if (t.buildDuration > _slowFrameThreshold) {
        PerfLog.I.record(
          'FRAME',
          'slow build ${t.buildDuration.inMilliseconds}ms '
          'raster ${t.rasterDuration.inMilliseconds}ms',
        );
      }
    }
  }

  Future<void> _saveChannels() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('channels', List.of(_channels));
  }

  void _reorderChannels(List<String> reordered) {
    _channels
      ..clear()
      ..addAll(reordered);
    _channelNotifier.value = List.of(_channels);
    if (_selectedChannel != null) {
      final newIdx = _channels.indexOf(_selectedChannel!);
      if (newIdx >= 0) _selectedTabIndex.value = newIdx;
    }
    if (mounted) setState(() {});
    _saveChannels();
  }

  // Fetch the account's Twitch block list before anything is shown so blocked
  // users never appear — not even briefly. Fail-open: chat shows normally if
  // the fetch fails, and a later login triggers a (guarded) retry.
  Future<void> _ensureBlockedUsersLoaded() async {
    if (_blocksFetched) return;
    final userId = widget.twitchAuth.userId;
    if (userId == null) {
      _blocksReady = true;
      _loadChannels();
      return;
    }
    _blocksFetched = true;
    try {
      final blocked = await _twitchApi
          .getBlockedUsers(widget.twitchAuth)
          .timeout(const Duration(seconds: 5));
      _blockedLogins.addAll(blocked);
    } catch (e) {
      logDebug('[HomeScreen] failed to fetch blocked users: $e');
    }
    if (!mounted) return;
    _blocksReady = true;
    _sweepBlockedMessages();
    _loadChannels();
    setState(() {});
  }

  void _sweepBlockedMessages() {
    for (final entry in _channelMessages.entries) {
      final msgs = entry.value;
      final before = msgs.length;
      msgs.removeWhere(
        (m) => !m.isSystem && _blockedLogins.contains(m.login.toLowerCase()),
      );
      if (msgs.length != before) _bumpChannel(entry.key);
    }
  }

  void _onUserBlocked(String login) {
    _blockedLogins.add(login.toLowerCase());
    _sweepBlockedMessages();
  }

  void _onUserUnblocked(String login) {
    _blockedLogins.remove(login.toLowerCase());
  }

  Future<void> _loadChannels() async {
    if (_channelsLoaded) return;
    _channelsLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('channels');
    if (saved == null || saved.isEmpty) return;
    for (final name in saved) {
      if (_channels.contains(name)) continue;
      _channels.add(name);
      _channelMessages.putIfAbsent(name, () => []);
      _atBottomNotifier(name).value = true;
    }
    _channelNotifier.value = List.of(_channels);
    _selectedChannel = _channels.first;
    _selectedTabIndex.value = 0;
    if (mounted) setState(() {});
    for (final name in saved) {
      _subscribeChannel(name);
      _recentMessages
          .fetchRecent(name, limit: _recentMessagesLimit)
          .then((history) {
            if (!mounted) return;
            _historyLoaded.add(name);
            setState(() {
              if (history.isEmpty) {
                _addSystemMessage(name, 'No chat history available');
              } else {
                _mergeHistoryIntoChannel(name, history);
              }
            });
            _maybeAddConnected(name);
          })
          .catchError((e) {
            if (!mounted) return;
            _historyLoaded.add(name);
            _addSystemMessage(name, 'Failed to load chat history ($e)');
            _maybeAddConnected(name);
          });
    }
  }

  // Merges robotty history into the channel message list (newest-first).
  // Messages whose messageId is already on screen are discarded as duplicates,
  // mentions are surfaced in the mentions panel, and a gap note is inserted at
  // the history boundary when the fetched window doesn't reach back to the
  // messages already displayed (only possible on reconnect re-fetches).
  //
  // The merged list is sorted by timestamp (DankChat-style) so re-fetched
  // history slots below messages that arrived after it — live messages are
  // never pushed under older history.
  void _mergeHistoryIntoChannel(String channel, List<TwitchMessage> history) {
    final sw = Stopwatch()..start();
    final existing = _channelMessages[channel]!;
    final existingSize = existing.length;
    final existingIds = existing.map((m) => m.messageId).toSet();
    var hasExistingNonSystem = false;
    for (final m in existing) {
      if (!m.isSystem) {
        hasExistingNonSystem = true;
        break;
      }
    }
    final insertedIds = <String?>{};
    var insertedCount = 0;
    for (final msg in history) {
      if (!msg.isSystem && msg.login.isNotEmpty) {
        final preferred =
            msg.displayName.toLowerCase() == msg.login.toLowerCase()
            ? msg.displayName
            : msg.login;
        _userStore.addUser(channel, preferred);
      }
      final id = msg.messageId;
      final isNew =
          id == null ||
          (!existingIds.contains(id) && !insertedIds.contains(id));
      if (isNew) {
        if (msg.isSystem && _currentUserLogin != null) {
          final selfLogin = _currentUserLogin!.toLowerCase();
          if (msg.login.toLowerCase() == selfLogin) {
            msg.text = msg.text.replaceFirst(
              RegExp(RegExp.escape(msg.login), caseSensitive: false),
              'You',
            );
            msg.text = msg.text.replaceFirst('was', 'were');
          }
        }
        if (id != null) insertedIds.add(id);
        existing.add(msg);
        insertedCount++;
      }
      if (msg.messageId != null) {
        _messageKeys.add('$channel:${msg.messageId}');
      }
      final login = _currentUserLogin?.toLowerCase();
      if (login != null && !msg.isHighlighted && isMentionOf(msg, login)) {
        msg.isHighlighted = true;
        _channelMessages.putIfAbsent(_mentionsChannel, () => []);
        final mentionList = _channelMessages[_mentionsChannel]!;
        final existingMentionIds = mentionList.map((m) => m.messageId).toSet();
        if (msg.messageId == null ||
            !existingMentionIds.contains(msg.messageId)) {
          mentionList.insert(0, msg);
        }
      }
    }
    if (hasExistingNonSystem &&
        insertedCount > 0 &&
        !history.any(
          (m) => m.messageId != null && existingIds.contains(m.messageId),
        )) {
      // 1ms before the oldest fetched message so the note sorts directly
      // below the history block.
      final oldestHistory = history
          .map((m) => m.timestamp)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      existing.add(
        TwitchMessage(
          login: '',
          text: 'History: Not all messages retrieved',
          isSystem: true,
          channel: channel,
          timestamp: oldestHistory.subtract(const Duration(milliseconds: 1)),
        ),
      );
    }
    // Chronological order, newest first (index 0 = newest).
    existing.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    _truncateChannelMessages(channel);
    _bumpChannel(channel);
    _moveConnectedMessageToTop(channel);
    sw.stop();
    PerfLog.I.record(
      'MERGE',
      '$channel history=${history.length} existing=$existingSize '
      'inserted=$insertedCount ${sw.elapsedMilliseconds}ms',
    );
  }

  void _onReconnected() {
    for (final channel in List.of(_channels)) {
      unawaited(_refetchHistory(channel));
    }
  }

  Future<void> _refetchHistory(String channel) async {
    if (!_historyLoaded.contains(channel) ||
        _refetchingChannels.contains(channel)) {
      return;
    }
    _refetchingChannels.add(channel);
    final sw = Stopwatch()..start();
    try {
      final history = await _recentMessages.fetchRecent(
        channel,
        limit: _recentMessagesLimit,
      );
      final fetchMs = sw.elapsedMilliseconds;
      if (!mounted || !_channels.contains(channel)) return;
      final existing = _channelMessages[channel];
      if (existing == null || history.isEmpty) return;
      PerfLog.I.record(
        'REFETCH',
        '$channel fetched=${history.length} existing=${existing.length} '
        'in ${fetchMs}ms',
      );
      // Messages recovered from history after a reconnect gap are marked as
      // backfill so they render greyed out, distinct from live chat.
      for (final msg in history) {
        msg.isBackfill = true;
      }
      setState(() {
        _mergeHistoryIntoChannel(channel, history);
      });
    } catch (e) {
      logDebug('[HomeScreen] history re-fetch failed for $channel: $e');
    } finally {
      _refetchingChannels.remove(channel);
    }
  }

  void _onInputFocusChanged() {
    if (_emoteSheetOpen) {
      unawaited(_closeEmoteSheet());
    }
  }

  void _onInputChanged() {
    _checkAutocompleteUndo();

    final text = _messageController.text;
    final cursor = _messageController.selection.baseOffset;
    final word = getCurrentWord(text, cursor);
    final isCommand = word.text.startsWith('/');
    var filterWord = word.text;
    if (isCommand) {
      filterWord = filterWord.substring(1);
    } else if (filterWord.startsWith('@') && filterWord.length >= 2) {
      filterWord = filterWord.substring(1);
    }
    if (filterWord.length < 2 && !isCommand) {
      if (_suggestionsNotifier.value.isNotEmpty) {
        _suggestionsNotifier.value = [];
      }
      _previousTextForUndo = _messageController.text;
      return;
    }
    final channel = _selectedChannel;
    if (channel == null) {
      _previousTextForUndo = _messageController.text;
      return;
    }

    final List<Suggestion> filtered;
    if (isCommand) {
      // All commands are suggested regardless of permissions; the API
      // rejects what the account cannot run (clean error notice shown).
      filtered = filterSuggestions(
        word: word.text,
        emotes: <GenericEmote>[],
        users: const <String>[],
        commands: CommandHandler.allCommands,
      );
    } else {
      final users = _userStore.usersForChannel(channel);
      final isMention = word.text.startsWith('@');
      final emotes = isMention
          ? <GenericEmote>[]
          : [
              ...?_emoteManager.byCode(channel)?.suggestions,
              // Subscriber emotes are global — usable in every channel, not
              // just the one they belong to.
              ..._emoteManager.subscriberEmotesByChannel().values.expand(
                (e) => e,
              ),
            ];
      filtered = filterSuggestions(
        word: filterWord,
        emotes: emotes,
        users: users,
        preferEmotesFirst: _preferEmotesFirst,
        recentEmoteIds: _emoteManager.recentEmoteIds,
      );
    }
    _suggestionsNotifier.value = filtered;
    _previousTextForUndo = _messageController.text;
  }

  void _onSuggestionSelected(Suggestion suggestion) {
    var replacement = switch (suggestion) {
      UserSuggestion() => suggestion.displayName,
      EmoteSuggestion() => suggestion.emote.code,
      CommandSuggestion() => suggestion.command,
    };

    final textBefore = _messageController.text;
    final cursorBefore = _messageController.selection.baseOffset;
    final wordBefore = getCurrentWord(textBefore, cursorBefore);

    if (suggestion is UserSuggestion) {
      if (wordBefore.text.startsWith('@')) {
        replacement = '@$replacement';
      }
    }

    final trailingSpace =
        wordBefore.end < textBefore.length && textBefore[wordBefore.end] == ' '
        ? ''
        : ' ';

    _lastAutoUndo = (
      start: wordBefore.start,
      originalText: wordBefore.text,
      replacementText: replacement + trailingSpace,
    );

    replaceCurrentWord(_messageController, replacement);

    final replEnd =
        wordBefore.start + replacement.length + trailingSpace.length;
    _undoExpectedAfter = _messageController.text.length > replEnd
        ? _messageController.text.substring(replEnd)
        : '';

    if (suggestion is EmoteSuggestion) {
      _emoteManager.markEmoteUsed(suggestion.emote);
    }
    _suggestionsNotifier.value = [];
    _focusNode.requestFocus();
  }

  // Detect a single backspace immediately after autocomplete and restore the
  // original typed text. Five sequential guards verify no other edits occurred.
  void _checkAutocompleteUndo() {
    final undo = _lastAutoUndo;
    if (undo == null) return;
    final prev = _previousTextForUndo;
    if (prev == null) return;

    final text = _messageController.text;
    final cursor = _messageController.selection.baseOffset;
    final replacementLen = undo.replacementText.length;
    final replEnd = undo.start + replacementLen;

    final minLen = text.length < replEnd ? text.length : replEnd;
    for (var i = undo.start; i < minLen; i++) {
      if (text.codeUnitAt(i) !=
          undo.replacementText.codeUnitAt(i - undo.start)) {
        _lastAutoUndo = null;
        _undoExpectedAfter = null;
        return;
      }
    }

    // Verify text after the replacement hasn't changed.
    final currentAfter = text.length > replEnd ? text.substring(replEnd) : '';
    final expectedAfter = _undoExpectedAfter ?? '';
    if (currentAfter != expectedAfter) {
      _lastAutoUndo = null;
      _undoExpectedAfter = null;
      return;
    }

    // Must be a single backspace.
    if (text.length != prev.length - 1) return;

    // Cursor must be right after the shortened replacement.
    if (cursor != replEnd - 1) return;

    // Region must match replacement minus its last char.
    final regionEnd = replEnd - 1;
    if (text.length < regionEnd) return;
    if (text.substring(undo.start, regionEnd) !=
        undo.replacementText.substring(0, replacementLen - 1)) {
      return;
    }

    // All checks passed. Undo.
    final before = text.substring(0, undo.start);
    final after = text.substring(regionEnd);
    _lastAutoUndo = null;
    _undoExpectedAfter = null;
    _messageController.value = TextEditingValue(
      text: before + undo.originalText + after,
      selection: TextSelection.collapsed(
        offset: undo.start + undo.originalText.length,
      ),
    );
  }

  void _onEmotesChanged() {
    // Emote data changed: cached message spans are validated against
    // EmoteManager.version, so no O(total messages) clear is needed here.
    // Just bump the affected channels so visible tiles lazily recompute.
    final channel = _emoteManager.consumeChangedChannel();
    if (channel != null) {
      // A live 7TV delta never re-renders existing messages: they keep the
      // emote state they were built with (no retroactive add/remove in chat),
      // and the sheet/autocomplete read the updated lists themselves. Only a
      // full refetch (no delta codes) clears the channel's tile cache.
      if (_emoteManager.consumeChangedCodes(channel) != null) return;
      _tileCache.remove(channel);
      _versionNotifier(channel).value++;
      _onPanelDataChanged(channel);
    } else {
      for (final c in List.of(_channels)) {
        _bumpChannel(c);
      }
      _mentionsBump.value++;
      _onPanelDataChanged();
    }
  }

  ValueNotifier<int> _versionNotifier(String channel) {
    return _chatVersions.putIfAbsent(channel, () => ValueNotifier(0));
  }

  ValueNotifier<int> _messageNotifier(String channel) {
    return _messageNotifiers.putIfAbsent(channel, () => ValueNotifier(0));
  }

  ValueNotifier<bool> _atBottomNotifier(String channel) {
    return _atBottomNotifiers.putIfAbsent(channel, () => ValueNotifier(true));
  }

  void _notifyNewMessage(String channel) {
    _messageNotifier(channel).value++;
    _onPanelDataChanged(channel);
  }

  void _bumpChannel(String channel) {
    _tileCache.remove(channel);
    _versionNotifier(channel).value++;
    _onPanelDataChanged(channel);
  }

  // Targeted tile invalidation: evict a single message (deletions, edits)
  // instead of clearing the whole channel cache. A null messageId is never
  // cached, so only the notify is needed to re-read the mutated message.
  void _invalidateMessage(String channel, String? messageId) {
    if (messageId != null) {
      _tileCache[channel]?.remove(messageId);
    }
    _messageNotifier(channel).value++;
  }

  void _onPanelDataChanged([String? changedChannel]) {
    if (_activePanel == OverlayPanel.closed) return;
    if (_activePanel == OverlayPanel.thread && _openThreadRoot != null) {
      // Skip recomputation unless the new message belongs to the open thread's
      // channel; the thread itself only mutates when that channel moves.
      if (changedChannel != null &&
          changedChannel != _openThreadRoot!.channel) {
        return;
      }
      final channel = _openThreadRoot!.channel!;
      _threadPanelData.value = ThreadPanelData(
        messages: _computeThreadMessages(),
        channel: channel,
      );
    } else if (_activePanel == OverlayPanel.mentions) {
      _mentionsPanelData.value = _channelMessages[_mentionsChannel] ?? [];
      _whispersPanelData.value = List.of(_whispers);
    }
  }

  void _onAuthChanged() {
    _emoteManager.accessToken = widget.twitchAuth.accessToken;
    _refreshEmotesAfterAuth();
    if (_currentUserLogin?.toLowerCase() !=
        widget.twitchAuth.login?.toLowerCase()) {
      // Account switched (or signed out): drop the cached user so the manager
      // re-resolves the active account and reconnects with its credentials.
      _currentUserLogin = null;
      _currentUserId = null;
      // The emote-set / block / mention caches are per-account: reset them so
      // the new account's USERSTATE re-fetches its sub emotes (instead of the
      // old account's set IDs being deduped out), blocks are re-fetched, the
      // retroactive mention scan re-runs, and channels re-resolve emotes with
      // the new token.
      _fetchedEmoteSetIds.clear();
      _inflightEmoteSetIds.clear();
      _emoteOwnerLogins.clear();
      _emoteOwnerLookupDone = false;
      _blocksFetched = false;
      // The previous account's block list must not keep filtering the new
      // account's chat; the re-fetch below repopulates it.
      _blockedLogins.clear();
      _mentionScanDone = false;
      _channelsEmotesResolved.clear();
      _scanHistoryForMentions();
      unawaited(_ensureBlockedUsersLoaded());
    }
    _chatConn.connect();
  }

  // Reads the persisted manual tier, auto mode, and disk-cache cap, then
  // applies them to the emote manager. Runs first in initState so emotes
  // resolve at the right tier; a persisted effective tier other than the
  // default high re-resolves caches because connect() may already have
  // fetched at the default.
  Future<void> _loadEmotePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _manualEmoteTierIndex =
          prefs.getInt(emoteFetchTierPrefsKey) ?? EmoteFetchTier.high.index;
      final autoIndex =
          prefs.getInt(emoteFetchAutoPrefsKey) ??
          defaultEmoteFetchAutoMode.index;
      // A corrupt/out-of-range persisted index would throw RangeError at
      // startup; fall back to the default instead.
      _emoteAutoMode =
          autoIndex >= 0 && autoIndex < EmoteFetchAutoMode.values.length
          ? EmoteFetchAutoMode.values[autoIndex]
          : defaultEmoteFetchAutoMode;
      final loadedCacheCap =
          prefs.getInt(emoteCacheMaxPrefsKey) ?? defaultEmoteCacheMax;
      _applyCacheCap(loadedCacheCap);
      await _refreshConnectivity();
      _reconcileEmoteTier();
    } catch (e) {
      logDebug('_loadEmotePrefs failed: $e');
    }
  }

  Future<void> _refreshConnectivity() async {
    // The service seeds itself in init() and corrects on later events, so
    // here we just read its cached state (avoiding a redundant plugin probe).
    _isMobile.value = _connectivityService.isMobile;
  }

  // Computes the effective tier from the manual tier + auto mode and applies
  // it if it changed. Called at launch, on manual/auto setting changes, and
  // on connectivity changes.
  void _reconcileEmoteTier() {
    final effective = effectiveEmoteFetchTier(
      manual: EmoteFetchTier.values[_manualEmoteTierIndex],
      auto: _emoteAutoMode,
      isMobile: _isMobile.value,
    );
    if (effective == _emoteManager.tier) return;
    _applyTier(effective);
  }

  void _applyEmoteTier(int index) {
    _manualEmoteTierIndex = index;
    _reconcileEmoteTier();
  }

  void _applyEmoteAutoMode(EmoteFetchAutoMode mode) {
    _emoteAutoMode = mode;
    _reconcileEmoteTier();
  }

  void _applyTier(EmoteFetchTier tier) {
    try {
      _emoteManager.tier = tier;
      if (tier == EmoteFetchTier.nothing) {
        // Rendering tier: wipe in-memory caches and render only whatever
        // survives on disk, never fetch.
        _emoteManager.evictGlobal();
        for (final c in _channels) {
          _emoteManager.evictChannel(c);
        }
        if (mounted) setState(() {});
      } else {
        // Re-resolve caches at the new tier's resolution; the tier tag on
        // persisted caches makes stale-resolution entries refetch.
        _emoteManager.evictGlobal();
        _emoteManager.preloadGlobalEmotes();
        for (final c in _channels) {
          _emoteManager.evictChannel(c);
          _emoteManager.resolveEmotes(c, _channelUserIds[c]);
        }
        if (mounted) setState(() {});
      }
    } catch (e) {
      logDebug('_applyTier failed: $e');
    }
  }

  void _applyCacheCap(int cap) {
    _emoteManager.cacheCap = cap;
  }

  Future<void> _refreshEmotesAfterAuth() async {
    try {
      for (final channel in _channels) {
        final userId = await _twitchApi.getUserId(widget.twitchAuth, channel);
        if (userId != null) {
          _channelUserIds[channel] = userId;
        }
      }
      _emoteManager.evictGlobal();
      _emoteManager.preloadGlobalEmotes();
      _badgeService.dispose();
      _badgeService.fetchGlobalBadges(widget.twitchAuth);
      for (final channel in _channels) {
        _emoteManager.evictChannel(channel);
        final userId = _channelUserIds[channel];
        if (userId != null) {
          _badgeService.fetchChannelBadges(widget.twitchAuth, userId, channel);
        }
      }
      await Future.wait(
        _channels.map(
          (c) => _emoteManager.resolveEmotes(c, _channelUserIds[c]),
        ),
      );
    } catch (e) {
      logDebug('_refreshEmotesAfterAuth failed: $e');
    }
    if (mounted) setState(() {});
  }

  // Manual "Reload emotes": clears the emote image cache on disk plus all
  // cached emote metadata, then re-fetches everything (list + images) for all
  // channels.
  Future<void> _reloadEmotes() async {
    try {
      await EmoteCacheManager().emptyCache();
    } catch (e) {
      logDebug('_reloadEmotes: cache clear failed: $e');
    }
    await _refreshEmotesAfterAuth();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Emotes reloaded')));
  }

  // Manual "Reconnect": brute-force teardown + reconnect of every socket.
  void _reconnect() {
    _chatConn.forceReconnect();
  }

  // Loads the account's subscriber emotes from the IRC emote-sets tag
  // (GLOBALUSERSTATE/USERSTATE), the authoritative source of which emote sets
  // the account can use (the Helix /chat/emotes/user endpoint omits certain
  // grants, e.g. bot accounts). USERSTATE is channel-scoped and stores the
  // fetched emotes directly under its channel; GLOBALUSERSTATE (null channel)
  // is the account-wide union and acts as a warm-up across open channels.
  // Set IDs are only marked fetched after a successful fetch, so a failed
  // fetch is retried by the next USERSTATE/GLOBALUSERSTATE.
  Future<void> _loadUserEmoteSets(
    String? channel,
    List<String> emoteSetIds,
  ) async {
    final auth = widget.twitchAuth;
    if (!auth.isConfigured) return;
    if (_emoteManager.tier == EmoteFetchTier.nothing) return;
    // Set "0" is Twitch's global emote set: it's already loaded by
    // preloadGlobalEmotes, so skip it here. Fetching it through this path
    // would duplicate global emotes into every per-channel cache and mislabel
    // them with whichever channel happens to be open.
    final newSetIds = emoteSetIds
        .where(
          (id) =>
              id != '0' &&
              !_fetchedEmoteSetIds.contains(id) &&
              !_inflightEmoteSetIds.contains(id),
        )
        .toList();
    if (newSetIds.isEmpty) return;
    _inflightEmoteSetIds.addAll(newSetIds);
    try {
      final byOwner = await TwitchEmoteProvider.fetchEmoteSets(
        newSetIds,
        accessToken: auth.accessToken,
        resolution: _emoteManager.tier.resolution!,
      );
      _fetchedEmoteSetIds.addAll(newSetIds);
      // Only the account's channel-owned sets are stored per channel. The
      // owner label is resolved from each set's owner_id to an open channel;
      // a set owned by a channel that isn't open must not be labeled with
      // whichever channel happens to be open (GLOBALUSERSTATE fans the union
      // of all the account's sets across every open channel).
      final perOwner = <String, List<GenericEmote>>{};
      for (final entry in byOwner.entries) {
        if (entry.key.isEmpty) continue;
        perOwner[entry.key] = entry.value;
      }
      if (perOwner.isEmpty) {
        logDebug(
          '_loadUserEmoteSets: ${newSetIds.length} sets fetched, no channel emotes',
        );
        return;
      }
      await _ensureEmoteOwnerLogins(perOwner.keys.toList());
      final targets = channel != null ? [channel] : List.of(_channels);
      if (targets.isEmpty) {
        logDebug('_loadUserEmoteSets: no channel targets (channel=$channel)');
        return;
      }
      final perChannel = <String, List<GenericEmote>>{};
      for (final target in targets) {
        perChannel[target] = <GenericEmote>[
          for (final entry in perOwner.entries)
            for (final e in entry.value)
              GenericEmote(
                id: e.id,
                code: e.code,
                type: e.type,
                url: e.url,
                url1x: e.url1x,
                url3x: e.url3x,
                isAnimated: e.isAnimated,
                scope: e.scope,
                tier: e.tier,
                emoteType: e.emoteType,
                ownerChannel: _emoteOwnerLogins[entry.key],
              ),
        ];
      }
      await _emoteManager.storeUserTwitchEmotes(perChannel);
    } catch (e) {
      logDebug('_loadUserEmoteSets failed: $e');
    } finally {
      // Leave successfully fetched IDs marked; failed IDs drop out of the
      // in-flight set so the next USERSTATE/GLOBALUSERSTATE retries them.
      _inflightEmoteSetIds.removeAll(
        newSetIds.where((id) => !_fetchedEmoteSetIds.contains(id)),
      );
    }
  }

  // Resolves sub-emote owner IDs to logins once per session: open channels
  // map directly, anything else goes through one batched Helix /users call.
  Future<void> _ensureEmoteOwnerLogins(List<String> ownerIds) async {
    if (_emoteOwnerLookupDone) return;
    _emoteOwnerLookupDone = true;
    // Seed from the open channels (login -> id), so they need no API call.
    for (final entry in _channelUserIds.entries) {
      _emoteOwnerLogins[entry.value] = entry.key;
    }
    final unknown = ownerIds
        .where((id) => !_emoteOwnerLogins.containsKey(id))
        .toSet()
        .toList();
    if (unknown.isEmpty) return;
    try {
      final resolved = await _twitchApi.getUserLoginsByIds(
        widget.twitchAuth,
        unknown,
      );
      _emoteOwnerLogins.addAll(resolved);
    } catch (e) {
      logDebug('_ensureEmoteOwnerLogins failed: $e');
    }
  }

  void _loadMaxMessages() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _maxMessagesPerChannel = prefs.getInt('max_messages_per_channel') ?? 200;
      _recentMessagesLimit = prefs.getInt('recent_messages_limit') ?? 100;
      _replyToRoot = prefs.getBool('reply_to_thread_root') ?? false;
      _preferEmotesFirst = prefs.getBool('prefer_emotes_first') ?? false;
      _showTimestamps = prefs.getBool(kShowTimestampsPrefKey) ?? true;
      _timestampFormat =
          prefs.getString(kTimestampFormatPrefKey) ?? kDefaultTimestampFormat;
      _chatFontSize = prefs.getDouble('chat_font_size') ?? 14.0;
      _checkeredMessages = prefs.getBool('checkered_messages') ?? false;
      _lineSeparator = prefs.getBool('line_separator') ?? false;
    });
  }

  void _loadAltPings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _altPings = prefs.getStringList('alt_pings') ?? _defaultAltPings;
  }

  @override
  void dispose() {
    final listener = _connectivityListener;
    if (listener != null) _connectivityService.removeListener(listener);
    _connectivityListener = null;
    _isMobile.dispose();
    _chatConn.dispose();
    unawaited(_ttsController.shutdown());
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.removeObserver(_predictiveBackHandler);
    _panelScaleCtrl.dispose();
    _widgetPageCtrl.dispose();
    _testWidgetsTimer?.cancel();
    _eventSub.dispose();
    _irc.dispose();
    _ircRead.dispose();
    _sevenTvClient.dispose();
    _emoteManager.removeListener(_onEmotesChanged);
    _emoteManager.dispose();
    widget.twitchAuth.removeListener(_onAuthChanged);
    _messageController.dispose();
    _focusNode.removeListener(_onInputFocusChanged);
    _focusNode.dispose();
    _threadSheetRatio.dispose();
    _mentionsSheetRatio.dispose();
    _emoteSheetCtrl.dispose();
    _mentionsTabCtrl.removeListener(_onMentionsTabChanged);
    _mentionsTabCtrl.dispose();
    _threadPanelScrollCtrl.dispose();
    _mentionsPanelScrollCtrl.dispose();
    _whispersPanelScrollCtrl.dispose();
    _threadPanelData.dispose();
    _mentionsPanelData.dispose();
    _whispersPanelData.dispose();
    for (final c in _scrollControllers.values) {
      c.dispose();
    }
    for (final n in _chatVersions.values) {
      n.dispose();
    }
    for (final n in _messageNotifiers.values) {
      n.dispose();
    }
    for (final n in _atBottomNotifiers.values) {
      n.dispose();
    }
    _tileCache.clear();
    _mentionsBump.dispose();
    _notificationTapSub?.cancel();
    _notificationService.dispose();
    super.dispose();
  }

  // Connection status lines are chronological entries, but a transient
  // "Disconnected" that is followed by a reconnect is folded into the
  // "Reconnected" line (one per reconnect), so a reconnection storm shows:
  // Connected, Reconnected, ..., Disconnected. Only a persistent outage (no
  // reconnect) renders as "Disconnected", and it never removes a prior
  // "Connected". Duplicate emissions are prevented upstream by the manager's
  // edge triggering, so each status event lands exactly once here.
  void _onHypeTrain(HypeTrainEvent event) {
    if (!mounted) return;
    setState(() {
      if (event.kind == 'end') {
        _hypeTrains.remove(event.channel);
      } else {
        _hypeTrains[event.channel] = event;
      }
    });
    _clampWidgetPage();
  }

  void _onPoll(PollEvent event) {
    if (!mounted) return;
    setState(() {
      if (event.kind == 'end') {
        _polls.remove(event.channel);
      } else {
        _polls[event.channel] = event;
      }
    });
    _clampWidgetPage();
  }

  void _onPrediction(PredictionEvent event) {
    if (!mounted) return;
    setState(() {
      if (event.kind == 'end') {
        _predictions.remove(event.channel);
      } else {
        _predictions[event.channel] = event;
      }
    });
    _clampWidgetPage();
  }

  // Dev toggle: feeds fake poll / prediction / hype train events into the
  // same state as the real EventSub pipeline so the cutout shows all three
  // cards with updating data. Stops and clears when the toggle is off.
  Future<void> _loadTestWidgets() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    if (prefs.getBool('test_chat_widgets') ?? false) {
      _startTestWidgets();
    } else {
      _stopTestWidgets();
    }
  }

  void _startTestWidgets() {
    _fakeTrainEndsAt = DateTime.now().add(const Duration(minutes: 5));
    _testWidgetsTimer?.cancel();
    _testWidgetsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickTestWidgets(),
    );
    _tickTestWidgets();
  }

  void _stopTestWidgets() {
    _testWidgetsTimer?.cancel();
    _testWidgetsTimer = null;
    if (!mounted) return;
    setState(() {
      _hypeTrains.clear();
      _polls.clear();
      _predictions.clear();
      _widgetsMinimized.clear();
    });
  }

  void _tickTestWidgets() {
    if (!mounted) return;
    final channel = _selectedChannel;
    if (channel == null) return;
    setState(() {
      _hypeTrains.clear();
      _polls.clear();
      _predictions.clear();

      _fakeProgress += 9;
      if (_fakeProgress >= _fakeGoal) {
        _fakeLevel++;
        _fakeGoal += 100;
        _fakeProgress = 0;
      }
      _hypeTrains[channel] = HypeTrainEvent(
        channel: channel,
        kind: 'progress',
        level: _fakeLevel,
        progress: _fakeProgress,
        total: _fakeGoal,
        expiresAt: _fakeTrainEndsAt,
        topContributions: [
          HypeTrainContribution(
            userName: 'fakebits',
            type: 'BITS',
            total: 5000,
          ),
          HypeTrainContribution(userName: 'fakesub', type: 'SUBS', total: 12),
        ],
      );

      _fakePollA += 3;
      _fakePollB += 2;
      _fakePollC += 1;
      _polls[channel] = PollEvent(
        channel: channel,
        kind: 'progress',
        title: 'Fake poll: what should we play?',
        choices: [
          PollChoice(title: 'Minecraft', votes: _fakePollA),
          PollChoice(title: 'Terraria', votes: _fakePollB),
          PollChoice(title: 'Stardew', votes: _fakePollC),
        ],
        status: 'ACTIVE',
      );

      _fakePredYes += 12;
      _fakePredNo += 5;
      _predictions[channel] = PredictionEvent(
        channel: channel,
        kind: 'progress',
        title: 'Fake prediction: will we win?',
        outcomes: [
          PredictionOutcome(
            title: 'Yes',
            users: _fakePredYes,
            channelPoints: 9000,
          ),
          PredictionOutcome(
            title: 'No',
            users: _fakePredNo,
            channelPoints: 4500,
          ),
        ],
        status: 'ACTIVE',
      );
    });
    _clampWidgetPage();
  }

  List<Widget> _widgetPagesFor(String channel) {
    final pages = <Widget>[];
    final poll = _polls[channel];
    if (poll != null) pages.add(PollCard(event: poll));
    final prediction = _predictions[channel];
    if (prediction != null) pages.add(PredictionCard(event: prediction));
    final hypeTrain = _hypeTrains[channel];
    if (hypeTrain != null) pages.add(HypeTrainCard(event: hypeTrain));
    return pages;
  }

  String _widgetLabelsFor(String channel) {
    final labels = <String>[];
    if (_polls.containsKey(channel)) labels.add('Poll');
    if (_predictions.containsKey(channel)) labels.add('Prediction');
    if (_hypeTrains.containsKey(channel)) labels.add('Hype Train');
    return labels.join(' / ');
  }

  Widget? _buildWidgetOverlay(String channel) {
    final pages = _widgetPagesFor(channel);
    if (pages.isEmpty) return null;
    if (_widgetsMinimized[channel] ?? false) {
      return ChatWidgetMinimizedBar(
        labels: _widgetLabelsFor(channel),
        onRestore: () => setState(() => _widgetsMinimized[channel] = false),
      );
    }
    return ChatWidgetCutout(
      pages: pages,
      controller: _widgetPageCtrl,
      onMinimize: () => setState(() => _widgetsMinimized[channel] = true),
    );
  }

  void _clampWidgetPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_widgetPageCtrl.hasClients) return;
      final channel = _selectedChannel;
      if (channel == null) return;
      final pages = _widgetPagesFor(channel).length;
      if (pages == 0) return;
      final idx = _widgetPageCtrl.page?.round() ?? 0;
      if (idx >= pages) {
        _widgetPageCtrl.jumpToPage(pages - 1);
      }
    });
  }

  void _resetWidgetPage() {
    if (_widgetPageCtrl.hasClients) _widgetPageCtrl.jumpToPage(0);
  }

  void _addSystemMessage(String channel, String text, {Color? accent}) {
    _channelMessages.putIfAbsent(channel, () => []);
    final msgs = _channelMessages[channel]!;

    const statusTexts = {
      'Connected',
      'Connected to IRC',
      'Disconnected',
      'Reconnected',
      'Chat reconnecting...',
    };
    if (statusTexts.contains(text)) {
      if (text == 'Connected' || text == 'Connected to IRC') {
        final hasPriorStatus = msgs.any(
          (m) => m.isSystem && statusTexts.contains(m.text),
        );
        text = hasPriorStatus ? 'Reconnected' : 'Connected';
      }
      final top = msgs.isEmpty ? null : msgs.first;
      if (text == 'Reconnected') {
        // The outage ended: fold the transient markers into this line rather
        // than leaving a bogus outage entry behind.
        msgs.removeWhere(
          (m) =>
              m.isSystem &&
              (m.text == 'Disconnected' || m.text == 'Chat reconnecting...'),
        );
        // The write and read sockets both report the recovery; keep a single
        // line instead of stacking duplicates.
        final newTop = msgs.isEmpty ? null : msgs.first;
        if (newTop != null && newTop.isSystem && newTop.text == 'Reconnected') {
          return;
        }
      } else if (text == 'Disconnected' || text == 'Chat reconnecting...') {
        // "Disconnected" is the dominant outage marker: it describes the whole
        // app being down, so "Chat reconnecting..." never replaces it.
        if (text == 'Chat reconnecting...') {
          final hasDisconnected = msgs.any(
            (m) => m.isSystem && m.text == 'Disconnected',
          );
          if (hasDisconnected) return;
          if (top != null && top.isSystem && top.text == text) return;
        } else {
          // A flapping socket must not pile up markers.
          if (top != null && top.isSystem && top.text == text) return;
          msgs.removeWhere(
            (m) => m.isSystem && m.text == 'Chat reconnecting...',
          );
        }
      }
    }

    msgs.insert(
      0,
      TwitchMessage(
        login: '',
        text: text,
        messageId: 'sys_${_nextSystemMessageId++}',
        isSystem: true,
        systemAccent: accent,
        channel: channel,
      ),
    );
    _truncateChannelMessages(channel);
    _notifyNewMessage(channel);
  }

  void _showMessageMenu(TwitchMessage msg) {
    final threadRoot = _findThreadRoot(msg);
    final hasThread = threadRoot != null;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply to message'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _replyToMsg = msg;
                  });
                  _focusNode.requestFocus();
                },
              ),
              if (hasThread)
                ListTile(
                  leading: const Icon(Icons.forum),
                  title: const Text('View thread'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showThreadView(threadRoot);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy message'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.text));
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: const Icon(Icons.more_horiz),
                title: const Text('More...'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showMoreMenu(msg);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showThreadMessageMenu(TwitchMessage msg) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy message'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.text));
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: const Icon(Icons.more_horiz),
                title: const Text('More...'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showMoreMenu(msg);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMoreMenu(TwitchMessage msg) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_all),
              title: const Text('Copy full message'),
              onTap: () {
                final ts = _showTimestamps
                    ? formatTimestamp(msg.timestamp, _timestampFormat)
                    : '';
                Clipboard.setData(
                  ClipboardData(
                    text: '$ts ${msg.formattedUsername}: ${msg.text}',
                  ),
                );
                Navigator.pop(ctx);
              },
            ),
            if (msg.messageId != null)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy message ID'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.messageId!));
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _maybeAddConnected(String channel) {
    _chatConn.maybeAddConnected(channel);
  }

  void _removeLoadingHistoryMessage(String channel) {
    _channelMessages[channel]?.removeWhere(
      (m) => m.isSystem && m.text == 'Loading chat history...',
    );
  }

  // "Connected" is emitted as soon as IRC is up, which is usually before
  // the robotty history fetch completes. History messages are then inserted
  // above it, so move the newest connect-state line ("Reconnected" on a
  // reconnect, otherwise "Connected") back to the most recent position to
  // stay visible.
  void _moveConnectedMessageToTop(String channel) {
    final msgs = _channelMessages[channel];
    if (msgs == null || msgs.length < 2) return;
    int idx = msgs.indexWhere((m) => m.isSystem && m.text == 'Reconnected');
    if (idx < 0) {
      idx = msgs.indexWhere(
        (m) =>
            m.isSystem &&
            (m.text == 'Connected' || m.text == 'Connected to IRC'),
      );
    }
    if (idx <= 0) return;
    final msg = msgs.removeAt(idx);
    msgs.insert(0, msg);
    _bumpChannel(channel);
  }

  Future<void> _addChannel(String channelName) async {
    final name = channelName.trim().toLowerCase();
    if (name.isEmpty || _channels.contains(name)) return;

    setState(() {
      _channels.add(name);
      _channelNotifier.value = List.of(_channels);
      _channelMessages.putIfAbsent(name, () => []);
      _atBottomNotifier(name).value = true;
      _selectedChannel = name;
      _selectedTabIndex.value = _channels.length - 1;
    });
    _saveChannels();
    _focusNode.requestFocus();

    final loadingMsg = TwitchMessage(
      login: '',
      text: 'Loading chat history...',
      isSystem: true,
      channel: name,
    );
    _channelMessages[name]!.insert(0, loadingMsg);

    _recentMessages
        .fetchRecent(name, limit: _recentMessagesLimit)
        .then((history) {
          if (!mounted) return;
          _historyLoaded.add(name);
          setState(() {
            _removeLoadingHistoryMessage(name);
            if (history.isEmpty) {
              _addSystemMessage(name, 'No chat history available');
            } else {
              _mergeHistoryIntoChannel(name, history);
            }
          });
          _maybeAddConnected(name);
        })
        .catchError((e) {
          if (!mounted) return;
          _historyLoaded.add(name);
          setState(() {
            _removeLoadingHistoryMessage(name);
            _addSystemMessage(name, 'Failed to load chat history ($e)');
          });
          _maybeAddConnected(name);
        });

    logDebug('[HomeScreen] joining channel: $name');
    await _subscribeChannel(name);

    if (mounted) setState(() {});
  }

  Future<void> _subscribeChannel(String channelName) async {
    _chatConn.subscribeChannel(channelName);
  }

  void _addChannelDialog() {
    showJoinChannelDialog(context, onJoin: _addChannel);
  }

  void _removeChannel(String channel) {
    _chatConn.stopChatStatusTimer(channel);
    _analytics.resetChannel(channel);
    _irc.part(channel);
    _ircRead.part(channel);
    _emoteManager.evictChannel(channel);
    _badgeService.clearChannel(channel);
    _channelsEmotesResolved.remove(channel);
    _historyLoaded.remove(channel);
    _channelUserIds.remove(channel);
    _lastSentWireText.remove(channel);
    _chatStatus.remove(channel);
    _hypeTrains.remove(channel);
    _polls.remove(channel);
    _predictions.remove(channel);
    _widgetsMinimized.remove(channel);
    // Per-channel notifiers and tile state must die with the channel: a
    // re-joined channel would otherwise reuse stale notifiers and an old
    // frozen snapshot, and the maps would grow for the session.
    _chatVersions.remove(channel)?.dispose();
    _messageNotifiers.remove(channel)?.dispose();
    _atBottomNotifiers.remove(channel)?.dispose();
    _tileCache.remove(channel);
    _frozenSnapshot.remove(channel);
    setState(() {
      _channels.remove(channel);
      _channelNotifier.value = List.of(_channels);
      _channelMessages.remove(channel);
      _userStore.removeChannel(channel);
      _scrollControllers.remove(channel)?.dispose();
      _channelsWithUnread.remove(channel);
      _channelsWithUnreadMentions.remove(channel);
      final removedUnread = _unreadMentionsPerChannel.remove(channel) ?? 0;
      if (removedUnread > 0) {
        _unreadMentions -= removedUnread;
        if (_unreadMentions < 0) _unreadMentions = 0;
      }
      _messageKeys.removeWhere((k) => k.startsWith('$channel:'));
      if (_selectedChannel == channel) {
        _selectedChannel = _channels.isNotEmpty ? _channels.last : null;
        if (_channels.isNotEmpty) {
          _selectedTabIndex.value = _channels.length - 1;
        }
      }
    });
    _saveChannels();
  }

  void _sendMessage() {
    if (_suggestionsNotifier.value.isNotEmpty) {
      _suggestionsNotifier.value = [];
    }

    final text = _messageController.text.trim();
    final channel = _selectedChannel;
    if (text.isEmpty || channel == null) {
      return;
    }

    if (!widget.twitchAuth.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect an account to chat')),
      );
      return;
    }

    // In the Whispers tab the box composes whispers: slash commands (incl.
    // /w) go through the command handler, plain text replies to the latest
    // whisper partner.
    if (_isWhispersTabActive) {
      if (text.startsWith('/')) {
        _lastSentText = text;
        _messageController.clear();
        _doSendMessage(text, channel);
      } else if (_whisperTarget != null) {
        _lastSentText = text;
        _messageController.clear();
        unawaited(
          _commandHandler.handle(
            '/w $_whisperTarget $text',
            channel,
            widget.twitchAuth,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Type /w <username> <message> to whisper'),
          ),
        );
      }
      return;
    }

    // The Mentions tab of the panel stays read-only.
    if (_activePanel == OverlayPanel.mentions) {
      return;
    }

    _lastSentText = text;
    _messageController.clear();

    final threadRoot = _openThreadRoot;
    if (threadRoot != null) {
      final threadMsgs = _computeThreadMessages();
      final TwitchMessage? replyTo;
      if (_replyToRoot) {
        final rootId = threadRoot.replyThreadRootId ?? threadRoot.messageId;
        replyTo = threadMsgs.firstWhere(
          (m) => m.messageId == rootId,
          orElse: () => TwitchMessage(
            login: '',
            text: '',
            messageId: rootId,
            channel: channel,
          ),
        );
      } else {
        replyTo = threadMsgs.isNotEmpty ? threadMsgs.last : null;
      }
      _doSendMessage(text, channel, replyTo: replyTo);
    } else {
      _doSendMessage(text, channel);
    }
  }

  void _doSendMessage(
    String text,
    String channel, {
    TwitchMessage? replyTo,
  }) async {
    _chatConn.doSendMessage(text, channel, replyTo: replyTo);
  }

  void _onSendLongPress() {
    if (_lastSentText != null && _lastSentText!.isNotEmpty) {
      _messageController.text = _lastSentText!;
      _messageController.selection = TextSelection.fromPosition(
        TextPosition(offset: _messageController.text.length),
      );
      _focusNode.requestFocus();
    }
  }

  void _openSettings() {
    _focusNode.unfocus();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          twitchAuth: widget.twitchAuth,
          onThemeChanged: (mode) {
            _tileCache.clear();
            widget.onThemeChanged(mode);
          },
          onKeepScreenOnChanged: widget.onKeepScreenOnChanged,
          onTrueDarkChanged: (value) {
            _tileCache.clear();
            widget.onTrueDarkChanged?.call(value);
          },
          onAccentColorChanged: (name) {
            _tileCache.clear();
            widget.onAccentColorChanged?.call(name);
          },
          onBackgroundServiceChanged: _setBackgroundService,
          onMentionPushChanged: _setMentionPush,
          onMaxMessagesPerChannelChanged: _setMaxMessagesPerChannel,
          onRecentMessagesChanged: _setRecentMessagesLimit,
          onReplyToRootChanged: _setReplyToRoot,
          onPreferEmotesFirstChanged: _setPreferEmotesFirst,
          onShowTimestampsChanged: _setShowTimestamps,
          onTimestampFormatChanged: _setTimestampFormat,
          onChatFontScaleChanged: _setChatFontScale,
          onCheckeredMessagesChanged: _setCheckeredMessages,
          onLineSeparatorChanged: _setLineSeparator,
          onEmoteTierChanged: _applyEmoteTier,
          onEmoteCacheMaxChanged: _applyCacheCap,
          onEmoteAutoModeChanged: _applyEmoteAutoMode,
          mobileNotifier: _isMobile,
          channelNotifier: _channelNotifier,
          onLeaveChannel: _removeChannel,
          onAddChannel: _addChannel,
          onReorderChannels: _reorderChannels,
          analyticsService: _analytics,
          channels: _channels,
          ttsController: _ttsController,
        ),
      ),
    ).then((_) {
      _loadAltPings();
      _loadMaxMessages();
      _loadTestWidgets();
      _tileCache.clear();
      if (mounted) setState(() {});
    });
  }

  /// Handles slash commands by routing to the appropriate Twitch API endpoint.
  Future<void> _handleCommand(
    String text,
    String channel,
    TwitchAuth auth,
  ) async {
    try {
      await _commandHandler.handle(text, channel, auth);
    } catch (e) {
      logDebug('[HomeScreen] command failed: $e');
      _addSystemMessage(channel, 'Command failed: $e');
    }
  }

  ScrollController _scrollCtrl(String channel) {
    return _scrollControllers.putIfAbsent(channel, () => ScrollController());
  }

  // Walk the reply-parent chain to the root with cycle detection (visited set).
  // A message that has children is treated as root even if it has a parent
  // (handles nested reply scenarios).
  TwitchMessage? _findThreadRoot(TwitchMessage msg) {
    if (msg.replyThreadRootId != null) return msg;

    final channel = msg.channel;
    if (channel == null) return null;
    final msgs = _channelMessages[channel];
    if (msgs == null) return null;

    if (msg.messageId != null &&
        msgs.any((m) => m.replyToParentId == msg.messageId)) {
      return msg;
    }

    if (msg.replyToParentId == null) return null;

    final visited = <String>{};
    TwitchMessage current = msg;
    while (current.replyToParentId != null &&
        visited.add(current.replyToParentId!)) {
      final parent = msgs
          .where((m) => m.messageId == current.replyToParentId)
          .firstOrNull;
      if (parent == null) break;
      current = parent;
    }
    return current;
  }

  Future<void> _showThreadView(TwitchMessage rootMsg) async {
    final channel = rootMsg.channel;
    if (channel == null) return;
    await _closePanel();
    if (_selectedChannel != channel) {
      final idx = _channels.indexOf(channel);
      if (idx >= 0) _onChannelChanged(idx);
    }
    setState(() {
      _activePanel = OverlayPanel.thread;
      _openThreadRoot = rootMsg;
    });
    _threadPanelData.value = ThreadPanelData(
      messages: _computeThreadMessages(),
      channel: channel,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _animateRatio(
          _threadSheetRatio,
          0.0,
          _fullHeightFraction,
          _sheetAnimDuration,
        );
      }
    });
  }

  Future<void> _showMentionsView() async {
    await _closePanel();
    _focusNode.unfocus();
    setState(() {
      _activePanel = OverlayPanel.mentions;
      _openThreadRoot = null;
    });
    _mentionsPanelData.value = _channelMessages[_mentionsChannel] ?? [];
    _whispersPanelData.value = List.of(_whispers);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _animateRatio(
          _mentionsSheetRatio,
          0.0,
          _fullHeightFraction,
          _sheetAnimDuration,
        );
      }
    });
  }

  void _showEmoteMenu() {
    // Kick emote resolution for the current channel + globals if the menu is
    // opened before the join-time rake finished (cold start), so the grids
    // aren't stuck on empty states until the next manager notify.
    final channel = _selectedChannel;
    if (channel != null && !_emoteManager.hasChannelCache(channel)) {
      unawaited(_emoteManager.resolveEmotes(channel, _channelUserIds[channel]));
    }
    if (!_emoteManager.hasGlobalCache) {
      unawaited(_emoteManager.preloadGlobalEmotes());
    }
    setState(() => _emoteSheetOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _emoteSheetCtrl.isAttached) {
        _emoteSheetCtrl.animateTo(
          _emoteMaxFraction,
          duration: _sheetAnimDuration,
          curve: Curves.easeInOutCubicEmphasized,
        );
      }
    });
  }

  Future<void> _closeEmoteSheet() async {
    if (!_emoteSheetOpen) return;
    if (_emoteSheetCtrl.isAttached) {
      // Scale the close duration by how open the sheet is, so a near-closed
      // sheet dismisses quickly while a fully-open one eases down.
      final fraction = (_emoteSheetCtrl.size / _emoteMaxFraction).clamp(
        0.0,
        1.0,
      );
      final duration = Duration(milliseconds: (80 + 180 * fraction).round());
      await _emoteSheetCtrl.animateTo(
        0.0,
        duration: duration,
        curve: Curves.easeInOutCubicEmphasized,
      );
    }
    if (mounted) {
      setState(() {
        _emoteSheetOpen = false;
        _panelScaleCtrl.value = 1.0;
      });
    }
  }

  void _handlePanelBack() {
    if (_emoteSheetOpen) {
      unawaited(_closeEmoteSheet());
    } else {
      unawaited(_closePanel());
    }
  }

  void _onEmoteSelected(GenericEmote emote) {
    final text = _messageController.text;
    final pos = _messageController.selection.baseOffset;
    final insertPos = pos.clamp(0, text.length);
    _messageController.text =
        '${text.substring(0, insertPos)}${emote.code} ${text.substring(insertPos)}';
    _messageController.selection = TextSelection.collapsed(
      offset: insertPos + emote.code.length + 1,
    );
    _emoteManager.markEmoteUsed(emote);
  }

  Future<void> _closePanel() async {
    final panelToClose = _activePanel;
    if (panelToClose == OverlayPanel.closed && !_emoteSheetOpen) return;
    await _closeEmoteSheet();
    if (panelToClose == OverlayPanel.closed) {
      if (mounted) setState(() {});
      return;
    }
    if (panelToClose == OverlayPanel.thread) {
      await _animateRatio(
        _threadSheetRatio,
        _threadSheetRatio.value,
        0.0,
        _sheetCloseDuration,
      );
    } else if (panelToClose == OverlayPanel.mentions) {
      await _animateRatio(
        _mentionsSheetRatio,
        _mentionsSheetRatio.value,
        0.0,
        _sheetCloseDuration,
      );
    }
    if (mounted) {
      setState(() {
        _activePanel = OverlayPanel.closed;
        _openThreadRoot = null;
        _threadPanelData.value = null;
        _mentionsPanelData.value = null;
        _panelScaleCtrl.value = 1.0;
      });
    }
  }

  Future<void> _animateRatio(
    ValueNotifier<double> ratio,
    double from,
    double to,
    Duration duration,
  ) async {
    if (from == to) return;
    final controller = AnimationController(vsync: this, duration: duration);
    final animation = Tween(
      begin: from,
      end: to,
    ).animate(CurvedAnimation(parent: controller, curve: Curves.easeOutCubic));
    void listener() {
      ratio.value = animation.value;
    }

    animation.addListener(listener);
    await controller.forward();
    animation.removeListener(listener);
    controller.dispose();
  }

  Widget _buildPanelDragHandle({
    required ValueNotifier<double> ratio,
    required double maxSize,
    required VoidCallback onClose,
    required VoidCallback onSnap,
    Widget? header,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (details) {
        _panelDragStartRatio = ratio.value;
        _panelDragStartY = details.globalPosition.dy;
      },
      onVerticalDragUpdate: (details) {
        final cumulativeDelta = details.globalPosition.dy - _panelDragStartY;
        final height =
            maxSize *
            (MediaQuery.of(context).size.height -
                MediaQuery.of(context).padding.top -
                MediaQuery.viewInsetsOf(context).bottom);
        ratio.value = (_panelDragStartRatio - cumulativeDelta / height).clamp(
          0.0,
          maxSize,
        );
      },
      onVerticalDragEnd: (details) {
        if (shouldCloseSheet(
          fraction: ratio.value / maxSize,
          velocity: details.primaryVelocity ?? 0,
        )) {
          onClose();
        } else {
          onSnap();
        }
      },
      // The whole header strip (handle + title row + divider) is the drag
      // surface, so a swipe-down starting anywhere above the list moves the
      // sheet. The detector only registers vertical drags, so taps on the
      // close button keep working.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            color: Colors.transparent,
            padding: const EdgeInsets.only(top: 10, bottom: 28),
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          ?header,
        ],
      ),
    );
  }

  Widget _buildOverlaySheet({
    required bool offstage,
    required ValueNotifier<double> ratio,
    required Widget header,
    required Widget body,
  }) {
    return Positioned(
      top: MediaQuery.of(context).padding.top,
      bottom: 0,
      left: 0,
      right: 0,
      child: Offstage(
        offstage: offstage,
        child: ScaleTransition(
          scale: _panelScaleCtrl,
          alignment: Alignment.bottomCenter,
          child: _buildSheetPanel(
            ratio: ratio,
            child: RepaintBoundary(
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                clipBehavior: Clip.hardEdge,
                child: Column(
                  children: [
                    _buildPanelDragHandle(
                      ratio: ratio,
                      maxSize: _fullHeightFraction,
                      onClose: _closePanel,
                      onSnap: () => _animateRatio(
                        ratio,
                        ratio.value,
                        _fullHeightFraction,
                        _sheetAnimDuration,
                      ),
                      header: header,
                    ),
                    Expanded(child: body),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSheetPanel({
    required ValueNotifier<double> ratio,
    required Widget child,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.bottomCenter,
            minHeight: height,
            maxHeight: height,
            child: AnimatedBuilder(
              animation: ratio,
              builder: (context, child) {
                final closedFraction = (1.0 - ratio.value).clamp(0.0, 1.0);
                return FractionalTranslation(
                  translation: Offset(0, closedFraction),
                  child: child!,
                );
              },
              child: child,
            ),
          ),
        );
      },
    );
  }

  /// Wraps [child] so it renders at its full expanded height and translates
  /// vertically as the sheet opens/closes — true slide-up/down motion.
  ///
  /// At size = 0 the content is shifted down by its full height (invisible
  /// below the viewport). As the sheet grows to [maxSize] the content rises
  /// into view, bottom-anchored.
  ///
  /// [totalAvailH] is the pixel height of the Positioned area that the sheet
  /// occupies. Captured once per layout from a LayoutBuilder wrapping the sheet.
  ///
  /// Uses [OverflowBox] so the child always lays out at full height regardless
  /// of sheet box size, preventing Column overflow during animation. [ClipRect]
  /// clips to the sheet box boundary. [AnimatedBuilder] and [FractionalTranslation]
  /// drive the per-frame offset.
  Widget _buildSlideUpContent({
    required DraggableScrollableController controller,
    required double totalAvailH,
    required double maxSize,
    required Widget child,
  }) {
    final contentH = maxSize * totalAvailH;
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.bottomCenter,
        minHeight: contentH,
        maxHeight: contentH,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, child) {
            final size = controller.isAttached ? controller.size : 0.0;
            final closedFraction = maxSize <= 0
                ? 0.0
                : (1 - (size / maxSize)).clamp(0.0, 1.0);
            return FractionalTranslation(
              translation: Offset(0, closedFraction),
              child: child!,
            );
          },
          child: child,
        ),
      ),
    );
  }

  List<TwitchMessage> _computeThreadMessages() {
    final entry = _openThreadRoot;
    if (entry == null) return const [];
    final channel = entry.channel;
    if (channel == null) return const [];
    final allMsgs = _channelMessages[channel] ?? [];

    final entryKey = entry.replyThreadRootId ?? entry.messageId;
    if (entryKey == null) return const [];

    final parentOf = <String, String>{};
    for (final m in allMsgs) {
      if (m.replyToParentId != null && m.messageId != null) {
        parentOf[m.messageId!] = m.replyToParentId!;
      }
    }

    final resolvedKey = threadKeyFor(entry, parentOf);

    final threadMsgs = allMsgs
        .where((m) => threadKeyFor(m, parentOf) == resolvedKey)
        .toList();

    threadMsgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return threadMsgs;
  }

  void _showUserProfile(
    String username,
    String? userId, {
    String? displayName,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => UserProfileSheet(
        username: username,
        displayName: displayName ?? username,
        userId: userId,
        twitchApi: _twitchApi,
        twitchAuth: widget.twitchAuth,
        messageController: _messageController,
        focusNode: _focusNode,
        onClose: () => Navigator.pop(ctx),
        onUserBlocked: _onUserBlocked,
        onWhisperUser: () => _showWhispersForUser(username),
      ),
    );
  }

  void _showEmoteSheet(List<GenericEmote> emotes) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => EmoteSheet(
        emotes: emotes,
        messageController: _messageController,
        focusNode: _focusNode,
        onClose: () => Navigator.pop(ctx),
      ),
    );
  }

  void _onMentionNotification(String channel, TwitchMessage msg) {
    if (!_mentionPush) return;
    if (!_isBackgrounded) return;
    if (msg.isHistory) return;
    _notificationService.showMentionNotification(
      channel: channel,
      userName: msg.displayName,
      message: msg.text,
    );
  }

  bool get _isWhispersTabActive =>
      _activePanel == OverlayPanel.mentions && _mentionsTabCtrl.index == 1;

  void _onWhisper(TwitchMessage msg) {
    if (!mounted) return;
    _whispers.insert(0, msg);
    if (_whispers.length > _maxMessagesPerChannel) {
      _whispers.removeRange(_maxMessagesPerChannel, _whispers.length);
    }
    _whisperTarget = msg.login;
    _whispersPanelData.value = List.of(_whispers);
    if (!_isWhispersTabActive) {
      _unreadWhispers++;
      _unreadMentions++;
    }
    _mentionsBump.value++;
  }

  void _addWhisperSystemMessage(String channel, String text) {
    _whispers.insert(
      0,
      TwitchMessage(login: '', text: text, isSystem: true, channel: null),
    );
    if (_whispers.length > _maxMessagesPerChannel) {
      _whispers.removeRange(_maxMessagesPerChannel, _whispers.length);
    }
    _whispersPanelData.value = List.of(_whispers);
    _mentionsBump.value++;
  }

  void _onWhisperSent(String target, String message) {
    final login = _currentUserLogin;
    if (login == null) return;
    _whisperTarget = target;
    _whispers.insert(
      0,
      TwitchMessage(
        login: login,
        displayName: login,
        text: message,
        channel: null,
      ),
    );
    if (_whispers.length > _maxMessagesPerChannel) {
      _whispers.removeRange(_maxMessagesPerChannel, _whispers.length);
    }
    _whispersPanelData.value = List.of(_whispers);
    _mentionsBump.value++;
  }

  void _onMentionsTabChanged() {
    // TabController notifies on every animation tick while a swipe is in
    // progress; rebuilding the whole screen per frame is wasted work.
    if (_mentionsTabCtrl.indexIsChanging) return;
    if (_mentionsTabCtrl.index == 1 && _unreadWhispers > 0) {
      _unreadMentions -= _unreadWhispers;
      if (_unreadMentions < 0) _unreadMentions = 0;
      _unreadWhispers = 0;
      _mentionsBump.value++;
    }
    setState(() {});
  }

  void _showWhispersForUser(String login) {
    _whisperTarget = login;
    if (_activePanel != OverlayPanel.mentions) {
      _showMentionsView();
    }
    _mentionsTabCtrl.animateTo(1);
    _unreadMentions -= _unreadWhispers;
    if (_unreadMentions < 0) _unreadMentions = 0;
    _unreadWhispers = 0;
    _mentionsBump.value++;
    _focusNode.requestFocus();
  }

  void _onNotificationTap(String channel) {
    _navigateToChannel(channel);
  }

  void _navigateToChannel(String channel) {
    final index = _channels.indexOf(channel);
    if (index >= 0) {
      _onChannelChanged(index);
    }
  }

  void _onChannelFocusChanged(int index) {
    final channel = _channels[index];
    if (_selectedChannel == channel) return;
    unawaited(_closePanel());
    _selectedChannel = channel;
    _channelsWithUnread.remove(channel);
    _channelsWithUnreadMentions.remove(channel);
    final cleared = _unreadMentionsPerChannel.remove(channel) ?? 0;
    if (cleared > 0) {
      _unreadMentions -= cleared;
      if (_unreadMentions < 0) _unreadMentions = 0;
      // Focus changes (swipes) skip the _onChannelChanged setState path, so
      // bump the bell's notifier to refresh the badge color.
      _mentionsBump.value++;
    }
    _openThreadRoot = null;
    if (_suggestionsNotifier.value.isNotEmpty) {
      _suggestionsNotifier.value = [];
    }
    _resetWidgetPage();
    _selectedTabIndex.value = index;
  }

  void _onChannelChanged(int index) {
    final channel = _channels[index];
    if (_selectedChannel == channel) return;
    unawaited(_closePanel());
    setState(() {
      _selectedChannel = channel;
      _channelsWithUnread.remove(channel);
      _channelsWithUnreadMentions.remove(channel);
      final cleared = _unreadMentionsPerChannel.remove(channel) ?? 0;
      if (cleared > 0) {
        _unreadMentions -= cleared;
        if (_unreadMentions < 0) _unreadMentions = 0;
      }
      _openThreadRoot = null;
      if (_suggestionsNotifier.value.isNotEmpty) {
        _suggestionsNotifier.value = [];
      }
    });
    _resetWidgetPage();
    _selectedTabIndex.value = index;
  }

  // Retroactive mention scan: runs once on login. Messages inserted at front
  // of mentions channel in scan order (reverse-chronological within each
  // channel), so they appear newest-first but may not be perfectly sorted.
  void _scanHistoryForMentions() {
    if (_mentionScanDone || _currentUserLogin == null) return;
    _mentionScanDone = true;
    final login = _currentUserLogin!.toLowerCase();
    for (final entry in _channelMessages.entries) {
      if (entry.key == _mentionsChannel) continue;
      for (final msg in entry.value) {
        if (msg.isHighlighted || !isMentionOf(msg, login)) continue;
        msg.isHighlighted = true;
        _channelMessages.putIfAbsent(_mentionsChannel, () => []);
        _channelMessages[_mentionsChannel]!.insert(0, msg);
      }
    }
  }

  void _truncateChannelMessages(String channel) {
    _chatConn.truncateChannelMessages(channel);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop:
          _activePanel == OverlayPanel.closed &&
          !_emoteSheetOpen &&
          !_focusNode.hasFocus,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_emoteSheetOpen) {
          unawaited(_closeEmoteSheet());
        } else if (_activePanel != OverlayPanel.closed) {
          unawaited(_closePanel());
        } else {
          _focusNode.unfocus();
          setState(() {});
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final statusBarH = MediaQuery.of(context).padding.top;
                  if (MediaQuery.viewInsetsOf(context).bottom == 0) {
                    _emoteSheetBoxHeight = constraints.maxHeight;
                  }
                  final fullBoxH =
                      (_emoteSheetBoxHeight ?? constraints.maxHeight) -
                      statusBarH;
                  // Squash the box only when the keyboard is taller than the
                  // anticipated gap, so the sheet (0.6 of the box) never
                  // extends past the top of the current Stack.
                  final maxFitBoxH =
                      (constraints.maxHeight - statusBarH) / _emoteMaxFraction;
                  final sheetBoxHeight = fullBoxH < maxFitBoxH
                      ? fullBoxH
                      : maxFitBoxH;
                  return Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Column(
                        children: [
                          ColoredBox(
                            color: theme.colorScheme.surfaceContainer,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SafeArea(
                                  bottom: false,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    child: Row(
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 8,
                                          ),
                                          child: Text(
                                            'ErmChat',
                                            style: TextStyle(
                                              fontSize: 22,
                                              fontWeight: FontWeight.w400,
                                            ),
                                          ),
                                        ),
                                        const Spacer(),
                                        IconButton(
                                          icon: const Icon(Icons.add),
                                          tooltip: 'Join channel',
                                          onPressed: _addChannelDialog,
                                        ),
                                        ListenableBuilder(
                                          listenable: _mentionsBump,
                                          builder: (context, _) => IconButton(
                                            icon: Icon(
                                              Icons.notifications_active,
                                              color: _unreadMentions > 0
                                                  ? theme.colorScheme.error
                                                  : null,
                                            ),
                                            tooltip: 'Mentions',
                                            onPressed: () {
                                              _unreadMentions = 0;
                                              _unreadWhispers = 0;
                                              _channelsWithUnreadMentions
                                                  .clear();
                                              _unreadMentionsPerChannel.clear();
                                              if (mounted) setState(() {});
                                              if (_activePanel ==
                                                  OverlayPanel.mentions) {
                                                unawaited(_closePanel());
                                              } else {
                                                _showMentionsView();
                                              }
                                            },
                                          ),
                                        ),
                                        PopupMenuButton<String>(
                                          popUpAnimationStyle:
                                              const AnimationStyle(
                                                duration: Duration(
                                                  milliseconds: 175,
                                                ),
                                              ),
                                          onSelected: (value) {
                                            switch (value) {
                                              case 'upload':
                                                _uploadController.pickAndUpload(
                                                  context,
                                                );
                                                break;
                                              case 'reload_emotes':
                                                _reloadEmotes();
                                                break;
                                              case 'reconnect':
                                                _reconnect();
                                                break;
                                              case 'settings':
                                                _openSettings();
                                                break;
                                            }
                                          },
                                          itemBuilder: (_) => const [
                                            PopupMenuItem(
                                              value: 'settings',
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    Icons.settings,
                                                    size: 20,
                                                  ),
                                                  SizedBox(width: 12),
                                                  Text('Settings'),
                                                ],
                                              ),
                                            ),
                                            PopupMenuDivider(),
                                            PopupMenuItem(
                                              value: 'upload',
                                              child: Text('Upload media'),
                                            ),
                                            PopupMenuItem(
                                              value: 'reload_emotes',
                                              child: Text('Reload emotes'),
                                            ),
                                            PopupMenuItem(
                                              value: 'reconnect',
                                              child: Text('Reconnect'),
                                            ),
                                          ],
                                          // Long-press on the 3-dot button
                                          // fast-tracks straight to Settings;
                                          // a quick tap opens the overflow
                                          // menu. The long-press sits on the
                                          // button's child (innermost in the
                                          // hit-test path) so it wins the
                                          // gesture arena over the Tooltip
                                          // PopupMenuButton always adds.
                                          child: GestureDetector(
                                            onLongPress: _openSettings,
                                            child: const Padding(
                                              padding: EdgeInsets.all(12),
                                              child: Icon(Icons.more_vert),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Stack(
                              children: [
                                Listener(
                                  behavior: HitTestBehavior.translucent,
                                  onPointerDown: (_) {
                                    _suggestionsNotifier.value = [];
                                  },
                                  child: _channels.isNotEmpty
                                      ? TabbedLayout(
                                          tabs: _channels,
                                          selectedIndex: _channels.indexOf(
                                            _selectedChannel ?? '',
                                          ),
                                          onSelectedIndexChanged:
                                              _onChannelChanged,
                                          onFocusChanged:
                                              _onChannelFocusChanged,
                                          pageBuilder: (_, i) {
                                            final channel = _channels[i];
                                            return ListenableBuilder(
                                              listenable: _versionNotifier(
                                                channel,
                                              ),
                                              builder: (_, _) => ChatView(
                                                channel: channel,
                                                messages:
                                                    _channelMessages[channel] ??
                                                    [],
                                                frozenSnapshot: _frozenSnapshot,
                                                tileCache: _tileCache,
                                                atBottomNotifier:
                                                    _atBottomNotifier(channel),
                                                messageNotifier:
                                                    _messageNotifier(channel),
                                                scrollController: _scrollCtrl(
                                                  channel,
                                                ),
                                                messageBuilder: _messageBuilder,
                                                showTimestamp: _showTimestamps,
                                                timestampFormat:
                                                    _timestampFormat,
                                                chatFontScale:
                                                    _chatFontSize / 14.0,
                                                checkeredMessages:
                                                    _checkeredMessages,
                                                lineSeparator: _lineSeparator,
                                                onShowUserProfile:
                                                    (
                                                      login,
                                                      userId, {
                                                      displayName,
                                                    }) => _showUserProfile(
                                                      login,
                                                      userId,
                                                      displayName: displayName,
                                                    ),
                                                onShowMessageMenu:
                                                    _showMessageMenu,
                                                onNewMessage: _notifyNewMessage,
                                                onFindThreadRoot:
                                                    _findThreadRoot,
                                                onShowThreadView:
                                                    _showThreadView,
                                              ),
                                            );
                                          },
                                          focusOnHalfDrag: true,
                                          tabBuilder: (_, i) {
                                            final channel = _channels[i];
                                            return ListenableBuilder(
                                              listenable: Listenable.merge([
                                                _selectedTabIndex,
                                                _messageNotifier(channel),
                                              ]),
                                              builder: (ctx, _) {
                                                final focused =
                                                    i ==
                                                    _selectedTabIndex.value;
                                                final selected =
                                                    focused ||
                                                    channel == _selectedChannel;
                                                final hasUnreadMention =
                                                    _channelsWithUnreadMentions
                                                        .contains(channel);
                                                return Stack(
                                                  clipBehavior: Clip.none,
                                                  children: [
                                                    Text(
                                                      channel,
                                                      style: TextStyle(
                                                        fontSize: 14,
                                                        fontWeight:
                                                            selected ||
                                                                _channelsWithUnread
                                                                    .contains(
                                                                      channel,
                                                                    )
                                                            ? FontWeight.w600
                                                            : FontWeight.normal,
                                                        color: selected
                                                            ? theme
                                                                  .colorScheme
                                                                  .primary
                                                            : _channelsWithUnread
                                                                  .contains(
                                                                    channel,
                                                                  )
                                                            ? theme
                                                                  .colorScheme
                                                                  .onSurface
                                                            : null,
                                                      ),
                                                    ),
                                                    if (hasUnreadMention &&
                                                        !selected)
                                                      Positioned(
                                                        top: -2,
                                                        right: -4,
                                                        child: Container(
                                                          key: const Key(
                                                            'unread_mention_dot',
                                                          ),
                                                          width: 6,
                                                          height: 6,
                                                          decoration:
                                                              BoxDecoration(
                                                                color: theme
                                                                    .colorScheme
                                                                    .error,
                                                                shape: BoxShape
                                                                    .circle,
                                                              ),
                                                        ),
                                                      ),
                                                  ],
                                                );
                                              },
                                            );
                                          },
                                        )
                                      : _buildEmpty(),
                                ),
                                if (_selectedChannel != null)
                                  // Sits just below the channel tab bar
                                  // (TabbedLayout's fixed 40px tab row) and
                                  // floats over the chat messages.
                                  Positioned(
                                    top: 50,
                                    left: 0,
                                    right: 0,
                                    child:
                                        _buildWidgetOverlay(
                                          _selectedChannel!,
                                        ) ??
                                        const SizedBox.shrink(),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      // Thread sheet — offstage when closed to avoid layout cost.
                      _buildOverlaySheet(
                        offstage: _activePanel != OverlayPanel.thread,
                        ratio: _threadSheetRatio,
                        header: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.close),
                                    tooltip: 'Close reply thread',
                                    onPressed: _closePanel,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      'Reply Thread',
                                      style: TextStyle(
                                        fontSize: 20,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Divider(
                              height: 1,
                              color: Theme.of(context).dividerColor,
                            ),
                          ],
                        ),
                        body: ThreadPanelWidget(
                          key: const ValueKey('thread_panel'),
                          data: _threadPanelData,
                          chatFontScale: _chatFontSize / 14.0,
                          checkeredMessages: _checkeredMessages,
                          lineSeparator: _lineSeparator,
                          onLongPress: _showThreadMessageMenu,
                          buildBadgeSpans: _messageBuilder.buildBadgeSpans,
                          buildMessageSpans: _messageBuilder.buildMessageSpans,
                          showTimestamp: _showTimestamps,
                          timestampFormat: _timestampFormat,
                          scrollController: _threadPanelScrollCtrl,
                        ),
                      ),
                      // Mentions sheet — offstage when closed to avoid layout cost.
                      _buildOverlaySheet(
                        offstage: _activePanel != OverlayPanel.mentions,
                        ratio: _mentionsSheetRatio,
                        header: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.arrow_back),
                                    tooltip: 'Back',
                                    onPressed: _closePanel,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      'Mentions / Whispers',
                                      style: TextStyle(
                                        fontSize: 20,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            TabBar(
                              controller: _mentionsTabCtrl,
                              padding: EdgeInsets.fromLTRB(
                                100.0,
                                0.0,
                                100.0,
                                0.0,
                              ),
                              tabs: const [
                                Tab(text: 'Mentions'),
                                Tab(text: 'Whispers'),
                              ],
                            ),
                            Divider(
                              height: 1,
                              color: Theme.of(context).dividerColor,
                            ),
                          ],
                        ),
                        body: TabBarView(
                          controller: _mentionsTabCtrl,
                          children: [
                            MentionsPanelWidget(
                              key: const ValueKey('mentions_panel'),
                              messages: _mentionsPanelData,
                              chatFontScale: _chatFontSize / 14.0,
                              checkeredMessages: _checkeredMessages,
                              lineSeparator: _lineSeparator,
                              buildBadgeSpans: _messageBuilder.buildBadgeSpans,
                              buildMessageSpans:
                                  _messageBuilder.buildMessageSpans,
                              showTimestamp: _showTimestamps,
                              timestampFormat: _timestampFormat,
                              scrollController: _mentionsPanelScrollCtrl,
                            ),
                            MentionsPanelWidget(
                              key: const ValueKey('whispers_panel'),
                              messages: _whispersPanelData,
                              chatFontScale: _chatFontSize / 14.0,
                              checkeredMessages: _checkeredMessages,
                              lineSeparator: _lineSeparator,
                              buildBadgeSpans: _messageBuilder.buildBadgeSpans,
                              buildMessageSpans:
                                  _messageBuilder.buildMessageSpans,
                              showTimestamp: _showTimestamps,
                              timestampFormat: _timestampFormat,
                              scrollController: _whispersPanelScrollCtrl,
                              emptyText: 'No whispers',
                            ),
                          ],
                        ),
                      ),
                      // Emote sheet - always mounted, always 60%.
                      // Box height is captured with the keyboard closed and
                      // squashed only when the keyboard shrinks the Stack
                      // below the sheet's anticipated height, so the tabs
                      // never flow past the top of the screen.
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: sheetBoxHeight,
                        child: ScaleTransition(
                          scale: _panelScaleCtrl,
                          alignment: Alignment.bottomCenter,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final totalAvailH = constraints.maxHeight;
                              return IgnorePointer(
                                ignoring: !_emoteSheetOpen,
                                child: DraggableScrollableSheet(
                                  controller: _emoteSheetCtrl,
                                  initialChildSize: 0,
                                  minChildSize: 0,
                                  maxChildSize: _emoteMaxFraction,
                                  snap: true,
                                  builder: (context, scrollController) {
                                    return _buildSlideUpContent(
                                      controller: _emoteSheetCtrl,
                                      totalAvailH: totalAvailH,
                                      maxSize: _emoteMaxFraction,
                                      child: RepaintBoundary(
                                        child: EmoteMenuPanelWidget(
                                          key: const ValueKey('emote_panel'),
                                          isActive: _emoteSheetOpen,
                                          selectedChannel: _selectedChannel,
                                          onEmoteSelected: _onEmoteSelected,
                                          onClose: _closeEmoteSheet,
                                          emoteManager: _emoteManager,
                                          scrollController: scrollController,
                                          sheetCtrl: _emoteSheetCtrl,
                                          emoteMaxFraction: _emoteMaxFraction,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      // Autocomplete dropdown — floats above chat, anchored just
                      // above the message input, 60% width like DankChat's popup.
                      Positioned(
                        bottom: 0,
                        left: 0,
                        child: SizedBox(
                          width: (MediaQuery.of(context).size.width * 0.6)
                              .clamp(0.0, 340.0),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.of(context).size.height * 0.25,
                            ),
                            child: ValueListenableBuilder<List<Suggestion>>(
                              valueListenable: _suggestionsNotifier,
                              builder: (_, suggestions, _) =>
                                  AutocompleteDropdown(
                                    suggestions: suggestions,
                                    onSelect: _onSuggestionSelected,
                                    onEmoteViewed:
                                        _emoteManager.markEmoteViewed,
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            Builder(
              builder: (ctx) {
                final inset = MediaQuery.viewInsetsOf(ctx).bottom;
                final pad = MediaQuery.paddingOf(ctx).bottom;
                return Padding(
                  padding: EdgeInsets.only(bottom: inset + pad),
                  child: ColoredBox(
                    color: theme.scaffoldBackgroundColor,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MessageInput(
                          controller: _messageController,
                          focusNode: _focusNode,
                          onSend: _sendMessage,
                          onSendLongPress: _onSendLongPress,
                          onTap: () => _suggestionsNotifier.value = [],
                          onEmoteToggle: () {
                            if (_emoteSheetOpen) {
                              unawaited(_closeEmoteSheet());
                            } else {
                              _showEmoteMenu();
                            }
                          },
                          replyToMsg: _replyToMsg,
                          onCancelReply: () =>
                              setState(() => _replyToMsg = null),
                          enabled:
                              (_activePanel != OverlayPanel.mentions ||
                                  _isWhispersTabActive) &&
                              widget.twitchAuth.isConfigured &&
                              _chatConn.irc.isConnected,
                          hintText: !widget.twitchAuth.isConfigured
                              ? 'Connect an account to chat'
                              : !_chatConn.irc.isConnected
                              ? 'Reconnecting...'
                              : _activePanel == OverlayPanel.thread
                              ? 'Reply to thread...'
                              : _isWhispersTabActive
                              ? _whisperTarget != null
                                    ? 'Whisper to $_whisperTarget...'
                                    : 'Type /w <username> <message>'
                              : _activePanel == OverlayPanel.mentions
                              ? 'Type a message...'
                              : null,
                        ),
                        ListenableBuilder(
                          listenable: Listenable.merge([
                            _versionNotifier(_selectedChannel ?? ''),
                            _selectedTabIndex,
                          ]),
                          builder: (context, _) {
                            final status = _chatStatus[_selectedChannel];
                            final hasStatus =
                                status != null && status.isNotEmpty;
                            return AnimatedSize(
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeInOut,
                              alignment: Alignment.topCenter,
                              child: hasStatus
                                  ? Padding(
                                      padding: const EdgeInsets.only(
                                        left: 12,
                                        right: 12,
                                        bottom: 4,
                                      ),
                                      child: Text(
                                        status,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    if (!widget.twitchAuth.isConfigured) {
      return const Center(
        child: Text('Configure Twitch credentials in Settings first'),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          const Text('Press + to join a channel'),
        ],
      ),
    );
  }
}
