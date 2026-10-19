import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../composer/composer_controller.dart';
import '../l10n/l10n.dart';
import '../models/twitch_message.dart';
import '../panels/search.dart';
import '../panels/threads.dart';
import '../chat/chat.dart';
import '../services/archive.dart';
import '../services/archive_history_source.dart';
import '../services/archive_reader.dart';
import '../services/link_whitelist.dart';
import '../services/stream_player_controller.dart';
import '../services/twitch_api.dart';
import '../widgets/seven_tv_paint_service.dart';
import '../services/twitch_auth.dart';
import '../sheets/message_menu.dart';
import '../sheets/user_sheet.dart';
import '../util/insets.dart';
import '../eventsub/decode/events.dart' show PinnedMessageEvent;
import '../services/mod_actions.dart' show ModResult;
import '../widgets/broadcast_widgets.dart';
import '../util/chat_search.dart';
import '../util/chrome_theme.dart';
import '../util/fake_history.dart';
import '../util/history_timeline.dart';
import '../widgets/chat_rows.dart';
import '../widgets/chat_view.dart';
import '../widgets/glass_chrome.dart';
import '../widgets/history_view.dart';
import '../widgets/message_builder.dart';
import '../widgets/tabbed_layout.dart';
import 'home_app_bar.dart';

// Fallback when the channel is gone; never bumps.
final _emptyNotifier = ValueNotifier<int>(0);

// Channel tabs, ChatView stack, welcome view, and selection verbs.
class ChannelPanels {
  ChannelPanels({
    required this.chat,
    required this.tileCache,
    required this.messageBuilder,
    required this.linkWhitelist,
    required this.twitchAuth,
    required this.twitchApi,
    required this.streamPlayer,
    required this.paintService,
    required this.selectedTabIndex,
    required this.userSheets,
    required this.menus,
    required this.threads,
    required this.search,
    required this.composer,
    required this.broadcastWidgets,
    required this.unpinFor,
    required this.homeAppBar,
    required this.selectedChannel,
    required this.showTimestamps,
    required this.timestampFormat,
    required this.chatFontSize,
    required this.checkeredMessages,
    required this.highlightOpacity,
    required this.lineSeparator,
    required this.sharedChatMode,
    required this.showNamePaints,
    required this.isFullscreen,
    required this.fastSnap,
    required this.commitChannelSelection,
    required this.copyMessage,
    required this.messageNotifier,
    required this.atBottomNotifier,
    required this.scrollCtrl,
    this.archiveReader,
    this.archive,
    this.emotesVersion,
  });

  static const welcomeChannel = '__welcome__';

  final Chat chat;
  final Map<String, Map<String?, Widget>> tileCache;
  final MessageBuilder messageBuilder;
  final LinkWhitelist linkWhitelist;
  final TwitchAuth twitchAuth;
  final TwitchApi twitchApi;

  /// Plays a stream's VOD and reports its position.
  final StreamPlayerController streamPlayer;
  final SevenTvPaintService paintService;
  final ValueNotifier<int> selectedTabIndex;
  final UserSheets userSheets;
  final MessageMenus menus;
  final ThreadPanels threads;
  final SearchPanels search;
  final ComposerController composer;
  final BroadcastWidgets broadcastWidgets;

  /// The Unpin action for [channel]'s pin, or null when the user does not
  /// moderate it.
  final Future<ModResult> Function(PinnedMessageEvent pin)? Function(
    String channel,
  )
  unpinFor;
  final HomeAppBar homeAppBar;
  final String? Function() selectedChannel;
  final bool Function() showTimestamps;
  final String Function() timestampFormat;
  final double Function() chatFontSize;
  final bool Function() checkeredMessages;
  final double Function() highlightOpacity;
  final bool Function() lineSeparator;
  final String Function() sharedChatMode;
  final bool Function() showNamePaints;
  final bool Function() isFullscreen;
  final bool Function() fastSnap;
  final void Function(int index, {required bool rebuild})
  commitChannelSelection;
  final void Function(TwitchMessage msg) copyMessage;
  final ValueNotifier<int> Function(String channel) messageNotifier;
  final ValueNotifier<bool> Function(String channel) atBottomNotifier;
  final ScrollController Function(String channel) scrollCtrl;

