import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../panels/mentions.dart';
import '../panels/mod_panel.dart';
import '../panels/threads.dart';
import '../services/chat_connection_manager.dart';
import '../chat/chat.dart';
import '../services/stream_player_controller.dart';
import '../services/twitch_auth.dart';
import '../util/chrome_theme.dart';
import '../util/constants.dart';
import '../util/settings.dart';
import 'layout_editor.dart';
import '../widgets/chrome_menu_button.dart';
import '../widgets/clear_message_button.dart';
import '../widgets/island_metrics.dart' show kComposerIslandBottomInset;
import '../widgets/media_upload_controller.dart';
import '../widgets/panel_manager.dart';

// Top app bar, chrome menu arrow, and their toggle/menu verbs.
class HomeAppBar {
  HomeAppBar({
    required this.chat,
    required this.chatConn,
    required this.networkBusy,
    required this.twitchAuth,
    required this.streamPlayer,
    required this.uploadController,
    required this.mentions,
    required this.mod,
    required this.threads,
    required this.activePanel,
    required this.closePanel,
    required this.chatLoading,
    required this.disableJoinSpinner,
    required this.selectedChannel,
    required this.isMounted,
    required this.markDirty,
    required this.addChannelDialog,
    required this.onHistory,
    required this.toggleFullscreen,
    required this.toggleInput,
    required this.toggleStream,
    required this.toggleSearch,
    required this.reloadEmotes,
    required this.reloadAllEmotes,
    required this.reconnect,
    required this.openSettings,
    required this.themeSpec,
    required this.layoutEdit,
    required this.editLayout,
    required this.messageController,
  });

  final Chat chat;
  final ChatConnectionManager chatConn;
  final ValueListenable<bool> networkBusy;
  final TwitchAuth twitchAuth;
  final StreamPlayerController streamPlayer;
  final MediaUploadController uploadController;
  final MentionsPanels mentions;
  final ModPanels mod;
  final ThreadPanels threads;
  final OverlayPanel Function() activePanel;
  final Future<void> Function() closePanel;
  final bool Function() chatLoading;
  final bool Function() disableJoinSpinner;
  final String? Function() selectedChannel;
  final bool Function() isMounted;
  final VoidCallback markDirty;
  final VoidCallback addChannelDialog;
  final VoidCallback onHistory;
  final VoidCallback toggleFullscreen;
  final VoidCallback toggleInput;
  final VoidCallback toggleStream;
  final VoidCallback toggleSearch;
  final VoidCallback reloadEmotes;
  final VoidCallback reloadAllEmotes;
  final VoidCallback reconnect;
  final VoidCallback openSettings;

  /// The chrome theme: which actions sit where.
  final ChromeThemeSpec Function() themeSpec;

  /// The layout editor while edit mode is on, else null. The slots then
  /// render as editable chips instead of working buttons.
  final LayoutEditController? Function() layoutEdit;
  final VoidCallback editLayout;

  /// The chat field's text, for the clear action when a theme places it
  /// outside the field.
  final TextEditingController messageController;

  bool _isChannelLive(String channel) =>
      chat.channelFor(channel)?.info.isLive ?? false;

  /// Whether the view menu offers the stream toggle: a running stream, no
  /// login to fetch one, or a live channel. The dev setting offers it on any
  /// selected channel, so an offline channel's player can be opened too.
  bool _showStreamToggle() =>
      streamPlayer.isActive ||
      !twitchAuth.isConfigured ||
      (selectedChannel() != null &&
          (_isChannelLive(selectedChannel()!) ||
              Settings.devShowOfflineStream.value));

  void _onBellPressed() {
    chat.clearAllUnread();
    mentions.clearUnreadWhispers();
    if (isMounted()) markDirty();
    if (activePanel() == OverlayPanel.mentions) {
      unawaited(closePanel());
    } else {
      mentions.showMentionsView();
    }
  }

  /// The view menu in the button row. The row outlives fullscreen and a
  /// hidden input, so the menu can always bring them back.
  Widget chromeMenu({VoidCallback? onCalendar}) {
    return ChromeMenuButton(
      onCalendar: onCalendar,
      onToggleFullscreen: toggleFullscreen,
      onToggleInput: toggleInput,
      onToggleStream: toggleStream,
      showStreamToggle: _showStreamToggle,
      streamActive: () => streamPlayer.isActive,
      onShowModView: mod.showModView,
      showModView: () {
        final channel = selectedChannel();
        if (channel == null) return false;
        return chatConn.isModerationActive(channel) ||
            chatConn.isAutomodActive(channel) ||
            mod.devModViewFor(channel);
      },
      onToggleSearch: toggleSearch,
    );
  }

  /// One chrome button, wherever the theme places it.
  Widget action(
    BuildContext context,
    ChromeAction action, {
    VoidCallback? onCalendar,
  }) => switch (action) {
    ChromeAction.join => _joinButton(),
    ChromeAction.mentions => mentionsButton(context),
    ChromeAction.threads => threadsButton(context),
    ChromeAction.settings => settingsButton(context),
    ChromeAction.overflow => overflowMenu(context),
    ChromeAction.history => _historyButton(context),
    ChromeAction.viewMenu => chromeMenu(onCalendar: onCalendar),
    ChromeAction.clear => ClearMessageButton(controller: messageController),
  };

