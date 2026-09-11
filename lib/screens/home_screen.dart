import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../third_party/flutter_list_view/flutter_list_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_providers.dart';
import '../providers/chat_pipeline.dart';
import '../providers/feature_providers.dart';
import '../providers/ui_state_providers.dart';
import '../models/generic_emote.dart';
import '../models/twitch_message.dart';
import '../util/haptics.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/command_macros.dart';
import '../util/connectivity.dart';
import '../services/seven_tv_event_client.dart';
import '../services/command_handler.dart';
import '../services/mod_actions.dart';
import '../services/chat_connection_manager.dart';
import '../services/ping_manager.dart';
import '../services/ignore_manager.dart';
import '../services/link_whitelist.dart';
import '../services/emote_manager.dart';
import '../util/data_usage.dart';
import '../services/stream_player_controller.dart';
import '../services/pip_service.dart';
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
import '../chat/chat.dart';
import '../client/session.dart';
import '../services/suggestion.dart';
import '../services/notification_service.dart';
import '../services/tts_controller.dart';
import '../widgets/autocomplete_dropdown.dart';
import '../widgets/app_snack.dart';
import '../widgets/broadcast_widgets.dart';
import '../widgets/chat_body.dart';
import '../widgets/chat_notice_bar.dart';
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
import '../panels/search.dart';
import '../widgets/nuke_overlay.dart';
import '../widgets/emote_image_provider.dart';
import '../widgets/media_upload_controller.dart';
import '../widgets/emote_menu_panel.dart';
import '../widgets/message_builder.dart';
import '../widgets/predictive_back_handler.dart';
import '../widgets/join_channel_dialog.dart';
import '../services/foreground_task.dart';

class HomeScreen extends ConsumerStatefulWidget {
  // Test seam: when true the join ("+") button never shows its loading spinner.
  // Tests that intentionally keep the app disconnected (un-faked TwitchChatApp)
  // flip this so they can still reach the button during the permanent
  // "connecting" state instead of hitting the gated spinner.
  static bool disableJoinSpinner = false;

  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<bool>? onKeepScreenOnChanged;
  final ValueChanged<bool>? onTrueDarkChanged;
  final ValueChanged<String>? onAccentColorChanged;
  final String? initialCurrentUserLogin;