  /// Reads channel history for the windowed list; null keeps every page on
  /// [ChatView] over the live buffer.
  final ArchiveReader? archiveReader;

  /// Writes to the archive: kept days and remembered VODs.
  final Archive? archive;

  /// Emote catalog version, for history rows read before a catalog landed.
  final Listenable? emotesVersion;

  /// History sources by channel, so a rebuilt page keeps its source.
  final _sources = <String, HistorySource>{};

  /// A time each channel's history page should show next: a tapped search
  /// result. The page consumes it.
  final _jumps = <String, ValueNotifier<DateTime?>>{};
  ValueNotifier<DateTime?> _jumpFor(String channel) =>
      _jumps.putIfAbsent(channel, () => ValueNotifier(null));

  /// Per channel page: the menu's calendar asks the page to open its days.
  final _calendars = <String, ValueNotifier<bool>>{};

  /// Opens the selected channel's days.
  void openCalendar() {
    final channel = selectedChannel();
    if (channel != null) _calendarFor(channel).value = true;
  }

  ValueNotifier<bool> _calendarFor(String channel) =>
      _calendars.putIfAbsent(channel, () => ValueNotifier(false));

  /// Drops a removed channel's history state.
  void forgetChannel(String channel) {
    _sources.remove(channel);
    _jumps.remove(channel)?.dispose();
    _calendars.remove(channel)?.dispose();
  }

  late final Listenable _tabSharedMerge = Listenable.merge([
    selectedTabIndex,
    chat.unreadVersion,
  ]);
  String? _welcomeMessagesKey;
  List<TwitchMessage>? _welcomeMessages;

  // Stable per-channel widgets: identical instances short-circuit element
  // updates, so keyboard ticks skip these subtrees instead of rebuilding
  // every tab and page. Safe because all live content inside flows through
  // channel listenables (version/message/search), which keep firing through
  // the cached widgets. Keyed by name; cleared whenever the channel list
  // changes in length, order, or membership, so reorder and same-length
  // part plus join can never serve stale pages or tabs.
  final _pageCache = <String, _CachedPage>{};

  /// The channel pager's fractional page while it moves, so broadcast cards
  /// slide with their channel instead of staying over the next one.
  final _swipePage = ValueNotifier<double?>(null);
  ValueListenable<double?> get swipePage => _swipePage;
  final _tabCache = <String, Widget>{};
  List<String> _cachedChannels = const [];

  void _dropStaleCaches() {
    final channels = chat.names;
    var same = channels.length == _cachedChannels.length;
    if (same) {
      for (var i = 0; i < channels.length; i++) {
        if (channels[i] != _cachedChannels[i]) {
          same = false;
          break;
        }
      }
    }
    if (!same) {
      _pageCache.clear();
      _tabCache.clear();
      _cachedChannels = List.of(channels);
    }
  }

  // Search mode and appearance settings change page inputs without bumping
  // channel listenables, so they join the validity check. Everything else
  // the page reads is either listenable-driven (messages, edits, dim, query
  // via version/message/search) or a session-long object. Settings setters
  // that change tile content must also call info.touch() plus clear tileCache
  // (see HomeScreen _setPref rerenderChannels); theme and text scale reach
  // tiles through inherited widgets, and late paints self-update inside
  // their own ListenableBuilder, so they need no token entry.
  String _pageToken() =>
      '${search.open}|${showTimestamps()}|${timestampFormat()}|'
      '${chatFontSize()}|${checkeredMessages()}|${highlightOpacity()}|'
      '${lineSeparator()}|${sharedChatMode()}|${showNamePaints()}';