  /// The strip's end: the theme's strip actions.
  Widget stripTrailing({VoidCallback? onCalendar}) {
    if (layoutEdit() case final edit?) {
      // The end target needs room, or the screen edge clips it.
      return Padding(
        padding: const EdgeInsetsDirectional.only(end: 8),
        child: LayoutSlotView(controller: edit, slot: LayoutSlot.strip),
      );
    }
    final actions = themeSpec().stripActions;
    return Builder(
      builder: (context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final a in actions) action(context, a, onCalendar: onCalendar),
        ],
      ),
    );
  }

  /// Whether the strip ends in a join tab: only when no action places join.
  bool get stripJoinTab => !themeSpec().places(ChromeAction.join);

  bool joinBusy() =>
      !disableJoinSpinner() && (chatLoading() || networkBusy.value);

  Listenable get joinBusyListenable =>
      Listenable.merge([chatConn.connectionStateNotifier, networkBusy]);

  Widget _historyButton(BuildContext context) => IconButton(
    icon: const Icon(Icons.history),
    tooltip: context.l10n.sentHistoryTitle,
    onPressed: onHistory,
  );

  Widget _joinButton() {
    return ListenableBuilder(
      listenable: joinBusyListenable,
      builder: (context, _) {
        final busy = joinBusy();
        return IconButton(
          icon: const Icon(Icons.add),
          tooltip: busy
              ? context.l10n.loadingEllipsis
              : context.l10n.addChannels,
          onPressed: busy || chat.length >= kMaxChannels
              ? null
              : addChannelDialog,
        );
      },
    );
  }

  /// Label for the compact layout's trailing join tab.
  Widget joinTab(BuildContext context) {
    return Tooltip(
      message: context.l10n.addChannels,
      child: Icon(
        Icons.add,
        color: chat.length >= kMaxChannels
            ? Theme.of(context).disabledColor
            : null,
      ),
    );
  }

  /// Join tab tap: same gating as the top bar button.
  void onJoinTab() {
    if (joinBusy() || chat.length >= kMaxChannels) return;
    addChannelDialog();
  }

  /// The button row's side inset, aligning its 44pt glyphs with the field's
  /// 48pt icon boxes, so the row's end buttons line up under the field's
  /// emote and send.
  static const double _rowInset = 10;

  Widget mentionsButton(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: chat.mentionsBump,
      builder: (context, _) => IconButton(
        icon: Icon(
          Icons.notifications_active,
          color: chat.unreadMentions > 0 ? theme.colorScheme.error : null,
        ),
        tooltip: context.l10n.sectionMentions,
        onPressed: _onBellPressed,
      ),
    );
  }

  Widget threadsButton(BuildContext context) => IconButton(
    icon: const Icon(Icons.forum_outlined),
    tooltip: context.l10n.threads,
    // Toggles, like the bell: a second tap closes the open threads panel.
    onPressed: () => activePanel() == OverlayPanel.thread
        ? unawaited(closePanel())
        : threads.showThreadsDashboard(tab: 1),
  );

  Widget settingsButton(BuildContext context) => IconButton(
    icon: const Icon(Icons.settings),
    tooltip: context.l10n.settingsTitle,
    onPressed: openSettings,
  );

  /// The ⋮ menu. Settings heads it when the theme folds it in; threads,
  /// mentions and the view menu's entries join it when the theme places no
  /// button for them, so none of them can go missing.
  Widget overflowMenu(BuildContext context) {
    final l10n = context.l10n;
    final spec = themeSpec();
    return ChromeMenu(
      entries: () => [
        if (spec.settingsInMenu) ...[
          ChromeMenuEntry(
            l10n.settingsTitle,
            openSettings,
            icon: Icons.settings,
          ),
          const ChromeMenuEntry.divider(),
        ],
        if (!spec.places(ChromeAction.threads))
          ChromeMenuEntry(
            l10n.threads,
            () => threads.showThreadsDashboard(tab: 1),
            icon: Icons.forum_outlined,
          ),
        if (!spec.places(ChromeAction.mentions))
          ChromeMenuEntry(
            l10n.sectionMentions,
            _onBellPressed,
            icon: Icons.notifications_none,
          ),
        if (!spec.places(ChromeAction.viewMenu)) ...[
          ChromeMenuEntry(l10n.search, toggleSearch, icon: Icons.search),
          ChromeMenuEntry(
            l10n.toggleFullscreen,
            toggleFullscreen,
            icon: Icons.fullscreen,
          ),
          ChromeMenuEntry(
            l10n.toggleInput,
            toggleInput,
            icon: Icons.keyboard_outlined,
          ),
          if (_showStreamToggle())
            ChromeMenuEntry(
              streamPlayer.isActive ? l10n.hideStream : l10n.showStream,
              toggleStream,
              icon: Icons.live_tv_outlined,
            ),
        ],
        ChromeMenuEntry(
          l10n.uploadMedia,
          () => uploadController.pickAndUpload(context),
          icon: Icons.upload_outlined,
        ),
        ChromeMenuEntry(
          l10n.reloadEmotes,
          reloadEmotes,
          icon: Icons.emoji_emotions_outlined,
        ),
        ChromeMenuEntry(
          l10n.reloadAllEmotes,
          reloadAllEmotes,
          icon: Icons.emoji_emotions_outlined,
        ),
        ChromeMenuEntry(l10n.reconnect, reconnect, icon: Icons.sync),
        ChromeMenuEntry(
          l10n.settingEditLayout,
          editLayout,
          icon: Icons.dashboard_customize_outlined,
        ),
      ],
      buttonStyle: const ButtonStyle(),
      trigger: const Icon(Icons.more_vert),
    );
  }

  /// The island's button row: [leading] (the composer's emote button), the
  /// theme's row actions, then [trailing] (send) on the right. The island
  /// draws the surface, so the row is bare. [middle] fills the free space
  /// between the buttons.
  Widget bottomBar(
    BuildContext context, {
    Widget? leading,
    Widget? middle,
    List<Widget> trailing = const [],
    VoidCallback? onCalendar,
  }) {
    final spec = themeSpec();
    Widget build(ChromeAction a) => action(context, a, onCalendar: onCalendar);
    if (layoutEdit() case final edit?) {
      return KeyedSubtree(
        key: const Key('bottom_chrome_bar'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: _rowInset),
          child: Row(
            children: [
              ?leading,
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: LayoutSlotView(
                        controller: edit,
                        slot: LayoutSlot.rowStart,
                      ),
                    ),
                    LayoutSlotView(controller: edit, slot: LayoutSlot.rowEnd),
                  ],
                ),
              ),
              ...trailing,
            ],
          ),
        ),
      );
    }
    final start = [for (final a in spec.rowStart) build(a)];
    final end = [for (final a in spec.rowEnd) build(a)];
    Widget group(List<Widget> actions) => actions.isEmpty
        ? const SizedBox.shrink()
        : Row(mainAxisSize: MainAxisSize.min, children: actions);
    // The row runs at 44pt so it and the field stay short: every button
    // loses the stock vertical padding and its 48pt minimum, but keeps
    // enough air for the icons not to crowd.
    final row = IconButtonTheme(
      data: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(44),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      child: Row(
        children: [
          ?leading,
          group(start),
          Expanded(child: middle ?? const SizedBox.shrink()),
          group(end),
          ...trailing,
        ],
      ),
    );
    // Inset like the field, so the row's end buttons line up under the
    // field's emote and send. The bottom inset keeps the row's icons off the
    // island's rim by the same air the field's top icons have.
    final inset = Padding(
      padding: EdgeInsets.fromLTRB(
        _rowInset,
        0,
        _rowInset,
        kComposerIslandBottomInset,
      ),
      child: row,
    );
    return KeyedSubtree(key: const Key('bottom_chrome_bar'), child: inset);
  }

  /// The top app bar: the theme's, or with no channels (no strip to hold
  /// the actions) join, the bell, ⋮ and settings.
  Widget appBar(BuildContext context, {bool transparent = false}) {
    final theme = Theme.of(context);
    final spec = themeSpec();
    final edit = layoutEdit();
    final appBarHeader = spec.header == HeaderStyle.appBar;
    // With no channels there is no strip, so this bar stands in for it: a
    // strip theme's join tab as a button, then the strip's own actions.
    final stripless = chat.length == 0;
    final stripJoin = stripless && !appBarHeader && stripJoinTab;
    final actions = [
      if (appBarHeader) ...spec.appBarActions,
      if (stripJoin) ChromeAction.join,
      if (stripless) ...spec.stripActions,
    ];
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                children: [
                  if (edit == null &&
                      appTitleFits(
                        context,
                        constraints.maxWidth,
                        actions.length,
                      ))
                    Padding(
                      padding: const EdgeInsets.only(left: _titleInset),
                      child: Text(
                        context.l10n.appTitle,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  const Spacer(),
                  if (edit == null)
                    for (final a in actions) action(context, a)
                  else ...[
                    if (appBarHeader)
                      LayoutSlotView(controller: edit, slot: LayoutSlot.appBar),
                    if (stripJoin) action(context, ChromeAction.join),
                    if (stripless) stripTrailing(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
    if (transparent) return content;
    return ColoredBox(
      color: theme.colorScheme.surfaceContainer,
      child: content,
    );
  }
}

const double _titleInset = 12;

/// Whether the app's name fits an app bar [width] wide beside [buttons]
/// 48pt buttons. A crowded bar drops the name rather than squeezing it.
bool appTitleFits(BuildContext context, double width, int buttons) {
  final title = TextPainter(
    text: TextSpan(
      text: context.l10n.appTitle,
      style: Theme.of(context).textTheme.titleLarge,
    ),
    textScaler: MediaQuery.textScalerOf(context),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final needed = _titleInset + title.width + 16 + buttons * 48;
  title.dispose();
  return needed <= width;
}
