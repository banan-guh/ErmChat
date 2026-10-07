import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../composer/composer_controller.dart';
import '../l10n/l10n.dart';
import '../models/twitch_message.dart';
import '../panels/search.dart';
import '../panels/threads.dart';
import '../chat/chat.dart';
import '../services/link_whitelist.dart';
import '../widgets/seven_tv_paint_service.dart';
import '../services/twitch_auth.dart';
import '../sheets/message_menu.dart';
import '../sheets/user_sheet.dart';
import '../util/insets.dart';
import '../eventsub/decode/events.dart' show PinnedMessageEvent;
import '../services/mod_actions.dart' show ModResult;
import '../widgets/broadcast_widgets.dart';
import '../widgets/chat_view.dart';
import '../widgets/glass_chrome.dart';
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
  });

  static const welcomeChannel = '__welcome__';

  final Chat chat;
  final Map<String, Map<String?, Widget>> tileCache;
  final MessageBuilder messageBuilder;
  final LinkWhitelist linkWhitelist;
  final TwitchAuth twitchAuth;
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
      builder: (_, active) => ChatView(
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
        onShowUserProfile: (login, userId, {displayName}) => userSheets
            .showUserProfile(context, login, userId, displayName: displayName),
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

  /// Tab label for [channel], stable across rebuilds (see [_tabCache]).
  /// Selection and unread state stay live inside the merged listenable.
  /// The focused index resolves live from the channel list, so reorder
  /// with the same length can never leave a stale highlight behind.
  Widget _buildTab(String channel) {
    return ListenableBuilder(
      listenable: _tabSharedMerge,
      builder: (ctx, _) {
        final focused = chat.names.indexOf(channel) == selectedTabIndex.value;
        final selected = focused || channel == selectedChannel();
        final hasUnreadMention =
            chat.channelFor(channel)?.unread.hasMention ?? false;
        final theme = Theme.of(ctx);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Text(
              channel,
              style: TextStyle(
                fontSize: 14,
                fontWeight:
                    selected ||
                        (chat.channelFor(channel)?.unread.hasUnread ?? false)
                    ? FontWeight.w600
                    : FontWeight.normal,
                color: selected
                    ? theme.colorScheme.primary
                    : (chat.channelFor(channel)?.unread.hasUnread ?? false)
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
  }

  Widget channelTabs(
    BuildContext context, {
    required bool hideChrome,
    bool merged = false,
    double overlayTop = 50,
    Widget? belowTabBar,
    bool glassOverlay = false,
    bool glassChrome = false,
    Widget? glassHeader,
    double glassHeaderHeight = 0,
    double glassTopPadding = 0,
  }) {
    return Expanded(
      child: channelStack(
        context,
        hideChrome: hideChrome,
        merged: merged,
        overlayTop: overlayTop,
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
    required double overlayTop,
    Widget? belowTabBar,
    bool glassOverlay = false,
    bool glassChrome = false,
    Widget? glassHeader,
    double glassHeaderHeight = 0,
    double glassTopPadding = 0,
  }) {
    _dropStaleCaches();
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
                      final ctrl = scrollCtrl(channel);
                      if (ctrl.hasClients) ctrl.jumpTo(0);
                      atBottomNotifier(channel).value = true;
                    },
                    showTabBar: !isFullscreen() && !hideChrome,
                    fullscreen: isFullscreen(),
                    chromeMenu: homeAppBar.chromeMenu(
                      glass: glassOverlay || glassChrome,
                    ),
                    // Compact merges the app bar into the strip: join as the
                    // last tab, the other actions pinned on the right.
                    addTab: merged ? homeAppBar.joinTab() : null,
                    onAddTab: homeAppBar.onJoinTab,
                    stripTrailing: merged
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              homeAppBar.mentionsButton(context),
                              homeAppBar.overflowMenu(context),
                            ],
                          )
                        : null,
                    stripTopInset: merged ? statusBarHeight(context) : 0,
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
                      child: glassHeaderSlot(
                        hidden: isFullscreen(),
                        child: glassBar(
                          dark: Theme.of(context).brightness == Brightness.dark,
                          child: glassHeader,
                        ),
                      ),
                    ),
                  ],
                )
              : welcomeChatView(context),
        ),
        if (selectedChannel() != null)
          Positioned(
            top: overlayTop,
            left: 0,
            right: 0,
            child: ListenableBuilder(
              listenable: Listenable.merge([
                broadcastWidgets.notifier,
                selectedTabIndex,
                _swipePage,
              ]),
              builder: (_, _) => _broadcastOverlay(
                glassEnabled(context, glassOverlay || glassChrome),
              ),
            ),
          ),
      ],
    );
  }

  /// The selected channel's broadcast cards; mid-swipe, both channels' cards,
  /// each offset with its page.
  Widget _broadcastOverlay(bool glass) {
    Widget cards(String channel) =>
        broadcastWidgets.buildOverlay(
          channel,
          onMinimizeChanged: broadcastWidgets.setMinimized,
          glass: glass,
          unpin: unpinFor(channel),
        ) ??
        const SizedBox.shrink();
    final names = chat.names;
    final page = _swipePage.value;
    final left = page?.floor() ?? -1;
    final t = page == null ? 0.0 : page - left;
    if (t < 0.001 || t > 0.999 || left < 0 || left + 1 >= names.length) {
      final channel = selectedChannel();
      return channel == null
          ? const SizedBox.shrink()
          : KeyedSubtree(key: ValueKey(channel), child: cards(channel));
    }
    return LayoutBuilder(
      builder: (_, constraints) {
        final width = constraints.maxWidth;
        return ClipRect(
          child: Stack(
            children: [
              for (final (i, dx) in [(left, -t), (left + 1, 1 - t)])
                Transform.translate(
                  key: ValueKey(names[i]),
                  offset: Offset(dx * width, 0),
                  child: cards(names[i]),
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