  /// Drop cached pages and tabs, forcing rebuild on next channelStack.
  /// Use for future settings that change tile content without a channel
  /// version bump.
  void invalidateCaches() {
    _pageCache.clear();
    _tabCache.clear();
    _cachedChannels = List.of(chat.names);
  }

  Widget _cachedPage(BuildContext context, String channel, double topPadding) {
    // Glass header clearance joins the token so toggling glass evicts stale
    // pages with stale spacers. The pill clearance arrives through
    // GlassChromeScope instead, so it never evicts a page.
    final token = '${_pageToken()}|${topPadding.round()}';
    final cached = _pageCache[channel];
    if (cached != null && cached.token == token) return cached.widget;
    final page = _buildPage(context, channel, topPadding);
    _pageCache[channel] = _CachedPage(page, token);
    return page;
  }

  void onChannelFocusChanged(int index) {
    commitChannelSelection(index, rebuild: false);
  }

  void onChannelChanged(int index) {
    commitChannelSelection(index, rebuild: true);
  }

  /// Page for [channel], stable across rebuilds (see [_pageCache]).
  /// Everything live inside is listenable-driven, so a cached instance
  /// still shows fresh rows, edits and search filtering. The captured
  /// [context] is channelStack's own long-lived build context.
  Widget _buildPage(
    BuildContext context,
    String channel, [
    double topPadding = 0,
  ]) {
    final history = _historySource(channel);
    if (history != null && !search.open) {
      return _historyPage(context, channel, history, topPadding);
    }
    final infoVersion =
        chat.channelFor(channel)?.info.version ?? _emptyNotifier;
    final messageVersion =
        chat.channelFor(channel)?.messages.version ?? _emptyNotifier;
    return _FocusGatedBuilder(
      // message version drives new rows and text edits;
      // search bumps only its own channel on keystrokes.
      listenable: Listenable.merge([
        infoVersion,
        messageVersion,
        search.channelVersion(channel),
      ]),
      builder: (_, active) =>
          _searchResults(context, channel, topPadding, active) ??
          ChatView(
            channel: channel,
            messages: search.visibleMessages(channel),
            tileCache: tileCache,
            isDimmed: search.dimPredicate(channel),
            emptyText:
                search.emptyText(channel, context.l10n) ??
                context.l10n.noMessagesYet,
            atBottomNotifier: atBottomNotifier(channel),
            messageNotifier: active ? messageVersion : _emptyNotifier,
            scrollController: scrollCtrl(channel),
            messageBuilder: messageBuilder,
            linkWhitelist: linkWhitelist,
            showTimestamp: showTimestamps(),
            timestampFormat: timestampFormat(),
            chatFontScale: chatFontSize() / 14.0,
            checkeredMessages: checkeredMessages(),
            highlightOpacity: highlightOpacity(),
            lineSeparator: lineSeparator(),
            sharedChatMode: sharedChatMode(),
            paintService: showNamePaints() ? paintService : null,
            topOverlayPadding: topPadding,
            onShowUserProfile: (login, userId, {displayName}) =>
                userSheets.showUserProfile(
                  context,
                  login,
                  userId,
                  displayName: displayName,
                ),
            onShowMessageMenu: (msg) => menus.showMessageMenu(context, msg),
            onCopyMessage: copyMessage,
            onScrollActivity: (c) {
              chat.clearUnread(c);
            },
            onFindThreadRoot: threads.findThreadRoot,
            onShowThreadView: (msg) => threads.showThreadView(msg),
            keepAlive: false,
            keepPosition: !search.open,
            keyboardDismissBehavior: (!kIsWeb && Platform.isIOS)
                ? ScrollViewKeyboardDismissBehavior.onDrag
                : ScrollViewKeyboardDismissBehavior.manual,
          ),
    );
  }

  /// The history source for [channel]'s page: generated rows for the
  /// prototype channels, the archive for the rest, null without an archive.
  HistorySource? _historySource(String channel) {
    if (FakeHistory.isFake(channel)) {
      return _sources[channel] ??= FakeHistorySource(channel);
    }
    final reader = archiveReader;
    if (reader == null) return null;
    return _sources[channel] ??= ArchiveHistorySource(channel, reader);
  }

