import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../third_party/flutter_list_view/flutter_list_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
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
import '../composer/composer_bar.dart';
import '../composer/composer_controller.dart';
import '../sheets/message_menu.dart';
import '../sheets/user_sheet.dart';
import '../channels/channel_manager.dart';
import '../chrome/channel_stack.dart';
import '../emotes/emote_applier.dart';
import '../chrome/home_app_bar.dart';
import '../chrome/stream_layout.dart';
import '../panels/threads.dart';
import '../panels/mentions.dart';
import '../panels/mod_panel.dart';
import '../widgets/nuke_overlay.dart';
import '../widgets/emote_image_provider.dart';
import '../widgets/media_upload_controller.dart';
import '../widgets/emote_menu_panel.dart';
import '../widgets/message_builder.dart';
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
        ModPanelsHost,
        HomeAppBarHost,
        ChannelPanelsHost,
        StreamPanelsHost,
        ChannelManagerHost,
        EmoteApplierHost {
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
  late final _sevenTvClient = SevenTvEventClient(
    connectivityService: _connectivityService,
  );
  late final _twitchApi = TwitchApi();
  late final _analytics = AnalyticsService(
    emoteLookup: (channel, senderTwitchId) =>
        _emoteManager.byCodeForSender(channel, senderTwitchId),
  );
  final _ttsController = TtsController();

  late final ChatStore _chatStore =
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
          _channelManager.scanHistoryForMentions();
          unawaited(_ensureBlockedUsersLoaded());
          // Warm the macro cache so sends can read it synchronously.
          if (v != null) unawaited(loadMacros(v));
        };

  late final ChatConnectionManager _chatConn = ChatConnectionManager(
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
        onJoinProgress: (ch, info) => _channelManager.onJoinProgress(ch, info),
        getSelectedChannel: () => _selectedChannel,
        getMaxMessagesPerChannel: () => _maxMessagesPerChannel,
      ),
      sinks: ChatSinks(
        onCommand: _handleCommand,
        getReplyToMsg: () => _composer.replyToMsg,
        setReplyToMsg: (v) => _composer.replyTo = v,
        onUserEmoteSets: (ch, ids) => _emotes.loadUserEmoteSets(ch, ids),
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
  String? _selectedChannel;
  final _blockedLogins = <String>{};
  bool _blocksReady = false;
  bool _blocksFetched = false;
  final _scrollControllers = <String, FlutterListViewController>{};
  final _atBottomNotifiers = <String, ValueNotifier<bool>>{};

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
  void switchChannelTo(int index) => _channels.onChannelChanged(index);

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

  late final _chrome = HomeAppBar(
    chatStore: _chatStore,
    chatConn: _chatConn,
    networkBusy: _networkBusy,
    twitchAuth: widget.twitchAuth,
    streamPlayer: _streamPlayer,
    uploadController: _uploadController,
    mentions: _mentions,
    mod: _mod,
    threads: _threads,
    host: this,
  );

  late final _channels = ChannelPanels(
    chatStore: _chatStore,
    tileCache: _tileCache,
    messageBuilder: _messageBuilder,
    linkWhitelist: _linkWhitelist,
    twitchAuth: widget.twitchAuth,
    paintService: _sevenTvPaintService,
    selectedTabIndex: _selectedTabIndex,
    userSheets: _userSheets,
    menus: _menus,
    threads: _threads,
    composer: _composer,
    broadcastWidgets: _broadcastWidgets,
    homeAppBar: _chrome,
    host: this,
  );

  late final _stream = StreamPanels(
    streamPlayer: _streamPlayer,
    chatStore: _chatStore,
    channels: _channels,
    homeAppBar: _chrome,
    host: this,
  );

  late final _channelManager = ChannelManager(
    chatStore: _chatStore,
    chatConn: _chatConn,
    irc: _irc,
    ircRead: _ircRead,
    twitchAuth: widget.twitchAuth,
    emoteManager: _emoteManager,
    badgeService: _badgeService,
    analytics: _analytics,
    streamPlayer: _streamPlayer,
    userStore: _userStore,
    pingManager: _pingManager,
    ignoreManager: _ignoreManager,
    notificationService: _notificationService,
    threads: _threads,
    composer: _composer,
    broadcastWidgets: _broadcastWidgets,
    tileCache: _tileCache,
    channelNotifier: _channelNotifier,
    selectedTabIndex: _selectedTabIndex,
    recentMessagesService: widget.recentMessagesService,
    mentionsChannel: _mentionsChannel,
    host: this,
  );

  late final _emotes = EmoteApplier(
    emoteManager: _emoteManager,
    twitchApi: _twitchApi,
    twitchAuth: widget.twitchAuth,
    chatStore: _chatStore,
    badgeService: _badgeService,
    connectivityService: _connectivityService,
    isMobile: _isMobile,
    networkBusy: _networkBusy,
    host: this,
  );

  // MentionsPanelsHost: shell-owned state the inbox reads but does not own.
  @override
  int get maxMessages => _maxMessagesPerChannel;
  @override
  void notifyWhisper(TwitchMessage msg) => _maybeNotifyWhisper(msg);

  // HomeAppBarHost / ChannelPanelsHost / StreamPanelsHost.
  @override
  Future<void> closePanel() => _closePanel();
  @override
  bool get chatLoading => _chatLoading;
  @override
  bool get disableJoinSpinner => HomeScreen.disableJoinSpinner;
  @override
  bool get isFullscreen => _isFullscreen;
  @override
  bool get showInput => _showInput;
  @override
  bool get showNamePaints => _showNamePaints;
  @override
  bool get fastSnap => _fastSnap;
  @override
  bool get theaterChatVisible => _theaterChatVisible;
  @override
  void toggleTheaterChat() =>
      setState(() => _theaterChatVisible = !_theaterChatVisible);
  @override
  void setStreamState(void Function() fn) => setState(fn);
  @override
  void addChannelDialog() => _addChannelDialog();
  @override
  void toggleFullscreen() => _toggleFullscreen();
  @override
  void toggleInput() => _toggleInputVisibility();
  @override
  void toggleStream() => _stream.toggleStreamForSelected();
  @override
  void reloadEmotes() => _emotes.reload();
  @override
  void reconnect() => _reconnect();
  @override
  void openSettings() => _openSettings();
  @override
  void commitChannelSelection(int index, {required bool rebuild}) =>
      _channelManager.commitChannelSelection(index, rebuild: rebuild);
  @override
  void onChannelChanged(int index) => _channels.onChannelChanged(index);
  @override
  ValueNotifier<int> versionNotifier(String channel) =>
      _versionNotifier(channel);
  @override
  ValueNotifier<int> messageNotifier(String channel) =>
      _messageNotifier(channel);
  @override
  ValueNotifier<bool> atBottomNotifier(String channel) =>
      _atBottomNotifier(channel);
  @override
  FlutterListViewController scrollCtrl(String channel) => _scrollCtrl(channel);

  // ChannelManagerHost / EmoteApplierHost.
  @override
  set selectedChannel(String? value) => _selectedChannel = value;
  @override
  void mutate(void Function() fn) => setState(fn);
  @override
  void addSystemMessage(String channel, String text) =>
      _addSystemMessage(channel, text);
  @override
  int get recentMessagesLimit => _recentMessagesLimit;
  @override
  bool get mentionPush => _mentionPush;
  @override
  void disposeChannelNotifiers(String channel) =>
      _scrollControllers.remove(channel)?.dispose();
  @override
  void forgetAtBottomNotifier(String channel) =>
      _atBottomNotifiers.remove(channel)?.dispose();
  @override
  void showSnack(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(_snackBar(message));

  @override
  void initState() {
    super.initState();
    unawaited(_ttsController.init());
    unawaited(PerfLog.I.init());
    DataUsageStats.I.start();
    _chatStore.session.login = widget.initialCurrentUserLogin;
    _pingManager.setAccount(widget.initialCurrentUserLogin);
    _emotes.loadPrefs();
    _mentionsTabCtrl = TabController(length: 2, vsync: this);
    _mentionsTabCtrl.addListener(_mentions.onMentionsTabChanged);
    _threadsTabCtrl = TabController(length: 3, vsync: this);
    _threadsTabCtrl.addListener(_threads.onThreadsTabChanged);
    _modTabCtrl = TabController(length: 3, vsync: this);
    _panelManager.emoteSheetCtrl.addListener(_panelManager.onSheetSizeChanged);
    _loadMaxMessages();
    unawaited(_threads.loadSaved());
    unawaited(
      _channelManager.loadRecentMessagesConfig().then((_) {
        if (mounted) _ensureBlockedUsersLoaded();
      }),
    );
    unawaited(_pingManager.load());
    unawaited(_ignoreManager.load());
    unawaited(_linkWhitelist.load());
    unawaited(_streamPlayer.loadPrefs());
    _streamPlayer.addListener(_stream.onStreamPlayerChanged);
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
      _emotes.reconcileTier();
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

  Future<void> _ensureBlockedUsersLoaded() async {
    if (_blocksFetched) return;
    final userId = widget.twitchAuth.userId;
    if (userId == null) {
      _blocksReady = true;
      _channelManager.loadChannels();
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
    _channelManager.loadChannels();
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

  void _onReconnected() {
    _channelManager.onReconnected();
    unawaited(_emotes.refreshSubEmoteOwners());
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
    _emotes.refreshAfterAuth();
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
      _channelManager.rearmMentionScan();
      _chatStore.channelsEmotesResolved.clear();
      // Whispers and the mentions feed belong to the previous account.
      _mentions.clearForAccountSwitch();
      _chatStore.truncateChannel(_mentionsChannel, maxMessages: 0);
      _channelManager.scanHistoryForMentions();
      unawaited(_ensureBlockedUsersLoaded());
    }
    // Re-resolve emotes with the new account's token BEFORE reconnecting so
    // sub emote sets fetch under the right auth; connect()'s GLOBALUSERSTATE
    // then layers the fresh sub emotes on top.
    unawaited(_emotes.refreshAfterAuth().then((_) => _chatConn.connect()));
  }

  // Reads the persisted manual tier, auto mode, and disk-cache cap, then
  // applies them to the emote manager. Runs first in initState so emotes
  // resolve at the right tier; a persisted effective tier other than the
  // default high re-resolves caches because connect() may already have
  // fetched at the default.
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
    _streamPlayer.removeListener(_stream.onStreamPlayerChanged);
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

  void _toggleInputVisibility() {
    setState(() => _showInput = !_showInput);
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setBool('show_input', _showInput),
      ),
    );
  }

  /// Translates join-queue progress into a live countdown system line
  /// ("Joining: position 12, ~14s"); position 0 means numbers are over
  /// (sent, awaiting echo) and the line degrades to a plain marker; a null
  /// [info] retires the line.
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

  void _addChannelDialog() {
    showJoinChannelDialog(context, onJoin: _channelManager.addChannel);
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
          onRecentMessagesModeChanged: _channelManager.setRecentMessagesMode,
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
          onCapEmoteFpsChanged: _emotes.setCapFps,
          onCheckeredMessagesChanged: _setCheckeredMessages,
          onHighlightOpacityChanged: _setHighlightOpacity,
          onLineSeparatorChanged: _setLineSeparator,
          onFastSnapChanged: _setFastSnap,
          onNamePaintsChanged: _setNamePaints,
          onEmoteTierChanged: _emotes.applyTier,
          onEmoteCacheMaxChanged: _emotes.applyCacheCap,
          onSharedChatModeChanged: _setSharedChatMode,
          onEmoteAutoModeChanged: _emotes.applyAutoMode,
          onNukeEmotes: _nukeEmotes,
          mobileNotifier: _isMobile,
          channelNotifier: _channelNotifier,
          onLeaveChannel: _channelManager.removeChannel,
          onAddChannel: _channelManager.addChannel,
          onReorderChannels: _channelManager.reorderChannels,
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
      await _emotes.runRefresh(nuke: true);
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
      _channels.onChannelChanged(index);
    }
  }

  // Single selection commit for BOTH entry points (swipe-tick focus and
  // settle/tab-tap). Whichever lands first owns the side effects; the shared
  // guard makes the second one a no-op, so bookkeeping runs exactly once per
  // real switch regardless of gesture timing.
  void _truncateChannelMessages(String channel) {
    _channelManager.truncateChannel(channel);
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
                  builder: (_, _) => _stream.bodyColumn(
                    context,
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
}
