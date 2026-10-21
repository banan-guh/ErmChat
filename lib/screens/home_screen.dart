import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

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
import '../util/chrome_theme.dart';
import '../services/app_updates.dart';
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
import '../util/prefs.dart';
import '../util/prefs_store.dart';
import '../util/settings.dart';
import '../screens/intro_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../widgets/panel_manager.dart';
import '../widgets/glass_chrome.dart';
import '../widgets/whats_new_sheet.dart';
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
import '../chrome/layout_editor.dart';
import '../chrome/stream_layout.dart';
import '../widgets/dialogs.dart' show confirmDialog;
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
import '../widgets/mod_view/dialogs.dart' show showModError;
import '../services/fake_chat_feed.dart';
import '../services/foreground_task.dart';
import '../widgets/design_tokens.dart';

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
  VoidCallback? _removeFilterListener;

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
  );
  Map<String, String> _channelUserIds() => ref.read(channelUserIdsProvider)();

  ModActions get _modActions => ref.read(modActionsProvider);
  CommandHandler get _commandHandler => ref.read(commandHandlerProvider);
  late final MediaUploadController _uploadController = MediaUploadController(
    onNotice: _chatNotice.show,
    onPaste: _pasteFromClipboard,
  );

  NotificationService get _notificationService =>
      ref.read(notificationServiceProvider);
  StreamSubscription<String>? _notificationTapSub;
  StreamSubscription<String>? _apnsTapSub;
  bool _backgroundService = false;
  bool _whisperNotify = true;

  /// The introduction shows once per install, on phones only. Home stays
  /// blank until it covers the screen. The app root loads prefs first.
  bool _introPending =
      (Platform.isAndroid || Platform.isIOS) &&
      !(Prefs.loaded?.welcomeSeen ?? true);

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

  // Held so dispose can unregister paste without touching ref.
  ChatNoticeController? _pasteHost;

  late final ChatUiSignals _signals = ref.read(chatUiSignalsProvider);

  final _signalUnsubs = <void Function()>[];

  BroadcastWidgets get _broadcastWidgets => ref.read(broadcastWidgetsProvider);

  // Settings the shell reads. Composer-owned input state (text, reply,
  // suggestions, cooldown) lives in _composer.
  bool get _replyToRoot => Settings.replyToThreadRoot.value;
  bool get _preferEmotesFirst => Settings.preferEmotesFirst.value;
  bool get _sendSwipeMenu => Settings.sendSwipeMenu.value;
  int get _spamIntervalMs => Settings.spamIntervalMs.value;
  int get _spamIntervalModMs => Settings.spamIntervalModMs.value;
  bool get _showTimestamps => Settings.showTimestamps.value;
  String get _timestampFormat => Settings.timestampFormat.value;
  double get _chatFontSize => Settings.chatFontSize.value;
  double get _highlightOpacity => Settings.highlightOpacity.value;
  bool get _checkeredMessages => Settings.checkeredMessages.value;
  bool get _lineSeparator => Settings.lineSeparator.value;
  bool get _fastSnap => Settings.fastChannelSnap.value;
  bool get _liquidGlass => Settings.liquidGlass.value;
  bool get _showNamePaints => Settings.sevenTvCosmetics.value;

  /// Whether the chat input box + status row is shown.
  bool get _showInput => Settings.showInput.value;

  /// Settings baked into cached message spans; a change rebuilds them.
  late final _spanSettings = Listenable.merge([
    Settings.showTimestamps,
    Settings.timestampFormat,
    Settings.chatFontSize,
    Settings.chatFontWeight,
    Settings.highlightOpacity,
    Settings.checkeredMessages,
    Settings.lineSeparator,
    Settings.sevenTvCosmetics,
    Settings.giphyInlineEnabled,
    Settings.giphyInlineHeight,
    Settings.imageEmbedEnabled,
    Settings.imageEmbedHeight,
    Settings.animateGifs,
    Settings.ffzEffects,
    Settings.bttvModifiers,
    Settings.doubleTapNameCopy,
    Settings.sharedChatMode,
  ]);

  /// Settings the shell builds from, beyond [_spanSettings].
  late final _shellSettings = Listenable.merge([
    Settings.replyToThreadRoot,
    Settings.preferEmotesFirst,
    Settings.sendSwipeMenu,
    Settings.spamIntervalMs,
    Settings.spamIntervalModMs,
    Settings.fastChannelSnap,
    Settings.liquidGlass,
    Settings.showInput,
    Settings.chromeTheme,
    Settings.customChromeThemes,
  ]);

  late final _sevenTvSettings = Listenable.merge([
    Settings.sevenTvCosmetics,
    Settings.emoteProvidersDisabled,
  ]);
  // True while a manual emote refresh (Reload emotes) is in flight. The
  // connect/reconnect + per-channel-join loading is read live from
  // [_chatLoading] (driven by ChatConnectionManager.connectionStateNotifier),
  // so this only covers emote work that doesn't move the connection phase.
  final ValueNotifier<bool> _networkBusy = ValueNotifier(false);
  // Kept so dispose unbinds only the handlers this state installed.
  late final PipService _pip;
  ValueChanged<bool>? _pipChangedHandler;
  ValueChanged<String>? _pipActionHandler;
  Color? _lastSurface;

  /// The saved chrome theme, decoded once per change.
  ChromeThemeSpec _chromeTheme = ChromeTheme.ermchat.spec;

  /// The draft layout while edit mode is on; the chrome renders from it.
  LayoutEditController? _layoutEdit;

  /// Settings asked for edit mode; it starts once settings has closed.
  bool _editLayoutPending = false;

  /// Hidden-chrome mode: drops the ErmChat header (title, join, mentions,
  /// overflow) and the channel tab bar so the chat fills the screen. Transient
  /// (session-only); the dropdown arrow stays visible to toggle it back.
  bool _isFullscreen = false;

  /// Mirror of the live system UI mode, so redundant SystemChrome calls are
  /// skipped while a forced re-apply (app resume) stays explicit.
  _SystemBars _bars = _SystemBars.all;

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
    setReplyTo: (value) => ref.read(replyToProvider.notifier).set(value),
    getSelectedChannel: () => ref.read(selectedChannelProvider),
    isWhispersTabActive: () => _mentions.isWhispersTabActive,
    whisperTarget: () => _mentions.whisperTarget,
    activePanel: () => _activePanel,
    threadsTabIndex: () => _threads.effectiveThreadsTab,
    openThreadRoot: () => _panelManager.openThreadRoot,
    replyToRoot: () => _replyToRoot,
    preferEmotesFirst: () => _preferEmotesFirst,
    sendSwipeMenu: () => _sendSwipeMenu,
    spamIntervalMs: () => _spamIntervalMs,
    spamIntervalModMs: () => _spamIntervalModMs,
    computeThreadMessages: () => _threads.computeThreadMessages(),
    channelChatReady: () => _channelChatReady,
    replayingVod: () => _streamPlayer.replaysVod(selectedChannel),
    showNotice: showNotice,
    strings: () => context.l10n,
    emoteSheetOpen: () => _emoteSheetOpen && !_panelManager.emoteSheetClosing,
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
    canModerate: (msg) =>
        msg.channel != null && _chatConn.isModerationActive(msg.channel!),
    pinMessage: (context, msg) async {
      final result = await _modActions.pinMessage(
        _twitchAuth,
        msg.channel!,
        msg.messageId!,
      );
      if (context.mounted) showModError(context, result);
    },
    deleteMessage: (context, msg) async {
      final result = await _modActions.deleteMessage(
        _twitchAuth,
        msg.channel!,
        msg.messageId!,
      );
      if (context.mounted) showModError(context, result);
    },
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
    sharedChatMode: () => Settings.sharedChatMode.value,
    namePaintService: () => _showNamePaints ? _sevenTvPaintService : null,
    copyMessage: _copyMessageToClipboard,
    strings: () => context.l10n,
    archiveStore: ref.read(archiveProvider)?.store,
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
    sharedChatMode: () => Settings.sharedChatMode.value,
    copyMessage: _copyMessageToClipboard,
    namePaintService: () => _showNamePaints ? _sevenTvPaintService : null,
    pingManager: _pingManager,
    archiveReader: ref.read(archiveProvider)?.reader,
    emotesVersion: _emotesVersion,
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
    themeSpec: () => _layoutEdit?.draft ?? _chromeTheme,
    layoutEdit: () => _layoutEdit,
    editLayout: _startLayoutEdit,
  );

  late final ChannelPanels _channels = ChannelPanels(
    chat: _chat,
    tileCache: _tileCache,
    messageBuilder: _messageBuilder,
    linkWhitelist: _linkWhitelist,
    twitchAuth: _twitchAuth,
    twitchApi: _twitchApi,
    streamPlayer: _streamPlayer,
    paintService: _sevenTvPaintService,
    selectedTabIndex: _selectedTabIndex,
    userSheets: _userSheets,
    menus: _menus,
    threads: _threads,
    search: _search,
    composer: _composer,
    broadcastWidgets: _broadcastWidgets,
    unpinFor: (channel) => _chatConn.isModerationActive(channel)
        ? (pin) =>
              _modActions.unpinMessage(_twitchAuth, pin.channel, pin.messageId)
        : null,
    homeAppBar: _chrome,
    selectedChannel: () => ref.read(selectedChannelProvider),
    showTimestamps: () => _showTimestamps,
    timestampFormat: () => _timestampFormat,
    chatFontSize: () => _chatFontSize,
    checkeredMessages: () => _checkeredMessages,
    highlightOpacity: () => _highlightOpacity,
    lineSeparator: () => _lineSeparator,
    sharedChatMode: () => Settings.sharedChatMode.value,
    showNamePaints: () => _showNamePaints,
    isFullscreen: () => _isFullscreen,
    fastSnap: () => _fastSnap,
    commitChannelSelection: _commitChannelSelection,
    copyMessage: _copyMessageToClipboard,
    messageNotifier: _messageNotifier,
    atBottomNotifier: _atBottomNotifier,
    scrollCtrl: _scrollCtrl,
    archiveReader: ref.read(archiveProvider)?.reader,
    archive: ref.read(archiveProvider),
    emotesVersion: _emotesVersion,
  );

  /// Emote catalog version for history pages; deltas leave it alone.
  final _emotesVersion = ValueNotifier<int>(0);

  late final StreamPanels _stream = StreamPanels(
    streamPlayer: _streamPlayer,
    pipService: _pipService,
    chat: _chat,
    channelsPending: () => _channelManager.session.channelsPending,
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

  void setShowInput(bool value) => unawaited(Settings.showInput.set(value));

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

  void _disposeChannelNotifiers(String channel) {
    _scrollControllers.remove(channel)?.dispose();
    _channels.forgetChannel(channel);
  }

  void _forgetAtBottomNotifier(String channel) =>
      _atBottomNotifiers.remove(channel)?.dispose();

  @override
  void initState() {
    super.initState();
    _pasteHost = _chatNotice..paste = _pasteFromClipboard;
    unawaited(_ttsController.init());
    unawaited(AppLog.I.init());
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
    // Main binds settings before the home screen, so the first frame reads
    // them. A later bind (tests) notifies whatever it changed.
    _applySettings();
    _spanSettings.addListener(_onSpanSettings);
    _shellSettings.addListener(_onShellSettings);
    _sevenTvSettings.addListener(_applySevenTvSettings);
    Settings.animateGifs.addListener(_applyAnimateGifs);
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
    _streamPlayer.vodPlayback.addListener(_onVodReplay);
    _streamPlayer.vodChatLive.addListener(_onVodReplay);
    // Launching in landscape gets no metrics change, so sync once up front.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncSystemUiMode());
    _linkWhitelist.addListener(_retile);
    _removeFilterListener = _chat.filter.changed.add(_retile);
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
    _reportingStalls = debugLogEnabled;
    if (_reportingStalls) {
      WidgetsBinding.instance.addTimingsCallback(_reportStalls);
    }
    _predictiveBackHandler = PanelPredictiveBackHandler(
      // A modal route above the home screen takes the back gesture itself.
      isPanelOpen: () =>
          (_activePanel != OverlayPanel.closed || _emoteSheetOpen) &&
          (!mounted || (ModalRoute.of(context)?.isCurrent ?? true)),
      onProgress: (progress) {
        _panelScaleCtrl.value = 1.0 - 0.10 * progress;
      },
      onCancel: () {
        _panelScaleCtrl.animateTo(1.0);
      },
      onCommit: _handlePanelBack,
    );
    WidgetsBinding.instance.addObserver(_predictiveBackHandler);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowIntro();
      unawaited(_runAppUpdates());
    });
  }

  /// What's new after an update, then the daily store version check. A
  /// first install shows neither: it has no previous version.
  Future<void> _runAppUpdates() async {
    final info = await PackageInfo.fromPlatform();
    final updates = ref.read(appUpdatesProvider);
    final from = await updates.takeWhatsNew(info.version);
    if (from != null) {
      final notes = await bundledNotes(info.version);
      if (!mounted) return;
      if (notes.isNotEmpty) {
        unawaited(
          showWhatsNewSheet(
            context,
            title: context.l10n.whatsNewTitle,
            notes: notes,
            more: from.isEmpty ? null : updates.missedNotes(from, info.version),
          ),
        );
      }
    }
    final source = updateSourceFor(info.installerStore, ios: Platform.isIOS);
    final update = await updates.checkForUpdate(info.version, source);
    if (update == null || !mounted) return;
    _chatNotice.show(
      context.l10n.updateAvailableSnack(update.version),
      actionLabel: context.l10n.whatsNewAction,
      onAction: () => showUpdateSheet(
        context,
        updates,
        update,
        source,
        currentVersion: info.version,
      ),
      duration: const Duration(seconds: 8),
      queue: true,
    );
  }

  /// Opens the introduction in place, with no entrance, so the app starts
  /// on it. It fades out to home when done.
  void _maybeShowIntro() {
    if (!_introPending || !mounted) return;
    Navigator.push(
      context,
      PageRouteBuilder<void>(
        fullscreenDialog: true,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Motion.normal,
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
        pageBuilder: (_, _, _) => IntroScreen(
          twitchAuth: _twitchAuth,
          onJoinChannel: (c) => _channelManager.addChannel(c, focus: false),
          mentionPush: ref.read(mentionPushProvider),
          onMentionPushChanged: _setMentionPush,
        ),
      ),
    );
    setState(() => _introPending = false);
    unawaited(Prefs.load().then((p) => p.setWelcomeSeen(true)));
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
    _initApnsPush(mentionPush);
    if (!Platform.isAndroid) return;
    if (backgroundService) {
      initForegroundService(mounted ? context.l10n : null);
    }
    if (mentionPush || whisperNotify) {
      _initNotificationInfra();
    }
  }

  /// iOS push through the proxy: taps open the channel, and the proxy
  /// learns whether to push. No-ops elsewhere.
  void _initApnsPush(bool push) {
    final apns = ref.read(apnsPushProvider);
    if (!apns.active) return;
    _apnsTapSub ??= apns.onTap.listen(_onNotificationTap);
    unawaited(
      apns.takeLaunchChannel().then((channel) {
        if (channel != null && mounted) _navigateToChannel(channel);
      }),
    );
    unawaited(apns.sync(push: push));
  }

  void _initNotificationInfra() {
    _notificationTapSub ??= _notificationService.onNotificationTap.listen(
      _onNotificationTap,
    );
    unawaited(
      _notificationService.init().then((_) {
        final pendingChannel = _notificationService.takePendingLaunchChannel();
        if (pendingChannel != null && mounted) {
          _navigateToChannel(pendingChannel);
        }
      }),
    );
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
        startForegroundService(List.of(_chat.names), context.l10n);
      }
    } else {
      stopForegroundService();
    }
  }

  void _setMentionPush(bool value) {
    if (ref.read(mentionPushProvider) == value) return;
    ref.read(mentionPushProvider.notifier).set(value);
    setState(() {});
    unawaited(ref.read(apnsPushProvider).sync(push: value));
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

  bool _reportingStalls = false;

  /// Reports each frame of [JankLog.stallMs] or more with what led up to it.
  void _reportStalls(List<FrameTiming> timings) {
    for (final t in timings) {
      if (t.totalSpan.inMilliseconds < JankLog.stallMs) continue;
      final vsync = t.timestampInMicroseconds(FramePhase.vsyncStart);
      JankLog.stall(
        startUs: vsync,
        endUs: t.timestampInMicroseconds(FramePhase.rasterFinish),
        waitMs:
            (t.timestampInMicroseconds(FramePhase.buildStart) - vsync) ~/ 1000,
        buildMs: t.buildDuration.inMilliseconds,
        rasterMs: t.rasterDuration.inMilliseconds,
        extra:
            ' queue=${(t.timestampInMicroseconds(FramePhase.rasterStart) - t.timestampInMicroseconds(FramePhase.buildFinish)) ~/ 1000}ms'
            ' images=${PaintingBinding.instance.imageCache.currentSize}',
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    JankLog.note('app ${state.name}');
    if (state == AppLifecycleState.paused) {
      _releaseDecodedImages();
      // A paused app may be killed without warning; save stats, threads,
      // the unsealed chat history and the app log.
      unawaited(_analytics.flush());
      unawaited(_threads.persistSaved());
      final archive = ref.read(archiveProvider);
      if (archive != null) unawaited(archive.writer.flush());
      unawaited(AppLog.I.flush());
    }
    // Inactive is still on screen (notification shade, system dialog), so
    // only a hidden app counts as backgrounded for notifications.
    final backgrounded =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
    ref.read(backgroundedProvider.notifier).set(backgrounded);
    if (Platform.isAndroid) {
      if (state == AppLifecycleState.paused) {
        if (_backgroundService) {
          startForegroundService(List.of(_chat.names), context.l10n);
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
    // A switch mid-fetch re-runs this for the new account; the old list and
    // its ready flag must not land in the new account's chat.
    if (!mounted || _twitchAuth.userId != userId) return;
    ref.read(blockedLoginsProvider.notifier).addAll(blocked);
    ref.read(chatReadyProvider.notifier).set(true);
    _channelManager.loadChannels();
    setState(() {});
  }

  /// Re-renders visible tiles after the link whitelist or the chat filter
  /// changes.
  void _retile() {
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
    DataUsageStats.I.setMobile(isMobile);
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
    _chatNotice.show(message);
  }

  // The grant predates a scope added since: nudge a re-login once per stale
  // spell, or the account's own emotes silently stop loading.
  bool _scopeNoticeShown = false;

  void _syncScopeNotice() {
    if (!_twitchAuth.scopeStale) {
      _scopeNoticeShown = false;
      return;
    }
    if (_scopeNoticeShown || !mounted) return;
    _scopeNoticeShown = true;
    _chatNotice.show(
      context.l10n.newPermissionsNotice,
      actionLabel: context.l10n.logInAgain,
      onAction: () => unawaited(_openSettings()),
      duration: const Duration(seconds: 8),
      queue: true,
    );
  }

  void _showLoginExpired() {
    if (!mounted) return;
    _chatNotice.show(
      context.l10n.loginExpiredReconnect,
      actionLabel: context.l10n.openAccount,
      onAction: () => unawaited(_openSettings()),
    );
  }

  // ChatUiSignals forwarding: the pipeline pushes, the shell routes each
  // signal to its existing UI owner. Dispose detaches every subscription.
  void _subscribeSignals() {
    final signals = _signals;
    final emoteSignals = ref.read(emoteSignalsProvider);
    _signalUnsubs.addAll([
      signals.focusComposer.add(_onFocusComposerSignal),
      signals.banner.add(_showBanner),
      signals.loginExpired.add(_showLoginExpired),
      signals.whisper.add(_mentions.onWhisper),
      signals.whisperSystem.add(
        (s) => _mentions.addWhisperSystemMessage(s.channel, s.text),
      ),
      signals.whisperSent.add(
        (s) => _mentions.onWhisperSent(s.target, s.message),
      ),
      emoteSignals.snack.add(_chatNotice.show),
      emoteSignals.busy.add((value) {
        _networkBusy.value = value;
        EmoteUrlProvider.loadBackoff.clear();
      }),
    ]);
  }

  void _onFocusComposerSignal() => _composer.focus();

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
    _syncScopeNotice();
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
      ref.read(replyToProvider.notifier).set(null);
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
      if (!_chatConn.isChannelChatReady(channel) &&
          !_chatConn.isChannelJoinFailed(channel)) {
        return true;
      }
    }
    return false;
  }

  // Connection phase changes can flip moderation/room state; refresh the
  // open mod panel so gating and room modes do not go stale.
  void _onConnectionChanged() {
    if (_activePanel == OverlayPanel.modView) _mod.refreshOnData(null);
  }

  /// Applies every setting the shell pushes into owners, without a rebuild.
  void _applySettings() {
    _chromeTheme = Prefs.loaded?.chromeTheme ?? _chromeTheme;
    _syncMessageBuilder();
    _applySevenTvSettings();
    _applyAnimateGifs();
  }

  void _syncMessageBuilder() {
    _messageBuilder
      ..showGifs = Settings.giphyInlineEnabled.value
      ..gifHeight = Settings.giphyInlineHeight.value
      ..showImages = Settings.imageEmbedEnabled.value
      ..imageHeight = Settings.imageEmbedHeight.value
      ..animateGifs = Settings.animateGifs.value
      ..ffzEffects = Settings.ffzEffects.value
      ..bttvModifiers = Settings.bttvModifiers.value
      ..doubleTapNameCopy = Settings.doubleTapNameCopy.value
      ..fontWeight = FontWeight.values.firstWhere(
        (w) => w.value == Settings.chatFontWeight.value,
        orElse: () => FontWeight.w400,
      );
  }

  void _applySevenTvSettings() {
    _sevenTvPaintService.enabled = _showNamePaints;
    _thirdPartyBadgeService.showSevenTv = _showNamePaints;
    final disabled = Settings.emoteProvidersDisabled.value ?? const [];
    _chatConn.applySevenTvSettings(
      emotes: !disabled.contains(EmoteType.sevenTv.name),
      cosmetics: _showNamePaints,
    );
  }

  void _applyAnimateGifs() =>
      EmoteUrlProvider.applyGifsEnabled(Settings.animateGifs.value);

  /// Rebuilds frozen spans and tiles from the changed display settings.
  void _onSpanSettings() {
    _syncMessageBuilder();
    _tileCache.clear();
    for (final channel in List.of(_chat.names)) {
      _chat.channelFor(channel)?.info.touch();
    }
    setState(() {});
  }

  void _onShellSettings() {
    setState(() => _chromeTheme = Prefs.loaded?.chromeTheme ?? _chromeTheme);
  }

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
    _pasteHost?.paste = null;
    _layoutEdit?.dispose();
    widget.routeObserver?.unsubscribe(this);
    _fakeChat.dispose();
    _isMobile.dispose();
    _emotesVersion.dispose();
    for (final unsubscribe in _signalUnsubs) {
      unsubscribe();
    }
    _signalUnsubs.clear();
    WidgetsBinding.instance.removeObserver(this);
    if (_reportingStalls) {
      WidgetsBinding.instance.removeTimingsCallback(_reportStalls);
    }
    WidgetsBinding.instance.removeObserver(_predictiveBackHandler);
    _panelManager.dispose();
    _composer.dispose();
    _uploadController.dispose();
    _networkBusy.dispose();
    _linkWhitelist.removeListener(_retile);
    _removeFilterListener?.call();
    _spanSettings.removeListener(_onSpanSettings);
    _shellSettings.removeListener(_onShellSettings);
    _sevenTvSettings.removeListener(_applySevenTvSettings);
    Settings.animateGifs.removeListener(_applyAnimateGifs);
    _streamPlayer.removeListener(_stream.onStreamPlayerChanged);
    _streamPlayer.removeListener(_syncSystemUiMode);
    _streamPlayer.vodPlayback.removeListener(_onVodReplay);
    _streamPlayer.vodChatLive.removeListener(_onVodReplay);
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
    _apnsTapSub?.cancel();
    if (_bars != _SystemBars.all) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  // Tiny phones (iPhone 8 and SE class, under 700pt on the long side; big
  // phones can be as short in landscape, so height alone misleads) enter
  // fullscreen in landscape, hiding the top bar; the floating menu's
  // fullscreen toggle brings it back. Leaving restores the user's own
  // setting. Null while not in tiny landscape.
  bool? _fullscreenBeforeTiny;

  void _syncTinyLandscape() {
    final size = MediaQuery.maybeSizeOf(context);
    final tiny =
        MediaQuery.maybeOrientationOf(context) == Orientation.landscape &&
        size != null &&
        size.longestSide < 700;
    if (tiny && _fullscreenBeforeTiny == null) {
      _fullscreenBeforeTiny = _isFullscreen;
      if (!_isFullscreen) setState(() => _isFullscreen = true);
    } else if (!tiny && _fullscreenBeforeTiny != null) {
      final before = _fullscreenBeforeTiny!;
      _fullscreenBeforeTiny = null;
      if (_isFullscreen != before) setState(() => _isFullscreen = before);
    }
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
    _syncTinyLandscape();
    // Phones in landscape go fullscreen on their own: every row of height
    // counts. Tablets keep the system bars, since landscape is their default.
    final size = MediaQuery.maybeSizeOf(context);
    final landscape =
        MediaQuery.maybeOrientationOf(context) == Orientation.landscape;
    final phoneLandscape = landscape && size != null && size.shortestSide < 600;
    final immersive =
        _isFullscreen ||
        phoneLandscape ||
        (_streamPlayer.isTheaterMode && landscape);
    // A stream stacked on top (portrait, under the split width) runs to the
    // screen's top edge, so the status bar steps aside instead of covering it.
    final stackedStream =
        _streamPlayer.currentChannel != null &&
        !_streamPlayer.isInPip &&
        !landscape &&
        size != null &&
        size.width < 600;
    final bars = immersive
        ? _SystemBars.none
        : stackedStream
        ? _SystemBars.noStatus
        : _SystemBars.all;
    if (bars == _bars && !force) return;
    _bars = bars;
    switch (bars) {
      case _SystemBars.none:
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      case _SystemBars.noStatus:
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: const [SystemUiOverlay.bottom],
        );
      case _SystemBars.all:
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _toggleInputVisibility() => setShowInput(!_showInput);

  bool _replayingVod = false;

  /// Rebuilds the composer when the selected page starts or stops replaying
  /// a VOD. Playback ticks every second, so it skips unchanged states.
  void _onVodReplay() {
    final replaying = _streamPlayer.replaysVod(selectedChannel);
    if (replaying == _replayingVod || !mounted) return;
    setState(() => _replayingVod = replaying);
  }

  /// The island footer [channel] shows, for its page's pre-placed clearance.
  double _statusHeightFor(String channel) =>
      composerStatusHeight(context, _composer, channel, modeRow: _modeRow);

  /// Whether room modes may ride the island's button row: the row shows.
  bool get _modeRow =>
      (_chat.names.isNotEmpty || _channelManager.session.channelsPending) &&
      _chromeTheme.hasRow &&
      _showInput;

  void _copyMessageToClipboard(TwitchMessage msg) {
    Clipboard.setData(ClipboardData(text: copyableChatText(msg.text)));
    _chatNotice.show(
      context.l10n.messageCopied,
      actionLabel: context.l10n.paste,
      onAction: _chatNotice.paste,
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

  /// Puts the chrome into edit mode on a draft of the current layout. It
  /// needs channels: the strip and the island row only exist with them.
  void _startLayoutEdit() {
    if (!mounted || _layoutEdit != null) return;
    if (_chat.names.isEmpty) {
      AppSnack.show(context, context.l10n.layoutJoinFirst);
      return;
    }
    _composer.unfocus();
    if (_isFullscreen) _toggleFullscreen();
    final edit = LayoutEditController(_chromeTheme);
    edit.addListener(markDirty);
    setState(() => _layoutEdit = edit);
  }

  void _endLayoutEdit() {
    final edit = _layoutEdit;
    if (edit == null) return;
    setState(() => _layoutEdit = null);
    // The tray listens until this frame rebuilds without it.
    WidgetsBinding.instance.addPostFrameCallback((_) => edit.dispose());
  }

  /// Saves the draft over the selected custom theme, or as a new one, and
  /// selects it.
  Future<void> _saveLayoutEdit() async {
    final edit = _layoutEdit;
    if (edit == null) return;
    if (!edit.dirty) return _endLayoutEdit();
    final name = context.l10n.layoutDefaultName;
    final spec = edit.draft.normalized();
    final prefs = await Prefs.load();
    final themes = [...prefs.customChromeThemes];
    final current = int.tryParse(
      prefs.chromeThemeKey.replaceFirst(Prefs.customChromeThemePrefix, ''),
    );
    var index = current;
    if (index != null && index < themes.length) {
      themes[index] = spec.copyWith(name: themes[index].name);
    } else {
      themes.add(spec.copyWith(name: name));
      index = themes.length - 1;
    }
    await prefs.setCustomChromeThemes(themes);
    await prefs.setChromeThemeKey('${Prefs.customChromeThemePrefix}$index');
    PrefsStore.instance.notifyChanged();
    if (!mounted) return;
    _chromeTheme = spec;
    _endLayoutEdit();
  }

  /// Back asks first when the draft holds changes.
  Future<void> _backFromLayoutEdit() async {
    final edit = _layoutEdit;
    if (edit == null) return;
    if (edit.dirty) {
      final l = context.l10n;
      final discard = await confirmDialog(
        context,
        title: l.themeBuilderDiscardTitle,
        confirmLabel: l.themeBuilderDiscard,
        destructive: true,
      );
      if (!discard || !mounted) return;
    }
    _endLayoutEdit();
  }

  Future<void> _openSettings() async {
    _composer.unfocus();
    // The menu hands focus back to the search field on close, which
    // would raise the keyboard over the settings page.
    _search.focusNode.unfocus();
    // Pop notices and overlay snackbars on screen change.
    _chatNotice.clear();
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
          onEditLayout: () => _editLayoutPending = true,
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
        ),
      ),
    );
    if (mounted) ref.invalidate(macrosProvider);
    if (_editLayoutPending) {
      _editLayoutPending = false;
      _startLayoutEdit();
    }
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
    // picker, and menus read the live mixer themselves. Only history pages
    // hear catalog commits, to heal rows read before a catalog landed.
    ref.listen(emoteStateProvider, (_, next) {
      _emotesVersion.value = next.version;
    });
    // Blocking from a command sweeps rows in the provider; drop their tiles.
    ref.listen(blockedLoginsProvider, (prev, next) {
      if (next.length > (prev?.length ?? 0)) _tileCache.clear();
    });
    ref.listen(twitchAuthTickProvider, (_, _) => _onAuthChanged());
    ref.listen(connectivityTickProvider, (_, _) => _onConnectivityChanged());
    ref.listen(connectionStateProvider, (_, _) => _onConnectionChanged());
    ref.listen(
      reconnectedTickProvider,
      (_, _) => unawaited(_emotes.refreshSubEmoteOwners()),
    );
    if (_introPending) {
      return ColoredBox(color: Theme.of(context).colorScheme.surface);
    }
    // Reply card floats above the composer. Hidden while search or the terms
    // box borrows the input, and while the composer is disabled.
    final glass = glassEnabled(
      context,
      _liquidGlass && (_layoutEdit?.draft ?? _chromeTheme).isIsland,
    );
    // With channels the app bar folds away, so the bell, overflow and
    // settings live in the island's button row. The welcome view keeps them
    // in the app bar.
    // Hiding the input drops the island entirely when the menu that brings
    // it back sits outside the row: on the strip or app bar, or floating
    // where the strip was in fullscreen.
    final layout = _layoutEdit?.draft ?? _chromeTheme;
    final inputMenu = layout.places(ChromeAction.viewMenu)
        ? ChromeAction.viewMenu
        : ChromeAction.overflow;
    final menuOnTop =
        layout.stripActions.contains(inputMenu) ||
        (layout.header == HeaderStyle.appBar &&
            layout.appBarActions.contains(inputMenu));
    final hasBottomBar =
        (_chat.names.isNotEmpty || _channelManager.session.channelsPending) &&
        (_showInput ||
            layout.rowActions.contains(inputMenu) ||
            !(_isFullscreen || menuOnTop));
    // A compact theme hides the row under the keyboard, leaving the field
    // row. A theme with no row actions drops the row.
    final edit = _layoutEdit;
    final spec = edit?.draft ?? _chromeTheme;
    // Edit mode keeps the row up so its slots can take drops.
    final rowless = !spec.hasRow && edit == null;
    // Without a row, emote and send fall back to the field row.
    final rowShown = hasBottomBar && _showInput && !rowless;
    final emoteInRow = rowShown && spec.emoteInRow;
    final sendOutside = rowShown && spec.send != SendPlace.field;
    final fieldStart = [
      if (!rowShown && spec.emoteInRow) FieldItem.emote,
      ...spec.fieldStart,
    ];
    final fieldEnd = [
      ...spec.fieldEnd,
      if (!rowShown && spec.send != SendPlace.field) FieldItem.send,
    ];
    final modeRow = _modeRow;
    final sendButton = ComposerRowButton.send(
      controller: _composer,
      search: _search,
      mod: _mod,
      dragTick: _panelDragTick,
    );
    // The editor's chips and drop targets stand in for the real buttons.
    Widget? partSlot(ComposerPart part, PartPlace place) =>
        edit != null && edit.shows(part, place)
        ? PartSlot(controller: edit, part: part, place: place)
        : null;
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
          _layoutEdit == null &&
          !_isFullscreen &&
          !_streamPlayer.isTheaterMode &&
          _activePanel == OverlayPanel.closed &&
          !_emoteSheetOpen &&
          !_search.open,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_layoutEdit != null) {
          unawaited(_backFromLayoutEdit());
        } else if (_search.open) {
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
        bottomNavigationBar: _layoutEdit == null
            ? null
            : LayoutEditTray(
                controller: _layoutEdit!,
                onDone: () => unawaited(_saveLayoutEdit()),
                onCancel: _endLayoutEdit,
              ),
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
            composerInPane: _stream.chatInPane(context),
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
            emotePickerBuilder:
                (context, {required sheetBoxHeight, required inset}) =>
                    _buildEmotePicker(
                      sheetBoxHeight: sheetBoxHeight,
                      inset: inset,
                    ),
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
                    emoteInRow: emoteInRow,
                    sendOutside: sendOutside,
                    startItems: fieldStart,
                    endItems: fieldEnd,
                    actionBuilder: (a) => _chrome.action(
                      context,
                      a,
                      glass: glass,
                      onCalendar: _channels.openCalendar,
                    ),
                    startSlot: edit == null
                        ? null
                        : FieldSideView(
                            controller: edit,
                            side: LayoutSlot.fieldStart,
                          ),
                    endSlot: edit == null
                        ? null
                        : FieldSideView(
                            controller: edit,
                            side: LayoutSlot.fieldEnd,
                          ),
                    readOnly: edit != null,
                    classic: spec.composer == ComposerStyle.classic,
                    modeRow: modeRow,
                    uploads: _uploadController,
                  )
                : null,
            bottomBar: hasBottomBar && !rowless
                ? _chrome.bottomBar(
                    context,
                    glass: glass,
                    trailing: [
                      if (edit != null)
                        ?partSlot(ComposerPart.send, PartPlace.row)
                      else if (spec.sendInRow && sendOutside)
                        SizedBox.square(dimension: 48, child: sendButton),
                    ],
                    middle: _showInput
                        ? ComposerModeRow(
                            controller: _composer,
                            selectedTabIndex: _selectedTabIndex,
                            search: _search,
                            mod: _mod,
                            dragTick: _panelDragTick,
                            swipePage: _channels.swipePage,
                            alignStart: spec.rowStart.isEmpty,
                            // Send down the island's side, with no buttons
                            // between the gap and it.
                            sendRoom:
                                sendOutside &&
                                    !spec.sendInRow &&
                                    spec.rowEnd.isEmpty
                                ? ChatBody.sideActionWidth
                                : 0,
                          )
                        : null,
                    leading: edit != null
                        ? partSlot(ComposerPart.emote, PartPlace.row)
                        : emoteInRow
                        ? ComposerRowButton.emote(
                            controller: _composer,
                            search: _search,
                            mod: _mod,
                            dragTick: _panelDragTick,
                          )
                        : null,
                    onCalendar: _channels.openCalendar,
                  )
                : null,
            // The channel status line at the island's foot.
            islandFooterHeightFor: hasBottomBar ? _statusHeightFor : null,
            islandFooter: hasBottomBar
                ? ComposerStatusRow(
                    controller: _composer,
                    selectedTabIndex: _selectedTabIndex,
                    search: _search,
                    mod: _mod,
                    dragTick: _panelDragTick,
                    modeRow: modeRow,
                    classic: spec.composer == ComposerStyle.classic,
                  )
                : null,
            // Send runs down the island's side while the row stays up.
            sideAction: edit != null
                ? partSlot(ComposerPart.send, PartPlace.column)
                : sendOutside && spec.send == SendPlace.column
                ? sendButton
                : null,
            islandFlush: spec.islandFlush,
            classic: spec.composer == ComposerStyle.classic,
            busyListenable: spec.busyBar ? _chrome.joinBusyListenable : null,
            isBusy: _chrome.joinBusy,
            notice: ChatNoticeBar(controller: _chatNotice),
            replyHeader: replyHeader,
            liquidGlass: glass,
            keyboardHidesButtons: spec.compact,
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

  Widget _buildEmotePicker({
    required double sheetBoxHeight,
    required EdgeInsets inset,
  }) {
    return Positioned(
      key: const ValueKey('emote_picker'),
      bottom: inset.bottom,
      left: inset.left,
      right: inset.right,
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

/// Which system bars show: all, all but the status bar, or none.
enum _SystemBars { all, noStatus, none }