  /// What [channel]'s history page offers for its days and streams; null
  /// without an archive.
  HistoryActions? _actionsFor(String channel) {
    final reader = archiveReader;
    final archive = this.archive;
    if (reader == null || archive == null || FakeHistory.isFake(channel)) {
      return null;
    }
    return HistoryActions(
      keptDays: () => reader.keptDays(channel),
      keepDay: (start, end, keep) =>
          archive.setDayKept(channel, start, end, keep: keep),
      findVod: (stream) => _findVod(archive, channel, stream),
      thumbnails: () => _thumbnails(channel),
      watchVod: (stream, vodId) =>
          streamPlayer.watchVod(channel, vodId, stream.start),
      follow: streamPlayer.vodPlayback,
    );
  }

  /// The video on demand of [stream], from the archive or else Helix, which
  /// the archive then remembers.
  Future<String?> _findVod(
    Archive archive,
    String channel,
    HistoryStream stream,
  ) async {
    if (stream.vodId case final held?) return held;
    final broadcaster = chat.channelFor(channel)?.info.broadcasterId;
    if (broadcaster == null || !twitchAuth.isConfigured) return null;
    final videos = await twitchApi.getArchiveVideos(twitchAuth, broadcaster);
    final id = videos?[stream.id]?.id;
    if (id != null) unawaited(archive.setVod(stream.id, id));
    return id;
  }

  /// Thumbnails of [channel]'s past broadcasts by stream id, sized for a
  /// list row. Empty when signed out or the lookup fails.
  Future<Map<String, String>> _thumbnails(String channel) async {
    final broadcaster = chat.channelFor(channel)?.info.broadcasterId;
    if (broadcaster == null || !twitchAuth.isConfigured) return const {};
    final videos = await twitchApi.getArchiveVideos(twitchAuth, broadcaster);
    return {
      for (final MapEntry(:key, :value) in (videos ?? const {}).entries)
        if (value.thumbnail.isNotEmpty)
          key: value.thumbnail
              .replaceFirst('%{width}', '320')
              .replaceFirst('%{height}', '180'),
    };
  }

  /// [channel]'s page as the windowed history list continuing into the live
  /// buffer. Info bumps (settings that change tiles) rebuild it; the list
  /// follows the buffer itself, and only while its page is active.
  Widget _historyPage(
    BuildContext context,
    String channel,
    HistorySource source,
    double topPadding,
  ) {
    final fake = FakeHistory.isFake(channel);
    final state = chat.channelFor(channel);
    final messages = state?.messages;
    return _FocusGatedBuilder(
      listenable: state?.info.version ?? _emptyNotifier,
      builder: (_, active) => HistoryView(
        // The pager reuses page slots across channels when tabs close or
        // reorder; the window belongs to one channel.
        key: ValueKey(channel),
        channel: channel,
        source: source,
        debugControls: fake,
        live: messages == null ? null : () => messages.chatRows,
        liveVersion: active ? messages?.version : null,
        emotesVersion: emotesVersion,
        jumpRequest: _jumpFor(channel),
        calendarRequest: _calendarFor(channel),
        actions: _actionsFor(channel),
        rows: _rows(context, channel),
        textScale: chatFontSize() / 14.0,
        topPadding: topPadding,
        tileCache: tileCache,
        atBottomNotifier: atBottomNotifier(channel),
        onScrollActivity: chat.clearUnread,
        emptyText: fake ? null : context.l10n.noMessagesYet,
        keyboardDismissBehavior: (!kIsWeb && Platform.isIOS)
            ? ScrollViewKeyboardDismissBehavior.onDrag
            : ScrollViewKeyboardDismissBehavior.manual,
      ),
    );
  }