  const HomeScreen({
    super.key,
    required this.onThemeChanged,
    this.onKeepScreenOnChanged,
    this.onTrueDarkChanged,
    this.onAccentColorChanged,
    this.initialCurrentUserLogin,
  });

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin
    implements
        ComposerHost,
        MessageMenuHost,
        UserSheetHost,
        ThreadPanelsHost,
        MentionsPanelsHost,
        ModPanelsHost,
        SearchPanelsHost,
        HomeAppBarHost,
        ChannelPanelsHost,
        StreamPanelsHost,
        ChannelManagerHost,
        EmoteApplierHost {
  static const _mentionsChannel = '@mentions';

  ConnectivityService? _connectivityServiceCache;
  ConnectivityService get _connectivityService {
    _connectivityServiceCache ??= ref.read(connectivityServiceProvider);
    return _connectivityServiceCache!;
  }

  SevenTvEventClient get _sevenTvClient => ref.read(sevenTvClientProvider);
  TwitchApi get _twitchApi => ref.read(twitchApiProvider);
  PingManager get _pingManager => ref.read(pingManagerProvider);
  IgnoreManager get _ignoreManager => ref.read(ignoreManagerProvider);

  final _linkWhitelist = LinkWhitelist.instance;

  AnalyticsService get _analytics => ref.read(analyticsServiceProvider);
  TtsController get _ttsController => ref.read(ttsControllerProvider);

  Chat? _chatCache;
  Chat get _chat {
    _chatCache ??= ref.read(chatProvider);
    return _chatCache!;
  }

  Session? _sessionCache;
  Session get _session {
    _sessionCache ??= ref.read(sessionProvider);
    return _sessionCache!;
  }

  TwitchAuth? _twitchAuthCache;
  TwitchAuth get _twitchAuth {
    _twitchAuthCache ??= ref.read(twitchAuthProvider);
    return _twitchAuthCache!;
  }

  // Session announces pipeline-resolved identity; the app refreshes the
  // account-scoped data it owns.
  void _onSessionApplied() {
    final login = _session.login;
    _pingManager.setAccount(login);
    _channelManager.scanHistoryForMentions();
    unawaited(_ensureBlockedUsersLoaded());
    // Warm the macro cache so sends can read it synchronously.
    if (login != null) {
      unawaited(
        loadMacros(login).then((_) {
          if (mounted) ref.invalidate(macrosProvider);
        }),
      );
    }
  }

  // Provider-owned pipeline, read once and cached. The provider owns
  // teardown, so the screen only observes its notifiers.
  ChatConnectionManager? _chatConnCache;
  ChatConnectionManager get _chatConn {
    _chatConnCache ??= ref.read(chatPipelineProvider);
    return _chatConnCache!;
  }

  late final MessageBuilder _messageBuilder = MessageBuilder(
    emoteManager: _emoteManager,
    badgeService: _badgeService,
    thirdPartyBadgeService: _thirdPartyBadgeService,
    onShowEmoteSheet: (emotes) => _userSheets.showEmoteSheet(context, emotes),
    linkWhitelist: LinkWhitelist.instance,
    showGifs: _showGifs,
    gifHeight: _gifHeight,
    showImages: _showImages,
    imageHeight: _imageHeight,
    animateGifs: _animateGifs,
  );
  Map<String, String> _channelUserIds() {
    final out = <String, String>{};
    for (final name in _chat.names) {
      final id = _chat.channelFor(name)?.info.broadcasterId;
      if (id != null) out[name] = id;
    }
    return out;
  }

  ModActions get _modActions => ref.read(modActionsProvider);
  CommandHandler get _commandHandler => ref.read(commandHandlerProvider);
  late final MediaUploadController _uploadController = MediaUploadController(
    input: _composer.messageController,
    focusNode: _composer.focusNode,
    onNotice: _chatNotice.show,
  );

  NotificationService get _notificationService =>
      ref.read(notificationServiceProvider);
  StreamSubscription<String>? _notificationTapSub;
  bool _backgroundService = false;
  bool _whisperNotify = true;

  final _isMobile = ValueNotifier<bool>(false);

  EmoteManager? _emoteManagerCache;
  EmoteManager get _emoteManager {
    _emoteManagerCache ??= ref.read(emoteManagerProvider);
    return _emoteManagerCache!;
  }

  TwitchBadgeService get _badgeService => ref.read(badgeServiceProvider);
  PipService get _pipService => ref.read(pipServiceProvider);
  ThirdPartyBadgeService get _thirdPartyBadgeService =>
      ref.read(thirdPartyBadgeServiceProvider);
  SevenTvPaintService get _sevenTvPaintService =>
      ref.read(sevenTvPaintServiceProvider);
  UserStore get _userStore => ref.read(userStoreProvider);
  final _channelNotifier = ValueNotifier<List<String>>([]);
  final _tileCache = <String, Map<String?, Widget>>{};
  bool _blocksFetched = false;
  final _scrollControllers = <String, FlutterListViewController>{};
  final _atBottomNotifiers = <String, ValueNotifier<bool>>{};
  ChatNoticeController get _chatNotice => ref.read(chatNoticeProvider);

  ChatUiSignals? _signalsCache;
  ChatUiSignals get _signals {
    _signalsCache ??= ref.read(chatUiSignalsProvider);
    return _signalsCache!;
  }

  final _signalUnsubs = <void Function()>[];

  BroadcastWidgets get _broadcastWidgets => ref.read(broadcastWidgetsProvider);

  // Appearance, stream, and panel prefs live here; composer-owned input
  // state (text, reply, suggestions, cooldown) lives in _composer.
  bool _replyToRoot = false;
  bool _preferEmotesFirst = false;
  // True while a manual emote refresh (Reload emotes) is in flight. The
  // connect/reconnect + per-channel-join loading is read live from
  // [_chatLoading] (driven by ChatConnectionManager.connectionStateNotifier),
  // so this only covers emote work that doesn't move the connection phase.
  final ValueNotifier<bool> _networkBusy = ValueNotifier(false);
  int _recentMessagesLimit = 100;
  bool _showTimestamps = true;
  String _timestampFormat = kDefaultTimestampFormat;
  double _chatFontSize = 14.0;
  double _highlightOpacity = 0.6;
  bool _checkeredMessages = false;
  Color? _lastSurface;
  bool _lineSeparator = false;
  bool _fastSnap = true;

  /// 7TV name paints (default off; toggled in Chat settings).
  bool _showNamePaints = false;

  /// Giphy inline embeds (default off; toggled in Chat > Inline embeds).
  bool _showGifs = kGiphyInlineEnabledDefault;
  double _gifHeight = kGiphyInlineHeightDefault;
  bool _showImages = kImageEmbedEnabledDefault;
  double _imageHeight = kImageEmbedHeightDefault;

  /// Animated emotes play (default on; toggled in Emotes settings). Mirrored
  /// into the message builder so frozen Twitch GIFs swap render paths.
  bool _animateGifs = true;

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
    twitchAuth: _twitchAuth,
    emoteManager: _emoteManager,
    userStore: _userStore,
    chat: _chat,
    session: _session,
    getReplyTo: () => ref.read(replyToProvider),
    setReplyTo: (value) => ref.read(replyToProvider.notifier).set(value),
    host: this,
  );

  // ComposerHost: shell-owned UI state the composer reads but does not own.
  @override
  String? get selectedChannel => ref.read(selectedChannelProvider);
  @override
  bool get isWhispersTabActive => _mentions.isWhispersTabActive;
  @override
  String? get whisperTarget => _mentions.whisperTarget;
  @override
  OverlayPanel get activePanel => _activePanel;
  @override
  int get threadsTabIndex => _threads.effectiveThreadsTab;
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
    _chatNotice.show(text);
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
    twitchAuth: _twitchAuth,
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
  String? get sessionLogin => _session.login;
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
    chat: _chat,
    chatConn: _chatConn,
    twitchApi: _twitchApi,
    twitchAuth: _twitchAuth,
    modActions: _modActions,
    emoteManager: _emoteManager,
    messageBuilder: _messageBuilder,
    composer: _composer,
    menus: _menus,
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
  String get sharedChatMode => ref.read(sharedChatModeProvider);
  @override
  SevenTvPaintService? get namePaintService =>
      _showNamePaints ? _sevenTvPaintService : null;
  @override
  void onUserBlocked(String login) =>
      _commandHandler.notifyUserBlockChanged(login, blocked: true);
  @override
  void showWhispersForUser(String login) =>
      _mentions.showWhispersForUser(login);
  @override
  void copyMessage(TwitchMessage msg) => _copyMessageToClipboard(msg);

