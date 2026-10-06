import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_providers.dart';
import '../providers/channel_providers.dart';
import '../providers/chat_pipeline.dart';
import '../providers/emote_providers.dart';
import '../providers/feature_providers.dart';
import '../providers/ui_state_providers.dart';
import '../emotes/emote.dart';
import '../l10n/l10n.dart';
import '../models/twitch_message.dart';
import '../util/chat_text.dart';
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
import '../services/emote_controller.dart';
import '../services/emote_usage_registry.dart';
import '../util/data_usage.dart';
import '../services/stream_player_controller.dart';
import '../services/pip_service.dart';
import '../services/analytics_service.dart';
import '../services/twitch_badge_service.dart';
import '../services/third_party_badge_service.dart';
import '../widgets/seven_tv_paint_service.dart';
import '../util/log.dart';
import '../util/constants.dart';
import '../util/prefs.dart';
import '../util/prefs_store.dart';
import '../util/timestamp_formatter.dart';
import '../screens/settings/settings_screen.dart';
import '../widgets/panel_manager.dart';
import '../widgets/glass_chrome.dart';
import '../widgets/welcome_dialog.dart';
import '../services/user_store.dart';
import '../chat/chat.dart';
import '../client/session.dart';
import '../composer/suggestion.dart';
import '../services/notification_service.dart';
import '../services/tts_controller.dart';
import '../widgets/autocomplete_dropdown.dart';
import '../widgets/app_snack.dart';
import '../widgets/broadcast_widgets.dart';
import '../widgets/chat_body.dart';
import '../widgets/chat_notice_bar.dart';
import '../widgets/message_input.dart';
import '../composer/composer_bar.dart';
import '../composer/composer_controller.dart';
import '../sheets/message_menu.dart';
import '../sheets/user_sheet.dart';
import '../channels/channel_manager.dart';
import '../chrome/channel_stack.dart';
import '../chrome/home_app_bar.dart';
import '../chrome/stream_layout.dart';
import '../panels/threads.dart';
import '../panels/mentions.dart';
import '../panels/mod_panel.dart';
import '../panels/search.dart';
import '../widgets/nuke_overlay.dart';
import '../widgets/emote_url_provider.dart';
import '../widgets/media_upload_controller.dart';
import '../widgets/emote_menu_panel.dart';
import '../widgets/message_builder.dart';
import '../widgets/predictive_back_handler.dart';
import '../widgets/join_channel_dialog.dart';
import '../services/fake_chat_feed.dart';
import '../services/foreground_task.dart';

class HomeScreen extends ConsumerStatefulWidget {
  // Test seam: when true the join ("+") button never shows its loading spinner.
  // Tests that intentionally keep the app disconnected (un-faked TwitchChatApp)
  // flip this so they can still reach the button during the permanent
  // "connecting" state instead of hitting the gated spinner.
  static bool disableJoinSpinner = false;

  final String? initialCurrentUserLogin;

  /// Reports routes pushed over this screen, so the composer can drop focus
  /// before a sheet or page takes it.
  final RouteObserver<ModalRoute<Object?>>? routeObserver;

