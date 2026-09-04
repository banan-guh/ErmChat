import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../third_party/flutter_list_view/flutter_list_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/emote_fetch_tier.dart';
import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
import '../services/emote_cache_manager.dart';
import '../util/haptics.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_eventsub.dart';
import '../util/duration_format.dart';
import '../services/join_rate_limiter.dart';
import '../services/twitch_irc.dart';
import '../services/command_macros.dart';
import '../services/connectivity_service.dart';
import '../services/recent_messages.dart';
import '../services/seven_tv_event_client.dart';
import '../services/command_handler.dart';
import '../services/chat_connection_manager.dart';
import '../services/ping_manager.dart';
import '../services/ignore_manager.dart';
import '../services/link_whitelist.dart';
import '../services/emote_manager.dart';
import '../services/data_usage.dart';
import '../services/stream_player_controller.dart';
import '../services/analytics_service.dart';
import '../services/twitch_badge_service.dart';
import '../services/third_party_badge_service.dart';
import '../services/seven_tv_paint_service.dart';
import '../util/log.dart';
import '../util/constants.dart';
import '../util/sheet_drag.dart';
import '../util/thread_utils.dart';
import '../util/timestamp_formatter.dart';
import '../screens/settings/settings_screen.dart';
import '../widgets/tabbed_layout.dart';
import '../widgets/welcome_dialog.dart';
import '../services/user_store.dart';
import '../services/chat_store.dart';
import '../services/saved_threads_store.dart';
import '../services/suggestion.dart';
import '../services/notification_service.dart';
import '../services/tts_controller.dart';
import '../widgets/autocomplete_dropdown.dart';
import '../widgets/chat_message_tile.dart';
import '../widgets/user_profile_sheet.dart';
import '../widgets/emote_sheet.dart';
import '../widgets/nuke_overlay.dart';
import '../widgets/emote_image_provider.dart';
import '../widgets/message_input.dart';
import '../widgets/media_upload_controller.dart';
import '../widgets/emote_menu_panel.dart';
import '../widgets/chat_view.dart';
import '../widgets/message_builder.dart';
import '../widgets/stream_player_view.dart';
import '../widgets/predictive_back_handler.dart';
import '../widgets/chat_widget_cutout.dart';
import '../widgets/join_channel_dialog.dart';
import '../services/foreground_task.dart';

enum OverlayPanel { closed, thread, mentions }

class HomeScreen extends StatefulWidget {
  // Test seam: when true the join ("+") button never shows its loading spinner.
  // Tests that intentionally keep the app disconnected (un-faked TwitchChatApp)
  // flip this so they can still reach the button during the permanent
  // "connecting" state instead of hitting the gated spinner.
  static bool disableJoinSpinner = false;

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
  final TwitchBadgeService? badgeService;
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
    this.badgeService,
    this.initialCurrentUserLogin,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const _mentionsChannel = '@mentions';

  late final _pingManager = PingManager.instance;
  late final _ignoreManager = IgnoreManager.instance;
  final _linkWhitelist = LinkWhitelist.instance;

  late final _connectivityService =
      widget.connectivityService ?? ConnectivityService();
  late final _eventSub =
      widget.eventSubService ??
      EventSubService(connectivityService: _connectivityService);
  // One JOIN budget shared by both IRC sockets: their combined rate stays
  // inside Twitch's ~20-commands-per-10s limit instead of each socket
  // bursting independently.
  final _joinBudget = JoinRateLimiter();
  late final _irc =
      widget.ircService ??
      IrcService(
        connectivityService: _connectivityService,
        joinBudget: _joinBudget,
      );
  late final _ircRead =
      widget.ircReadService ??
      IrcReadService(
        connectivityService: _connectivityService,
        joinBudget: _joinBudget,
      );
  late RecentMessagesService _recentMessages;
  RecentMessagesConfig _recentMessagesConfig = RecentMessagesConfig();
  late final _sevenTvClient = SevenTvEventClient(
    connectivityService: _connectivityService,
  );
  late final _twitchApi = TwitchApi();
  late final _analytics = AnalyticsService(
    emoteLookup: (channel, senderTwitchId) =>
        _emoteManager.byCodeForSender(channel, senderTwitchId),
  );
  final _ttsController = TtsController();
  final _inputBarKey = GlobalKey();

  late final _chatStore =
      ChatStore(
          channels: [],
          channelMessages: {},
          messageKeys: {},
          chatStatus: {},
          channelsWithUnread: {},
          channelsWithUnreadMentions: {},
          unreadMentionsPerChannel: {},
          historyLoaded: {},
          channelsEmotesResolved: {},
          channelUserIds: {},
          lastSentWireText: {},
        )
        ..onLoginApplied = (v) {
          _pingManager.setAccount(v);
          _scanHistoryForMentions();
          unawaited(_ensureBlockedUsersLoaded());
          // Warm the macro cache so sends can read it synchronously.
          if (v != null) unawaited(loadMacros(v));
        };

  late final _chatConn = ChatConnectionManager(
    ChatConnectionConfig(
      services: ChatServices(
        twitchApi: _twitchApi,
        eventSub: _eventSub,
        irc: _irc,
        ircRead: _ircRead,
        sevenTvClient: _sevenTvClient,
        emoteManager: _emoteManager,
        badgeService: _badgeService,
        userStore: _userStore,
        twitchAuth: widget.twitchAuth,
        pingManager: _pingManager,
        ignoreManager: _ignoreManager,
        joinBudget: _joinBudget,
      ),
      store: _chatStore,
      bridge: ChatViewBridge(
        mentionsChannel: _mentionsChannel,
        onSystemMessage: _addSystemMessage,
        onJoinProgress: _onJoinProgress,
        getSelectedChannel: () => _selectedChannel,
        getMaxMessagesPerChannel: () => _maxMessagesPerChannel,
      ),
      sinks: ChatSinks(
        onCommand: _handleCommand,
        getReplyToMsg: () => _replyToMsg,
        setReplyToMsg: (v) => _replyToMsg = v,
        onUserEmoteSets: _loadUserEmoteSets,
        onReconnected: _onReconnected,
        getMacros: () {
          final login = _chatStore.session.login;
          if (login == null) return const {};
          return cachedMacroLookup(login) ?? const {};
        },
        isChatReady: () => _blocksReady,
        isBlocked: (login) => _blockedLogins.contains(login.toLowerCase()),
        getSharedChatMode: () => _sharedChatMode,
        onAnalyticsMessage: (channel, msg) =>
            _analytics.recordMessage(channel, msg),
        onAnalyticsModeration: (channel, isTimeout) =>
            _analytics.recordModeration(channel, isTimeout),
        onHypeTrain: _broadcastWidgets.onHypeTrain,
        onPoll: _broadcastWidgets.onPoll,
        onPrediction: _broadcastWidgets.onPrediction,
        onChatMessage: (channel, msg) =>
            _ttsController.handleMessage(channel, msg, _selectedChannel),
      ),
    ),
  );
  late final _messageBuilder = MessageBuilder(
    emoteManager: _emoteManager,
    badgeService: _badgeService,
    thirdPartyBadgeService: _thirdPartyBadgeService,
    onShowEmoteSheet: _showEmoteSheet,
    linkWhitelist: LinkWhitelist.instance,
  );
  late final _commandHandler = CommandHandler(
    twitchApi: _twitchApi,
    irc: _irc,
    getChannelUserIds: () => _chatStore.channelUserIds,
    getCurrentUserId: () => _chatStore.session.userId,
    getCurrentUserLogin: () => _chatStore.session.login,
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
  bool _whisperNotify = true;
  var _isBackgrounded = false;

  int _manualEmoteTierIndex = EmoteFetchTier.high.index;
  EmoteFetchAutoMode _emoteAutoMode = defaultEmoteFetchAutoMode;
  final _isMobile = ValueNotifier<bool>(false);
  VoidCallback? _connectivityListener;

  late final _emoteManager = EmoteManager(
    probe: _connectivityService.checkConnectivity,
  );
  late final _badgeService = widget.badgeService ?? TwitchBadgeService();
  late final _thirdPartyBadgeService = ThirdPartyBadgeService();
  late final _sevenTvPaintService = SevenTvPaintService();
  final _userStore = UserStore();
  final _channelNotifier = ValueNotifier<List<String>>([]);
  final _tileCache = <String, Map<String?, Widget>>{};
  final _tabMergeCache = <int, Listenable>{};
  String? _selectedChannel;
  final _blockedLogins = <String>{};
  bool _blocksReady = false;
  bool _blocksFetched = false;
  bool _channelsLoaded = false;
  final _scrollControllers = <String, FlutterListViewController>{};
  final _atBottomNotifiers = <String, ValueNotifier<bool>>{};
  final _refetchingChannels = <String>{};
  // Cached flattened emote list for autocomplete, rebuilt on emote set changes.
  List<GenericEmote>? _cachedAutocompleteEmotes;

  List<TwitchMessage>? _welcomeMessages;
  String? _welcomeMessagesKey;

  late final _broadcastWidgets = _BroadcastWidgets(
    selectedChannel: () => _selectedChannel,
  );

  TwitchMessage? _replyToMsg;
  bool _replyToRoot = false;
  bool _preferEmotesFirst = false;

  // Input-box send-gate countdown ("Slow mode: 12s" / "Timed out: 5s"),
  // ticking once per second while a gate is active on the visible channel.
  Timer? _cooldownTickTimer;
  // Drives the composer's hint directly so the countdown repaints without a
  // full-screen setState — mid-swipe selection commits skip that path.
  final ValueNotifier<String?> _cooldownLabelNotifier = ValueNotifier(null);
  // True while a manual emote refresh (Reload emotes) is in flight. The
  // connect/reconnect + per-channel-join loading is read live from
  // [_chatLoading] (driven by ChatConnectionManager.connectionStateNotifier),
  // so this only covers emote work that doesn't move the connection phase.
  final ValueNotifier<bool> _networkBusy = ValueNotifier(false);
  int _maxMessagesPerChannel = kMaxMessagesPerChannelDefault;
  int _recentMessagesLimit = 100;
  bool _showTimestamps = true;
  String _timestampFormat = kDefaultTimestampFormat;
  String _sharedChatMode = 'spotlight';
  double _chatFontSize = 14.0;
  double _highlightOpacity = 0.6;
  bool _checkeredMessages = false;
  Color? _lastSurface;
  bool _lineSeparator = false;
  bool _fastSnap = true;

  /// 7TV name paints (default off; toggled in Chat settings).
  bool _showNamePaints = false;

  /// Hidden-chrome mode: drops the ErmChat header (title, join, mentions,
  /// overflow) and the channel tab bar so the chat fills the screen. Transient
  /// (session-only); the dropdown arrow stays visible to toggle it back.
  bool _isFullscreen = false;

  /// Whether the chat input box + status row is shown. Persisted.
  bool _showInput = true;

  final _streamPlayer = StreamPlayerController();
  bool _theaterChatVisible = true;
  bool _wasTheaterMode = false;
  static const _audioBarHeight = 56.0;

  final _suggestionsNotifier = ValueNotifier<List<Suggestion>>([]);
  final _selectedTabIndex = ValueNotifier<int>(0);

  late final _panelManager = _PanelManager(
    vsync: this,
    markDirty: () {
      if (mounted) setState(() {});
    },
    isMounted: () => mounted,
  );

  // Delegating accessors for state that moved to _PanelManager.
  OverlayPanel get _activePanel => _panelManager.activePanel;
  set _activePanel(OverlayPanel v) => _panelManager.activePanel = v;
  bool get _emoteSheetOpen => _panelManager.emoteSheetOpen;
  TwitchMessage? get _openThreadRoot => _panelManager.openThreadRoot;
  set _openThreadRoot(TwitchMessage? v) => _panelManager.openThreadRoot = v;
  List<TwitchMessage> get _threadMessages => _panelManager.threadMessages;
  set _threadMessages(List<TwitchMessage> v) =>
      _panelManager.threadMessages = v;
  String? get _threadChannel => _panelManager.threadChannel;
  set _threadChannel(String? v) => _panelManager.threadChannel = v;

  // Aliases for panel-manager constants/state accessed inline in build.
  AnimationController get _panelScaleCtrl => _panelManager.panelScaleCtrl;
  DraggableScrollableController get _emoteSheetCtrl =>
      _panelManager.emoteSheetCtrl;
  double? get _emoteSheetBoxHeight => _panelManager.emoteSheetBoxHeight;
  set _emoteSheetBoxHeight(double? v) => _panelManager.emoteSheetBoxHeight = v;
  static const _emoteMaxFraction = _PanelManager.emoteMaxFraction;

  // When the soft keyboard is open and the top region shrinks below this
  // height, the app bar + channel tabs collapse instantly (like dankchat) so
  // the chat keeps enough room instead of overflowing. Tuned so portrait
  // phones and roomy landscape tablets keep the bar.
  static const _kKeyboardChromeCollapseBelowHeight = 300.0;
  ValueNotifier<double> get _threadSheetRatio => _panelManager.threadSheetRatio;
  ValueNotifier<double> get _mentionsSheetRatio =>
      _panelManager.mentionsSheetRatio;

  late final TabController _mentionsTabCtrl;
  late final TabController _threadsTabCtrl;
  final _threadPanelScrollCtrl = FlutterListViewController();
  final _mentionsPanelScrollCtrl = FlutterListViewController();

  late final PanelPredictiveBackHandler _predictiveBackHandler;

  // Panel rebuild plumbing mirrors main chat: the lists below are read
  // directly by each ChatView and these notifiers just tick rebuilds.
  final _threadAtBottom = ValueNotifier(true);
  final _threadMsgCount = ValueNotifier(0);
  final _mentionsAtBottom = ValueNotifier(true);
  final _mentionsMsgCount = ValueNotifier(0);
  final _whispersAtBottom = ValueNotifier(true);
  final _whispersMsgCount = ValueNotifier(0);

  final _whispersPanelScrollCtrl = FlutterListViewController();
  final _whispers = <TwitchMessage>[];
  int _unreadWhispers = 0;
  String? _whisperTarget;

  // Threads dashboard state (view-only caches; the kernel owns the threads).
  final _savedThreads = SavedThreadsStore();
  // Last-viewed stamp per "$channel:$rootId"; a thread is unread while its
  // kernel lastActivity runs ahead of this stamp.
  final _threadLastSeen = <String, DateTime>{};
  // Ticks the Active/Saved lists (they read the kernel + saved store live).
  final _threadsListVersion = ValueNotifier(0);

  bool _mentionScanDone = false;
  String? _lastSentText;

  ({int start, String originalText, String replacementText})? _lastAutoUndo;
  String? _previousTextForUndo;
  String? _undoExpectedAfter;

  @override
  void initState() {
    super.initState();
    unawaited(_ttsController.init());
    unawaited(PerfLog.I.init());
    DataUsageStats.I.start();
    _chatStore.session.login = widget.initialCurrentUserLogin;
    _pingManager.setAccount(widget.initialCurrentUserLogin);
    _loadEmotePrefs();
    _mentionsTabCtrl = TabController(length: 2, vsync: this);
    _mentionsTabCtrl.addListener(_onMentionsTabChanged);
    _threadsTabCtrl = TabController(length: 3, vsync: this);
    _threadsTabCtrl.addListener(_onThreadsTabChanged);
    _panelManager.emoteSheetCtrl.addListener(_panelManager.onSheetSizeChanged);
    _loadMaxMessages();
    unawaited(_loadSavedThreads());
    unawaited(
      _loadRecentMessagesConfig().then((_) {
        if (mounted) _ensureBlockedUsersLoaded();
      }),
    );
    unawaited(_pingManager.load());
    unawaited(_ignoreManager.load());
    unawaited(_linkWhitelist.load());
    unawaited(_streamPlayer.loadPrefs());
    _streamPlayer.addListener(_onStreamPlayerChanged);
    _linkWhitelist.addListener(_onLinkWhitelistChanged);
    _loadNotificationSettings();
    _broadcastWidgets.loadTestWidgets();
    _storeEventsSub = _chatStore.events.listen(_onStoreEvent);
    _noticesSub = _chatStore.notices.listen(_onStoreNotice);
    _chatConn.connect();
    _cooldownTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateCooldownLabel();
    });
    _chatConn.onWhisper = _onWhisper;
    _emoteManager.accessToken = widget.twitchAuth.accessToken;
    _emoteManager.viewerTwitchId = widget.twitchAuth.userId;
    _emoteManager.preloadGlobalEmotes();
    unawaited(_emoteManager.loadViewerPersonalSevenTvSets());
    _emoteManager.startCacheGc();
    _emoteManager.addListener(_onEmotesChanged);
    _connectivityService.init();
    _connectivityListener = () {
      final isMobile = _connectivityService.isMobile;
      if (isMobile == _isMobile.value) return;
      _isMobile.value = isMobile;
      DataUsageStats.I.setContext(isMobile: isMobile);
      _reconcileEmoteTier();
    };
    _connectivityService.addListener(_connectivityListener!);
    _badgeService.fetchGlobalBadges(widget.twitchAuth);
    _thirdPartyBadgeService.bindSevenTvEvents(_sevenTvClient);
    _sevenTvPaintService.bindSevenTvEvents(_sevenTvClient);
    _sevenTvEntitlementSub = _sevenTvClient.onEntitlement.listen(
      _emoteManager.applySevenTvEntitlement,
    );
    unawaited(_thirdPartyBadgeService.fetchFfzBadges());
    unawaited(_thirdPartyBadgeService.fetchBttvBadges());
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
    final whisperNotify = prefs.getBool('whisper_notifications') ?? false;
    if (!mounted) return;
    setState(() {
      _backgroundService = backgroundService;
      _mentionPush = mentionPush;
      _whisperNotify = whisperNotify;
    });
    if (!Platform.isAndroid) return;
    if (backgroundService) {
      initForegroundService();
    }
    if (mentionPush || whisperNotify) {
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messageBuilder.onEmailTap = _copyEmail;
    final surface = Theme.of(context).scaffoldBackgroundColor;
    if (_lastSurface != surface) {
      _lastSurface = surface;
      _tileCache.clear();
    }
  }