  /// [channel]'s rows as both history pages draw them.
  ChatRows _rows(
    BuildContext context,
    String channel, {
    void Function(TwitchMessage msg)? onTapMessage,
  }) => ChatRows(
    channel: channel,
    messageBuilder: messageBuilder,
    linkWhitelist: linkWhitelist,
    showTimestamp: showTimestamps(),
    timestampFormat: timestampFormat(),
    checkeredMessages: checkeredMessages(),
    highlightOpacity: highlightOpacity(),
    lineSeparator: lineSeparator(),
    sharedChatMode: sharedChatMode(),
    paintService: showNamePaints() ? paintService : null,
    onShowUserProfile: (login, userId, {displayName}) => userSheets
        .showUserProfile(context, login, userId, displayName: displayName),
    onShowMessageMenu: (msg) => menus.showMessageMenu(context, msg),
    onCopyMessage: copyMessage,
    onFindThreadRoot: threads.findThreadRoot,
    onShowThreadView: (msg) => threads.showThreadView(msg),
    onTapMessage: onTapMessage,
  );

  /// [channel]'s search as a history list of matches over the whole archive,
  /// newest at the bottom and live matches joining it. A tap closes search
  /// and shows the message in the channel's history. Null when the buffer
  /// filter applies instead: dim or paused (both need every buffer row), no
  /// query, or no archive.
  Widget? _searchResults(
    BuildContext context,
    String channel,
    double topPadding,
    bool active,
  ) {
    final reader = archiveReader;
    final filter = search.stateFor(channel);
    if (reader == null ||
        FakeHistory.isFake(channel) ||
        !filter.isActive ||
        filter.display != ChatSearchDisplay.hide ||
        filter.live != ChatSearchLive.stream) {
      return null;
    }
    final q = filter.query.trim().toLowerCase();
    final scope = filter.scope;
    final messages = chat.channelFor(channel)?.messages;
    return HistoryView(
      // A new query or scope starts a new list.
      key: ValueKey('search|$channel|${scope.name}|$q'),
      channel: channel,
      source: ArchiveFindSource.search(channel, reader, query: q, scope: scope),
      emptyStretches: false,
      live: messages == null
          ? null
          : () => [
              for (final m in messages.chatRows)
                if (searchMatchesLower(m, q, scope)) m,
            ],
      liveVersion: active ? messages?.version : null,
      emotesVersion: emotesVersion,
      rows: _rows(
        context,
        channel,
        onTapMessage: (msg) {
          search.closeSearch();
          _jumpFor(channel).value = msg.timestamp;
        },
      ),
      textScale: chatFontSize() / 14.0,
      topPadding: topPadding,
      tileCache: tileCache,
      atBottomNotifier: atBottomNotifier(channel),
      emptyText: context.l10n.noMatches,
      keyboardDismissBehavior: (!kIsWeb && Platform.isIOS)
          ? ScrollViewKeyboardDismissBehavior.onDrag
          : ScrollViewKeyboardDismissBehavior.manual,
    );
  }

  /// Tab label for [channel], stable across rebuilds (see [_tabCache]).
  /// Selection and unread state stay live inside the merged listenable.
  /// The focused index resolves live from the channel list, so reorder
  /// with the same length can never leave a stale highlight behind.
  Widget _buildTab(String channel) {
    return _ChannelTab(
      chat: chat,
      channel: channel,
      selectedTabIndex: selectedTabIndex,
      selectedChannel: selectedChannel,
      listenable: _tabSharedMerge,
    );
  }

  Widget channelTabs(
    BuildContext context, {
    required bool hideChrome,
    bool merged = false,
    Widget? belowTabBar,
    bool glassOverlay = false,
    bool glassChrome = false,
    Widget? glassHeader,
    double glassHeaderHeight = 0,
    double glassTopPadding = 0,
    bool underStream = false,
  }) {
    return Expanded(
      child: channelStack(
        context,
        hideChrome: hideChrome,
        merged: merged,
        underStream: underStream,
        belowTabBar: belowTabBar,
        glassOverlay: glassOverlay,
        glassChrome: glassChrome,
        glassHeader: glassHeader,
        glassHeaderHeight: glassHeaderHeight,
        glassTopPadding: glassTopPadding,
      ),
    );
  }