  const HomeScreen({
    super.key,
    this.initialCurrentUserLogin,
    this.routeObserver,
  });

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin, RouteAware {
  static const _mentionsChannel = '@mentions';

  late final ConnectivityService _connectivityService = ref.read(
    connectivityServiceProvider,
  );

  SevenTvEventClient get _sevenTvClient => ref.read(sevenTvClientProvider);
  TwitchApi get _twitchApi => ref.read(twitchApiProvider);
  PingManager get _pingManager => ref.read(pingManagerProvider);
  IgnoreManager get _ignoreManager => ref.read(ignoreManagerProvider);

  final _linkWhitelist = LinkWhitelist.instance;

  AnalyticsService get _analytics => ref.read(analyticsServiceProvider);
  TtsController get _ttsController => ref.read(ttsControllerProvider);

  late final Chat _chat = ref.read(chatProvider);

  late final Session _session = ref.read(sessionProvider);

  late final TwitchAuth _twitchAuth = ref.read(twitchAuthProvider);

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

  // The provider owns teardown, so the screen only observes its notifiers.
  late final ChatConnectionManager _chatConn = ref.read(chatPipelineProvider);

  late final MessageBuilder _messageBuilder = MessageBuilder(
    emoteSource: _emoteLookupSource,
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
  Map<String, String> _channelUserIds() => ref.read(channelUserIdsProvider)();

  ModActions get _modActions => ref.read(modActionsProvider);
  CommandHandler get _commandHandler => ref.read(commandHandlerProvider);
  late final MediaUploadController _uploadController = MediaUploadController(
    onNotice: _chatNotice.show,
  );

  NotificationService get _notificationService =>
      ref.read(notificationServiceProvider);
  StreamSubscription<String>? _notificationTapSub;
  bool _backgroundService = false;
  bool _whisperNotify = true;

  final _isMobile = ValueNotifier<bool>(false);

  late final EmoteManager _emoteManager = ref.read(emoteManagerProvider);
  late final FakeChatFeed _fakeChat = FakeChatFeed(
    // ignore: invalid_use_of_visible_for_testing_member
    decoder: _chatConn.readDecoder,
    channel: () => selectedChannel,
    emotes: _emoteManager.channelTabEmotes,
  );

  late final EmoteLookupSource _emoteLookupSource = ref.read(
    emoteLookupSourceProvider,
  );

  late final EmoteUsageRegistry _emoteUsage = ref.read(
    emoteUsageRegistryProvider,
  );

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
  final _scrollControllers = <String, ScrollController>{};
  final _atBottomNotifiers = <String, ValueNotifier<bool>>{};
  ChatNoticeController get _chatNotice => ref.read(chatNoticeProvider);

  late final ChatUiSignals _signals = ref.read(chatUiSignalsProvider);

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
  // Kept so dispose unbinds only the handlers this state installed.
  late final PipService _pip;
  ValueChanged<bool>? _pipChangedHandler;
  ValueChanged<String>? _pipActionHandler;
  bool _showTimestamps = true;
  String _timestampFormat = kDefaultTimestampFormat;
  double _chatFontSize = 14.0;
  double _highlightOpacity = 0.6;
  bool _checkeredMessages = false;
  Color? _lastSurface;
  bool _lineSeparator = false;
  bool _fastSnap = true;

  /// Liquid glass chrome (default off; toggled in Customization).
  bool _liquidGlass = false;

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

  /// Mirror of the live system UI mode, so redundant SystemChrome calls are
  /// skipped while a forced re-apply (app resume) stays explicit.
  bool _immersive = false;

  /// Whether the chat input box + status row is shown. Persisted.
  bool _showInput = true;

  // The provider owns teardown; the shell only binds PiP and observes it.
  late final StreamPlayerController _streamPlayer = ref.read(
    streamPlayerProvider,
  );

  bool _theaterChatVisible = true;

  final _selectedTabIndex = ValueNotifier<int>(0);

  late final _panelManager = PanelManager(
    vsync: this,
    markDirty: () {
      if (mounted) setState(() {});
    },
    isMounted: () => mounted,
  );

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
    emoteSource: _emoteLookupSource,
    emoteUsage: _emoteUsage,
    userStore: _userStore,
    chat: _chat,
    session: _session,
    getReplyTo: () => ref.read(replyToProvider),
    setReplyTo: (value) => ref.read(replyToProvider.notifier).set(value),
    getSelectedChannel: () => ref.read(selectedChannelProvider),
    isWhispersTabActive: () => _mentions.isWhispersTabActive,
    whisperTarget: () => _mentions.whisperTarget,
    activePanel: () => _activePanel,
    threadsTabIndex: () => _threads.effectiveThreadsTab,
    openThreadRoot: () => _panelManager.openThreadRoot,
    replyToRoot: () => _replyToRoot,
    preferEmotesFirst: () => _preferEmotesFirst,
    computeThreadMessages: () => _threads.computeThreadMessages(),
    channelChatReady: () => _channelChatReady,
    showNotice: showNotice,
    strings: () => context.l10n,
    emoteSheetOpen: () => _emoteSheetOpen,
    closeEmoteSheet: _closeEmoteSheet,
    showEmoteMenu: _showEmoteMenu,
    markDirty: markDirty,
  );

  String? get selectedChannel => ref.read(selectedChannelProvider);

  void showNotice(String text) {
    _chatNotice.show(text);
  }

  void markDirty() {
    if (mounted) setState(() {});
  }

  late final MessageMenus _menus = MessageMenus(
    prefs: ref.read(prefsProvider),
    findThreadRoot: (msg) => _threads.findThreadRoot(msg),
    showThreadView: (root) =>
        _threads.showThreadView(root, switchChannel: true),
    startReply: _composer.startReply,
  );

  late final UserSheets _userSheets = UserSheets(
    chat: _chat,
    chatConn: _chatConn,
    twitchApi: _twitchApi,
    twitchAuth: _twitchAuth,
    modActions: _modActions,
    emoteSource: _emoteLookupSource,
    emoteUsage: _emoteUsage,
    messageBuilder: _messageBuilder,
    composer: _composer,
    menus: _menus,
    selectedChannel: () => ref.read(selectedChannelProvider),
    session: _session,
    paintService: _sevenTvPaintService,
    onUserBlocked: (login) =>
        _commandHandler.notifyUserBlockChanged(login, blocked: true),
    showWhispersForUser: (login) => _mentions.showWhispersForUser(login),
    copyMessage: _copyMessageToClipboard,
    prefs: ref.read(prefsProvider),
  );

  late final ThreadPanels _threads = ThreadPanels(
    panelManager: _panelManager,
    chat: _chat,
    threadsTab: () => _threadsTabCtrl,
    composer: _composer,
    messageBuilder: _messageBuilder,
    userSheets: _userSheets,
    menus: _menus,
    selectedChannel: () => ref.read(selectedChannelProvider),
    isMounted: () => mounted,
    markDirty: markDirty,
    switchChannelTo: (index) => _channels.onChannelChanged(index),
    showNotice: showNotice,
    showTimestamps: () => _showTimestamps,
    timestampFormat: () => _timestampFormat,
    chatFontSize: () => _chatFontSize,
    checkeredMessages: () => _checkeredMessages,
    highlightOpacity: () => _highlightOpacity,
    lineSeparator: () => _lineSeparator,
    sharedChatMode: () => ref.read(sharedChatModeProvider),
    namePaintService: () => _showNamePaints ? _sevenTvPaintService : null,
    copyMessage: _copyMessageToClipboard,
    strings: () => context.l10n,
  );

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
    isMounted: () => mounted,
    markDirty: markDirty,
    maxMessages: () => ref.read(maxMessagesPerChannelProvider),
    notifyWhisper: _maybeNotifyWhisper,
    showTimestamps: () => _showTimestamps,
    timestampFormat: () => _timestampFormat,
    chatFontSize: () => _chatFontSize,
    checkeredMessages: () => _checkeredMessages,
    highlightOpacity: () => _highlightOpacity,
    lineSeparator: () => _lineSeparator,
    sharedChatMode: () => ref.read(sharedChatModeProvider),
    copyMessage: _copyMessageToClipboard,
    namePaintService: () => _showNamePaints ? _sevenTvPaintService : null,
  );

