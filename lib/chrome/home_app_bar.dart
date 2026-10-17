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

  bool _isChannelLive(String channel) =>
      chat.channelFor(channel)?.info.isLive ?? false;

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
      showStreamToggle: () =>
          streamPlayer.isActive ||
          !twitchAuth.isConfigured ||
          (selectedChannel() != null && _isChannelLive(selectedChannel()!)),
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
          icon: busy ? _joinSpinner(context) : const Icon(Icons.add),
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

  /// The ⋮ menu. Settings heads it when the theme folds it in, and threads
  /// joins it when the theme places no threads button.
  Widget overflowMenu(BuildContext context, {bool glass = false}) {
    final l10n = context.l10n;
    return ChromeMenu(
      glass: glass,
      entries: () => [
        if (themeSpec().settingsInMenu) ...[
          ChromeMenuEntry(
            l10n.settingsTitle,
            openSettings,
            icon: Icons.settings,
          ),
          const ChromeMenuEntry.divider(),
        ],
        if (!themeSpec().places(ChromeAction.threads))
          ChromeMenuEntry(
            l10n.threads,
            () => threads.showThreadsDashboard(tab: 1),
          ),
        ChromeMenuEntry(
          l10n.uploadMedia,
          () => uploadController.pickAndUpload(context),
        ),
        ChromeMenuEntry(l10n.reloadEmotes, reloadEmotes),
        ChromeMenuEntry(l10n.reconnect, reconnect),
      ],
      buttonStyle: const ButtonStyle(),
      trigger: const Icon(Icons.more_vert),
    );
  }

  /// The island's button row: [leading] (the composer's emote button), the
  /// theme's row actions, then [trailing] (send) on the right. The island
  /// draws the surface, so the row is bare. [withMenu] adds the view menu,
  /// for when the strip that holds it is hidden.
  Widget bottomBar(
    BuildContext context, {
    bool glass = false,
    Widget? leading,
    List<Widget> trailing = const [],
    bool withMenu = false,
    VoidCallback? onCalendar,
  }) {
    final spec = themeSpec();
    final actions = [
      for (final a in spec.rowActions) action(context, a, glass: glass),
      if (withMenu) chromeMenu(glass: glass, onCalendar: onCalendar),
    ];
    final row = Row(
      children: [
        ?leading,
        if (spec.rowActionsRight) const Spacer(),
        ...actions,
        if (!spec.rowActionsRight) const Spacer(),
        ...trailing,
      ],
    );
    // Narrow islands tighten the 48pt buttons so the row still fits.
    final count = actions.length + (leading == null ? 0 : 1) + trailing.length;
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
    return KeyedSubtree(
      key: const Key('bottom_chrome_bar'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _rowInset),
        child: fitted,
      ),
    );
  }

  /// The top app bar: the theme's, or with no channels (no strip to hold
  /// the actions) join, the bell, ⋮ and settings.
  Widget appBar(BuildContext context, {bool transparent = false}) {
    final theme = Theme.of(context);
    final spec = themeSpec();
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
            child: Row(
              children: [
                if (spec.appBarTitle)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      context.l10n.appTitle,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                const Spacer(),
                for (final a in actions) action(context, a),
              ],
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
