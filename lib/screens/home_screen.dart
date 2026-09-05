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
import '../services/join_rate_limiter.dart';
import '../services/twitch_irc.dart';
import '../services/command_macros.dart';
import '../services/connectivity_service.dart';
import '../services/recent_messages.dart';
import '../services/seven_tv_event_client.dart';
import '../services/command_handler.dart';
import '../services/mod_actions.dart';
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
import '../util/timestamp_formatter.dart';
import '../screens/settings/settings_screen.dart';
import '../widgets/tabbed_layout.dart';
import '../widgets/panel_manager.dart';
import '../widgets/welcome_dialog.dart';
import '../services/user_store.dart';
import '../services/chat_store.dart';
import '../services/suggestion.dart';
import '../services/notification_service.dart';
import '../services/tts_controller.dart';
import '../widgets/autocomplete_dropdown.dart';
import '../widgets/broadcast_widgets.dart';
import '../widgets/chat_body.dart';
import '../widgets/chrome_menu_button.dart';
import '../composer/composer_bar.dart';
import '../composer/composer_controller.dart';
import '../sheets/message_menu.dart';
import '../sheets/user_sheet.dart';
import '../panels/threads.dart';
import '../panels/mentions.dart';
import '../panels/mod_panel.dart';
import '../widgets/nuke_overlay.dart';
import '../widgets/emote_image_provider.dart';
import '../widgets/media_upload_controller.dart';
import '../widgets/emote_menu_panel.dart';
import '../widgets/chat_view.dart';
import '../widgets/message_builder.dart';
import '../widgets/stream_player_view.dart';
import '../widgets/predictive_back_handler.dart';
import '../widgets/join_channel_dialog.dart';
import '../services/foreground_task.dart';

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
    with WidgetsBindingObserver, TickerProviderStateMixin
    implements
        ComposerHost,
        MessageMenuHost,
        UserSheetHost,
        ThreadPanelsHost,
        MentionsPanelsHost,
        ModPanelsHost {
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
        getReplyToMsg: () => _composer.replyToMsg,
        setReplyToMsg: (v) => _composer.replyTo = v,
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
  late final MessageBuilder _messageBuilder = MessageBuilder(
    emoteManager: _emoteManager,
    badgeService: _badgeService,
    thirdPartyBadgeService: _thirdPartyBadgeService,
    onShowEmoteSheet: (emotes) => _userSheets.showEmoteSheet(context, emotes),
    linkWhitelist: LinkWhitelist.instance,
  );
  late final _modActions = ModActions(
    twitchApi: _twitchApi,
    getChannelUserIds: () => _chatStore.channelUserIds,
    getCurrentUserId: () => _chatStore.session.userId,
  );
  late final _commandHandler = CommandHandler(
    twitchApi: _twitchApi,
    irc: _irc,
    modActions: _modActions,
    getChannelUserIds: () => _chatStore.channelUserIds,
    getCurrentUserId: () => _chatStore.session.userId,
    getCurrentUserLogin: () => _chatStore.session.login,
    addSystemMessage: _addSystemMessage,
    whisperAddSystemMessage: (channel, text) =>
        _mentions.addWhisperSystemMessage(channel, text),
    onWhisperSent: (target, message) =>
        _mentions.onWhisperSent(target, message),
    onUserBlocked: _onUserBlocked,
    onUserUnblocked: _onUserUnblocked,
  );
  late final MediaUploadController _uploadController = MediaUploadController(
    input: _composer.messageController,
    focusNode: _composer.focusNode,
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

  List<TwitchMessage>? _welcomeMessages;
  String? _welcomeMessagesKey;

  late final _broadcastWidgets = BroadcastWidgets(
    selectedChannel: () => _selectedChannel,
  );

  // Appearance, stream, and panel prefs live here; composer-owned input
  // state (text, reply, suggestions, cooldown) lives in _composer.
  bool _replyToRoot = false;
  bool _preferEmotesFirst = false;
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

  final _selectedTabIndex = ValueNotifier<int>(0);

  late final _panelManager = PanelManager(
    vsync: this,
    markDirty: () {
      if (mounted) setState(() {});
    },
    isMounted: () => mounted,
  );

  // Delegating accessors for state that moved to PanelManager.
  OverlayPanel get _activePanel => _panelManager.activePanel;
  bool get _emoteSheetOpen => _panelManager.emoteSheetOpen;

  // Aliases for panel-manager constants/state accessed inline in build.
  AnimationController get _panelScaleCtrl => _panelManager.panelScaleCtrl;
  DraggableScrollableController get _emoteSheetCtrl =>
      _panelManager.emoteSheetCtrl;
  static const _emoteMaxFraction = PanelManager.emoteMaxFraction;

  late final TabController _mentionsTabCtrl;
  late final TabController _threadsTabCtrl;
  late final TabController _modTabCtrl;

  late final PanelPredictiveBackHandler _predictiveBackHandler;

  bool _mentionScanDone = false;

  late final ComposerController _composer = ComposerController(
    chatConn: _chatConn,
    commandHandler: _commandHandler,
    twitchAuth: widget.twitchAuth,
    emoteManager: _emoteManager,
    userStore: _userStore,
    chatStore: _chatStore,
    host: this,
  );

  // ComposerHost: shell-owned UI state the composer reads but does not own.
  @override
  String? get selectedChannel => _selectedChannel;
  @override
  bool get isWhispersTabActive => _mentions.isWhispersTabActive;
  @override
  String? get whisperTarget => _mentions.whisperTarget;
  @override
  OverlayPanel get activePanel => _activePanel;
  @override
  int get threadsTabIndex => _threadsTabCtrl.index;
  @override
  TwitchMessage? get openThreadRoot => _panelManager.openThreadRoot;
  @override
  bool get replyToRoot => _replyToRoot;
  @override
  bool get preferEmotesFirst => _preferEmotesFirst;
  @override
  List<TwitchMessage> computeThreadMessages() =>
      _threads.computeThreadMessages();
  @override
  bool get channelChatReady => _channelChatReady;
  @override
  void showNotice(String text) {
    ScaffoldMessenger.of(context).showSnackBar(_snackBar(text));
  }

  @override
  bool get emoteSheetOpen => _emoteSheetOpen;
  @override
  Future<void> closeEmoteSheet() => _closeEmoteSheet();
  @override
  void showEmoteMenu() => _showEmoteMenu();
  @override
  void markDirty() {
    if (mounted) setState(() {});
  }

  late final _menus = MessageMenus(
    twitchAuth: widget.twitchAuth,
    chatConn: _chatConn,
    modActions: _modActions,
    host: this,
  );

  // MessageMenuHost: shell-owned state the menus read but do not own.
  @override
  bool get showTimestamps => _showTimestamps;
  @override
  String get timestampFormat => _timestampFormat;
  @override
  String? get sessionLogin => _chatStore.session.login;
  @override
  TwitchMessage? findThreadRoot(TwitchMessage msg) =>
      _threads.findThreadRoot(msg);
  @override
  bool isThreadSaved(TwitchMessage msg) => _threads.isThreadSaved(msg);
  @override
  void startReply(TwitchMessage msg) => _composer.startReply(msg);
  @override
  Future<void> showThreadView(TwitchMessage root) =>
      _threads.showThreadView(root, switchChannel: true);
  @override
  void toggleSaveThread(TwitchMessage root) => _threads.toggleSaveThread(root);

  late final _userSheets = UserSheets(
    chatStore: _chatStore,
    chatConn: _chatConn,
    twitchApi: _twitchApi,
    twitchAuth: widget.twitchAuth,
    modActions: _modActions,
    emoteManager: _emoteManager,
    messageBuilder: _messageBuilder,
    composer: _composer,
    host: this,
  );

  // UserSheetHost: shell-owned state the user sheet reads but does not own.
  // selectedChannel, sessionLogin, showTimestamps, timestampFormat come
  // from the shared ShellState implementation above.
  @override
  double get chatFontSize => _chatFontSize;
  @override
  bool get checkeredMessages => _checkeredMessages;
  @override
  double get highlightOpacity => _highlightOpacity;
  @override
  bool get lineSeparator => _lineSeparator;
  @override
  String get sharedChatMode => _sharedChatMode;
  @override
  SevenTvPaintService? get namePaintService =>
      _showNamePaints ? _sevenTvPaintService : null;
  @override
  void onUserBlocked(String login) => _onUserBlocked(login);
  @override
  void showWhispersForUser(String login) =>
      _mentions.showWhispersForUser(login);
  @override
  void copyMessage(TwitchMessage msg) => _copyMessageToClipboard(msg);

  late final _threads = ThreadPanels(
    panelManager: _panelManager,
    chatStore: _chatStore,
    threadsTab: () => _threadsTabCtrl,
    composer: _composer,
    messageBuilder: _messageBuilder,
    userSheets: _userSheets,
    menus: _menus,
    host: this,
  );

  // ThreadPanelsHost: shell-owned state the thread panels read but do not own.
  // Appearance getters come from the UserSheetHost implementation above.
  @override
  bool isMounted() => mounted;
  @override
  void switchChannelTo(int index) => _onChannelChanged(index);

  late final _mentions = MentionsPanels(
    panelManager: _panelManager,
    chatStore: _chatStore,
    chatConn: _chatConn,
    twitchAuth: widget.twitchAuth,
    mentionsTab: () => _mentionsTabCtrl,
    composer: _composer,
    messageBuilder: _messageBuilder,
    userSheets: _userSheets,
    menus: _menus,
    mentionsChannel: _mentionsChannel,
    host: this,
  );

  late final _mod = ModPanels(
    panelManager: _panelManager,
    chatStore: _chatStore,
    chatConn: _chatConn,
    twitchAuth: widget.twitchAuth,
    modActions: _modActions,
    modTab: () => _modTabCtrl,
    composer: _composer,
    host: this,
  );

  // MentionsPanelsHost: shell-owned state the inbox reads but does not own.
  @override
  int get maxMessages => _maxMessagesPerChannel;
  @override
  void notifyWhisper(TwitchMessage msg) => _maybeNotifyWhisper(msg);

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
    _mentionsTabCtrl.addListener(_mentions.onMentionsTabChanged);
    _threadsTabCtrl = TabController(length: 3, vsync: this);
    _threadsTabCtrl.addListener(_threads.onThreadsTabChanged);
    _modTabCtrl = TabController(length: 3, vsync: this);
    _panelManager.emoteSheetCtrl.addListener(_panelManager.onSheetSizeChanged);
    _loadMaxMessages();
    unawaited(_threads.loadSaved());
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
    _chatConn.onWhisper = _mentions.onWhisper;
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
    if (_notificationTapSub == null || _mentions.isWhispersTabActive) return;
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

  void _onLinkWhitelistChanged() {
    // Re-render visible tiles so the new link-whitelist entries take effect.
    _tileCache.clear();
    for (final channel in List.of(_chatStore.channels)) {
      _chatStore.touchChannel(channel);
    }
    if (mounted) setState(() {});
  }

  void _onEmotesChanged() {
    _composer.invalidateEmoteCache();
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
        _composer.focus();
    }
  }

  void _onStoreEvent(ChatStoreEvent event) {
    // The composer's send-gate countdown arms off moderation events (self
    // timeouts land here as system lines); refresh it eagerly so the label
    // appears without waiting for the next tick.
    _composer.refreshCooldown();
    switch (event.signal) {
      case ChatStoreSignal.newContent:
        _threads.syncSavedWithChannel(event.channel);
        _onPanelDataChanged(event.channel);
      case ChatStoreSignal.channelTouched:
        _tileCache.remove(event.channel);
        _threads.syncSavedWithChannel(event.channel);
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
  void _onPanelDataChanged([String? changedChannel]) {
    if (_activePanel == OverlayPanel.closed) return;
    _threads.refreshOnData(changedChannel);
    if (_activePanel == OverlayPanel.mentions) _mentions.refreshOnData();
    _mod.refreshOnData(changedChannel);
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
      // The queue belongs to the previous account's moderation scope.
      _chatStore.clearAllHeldMessages();
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
      _mentions.clearForAccountSwitch();
      _chatStore.truncateChannel(_mentionsChannel, maxMessages: 0);
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
    _composer.dispose();
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
    _mentionsTabCtrl.removeListener(_mentions.onMentionsTabChanged);
    _mentionsTabCtrl.dispose();
    _threadsTabCtrl.removeListener(_threads.onThreadsTabChanged);
    _threadsTabCtrl.dispose();
    _modTabCtrl.dispose();
    _threads.dispose();
    _mentions.dispose();
    _mod.dispose();
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
  Widget _buildChromeMenu() {
    return ChromeMenuButton(
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
    final inputBarH = inputBarKey.currentContext?.size?.height ?? 0;
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
    final controller = _composer.messageController;
    final selection = controller.selection;
    final base = selection.baseOffset;
    final insertAt = base < 0 ? controller.text.length : base;
    final newText = controller.text.replaceRange(insertAt, insertAt, text);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: insertAt + text.length),
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
    _composer.focus();

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
    _chatConn.forgetChannel(channel);
    _analytics.resetChannel(channel);
    if (_streamPlayer.currentChannel == channel) _streamPlayer.closeStream();
    _irc.part(channel);
    _ircRead.part(channel);
    _emoteManager.evictChannel(channel);
    _badgeService.clearChannel(channel);
    _chatStore.channelsEmotesResolved.remove(channel);
    _chatStore.historyLoaded.remove(channel);
    // Sync, unlike forgetChannel below: the global heldVersion has no
    // per-channel listeners to protect, so the queue dies with the channel.
    _chatStore.clearHeldMessages(channel);
    _chatStore.channelUserIds.remove(channel);
    _chatStore.lastSentWireText.remove(channel);
    _chatStore.chatStatus.remove(channel);
    _broadcastWidgets.clearChannel(channel);
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
      _threads.forgetChannel(channel);
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

  Future<void> _openSettings() async {
    _composer.unfocus();
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
    _composer.insertEmoteAtCursor(emote);
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
      _composer.refreshCooldown();
      _chatStore.channelsWithUnread.remove(channel);
      _chatStore.channelsWithUnreadMentions.remove(channel);
      _chatStore.unreadVersion.value++;
      clearedUnread = _chatStore.unreadMentionsPerChannel.remove(channel) ?? 0;
      if (clearedUnread > 0) {
        _chatStore.unreadMentions -= clearedUnread;
        if (_chatStore.unreadMentions < 0) _chatStore.unreadMentions = 0;
      }
      _threads.clearOpenThread();
      _composer.onChannelChanged();
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
    return PopScope(
      canPop:
          !_isFullscreen &&
          !_streamPlayer.isTheaterMode &&
          _activePanel == OverlayPanel.closed &&
          !_emoteSheetOpen &&
          !_composer.hasFocus,
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
          _composer.unfocus();
          setState(() {});
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: ChatBody(
          emoteMaxFraction: _emoteMaxFraction,
          bodyBuilder:
              (
                context, {
                required hideChromeForKeyboard,
                required maxWidth,
                required maxHeight,
                required keyboardH,
              }) {
                return ListenableBuilder(
                  listenable: _streamPlayer,
                  builder: (_, _) => _buildBodyColumn(
                    hideChromeForKeyboard: hideChromeForKeyboard,
                    maxWidth: maxWidth,
                    maxHeight: maxHeight,
                    keyboardH: keyboardH,
                  ),
                );
              },
          threadPanel: _threads.threadPanel(
            context,
            overlaySheet: _buildOverlaySheet,
            closePanel: _closePanel,
          ),
          mentionsPanel: _mentions.mentionsPanel(
            context,
            overlaySheet: _buildOverlaySheet,
            closePanel: _closePanel,
          ),
          modViewPanel: _mod.modViewPanel(
            context,
            overlaySheet: _buildOverlaySheet,
            closePanel: _closePanel,
          ),
          emotePickerBuilder: (context, {required sheetBoxHeight}) =>
              _buildEmotePicker(sheetBoxHeight: sheetBoxHeight),
          autocomplete: ValueListenableBuilder<List<Suggestion>>(
            valueListenable: _composer.suggestions,
            builder: (_, suggestions, _) => AutocompleteDropdown(
              suggestions: suggestions,
              onSelect: _composer.selectSuggestion,
              onEmoteViewed: _emoteManager.markEmoteViewed,
            ),
          ),
          composer: _showInput
              ? ComposerBar(
                  controller: _composer,
                  selectedTabIndex: _selectedTabIndex,
                )
              : null,
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
              ? Duration.zero
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
        ? (inputBarKey.currentContext?.size?.height ?? 56)
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
                        _mentions.clearUnreadWhispers();
                        _chatStore.channelsWithUnreadMentions.clear();
                        _chatStore.unreadMentionsPerChannel.clear();
                        _chatStore.unreadVersion.value++;
                        if (mounted) setState(() {});
                        if (_activePanel == OverlayPanel.mentions) {
                          unawaited(_closePanel());
                        } else {
                          _mentions.showMentionsView();
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
                        case 'modview':
                          _mod.showModView();
                          break;
                        case 'threads':
                          _threads.showThreadsDashboard(tab: 1);
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
                      if (_selectedChannel != null)
                        const PopupMenuItem(
                          value: 'modview',
                          child: Row(
                            children: [
                              Icon(Icons.shield_outlined, size: 20),
                              SizedBox(width: 12),
                              Text('Mod view'),
                            ],
                          ),
                        ),
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
            _composer.clearSuggestions();
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
                      ? Duration.zero
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
                            _userSheets.showUserProfile(
                              context,
                              login,
                              userId,
                              displayName: displayName,
                            ),
                        onShowMessageMenu: (msg) =>
                            _menus.showMessageMenu(context, msg),
                        onCopyMessage: _copyMessageToClipboard,
                        onNewMessage: _chatStore.noteNewMessage,
                        onFindThreadRoot: _threads.findThreadRoot,
                        onShowThreadView: (msg) => _threads.showThreadView(msg),
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
                      _broadcastWidgets.setMinimized(ch, minimized);
                    },
                  ) ??
                  const SizedBox.shrink(),
            ),
          ),
      ],
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
      onShowUserProfile: (login, userId, {displayName}) => _userSheets
          .showUserProfile(context, login, userId, displayName: displayName),
      keyboardDismissBehavior: (!kIsWeb && Platform.isIOS)
          ? ScrollViewKeyboardDismissBehavior.onDrag
          : ScrollViewKeyboardDismissBehavior.manual,
    );
  }
}