  late final _threads = ThreadPanels(
    panelManager: _panelManager,
    chat: _chat,
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
    chat: _chat,
    session: _session,
    chatConn: _chatConn,
    twitchAuth: _twitchAuth,
    mentionsTab: () => _mentionsTabCtrl,
    composer: _composer,
    messageBuilder: _messageBuilder,
    userSheets: _userSheets,
    menus: _menus,
    mentionsChannel: _mentionsChannel,
    host: this,
  );

  late final _search = SearchPanels(chat: _chat, host: this);

  late final _mod = ModPanels(
    panelManager: _panelManager,
    chat: _chat,
    chatConn: _chatConn,
    twitchAuth: _twitchAuth,
    modActions: _modActions,
    modTab: () => _modTabCtrl,
    composer: _composer,
    closeSearch: () => _search.closeSearch(),
    host: this,
  );

  /// Panel tab drag crossings, merged for ComposerBar so the morph tracks
  /// 50% without a full rebuild per crossing.
  late final _panelDragTick = Listenable.merge([
    _mod.tabDragFocus.dragFocus,
    _mentions.tabDragFocus.dragFocus,
    _threads.tabDragFocus.dragFocus,
  ]);

  late final _chrome = HomeAppBar(
    chat: _chat,
    chatConn: _chatConn,
    networkBusy: _networkBusy,
    twitchAuth: _twitchAuth,
    streamPlayer: _streamPlayer,
    uploadController: _uploadController,
    mentions: _mentions,
    mod: _mod,
    threads: _threads,
    host: this,
  );

  late final _channels = ChannelPanels(
    chat: _chat,
    tileCache: _tileCache,
    messageBuilder: _messageBuilder,
    linkWhitelist: _linkWhitelist,
    twitchAuth: _twitchAuth,
    paintService: _sevenTvPaintService,
    selectedTabIndex: _selectedTabIndex,
    userSheets: _userSheets,
    menus: _menus,
    threads: _threads,
    search: _search,
    composer: _composer,
    broadcastWidgets: _broadcastWidgets,
    homeAppBar: _chrome,
    host: this,
  );

  late final _stream = StreamPanels(
    streamPlayer: _streamPlayer,
    pipService: _pipService,
    chat: _chat,
    channels: _channels,
    homeAppBar: _chrome,
    host: this,
  );

  late final _channelManager = ChannelManager(
    chat: _chat,
    session: _session,
    chatConn: _chatConn,
    irc: ref.read(ircServiceProvider),
    ircRead: ref.read(ircReadServiceProvider),
    twitchAuth: _twitchAuth,
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
    recentMessagesService: ref.read(recentMessagesServiceProvider),
    mentionsChannel: _mentionsChannel,
    host: this,
  );

  late final _emotes = EmoteApplier(
    emoteManager: _emoteManager,
    twitchApi: _twitchApi,
    twitchAuth: _twitchAuth,
    chat: _chat,
    badgeService: _badgeService,
    connectivityService: _connectivityService,
    isMobile: _isMobile,
    networkBusy: _networkBusy,
    host: this,
  );

  // MentionsPanelsHost: shell-owned state the inbox reads but does not own.
  @override
  int get maxMessages => ref.read(maxMessagesPerChannelProvider);
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
  void toggleSearch() {
    if (_activePanel == OverlayPanel.modView) return;
    _search.toggleSearch();
  }

  @override
  void setShowInput(bool value) => _setShowInput(value);
  @override
  void clearComposerSuggestions() => _composer.clearSuggestions();
  @override
  FocusNode get composerFocusNode => _composer.focusNode;
  @override
  void forgetSearch(String channel) {
    _search.forget(channel);
    _search.syncFieldTo(selectedChannel);
    _mod.syncTermsToSelected();
  }

  @override
  void reloadEmotes() => _emotes.reload();
  @override
  void reconnect() => _reconnect();
  @override
  void openSettings() => _openSettings();
  @override
  void commitChannelSelection(int index, {required bool rebuild}) {
    _channelManager.commitChannelSelection(index, rebuild: rebuild);
    _search.syncFieldTo(selectedChannel);
    _mod.syncTermsToSelected();
  }

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
  set selectedChannel(String? value) =>
      ref.read(selectedChannelProvider.notifier).set(value);
  @override
  void mutate(void Function() fn) => setState(fn);
  @override
  void addSystemMessage(String channel, String text) =>
      _addSystemMessage(channel, text);
  @override
  int get recentMessagesLimit => _recentMessagesLimit;
  @override
  bool get mentionPush => ref.read(mentionPushProvider);
  @override
  void disposeChannelNotifiers(String channel) =>
      _scrollControllers.remove(channel)?.dispose();
  @override
  void invalidateCaches() => _channels.invalidateCaches();
  @override
  void forgetAtBottomNotifier(String channel) =>
      _atBottomNotifiers.remove(channel)?.dispose();
  @override
  void showSnack(String message) => _chatNotice.show(message);

