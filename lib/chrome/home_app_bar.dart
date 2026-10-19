import 'dart:math' as math;

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
import 'layout_editor.dart';
import '../widgets/chrome_menu_button.dart';
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
    required this.toggleFullscreen,
    required this.toggleInput,
    required this.toggleStream,
    required this.toggleSearch,
    required this.reloadEmotes,
    required this.reconnect,
    required this.openSettings,
    required this.themeSpec,
    required this.layoutEdit,
    required this.editLayout,
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
  final VoidCallback toggleFullscreen;
  final VoidCallback toggleInput;
  final VoidCallback toggleStream;
  final VoidCallback toggleSearch;
  final VoidCallback reloadEmotes;
  final VoidCallback reconnect;
  final VoidCallback openSettings;

  /// The chrome theme: which actions sit where.
  final ChromeThemeSpec Function() themeSpec;

  /// The layout editor while edit mode is on, else null. The slots then
  /// render as editable chips instead of working buttons.
  final LayoutEditController? Function() layoutEdit;
  final VoidCallback editLayout;

  bool _isChannelLive(String channel) =>
      chat.channelFor(channel)?.info.isLive ?? false;

  /// Whether the view menu offers the stream toggle: a running stream, no
  /// login to fetch one, or a live channel.
  bool _showStreamToggle() =>
      streamPlayer.isActive ||
      !twitchAuth.isConfigured ||
      (selectedChannel() != null && _isChannelLive(selectedChannel()!));

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
  Widget chromeMenu({bool glass = false, VoidCallback? onCalendar}) {
    return ChromeMenuButton(
      glass: glass,
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
            chatConn.isAutomodActive(channel);
      },
      onToggleSearch: toggleSearch,
    );
  }

  /// One chrome button, wherever the theme places it.
  Widget action(
    BuildContext context,
    ChromeAction action, {
    bool glass = false,
    VoidCallback? onCalendar,
  }) => switch (action) {
    ChromeAction.join => _joinButton(),
    ChromeAction.mentions => mentionsButton(context),
    ChromeAction.threads => threadsButton(context),
    ChromeAction.settings => settingsButton(context),
    ChromeAction.overflow => overflowMenu(context, glass: glass),
    ChromeAction.viewMenu => chromeMenu(glass: glass, onCalendar: onCalendar),
  };

  /// The strip's end: the theme's strip actions.
  Widget stripTrailing({bool glass = false, VoidCallback? onCalendar}) {
    if (layoutEdit() case final edit?) {
      return LayoutSlotView(controller: edit, slot: LayoutSlot.strip);
    }
    final actions = themeSpec().stripActions;
    return Builder(
      builder: (context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final a in actions)
            action(context, a, glass: glass, onCalendar: onCalendar),
        ],
      ),
    );
  }

  /// Whether the strip ends in a join tab: only when no action places join.
  bool get stripJoinTab => !themeSpec().places(ChromeAction.join);

  bool _joinBusy() =>
      !disableJoinSpinner() && (chatLoading() || networkBusy.value);

  Listenable get _joinBusyListenable =>
      Listenable.merge([chatConn.connectionStateNotifier, networkBusy]);

  Widget _joinButton() {
    return ListenableBuilder(
      listenable: _joinBusyListenable,
      builder: (context, _) {
        final busy = _joinBusy();
        return IconButton(
          // A theme with a loading bar keeps the plain + while the row
          // that carries the bar shows.
          icon: busy && !(themeSpec().busyBar && chat.length > 0)
              ? _joinSpinner(context)
              : const Icon(Icons.add),
          tooltip: busy
              ? context.l10n.loadingEllipsis
              : context.l10n.joinChannel,
          onPressed: busy || chat.length >= kMaxChannels
              ? null
              : addChannelDialog,
        );
      },
    );
  }

  Widget _joinSpinner(BuildContext context) => SizedBox(
    width: 24,
    height: 24,
    child: CircularProgressIndicator(
      strokeWidth: 2,
      color: IconTheme.of(context).color,
    ),
  );

  /// Label for the compact layout's trailing join tab.
  Widget joinTab() {
    return ListenableBuilder(
      listenable: _joinBusyListenable,
      builder: (context, _) {
        if (_joinBusy()) return _joinSpinner(context);
        return Tooltip(
          message: context.l10n.joinChannel,
          child: Icon(
            Icons.add,
            color: chat.length >= kMaxChannels
                ? Theme.of(context).disabledColor
                : null,
          ),
        );
      },
    );
  }

  /// Join tab tap: same gating as the top bar button.
  void onJoinTab() {
    if (_joinBusy() || chat.length >= kMaxChannels) return;
    addChannelDialog();
  }

  /// The button row's side inset, matching the field's, so the row's end
  /// buttons line up under the field's emote and send.
  static const double _rowInset = 8;

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
  Widget overflowMenu(BuildContext context, {bool glass = false}) {
    final l10n = context.l10n;
    final spec = themeSpec();
    return ChromeMenu(
      glass: glass,
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
          ),
        if (!spec.places(ChromeAction.mentions))
          ChromeMenuEntry(l10n.sectionMentions, _onBellPressed),
        if (!spec.places(ChromeAction.viewMenu)) ...[
          ChromeMenuEntry(l10n.search, toggleSearch),
          ChromeMenuEntry(l10n.toggleFullscreen, toggleFullscreen),
          ChromeMenuEntry(l10n.toggleInput, toggleInput),
          if (_showStreamToggle())
            ChromeMenuEntry(
              streamPlayer.isActive ? l10n.hideStream : l10n.showStream,
              toggleStream,
            ),
        ],
        ChromeMenuEntry(
          l10n.uploadMedia,
          () => uploadController.pickAndUpload(context),
        ),
        ChromeMenuEntry(l10n.reloadEmotes, reloadEmotes),
        ChromeMenuEntry(l10n.reconnect, reconnect),
        ChromeMenuEntry(l10n.settingEditLayout, editLayout),
      ],
      buttonStyle: const ButtonStyle(),
      trigger: const Icon(Icons.more_vert),
    );
  }

  /// The island's button row: [leading] (the composer's emote button), the
  /// theme's row actions, then [trailing] (send) on the right. The island
  /// draws the surface, so the row is bare. [withMenu] adds the view menu,
  /// for when the strip that holds it is hidden. [middle] fills the free
  /// space between the buttons.
  Widget bottomBar(
    BuildContext context, {
    bool glass = false,
    Widget? leading,
    Widget? middle,
    List<Widget> trailing = const [],
    bool withMenu = false,
    VoidCallback? onCalendar,
  }) {
    final spec = themeSpec();
    Widget build(ChromeAction a) =>
        action(context, a, glass: glass, onCalendar: onCalendar);
    if (layoutEdit() case final edit?) {
      // Each slot scales down rather than overflow the island.
      Widget slot(LayoutSlot s) => Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: LayoutSlotView(controller: edit, slot: s),
        ),
      );
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
                    slot(LayoutSlot.rowStart),
                    slot(LayoutSlot.rowEnd),
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
    final end = [
      for (final a in spec.rowEnd) build(a),
      if (withMenu && !spec.rowActions.contains(ChromeAction.viewMenu))
        chromeMenu(glass: glass, onCalendar: onCalendar),
    ];
    // The action groups sit a little closer than the stock 48pt; the leading
    // and trailing slots keep it, lining up with the field's emote and send.
    // A narrow island's compact density still wins.
    Widget group(List<Widget> actions) => actions.isEmpty
        ? const SizedBox.shrink()
        : Builder(
            builder: (context) {
              final theme = Theme.of(context);
              final density = theme.visualDensity;
              return Theme(
                data: theme.copyWith(
                  visualDensity: VisualDensity(
                    horizontal: math.min(density.horizontal, -1),
                    vertical: density.vertical,
                  ),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: actions),
              );
            },
          );
    final row = Row(
      children: [
        ?leading,
        group(start),
        Expanded(child: middle ?? const SizedBox.shrink()),
        group(end),
        ...trailing,
      ],
    );
    // Narrow islands tighten the 48pt buttons so the row still fits.
    final count =
        start.length + end.length + (leading == null ? 0 : 1) + trailing.length;
    final fitted = LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth >= count * 48 + 2 * _rowInset
          ? row
          : Theme(
              data: Theme.of(
                context,
              ).copyWith(visualDensity: VisualDensity.compact),
              child: row,
            ),
    );
    // Inset like the field, so the row's end buttons line up under the
    // field's emote and send.
    final inset = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _rowInset),
      child: fitted,
    );
    return KeyedSubtree(
      key: const Key('bottom_chrome_bar'),
      // The loading bar overlays the row's top edge, so it costs no height.
      child: !spec.busyBar
          ? inset
          : Stack(
              children: [
                inset,
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: ListenableBuilder(
                    listenable: _joinBusyListenable,
                    builder: (context, _) => _joinBusy()
                        ? const LinearProgressIndicator(minHeight: 2)
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
    );
  }

  /// The top app bar: the theme's, or with no channels (no strip to hold
  /// the actions) join, the bell, ⋮ and settings.
  Widget appBar(BuildContext context, {bool transparent = false}) {
    final theme = Theme.of(context);
    final spec = themeSpec();
    final edit = spec.header == HeaderStyle.appBar ? layoutEdit() : null;
    final actions = spec.header == HeaderStyle.appBar
        ? spec.appBarActions
        : [
            ChromeAction.join,
            ChromeAction.mentions,
            ChromeAction.overflow,
            if (!spec.settingsInMenu) ChromeAction.settings,
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
                  if (edit != null)
                    LayoutSlotView(controller: edit, slot: LayoutSlot.appBar)
                  else
                    for (final a in actions) action(context, a),
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
