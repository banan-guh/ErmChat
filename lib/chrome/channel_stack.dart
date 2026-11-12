import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
import '../util/haptics.dart';
import '../util/history_timeline.dart';
import '../widgets/chat_rows.dart';
import '../widgets/chat_view.dart';
import '../widgets/dialogs.dart';
import '../widgets/history_view.dart';
import '../widgets/island_metrics.dart';
import '../widgets/join_channel_dialog.dart';
import '../widgets/message_builder.dart';
import '../widgets/tabbed_layout.dart';
import 'home_app_bar.dart';
import '../widgets/design_tokens.dart';

// Fallback when the channel is gone; never bumps.
final _emptyNotifier = ValueNotifier<int>(0);

/// The two channels split chat shows, by fixed pane slot, and the slot that
/// owns the composer.
typedef SplitPair = ({String first, String second, int active});

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
    required this.ownLogin,
    required this.onHeldDecide,
    required this.isFullscreen,
    required this.fastSnap,
    required this.commitChannelSelection,
    required this.copyMessage,
    required this.removeChannel,
    required this.renameChannel,
    required this.splitPair,
    required this.openSplit,
    required this.closeSplit,
    required this.focusSplitPane,
    required this.setSplitPaneChannel,
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
  final String? Function() ownLogin;

  /// Resolves an AutoMod-held row from its inline buttons.
  final Future<void> Function(String channel, TwitchMessage msg, bool allow)
  onHeldDecide;
  final bool Function() isFullscreen;
  final bool Function() fastSnap;
  final void Function(int index, {required bool rebuild})
  commitChannelSelection;
  final void Function(TwitchMessage msg) copyMessage;

  /// Leaves [channel] from its tab's long-press menu.
  final void Function(String channel) removeChannel;

  /// Swaps [from] for [to] at the same tab position.
  final void Function(String from, String to) renameChannel;

  /// The two channels split chat shows, or null when it is off.
  final SplitPair? Function() splitPair;

  /// Puts [channel] in the split below the current pane.
  final void Function(String channel) openSplit;

  /// Leaves split chat.
  final VoidCallback closeSplit;

  /// Makes the [slot] pane the one the composer sends to.
  final void Function(int slot) focusSplitPane;

  /// Moves [slot]'s pager to the tab at [index].
  final void Function(int slot, int index) setSplitPaneChannel;
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

  /// Whether the keyboard hid the chrome; the page token and top clearance
  /// follow it.
  bool _hideChrome = false;

  /// Whether the pages area shows split chat, so the panes carry the strip's
  /// clearance instead of every page.
  bool _splitMode = false;

  /// Whether a stream sits above the strip, so its top inset is zero.
  bool _underStream = false;

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

  /// Shows [time] when [channel]'s history page is next built or selected,
  /// then pulses that row so the jump is visible.
  void jumpTo(String channel, DateTime time) {
    _jumpFor(channel).value = time;
    final request = FlashRequest(time, ++_flashToken);
    final flashes = _flashFor(channel);
    flashes.value = request;
    _flashTimers.remove(channel)?.cancel();
    _flashTimers[channel] = Timer(const Duration(seconds: 2), () {
      _flashTimers.remove(channel);
      if (flashes.value == request) flashes.value = null;
    });
  }

  /// A pulse request each channel's rows watch, so a jump target shows.
  final _flashes = <String, ValueNotifier<FlashRequest?>>{};
  final _flashTimers = <String, Timer>{};
  int _flashToken = 0;
  ValueNotifier<FlashRequest?> _flashFor(String channel) =>
      _flashes.putIfAbsent(channel, () => ValueNotifier(null));

  ValueNotifier<bool> _calendarFor(String channel) =>
      _calendars.putIfAbsent(channel, () => ValueNotifier(false));

  /// Drops a removed channel's history state.
  void forgetChannel(String channel) {
    _sources.remove(channel);
    _jumps.remove(channel)?.dispose();
    _calendars.remove(channel)?.dispose();
    _flashTimers.remove(channel)?.cancel();
    _flashes.remove(channel)?.dispose();
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

  /// The page stack's key, so floating chrome anchors under the tabs and
  /// stream rather than the app bar.
  final pagesKey = GlobalKey();

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
  /// Whether fullscreen floats the view menu over the pages' top-right
  /// corner, because the theme's button row does not carry it.
  bool _menuFloats() =>
      isFullscreen() &&
      !homeAppBar.themeSpec().rowActions.contains(ChromeAction.viewMenu);

  String _pageToken() =>
      '${homeAppBar.themeSpec().header.name}|${isFullscreen()}|'
      '$_hideChrome|$_underStream|$_splitMode|${search.open}|'
      '${showTimestamps()}|'
      '${timestampFormat()}|${chatFontSize()}|${checkeredMessages()}|'
      '${highlightOpacity()}|${lineSeparator()}|${sharedChatMode()}|'
      '${showNamePaints()}';

  /// Clearance above the oldest row when the bubble strip floats over the
  /// page. Zero for every other header, fullscreen, or hidden chrome.
  double _bubbleClearance(BuildContext context) {
    if (_hideChrome || isFullscreen()) return 0;
    if (homeAppBar.themeSpec().header != HeaderStyle.bubbles) return 0;
    return (_underStream ? 0 : statusBarHeight(context)) +
        TabbedLayout.bubbleStripHeight;
  }

  /// The clearance a page adds itself. Split chat pads its panes once
  /// instead, so each one does not leave the strip's gap under its header.
  double _bubbleTopPadding(BuildContext context) =>
      _splitMode ? 0 : _bubbleClearance(context);

  /// Drop cached pages and tabs, forcing rebuild on next channelStack.
  /// Use for future settings that change tile content without a channel
  /// version bump.
  void invalidateCaches() {
    _pageCache.clear();
    _tabCache.clear();
    _cachedChannels = List.of(chat.names);
  }

  /// Key for a page's per-view state: the channel itself, or one split slot's
  /// half of it so the same channel can live twice with separate scroll.
  String _paneKey(String channel, int? slot) =>
      slot == null ? channel : '$channel#split$slot';

  Widget _cachedPage(
    BuildContext context,
    String channel, {
    bool clearsIsland = true,
    int? slot,
  }) {
    // The split flag changes which island spacer the page uses, so it joins
    // the token. The clearance itself sizes in layout.
    final token = '${_pageToken()}|${_menuFloats()}|$clearsIsland|$slot';
    final key = _paneKey(channel, slot);
    final cached = _pageCache[key];
    if (cached != null && cached.token == token) return cached.widget;
    final page = _buildPage(
      context,
      channel,
      clearsIsland: clearsIsland,
      slot: slot,
    );
    _pageCache[key] = _CachedPage(page, token);
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
    String channel, {
    bool clearsIsland = true,
    int? slot,
  }) {
    final history = _historySource(channel);
    if (history != null && !search.open) {
      return _historyPage(
        context,
        channel,
        history,
        clearsIsland: clearsIsland,
        slot: slot,
      );
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
      builder: (ctx, active) {
        final buffer = ChatView(
          channel: channel,
          channelPage: true,
          messages: search.visibleMessages(channel),
          topPadding: _bubbleTopPadding(ctx),
          clearsIsland: clearsIsland,
          tileCache: tileCache,
          isDimmed: search.dimPredicate(channel),
          hides: chat.filter.hides,
          emptyText:
              search.emptyText(channel, ctx.l10n) ?? ctx.l10n.noMessagesYet,
          atBottomNotifier: atBottomNotifier(_paneKey(channel, slot)),
          messageNotifier: active ? messageVersion : _emptyNotifier,
          scrollController: scrollCtrl(_paneKey(channel, slot)),
          scrollFabHeroTag: slot == null
              ? null
              : 'scroll_down_${channel}_split$slot',
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
          onShowUserProfile: (ctx, login, userId, {displayName}) => userSheets
              .showUserProfile(ctx, login, userId, displayName: displayName),
          onShowMessageMenu: (ctx, msg) => menus.showMessageMenu(ctx, msg),
          onCopyMessage: copyMessage,
          onScrollActivity: (c) {
            chat.clearUnread(c);
          },
          onFindThreadRoot: threads.findThreadRoot,
          onShowThreadView: (msg) => threads.showThreadView(msg),
          flashRequest: _flashFor(channel),
          keepAlive: false,
          keepPosition: !search.open,
          keyboardDismissBehavior: (!kIsWeb && Platform.isIOS)
              ? ScrollViewKeyboardDismissBehavior.onDrag
              : ScrollViewKeyboardDismissBehavior.manual,
        );
        return _searchResults(ctx, channel, active, buffer) ?? buffer;
      },
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
      vodLive: streamPlayer.vodChatLive,
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
    HistorySource source, {
    bool clearsIsland = true,
    int? slot,
  }) {
    final fake = FakeHistory.isFake(channel);
    final state = chat.channelFor(channel);
    final messages = state?.messages;
    return _FocusGatedBuilder(
      listenable: state?.info.version ?? _emptyNotifier,
      builder: (ctx, active) => HistoryView(
        // The pager reuses page slots across channels when tabs close or
        // reorder; the window belongs to one channel. Split slots get their
        // own key and reading position so the same channel can live twice.
        key: ValueKey(_paneKey(channel, slot)),
        storageId: slot == null ? null : 'history:${_paneKey(channel, slot)}',
        channel: channel,
        channelPage: true,
        source: source,
        topPadding: _bubbleTopPadding(ctx),
        clearsIsland: clearsIsland,
        debugControls: fake,
        live: messages == null ? null : () => messages.chatRows,
        liveVersion: active ? messages?.version : null,
        emotesVersion: emotesVersion,
        active: active,
        jumpRequest: _jumpFor(channel),
        calendarRequest: _calendarFor(channel),
        actions: _actionsFor(channel),
        underCornerMenu: _menuFloats(),
        rows: _rows(channel),
        textScale: chatFontSize() / 14.0,
        tileCache: tileCache,
        compact: true,
        ownLogin: ownLogin,
        atBottomNotifier: atBottomNotifier(_paneKey(channel, slot)),
        scrollFabHeroTag: slot == null
            ? null
            : 'scroll_down_${channel}_split$slot',
        onScrollActivity: chat.clearUnread,
        emptyText: fake ? null : ctx.l10n.noMessagesYet,
        keyboardDismissBehavior: (!kIsWeb && Platform.isIOS)
            ? ScrollViewKeyboardDismissBehavior.onDrag
            : ScrollViewKeyboardDismissBehavior.manual,
      ),
    );
  }

  /// [channel]'s rows as both history pages draw them.
  ChatRows _rows(
    String channel, {
    void Function(TwitchMessage msg)? goToMessage,
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
    onShowUserProfile: (ctx, login, userId, {displayName}) => userSheets
        .showUserProfile(ctx, login, userId, displayName: displayName),
    onShowMessageMenu: goToMessage == null
        ? (ctx, msg) => menus.showMessageMenu(ctx, msg)
        : (ctx, msg) => menus.showPanelMessageMenu(
            ctx,
            msg,
            goToMessage: () => goToMessage(msg),
          ),
    onCopyMessage: copyMessage,
    onHeldDecide: (msg, allow) => onHeldDecide(channel, msg, allow),
    onFindThreadRoot: threads.findThreadRoot,
    onShowThreadView: (msg) => threads.showThreadView(msg),
    hides: chat.filter.hides,
    flashRequest: _flashFor(channel),
  );

  /// [channel]'s search as a history list of matches over the whole archive,
  /// newest at the bottom and live matches joining it. A tap closes search
  /// and shows the message in the channel's history. [buffer] shows while
  /// the query is empty. Null when the buffer filter applies instead: dim or
  /// paused (both need every buffer row), or no archive.
  Widget? _searchResults(
    BuildContext context,
    String channel,
    bool active,
    Widget buffer,
  ) {
    final reader = archiveReader;
    final filter = search.stateFor(channel);
    if (reader == null ||
        FakeHistory.isFake(channel) ||
        filter.display != ChatSearchDisplay.hide ||
        filter.live != ChatSearchLive.stream) {
      return null;
    }
    final messages = chat.channelFor(channel)?.messages;
    return _SettledSearch(
      key: ValueKey('search|$channel'),
      query: filter.query.trim().toLowerCase(),
      scope: filter.scope,
      empty: buffer,
      onEnd: reader.endSearch,
      source: (q, scope) =>
          ArchiveFindSource.search(channel, reader, query: q, scope: scope),
      build: (source, newest, q, scope) {
        final query = ChatQuery.parse(q, scope);
        final searchId = 'search|$channel|${scope.name}|$q';
        return HistoryView(
          // A new query or scope starts a new list.
          key: ValueKey(searchId),
          storageId: 'history:$searchId',
          channel: channel,
          channelPage: true,
          source: source,
          topPadding: _bubbleTopPadding(context),
          emptyStretches: false,
          live: messages == null
              ? null
              : () => [
                  for (final m in messages.chatRows)
                    if (query.matches(m)) m,
                ],
          // The settle step already waited for the archive's matches, so
          // the list opens on them instead of the buffer's few.
          liveFirst: false,
          newestRows: newest,
          liveVersion: active ? messages?.version : null,
          emotesVersion: emotesVersion,
          rows: _rows(
            channel,
            goToMessage: (msg) {
              search.closeSearch();
              jumpTo(channel, msg.timestamp);
            },
          ),
          textScale: chatFontSize() / 14.0,
          // Result rows carry their own menu, so they never share a tile
          // with the channel page's cached ones.
          tileCache: null,
          atBottomNotifier: atBottomNotifier(channel),
          emptyText: context.l10n.noMatches,
          keyboardDismissBehavior: (!kIsWeb && Platform.isIOS)
              ? ScrollViewKeyboardDismissBehavior.onDrag
              : ScrollViewKeyboardDismissBehavior.manual,
        );
      },
    );
  }

  /// Tab label for [channel], stable across rebuilds (see [_tabCache]).
  /// Selection and unread state stay live inside the merged listenable.
  /// The focused index resolves live from the channel list, so reorder
  /// with the same length can never leave a stale highlight behind.
  Widget _buildTab(BuildContext context, String channel) {
    return _ChannelTab(
      chat: chat,
      channel: channel,
      selectedTabIndex: selectedTabIndex,
      selectedChannel: selectedChannel,
      listenable: _tabSharedMerge,
    );
  }

  /// Edit, split and remove actions for [channel], held from its tab.
  void _showChannelMenu(BuildContext context, String channel) {
    Haptics.press();
    final split = splitPair();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (split == null)
              ListTile(
                leading: const Icon(Icons.splitscreen),
                title: Text(ctx.l10n.splitChannel),
                onTap: () => _afterPop(ctx, () => openSplit(channel)),
              )
            else
              ListTile(
                leading: const Icon(Icons.close),
                title: Text(ctx.l10n.closeSplit),
                onTap: () => _afterPop(ctx, closeSplit),
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(ctx.l10n.editChannel),
              onTap: () {
                Navigator.pop(ctx);
                showEditChannelDialog(
                  context,
                  channel: channel,
                  onSave: (to) => renameChannel(channel, to),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: Text(ctx.l10n.removeChannel),
              onTap: () async {
                final l = ctx.l10n;
                Navigator.pop(ctx);
                final ok = await confirmDialog(
                  context,
                  title: l.removeChannelConfirm(channel),
                  confirmLabel: l.removeChannel,
                  destructive: true,
                );
                if (ok) removeChannel(channel);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Pops the sheet at [sheetContext], then runs [action] after its exit
  /// animation. Rebuilding the split in the pop's own frame eats the slide on
  /// a busy chat, so the sheet looks like it vanishes.
  void _afterPop(BuildContext sheetContext, VoidCallback action) {
    final animation = ModalRoute.of(sheetContext)?.animation;
    Navigator.pop(sheetContext);
    if (animation == null) {
      action();
      return;
    }
    void done(AnimationStatus status) {
      if (status != AnimationStatus.dismissed) return;
      animation.removeStatusListener(done);
      action();
    }

    animation.addStatusListener(done);
  }

  /// Two chat panes, top and bottom. The first slot carries the strip's
  /// clearance once for both.
  Widget _splitBody(BuildContext context, SplitPair split) {
    final first = _splitPane(
      context,
      split.first,
      slot: 0,
      active: split.active == 0,
    );
    final second = _splitPane(
      context,
      split.second,
      slot: 1,
      active: split.active == 1,
    );
    // The composer floats below the split, not over it, so both panes split
    // the room above the island and neither keeps a gap for it.
    return Padding(
      padding: EdgeInsets.only(top: _bubbleClearance(context)),
      child: IslandInset(
        child: Padding(
          padding: const EdgeInsets.only(bottom: kComposerGap),
          child: _SplitLayout(
            first: first,
            second: second,
            axis: Axis.vertical,
          ),
        ),
      ),
    );
  }

  /// A split pane's channel bar. Tapping it focuses that slot.
  Widget _splitHeader(
    BuildContext context,
    String channel, {
    required int slot,
    required bool active,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: active ? scheme.surfaceContainerHigh : scheme.surface,
      child: InkWell(
        onTap: () => focusSplitPane(slot),
        child: SizedBox(
          height: 28,
          child: Row(
            children: [
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '#$channel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: active ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One split pane: its channel header, then its chat. The inactive pane
  /// dims and swallows taps so the first touch only focuses it.
  Widget _splitPane(
    BuildContext context,
    String channel, {
    required int slot,
    required bool active,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        if (!active) focusSplitPane(slot);
      },
      child: AbsorbPointer(
        absorbing: !active,
        child: AnimatedOpacity(
          opacity: active ? 1 : 0.7,
          duration: Motion.fast,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // A pane squeezed below the label plus one chat line keeps the
              // chat and drops the label, so it never overflows.
              final labelled = constraints.maxHeight >= 48;
              return Column(
                children: [
                  if (labelled) ...[
                    _splitHeader(context, channel, slot: slot, active: active),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: scheme.outlineVariant,
                    ),
                  ],
                  Expanded(
                    child: chat.names.isEmpty
                        ? const SizedBox.shrink()
                        : TabbedLayout(
                            tabs: chat.names,
                            selectedIndex: chat.names
                                .indexOf(channel)
                                .clamp(0, chat.names.length - 1),
                            showTabBar: false,
                            fullscreen: true,
                            fastSnap: fastSnap(),
                            focusOnHalfDrag: true,
                            preloadAdjacentPages: true,
                            onFocusChanged: (i) => setSplitPaneChannel(slot, i),
                            onSelectedIndexChanged: (i) =>
                                setSplitPaneChannel(slot, i),
                            pageBuilder: (ctx, i) => _cachedPage(
                              ctx,
                              chat.names[i],
                              clearsIsland: false,
                              slot: slot,
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget channelTabs(
    BuildContext context, {
    required bool hideChrome,
    bool merged = false,
    Widget? belowTabBar,
    bool underStream = false,
  }) {
    return Expanded(
      child: channelStack(
        context,
        hideChrome: hideChrome,
        merged: merged,
        underStream: underStream,
        belowTabBar: belowTabBar,
      ),
    );
  }

  Widget channelStack(
    BuildContext context, {
    required bool hideChrome,
    bool merged = false,
    Widget? belowTabBar,
    bool underStream = false,
  }) {
    _hideChrome = hideChrome;
    _underStream = underStream;
    final split = splitPair();
    _splitMode = split != null;
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
                    pagesKey: pagesKey,
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
                    onTabLongPress: (index) =>
                        _showChannelMenu(context, chat.names[index]),
                    singlePage: split == null
                        ? null
                        : _splitBody(context, split),
                    showTabBar: showStrip,
                    fullscreen: isFullscreen(),
                    pagesOverlay: split != null || selectedChannel() == null
                        ? null
                        : ListenableBuilder(
                            listenable: Listenable.merge([
                              broadcastWidgets.notifier,
                              selectedTabIndex,
                              _swipePage,
                            ]),
                            builder: (_, _) => _broadcastOverlay(),
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
                        ? homeAppBar.stripTrailing(onCalendar: openCalendar)
                        : null,
                    fullscreenMenu: _menuFloats()
                        ? homeAppBar.action(
                            context,
                            ChromeAction.viewMenu,
                            onCalendar: openCalendar,
                          )
                        : null,
                    // A stream above the strip already sits at the top.
                    stripTopInset: merged && !underStream
                        ? statusBarHeight(context)
                        : 0,
                    belowTabBar: belowTabBar,
                    pageBuilder: (_, i) {
                      final channel = chat.names[i];
                      return _cachedPage(context, channel);
                    },
                    focusOnHalfDrag: true,
                    fastSnap: fastSnap(),
                    preloadAdjacentPages: true,
                    tabBuilder: (_, i) {
                      final channel = chat.names[i];
                      final cached = _tabCache[channel];
                      if (cached != null) return cached;
                      final tab = _buildTab(context, channel);
                      _tabCache[channel] = tab;
                      return tab;
                    },
                  ),
                )
              : welcomeChatView(context),
        ),
      ],
    );
  }

  /// The selected channel's broadcast cards; mid-swipe, both channels' cards,
  /// each offset with its page.
  Widget _broadcastOverlay() {
    // Minimizing, restoring and cards coming or going expand and retract
    // from the top edge, with no fade.
    Widget cards(String channel, double room) {
      final overlay = broadcastWidgets.buildOverlay(
        channel,
        room: room,
        onMinimizeChanged: broadcastWidgets.setMinimized,
        unpin: unpinFor(channel),
      );
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: TabbedLayout.cardInset),
        child: AnimatedSize(
          duration: Motion.normal,
          curve: Motion.enter,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: Motion.normal,
            switchInCurve: Motion.enter,
            switchOutCurve: Motion.enter,
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

  Widget welcomeChatView(BuildContext context) {
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
      onShowUserProfile: (ctx, login, userId, {displayName}) => userSheets
          .showUserProfile(ctx, login, userId, displayName: displayName),
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

/// Two panes with a draggable split. The user owns the size; nothing
/// collapses on its own.
class _SplitLayout extends StatefulWidget {
  const _SplitLayout({
    required this.first,
    required this.second,
    required this.axis,
  });

  final Widget first;
  final Widget second;
  final Axis axis;

  @override
  State<_SplitLayout> createState() => _SplitLayoutState();
}

class _SplitLayoutState extends State<_SplitLayout> {
  static const double _handle = 16;

  /// Smallest pane a drag may leave: the label plus a couple of chat lines.
  static const double _minPane = 64;
  double _fraction = 0.5;

  @override
  Widget build(BuildContext context) {
    final portrait = widget.axis == Axis.vertical;
    return LayoutBuilder(
      builder: (context, constraints) {
        final total =
            ((portrait ? constraints.maxHeight : constraints.maxWidth) -
                    _handle)
                .clamp(0.0, double.infinity);
        final minPane = math.min(_minPane, total / 2);
        final first = (total * _fraction).clamp(minPane, total - minPane);
        final second = total - first;
        if (portrait) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: first,
                child: ClipRect(child: widget.first),
              ),
              _handleBox(
                vertical: true,
                onDrag: (delta) => _drag(delta, total),
              ),
              SizedBox(
                height: second,
                child: ClipRect(child: widget.second),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: first,
              child: ClipRect(child: widget.first),
            ),
            _handleBox(vertical: false, onDrag: (delta) => _drag(delta, total)),
            SizedBox(
              width: second,
              child: ClipRect(child: widget.second),
            ),
          ],
        );
      },
    );
  }

  void _drag(double delta, double total) {
    if (total <= 0) return;
    final minFraction = math.min(_minPane / total, 0.5);
    setState(() {
      // Re-clamp first: the room may have shrunk since the last drag.
      final current = _fraction.clamp(minFraction, 1 - minFraction);
      _fraction = (current + delta / total).clamp(minFraction, 1 - minFraction);
    });
  }

  Widget _handleBox({
    required bool vertical,
    required ValueChanged<double> onDrag,
  }) {
    return GestureDetector(
      key: const ValueKey('split_handle'),
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: vertical ? (d) => onDrag(d.delta.dy) : null,
      onHorizontalDragUpdate: vertical ? null : (d) => onDrag(d.delta.dx),
      child: SizedBox(
        width: vertical ? double.infinity : _handle,
        height: vertical ? _handle : double.infinity,
        child: Center(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: Colors.grey,
              borderRadius: BorderRadius.all(Radius.circular(Radii.small)),
            ),
            child: SizedBox(
              width: vertical ? 48 : 4,
              height: vertical ? 4 : 48,
            ),
          ),
        ),
      ),
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
    duration: Motion.normal,
  );
  // One out-and-back pulse per new mention.
  late final Animation<double> _pulse = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 1),
  ]).animate(CurvedAnimation(parent: _flash, curve: Motion.enter));

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
    // Sized to the bold name so selection and unread changes never resize
    // the tab and shift the strip mid-swipe.
    final painter = TextPainter(
      text: TextSpan(
        text: widget.channel,
        style: DefaultTextStyle.of(context).style.merge(
          const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final boldWidth = painter.width.ceilToDouble();
    painter.dispose();
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
            SizedBox(
              width: boldWidth,
              child: Text(
                widget.channel,
                textAlign: TextAlign.center,
                maxLines: 1,
                softWrap: false,
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

/// Search results that keep the previous query's list on screen until the
/// new one has its first rows, so typing never flashes an empty list. A
/// search slower than [_patience] shows its list while it loads.
class _SettledSearch extends StatefulWidget {
  const _SettledSearch({
    super.key,
    required this.query,
    required this.scope,
    required this.empty,
    required this.onEnd,
    required this.source,
    required this.build,
  });

  final String query;
  final ChatSearchScope scope;

  /// Shown while the query is empty, and until the first query settles.
  final Widget empty;

  /// Runs once search closes.
  final VoidCallback onEnd;
  final ArchiveFindSource Function(String query, ChatSearchScope scope) source;
  final Widget Function(
    ArchiveFindSource source,
    List<TwitchMessage>? newest,
    String query,
    ChatSearchScope scope,
  )
  build;

  @override
  State<_SettledSearch> createState() => _SettledSearchState();
}

class _SettledSearchState extends State<_SettledSearch> {
  static const _patience = Duration(milliseconds: 500);

  late String _query = widget.query;
  late ChatSearchScope _scope = widget.scope;
  late ArchiveFindSource? _source = _query.isEmpty
      ? null
      : widget.source(_query, _scope);
  List<TwitchMessage>? _newest;

  @override
  void didUpdateWidget(_SettledSearch old) {
    super.didUpdateWidget(old);
    if (widget.query != old.query || widget.scope != old.scope) _settle();
  }

  Future<void> _settle() async {
    final query = widget.query;
    final scope = widget.scope;
    final source = query.isEmpty ? null : widget.source(query, scope);
    List<TwitchMessage>? newest;
    final held = _newest;
    final q = ChatQuery.parse(query, scope);
    if (source != null &&
        held != null &&
        q.narrows(ChatQuery.parse(_query, _scope))) {
      // Typing on narrows the held rows, so they open at once; older
      // matches load from the archive as the list asks for them.
      newest = [
        for (final m in held)
          if (q.matches(m)) m,
      ];
    }
    // None left could still mean older matches: the archive decides.
    if (source != null && (newest?.isEmpty ?? true)) {
      try {
        await source.prefetch().timeout(_patience);
        // Takes the prefetched rows, so a later newest read hits the archive.
        newest = await source.newest();
      } catch (_) {
        // Slow or failed: the list shows its own loading or error state.
      }
    }
    if (!mounted || widget.query != query || widget.scope != scope) return;
    setState(() {
      _query = query;
      _scope = scope;
      _source = source;
      _newest = newest;
    });
  }

  @override
  void dispose() {
    widget.onEnd();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (_source) {
    final source? => widget.build(source, _newest, _query, _scope),
    null => widget.empty,
  };
}