  late final _search = SearchPanels(
    chat: _chat,
    selectedChannel: () => ref.read(selectedChannelProvider),
    isMounted: () => mounted,
    markDirty: markDirty,
    showInput: () => _showInput,
    setShowInput: setShowInput,
    emoteSheetOpen: () => _emoteSheetOpen,
    closeEmoteSheet: _closeEmoteSheet,
    clearComposerSuggestions: _composer.clearSuggestions,
    composerFocusNode: _composer.focusNode,
  );

  late final _mod = ModPanels(
    panelManager: _panelManager,
    chat: _chat,
    chatConn: _chatConn,
    twitchAuth: _twitchAuth,
    modActions: _modActions,
    modTab: () => _modTabCtrl,
    composer: _composer,
    closeSearch: () => _search.closeSearch(),
    selectedChannel: () => ref.read(selectedChannelProvider),
    isMounted: () => mounted,
    markDirty: markDirty,
    showNotice: showNotice,
    showInput: () => _showInput,
    setShowInput: setShowInput,
    strings: () => context.l10n,
    emoteSheetOpen: () => _emoteSheetOpen,
    closeEmoteSheet: _closeEmoteSheet,
    clearComposerSuggestions: _composer.clearSuggestions,
    composerFocusNode: _composer.focusNode,
  );

  /// Panel tab drag crossings, merged for ComposerBar so the morph tracks
  /// 50% without a full rebuild per crossing.
  late final _panelDragTick = Listenable.merge([
    _mod.tabDragFocus.dragFocus,
    _mentions.tabDragFocus.dragFocus,
    _threads.tabDragFocus.dragFocus,
  ]);

  late final HomeAppBar _chrome = HomeAppBar(
    chat: _chat,
    chatConn: _chatConn,
    networkBusy: _networkBusy,
    twitchAuth: _twitchAuth,
    streamPlayer: _streamPlayer,
    uploadController: _uploadController,
    mentions: _mentions,
    mod: _mod,
    threads: _threads,
    activePanel: () => _activePanel,
    closePanel: _closePanel,
    chatLoading: () => _chatLoading,
    disableJoinSpinner: () => HomeScreen.disableJoinSpinner,
    selectedChannel: () => ref.read(selectedChannelProvider),
    isMounted: () => mounted,
    markDirty: markDirty,
    addChannelDialog: _addChannelDialog,
    toggleFullscreen: _toggleFullscreen,
    toggleInput: _toggleInputVisibility,
    toggleStream: () => _stream.toggleStreamForSelected(),
    toggleSearch: _toggleSearch,
    reloadEmotes: _emotes.reload,
    reconnect: _reconnect,
    openSettings: _openSettings,
  );

  late final ChannelPanels _channels = ChannelPanels(
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
    selectedChannel: () => ref.read(selectedChannelProvider),
    showTimestamps: () => _showTimestamps,
    timestampFormat: () => _timestampFormat,
    chatFontSize: () => _chatFontSize,
    checkeredMessages: () => _checkeredMessages,
    highlightOpacity: () => _highlightOpacity,
    lineSeparator: () => _lineSeparator,
    sharedChatMode: () => ref.read(sharedChatModeProvider),
    showNamePaints: () => _showNamePaints,
    isFullscreen: () => _isFullscreen,
    fastSnap: () => _fastSnap,
    commitChannelSelection: _commitChannelSelection,
    copyMessage: _copyMessageToClipboard,
    messageNotifier: _messageNotifier,
    atBottomNotifier: _atBottomNotifier,
    scrollCtrl: _scrollCtrl,
  );

  late final StreamPanels _stream = StreamPanels(
    streamPlayer: _streamPlayer,
    pipService: _pipService,
    chat: _chat,
    channels: _channels,
    homeAppBar: _chrome,
    selectedChannel: () => ref.read(selectedChannelProvider),
    isMounted: () => mounted,
    markDirty: markDirty,
    setStreamState: _setStreamState,
    chatFontSize: () => _chatFontSize,
    isFullscreen: () => _isFullscreen,
    theaterChatVisible: () => _theaterChatVisible,
    toggleTheaterChat: _toggleTheaterChat,
    onChannelChanged: _channels.onChannelChanged,
  );