  @override
  void initState() {
    super.initState();
    unawaited(_ttsController.init());
    unawaited(PerfLog.I.init());
    DataUsageStats.I.start();
    _session.seed(widget.initialCurrentUserLogin);
    _session.version.addListener(_onSessionApplied);
    _pingManager.setAccount(widget.initialCurrentUserLogin);
    _emotes.loadPrefs();
    _mentionsTabCtrl = TabController(length: 2, vsync: this);
    _mentionsTabCtrl.addListener(_mentions.onMentionsTabChanged);
    _threadsTabCtrl = TabController(length: 3, vsync: this);
    _threadsTabCtrl.addListener(_threads.onThreadsTabChanged);
    _modTabCtrl = TabController(length: ModPanels.tabCount, vsync: this);
    _modTabCtrl.addListener(_mod.onModTabChanged);
    _panelManager.emoteSheetCtrl.addListener(_panelManager.onSheetSizeChanged);
    _panelManager.onPanelClosed = (panel) {
      switch (panel) {
        case OverlayPanel.modView:
          _mod.onPanelClosed();
        case OverlayPanel.mentions:
          _mentions.onMentionsClosed();
        case OverlayPanel.thread:
          _threads.onThreadsClosed();
        case OverlayPanel.closed:
          break;
      }
    };
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
    _streamPlayer.pipService = _pipService;
    _pipService.onPipChanged = (inPip) {
      if (!mounted) return;
      // No context here (channel callback), so dismiss globally. Covers
      // the auto-enter path where no overlay button runs first.
      if (inPip) FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _streamPlayer.setPipActive(inPip));
    };
    // PiP window taps land on the controller; the player view (which owns
    // the WebView) consumes them via its controller listener.
    _pipService.onPipAction = _streamPlayer.notifyPipAction;
    _streamPlayer.addListener(_stream.onStreamPlayerChanged);
    _linkWhitelist.addListener(_onLinkWhitelistChanged);
    _loadNotificationSettings();
    _broadcastWidgets.loadTestWidgets();
    _channelNotifier.addListener(_syncChannelSubs);
    _chat.mentions.version.addListener(_onMentionsContent);
    _syncChannelSubs();
    _subscribeSignals();
    _startChatPipe();
    _emoteManager.startCacheGc();
    _connectivityService.init();
    _badgeService.fetchGlobalBadges(_twitchAuth);
    _thirdPartyBadgeService.bindSevenTvEvents(_sevenTvClient);
    _sevenTvPaintService.bindSevenTvEvents(_sevenTvClient);
    _sevenTvEntitlementSub = _sevenTvClient.onEntitlement.listen(
      _emoteManager.applySevenTvEntitlement,
    );
    unawaited(_thirdPartyBadgeService.fetchFfzBadges());
    unawaited(_thirdPartyBadgeService.fetchBttvBadges());
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
    ref.read(mentionPushProvider.notifier).set(mentionPush);
    setState(() {
      _backgroundService = backgroundService;
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
      if (_chat.names.isNotEmpty) {
        startForegroundService(List.of(_chat.names));
      }
    } else {
      stopForegroundService();
    }
  }

  void _setMentionPush(bool value) {
    if (ref.read(mentionPushProvider) == value) return;
    ref.read(mentionPushProvider.notifier).set(value);
    setState(() {});
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
    if (!_whisperNotify || !ref.read(backgroundedProvider)) return;
    if (_notificationTapSub == null || _mentions.isWhispersTabActive) return;
    unawaited(
      _notificationService.showWhisperNotification(
        userName: msg.displayName,
        message: msg.text,
      ),
    );
  }