  void _setBackgroundService(bool value) {
    if (_backgroundService == value) return;
    setState(() => _backgroundService = value);
    if (!Platform.isAndroid) return;
    if (value) {
      _initForegroundService();
      if (_chatStore.channels.isNotEmpty) {
        startForegroundService(List.of(_chatStore.channels));
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

  void _setWhisperNotify(bool value) {
    if (_whisperNotify == value) return;
    setState(() => _whisperNotify = value);
    if (!Platform.isAndroid) return;
    // Whispers are independent of mention push (DankChat parity): they only
    // need the same notification infrastructure to exist.
    if (value) {
      requestForegroundPermissions();
      _initNotificationInfra();
    }
  }

  void _maybeNotifyWhisper(TwitchMessage msg) {
    if (!_whisperNotify || !_isBackgrounded) return;
    if (_notificationTapSub == null || _isWhispersTabActive) return;
    unawaited(
      _notificationService.showWhisperNotification(
        userName: msg.displayName,
        message: msg.text,
      ),
    );
  }

  void _setMaxMessagesPerChannel(int value) {
    if (_maxMessagesPerChannel == value) return;
    setState(() => _maxMessagesPerChannel = value);
    // Apply a lower cap immediately instead of waiting for the next incoming
    // message to hit the truncation path.
    for (final channel in List.of(_chatStore.channels)) {
      _chatStore.truncateChannel(channel, maxMessages: _maxMessagesPerChannel);
      _chatStore.touchChannel(channel);
    }
  }

  /// Generic preference setter: guard, setState, optionally rerender channels.
  void _setPref<T>(
    T Function() get,
    void Function(T) set,
    T value, {
    bool rerenderChannels = false,
  }) {
    if (get() == value) return;
    setState(() => set(value));
    if (rerenderChannels) {
      _tileCache.clear();
      for (final channel in List.of(_chatStore.channels)) {
        _chatStore.touchChannel(channel);
      }
    }
  }

  void _setRecentMessagesLimit(int value) => _setPref(
    () => _recentMessagesLimit,
    (v) => _recentMessagesLimit = v,
    value,
  );

  void _setReplyToRoot(bool value) =>
      _setPref(() => _replyToRoot, (v) => _replyToRoot = v, value);

  void _setPreferEmotesFirst(bool value) =>
      _setPref(() => _preferEmotesFirst, (v) => _preferEmotesFirst = v, value);

  void _setShowTimestamps(bool value) => _setPref(
    () => _showTimestamps,
    (v) => _showTimestamps = v,
    value,
    rerenderChannels: true,
  );

  void _setTimestampFormat(String value) => _setPref(
    () => _timestampFormat,
    (v) => _timestampFormat = v,
    value,
    rerenderChannels: true,
  );

  void _setSharedChatMode(String value) => _setPref(
    () => _sharedChatMode,
    (v) => _sharedChatMode = v,
    value,
    rerenderChannels: true,
  );

  void _setChatFontScale(double value) => _setPref(
    () => _chatFontSize,
    (v) => _chatFontSize = v,
    value,
    rerenderChannels: true,
  );

  void _setCheckeredMessages(bool value) => _setPref(
    () => _checkeredMessages,
    (v) => _checkeredMessages = v,
    value,
    rerenderChannels: true,
  );

  void _setHighlightOpacity(double value) => _setPref(
    () => _highlightOpacity,
    (v) => _highlightOpacity = v,
    value,
    rerenderChannels: true,
  );

  void _setLineSeparator(bool value) => _setPref(
    () => _lineSeparator,
    (v) => _lineSeparator = v,
    value,
    rerenderChannels: true,
  );

  void _setFastSnap(bool value) =>
      _setPref(() => _fastSnap, (v) => _fastSnap = v, value);

  void _setNamePaints(bool value) {
    if (_showNamePaints == value) return;
    setState(() => _showNamePaints = value);
    _sevenTvPaintService.enabled = value;
    _tileCache.clear();
    for (final channel in List.of(_chatStore.channels)) {
      _chatStore.touchChannel(channel);
    }
  }

  Future<void> _initForegroundService() async {
    initForegroundService();
    await requestForegroundPermissions();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isBackgrounded =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive;
    if (Platform.isAndroid) {
      if (state == AppLifecycleState.paused) {
        if (_backgroundService) {
          startForegroundService(List.of(_chatStore.channels));
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

  Future<void> _saveChannels() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('channels', List.of(_chatStore.channels));
  }

  void _reorderChannels(List<String> reordered) {
    _chatStore.channels
      ..clear()
      ..addAll(reordered);
    _channelNotifier.value = List.of(_chatStore.channels);
    if (_selectedChannel != null) {
      final newIdx = _chatStore.channels.indexOf(_selectedChannel!);
      if (newIdx >= 0) _selectedTabIndex.value = newIdx;
    }
    if (mounted) setState(() {});
    _saveChannels();
  }

  // Fetch the account's Twitch block list before anything is shown so blocked
  // users never appear - not even briefly. Fail-open: chat shows normally if
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
    for (final entry in _chatStore.channelMessages.entries) {
      final msgs = entry.value;
      final before = msgs.length;
      final removed = <TwitchMessage>[];
      msgs.removeWhere((m) {
        final blocked =
            !m.isSystem && _blockedLogins.contains(m.login.toLowerCase());
        if (blocked) removed.add(m);
        return blocked;
      });
      if (msgs.length != before) {
        // Keep the thread store in sync with the buffer: blocked users'
        // messages bypass truncation, so decay them explicitly.
        _chatStore.decayEvicted(entry.key, removed);
        _chatStore.touchChannel(entry.key);
      }
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
    // Registry files outlive joins; sweep ones whose channel is gone.
    unawaited(_emoteManager.pruneStaleChannels(saved?.toSet() ?? const {}));
    if (saved == null || saved.isEmpty) return;
    for (final name in saved) {
      if (_chatStore.channels.contains(name)) continue;
      _chatStore.channels.add(name);
      _chatStore.channelMessages.putIfAbsent(name, () => []);
      _atBottomNotifier(name).value = true;
    }
    _channelNotifier.value = List.of(_chatStore.channels);
    _selectedChannel = _chatStore.channels.first;
    _selectedTabIndex.value = 0;
    if (mounted) setState(() {});
    for (final name in saved) {
      _subscribeChannel(name);
      _recentMessages
          .fetchRecentPreferWarm(name, limit: _recentMessagesLimit)
          .then((history) {
            if (!mounted) return;
            _chatStore.historyLoaded.add(name);
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
            _chatStore.historyLoaded.add(name);
            _addSystemMessage(
              name,
              e is RecentMessagesException
                  ? e.message
                  : 'Failed to load chat history',
            );
            _maybeAddConnected(name);
          });
    }
  }

  // Merges robotty history into the channel message list (newest-first).
  // Messages whose messageId is already on screen are discarded as duplicates,
  // mentions are surfaced in the mentions panel, and a gap note is inserted at
  // the history boundary when the fetched window doesn't reach back to the
  // messages already displayed (only possible on reconnect re-fetches).
  // The merged list is sorted by timestamp (DankChat-style) so re-fetched
  // history slots below messages that arrived after it - live messages are
  // never pushed under older history.
  void _mergeHistoryIntoChannel(String channel, List<TwitchMessage> history) {
    final existing = _chatStore.channelMessages[channel]!;
    final existingIds = existing.map((m) => m.messageId).toSet();
    var hasExistingNonSystem = false;
    for (final m in existing) {
      if (!m.isSystem) {
        hasExistingNonSystem = true;
        break;
      }
    }
    final insertedIds = <String?>{};
    final insertedMsgs = <TwitchMessage>[];
    final mentionHits = <TwitchMessage>[];
    var insertedCount = 0;
    for (final msg in history) {
      // Locally ignored users' history never renders (matches the live gate).
      if (!msg.isSystem && _ignoreManager.isIgnored(msg.login)) continue;
      if (!msg.isSystem && msg.login.isNotEmpty) {
        final preferred =
            msg.displayName.toLowerCase() == msg.login.toLowerCase()
            ? msg.displayName
            : msg.login;
        _userStore.addUser(channel, preferred);
      }
      final id = msg.messageId;
      // Ban lines and NOTICEs carry no message id, so a backfill that
      // overlaps what already arrived live would double them up. Fold an
      // id-less system row into an identical row near the same time.
      if (id == null &&
          msg.isSystem &&
          _isDuplicateIdlessSystemRow(existing, insertedMsgs, msg)) {
        continue;
      }
      final isNew =
          id == null ||
          (!existingIds.contains(id) && !insertedIds.contains(id));
      if (isNew) {
        if (msg.isSystem && _chatStore.session.login != null) {
          final selfLogin = _chatStore.session.login!.toLowerCase();
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
        insertedMsgs.add(msg);
        insertedCount++;
      }
      if (msg.messageId != null) {
        _chatStore.messageKeys.add('$channel:${msg.messageId}');
      }
      // Evaluate rules even while logged out: custom/user/badge/event rules
      // need no account, and live ingestion already evaluates anonymously.
      if (msg.highlight == null) {
        final state = _pingManager.evaluate(msg);
        if (state != null && state.hasMention) {
          msg.highlight = state;
          mentionHits.add(msg);
        }
      }
    }
    if (mentionHits.isNotEmpty) {
      _chatStore.mirrorMentions(
        _mentionsChannel,
        mentionHits,
        maxMessages: _maxMessagesPerChannel,
      );
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
    // Index freshly fetched rows into the thread store so threads recovered
    // by backfill (cold start, reconnect) stay viewable past buffer trimming.
    // Runs after the merge so roots inserted in the same batch link up.
    if (insertedMsgs.isNotEmpty) {
      _chatStore.indexMessages(channel, insertedMsgs);
    }
    _chatStore.touchChannel(channel);
    _moveConnectedMessageToTop(channel);
  }

  /// True when an id-less system row from history duplicates a system row
  /// already on screen or just inserted from this batch: identical text and
  /// a timestamp inside [_systemDedupWindow]. Robotty's receive timestamp
  /// and the live arrival clock differ by at most a couple of seconds, so
  /// true copies land well inside the window while distinct repeats of the
  /// same line stay out.
  static const _systemDedupWindow = Duration(seconds: 10);

  bool _isDuplicateIdlessSystemRow(
    List<TwitchMessage> existing,
    List<TwitchMessage> inserted,
    TwitchMessage candidate,
  ) {
    for (final row in existing) {
      if (_isSameSystemEvent(row, candidate)) return true;
    }
    for (final row in inserted) {
      if (_isSameSystemEvent(row, candidate)) return true;
    }
    return false;
  }

  bool _isSameSystemEvent(TwitchMessage a, TwitchMessage b) {
    return a.isSystem &&
        a.text == b.text &&
        a.timestamp.difference(b.timestamp).abs() <= _systemDedupWindow;
  }

  void _onReconnected() {
    for (final channel in List.of(_chatStore.channels)) {
      unawaited(_refetchHistory(channel));
    }
    // Re-join may have opened channels whose sub-emote owners were previously
    // unknown; heal their labels in the emote daemon (no re-fetch needed).
    final auth = widget.twitchAuth;
    if (auth.isConfigured) {
      unawaited(
        _emoteManager.loadUserEmoteSets([], auth, _chatStore.channelUserIds),
      );
    }
  }

  Future<void> _refetchHistory(String channel) async {
    if (!_chatStore.historyLoaded.contains(channel) ||
        _refetchingChannels.contains(channel)) {
      return;
    }
    _refetchingChannels.add(channel);
    try {
      final history = await _recentMessages.fetchRecent(
        channel,
        limit: _recentMessagesLimit,
      );
      if (!mounted || !_chatStore.channels.contains(channel)) return;
      final existing = _chatStore.channelMessages[channel];
      if (existing == null || history.isEmpty) return;
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
    final word = getCurrentWord(text, cursor, extendRight: false);
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
          : _cachedAutocompleteEmotes ??= _emoteManager.sendableEmotes(channel);
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
    final wordBefore = getCurrentWord(
      textBefore,
      cursorBefore,
      extendRight: false,
    );

    if (suggestion is UserSuggestion) {
      if (wordBefore.text.startsWith('@')) {
        replacement = '@$replacement';
      }
    }

    final trailingSpace = wordBefore.end >= textBefore.length
        ? ' '
        : (textBefore[wordBefore.end] == ' ' ? '' : '');

    _lastAutoUndo = (
      start: wordBefore.start,
      originalText: wordBefore.text,
      replacementText: replacement + trailingSpace,
    );

    replaceCurrentWord(_messageController, replacement, extendRight: false);

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

  void _onLinkWhitelistChanged() {
    // Re-render visible tiles so the new link-whitelist entries take effect.
    _tileCache.clear();
    for (final channel in List.of(_chatStore.channels)) {
      _chatStore.touchChannel(channel);
    }
    if (mounted) setState(() {});
  }

  void _onEmotesChanged() {
    _cachedAutocompleteEmotes = null;
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
      for (final c in List.of(_chatStore.channels)) {
        _chatStore.touchChannel(c);
      }
      _chatStore.mentionsBump.value++;
      _onPanelDataChanged();
    }
  }

  ValueNotifier<int> _versionNotifier(String channel) {
    return _chatStore.versionNotifier(channel);
  }

  ValueNotifier<int> _messageNotifier(String channel) {
    return _chatStore.messageCountNotifier(channel);
  }

  ValueNotifier<bool> _atBottomNotifier(String channel) {
    return _atBottomNotifiers.putIfAbsent(channel, () => ValueNotifier(true));
  }

  StreamSubscription<ChatStoreEvent>? _storeEventsSub;
  StreamSubscription<ChatNotice>? _noticesSub;
  StreamSubscription<SevenTvEntitlementEvent>? _sevenTvEntitlementSub;

  // The store announces every mutation; this is the view bookkeeping that
  // reacts: tile-cache eviction and overlay-panel data refresh. Rendering
  // itself happens through the per-channel notifiers the tiles listen to.
  void _onStoreNotice(ChatNotice notice) {
    switch (notice.kind) {
      case ChatNoticeKind.info:
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        // Replace any current snackbar so identical/rapid info popups don't
        // queue up one after another.
        messenger.removeCurrentSnackBar();
        messenger.showSnackBar(_snackBar(notice.message ?? ''));
      case ChatNoticeKind.focusInput:
        _focusNode.requestFocus();
    }
  }

  void _onStoreEvent(ChatStoreEvent event) {
    // The composer's send-gate countdown arms off moderation events (self
    // timeouts land here as system lines); refresh it eagerly so the label
    // appears without waiting for the next tick.
    _updateCooldownLabel();
    switch (event.signal) {
      case ChatStoreSignal.newContent:
        _syncSavedWithChannel(event.channel);
        _onPanelDataChanged(event.channel);
      case ChatStoreSignal.channelTouched:
        _tileCache.remove(event.channel);
        _syncSavedWithChannel(event.channel);
        _onPanelDataChanged(event.channel);
      case ChatStoreSignal.messageMutated:
        if (event.messageId != null) {
          _tileCache[event.channel]?.remove(event.messageId);
        }
        // Deletes and ban-stack text edits emit only this signal (no trailing
        // system line in every path), so an open panel would keep rendering
        // the stale row.
        _onPanelDataChanged(event.channel);
    }
  }

  // Appends channel buffer rows belonging to saved threads into the
  // persisted full log. Skips channels with no saved threads; dedup by id
  // keeps the per-event scan cheap and idempotent across history merges.
  void _syncSavedWithChannel(String channel) {
    var hasSaved = false;
    for (final t in _savedThreads.threads) {
      if (t.channel == channel) {
        hasSaved = true;
        break;
      }
    }
    if (!hasSaved) return;
    final msgs = _chatStore.channelMessages[channel];
    if (msgs == null || msgs.isEmpty) return;
    var appended = false;
    for (final m in msgs) {
      if (m.isSystem) continue;
      if (_savedThreads.appendMessage(m)) appended = true;
    }
    if (appended) {
      unawaited(_persistSavedThreads());
      _threadsListVersion.value++;
    }
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
      _threadChannel = _openThreadRoot!.channel;
      _threadMessages
        ..clear()
        ..addAll(_computeThreadMessages());
      _threadMsgCount.value++;
      // Watching the Thread tab marks it seen so the Active row does not flip
      // back to unread while you stare at it.
      if (_threadsTabCtrl.index == 0) {
        final channel = _openThreadRoot!.channel;
        final rootId =
            _openThreadRoot!.replyThreadRootId ?? _openThreadRoot!.messageId;
        if (channel != null && rootId != null) {
          _threadLastSeen['$channel:$rootId'] = DateTime.now();
        }
      }
      _threadsListVersion.value++;
    } else if (_activePanel == OverlayPanel.thread) {
      // Dashboard open without a thread selected: the Active list still moves.
      if (changedChannel != null &&
          changedChannel != _selectedChannel &&
          changedChannel != _threadChannel) {
        return;
      }
      _threadsListVersion.value++;
    } else if (_activePanel == OverlayPanel.mentions) {
      _mentionsMsgCount.value++;
      _whispersMsgCount.value++;
    }
  }

  void _onAuthChanged() {
    _emoteManager.accessToken = widget.twitchAuth.accessToken;
    _refreshEmotesAfterAuth();
    if (_chatStore.session.login?.toLowerCase() !=
        widget.twitchAuth.login?.toLowerCase()) {
      // Account switched (or signed out): drop the cached user so the manager
      // re-resolves the active account and reconnects with its credentials.
      _chatStore.session.login = null;
      _chatStore.session.userId = null;
      _pingManager.setAccount(null);
      // The emote-set / block / mention caches are per-account: reset them so
      // the new account's USERSTATE re-fetches its sub emotes (instead of the
      // old account's set IDs being deduped out), blocks are re-fetched, the
      // retroactive mention scan re-runs, and channels re-resolve emotes with
      // the new token.
      _emoteManager.resetUserEmoteState();
      _blocksFetched = false;
      // Fail closed until the new account's block list arrives; without this
      // chat unhides immediately and the old account's list briefly filters.
      _blocksReady = false;
      // The previous account's block list must not keep filtering the new
      // account's chat; the re-fetch below repopulates it.
      _blockedLogins.clear();
      _mentionScanDone = false;
      _chatStore.channelsEmotesResolved.clear();
      // Whispers and the mentions feed belong to the previous account.
      _whispers.clear();
      _unreadWhispers = 0;
      _whispersMsgCount.value++;
      _chatStore.truncateChannel(_mentionsChannel, maxMessages: 0);
      _mentionsMsgCount.value++;
      _scanHistoryForMentions();
      unawaited(_ensureBlockedUsersLoaded());
    }
    // Re-resolve emotes with the new account's token BEFORE reconnecting so
    // sub emote sets fetch under the right auth; connect()'s GLOBALUSERSTATE
    // then layers the fresh sub emotes on top.
    unawaited(_refreshEmotesAfterAuth().then((_) => _chatConn.connect()));
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
      final capEmoteFps = prefs.getBool('emote_cap_fps') ?? false;
      if (capEmoteFps) {
        EmoteUrlProvider.applyFpsCap(prefs.getInt('emote_fps_cap') ?? 30);
        EmoteUrlProvider.applyAdaptiveThrottle(
          prefs.getBool('emote_auto_throttle') ?? true,
        );
        EmoteUrlProvider.alwaysAnimatePanel =
            prefs.getBool('always_animate_emote_panel') ?? true;
      } else {
        // Uncapped: 60 fps is effectively native on a 60 Hz display.
        EmoteUrlProvider.applyFpsCap(60);
        EmoteUrlProvider.applyAdaptiveThrottle(false);
        EmoteUrlProvider.alwaysAnimatePanel = true;
      }
      EmoteUrlProvider.applyGifsEnabled(prefs.getBool('animate_gifs') ?? true);
      await _refreshConnectivity();
      _reconcileEmoteTier();
    } catch (e) {
      logDebug('_loadEmotePrefs failed: $e');
    }
  }

  /// Applies emote frame-rate provider state when the master 'Cap emote FPS'
  /// toggle changes.  When off, emotes run uncapped (fpsCap 60 ~= native 60 Hz)
  /// with adaptive throttling disabled; the three sub-settings are hidden.
  void _setCapEmoteFps(bool enabled) {
    SharedPreferences.getInstance().then((prefs) {
      if (enabled) {
        EmoteUrlProvider.applyFpsCap(prefs.getInt('emote_fps_cap') ?? 30);
        EmoteUrlProvider.applyAdaptiveThrottle(
          prefs.getBool('emote_auto_throttle') ?? true,
        );
        EmoteUrlProvider.alwaysAnimatePanel =
            prefs.getBool('always_animate_emote_panel') ?? true;
      } else {
        EmoteUrlProvider.applyFpsCap(60);
        EmoteUrlProvider.applyAdaptiveThrottle(false);
        EmoteUrlProvider.alwaysAnimatePanel = true;
      }
    });
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
    final oldTier = _emoteManager.tier;
    try {
      _emoteManager.tier = tier;
      DataUsageStats.I.setContext(tier: tier, isMobile: _isMobile.value);
      if (tier == EmoteFetchTier.nothing) {
        // Nothing tier: the resolution is null, so no new fetches happen, but we
        // must NOT evict the in-memory registry. Cached emotes keep rendering
        // from disk; wiping would force a full re-resolve (and its rebuild
        // storm) on every toggle.
        if (mounted) setState(() {});
      } else {
        // A "no-diff -> diff" switch (e.g. low -> high) introduces resolutions
        // the old tier never fetched, so force-fetch the new emote URLs. A
        // switch that stays within already-fetched resolutions (e.g. high ->
        // medium) reuses the cached tier instead of re-downloading. No evict:
        // successful fetches replace the caches wholesale, and evicting
        // mid-session breaks the connected 7TV WS client's delta state
        // (same hazard as the reload path).
        final needsDiff = _tierAddsResolution(oldTier, tier);
        _emoteManager.preloadGlobalEmotes(force: needsDiff);
        for (final c in _chatStore.channels) {
          _emoteManager.resolveEmotes(
            c,
            _chatStore.channelUserIds[c],
            force: needsDiff,
          );
        }
        if (mounted) setState(() {});
      }
    } catch (e) {
      logDebug('_applyTier failed: $e');
    }
  }

  /// True when [neu] fetches resolutions [old] did not, i.e. a manual switch
  /// from a no-diff tier to a diff tier that requires re-fetching emote URLs.
  bool _tierAddsResolution(EmoteFetchTier old, EmoteFetchTier neu) {
    final oldSet = _tierResolutions(old);
    return _tierResolutions(neu).any((r) => !oldSet.contains(r));
  }

  Set<EmoteResolution> _tierResolutions(EmoteFetchTier tier) => switch (tier) {
    EmoteFetchTier.nothing => const {},
    EmoteFetchTier.low => const {EmoteResolution.low},
    EmoteFetchTier.medium => const {EmoteResolution.medium},
    EmoteFetchTier.high => const {EmoteResolution.medium, EmoteResolution.high},
  };

  void _applyCacheCap(int cap) {
    _emoteManager.cacheCap = cap;
  }

  Future<bool> _refreshEmotesAfterAuth({bool force = false}) async {
    try {
      for (final channel in _chatStore.channels) {
        final userId = await _twitchApi.getUserId(widget.twitchAuth, channel);
        if (userId != null) {
          _chatStore.channelUserIds[channel] = userId;
        }
      }
      // No evict here: a force fetch replaces the caches wholesale and the
      // per-provider stashes retain the previous data when a provider fails.
      // Evicting mid-session wrecked live state instead: the connected 7TV
      // WS client kept applying deltas, and updateSevenTvEmotes rebuilt a
      // null cache from a single delta's added list, which _reapplyLiveSevenTv
      // then propagated over every later rebuild.
      // Await so global emote metadata is present before the post-refresh
      // rebuild; unawaited left a window where global emotes rendered as text.
      await _emoteManager.preloadGlobalEmotes(force: force);
      _emoteManager.viewerTwitchId = widget.twitchAuth.userId;
      await _emoteManager.loadViewerPersonalSevenTvSets();
      _badgeService.resetCaches();
      await _badgeService.fetchGlobalBadges(widget.twitchAuth);
      for (final channel in _chatStore.channels) {
        final userId = _chatStore.channelUserIds[channel];
        if (userId != null) {
          _badgeService.fetchChannelBadges(widget.twitchAuth, userId, channel);
        }
      }
      await Future.wait(
        _chatStore.channels.map(
          (c) => _emoteManager.resolveEmotes(
            c,
            _chatStore.channelUserIds[c],
            force: force,
          ),
        ),
      );
      if (mounted) setState(() {});
      return true;
    } catch (e) {
      logDebug('_refreshEmotesAfterAuth failed: $e');
      if (mounted) setState(() {});
      return false;
    }
  }

  // Manual "Reload emotes": diff refresh. Re-fetches emote metadata
  // (catalogues + subs) for all channels without touching in-memory state,
  // so live 7TV WS deltas and cached images stay valid. Force bypasses the
  // fresh-cache short-circuits so third-party catalogues (7TV/BTTV/FFZ) are
  // pulled again, not just Twitch.
  Future<void> _reloadEmotes() => _runEmoteRefresh(nuke: false);

  // Nuke (emotes settings): destroy everything, then refetch from the
  // network. Besides the in-memory state this also drops the persisted
  // metadata and the image caches, so emotes visibly re-buffer instead of
  // being instantly restored from disk.
  bool _nukePending = false;

  void _nukeEmotes() {
    _nukePending = true;
    // Pop both EmotesSettingsScreen and SettingsScreen back to home.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _runEmoteRefresh({required bool nuke}) async {
    _networkBusy.value = true;
    // Discard failures from before this refresh so the report below only
    // reflects fetches this refresh triggered.
    _emoteManager.takeFetchFailures();
    try {
      if (nuke) {
        await _emoteManager.wipePersisted();
        _emoteManager.evictGlobal();
        for (final channel in _chatStore.channels) {
          _emoteManager.evictChannel(channel);
        }
        await EmoteCacheManager().emptyCache();
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        // Rebuild now, while everything is empty, so the nuke is visible
        // instead of being instantly papered over by the refetch.
        _emoteManager.notifyStateCleared();
      }
      final ok = await _refreshEmotesAfterAuth(force: true);
      // Subscriber emotes aren't covered by the global/channel refresh; re-fetch
      // the sets already known from a prior USERSTATE.
      final auth = widget.twitchAuth;
      var subFailed = false;
      if (ok && auth.isConfigured) {
        try {
          await _emoteManager.reloadUserEmoteSets(
            auth,
            _chatStore.channelUserIds,
          );
        } catch (e) {
          subFailed = true;
          logDebug('_reloadEmotes: sub emote reload failed: $e');
        }
      }
      if (!mounted) return;
      String message;
      if (!ok) {
        message = 'Emote reload failed';
      } else {
        final failed = _emoteManager.takeFetchFailures();
        if (subFailed) failed.add('sub emotes');
        message = failed.isEmpty
            ? 'Emotes reloaded'
            : 'Emotes failed to load for ${failed.join(', ')}';
      }
      ScaffoldMessenger.of(context).showSnackBar(_snackBar(message));
    } finally {
      _networkBusy.value = false;
    }
  }

  // Manual "Reconnect": brute-force teardown + reconnect of every socket.
  void _reconnect() {
    _chatConn.forceReconnect();
  }

  // True while the chat pipe is still coming up or not every joined channel
  // has confirmed its JOIN: the join button spins through first load, a
  // reconnect, and until the last channel is ready. Recomputed on every
  // connectionStateNotifier bump (phase change + per-channel readiness).
  bool get _chatLoading {
    if (_chatConn.connectPhase != ChatPhase.online) return true;
    for (final channel in _chatStore.channels) {
      if (!_chatConn.isChannelChatReady(channel)) return true;
    }
    return false;
  }

  // Loads the account's subscriber emotes from the IRC emote-sets tag
  // (GLOBALUSERSTATE/USERSTATE), the authoritative source of which emote sets
  // the account can use (the Helix /chat/emotes/user endpoint omits certain
  // grants, e.g. bot accounts). USERSTATE is channel-scoped; GLOBALUSERSTATE
  // (null channel) is the account-wide union. The actual fetch, owner-login
  // resolution, and per-channel storage all live in EmoteManager (the emote
  // daemon); this is a thin forwarder so HomeScreen stays out of emote state.
  Future<void> _loadUserEmoteSets(
    String? channel,
    List<String> emoteSetIds,
  ) async {
    final auth = widget.twitchAuth;
    if (!auth.isConfigured) return;
    await _emoteManager.loadUserEmoteSets(
      emoteSetIds,
      auth,
      _chatStore.channelUserIds,
    );
  }

  Future<void> _loadRecentMessagesConfig() async {
    if (widget.recentMessagesService != null) {
      _recentMessages = widget.recentMessagesService!;
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      _recentMessagesConfig = RecentMessagesConfig.fromPrefs(prefs);
    } catch (e) {
      logDebug('Failed to load recent-messages config: $e');
    }
    _recentMessages = RecentMessagesService(config: _recentMessagesConfig);
  }

  void _setRecentMessagesMode(RecentMessagesConfig config) {
    if (widget.recentMessagesService != null) return;
    setState(() => _recentMessagesConfig = config);
    _recentMessages = RecentMessagesService(config: config);
    unawaited(
      SharedPreferences.getInstance().then((prefs) => config.toPrefs(prefs)),
    );
  }

  void _loadMaxMessages() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _maxMessagesPerChannel =
          prefs.getInt('max_messages_per_channel') ??
          kMaxMessagesPerChannelDefault;
      _recentMessagesLimit =
          prefs.getInt('recent_messages_limit') ?? kRecentMessagesLimitDefault;
      _replyToRoot = prefs.getBool('reply_to_thread_root') ?? false;
      _preferEmotesFirst = prefs.getBool('prefer_emotes_first') ?? false;
      _showTimestamps = prefs.getBool(kShowTimestampsPrefKey) ?? true;
      _timestampFormat =
          prefs.getString(kTimestampFormatPrefKey) ?? kDefaultTimestampFormat;
      _chatFontSize = prefs.getDouble('chat_font_size') ?? 14.0;
      _highlightOpacity = prefs.getDouble('highlight_opacity') ?? 0.6;
      _checkeredMessages = prefs.getBool('checkered_messages') ?? false;
      _lineSeparator = prefs.getBool('line_separator') ?? false;
      _fastSnap = prefs.getBool('fast_channel_snap') ?? true;
      _sharedChatMode = prefs.getString('shared_chat_mode') ?? 'spotlight';
      _showNamePaints = prefs.getBool('seventv_name_paints') ?? false;
      _showInput = prefs.getBool('show_input') ?? true;
    });
    if (_showNamePaints) {
      _sevenTvPaintService.enabled = true;
      for (final channel in List.of(_chatStore.channels)) {
        _chatStore.touchChannel(channel);
      }
    }
  }

  @override
  void dispose() {
    final listener = _connectivityListener;
    if (listener != null) _connectivityService.removeListener(listener);
    _connectivityListener = null;
    _isMobile.dispose();
    DataUsageStats.I.dispose();
    _chatConn.dispose();
    unawaited(_ttsController.shutdown());
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.removeObserver(_predictiveBackHandler);
    _panelManager.dispose();
    _broadcastWidgets.dispose();
    _cooldownTickTimer?.cancel();
    _cooldownLabelNotifier.dispose();
    _networkBusy.dispose();
    _eventSub.dispose();
    _irc.dispose();
    _ircRead.dispose();
    _sevenTvClient.dispose();
    _sevenTvEntitlementSub?.cancel();
    _thirdPartyBadgeService.dispose();
    _emoteManager.removeListener(_onEmotesChanged);
    _linkWhitelist.removeListener(_onLinkWhitelistChanged);
    _streamPlayer.removeListener(_onStreamPlayerChanged);
    _streamPlayer.dispose();
    _emoteManager.dispose();
    widget.twitchAuth.removeListener(_onAuthChanged);
    _messageController.dispose();
    _focusNode.removeListener(_onInputFocusChanged);
    _focusNode.dispose();
    _mentionsTabCtrl.removeListener(_onMentionsTabChanged);
    _mentionsTabCtrl.dispose();
    _threadsTabCtrl.removeListener(_onThreadsTabChanged);
    _threadsTabCtrl.dispose();
    _threadPanelScrollCtrl.dispose();
    _mentionsPanelScrollCtrl.dispose();
    _whispersPanelScrollCtrl.dispose();
    _threadAtBottom.dispose();
    _threadMsgCount.dispose();
    _threadsListVersion.dispose();
    _mentionsAtBottom.dispose();
    _mentionsMsgCount.dispose();
    _whispersAtBottom.dispose();
    _whispersMsgCount.dispose();
    for (final c in _scrollControllers.values) {
      c.dispose();
    }
    for (final n in _atBottomNotifiers.values) {
      n.dispose();
    }
    _tileCache.clear();
    _storeEventsSub?.cancel();
    _noticesSub?.cancel();
    _chatStore.dispose();
    _notificationTapSub?.cancel();
    _notificationService.dispose();
    super.dispose();
  }

  void _addSystemMessage(
    String channel,
    String text, {
    Color? accent,
    String? messageId,
  }) {
    if (!_chatStore.addSystemMessage(
      channel,
      text,
      accent: accent,
      messageId: messageId,
    )) {
      return;
    }
    _truncateChannelMessages(channel);
    _chatStore.noteNewMessage(channel);
  }

  void _toggleFullscreen() {
    setState(() => _isFullscreen = !_isFullscreen);
  }

  void _toggleStreamForSelected() {
    if (_streamPlayer.isActive) {
      setState(() => _streamPlayer.closeStream());
      return;
    }
    final channel = _selectedChannel;
    if (channel == null) return;
    setState(() => _streamPlayer.toggleStream(channel));
  }

  bool _isChannelLive(String channel) =>
      (_chatStore.chatStatus[channel] ?? '').contains('Live');

  void _onStreamPlayerChanged() {
    if (!mounted) return;
    final enteringTheater = _streamPlayer.isTheaterMode && !_wasTheaterMode;
    _wasTheaterMode = _streamPlayer.isTheaterMode;
    setState(() {});
    if (!enteringTheater) return;
    final channel = _streamPlayer.currentChannel;
    if (channel == null) return;
    if (_selectedChannel == channel) return;
    if (!_chatStore.channels.contains(channel)) return;
    _onChannelChanged(_chatStore.channels.indexOf(channel));
  }

  void _toggleInputVisibility() {
    setState(() => _showInput = !_showInput);
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setBool('show_input', _showInput),
      ),
    );
  }

  /// Tiny arrow anchored top-right just below the channel tab strip (see
  /// TabbedLayout). Always visible so the top bar / input can be toggled back
  /// even in fullscreen.
  /// Tiny arrow anchored top-right just below the channel tab strip (see
  /// TabbedLayout). Always visible so the top bar / input can be toggled back
  /// even in fullscreen.
  Widget _buildChromeMenu() {
    return _ChromeMenuButton(
      onToggleFullscreen: _toggleFullscreen,
      onToggleInput: _toggleInputVisibility,
      onToggleStream: _toggleStreamForSelected,
      showStreamToggle: () =>
          _streamPlayer.isActive ||
          !widget.twitchAuth.isConfigured ||
          (_selectedChannel != null && _isChannelLive(_selectedChannel!)),
      streamActive: () => _streamPlayer.isActive,
    );
  }

  /// Translates join-queue progress into a live countdown system line
  /// ("Joining: position 12, ~14s"); position 0 means numbers are over
  /// (sent, awaiting echo) and the line degrades to a plain marker; a null
  /// [info] retires the line.
  void _onJoinProgress(String channel, JoinProgress? info) {
    final id = 'join_wait_$channel';
    var changed = false;
    if (info == null) {
      changed = _chatStore.removeSystemMessage(channel, id);
    } else {
      final text = info.position <= 0
          ? 'Joining #$channel...'
          : info.etaSeconds <= 0
          ? 'Joining: position ${info.position}'
          : 'Joining: position ${info.position}, ~${info.etaSeconds}s';
      changed = _chatStore.upsertSystemMessage(channel, text, messageId: id);
    }
    if (!changed) return;
    // Upsert mutates the row's text in place: drop the cached tile or the
    // list keeps rendering the first countdown values forever.
    _tileCache[channel]?.remove(id);
    _truncateChannelMessages(channel);
    _chatStore.noteNewMessage(channel);
  }

  SnackBar _snackBar(String text, {SnackBarAction? action}) {
    final inputBarH = _inputBarKey.currentContext?.size?.height ?? 0;
    return SnackBar(
      behavior: SnackBarBehavior.floating,
      dismissDirection: DismissDirection.horizontal,
      margin: EdgeInsets.only(bottom: inputBarH, left: 16, right: 16),
      content: Text(text),
      action: action,
    );
  }

  void _copyMessageToClipboard(TwitchMessage msg) {
    Clipboard.setData(ClipboardData(text: msg.text));
    ScaffoldMessenger.of(context).showSnackBar(
      _snackBar(
        'Message copied',
        action: SnackBarAction(label: 'Paste', onPressed: _pasteFromClipboard),
      ),
    );
  }

  void _copyEmail(String email) {
    Clipboard.setData(ClipboardData(text: email));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(_snackBar('Copied $email'));
  }

  /// Pastes the current clipboard text into the chat input at the cursor.
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    final controller = _messageController;
    final selection = controller.selection;
    final base = selection.baseOffset;
    final insertAt = base < 0 ? controller.text.length : base;
    final newText = controller.text.replaceRange(insertAt, insertAt, text);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: insertAt + text.length),
    );
  }

  void _showMessageMenu(TwitchMessage msg) {
    iosHaptic(HapticFeedback.mediumImpact);
    final threadRoot = _findThreadRoot(msg);
    final hasThread = threadRoot != null;
    final threadSaved = hasThread && _isThreadSaved(threadRoot);
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
                    unawaited(_showThreadView(threadRoot));
                  },
                ),
              if (hasThread)
                ListTile(
                  leading: Icon(
                    threadSaved ? Icons.bookmark : Icons.bookmark_border,
                  ),
                  title: Text(threadSaved ? 'Unsave thread' : 'Save thread'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleSaveThread(threadRoot);
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

  // Panels (thread, mentions, whispers): copy + more menu. No reply (the
  // input bar belongs to the main chat) and no thread navigation.
  void _showPanelMessageMenu(TwitchMessage msg) {
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
    _chatStore.channelMessages[channel]?.removeWhere(
      (m) => m.isSystem && m.text == 'Loading chat history...',
    );
  }

  // "Connected" is emitted as soon as IRC is up, which is usually before
  // the robotty history fetch completes. History messages are then inserted
  // above it, so move the newest connect-state line ("Reconnected" on a
  // reconnect, otherwise "Connected") back to the most recent position to
  // stay visible.
  void _moveConnectedMessageToTop(String channel) {
    final msgs = _chatStore.channelMessages[channel];
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
    _chatStore.touchChannel(channel);
  }

  Future<void> _addChannel(String channelName) async {
    final name = channelName.trim().toLowerCase();
    if (name.isEmpty || _chatStore.channels.contains(name)) return;
    if (_chatStore.channels.length >= kMaxChannels) return;

    setState(() {
      _chatStore.channels.add(name);
      _channelNotifier.value = List.of(_chatStore.channels);
      _chatStore.channelMessages.putIfAbsent(name, () => []);
      _atBottomNotifier(name).value = true;
      _selectedChannel = name;
      _selectedTabIndex.value = _chatStore.channels.length - 1;
    });
    _saveChannels();
    _focusNode.requestFocus();

    final loadingMsg = TwitchMessage(
      login: '',
      text: 'Loading chat history...',
      isSystem: true,
      channel: name,
    );
    _chatStore.channelMessages[name]!.insert(0, loadingMsg);

    _recentMessages
        .fetchRecentPreferWarm(name, limit: _recentMessagesLimit)
        .then((history) {
          if (!mounted) return;
          _chatStore.historyLoaded.add(name);
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
          _chatStore.historyLoaded.add(name);
          setState(() {
            _removeLoadingHistoryMessage(name);
            _addSystemMessage(
              name,
              e is RecentMessagesException
                  ? e.message
                  : 'Failed to load chat history',
            );
          });
          _maybeAddConnected(name);
        });

    logDebug('[HomeScreen] joining channel: $name');
    await _subscribeChannel(name);
    _chatConn.focusChannel(name);

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
    if (_streamPlayer.currentChannel == channel) _streamPlayer.closeStream();
    _irc.part(channel);
    _ircRead.part(channel);
    _emoteManager.evictChannel(channel);
    _badgeService.clearChannel(channel);
    _chatStore.channelsEmotesResolved.remove(channel);
    _chatStore.historyLoaded.remove(channel);
    _chatStore.channelUserIds.remove(channel);
    _chatStore.lastSentWireText.remove(channel);
    _chatStore.chatStatus.remove(channel);
    _broadcastWidgets.hypeTrains.remove(channel);
    _broadcastWidgets.polls.remove(channel);
    _broadcastWidgets.predictions.remove(channel);
    _broadcastWidgets.widgetsMinimized.remove(channel);
    // Per-channel notifiers and tile state must die with the channel: a
    // re-joined channel would otherwise reuse stale notifiers and an old
    // frozen snapshot, and the maps would grow for the session.
    _tileCache.remove(channel);
    setState(() {
      _chatStore.channels.remove(channel);
      _channelNotifier.value = List.of(_chatStore.channels);
      _chatStore.channelMessages.remove(channel);
      _userStore.removeChannel(channel);
      _scrollControllers.remove(channel)?.dispose();
      _chatStore.channelsWithUnread.remove(channel);
      _chatStore.channelsWithUnreadMentions.remove(channel);
      _chatStore.unreadVersion.value++;
      final removedUnread =
          _chatStore.unreadMentionsPerChannel.remove(channel) ?? 0;
      if (removedUnread > 0) {
        _chatStore.unreadMentions -= removedUnread;
        if (_chatStore.unreadMentions < 0) _chatStore.unreadMentions = 0;
      }
      _chatStore.messageKeys.removeWhere((k) => k.startsWith('$channel:'));
      _threadLastSeen.removeWhere((k, _) => k.startsWith('$channel:'));
      // Drop thread-panel state pointing at the departed channel so the
      // Thread tab never renders a channel that is no longer joined. Saved
      // bookmarks are global and intentionally survive.
      if (_openThreadRoot?.channel == channel) _openThreadRoot = null;
      if (_openThreadRoot == null) _threadMessages = [];
      if (_threadChannel == channel) _threadChannel = null;
      if (_selectedChannel == channel) {
        _selectedChannel = _chatStore.channels.isNotEmpty
            ? _chatStore.channels.last
            : null;
        if (_chatStore.channels.isNotEmpty) {
          _selectedTabIndex.value = _chatStore.channels.length - 1;
        }
      }
    });
    // Notifier disposal must land after the widgets listening to them have
    // actually unmounted (the frame the setState above schedules); disposing
    // earlier makes their removeListener hit a disposed notifier in debug
    // builds when leaving a channel.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _atBottomNotifiers.remove(channel)?.dispose();
      _chatStore.forgetChannel(channel);
    });
    _saveChannels();
  }

  void _sendMessage() {
    iosHaptic(HapticFeedback.lightImpact);
    if (_suggestionsNotifier.value.isNotEmpty) {
      _suggestionsNotifier.value = [];
    }

    final text = _messageController.text.trim();
    final channel = _selectedChannel;
    if (text.isEmpty || channel == null) {
      return;
    }

    if (!widget.twitchAuth.isConfigured) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(_snackBar('Connect an account to chat'));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(_snackBar('Type /w <username> <message> to whisper'));
      }
      return;
    }

    // The Mentions tab of the panel stays read-only, as do the threads
    // dashboard lists: replies are composed from the Thread tab only.
    if (_activePanel == OverlayPanel.mentions) {
      return;
    }
    if (_activePanel == OverlayPanel.thread && _threadsTabCtrl.index != 0) {
      return;
    }

    // Send gates are soft: the countdown is shown as a hint in the input box
    // (_cooldownLabel) but the message is never held back - Twitch enforces
    // the real block, and a successful echo heals any stale self-timeout gate
    // (see ChatIngestion.onOwnIrcMessage). A rejection NOTICE just re-surfaces
    // the countdown.

    _lastSentText = text;
    _messageController.clear();

    final threadRoot = _openThreadRoot;
    if (threadRoot != null) {
      // The reply lands in the thread's channel, which can differ from the
      // selected channel when a saved thread from another channel is open.
      final targetChannel = threadRoot.channel ?? channel;
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
            channel: targetChannel,
          ),
        );
      } else {
        // Newest-first thread order: the latest reply sits at index 0.
        replyTo = threadMsgs.isNotEmpty ? threadMsgs.first : null;
      }
      _doSendMessage(text, targetChannel, replyTo: replyTo);
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

  Future<void> _openSettings() async {
    _focusNode.unfocus();
    await Navigator.push(
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
          onWhisperNotifyChanged: _setWhisperNotify,
          onMaxMessagesPerChannelChanged: _setMaxMessagesPerChannel,
          onRecentMessagesChanged: _setRecentMessagesLimit,
          onRecentMessagesModeChanged: _setRecentMessagesMode,
          onReplyToRootChanged: _setReplyToRoot,
          onPreferEmotesFirstChanged: _setPreferEmotesFirst,
          onShowTimestampsChanged: _setShowTimestamps,
          onTimestampFormatChanged: _setTimestampFormat,
          onChatFontScaleChanged: _setChatFontScale,
          onEmoteFpsCapChanged: EmoteUrlProvider.applyFpsCap,
          onAnimateGifsChanged: EmoteUrlProvider.applyGifsEnabled,
          onAdaptiveThrottleChanged: EmoteUrlProvider.applyAdaptiveThrottle,
          onAlwaysAnimatePanelChanged: (value) =>
              EmoteUrlProvider.alwaysAnimatePanel = value,
          onCapEmoteFpsChanged: _setCapEmoteFps,
          onCheckeredMessagesChanged: _setCheckeredMessages,
          onHighlightOpacityChanged: _setHighlightOpacity,
          onLineSeparatorChanged: _setLineSeparator,
          onFastSnapChanged: _setFastSnap,
          onNamePaintsChanged: _setNamePaints,
          onEmoteTierChanged: _applyEmoteTier,
          onEmoteCacheMaxChanged: _applyCacheCap,
          onSharedChatModeChanged: _setSharedChatMode,
          onEmoteAutoModeChanged: _applyEmoteAutoMode,
          onNukeEmotes: _nukeEmotes,
          mobileNotifier: _isMobile,
          channelNotifier: _channelNotifier,
          onLeaveChannel: _removeChannel,
          onAddChannel: _addChannel,
          onReorderChannels: _reorderChannels,
          analyticsService: _analytics,
          channels: _chatStore.channels,
          ttsController: _ttsController,
          emoteManager: _emoteManager,
          onStreamExtensionsChanged: _streamPlayer.setShowExtensions,
          onRetainWebviewChanged: _streamPlayer.setRetainWebview,
          onTestWidgetsChanged: _broadcastWidgets.setTestWidgets,
        ),
      ),
    );
    if (_nukePending) {
      _nukePending = false;
      if (!mounted) return;
      NukeOverlay.show(context);
      await _runEmoteRefresh(nuke: true);
    }
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

  FlutterListViewController _scrollCtrl(String channel) {
    return _scrollControllers.putIfAbsent(
      channel,
      () => FlutterListViewController(),
    );
  }

  // Walk the reply-parent chain to the root with cycle detection (visited set).
  // A message that has children is treated as root even if it has a parent
  // (handles nested reply scenarios).
  TwitchMessage? _findThreadRoot(TwitchMessage msg) {
    return _panelManager.findThreadRoot(
      msg,
      channelMessages: _chatStore.channelMessages,
    );
  }

  Future<void> _showThreadView(
    TwitchMessage rootMsg, {
    bool switchChannel = true,
  }) async {
    final channel = rootMsg.channel;
    if (channel == null) return;
    await _panelManager.closePanel();
    if (!mounted) return;
    if (switchChannel && _selectedChannel != channel) {
      final idx = _chatStore.channels.indexOf(channel);
      if (idx >= 0) _onChannelChanged(idx);
    }
    if (!mounted) return;
    setState(() {
      _activePanel = OverlayPanel.thread;
      _openThreadRoot = rootMsg;
    });
    _threadChannel = channel;
    _threadMessages = _computeThreadMessages();
    _threadMsgCount.value++;
    final rootId = rootMsg.replyThreadRootId ?? rootMsg.messageId;
    if (rootId != null) {
      _threadLastSeen['$channel:$rootId'] = DateTime.now();
      _threadsListVersion.value++;
    }
    // Jump, don't animate: the panel opens already on the Thread tab, so an
    // animateTo would flash the strip swiping over from Active/Saved.
    _threadsTabCtrl.index = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _panelManager.animateRatio(
          _panelManager.threadSheetRatio,
          0.0,
          _PanelManager.fullHeightFraction,
          _PanelManager.sheetAnimDuration,
        );
      }
    });
  }

  // Opens the threads dashboard (Thread | Active | Saved tabs) without
  // dropping a currently open thread: the Thread tab keeps its rows so the
  // dashboard can be browsed and returned from.
  Future<void> _showThreadsDashboard({int tab = 1}) async {
    final prevRoot = _openThreadRoot;
    final prevMsgs = List.of(_threadMessages);
    final prevChannel = _threadChannel;
    await _panelManager.closePanel();
    if (!mounted) return;
    _focusNode.unfocus();
    setState(() {
      _activePanel = OverlayPanel.thread;
    });
    // closePanel clears the manager's root; restore the open thread so the
    // Thread tab survives dashboard browsing. Active stays per selected
    // channel; the Thread tab may show another channel's thread.
    _openThreadRoot = prevRoot;
    _panelManager.openThreadRoot = prevRoot;
    _threadMessages = prevMsgs;
    _threadChannel = prevRoot?.channel ?? prevChannel ?? _selectedChannel;
    // Same no-flash jump as _showThreadView: the sheet opens already on the
    // requested tab.
    _threadsTabCtrl.index = tab.clamp(0, 2);
    _threadsListVersion.value++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _panelManager.animateRatio(
          _panelManager.threadSheetRatio,
          0.0,
          _PanelManager.fullHeightFraction,
          _PanelManager.sheetAnimDuration,
        );
      }
    });
  }

  Future<void> _loadSavedThreads() async {
    try {
      await _savedThreads.load();
      _syncSavedKeys();
      if (mounted) _threadsListVersion.value++;
    } catch (_) {
      // Corrupt storage never blocks startup; dashboard just starts empty.
    }
  }

  Future<void> _persistSavedThreads() async {
    try {
      await _savedThreads.flush();
    } catch (_) {
      // Best effort; the in-memory list still works for the session.
    }
  }

  void _syncSavedKeys() {
    _chatStore.savedThreadKeys
      ..clear()
      ..addAll(_savedThreads.keys);
  }

  String? _threadRootIdOf(TwitchMessage msg) =>
      msg.replyThreadRootId ?? msg.messageId;

  bool _isThreadSaved(TwitchMessage rootMsg) {
    final channel = rootMsg.channel;
    final rootId = _threadRootIdOf(rootMsg);
    if (channel == null || rootId == null) return false;
    return _savedThreads.isSaved(channel, rootId);
  }

  // Resolves the actual root message for a thread key, so bookmarks snapshot
  // the root's author/text instead of whichever reply the user long-pressed.
  TwitchMessage? _resolveThreadRootMessage(String channel, String rootId) {
    final indexed = _chatStore.threadFor(channel, rootId);
    if (indexed != null) {
      for (final m in indexed) {
        if (m.messageId == rootId) return m;
      }
    }
    final buffered = _chatStore.channelMessages[channel];
    if (buffered != null) {
      for (final m in buffered) {
        if (m.messageId == rootId) return m;
      }
    }
    final logged = _savedThreads.messagesFor(channel, rootId);
    for (final m in logged) {
      if (m.messageId == rootId) return m;
    }
    return null;
  }

  // Newest message of a thread by timestamp (insertion order is not a sort
  // contract: history batches can arrive out of order).
  TwitchMessage? _newestThreadMessage(List<TwitchMessage> msgs) {
    if (msgs.isEmpty) return null;
    var best = msgs.first;
    for (final m in msgs.skip(1)) {
      if (m.timestamp.isAfter(best.timestamp)) best = m;
    }
    return best;
  }

  void _toggleSaveThread(TwitchMessage rootMsg) {
    final channel = rootMsg.channel?.toLowerCase();
    final rootId = _threadRootIdOf(rootMsg);
    if (channel == null || rootId == null) return;
    final resolved = _resolveThreadRootMessage(channel, rootId) ?? rootMsg;
    final willEvict =
        !_savedThreads.isSaved(channel, rootId) &&
        _savedThreads.threads.length >= maxSavedThreads;
    final fullLog = _computeThreadMessagesFor(channel, rootId);
    final saved = _savedThreads.toggle(
      SavedThread.fromMessage(resolved, rootId),
      fullLog.isEmpty ? [resolved] : fullLog,
    );
    _syncSavedKeys();
    unawaited(_persistSavedThreads());
    _threadsListVersion.value++;
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        _snackBar(
          saved
              ? (willEvict ? 'Thread saved (oldest removed)' : 'Thread saved')
              : 'Thread unsaved',
        ),
      );
    }
  }

  // Full log for a thread key: live store first, then the persisted log for
  // saved threads (dedup by id, newest-first). Used at save time and by the
  // thread view so saved threads render fully offline.
  List<TwitchMessage> _computeThreadMessagesFor(String channel, String rootId) {
    final seen = <String>{};
    final out = <TwitchMessage>[];
    void add(TwitchMessage m) {
      final id = m.messageId;
      if (id != null) {
        if (!seen.add(id)) return;
      }
      out.add(m);
    }

    final live = _chatStore.threadFor(channel, rootId);
    if (live != null) {
      for (final m in live) {
        add(m);
      }
    } else {
      final buffered = _chatStore.channelMessages[channel];
      if (buffered != null) {
        final parentOf = <String, String>{};
        for (final m in buffered) {
          if (m.replyToParentId != null && m.messageId != null) {
            parentOf[m.messageId!] = m.replyToParentId!;
          }
        }
        for (final m in buffered) {
          if (threadKeyFor(m, parentOf) == rootId) add(m);
        }
      }
    }
    if (_savedThreads.isSaved(channel, rootId)) {
      for (final m in _savedThreads.messagesFor(channel, rootId)) {
        add(m);
      }
    }
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  void _openActiveThread(ThreadSummary summary, String channel) {
    final msgs = _chatStore.threadFor(channel, summary.rootId);
    TwitchMessage? target = summary.root;
    target ??= msgs?.firstOrNull;
    target ??= _resolveThreadRootMessage(channel, summary.rootId);
    if (target == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(_snackBar('Thread no longer available'));
      return;
    }
    unawaited(_showThreadView(target));
  }

  void _openSavedThread(SavedThread entry) {
    // Saved threads open offline: the persisted log renders even when the
    // channel is not joined, and no channel switch happens in that case.
    final joined = _chatStore.channels.contains(entry.channel);
    final target =
        _resolveThreadRootMessage(entry.channel, entry.rootId) ??
        TwitchMessage(
          login: entry.login.isNotEmpty ? entry.login : 'thread',
          displayName: entry.author.isNotEmpty ? entry.author : entry.login,
          text: '',
          messageId: entry.rootId,
          channel: entry.channel,
        );
    unawaited(_showThreadView(target, switchChannel: joined));
  }

  Future<void> _showMentionsView() async {
    await _panelManager.closePanel();
    if (!mounted) return;
    _focusNode.unfocus();
    setState(() {
      _activePanel = OverlayPanel.mentions;
      _openThreadRoot = null;
    });
    // Pre-create the mentions buffer so the ChatView's list reference stays
    // stable across the first mirrorMentions insertion.
    _chatStore.channelMessages.putIfAbsent(_mentionsChannel, () => []);
    _mentionsMsgCount.value++;
    _whispersMsgCount.value++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _panelManager.animateRatio(
          _panelManager.mentionsSheetRatio,
          0.0,
          _PanelManager.fullHeightFraction,
          _PanelManager.sheetAnimDuration,
        );
      }
    });
  }

  void _showEmoteMenu() {
    _panelManager.showEmoteMenu(
      selectedChannel: _selectedChannel,
      emoteManager: _emoteManager,
      channelUserIds: _chatStore.channelUserIds,
    );
  }

  Future<void> _closeEmoteSheet() {
    iosHaptic(HapticFeedback.lightImpact);
    return _panelManager.closeEmoteSheet();
  }

  void _handlePanelBack() => _panelManager.handlePanelBack();

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

  Future<void> _closePanel() => _panelManager.closePanel();

  Widget _buildOverlaySheet({
    required bool offstage,
    required ValueNotifier<double> ratio,
    required Widget header,
    required Widget body,
  }) => _panelManager.buildOverlaySheet(
    offstage: offstage,
    ratio: ratio,
    header: header,
    body: body,
    context: context,
  );

  Widget _buildSlideUpContent({
    required DraggableScrollableController controller,
    required double totalAvailH,
    required double maxSize,
    required Widget child,
  }) => _panelManager.buildSlideUpContent(
    controller: controller,
    totalAvailH: totalAvailH,
    maxSize: maxSize,
    child: child,
  );

  List<TwitchMessage> _computeThreadMessages() {
    final live = _panelManager.computeThreadMessages(
      openThreadRoot: _openThreadRoot,
      channelMessages: _chatStore.channelMessages,
      threadFor: (ch, rootId) => _chatStore.threadFor(ch, rootId),
    );
    // Saved threads merge the persisted full log so the view survives buffer
    // eviction and restarts. Live rows win on id conflicts.
    final root = _openThreadRoot;
    final channel = root?.channel;
    final rootId = root == null
        ? null
        : (root.replyThreadRootId ?? root.messageId);
    if (channel == null || rootId == null) return live;
    if (!_savedThreads.isSaved(channel, rootId)) return live;
    final seen = <String>{};
    final out = <TwitchMessage>[];
    for (final m in live) {
      final id = m.messageId;
      if (id != null) {
        if (!seen.add(id)) continue;
      }
      out.add(m);
    }
    for (final m in _savedThreads.messagesFor(channel, rootId)) {
      final id = m.messageId;
      if (id != null) {
        if (!seen.add(id)) continue;
      }
      out.add(m);
    }
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  void _showUserProfile(
    String username,
    String? userId, {
    String? displayName,
  }) {
    final channel = _selectedChannel;
    // Buffer snapshot oldest-first like chat; short-lived, so no subscription.
    final history = channel == null
        ? const <TwitchMessage>[]
        : _chatStore
              .recentMessagesFromUser(channel, username)
              .reversed
              .toList();
    // Threads panels top out below the status bar; match that edge here.
    final screenH = MediaQuery.sizeOf(context).height;
    final maxChildSize =
        (screenH - MediaQuery.paddingOf(context).top) / screenH;
    final sheetController = DraggableScrollableController();
    // Compact card: history reveals by scrolling. Detents are card and full
    // only. Releasing below card slides to min, which pops the route, so
    // dismissal never rests mid-way.
    const initialChildSize = 0.42;
    const minExtent = 0.25;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        controller: sheetController,
        initialChildSize: initialChildSize,
        minChildSize: minExtent,
        maxChildSize: maxChildSize,
        expand: false,
        snap: true,
        snapSizes: [initialChildSize, maxChildSize],
        builder: (_, scrollController) => UserProfileSheet(
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
          scrollController: scrollController,
          sheetController: sheetController,
          sheetCollapsedExtent: initialChildSize,
          userMessages: history,
          messageRowBuilder: _buildUserHistoryRow,
        ),
      ),
    ).whenComplete(sheetController.dispose);
  }

  // Read-only history row for the user card: full chat styling, but no
  // profile recursion, menus, or reply affordances. Double-tap copies.
  Widget _buildUserHistoryRow(BuildContext context, TwitchMessage msg) {
    final theme = Theme.of(context);
    // Same background the modal sheet paints, so rows blend into the card.
    final surface =
        theme.bottomSheetTheme.modalBackgroundColor ??
        theme.bottomSheetTheme.backgroundColor ??
        theme.colorScheme.surfaceContainerLow;
    return RepaintBoundary(
      child: ChatMessageTile(
        message: msg,
        channel: msg.channel ?? _selectedChannel ?? '',
        surface: surface,
        textScale:
            MediaQuery.textScalerOf(context).scale(1.0) * _chatFontSize / 14.0,
        buildBadgeSpans: _messageBuilder.buildBadgeSpans,
        buildMessageSpans: _messageBuilder.buildMessageSpans,
        onDoubleTap: () => _copyMessageToClipboard(msg),
        showTimestamp: _showTimestamps,
        timestampFormat: _timestampFormat,
        checkeredMessages: _checkeredMessages,
        highlightOpacity: _highlightOpacity,
        lineSeparator: _lineSeparator,
        sharedChatMode: _sharedChatMode,
        fadeDeleted: false,
        paintService: _showNamePaints ? _sevenTvPaintService : null,
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
        onUseEmote: _emoteManager.markEmoteUsed,
      ),
    );
  }

  // Push-dedup for shared chat: a message you're joined to both sides of
  // arrives once natively and once mirrored, with different room-local `id`s
  // but the same stable `source-id`. Key on that to notify exactly once.
  final _recentMentionPings = <String>{};

  void _onMentionNotification(String channel, TwitchMessage msg) {
    if (!_mentionPush) return;
    if (!_isBackgrounded) return;
    if (msg.isHistory) return;
    // Per-rule opt-in: only rules with "notify" enabled may buzz.
    if (!(msg.highlight?.notify ?? false)) return;
    final pingKey = msg.sourceMessageId ?? msg.messageId;
    if (pingKey != null) {
      if (!_recentMentionPings.add(pingKey)) return;
      while (_recentMentionPings.length > 64) {
        _recentMentionPings.remove(_recentMentionPings.first);
      }
    }
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
    _maybeNotifyWhisper(msg);
    _whispers.insert(0, msg);
    if (_whispers.length > _maxMessagesPerChannel) {
      _whispers.removeRange(_maxMessagesPerChannel, _whispers.length);
    }
    _whisperTarget = msg.login;
    _whispersMsgCount.value++;
    if (!_isWhispersTabActive) {
      _unreadWhispers++;
      _chatStore.unreadMentions++;
    }
    _chatStore.mentionsBump.value++;
  }

  void _addWhisperSystemMessage(String channel, String text) {
    _whispers.insert(
      0,
      TwitchMessage(login: '', text: text, isSystem: true, channel: null),
    );
    if (_whispers.length > _maxMessagesPerChannel) {
      _whispers.removeRange(_maxMessagesPerChannel, _whispers.length);
    }
    _whispersMsgCount.value++;
    _chatStore.mentionsBump.value++;
  }

  void _onWhisperSent(String target, String message) {
    final login = _chatStore.session.login;
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
    _whispersMsgCount.value++;
    _chatStore.mentionsBump.value++;
  }

  void _onMentionsTabChanged() {
    // TabController notifies on every animation tick while a swipe is in
    // progress; rebuilding the whole screen per frame is wasted work.
    if (_mentionsTabCtrl.indexIsChanging) return;
    iosHaptic(HapticFeedback.selectionClick);
    if (_mentionsTabCtrl.index == 1 && _unreadWhispers > 0) {
      _chatStore.unreadMentions -= _unreadWhispers;
      if (_chatStore.unreadMentions < 0) _chatStore.unreadMentions = 0;
      _unreadWhispers = 0;
      _chatStore.mentionsBump.value++;
    }
    setState(() {});
  }

  void _onThreadsTabChanged() {
    if (_threadsTabCtrl.indexIsChanging) return;
    iosHaptic(HapticFeedback.selectionClick);
    // Returning to the Thread tab marks the open thread seen so its Active
    // row clears its unread highlight.
    if (_threadsTabCtrl.index == 0 && _openThreadRoot != null) {
      final channel = _openThreadRoot!.channel;
      final rootId =
          _openThreadRoot!.replyThreadRootId ?? _openThreadRoot!.messageId;
      if (channel != null && rootId != null) {
        _threadLastSeen['$channel:$rootId'] = DateTime.now();
        _threadsListVersion.value++;
      }
    }
    setState(() {});
  }

  void _showWhispersForUser(String login) {
    _whisperTarget = login;
    if (_activePanel != OverlayPanel.mentions) {
      _showMentionsView();
    }
    _mentionsTabCtrl.animateTo(1);
    _chatStore.unreadMentions -= _unreadWhispers;
    if (_chatStore.unreadMentions < 0) _chatStore.unreadMentions = 0;
    _unreadWhispers = 0;
    _chatStore.mentionsBump.value++;
    _focusNode.requestFocus();
  }

  void _onNotificationTap(String channel) {
    _navigateToChannel(channel);
  }

  void _navigateToChannel(String channel) {
    final index = _chatStore.channels.indexOf(channel);
    if (index >= 0) {
      _onChannelChanged(index);
    }
  }

  // Single selection commit for BOTH entry points (swipe-tick focus and
  // settle/tab-tap). Whichever lands first owns the side effects; the shared
  // guard makes the second one a no-op, so bookkeeping runs exactly once per
  // real switch regardless of gesture timing.
  void _commitChannelSelection(int index, {required bool rebuild}) {
    final channel = _chatStore.channels[index];
    if (_selectedChannel == channel) return;
    unawaited(_closePanel());
    var clearedUnread = 0;
    void mutate() {
      iosHaptic(HapticFeedback.selectionClick);
      _selectedChannel = channel;
      _updateCooldownLabel();
      _chatStore.channelsWithUnread.remove(channel);
      _chatStore.channelsWithUnreadMentions.remove(channel);
      _chatStore.unreadVersion.value++;
      clearedUnread = _chatStore.unreadMentionsPerChannel.remove(channel) ?? 0;
      if (clearedUnread > 0) {
        _chatStore.unreadMentions -= clearedUnread;
        if (_chatStore.unreadMentions < 0) _chatStore.unreadMentions = 0;
      }
      _openThreadRoot = null;
      if (_suggestionsNotifier.value.isNotEmpty) {
        _suggestionsNotifier.value = [];
      }
      _cachedAutocompleteEmotes = null;
    }

    if (rebuild) {
      setState(mutate);
    } else {
      mutate();
      // Focus changes (swipes) skip the setState path, so bump the bell's
      // notifier directly to refresh the badge color.
      if (clearedUnread > 0) _chatStore.mentionsBump.value++;
    }
    if (clearedUnread > 0 && _mentionPush) {
      unawaited(_notificationService.clearMentionNotifications(channel));
    }
    _broadcastWidgets.resetPage();
    _selectedTabIndex.value = index;
    _chatConn.focusChannel(channel);
  }

  void _onChannelFocusChanged(int index) {
    _commitChannelSelection(index, rebuild: false);
  }

  void _onChannelChanged(int index) {
    _commitChannelSelection(index, rebuild: true);
  }

  // The input-box override text while you cannot send in the visible
  // channel: your remaining timeout wins over the slow-mode window.
  String? _cooldownLabel() {
    final channel = _selectedChannel;
    if (channel == null || !_chatStore.channels.contains(channel)) return null;
    final timeout = _chatConn.remainingSelfTimeout(channel);
    if (timeout != null) return 'Timed out: ${formatSeconds(timeout)}';
    final slow = _chatConn.remainingSlowCooldown(channel);
    if (slow != null) return 'Slow mode: ${formatSeconds(slow)}';
    return null;
  }

  void _updateCooldownLabel() =>
      _cooldownLabelNotifier.value = _cooldownLabel();

  // Retroactive mention scan: runs once on login. Hits are batched and
  // mirrored through ChatStore, which sorts the mentions buffer newest-first
  // regardless of the (newest-first) channel-buffer iteration order.
  void _scanHistoryForMentions() {
    if (_mentionScanDone || _chatStore.session.login == null) return;
    _mentionScanDone = true;
    final hits = <TwitchMessage>[];
    for (final entry in _chatStore.channelMessages.entries) {
      if (entry.key == _mentionsChannel) continue;
      for (final msg in entry.value) {
        if (msg.highlight != null) continue;
        final state = _pingManager.evaluate(msg);
        if (state == null || !state.hasMention) continue;
        msg.highlight = state;
        hits.add(msg);
      }
    }
    if (hits.isNotEmpty) {
      _chatStore.mirrorMentions(
        _mentionsChannel,
        hits,
        maxMessages: _maxMessagesPerChannel,
      );
    }
  }

  void _truncateChannelMessages(String channel) {
    _chatStore.truncateChannel(channel, maxMessages: _maxMessagesPerChannel);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop:
          !_isFullscreen &&
          !_streamPlayer.isTheaterMode &&
          _activePanel == OverlayPanel.closed &&
          !_emoteSheetOpen &&
          !_focusNode.hasFocus,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_emoteSheetOpen) {
          unawaited(_closeEmoteSheet());
        } else if (_activePanel != OverlayPanel.closed) {
          unawaited(_closePanel());
        } else if (_streamPlayer.isTheaterMode) {
          _streamPlayer.exitTheaterMode();
        } else if (_isFullscreen) {
          _toggleFullscreen();
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
                  final statusBarH = MediaQuery.paddingOf(context).top;
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
                  // Collapse the top chrome when the keyboard eats so much
                  // vertical space that the chat would overflow. The composer
                  // already pads itself up by the inset, so constraints already
                  // reflect the space left; rebuild fires automatically on
                  // inset changes.
                  final keyboardH = MediaQuery.viewInsetsOf(context).bottom;
                  final hideChromeForKeyboard =
                      keyboardH > 0 &&
                      constraints.maxHeight <
                          _kKeyboardChromeCollapseBelowHeight;
                  return Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      ListenableBuilder(
                        listenable: _streamPlayer,
                        builder: (_, _) => _buildBodyColumn(
                          hideChromeForKeyboard: hideChromeForKeyboard,
                          maxWidth: constraints.maxWidth,
                          maxHeight: constraints.maxHeight,
                          keyboardH: keyboardH,
                        ),
                      ),
                      _buildThreadPanel(),
                      _buildMentionsPanel(),
                      _buildEmotePicker(sheetBoxHeight: sheetBoxHeight),
                      // Autocomplete dropdown - floats above chat, anchored just
                      // above the message input, 60% width like DankChat's popup.
                      Positioned(
                        bottom: 0,
                        left: 0,
                        child: SizedBox(
                          width: (MediaQuery.sizeOf(context).width * 0.6).clamp(
                            0.0,
                            340.0,
                          ),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.sizeOf(context).height * 0.25,
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
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              child: _showInput
                  ? _buildInputBar(theme: theme)
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  /// Whether the selected channel's JOIN is confirmed on the write socket.
  /// Between socket-connect and join-confirm, PRIVMSGs would vanish - the
  /// input stays disabled for that window. Whispers are not channel-bound.
  bool get _channelChatReady =>
      _selectedChannel != null &&
      _chatConn.isChannelChatReady(_selectedChannel!);

  /// Stream layout selector (DankChat MainScreen): landscape theater first,
  /// then wide split, else the stacked portrait player above chat.
  Widget _buildBodyColumn({
    required bool hideChromeForKeyboard,
    required double maxWidth,
    required double maxHeight,
    required double keyboardH,
  }) {
    final channel = _streamPlayer.currentChannel;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    if (channel != null &&
        !_streamPlayer.isAudioOnly &&
        _streamPlayer.isTheaterMode &&
        landscape) {
      return Column(children: [Expanded(child: _buildTheater(channel))]);
    }
    if (channel != null && !_streamPlayer.isAudioOnly && maxWidth >= 600) {
      return Column(
        children: [Expanded(child: _buildSplit(channel, maxWidth))],
      );
    }
    final showVideo =
        channel == null ||
        _showStreamVideo(
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          keyboardH: keyboardH,
        );
    final showPlayerVideo =
        showVideo && channel != null && !_streamPlayer.isAudioOnly;
    final aboveTabsH = channel == null
        ? 0.0
        : showPlayerVideo
        ? maxWidth * 9 / 16
        : _audioBarHeight;
    return Column(
      children: [
        AnimatedSize(
          duration: hideChromeForKeyboard
              ? const Duration(milliseconds: 1)
              : const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          child: !_isFullscreen && !hideChromeForKeyboard
              ? _buildAppBar()
              : const SizedBox.shrink(),
        ),
        _buildChannelTabs(
          hideChrome: hideChromeForKeyboard,
          overlayTop: 50 + aboveTabsH,
          belowTabBar: channel == null
              ? null
              : _buildStackedPlayer(channel, showVideo),
        ),
      ],
    );
  }

  // DankChat shouldShowStream: hide video when the keyboard leaves under
  // 9 chat lines; audio keeps playing.
  bool _showStreamVideo({
    required double maxWidth,
    required double maxHeight,
    required double keyboardH,
  }) {
    if (keyboardH <= 0) return true;
    final inputH = _showInput
        ? (_inputBarKey.currentContext?.size?.height ?? 56)
        : 0;
    final streamH = maxWidth * 9 / 16;
    return maxHeight - keyboardH - streamH - inputH >= _chatFontSize * 9;
  }

  Widget _playerView(
    String channel, {
    bool fillPane = false,
    bool visible = true,
  }) {
    final key = _streamPlayer.retainWebview ? 'stream' : 'stream:$channel';
    return StreamPlayerView(
      key: ValueKey(key),
      controller: _streamPlayer,
      channel: channel,
      fillPane: fillPane,
      visible: visible,
    );
  }

  Widget _buildStackedPlayer(String channel, bool showVideo) {
    final show = showVideo && !_streamPlayer.isAudioOnly;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Visibility(
          visible: show,
          maintainState: true,
          maintainAnimation: true,
          child: _playerView(channel, visible: show),
        ),
        if (!show)
          StreamAudioBar(
            key: ValueKey('audio:$channel'),
            controller: _streamPlayer,
            channel: channel,
          ),
      ],
    );
  }

  // Landscape theater: full-bleed video with a translucent chat overlay.
  // The WebView keeps full size and is never resized (DankChat TheaterLayout).
  Widget _buildTheater(String channel) {
    final scheme = Theme.of(context).colorScheme;
    final panelW = (MediaQuery.sizeOf(context).width - 120).clamp(200.0, 320.0);
    return Stack(
      children: [
        Positioned.fill(child: _playerView(channel, fillPane: true)),
        if (_theaterChatVisible)
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: panelW,
            child: ColoredBox(
              color: scheme.surface.withValues(alpha: 0.92),
              child: SafeArea(
                left: false,
                child: _buildChannelStack(hideChrome: true, overlayTop: 8),
              ),
            ),
          ),
        Positioned(
          bottom: 16,
          right: _theaterChatVisible ? panelW + 8 : 8,
          child: FloatingActionButton.small(
            heroTag: 'theater_chat_toggle',
            tooltip: _theaterChatVisible ? 'Hide chat' : 'Show chat',
            onPressed: () =>
                setState(() => _theaterChatVisible = !_theaterChatVisible),
            child: Icon(
              _theaterChatVisible ? Icons.visibility_off : Icons.visibility,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSplit(String channel, double maxWidth) {
    var dragFrac = _streamPlayer.splitFraction;
    return StatefulBuilder(
      builder: (context, setLocal) {
        return Row(
          children: [
            SizedBox(
              width: maxWidth * dragFrac,
              child: _playerView(channel, fillPane: true),
            ),
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (details) => setLocal(() {
                dragFrac = (dragFrac + details.delta.dx / maxWidth).clamp(
                  0.2,
                  0.8,
                );
              }),
              onHorizontalDragEnd: (_) =>
                  _streamPlayer.setSplitFraction(dragFrac),
              child: const SizedBox(
                width: 16,
                child: Center(
                  child: SizedBox(
                    width: 4,
                    height: 48,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.grey,
                        borderRadius: BorderRadius.all(Radius.circular(2)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _buildChannelStack(hideChrome: false, overlayTop: 50),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAppBar() {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      'ErmChat',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                  const Spacer(),
                  ListenableBuilder(
                    listenable: Listenable.merge([
                      _chatConn.connectionStateNotifier,
                      _networkBusy,
                    ]),
                    builder: (context, _) {
                      final busy =
                          !HomeScreen.disableJoinSpinner &&
                          (_chatLoading || _networkBusy.value);
                      return IconButton(
                        icon: busy
                            ? SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: IconTheme.of(context).color,
                                ),
                              )
                            : const Icon(Icons.add),
                        tooltip: busy ? 'Loading...' : 'Join channel',
                        onPressed:
                            busy || _chatStore.channels.length >= kMaxChannels
                            ? null
                            : _addChannelDialog,
                      );
                    },
                  ),
                  ListenableBuilder(
                    listenable: _chatStore.mentionsBump,
                    builder: (context, _) => IconButton(
                      icon: Icon(
                        Icons.notifications_active,
                        color: _chatStore.unreadMentions > 0
                            ? theme.colorScheme.error
                            : null,
                      ),
                      tooltip: 'Mentions',
                      onPressed: () {
                        _chatStore.unreadMentions = 0;
                        _unreadWhispers = 0;
                        _chatStore.channelsWithUnreadMentions.clear();
                        _chatStore.unreadMentionsPerChannel.clear();
                        _chatStore.unreadVersion.value++;
                        if (mounted) setState(() {});
                        if (_activePanel == OverlayPanel.mentions) {
                          unawaited(_closePanel());
                        } else {
                          _showMentionsView();
                        }
                      },
                    ),
                  ),
                  PopupMenuButton<String>(
                    popUpAnimationStyle: const AnimationStyle(
                      duration: Duration(milliseconds: 175),
                    ),
                    onSelected: (value) {
                      switch (value) {
                        case 'threads':
                          _showThreadsDashboard(tab: 1);
                          break;
                        case 'upload':
                          _uploadController.pickAndUpload(context);
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
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'settings',
                        child: Row(
                          children: [
                            Icon(Icons.settings, size: 20),
                            SizedBox(width: 12),
                            Text('Settings'),
                          ],
                        ),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'threads',
                        child: Row(
                          children: [
                            Icon(Icons.forum, size: 20),
                            SizedBox(width: 12),
                            Text('Threads'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'upload',
                        child: Text('Upload media'),
                      ),
                      const PopupMenuItem(
                        value: 'reload_emotes',
                        child: Text('Reload emotes'),
                      ),
                      const PopupMenuItem(
                        value: 'reconnect',
                        child: Text('Reconnect'),
                      ),
                    ],
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
    );
  }

  Widget _buildChannelTabs({
    required bool hideChrome,
    double overlayTop = 50,
    Widget? belowTabBar,
  }) {
    return Expanded(
      child: _buildChannelStack(
        hideChrome: hideChrome,
        overlayTop: overlayTop,
        belowTabBar: belowTabBar,
      ),
    );
  }

  Widget _buildChannelStack({
    required bool hideChrome,
    required double overlayTop,
    Widget? belowTabBar,
  }) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            _suggestionsNotifier.value = [];
          },
          child: _chatStore.channels.isNotEmpty
              ? TabbedLayout(
                  tabs: _chatStore.channels,
                  selectedIndex: _chatStore.channels.indexOf(
                    _selectedChannel ?? '',
                  ),
                  onSelectedIndexChanged: _onChannelChanged,
                  onFocusChanged: _onChannelFocusChanged,
                  onTabTapped: (index) {
                    final channel = _chatStore.channels[index];
                    final ctrl = _scrollCtrl(channel);
                    if (ctrl.hasClients) ctrl.jumpTo(0);
                    _atBottomNotifier(channel).value = true;
                  },
                  showTabBar: !_isFullscreen && !hideChrome,
                  tabBarAnimationDuration: hideChrome
                      ? const Duration(milliseconds: 1)
                      : const Duration(milliseconds: 200),
                  chromeMenu: _buildChromeMenu(),
                  belowTabBar: belowTabBar,
                  pageBuilder: (_, i) {
                    final channel = _chatStore.channels[i];
                    return ListenableBuilder(
                      listenable: _versionNotifier(channel),
                      builder: (_, _) => ChatView(
                        channel: channel,
                        messages: _chatStore.channelMessages[channel] ?? [],
                        tileCache: _tileCache,
                        atBottomNotifier: _atBottomNotifier(channel),
                        messageNotifier: _messageNotifier(channel),
                        scrollController: _scrollCtrl(channel),
                        messageBuilder: _messageBuilder,
                        linkWhitelist: _linkWhitelist,
                        showTimestamp: _showTimestamps,
                        timestampFormat: _timestampFormat,
                        chatFontScale: _chatFontSize / 14.0,
                        checkeredMessages: _checkeredMessages,
                        highlightOpacity: _highlightOpacity,
                        lineSeparator: _lineSeparator,
                        sharedChatMode: _sharedChatMode,
                        paintService: _showNamePaints
                            ? _sevenTvPaintService
                            : null,
                        onShowUserProfile: (login, userId, {displayName}) =>
                            _showUserProfile(
                              login,
                              userId,
                              displayName: displayName,
                            ),
                        onShowMessageMenu: _showMessageMenu,
                        onCopyMessage: _copyMessageToClipboard,
                        onNewMessage: _chatStore.noteNewMessage,
                        onFindThreadRoot: _findThreadRoot,
                        onShowThreadView: _showThreadView,
                        keyboardDismissBehavior: (!kIsWeb && Platform.isIOS)
                            ? ScrollViewKeyboardDismissBehavior.onDrag
                            : ScrollViewKeyboardDismissBehavior.manual,
                      ),
                    );
                  },
                  focusOnHalfDrag: true,
                  fastSnap: _fastSnap,
                  tabBuilder: (_, i) {
                    final channel = _chatStore.channels[i];
                    return ListenableBuilder(
                      listenable: _tabMergeCache.putIfAbsent(
                        i,
                        () => Listenable.merge([
                          _selectedTabIndex,
                          _chatStore.unreadVersion,
                        ]),
                      ),
                      builder: (ctx, _) {
                        final focused = i == _selectedTabIndex.value;
                        final selected = focused || channel == _selectedChannel;
                        final hasUnreadMention = _chatStore
                            .channelsWithUnreadMentions
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
                                        _chatStore.channelsWithUnread.contains(
                                          channel,
                                        )
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: selected
                                    ? theme.colorScheme.primary
                                    : _chatStore.channelsWithUnread.contains(
                                        channel,
                                      )
                                    ? theme.colorScheme.onSurface
                                    : null,
                              ),
                            ),
                            if (hasUnreadMention && !selected)
                              Positioned(
                                top: -2,
                                right: -4,
                                child: Container(
                                  key: const Key('unread_mention_dot'),
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.error,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    );
                  },
                )
              : _buildWelcomeChatView(),
        ),
        if (_selectedChannel != null)
          Positioned(
            top: overlayTop,
            left: 0,
            right: 0,
            child: ValueListenableBuilder<int>(
              valueListenable: _broadcastWidgets.notifier,
              builder: (_, _, _) =>
                  _broadcastWidgets.buildOverlay(
                    _selectedChannel!,
                    onMinimizeChanged: (ch, minimized) {
                      _broadcastWidgets.widgetsMinimized[ch] = minimized;
                      _broadcastWidgets.notifier.value++;
                    },
                  ) ??
                  const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }

  Widget _buildThreadPanel() {
    return _buildOverlaySheet(
      offstage: _activePanel != OverlayPanel.thread,
      ratio: _threadSheetRatio,
      header: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: _closePanel,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Threads',
                    style: TextStyle(
                      fontSize: 20,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
          TabBar(
            controller: _threadsTabCtrl,
            padding: EdgeInsets.fromLTRB(100.0, 0.0, 100.0, 0.0),
            // Three tabs in the mentions-width island: center the strip so it
            // reads the same, and let it scroll instead of clipping labels on
            // narrow phones.
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            tabs: const [
              Tab(text: 'Thread'),
              Tab(text: 'Active'),
              Tab(text: 'Saved'),
            ],
          ),
          Divider(height: 1, color: Theme.of(context).dividerColor),
        ],
      ),
      body: TabBarView(
        controller: _threadsTabCtrl,
        children: [
          ChatView(
            key: const ValueKey('thread_panel'),
            channel: _threadChannel ?? '',
            messages: _threadMessages,
            atBottomNotifier: _threadAtBottom,
            messageNotifier: _threadMsgCount,
            scrollController: _threadPanelScrollCtrl,
            messageBuilder: _messageBuilder,
            showTimestamp: _showTimestamps,
            timestampFormat: _timestampFormat,
            chatFontScale: _chatFontSize / 14.0,
            checkeredMessages: _checkeredMessages,
            highlightOpacity: _highlightOpacity,
            lineSeparator: _lineSeparator,
            sharedChatMode: _sharedChatMode,
            paintService: _showNamePaints ? _sevenTvPaintService : null,
            onShowUserProfile: _showUserProfile,
            onShowMessageMenu: _showPanelMessageMenu,
            onCopyMessage: _copyMessageToClipboard,
            showReplyIndicators: false,
            emptyText: 'No messages found',
          ),
          _buildActiveThreadsList(),
          _buildSavedThreadsList(),
        ],
      ),
    );
  }

  bool _isThreadUnread(String channel, ThreadSummary summary) {
    final seen = _threadLastSeen['$channel:${summary.rootId}'];
    if (seen == null) return true;
    return summary.lastActivity.isAfter(seen);
  }

  Widget _buildActiveThreadsList() {
    return ValueListenableBuilder<int>(
      valueListenable: _threadsListVersion,
      builder: (context, _, _) {
        final channel = _selectedChannel ?? _threadChannel;
        if (channel == null) {
          return const Center(child: Text('Join a channel to see threads'));
        }
        final threads = _chatStore.activeThreads(channel);
        if (threads.isEmpty) {
          return const Center(child: Text('No active threads'));
        }
        final theme = Theme.of(context);
        return ListView.builder(
          itemCount: threads.length,
          itemBuilder: (context, i) {
            final summary = threads[i];
            final unread = _isThreadUnread(channel, summary);
            // Orphan threads have no root yet; show the newest reply by
            // timestamp so the row still identifies the conversation.
            final live = _chatStore.threadFor(channel, summary.rootId);
            final display =
                summary.root ??
                (live == null ? null : _newestThreadMessage(live));
            final author = display != null
                ? (display.displayName.isNotEmpty
                      ? display.displayName
                      : display.login)
                : 'Thread';
            final preview = display != null ? display.text : '';
            final saved = _savedThreads.isSaved(channel, summary.rootId);
            return ListTile(
              leading: const Icon(Icons.forum),
              title: Text(
                preview.isEmpty ? author : '$author: $preview',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
                  color: unread ? theme.colorScheme.onSurface : null,
                ),
              ),
              subtitle: Text(
                '${summary.replyCount} '
                '${summary.replyCount == 1 ? 'reply' : 'replies'}'
                ' · ${formatTimestamp(summary.lastActivity, _timestampFormat)}',
              ),
              trailing: display == null
                  ? null
                  : IconButton(
                      icon: Icon(
                        saved ? Icons.bookmark : Icons.bookmark_border,
                      ),
                      tooltip: saved ? 'Unsave thread' : 'Save thread',
                      onPressed: () => _toggleSaveThread(display),
                    ),
              onTap: () => _openActiveThread(summary, channel),
            );
          },
        );
      },
    );
  }

  Widget _buildSavedThreadsList() {
    return ValueListenableBuilder<int>(
      valueListenable: _threadsListVersion,
      builder: (context, _, _) {
        final saved = _savedThreads.threads;
        if (saved.isEmpty) {
          return const Center(child: Text('No saved threads yet'));
        }
        return ListView.builder(
          itemCount: saved.length,
          itemBuilder: (context, i) {
            final entry = saved[i];
            return ListTile(
              leading: const Icon(Icons.bookmark),
              title: Text(
                entry.preview.isEmpty
                    ? entry.author
                    : '${entry.author}: ${entry.preview}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('#${entry.channel}'),
              trailing: IconButton(
                icon: const Icon(Icons.bookmark),
                tooltip: 'Unsave thread',
                onPressed: () {
                  _savedThreads.remove(entry.channel, entry.rootId);
                  _syncSavedKeys();
                  unawaited(_persistSavedThreads());
                  _threadsListVersion.value++;
                  if (mounted) {
                    setState(() {});
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(_snackBar('Thread unsaved'));
                  }
                },
              ),
              onTap: () => _openSavedThread(entry),
            );
          },
        );
      },
    );
  }

  Widget _buildMentionsPanel() {
    return _buildOverlaySheet(
      offstage: _activePanel != OverlayPanel.mentions,
      ratio: _mentionsSheetRatio,
      header: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
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
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
          TabBar(
            controller: _mentionsTabCtrl,
            padding: EdgeInsets.fromLTRB(100.0, 0.0, 100.0, 0.0),
            tabs: const [
              Tab(text: 'Mentions'),
              Tab(text: 'Whispers'),
            ],
          ),
          Divider(height: 1, color: Theme.of(context).dividerColor),
        ],
      ),
      body: TabBarView(
        controller: _mentionsTabCtrl,
        children: [
          ChatView(
            key: const ValueKey('mentions_panel'),
            channel: _mentionsChannel,
            messages: _chatStore.channelMessages[_mentionsChannel] ?? const [],
            atBottomNotifier: _mentionsAtBottom,
            messageNotifier: _mentionsMsgCount,
            scrollController: _mentionsPanelScrollCtrl,
            messageBuilder: _messageBuilder,
            linkWhitelist: _linkWhitelist,
            showTimestamp: _showTimestamps,
            timestampFormat: _timestampFormat,
            chatFontScale: _chatFontSize / 14.0,
            checkeredMessages: _checkeredMessages,
            highlightOpacity: _highlightOpacity,
            lineSeparator: _lineSeparator,
            sharedChatMode: _sharedChatMode,
            physics: const ClampingScrollPhysics(),
            onShowUserProfile: _showUserProfile,
            onShowMessageMenu: _showPanelMessageMenu,
            onCopyMessage: _copyMessageToClipboard,
            showReplyIndicators: false,
            fadeDeleted: false,
            emptyText: 'No mentions or whispers',
          ),
          ChatView(
            key: const ValueKey('whispers_panel'),
            channel: '@whispers',
            messages: _whispers,
            atBottomNotifier: _whispersAtBottom,
            messageNotifier: _whispersMsgCount,
            scrollController: _whispersPanelScrollCtrl,
            messageBuilder: _messageBuilder,
            linkWhitelist: _linkWhitelist,
            showTimestamp: _showTimestamps,
            timestampFormat: _timestampFormat,
            chatFontScale: _chatFontSize / 14.0,
            checkeredMessages: _checkeredMessages,
            highlightOpacity: _highlightOpacity,
            lineSeparator: _lineSeparator,
            sharedChatMode: _sharedChatMode,
            physics: const ClampingScrollPhysics(),
            onShowUserProfile: _showUserProfile,
            onShowMessageMenu: _showPanelMessageMenu,
            onCopyMessage: _copyMessageToClipboard,
            showReplyIndicators: false,
            emptyText: 'No whispers',
          ),
        ],
      ),
    );
  }

  Widget _buildEmotePicker({required double sheetBoxHeight}) {
    return Positioned(
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
    );
  }

  Widget _buildInputBar({required ThemeData theme}) {
    return Builder(
      builder: (ctx) {
        final inset = MediaQuery.viewInsetsOf(ctx).bottom;
        final pad = MediaQuery.paddingOf(ctx).bottom;
        return Padding(
          key: _inputBarKey,
          padding: EdgeInsets.only(bottom: inset + pad),
          child: ColoredBox(
            color: theme.scaffoldBackgroundColor,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListenableBuilder(
                  listenable: Listenable.merge([
                    _cooldownLabelNotifier,
                    _chatConn.connectionStateNotifier,
                  ]),
                  builder: (context, _) {
                    return MessageInput(
                      controller: _messageController,
                      focusNode: _focusNode,
                      onSend: _sendMessage,
                      onSendLongPress: _onSendLongPress,
                      onTap: () => _suggestionsNotifier.value = [],
                      onEmoteToggle: () {
                        PerfLog.I.record(
                          'EmoteSheet',
                          'toggle: open=$_emoteSheetOpen',
                        );
                        if (_emoteSheetOpen) {
                          unawaited(_closeEmoteSheet());
                        } else {
                          _showEmoteMenu();
                        }
                      },
                      replyToMsg: _replyToMsg,
                      onCancelReply: () => setState(() => _replyToMsg = null),
                      enabled:
                          (_activePanel != OverlayPanel.mentions ||
                              _isWhispersTabActive) &&
                          (_activePanel != OverlayPanel.thread ||
                              _threadsTabCtrl.index == 0) &&
                          widget.twitchAuth.isConfigured &&
                          _chatConn.isChatPipeConnected &&
                          (_isWhispersTabActive || _channelChatReady),
                      hintText:
                          _cooldownLabelNotifier.value ??
                          (!widget.twitchAuth.isConfigured
                              ? 'Connect an account to chat'
                              : switch ((
                                  _chatConn.connectPhase,
                                  _activePanel,
                                  _isWhispersTabActive,
                                  _channelChatReady,
                                )) {
                                  (ChatPhase.connecting, _, _, _) =>
                                    'Connecting...',
                                  (ChatPhase.reconnecting, _, _, _) =>
                                    'Reconnecting...',
                                  (ChatPhase.online, _, false, false)
                                      when _selectedChannel != null =>
                                    'Disconnected',
                                  (_, OverlayPanel.thread, _, _)
                                      when _threadsTabCtrl.index == 0 =>
                                    'Reply to thread...',
                                  (_, OverlayPanel.thread, _, _) =>
                                    'Select a thread to reply...',
                                  (_, _, true, _) =>
                                    _whisperTarget != null
                                        ? 'Whisper to $_whisperTarget...'
                                        : 'Type /w <username> <message>',
                                  (_, OverlayPanel.mentions, _, _) =>
                                    'Type a message...',
                                  _ => null,
                                }),
                    );
                  },
                ),
                ListenableBuilder(
                  listenable: Listenable.merge([
                    _versionNotifier(_selectedChannel ?? ''),
                    _selectedTabIndex,
                    _chatStore.loadFailedChannels,
                  ]),
                  builder: (context, _) {
                    final status = _chatStore.chatStatus[_selectedChannel];
                    final hasStatus = status != null && status.isNotEmpty;
                    final hasLoadFailure =
                        _selectedChannel != null &&
                        _chatStore.loadFailedChannels.value.contains(
                          _selectedChannel,
                        );
                    return AnimatedSize(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      alignment: Alignment.topCenter,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (hasStatus)
                            Padding(
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
                            ),
                          if (hasLoadFailure)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: InkWell(
                                onTap: () => _chatConn.retryChannelData(
                                  _selectedChannel!,
                                ),
                                child: Text(
                                  'Retry failed emotes/badges',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static const _welcomeChannel = '__welcome__';

  Widget _buildWelcomeChatView() {
    final configured = widget.twitchAuth.isConfigured;
    final login = widget.twitchAuth.login;
    final key = '$configured:$login';
    if (_welcomeMessagesKey != key) {
      _welcomeMessagesKey = key;
      _welcomeMessages = [
        if (!configured)
          TwitchMessage(
            login: '',
            text: 'Configure Twitch credentials in Settings first',
            isSystem: true,
            messageId: 'welcome',
            channel: _welcomeChannel,
          )
        else ...[
          if (login != null)
            TwitchMessage(
              login: '',
              text: 'Signed in as $login',
              isSystem: true,
              messageId: 'welcome-signin',
              channel: _welcomeChannel,
            ),
          TwitchMessage(
            login: '',
            text: 'Press + to join a channel.',
            isSystem: true,
            messageId: 'welcome-join',
            channel: _welcomeChannel,
          ),
        ],
      ];
    }
    return ChatView(
      channel: _welcomeChannel,
      messages: _welcomeMessages!,
      tileCache: _tileCache,
      atBottomNotifier: _atBottomNotifier(_welcomeChannel),
      messageNotifier: _messageNotifier(_welcomeChannel),
      scrollController: _scrollCtrl(_welcomeChannel),
      messageBuilder: _messageBuilder,
      linkWhitelist: _linkWhitelist,
      showTimestamp: _showTimestamps,
      timestampFormat: _timestampFormat,
      chatFontScale: _chatFontSize / 14.0,
      checkeredMessages: _checkeredMessages,
      highlightOpacity: _highlightOpacity,
      lineSeparator: _lineSeparator,
      sharedChatMode: _sharedChatMode,
      paintService: _showNamePaints ? _sevenTvPaintService : null,
      onShowUserProfile: (login, userId, {displayName}) =>
          _showUserProfile(login, userId, displayName: displayName),
      keyboardDismissBehavior: (!kIsWeb && Platform.isIOS)
          ? ScrollViewKeyboardDismissBehavior.onDrag
          : ScrollViewKeyboardDismissBehavior.manual,
    );
  }
}

class _BroadcastWidgets {
  _BroadcastWidgets({required this.selectedChannel});

  final String? Function() selectedChannel;
  final notifier = ValueNotifier<int>(0);

  final hypeTrains = <String, HypeTrainEvent>{};
  final polls = <String, PollEvent>{};
  final predictions = <String, PredictionEvent>{};
  final widgetsMinimized = <String, bool>{};
  final pageCtrl = PageController();

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

  bool mounted = true;

  void dispose() {
    mounted = false;
    _testWidgetsTimer?.cancel();
    pageCtrl.dispose();
    notifier.dispose();
  }

  void onHypeTrain(HypeTrainEvent event) {
    if (!mounted) return;
    if (event.kind == 'end') {
      hypeTrains.remove(event.channel);
    } else {
      hypeTrains[event.channel] = event;
    }
    notifier.value++;
    clampPage();
  }

  void onPoll(PollEvent event) {
    if (!mounted) return;
    if (event.kind == 'end') {
      polls.remove(event.channel);
    } else {
      polls[event.channel] = event;
    }
    notifier.value++;
    clampPage();
  }

  void onPrediction(PredictionEvent event) {
    if (!mounted) return;
    if (event.kind == 'end') {
      predictions.remove(event.channel);
    } else {
      predictions[event.channel] = event;
    }
    notifier.value++;
    clampPage();
  }

  Future<void> loadTestWidgets() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    applyTestWidgets(prefs.getBool('test_chat_widgets') ?? false);
  }

  void setTestWidgets(bool value) {
    if (!mounted) return;
    applyTestWidgets(value);
  }

  void applyTestWidgets(bool value) {
    if (value) {
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
    hypeTrains.clear();
    polls.clear();
    predictions.clear();
    widgetsMinimized.clear();
    notifier.value++;
  }

  void _tickTestWidgets() {
    if (!mounted) return;
    final channel = selectedChannel();
    if (channel == null) return;
    hypeTrains.clear();
    polls.clear();
    predictions.clear();

    _fakeProgress += 9;
    if (_fakeProgress >= _fakeGoal) {
      _fakeLevel++;
      _fakeGoal += 100;
      _fakeProgress = 0;
    }
    hypeTrains[channel] = HypeTrainEvent(
      channel: channel,
      kind: 'progress',
      level: _fakeLevel,
      progress: _fakeProgress,
      total: _fakeGoal,
      expiresAt: _fakeTrainEndsAt,
      topContributions: [
        HypeTrainContribution(userName: 'fakebits', type: 'BITS', total: 5000),
        HypeTrainContribution(userName: 'fakesub', type: 'SUBS', total: 12),
      ],
    );

    _fakePollA += 3;
    _fakePollB += 2;
    _fakePollC += 1;
    polls[channel] = PollEvent(
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
    predictions[channel] = PredictionEvent(
      channel: channel,
      kind: 'progress',
      title: 'Fake prediction: will we win?',
      outcomes: [
        PredictionOutcome(
          title: 'Yes',
          users: _fakePredYes,
          channelPoints: 9000,
        ),
        PredictionOutcome(title: 'No', users: _fakePredNo, channelPoints: 4500),
      ],
      status: 'ACTIVE',
    );
    notifier.value++;
    clampPage();
  }

  List<Widget> pagesFor(String channel) {
    final result = <Widget>[];
    final poll = polls[channel];
    if (poll != null) result.add(PollCard(event: poll));
    final prediction = predictions[channel];
    if (prediction != null) result.add(PredictionCard(event: prediction));
    final hypeTrain = hypeTrains[channel];
    if (hypeTrain != null) result.add(HypeTrainCard(event: hypeTrain));
    return result;
  }

  String labelsFor(String channel) {
    final labels = <String>[];
    if (polls.containsKey(channel)) labels.add('Poll');
    if (predictions.containsKey(channel)) labels.add('Prediction');
    if (hypeTrains.containsKey(channel)) labels.add('Hype Train');
    return labels.join(' / ');
  }

  Widget? buildOverlay(
    String channel, {
    required void Function(String, bool) onMinimizeChanged,
  }) {
    final pages = pagesFor(channel);
    if (pages.isEmpty) return null;
    if (widgetsMinimized[channel] ?? false) {
      return ChatWidgetMinimizedBar(
        labels: labelsFor(channel),
        onRestore: () => onMinimizeChanged(channel, false),
      );
    }
    return ChatWidgetCutout(
      pages: pages,
      controller: pageCtrl,
      onMinimize: () => onMinimizeChanged(channel, true),
    );
  }

  void clampPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !pageCtrl.hasClients) return;
      final channel = selectedChannel();
      if (channel == null) return;
      final pages = pagesFor(channel).length;
      if (pages == 0) return;
      final idx = pageCtrl.page?.round() ?? 0;
      if (idx >= pages) {
        pageCtrl.jumpToPage(pages - 1);
      }
    });
  }

  void resetPage() {
    if (pageCtrl.hasClients) pageCtrl.jumpToPage(0);
  }
}

class _PanelManager {
  _PanelManager({
    required this.vsync,
    required this.markDirty,
    required this.isMounted,
  });

  final TickerProvider vsync;
  final VoidCallback markDirty;
  final bool Function() isMounted;

  OverlayPanel activePanel = OverlayPanel.closed;
  bool emoteSheetOpen = false;
  TwitchMessage? openThreadRoot;
  List<TwitchMessage> threadMessages = [];
  String? threadChannel;

  final threadSheetRatio = ValueNotifier(0.0);
  final mentionsSheetRatio = ValueNotifier(0.0);
  late final AnimationController panelScaleCtrl = AnimationController(
    vsync: vsync,
    duration: const Duration(milliseconds: 200),
    value: 1.0,
  );
  late final DraggableScrollableController emoteSheetCtrl =
      DraggableScrollableController();

  double panelDragStartRatio = 0.0;
  double panelDragStartY = 0.0;
  double? emoteSheetBoxHeight;

  static const sheetAnimDuration = Duration(milliseconds: 250);
  static const sheetCloseDuration = Duration(milliseconds: 180);
  static const emoteMaxFraction = 0.6;
  static const fullHeightFraction = 1.0;

  double get emoteSheetPhysicalSize =>
      emoteSheetCtrl.isAttached ? emoteSheetCtrl.size : 0.0;

  void dispose() {
    panelScaleCtrl.dispose();
    emoteSheetCtrl.dispose();
    threadSheetRatio.dispose();
    mentionsSheetRatio.dispose();
  }

  void onSheetSizeChanged() {
    if (emoteSheetOpen &&
        emoteSheetCtrl.isAttached &&
        emoteSheetCtrl.size <= 0.001) {
      PerfLog.I.record(
        'EmoteSheet',
        'size collapsed to ${emoteSheetCtrl.size.toStringAsFixed(3)} '
            'while open; closing',
      );
      emoteSheetOpen = false;
      panelScaleCtrl.value = 1.0;
      markDirty();
    }
  }

  Future<void> closePanel() async {
    final panelToClose = activePanel;
    if (panelToClose == OverlayPanel.closed && !emoteSheetOpen) return;
    await closeEmoteSheet();
    if (panelToClose == OverlayPanel.closed) {
      if (isMounted()) markDirty();
      return;
    }
    if (panelToClose == OverlayPanel.thread) {
      await animateRatio(
        threadSheetRatio,
        threadSheetRatio.value,
        0.0,
        sheetCloseDuration,
      );
    } else if (panelToClose == OverlayPanel.mentions) {
      await animateRatio(
        mentionsSheetRatio,
        mentionsSheetRatio.value,
        0.0,
        sheetCloseDuration,
      );
    }
    if (isMounted()) {
      // A reopen racing the close animation wins: only clear when the panel
      // is still the one that started closing (e.g. rapid thread-to-thread
      // taps must not wipe the newly opened root).
      if (activePanel == panelToClose) {
        activePanel = OverlayPanel.closed;
        openThreadRoot = null;
      }
      panelScaleCtrl.value = 1.0;
      markDirty();
    }
  }

  Future<void> animateRatio(
    ValueNotifier<double> ratio,
    double from,
    double to,
    Duration duration,
  ) async {
    if (from == to) return;
    final controller = AnimationController(vsync: vsync, duration: duration);
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

  Widget buildPanelDragHandle({
    required ValueNotifier<double> ratio,
    required double maxSize,
    required VoidCallback onClose,
    required VoidCallback onSnap,
    required BuildContext context,
    Widget? header,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (details) {
        panelDragStartRatio = ratio.value;
        panelDragStartY = details.globalPosition.dy;
      },
      onVerticalDragUpdate: (details) {
        final cumulativeDelta = details.globalPosition.dy - panelDragStartY;
        final height =
            maxSize *
            (MediaQuery.sizeOf(context).height -
                MediaQuery.paddingOf(context).top -
                MediaQuery.viewInsetsOf(context).bottom);
        ratio.value = (panelDragStartRatio - cumulativeDelta / height).clamp(
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

  Widget buildOverlaySheet({
    required bool offstage,
    required ValueNotifier<double> ratio,
    required Widget header,
    required Widget body,
    required BuildContext context,
  }) {
    return Positioned(
      top: MediaQuery.paddingOf(context).top,
      bottom: 0,
      left: 0,
      right: 0,
      child: Offstage(
        offstage: offstage,
        child: ScaleTransition(
          scale: panelScaleCtrl,
          alignment: Alignment.bottomCenter,
          child: buildSheetPanel(
            ratio: ratio,
            child: RepaintBoundary(
              child: Material(
                color: Theme.of(context).scaffoldBackgroundColor,
                clipBehavior: Clip.hardEdge,
                child: Column(
                  children: [
                    ColoredBox(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      child: buildPanelDragHandle(
                        ratio: ratio,
                        maxSize: fullHeightFraction,
                        onClose: closePanel,
                        onSnap: () => animateRatio(
                          ratio,
                          ratio.value,
                          fullHeightFraction,
                          sheetAnimDuration,
                        ),
                        context: context,
                        header: header,
                      ),
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

  Widget buildSheetPanel({
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

  Widget buildSlideUpContent({
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

  void showEmoteMenu({
    required String? selectedChannel,
    required EmoteManager emoteManager,
    required Map<String, String> channelUserIds,
  }) {
    iosHaptic(HapticFeedback.lightImpact);
    if (selectedChannel != null &&
        !emoteManager.hasChannelCache(selectedChannel)) {
      unawaited(
        emoteManager.resolveEmotes(
          selectedChannel,
          channelUserIds[selectedChannel],
        ),
      );
    }
    if (!emoteManager.hasGlobalCache) {
      unawaited(emoteManager.preloadGlobalEmotes());
    }
    emoteSheetOpen = true;
    markDirty();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isMounted()) {
        PerfLog.I.record('EmoteSheet', 'open aborted: unmounted');
        return;
      }
      if (!emoteSheetCtrl.isAttached) {
        PerfLog.I.record(
          'EmoteSheet',
          'open skipped: controller has no clients',
        );
        return;
      }
      PerfLog.I.record(
        'EmoteSheet',
        'animating open from ${emoteSheetCtrl.size.toStringAsFixed(3)}',
      );
      unawaited(
        emoteSheetCtrl
            .animateTo(
              emoteMaxFraction,
              duration: sheetAnimDuration,
              curve: Curves.easeInOutCubicEmphasized,
            )
            .then((_) {
              if (!isMounted()) return;
              PerfLog.I.record(
                'EmoteSheet',
                'open animation ended at '
                    '${emoteSheetPhysicalSize.toStringAsFixed(3)}'
                    '${emoteSheetCtrl.isAttached ? '' : ' (detached)'}',
              );
            }),
      );
    });
  }

  Future<void> closeEmoteSheet() async {
    if (!emoteSheetOpen) {
      PerfLog.I.record('EmoteSheet', 'close ignored: already closed');
      return;
    }
    if (emoteSheetCtrl.isAttached) {
      if (emoteSheetCtrl.size <= 0.001) {
        PerfLog.I.record('EmoteSheet', 'closing skipped: sheet already at 0');
        if (isMounted()) {
          emoteSheetOpen = false;
          panelScaleCtrl.value = 1.0;
          markDirty();
        }
        return;
      }
      final fraction = (emoteSheetCtrl.size / emoteMaxFraction).clamp(0.0, 1.0);
      final duration = Duration(milliseconds: (80 + 180 * fraction).round());
      PerfLog.I.record(
        'EmoteSheet',
        'closing from ${emoteSheetCtrl.size.toStringAsFixed(3)} '
            '(${(fraction * 100).round()}%) over ${duration.inMilliseconds}ms',
      );
      unawaited(
        emoteSheetCtrl
            .animateTo(
              0,
              duration: duration,
              curve: Curves.easeInOutCubicEmphasized,
            )
            .then((_) {
              if (!isMounted()) return;
              PerfLog.I.record(
                'EmoteSheet',
                'close animation ended at '
                    '${emoteSheetPhysicalSize.toStringAsFixed(3)}'
                    '${emoteSheetCtrl.isAttached ? '' : ' (detached)'}',
              );
              emoteSheetOpen = false;
              panelScaleCtrl.value = 1.0;
              markDirty();
            }),
      );
    } else {
      PerfLog.I.record('EmoteSheet', 'close without animation: no clients');
      if (isMounted()) {
        emoteSheetOpen = false;
        panelScaleCtrl.value = 1.0;
        markDirty();
      }
    }
  }

  void handlePanelBack() {
    if (emoteSheetOpen) {
      unawaited(closeEmoteSheet());
    } else {
      unawaited(closePanel());
    }
  }

  List<TwitchMessage> computeThreadMessages({
    required TwitchMessage? openThreadRoot,
    required Map<String, List<TwitchMessage>> channelMessages,
    required List<TwitchMessage>? Function(String channel, String rootId)
    threadFor,
  }) {
    final entry = openThreadRoot;
    if (entry == null) return const [];
    final channel = entry.channel;
    if (channel == null) return const [];
    final allMsgs = channelMessages[channel] ?? [];

    final entryKey = entry.replyThreadRootId ?? entry.messageId;
    if (entryKey == null) return const [];

    final parentOf = <String, String>{};
    for (final m in allMsgs) {
      if (m.replyToParentId != null && m.messageId != null) {
        parentOf[m.messageId!] = m.replyToParentId!;
      }
    }

    final resolvedKey = threadKeyFor(entry, parentOf);
    if (resolvedKey == null) return const [];

    // Prefer the incremental thread store: it survives scrollback trimming
    // (pinned root, decayed replies) where a pure buffer scan comes up empty.
    // Old-style parent-chain threads that were never tagged fall back to the
    // scan below.
    final threadMsgs =
        threadFor(channel, resolvedKey) ??
        allMsgs.where((m) => threadKeyFor(m, parentOf) == resolvedKey).toList();

    threadMsgs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return threadMsgs;
  }

  TwitchMessage? findThreadRoot(
    TwitchMessage msg, {
    required Map<String, List<TwitchMessage>> channelMessages,
  }) {
    if (msg.replyThreadRootId != null) return msg;

    final channel = msg.channel;
    if (channel == null) return null;
    final msgs = channelMessages[channel];
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
}

class _ChromeMenuButton extends StatefulWidget {
  final VoidCallback onToggleFullscreen;
  final VoidCallback onToggleInput;
  final VoidCallback? onToggleStream;
  final bool Function()? showStreamToggle;
  final bool Function()? streamActive;

  const _ChromeMenuButton({
    required this.onToggleFullscreen,
    required this.onToggleInput,
    this.onToggleStream,
    this.showStreamToggle,
    this.streamActive,
  });

  @override
  State<_ChromeMenuButton> createState() => _ChromeMenuButtonState();
}

class _ChromeMenuButtonState extends State<_ChromeMenuButton> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<String>(
      position: PopupMenuPosition.under,
      popUpAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 175),
      ),
      onOpened: () => setState(() => _open = true),
      onCanceled: () => setState(() => _open = false),
      onSelected: (value) {
        setState(() => _open = false);
        switch (value) {
          case 'fullscreen':
            widget.onToggleFullscreen();
            break;
          case 'input':
            widget.onToggleInput();
            break;
          case 'stream':
            widget.onToggleStream?.call();
            break;
        }
      },
      itemBuilder: (_) {
        final showStream = widget.showStreamToggle?.call() ?? false;
        final active = widget.streamActive?.call() ?? false;
        return [
          const PopupMenuItem(
            value: 'fullscreen',
            child: Text('Toggle fullscreen'),
          ),
          const PopupMenuItem(value: 'input', child: Text('Toggle input')),
          if (showStream)
            PopupMenuItem(
              value: 'stream',
              child: Text(active ? 'Hide stream' : 'Show stream'),
            ),
        ];
      },
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(4),
        child: AnimatedRotation(
          turns: _open ? 0.5 : 0.0,
          duration: const Duration(milliseconds: 175),
          child: Icon(
            Icons.expand_more,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