  late final _channelManager = ChannelManager(
    session: ref.read(channelSessionProvider),
    composer: _composer,
    threads: _threads,
    broadcastWidgets: _broadcastWidgets,
    tileCache: _tileCache,
    channelNotifier: _channelNotifier,
    selectedTabIndex: _selectedTabIndex,
    isMounted: () => mounted,
    markDirty: markDirty,
    mutate: _mutate,
    closePanel: _closePanel,
    atBottomNotifier: _atBottomNotifier,
    disposeChannelNotifiers: _disposeChannelNotifiers,
    forgetAtBottomNotifier: _forgetAtBottomNotifier,
    forgetSearch: _forgetSearch,
    invalidateCaches: _channels.invalidateCaches,
    notificationService: _notificationService,
    mentionPush: () => ref.read(mentionPushProvider),
  );

  late final EmoteController _emotes = ref.read(emoteControllerProvider);

  // Verb adapters the owners hold as lazy callbacks, reading live shell state.
  void _setStreamState(void Function() fn) => setState(fn);

  void _toggleTheaterChat() =>
      setState(() => _theaterChatVisible = !_theaterChatVisible);

  void _toggleSearch() {
    if (_activePanel == OverlayPanel.modView) return;
    _search.toggleSearch();
  }

  void setShowInput(bool value) {
    if (_showInput == value) return;
    setState(() => _showInput = value);
    unawaited(Prefs.load().then((prefs) => prefs.setShowInput(value)));
  }

  void _forgetSearch(String channel) {
    _search.forget(channel);
    _search.syncFieldTo(selectedChannel);
    _mod.syncTermsToSelected();
  }

  void _commitChannelSelection(int index, {required bool rebuild}) {
    _channelManager.commitChannelSelection(index, rebuild: rebuild);
    _search.syncFieldTo(selectedChannel);
    _mod.syncTermsToSelected();
  }

  void _mutate(void Function() fn) => setState(fn);

  void _disposeChannelNotifiers(String channel) =>
      _scrollControllers.remove(channel)?.dispose();

  void _forgetAtBottomNotifier(String channel) =>
      _atBottomNotifiers.remove(channel)?.dispose();