  void _setMaxMessagesPerChannel(int value) {
    if (ref.read(maxMessagesPerChannelProvider) == value) return;
    setState(() => ref.read(maxMessagesPerChannelProvider.notifier).set(value));
    // Apply a lower cap immediately instead of waiting for the next incoming
    // message to hit the truncation path.
    for (final channel in List.of(_chat.names)) {
      _channelManager.truncateChannel(channel);
      _chat.channelFor(channel)?.info.touch();
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
      for (final channel in List.of(_chat.names)) {
        _chat.channelFor(channel)?.info.touch();
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
    () => ref.read(sharedChatModeProvider),
    (v) => ref.read(sharedChatModeProvider.notifier).set(v),
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
    for (final channel in List.of(_chat.names)) {
      _chat.channelFor(channel)?.info.touch();
    }
  }

  void _setShowGifs(bool value) {
    if (_showGifs == value) return;
    setState(() => _showGifs = value);
    _messageBuilder.showGifs = value;
    _tileCache.clear();
    for (final channel in List.of(_chat.names)) {
      _chat.channelFor(channel)?.info.touch();
    }
  }

  void _setAnimateGifs(bool value) {
    EmoteUrlProvider.applyGifsEnabled(value);
    if (_animateGifs == value) return;
    setState(() => _animateGifs = value);
    _messageBuilder.animateGifs = value;
    _tileCache.clear();
    for (final channel in List.of(_chat.names)) {
      _chat.channelFor(channel)?.info.touch();
    }
  }

  void _setGifHeight(double value) {
    final clamped = value.clamp(kGiphyInlineHeightMin, kGiphyInlineHeightMax);
    if (_gifHeight == clamped) return;
    setState(() => _gifHeight = clamped);
    _messageBuilder.gifHeight = clamped;
    _tileCache.clear();
    for (final channel in List.of(_chat.names)) {
      _chat.channelFor(channel)?.info.touch();
    }
  }

  void _setShowImages(bool value) {
    if (_showImages == value) return;
    setState(() => _showImages = value);
    _messageBuilder.showImages = value;
    _tileCache.clear();
    for (final channel in List.of(_chat.names)) {
      _chat.channelFor(channel)?.info.touch();
    }
  }

  void _setImageHeight(double value) {
    final clamped = value.clamp(kImageEmbedHeightMin, kImageEmbedHeightMax);
    if (_imageHeight == clamped) return;
    setState(() => _imageHeight = clamped);
    _messageBuilder.imageHeight = clamped;
    _tileCache.clear();
    for (final channel in List.of(_chat.names)) {
      _chat.channelFor(channel)?.info.touch();
    }
  }

  Future<void> _initForegroundService() async {
    initForegroundService();
    await requestForegroundPermissions();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final backgrounded =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive;
    ref.read(backgroundedProvider.notifier).set(backgrounded);
    if (Platform.isAndroid) {
      if (state == AppLifecycleState.paused) {
        if (_backgroundService) {
          startForegroundService(List.of(_chat.names));
        }
      } else if (state == AppLifecycleState.resumed) {
        if (_backgroundService) {
          stopForegroundService();
        }
        if (ref.read(mentionPushProvider)) {
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
    final userId = _twitchAuth.userId;
    if (userId == null) {
      ref.read(chatReadyProvider.notifier).set(true);
      _channelManager.loadChannels();
      return;
    }
    _blocksFetched = true;
    var blocked = <String>{};
    try {
      blocked = await _twitchApi
          .getBlockedUsers(_twitchAuth)
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      logDebug('[HomeScreen] failed to fetch blocked users: $e');
    }
    if (!mounted) return;
    ref.read(blockedLoginsProvider.notifier).addAll(blocked);
    ref.read(chatReadyProvider.notifier).set(true);
    _sweepBlockedMessages();
    _channelManager.loadChannels();
    setState(() {});
  }

  void _sweepBlockedMessages() {
    final blocked = ref.read(blockedLoginsProvider);
    for (final name in List.of(_chat.names)) {
      final channel = _chat.channelFor(name);
      if (channel == null) continue;
      // Blocked messages bypass truncation, so the verb decays them too.
      final removed = channel.removeMessages(
        (m) => !m.isSystem && blocked.contains(m.login.toLowerCase()),
      );
      if (removed.isEmpty) continue;
      _tileCache.remove(name);
    }
  }

  void _onReconnected() {
    _channelManager.onReconnected();
    unawaited(_emotes.refreshSubEmoteOwners());
  }

  void _onLinkWhitelistChanged() {
    // Re-render visible tiles so the new link-whitelist entries take effect.
    _tileCache.clear();
    for (final channel in List.of(_chat.names)) {
      _chat.channelFor(channel)?.info.touch();
    }
    if (mounted) setState(() {});
  }

  void _onConnectivityChanged() {
    final isMobile = _connectivityService.isMobile;
    if (isMobile == _isMobile.value) return;
    _isMobile.value = isMobile;
    DataUsageStats.I.setContext(isMobile: isMobile);
    _emotes.reconcileTier();
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
      _chat.channelFor(channel)?.info.touch();
      _onPanelDataChanged(channel);
    } else {
      for (final c in List.of(_chat.names)) {
        _chat.channelFor(c)?.info.touch();
      }
      _chat.touchMentions();
      _onPanelDataChanged();
    }
  }

  static final _emptyNotifier = ValueNotifier<int>(0);

  ValueNotifier<int> _versionNotifier(String channel) {
    return _chat.channelFor(channel)?.info.version ?? _emptyNotifier;
  }

  ValueNotifier<int> _messageNotifier(String channel) {
    return _chat.channelFor(channel)?.messages.version ?? _emptyNotifier;
  }

  ValueNotifier<bool> _atBottomNotifier(String channel) {
    return _atBottomNotifiers.putIfAbsent(channel, () => ValueNotifier(true));
  }

  StreamSubscription<SevenTvEntitlementEvent>? _sevenTvEntitlementSub;

  final _contentListeners = <String, VoidCallback>{};
  final _infoListeners = <String, VoidCallback>{};
  final _modListeners = <String, VoidCallback>{};
  final _mutationListeners = <String, void Function(String?)?>{};
  final _mutationAllListeners = <String, VoidCallback>{};

  void _showBanner(String message) {
    if (!mounted) return;
    if (message == 'Login expired') {
      _chatNotice.show(
        'Login expired - reconnect your account',
        actionLabel: 'Open Account',
        onAction: () => unawaited(_openSettings()),
      );
      return;
    }
    _chatNotice.show(message);
  }

  // ChatUiSignals forwarding: the pipeline pushes, the shell routes each
  // signal to its existing UI owner. Dispose detaches every subscription.
  void _subscribeSignals() {
    final signals = _signals;
    _signalUnsubs.addAll([
      signals.focusComposer.add(_onFocusComposerSignal),
      signals.banner.add(_showBanner),
      signals.reconnected.add(_onReconnected),
      signals.joinProgress.add(_onJoinProgressSignal),
      signals.whisper.add(_mentions.onWhisper),
      signals.userEmoteSets.add(_onUserEmoteSetsSignal),
      signals.whisperSystem.add(
        (s) => _mentions.addWhisperSystemMessage(s.channel, s.text),
      ),
      signals.whisperSent.add(
        (s) => _mentions.onWhisperSent(s.target, s.message),
      ),
    ]);
  }

  void _onFocusComposerSignal() => _composer.focus();

  void _onJoinProgressSignal(JoinProgressSignal signal) =>
      _channelManager.onJoinProgress(signal.channel, signal.info);

  void _onUserEmoteSetsSignal(UserEmoteSetsSignal signal) =>
      unawaited(_emotes.loadUserEmoteSets(signal.channel, signal.ids));

  void _onChannelContent(String channel) {
    _composer.refreshCooldown();
    _threads.syncSavedWithChannel(channel);
    _onPanelDataChanged(channel);
  }

  void _onChannelInfo(String channel) {
    _composer.refreshCooldown();
    _tileCache.remove(channel);
    _threads.syncSavedWithChannel(channel);
    _onPanelDataChanged(channel);
  }

  void _onMentionsContent() {
    _onPanelDataChanged();
  }

  void _syncChannelSubs() {
    final live = Set.of(_channelNotifier.value);
    for (final name in live) {
      if (_contentListeners.containsKey(name)) continue;
      final channel = _chat.channelFor(name);
      if (channel == null) continue;
      void onContent() => _onChannelContent(name);
      void onInfo() => _onChannelInfo(name);
      // Subscription wakeups mutate no rows, so they refresh panels only:
      // never the tile cache.
      void onModSub() => _onPanelDataChanged(name);
      void onMutation(String? id) {
        if (id != null) _tileCache[name]?.remove(id);
      }

      void onMutateAll() => _tileCache.remove(name);
      channel.messages.version.addListener(onContent);
      channel.info.version.addListener(onInfo);
      channel.moderation.version.addListener(onModSub);
      channel.messages.mutations.addListener(onMutation);
      channel.messages.mutations.addAllListener(onMutateAll);
      _contentListeners[name] = onContent;
      _infoListeners[name] = onInfo;
      _modListeners[name] = onModSub;
      _mutationListeners[name] = onMutation;
      _mutationAllListeners[name] = onMutateAll;
    }
    for (final name in _contentListeners.keys.toList()) {
      if (live.contains(name)) continue;
      final channel = _chat.channelFor(name);
      channel?.messages.version.removeListener(_contentListeners[name]!);
      channel?.info.version.removeListener(_infoListeners[name]!);
      channel?.moderation.version.removeListener(_modListeners[name]!);
      channel?.messages.mutations.removeListener(_mutationListeners[name]!);
      channel?.messages.mutations.removeAllListener(
        _mutationAllListeners[name]!,
      );
      _contentListeners.remove(name);
      _infoListeners.remove(name);
      _modListeners.remove(name);
      _mutationListeners.remove(name);
      _mutationAllListeners.remove(name);
    }
  }

  void _dropChannelSubs() {
    for (final entry in _contentListeners.entries) {
      _chat.channelFor(entry.key)?.messages.version.removeListener(entry.value);
    }
    for (final entry in _infoListeners.entries) {
      _chat.channelFor(entry.key)?.info.version.removeListener(entry.value);
    }
    for (final entry in _modListeners.entries) {
      _chat
          .channelFor(entry.key)
          ?.moderation
          .version
          .removeListener(entry.value);
    }
    for (final entry in _mutationListeners.entries) {
      _chat
          .channelFor(entry.key)
          ?.messages
          .mutations
          .removeListener(entry.value!);
    }
    for (final entry in _mutationAllListeners.entries) {
      _chat
          .channelFor(entry.key)
          ?.messages
          .mutations
          .removeAllListener(entry.value);
    }
    _contentListeners.clear();
    _infoListeners.clear();
    _modListeners.clear();
    _mutationListeners.clear();
    _mutationAllListeners.clear();
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

  // Cold-start pipe shared with account switch: IRC connect and emote
  // priming run together so neither gates the other.
  void _startChatPipe() {
    _chatConn.connect();
    _emoteManager.accessToken = _twitchAuth.accessToken;
    _emoteManager.viewerTwitchId = _twitchAuth.userId;
    _emoteManager.preloadGlobalEmotes();
    unawaited(_emoteManager.loadViewerPersonalSevenTvSets());
  }

  void _onAuthChanged() {
    _mod.refreshOnData(null);
    if (_session.login?.toLowerCase() != _twitchAuth.login?.toLowerCase()) {
      // Account switched (or signed out): drop identity and account-scoped
      // chat state. The remaining resets are HomeScreen side effects.
      _session.clear();
      _chat.clearAccountScopedState();
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
      ref.read(chatReadyProvider.notifier).set(false);
      // The previous account's block list must not keep filtering the new
      // account's chat; the re-fetch below repopulates it.
      ref.read(blockedLoginsProvider.notifier).clear();
      _channelManager.rearmMentionScan();
      // Whispers and the mentions feed belong to the previous account.
      _mentions.clearForAccountSwitch();
      _channelManager.scanHistoryForMentions();
      unawaited(_ensureBlockedUsersLoaded());
    }
    // Same pipe as cold start: connect now so the indicator flips at once;
    // the full re-resolve runs alongside instead of gating the reconnect.
    _startChatPipe();
    unawaited(_emotes.refreshAfterAuth());
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
    for (final channel in _chat.names) {
      if (!_chatConn.isChannelChatReady(channel)) return true;
    }
    return false;
  }

  // Connection phase changes can flip moderation/room state; refresh the
  // open mod panel so gating and room modes do not go stale.
  void _onConnectionChanged() {
    if (_activePanel == OverlayPanel.modView) _mod.refreshOnData(null);
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
      ref
          .read(maxMessagesPerChannelProvider.notifier)
          .set(
            prefs.getInt('max_messages_per_channel') ??
                kMaxMessagesPerChannelDefault,
          );
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
      ref
          .read(sharedChatModeProvider.notifier)
          .set(prefs.getString('shared_chat_mode') ?? 'spotlight');
      _showNamePaints = prefs.getBool('seventv_name_paints') ?? false;
      _showGifs =
          prefs.getBool(kGiphyInlineEnabledPrefKey) ??
          kGiphyInlineEnabledDefault;
      _gifHeight =
          (prefs.getDouble(kGiphyInlineHeightPrefKey) ??
                  kGiphyInlineHeightDefault)
              .clamp(kGiphyInlineHeightMin, kGiphyInlineHeightMax);
      _showImages =
          prefs.getBool(kImageEmbedEnabledPrefKey) ?? kImageEmbedEnabledDefault;
      _imageHeight =
          (prefs.getDouble(kImageEmbedHeightPrefKey) ??
                  kImageEmbedHeightDefault)
              .clamp(kImageEmbedHeightMin, kImageEmbedHeightMax);
      _showInput = prefs.getBool('show_input') ?? true;
      _animateGifs = prefs.getBool('animate_gifs') ?? true;
      _messageBuilder.showGifs = _showGifs;
      _messageBuilder.gifHeight = _gifHeight;
      _messageBuilder.showImages = _showImages;
      _messageBuilder.imageHeight = _imageHeight;
      _messageBuilder.animateGifs = _animateGifs;
      // Prefs load async; tiles built with defaults before this returns
      // would keep stale spans, so evict them like the live setters do.
      _tileCache.clear();
      for (final channel in List.of(_chat.names)) {
        _chat.channelFor(channel)?.info.touch();
      }
    });
    if (_showNamePaints) {
      _sevenTvPaintService.enabled = true;
      for (final channel in List.of(_chat.names)) {
        _chat.channelFor(channel)?.info.touch();
      }
    }
  }

  @override
  void dispose() {
    _isMobile.dispose();
    DataUsageStats.I.dispose();
    for (final unsubscribe in _signalUnsubs) {
      unsubscribe();
    }
    _signalUnsubs.clear();
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.removeObserver(_predictiveBackHandler);
    _panelManager.dispose();
    _composer.dispose();
    _networkBusy.dispose();
    _sevenTvEntitlementSub?.cancel();
    _linkWhitelist.removeListener(_onLinkWhitelistChanged);
    _streamPlayer.removeListener(_stream.onStreamPlayerChanged);
    _streamPlayer.dispose();
    _mentionsTabCtrl.removeListener(_mentions.onMentionsTabChanged);
    _mentionsTabCtrl.dispose();
    _threadsTabCtrl.removeListener(_threads.onThreadsTabChanged);
    _threadsTabCtrl.dispose();
    _modTabCtrl.removeListener(_mod.onModTabChanged);
    _modTabCtrl.dispose();
    _threads.dispose();
    _mentions.dispose();
    _mod.dispose();
    _search.dispose();
    for (final c in _scrollControllers.values) {
      c.dispose();
    }
    for (final n in _atBottomNotifiers.values) {
      n.dispose();
    }
    _tileCache.clear();
    _channelNotifier.removeListener(_syncChannelSubs);
    _chat.mentions.version.removeListener(_onMentionsContent);
    _dropChannelSubs();
    _session.version.removeListener(_onSessionApplied);
    _notificationTapSub?.cancel();
    super.dispose();
  }

  void _addSystemMessage(
    String channel,
    String text, {
    Color? accent,
    String? messageId,
  }) {
    final messages = _chat.channelFor(channel)?.messages;
    if (messages == null) return;
    if (!messages.addSystem(text, accent: accent, messageId: messageId)) {
      return;
    }
    _truncateChannelMessages(channel);
  }

  void _toggleFullscreen() {
    setState(() => _isFullscreen = !_isFullscreen);
  }

  void _toggleInputVisibility() => _setShowInput(!_showInput);

  void _setShowInput(bool value) {
    if (_showInput == value) return;
    setState(() => _showInput = value);
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setBool('show_input', value),
      ),
    );
  }

  /// Translates join-queue progress into a live countdown system line
  /// ("Joining: position 12, ~14s"); position 0 means numbers are over
  /// (sent, awaiting echo) and the line degrades to a plain marker; a null
  /// [info] retires the line.
  void _copyMessageToClipboard(TwitchMessage msg) {
    Clipboard.setData(ClipboardData(text: msg.text));
    _chatNotice.show(
      'Message copied',
      actionLabel: 'Paste',
      onAction: _pasteFromClipboard,
    );
  }

  void _copyEmail(String email) {
    Clipboard.setData(ClipboardData(text: email));
    if (!mounted) return;
    _chatNotice.show('Copied $email');
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
    // The menu hands focus back to the search field on close, which
    // would raise the keyboard over the settings page.
    _search.focusNode.unfocus();
    // Pop notices and overlay snackbars on screen change.
    _chatNotice.dismiss();
    if (mounted) AppSnack.clear(context);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          twitchAuth: _twitchAuth,
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
          onAnimateGifsChanged: _setAnimateGifs,
          onAdaptiveThrottleChanged: EmoteUrlProvider.applyAdaptiveThrottle,
          onAlwaysAnimatePanelChanged: (value) =>
              EmoteUrlProvider.alwaysAnimatePanel = value,
          onCapEmoteFpsChanged: _emotes.setCapFps,
          onCheckeredMessagesChanged: _setCheckeredMessages,
          onHighlightOpacityChanged: _setHighlightOpacity,
          onLineSeparatorChanged: _setLineSeparator,
          onFastSnapChanged: _setFastSnap,
          onNamePaintsChanged: _setNamePaints,
          onShowGifsChanged: _setShowGifs,
          onGifHeightChanged: _setGifHeight,
          onShowImagesChanged: _setShowImages,
          onImageHeightChanged: _setImageHeight,
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
          channels: _chat.names,
          ttsController: _ttsController,
          emoteManager: _emoteManager,
          onStreamExtensionsChanged: _streamPlayer.setShowExtensions,
          onRetainWebviewChanged: _streamPlayer.setRetainWebview,
          onPipEnabledChanged: _streamPlayer.setPipEnabled,
          onTestWidgetsChanged: _broadcastWidgets.setTestWidgets,
        ),
      ),
    );
    if (mounted) ref.invalidate(macrosProvider);
    if (_nukePending) {
      _nukePending = false;
      if (!mounted) return;
      NukeOverlay.show(context);
      await _emotes.runRefresh(nuke: true);
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
      selectedChannel: selectedChannel,
      emoteManager: _emoteManager,
      channelUserIds: _channelUserIds(),
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

  void _onNotificationTap(String channel) {
    _navigateToChannel(channel);
  }

  void _navigateToChannel(String channel) {
    final index = _chat.names.indexOf(channel);
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
    // Provider-owned shared objects observed as Riverpod state. These replace
    // the manual addListener/removeListener pairs; ref.listen auto-cancels.
    ref.listen(emoteManagerTickProvider, (_, _) => _onEmotesChanged());
    ref.listen(twitchAuthTickProvider, (_, _) => _onAuthChanged());
    ref.listen(connectivityTickProvider, (_, _) => _onConnectivityChanged());
    ref.listen(connectionStateProvider, (_, _) => _onConnectionChanged());
    return PopScope(
      canPop:
          !_isFullscreen &&
          !_streamPlayer.isTheaterMode &&
          _activePanel == OverlayPanel.closed &&
          !_emoteSheetOpen &&
          !_search.open &&
          !_composer.hasFocus,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_search.open) {
          _search.closeSearch();
        } else if (_emoteSheetOpen) {
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
        // Stock resize path: the Scaffold shrinks the body with the
        // keyboard, replaying the system ticks directly. No manual lift and
        // no second animator: Dart curves of a different duration only cross
        // the system motion (behind-ahead-behind). Discrete rules read the
        // debounced lift in ChatBody so they flip once per gesture.
        resizeToAvoidBottomInset: true,
        body: ListenableBuilder(
          listenable: _streamPlayer,
          builder: (_, _) => ChatBody(
            emoteMaxFraction: _emoteMaxFraction,
            // Read above the Scaffold: the body subtree sees viewInsets
            // stripped to zero once the Scaffold consumes them resizing.
            keyboardH: MediaQuery.viewInsetsOf(context).bottom,
            // System PiP collapses the whole body to video-only; ChatBody
            // drops composer/panels/notice so the window shows the stream.
            isInPip: _streamPlayer.isInPip,
            bodyBuilder:
                (
                  context, {
                  required hideChromeForKeyboard,
                  required maxWidth,
                  required maxHeight,
                  required keyboardH,
                  required composerH,
                }) {
                  return _stream.bodyColumn(
                    context,
                    hideChromeForKeyboard: hideChromeForKeyboard,
                    maxWidth: maxWidth,
                    maxHeight: maxHeight,
                    keyboardH: keyboardH,
                    composerH: composerH,
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
              onShowUser: (login) =>
                  _userSheets.showUserProfile(context, login, null),
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
                    search: _search,
                    mod: _mod,
                    dragTick: _panelDragTick,
                  )
                : null,
            notice: ChatNoticeBar(controller: _chatNotice),
          ),
        ),
      ),
    );
  }

  /// Whether the selected channel's JOIN is confirmed on the write socket.
  /// Between socket-connect and join-confirm, PRIVMSGs would vanish - the
  /// input stays disabled for that window. Whispers are not channel-bound.
  bool get _channelChatReady {
    final channel = selectedChannel;
    return channel != null && _chatConn.isChannelChatReady(channel);
  }

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
                        selectedChannel: selectedChannel,
                        onEmoteSelected: _onEmoteSelected,
                        onClose: _closeEmoteSheet,
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