  Widget channelStack(
    BuildContext context, {
    required bool hideChrome,
    bool merged = false,
    Widget? belowTabBar,
    bool glassOverlay = false,
    bool glassChrome = false,
    Widget? glassHeader,
    double glassHeaderHeight = 0,
    double glassTopPadding = 0,
    bool underStream = false,
  }) {
    _dropStaleCaches();
    // The view menu, bell, overflow and settings live in the island's row.
    final showStrip = !isFullscreen() && !hideChrome;
    // A themed app bar holds the actions; the strip keeps its own.
    final appBarHeader =
        homeAppBar.themeSpec().header == HeaderStyle.appBar &&
        chat.names.isNotEmpty;
    return Stack(
      children: [
        Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            composer.clearSuggestions();
          },
          child: chat.names.isNotEmpty
              ? NotificationListener<ScrollUpdateNotification>(
                  onNotification: (n) {
                    final metrics = n.metrics;
                    if (n.depth == 0 && metrics is PageMetrics) {
                      _swipePage.value = metrics.page;
                    }
                    return false;
                  },
                  child: TabbedLayout(
                    tabs: chat.names,
                    selectedIndex: chat.names.indexOf(selectedChannel() ?? ''),
                    onSelectedIndexChanged: onChannelChanged,
                    onFocusChanged: onChannelFocusChanged,
                    onTabTapped: (index) {
                      final channel = chat.names[index];
                      // ChatView rests on the newest row at 0; a history
                      // page jumps itself when the notifier turns true.
                      final ctrl = scrollCtrl(channel);
                      if (ctrl.hasClients) ctrl.jumpTo(0);
                      atBottomNotifier(channel).value = true;
                    },
                    showTabBar: showStrip,
                    fullscreen: isFullscreen(),
                    pagesOverlay: selectedChannel() == null
                        ? null
                        : ListenableBuilder(
                            listenable: Listenable.merge([
                              broadcastWidgets.notifier,
                              selectedTabIndex,
                              _swipePage,
                            ]),
                            builder: (_, _) => _broadcastOverlay(
                              glassEnabled(
                                context,
                                glassOverlay || glassChrome,
                              ),
                            ),
                          ),
                    // Join stays the last tab unless the theme places a join
                    // button; the theme's strip actions pin to the strip's
                    // end. Fullscreen hides the strip, so the view menu
                    // floats in its place then.
                    addTab: merged && homeAppBar.stripJoinTab
                        ? homeAppBar.joinTab()
                        : null,
                    onAddTab: homeAppBar.onJoinTab,
                    stripBubbles:
                        homeAppBar.themeSpec().header == HeaderStyle.bubbles,
                    stripTrailing: merged || appBarHeader
                        ? homeAppBar.stripTrailing(
                            glass: glassOverlay || glassChrome,
                            onCalendar: openCalendar,
                          )
                        : null,
                    fullscreenMenu:
                        isFullscreen() &&
                            !homeAppBar.themeSpec().rowActions.contains(
                              ChromeAction.viewMenu,
                            )
                        ? homeAppBar.action(
                            context,
                            ChromeAction.viewMenu,
                            glass: glassOverlay || glassChrome,
                            onCalendar: openCalendar,
                          )
                        : null,
                    // A stream above the strip already sits at the top.
                    stripTopInset: merged && !underStream
                        ? statusBarHeight(context)
                        : 0,
                    belowTabBar: belowTabBar,
                    glassOverlay: glassOverlay,
                    headerOverlay: glassHeader,
                    overlayHeaderHeight: glassHeaderHeight,
                    pageBuilder: (_, i) {
                      final channel = chat.names[i];
                      return _cachedPage(context, channel, glassTopPadding);
                    },
                    focusOnHalfDrag: true,
                    fastSnap: fastSnap(),
                    preloadAdjacentPages: true,
                    tabBuilder: (_, i) {
                      final channel = chat.names[i];
                      final cached = _tabCache[channel];
                      if (cached != null) return cached;
                      final tab = _buildTab(channel);
                      _tabCache[channel] = tab;
                      return tab;
                    },
                  ),
                )
              : glassOverlay && glassHeader != null
              ? Stack(
                  children: [
                    Positioned.fill(
                      child: welcomeChatView(
                        context,
                        topPadding: glassTopPadding,
                      ),
                    ),
                    Positioned(
                      top: -kGlassEdgeBleed,
                      left: -kGlassEdgeBleed,
                      right: -kGlassEdgeBleed,
                      child: glassHeaderBar(
                        hidden: isFullscreen(),
                        dark: Theme.of(context).brightness == Brightness.dark,
                        child: glassHeader,
                      ),
                    ),
                  ],
                )
              : welcomeChatView(context),
        ),
      ],
    );
  }

  /// The selected channel's broadcast cards; mid-swipe, both channels' cards,
  /// each offset with its page.
  Widget _broadcastOverlay(bool glass) {
    // Minimizing, restoring and cards coming or going expand and retract
    // from the top edge, with no fade.
    Widget cards(String channel, double room) {
      final overlay = broadcastWidgets.buildOverlay(
        channel,
        room: room,
        onMinimizeChanged: broadcastWidgets.setMinimized,
        glass: glass,
        unpin: unpinFor(channel),
      );
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: TabbedLayout.cardInset),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeOut,
            transitionBuilder: (child, animation) => SizeTransition(
              sizeFactor: animation,
              alignment: Alignment.topCenter,
              child: child,
            ),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [...previous, ?current],
            ),
            child: KeyedSubtree(
              key: ValueKey(overlay?.runtimeType),
              child: overlay ?? const SizedBox(width: double.infinity),
            ),
          ),
        ),
      );
    }

    final shown = swipeShown(chat.names, _swipePage.value, selectedChannel());
    // One tree shape at rest and mid-swipe, keyed by channel, so a card
    // keeps its state when a swipe starts instead of rebuilding.
    return LayoutBuilder(
      builder: (_, constraints) {
        final width = constraints.maxWidth;
        return ClipRect(
          child: Stack(
            children: [
              for (final (channel, dx) in shown)
                Transform.translate(
                  key: ValueKey(channel),
                  offset: Offset(dx * width, 0),
                  child: cards(channel, constraints.maxHeight),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget welcomeChatView(BuildContext context, {double topPadding = 0}) {
    final configured = twitchAuth.isConfigured;
    final login = twitchAuth.login;
    final l10n = context.l10n;
    final key = '$configured:$login:${l10n.localeName}';
    if (_welcomeMessagesKey != key) {
      _welcomeMessagesKey = key;
      _welcomeMessages = [
        if (!configured)
          TwitchMessage(
            login: '',
            text: l10n.welcomeConfigure,
            isSystem: true,
            messageId: 'welcome',
            channel: welcomeChannel,
          )
        else ...[
          if (login != null)
            TwitchMessage(
              login: '',
              text: l10n.welcomeSignedIn(login),
              isSystem: true,
              messageId: 'welcome-signin',
              channel: welcomeChannel,
            ),
          TwitchMessage(
            login: '',
            text: l10n.welcomePressPlus,
            isSystem: true,
            messageId: 'welcome-join',
            channel: welcomeChannel,
          ),
        ],
      ];
    }
    return ChatView(
      channel: welcomeChannel,
      messages: _welcomeMessages!,
      tileCache: tileCache,
      atBottomNotifier: atBottomNotifier(welcomeChannel),
      messageNotifier: messageNotifier(welcomeChannel),
      scrollController: scrollCtrl(welcomeChannel),
      messageBuilder: messageBuilder,
      linkWhitelist: linkWhitelist,
      showTimestamp: showTimestamps(),
      timestampFormat: timestampFormat(),
      chatFontScale: chatFontSize() / 14.0,
      checkeredMessages: checkeredMessages(),
      highlightOpacity: highlightOpacity(),
      lineSeparator: lineSeparator(),
      sharedChatMode: sharedChatMode(),
      paintService: showNamePaints() ? paintService : null,
      topOverlayPadding: topPadding,
      onShowUserProfile: (login, userId, {displayName}) => userSheets
          .showUserProfile(context, login, userId, displayName: displayName),
      keyboardDismissBehavior: (!kIsWeb && Platform.isIOS)
          ? ScrollViewKeyboardDismissBehavior.onDrag
          : ScrollViewKeyboardDismissBehavior.manual,
    );
  }
}

/// Cached page plus the config token it was built under.
class _CachedPage {
  const _CachedPage(this.widget, this.token);

  final Widget widget;
  final String token;
}

/// Runs [builder] against the channel versions only while the page's pager tab
/// is focused. A background page keeps its last frame and stops rebuilding; on
/// refocus the builder runs with the messages it missed.
class _FocusGatedBuilder extends StatelessWidget {
  const _FocusGatedBuilder({required this.listenable, required this.builder});

  final Listenable listenable;
  final Widget Function(BuildContext context, bool active) builder;

  @override
  Widget build(BuildContext context) {
    final active = TickerMode.valuesOf(context).enabled;
    return ListenableBuilder(
      listenable: active ? listenable : _emptyNotifier,
      builder: (context, _) => builder(context, active),
    );
  }
}

/// Channel tab label. A new mention on an unselected channel pulses the label
/// to the accent color once, on top of the steady unread dot.
class _ChannelTab extends StatefulWidget {
  const _ChannelTab({
    required this.chat,
    required this.channel,
    required this.selectedTabIndex,
    required this.selectedChannel,
    required this.listenable,
  });

  final Chat chat;
  final String channel;
  final ValueNotifier<int> selectedTabIndex;
  final String? Function() selectedChannel;

  /// Merged selection and unread notifier the label reads through.
  final Listenable listenable;

  @override
  State<_ChannelTab> createState() => _ChannelTabState();
}

class _ChannelTabState extends State<_ChannelTab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  // One out-and-back pulse per new mention.
  late final Animation<double> _pulse = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 1),
  ]).animate(CurvedAnimation(parent: _flash, curve: Curves.easeOut));

  bool _hadMention = false;

  bool get _hasMention =>
      widget.chat.channelFor(widget.channel)?.unread.hasMention ?? false;

  bool get _selected =>
      widget.chat.names.indexOf(widget.channel) ==
          widget.selectedTabIndex.value ||
      widget.channel == widget.selectedChannel();

  @override
  void initState() {
    super.initState();
    _hadMention = _hasMention;
    widget.listenable.addListener(_onUnreadChanged);
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_onUnreadChanged);
    _flash.dispose();
    super.dispose();
  }

  void _onUnreadChanged() {
    final mention = _hasMention;
    // Only a fresh mention on a background channel flashes, and never a
    // re-notify of one already showing.
    if (mention && !_hadMention && !_selected) _flash.forward(from: 0);
    _hadMention = mention;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([widget.listenable, _pulse]),
      builder: (ctx, _) {
        final unread = widget.chat.channelFor(widget.channel)?.unread;
        final hasUnread = unread?.hasUnread ?? false;
        final hasUnreadMention = unread?.hasMention ?? false;
        final selected = _selected;
        final base = selected
            ? theme.colorScheme.primary
            : hasUnread
            ? theme.colorScheme.onSurface
            : null;
        final pulse = selected ? 0.0 : _pulse.value;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Text(
              widget.channel,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected || hasUnread
                    ? FontWeight.w600
                    : FontWeight.normal,
                // Flash toward the unread-dot color so it reads as a new
                // mention, not a selection.
                color: pulse <= 0
                    ? base
                    : Color.lerp(base, theme.colorScheme.error, pulse),
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
  }
}