  @override
  void initState() {
    super.initState();
    unawaited(_ttsController.init());
    unawaited(PerfLog.I.init());
    DataUsageStats.I.start();
    // Creating the outbox resends reports queued in an earlier session.
    ref.read(bugReportOutboxProvider);
    _session.seed(widget.initialCurrentUserLogin);
    _session.version.addListener(_onSessionApplied);
    _pingManager.setAccount(widget.initialCurrentUserLogin);
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
    // Main loaded prefs before the home screen, so the first frame can use
    // them; the async pass then only picks up later writes.
    final loaded = Prefs.loaded;
    if (loaded != null) _applyPrefsFrom(loaded, initial: true);
    _applyPrefs();
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
    _pip = _pipService;
    _pipChangedHandler = (inPip) {
      if (!mounted) return;
      // No context here (channel callback), so dismiss globally. Covers
      // the auto-enter path where no overlay button runs first.
      if (inPip) FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _streamPlayer.setPipActive(inPip));
    };
    _pip.onPipChanged = _pipChangedHandler;
    // PiP window taps land on the controller; the player view (which owns
    // the WebView) consumes them via its controller listener.
    _pipActionHandler = _streamPlayer.notifyPipAction;
    _pip.onPipAction = _pipActionHandler;
    _streamPlayer.addListener(_stream.onStreamPlayerChanged);
    _streamPlayer.addListener(_syncSystemUiMode);
    _linkWhitelist.addListener(_onLinkWhitelistChanged);
    PrefsStore.instance.addListener(_onPrefsChanged);
    _loadNotificationSettings();
    _broadcastWidgets.loadTestWidgets();
    _channelNotifier.addListener(_syncChannelSubs);
    _chat.mentions.version.addListener(_onMentionsContent);
    _syncChannelSubs();
    _subscribeSignals();
    _connectChat();
    _emotes.start();
    _connectivityService.init();
    _badgeService.fetchGlobalBadges(_twitchAuth);
    _thirdPartyBadgeService.bindSevenTvEvents(_sevenTvClient);
    _sevenTvPaintService.bindSevenTvEvents(_sevenTvClient);
    unawaited(_thirdPartyBadgeService.fetchFfzBadges());
    unawaited(_thirdPartyBadgeService.fetchBttvBadges());
    unawaited(_thirdPartyBadgeService.fetchLimerinoBadges());
    unawaited(_thirdPartyBadgeService.fetchListBadges());
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
    final prefs = await Prefs.load();
    if (prefs.welcomeSeen) return;
    await prefs.setWelcomeSeen(true);
    if (!mounted) return;
    showWelcomeDialog(context);
  }

  Future<void> _loadNotificationSettings() async {
    final prefs = await Prefs.load();
    final backgroundService = prefs.backgroundService;
    final mentionPush = prefs.mentionPush;
    final whisperNotify = prefs.whisperNotifications;
    if (!mounted) return;
    ref.read(mentionPushProvider.notifier).set(mentionPush);
    ref
        .read(notificationPauseProvider.notifier)
        .restore(prefs.notificationsPausedUntil);
    setState(() {
      _backgroundService = backgroundService;
      _whisperNotify = whisperNotify;
    });
    if (!Platform.isAndroid) return;
    if (backgroundService) {
      initForegroundService(mounted ? context.l10n : null);
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
    final route = ModalRoute.of(context);
    if (route != null) widget.routeObserver?.subscribe(this, route);
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
    // The Highlights master switch covers whispers too.
    if (!_whisperNotify || !ref.read(mentionPushProvider)) return;
    if (!ref.read(backgroundedProvider)) return;
    if (ref.read(notificationPauseProvider.notifier).paused) return;
    if (_notificationTapSub == null || _mentions.isWhispersTabActive) return;
    unawaited(
      _notificationService.showWhisperNotification(
        userName: msg.displayName,
        message: msg.text,
      ),
    );
  }

  Future<void> _initForegroundService() async {
    initForegroundService(context.l10n);
    await requestForegroundPermissions();
  }

  /// Decoded frames buy nothing while nothing renders: emotes re-decode from
  /// the disk cache on return. Frames on screen stay until their rows go.
  void _releaseDecodedImages() {
    EmoteUrlProvider.releaseDecodedFrames();
    PaintingBinding.instance.imageCache.clear();
  }

  @override
  void didHaveMemoryPressure() => _releaseDecodedImages();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _releaseDecodedImages();
      // Android may kill a paused app without warning; save stats now.
      unawaited(_analytics.flush());
    }
    // Inactive is still on screen (notification shade, system dialog), so
    // only a hidden app counts as backgrounded for notifications.
    final backgrounded =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
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
      // Android clears immersive on background; re-assert it on return.
      _syncSystemUiMode(force: true);
    }
  }

  @override
  void didChangeMetrics() {
    // Rotation flips the theater layout; read the settled MediaQuery after
    // the rebuild, since this callback still sees the pre-rotation size.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncSystemUiMode());
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
    final touched = _chat.removeBlocked(blocked);
    for (final name in touched) {
      _tileCache.remove(name);
    }
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

  static final _emptyNotifier = ValueNotifier<int>(0);

  ValueNotifier<int> _messageNotifier(String channel) {
    return _chat.channelFor(channel)?.messages.version ?? _emptyNotifier;
  }

  ValueNotifier<bool> _atBottomNotifier(String channel) {
    return _atBottomNotifiers.putIfAbsent(channel, () => ValueNotifier(true));
  }

  final _contentListeners = <String, VoidCallback>{};
  final _infoListeners = <String, VoidCallback>{};
  final _modListeners = <String, VoidCallback>{};
  final _threadListeners = <String, VoidCallback>{};
  final _mutationListeners = <String, void Function(String?)?>{};
  final _mutationAllListeners = <String, VoidCallback>{};

  void _showBanner(String message) {
    if (!mounted) return;
    if (message == 'Login expired') {
      _chatNotice.show(
        context.l10n.loginExpiredReconnect,
        actionLabel: context.l10n.openAccount,
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
    final emoteSignals = ref.read(emoteSignalsProvider);
    _signalUnsubs.addAll([
      signals.focusComposer.add(_onFocusComposerSignal),
      signals.banner.add(_showBanner),
      signals.whisper.add(_mentions.onWhisper),
      signals.userEmoteSets.add(_onUserEmoteSetsSignal),
      signals.whisperSystem.add(
        (s) => _mentions.addWhisperSystemMessage(s.channel, s.text),
      ),
      signals.whisperSent.add(
        (s) => _mentions.onWhisperSent(s.target, s.message),
      ),
      emoteSignals.snack.add(_chatNotice.show),
      emoteSignals.busy.add((value) => _networkBusy.value = value),
    ]);
  }

  void _onFocusComposerSignal() => _composer.focus();

  void _onUserEmoteSetsSignal(UserEmoteSetsSignal signal) =>
      unawaited(_emotes.loadUserEmoteSets(signal.channel, signal.ids));

  void _onChannelContent(String channel) {
    if (channel == selectedChannel) _composer.refreshCooldown();
    _threads.syncSavedWithChannel(channel, newOnly: true);
  }

  void _onChannelInfo(String channel) {
    _composer.refreshCooldown();
    _tileCache.remove(channel);
    _threads.syncSavedWithChannel(channel);
    _onPanelDataChanged(channel);
    // Badges and link rules render into mention rows too.
    _onMentionsContent();
  }

  void _onMentionsContent() {
    if (_activePanel == OverlayPanel.mentions) _mentions.refreshOnData();
  }

  // Channels with row edits awaiting one coalesced panel refresh.
  final _rowPanelChannels = <String>{};

  /// Mention and thread rows are shared with the channel buffers, so in-place
  /// edits there (deletes, restamps) refresh the panels. A ban emits one edit
  /// per row, so the refresh runs once per channel after the verb finishes.
  void _refreshRowPanels(String channel) {
    if (_activePanel == OverlayPanel.closed) return;
    final scheduled = _rowPanelChannels.isNotEmpty;
    _rowPanelChannels.add(channel);
    if (scheduled) return;
    scheduleMicrotask(() {
      final channels = List.of(_rowPanelChannels);
      _rowPanelChannels.clear();
      if (!mounted) return;
      _onMentionsContent();
      for (final c in channels) {
        _threads.refreshOnData(c);
      }
    });
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
      // Thread index runs after Messages.version fires, so thread panels
      // observe the index itself and never read it too early.
      void onThread() => _onPanelDataChanged(name);
      void onMutation(String? id) {
        if (id != null) _tileCache[name]?.remove(id);
        _refreshRowPanels(name);
      }

      void onMutateAll() {
        _tileCache.remove(name);
        _refreshRowPanels(name);
      }

      channel.messages.version.addListener(onContent);
      channel.info.version.addListener(onInfo);
      channel.moderation.version.addListener(onModSub);
      channel.threads.version.addListener(onThread);
      channel.messages.mutations.addListener(onMutation);
      channel.messages.mutations.addAllListener(onMutateAll);
      _contentListeners[name] = onContent;
      _infoListeners[name] = onInfo;
      _modListeners[name] = onModSub;
      _threadListeners[name] = onThread;
      _mutationListeners[name] = onMutation;
      _mutationAllListeners[name] = onMutateAll;
    }
    for (final name in _contentListeners.keys.toList()) {
      if (live.contains(name)) continue;
      final channel = _chat.channelFor(name);
      channel?.messages.version.removeListener(_contentListeners[name]!);
      channel?.info.version.removeListener(_infoListeners[name]!);
      channel?.moderation.version.removeListener(_modListeners[name]!);
      channel?.threads.version.removeListener(_threadListeners[name]!);
      channel?.messages.mutations.removeListener(_mutationListeners[name]!);
      channel?.messages.mutations.removeAllListener(
        _mutationAllListeners[name]!,
      );
      _contentListeners.remove(name);
      _infoListeners.remove(name);
      _modListeners.remove(name);
      _threadListeners.remove(name);
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
    for (final entry in _threadListeners.entries) {
      _chat.channelFor(entry.key)?.threads.version.removeListener(entry.value);
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
    _threadListeners.clear();
    _mutationListeners.clear();
    _mutationAllListeners.clear();
  }

  // Appends channel buffer rows belonging to saved threads into the
  // persisted full log. Skips channels with no saved threads; dedup by id
  // keeps the per-event scan cheap and idempotent across history merges.
  void _onPanelDataChanged(String? changedChannel, {bool modView = true}) {
    if (_activePanel == OverlayPanel.closed) return;
    _threads.refreshOnData(changedChannel);
    // Mod View reads room modes and moderation state, not message rows.
    if (modView) _mod.refreshOnData(changedChannel);
  }

  // Cold-start pipe shared with account switch: the IRC connect. Emote
  // priming and post-auth refresh live in EmoteController.
  void _connectChat() {
    _chatConn.connect();
    _fakeChat.start();
  }

  void _onAuthChanged() {
    _mod.refreshOnData(null);
    final switched =
        _session.login?.toLowerCase() != _twitchAuth.login?.toLowerCase();
    if (switched) {
      // Account switched (or signed out): drop identity and account-scoped
      // chat state. The remaining resets are HomeScreen side effects.
      _session.clear();
      _chat.clearAccountScopedState();
      _pingManager.setAccount(null);
      // The block / mention caches are per-account: reset them so blocks are
      // re-fetched, the retroactive mention scan re-runs, and channels
      // re-resolve emotes with the new token.
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
    // Same pipe as cold start: connect now so the indicator flips at once.
    // The emote lifecycle resets/re-primes/refetches alongside instead of
    // gating the reconnect.
    _connectChat();
    unawaited(switched ? _emotes.onAccountChanged() : _emotes.onAuthChanged());
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

  /// Re-reads every persisted chat preference into its mirror field and
  /// applies the matching side effects. Runs at startup and whenever settings
  /// write through [PrefsStore].
  Future<void> _applyPrefs() async {
    final prefs = await Prefs.load();
    if (!mounted) return;
    _applyPrefsFrom(prefs);
  }

  /// [initial] runs from initState, before the first frame: fields only, no
  /// setState and no cache churn, so the first frame already has the saved
  /// chrome instead of animating over from defaults.
  void _applyPrefsFrom(Prefs prefs, {bool initial = false}) {
    final gifHeight = prefs.giphyInlineHeight.clamp(
      kGiphyInlineHeightMin,
      kGiphyInlineHeightMax,
    );
    final imageHeight = prefs.imageEmbedHeight.clamp(
      kImageEmbedHeightMin,
      kImageEmbedHeightMax,
    );
    final maxCapChanged =
        ref.read(maxMessagesPerChannelProvider) != prefs.maxMessagesPerChannel;
    final recentLimitChanged =
        ref.read(recentMessagesLimitProvider) != prefs.recentMessagesLimit;
    final sharedChatChanged =
        ref.read(sharedChatModeProvider) != prefs.sharedChatMode;
    final animateChanged = _animateGifs != prefs.animateGifs;
    // Only appearance prefs rebuild frozen spans; unchanged ones skip the
    // churn so unrelated settings writes stay cheap.
    final appearanceChanged =
        _showTimestamps != prefs.showTimestamps ||
        _timestampFormat != prefs.timestampFormat ||
        _chatFontSize != prefs.chatFontSize ||
        _highlightOpacity != prefs.highlightOpacity ||
        _checkeredMessages != prefs.checkeredMessages ||
        _lineSeparator != prefs.lineSeparator ||
        _showNamePaints != prefs.seventvNamePaints ||
        _showGifs != prefs.giphyInlineEnabled ||
        _gifHeight != gifHeight ||
        animateChanged ||
        _messageBuilder.ffzEffects != prefs.ffzEffects ||
        _messageBuilder.bttvModifiers != prefs.bttvModifiers ||
        _showImages != prefs.imageEmbedEnabled ||
        _imageHeight != imageHeight ||
        _messageBuilder.doubleTapNameCopy != prefs.doubleTapNameCopy;
    // Every field apply() writes; any change keeps the rebuild.
    final fieldsChanged =
        appearanceChanged ||
        maxCapChanged ||
        recentLimitChanged ||
        sharedChatChanged ||
        _replyToRoot != prefs.replyToThreadRoot ||
        _preferEmotesFirst != prefs.preferEmotesFirst ||
        _fastSnap != prefs.fastChannelSnap ||
        _liquidGlass != prefs.liquidGlass ||
        _showInput != prefs.showInput;

    void apply() {
      // Providers cannot change during initState; none of these touch the
      // chrome, so the async pass sets them a beat later.
      if (!initial) {
        ref
            .read(maxMessagesPerChannelProvider.notifier)
            .set(prefs.maxMessagesPerChannel);
        ref
            .read(recentMessagesLimitProvider.notifier)
            .set(prefs.recentMessagesLimit);
        ref.read(sharedChatModeProvider.notifier).set(prefs.sharedChatMode);
      }
      _replyToRoot = prefs.replyToThreadRoot;
      _preferEmotesFirst = prefs.preferEmotesFirst;
      _showTimestamps = prefs.showTimestamps;
      _timestampFormat = prefs.timestampFormat;
      _chatFontSize = prefs.chatFontSize;
      _highlightOpacity = prefs.highlightOpacity;
      _checkeredMessages = prefs.checkeredMessages;
      _lineSeparator = prefs.lineSeparator;
      _fastSnap = prefs.fastChannelSnap;
      _liquidGlass = prefs.liquidGlass;
      _showNamePaints = prefs.seventvNamePaints;
      _showGifs = prefs.giphyInlineEnabled;
      _gifHeight = gifHeight;
      _showImages = prefs.imageEmbedEnabled;
      _imageHeight = imageHeight;
      _showInput = prefs.showInput;
      _animateGifs = prefs.animateGifs;
      _messageBuilder.showGifs = _showGifs;
      _messageBuilder.gifHeight = _gifHeight;
      _messageBuilder.showImages = _showImages;
      _messageBuilder.imageHeight = _imageHeight;
      _messageBuilder.animateGifs = _animateGifs;
      _messageBuilder.ffzEffects = prefs.ffzEffects;
      _messageBuilder.bttvModifiers = prefs.bttvModifiers;
      _messageBuilder.doubleTapNameCopy = prefs.doubleTapNameCopy;
    }

    if (initial) {
      apply();
    } else {
      apply();
      if (fieldsChanged) setState(() {});
    }
    _sevenTvPaintService.enabled = _showNamePaints;
    if (animateChanged) EmoteUrlProvider.applyGifsEnabled(_animateGifs);
    if (initial) return;
    if (maxCapChanged) {
      // Drop a lowering cap without waiting for the next incoming message.
      for (final channel in List.of(_chat.names)) {
        _channelManager.truncateChannel(channel);
        _chat.channelFor(channel)?.info.touch();
      }
    }
    if (appearanceChanged || sharedChatChanged) {
      _tileCache.clear();
      for (final channel in List.of(_chat.names)) {
        _chat.channelFor(channel)?.info.touch();
      }
    }
  }

  void _onPrefsChanged() => unawaited(_applyPrefs());

  // The emote sheet lives in this route's tree, so a sheet, menu or page
  // pushed on top would otherwise open with it still up underneath.
  @override
  void didPushNext() {
    if (_panelManager.emoteSheetOpen) {
      unawaited(_panelManager.closeEmoteSheet());
    }
  }

  // A covering route hands focus back on pop, and Android sometimes ignores
  // that restored IME show, leaving the field focused with no keyboard.
  // Settings drops focus before it opens, so it never comes back here.
  @override
  void didPopNext() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_composer.hasFocus) return;
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
    });
  }

  @override
  void dispose() {
    widget.routeObserver?.unsubscribe(this);
    _fakeChat.dispose();
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
    _uploadController.dispose();
    _networkBusy.dispose();
    _linkWhitelist.removeListener(_onLinkWhitelistChanged);
    PrefsStore.instance.removeListener(_onPrefsChanged);
    _streamPlayer.removeListener(_stream.onStreamPlayerChanged);
    _streamPlayer.removeListener(_syncSystemUiMode);
    if (_pip.onPipChanged == _pipChangedHandler) {
      _pip.onPipChanged = null;
    }
    if (_pip.onPipAction == _pipActionHandler) {
      _pip.onPipAction = null;
    }
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
    _channelManager.dispose();
    _session.version.removeListener(_onSessionApplied);
    _notificationTapSub?.cancel();
    if (_immersive) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  void _toggleFullscreen() {
    setState(() => _isFullscreen = !_isFullscreen);
    _syncSystemUiMode();
  }

  /// Immersive hides the system bars in fullscreen and in landscape theater
  /// mode. The theater flag persists through portrait, where the stacked
  /// layout renders, so only the landscape theater layout counts.
  void _syncSystemUiMode({bool force = false}) {
    if (!mounted) return;
    final immersive =
        _isFullscreen ||
        (_streamPlayer.isTheaterMode &&
            MediaQuery.maybeOrientationOf(context) == Orientation.landscape);
    if (immersive == _immersive && !force) return;
    _immersive = immersive;
    SystemChrome.setEnabledSystemUIMode(
      immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  void _toggleInputVisibility() => setShowInput(!_showInput);

  void _copyMessageToClipboard(TwitchMessage msg) {
    Clipboard.setData(ClipboardData(text: copyableChatText(msg.text)));
    _chatNotice.show(
      context.l10n.messageCopied,
      actionLabel: context.l10n.paste,
      onAction: _pasteFromClipboard,
    );
  }

  void _copyEmail(String email) {
    Clipboard.setData(ClipboardData(text: email));
    if (!mounted) return;
    _chatNotice.show(context.l10n.copiedValue(email));
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
          onBackgroundServiceChanged: _setBackgroundService,
          onMentionPushChanged: _setMentionPush,
          onWhisperNotifyChanged: _setWhisperNotify,
          onRecentMessagesModeChanged: _channelManager.setRecentMessagesMode,
          onEmoteTierChanged: _emotes.setManualTier,
          onEmoteCacheMaxChanged: _emotes.applyCacheCap,
          onEmoteAutoModeChanged: _emotes.applyAutoMode,
          onNukeEmotes: _nukeEmotes,
          mobileNotifier: _isMobile,
          channelNotifier: _channelNotifier,
          onLeaveChannel: _channelManager.removeChannel,
          onAddChannel: _channelManager.addChannel,
          onReorderChannels: _channelManager.reorderChannels,
          onRenameChannel: (from, to) =>
              unawaited(_channelManager.renameChannel(from, to)),
          analyticsService: _analytics,
          channels: _chat.names,
          ttsController: _ttsController,
          emoteManager: _emoteManager,
          onPipEnabledChanged: _streamPlayer.setPipEnabled,
          onTestWidgetsChanged: _broadcastWidgets.setTestWidgets,
          fakeChat: _fakeChat,
          fakeFillCount: () => ref.read(maxMessagesPerChannelProvider),
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

  ScrollController _scrollCtrl(String channel) {
    return _scrollControllers.putIfAbsent(channel, () => ScrollController());
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

  void _onEmoteSelected(Emote emote) {
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

  @override
  Widget build(BuildContext context) {
    // Provider-owned shared objects observed as Riverpod state. These replace
    // the manual addListener/removeListener pairs; ref.listen auto-cancels.
    // Rendered rows ignore emote changes (tokens bake at ingest); typing,
    // picker, and menus read the live mixer themselves, so no fan-out here.
    ref.listen(twitchAuthTickProvider, (_, _) => _onAuthChanged());
    ref.listen(connectivityTickProvider, (_, _) => _onConnectivityChanged());
    ref.listen(connectionStateProvider, (_, _) => _onConnectionChanged());
    ref.listen(
      reconnectedTickProvider,
      (_, _) => unawaited(_emotes.refreshSubEmoteOwners()),
    );
    // Reply card floats above the composer. Hidden while search or the terms
    // box borrows the input, and while the composer is disabled.
    final glass = glassEnabled(context, _liquidGlass);
    // Watched, not read: the send path clears the reply without a setState.
    final replyMsg = ref.watch(replyToProvider);
    final replyHeader =
        _showInput &&
            replyMsg != null &&
            _composer.enabled &&
            !_search.open &&
            !_mod.termsInputActive
        ? ReplyHeader(message: replyMsg, onDismiss: _composer.clearReply)
        : null;
    // Focus stays out of canPop: the IME owns back while it is up and
    // ChatBody unfocuses on close. Claiming back would outrank the IME's
    // callback after any rebuild and skip its predictive dip.
    return PopScope(
      canPop:
          !_isFullscreen &&
          !_streamPlayer.isTheaterMode &&
          _activePanel == OverlayPanel.closed &&
          !_emoteSheetOpen &&
          !_search.open,
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
        }
      },
      child: Scaffold(
        // Stock resize path: the Scaffold shrinks the body with the
        // keyboard, replaying the system ticks directly. No manual lift and
        // no second animator: Dart curves of a different duration only cross
        // the system motion (behind-ahead-behind). ChatBody reads the
        // keyboard itself, so this screen never rebuilds per keyboard tick.
        resizeToAvoidBottomInset: true,
        body: ListenableBuilder(
          listenable: _streamPlayer,
          builder: (_, _) => ChatBody(
            emoteMaxFraction: _emoteMaxFraction,
            // A dismissed keyboard leaves the field focused, which keeps
            // the back guard and focus styling stuck; drop it once the
            // close settles (ChatBody delays the call past the animation).
            onKeyboardDismissed: _composer.unfocus,
            // System PiP collapses the whole body to video-only; ChatBody
            // drops composer/panels/notice so the window shows the stream.
            isInPip: _streamPlayer.isInPip,
            // Keyboard room only decides whether a stacked player hides.
            bodyReadsKeyboard: _streamPlayer.currentChannel != null,
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
                    liquidGlass: glass,
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
                images: _emoteLookupSource.images,
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
                    transparent: glass,
                  )
                : null,
            notice: ChatNoticeBar(controller: _chatNotice),
            replyHeader: replyHeader,
            liquidGlass: glass,
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
      key: const ValueKey('emote_picker'),
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
