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

  /// The tab strip's buttons: full-size icons in a 40pt slot, narrower than
  /// stock so three fit beside the tabs.
  static const double _smallWidth = 40;
  static const double _smallIcon = 24;

  static ButtonStyle? _small(bool small) => small
      ? IconButton.styleFrom(
          fixedSize: const Size(_smallWidth, 40),
          minimumSize: Size.zero,
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        )
      : null;

  Widget mentionsButton(BuildContext context, {bool small = false}) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: chat.mentionsBump,
      builder: (context, _) => IconButton(
        style: _small(small),
        iconSize: small ? _smallIcon : null,
        icon: Icon(
          Icons.notifications_active,
          color: chat.unreadMentions > 0 ? theme.colorScheme.error : null,
        ),
        tooltip: context.l10n.sectionMentions,
        onPressed: _onBellPressed,
      ),
    );
  }

  Widget threadsButton(BuildContext context, {bool small = false}) =>
      IconButton(
        style: _small(small),
        iconSize: small ? _smallIcon : null,
        icon: const Icon(Icons.forum_outlined),
        tooltip: context.l10n.threads,
        onPressed: () => threads.showThreadsDashboard(tab: 1),
      );

  Widget settingsButton(BuildContext context, {bool small = false}) =>
      IconButton(
        style: _small(small),
        iconSize: small ? _smallIcon : null,
        icon: const Icon(Icons.settings),
        tooltip: context.l10n.settingsTitle,
        onPressed: openSettings,
      );

  Widget overflowMenu(
    BuildContext context, {
    bool small = false,
    bool glass = false,
  }) {
    final l10n = context.l10n;
    return ChromeMenu(
      glass: glass,
      entries: () => [
        ChromeMenuEntry(
          l10n.uploadMedia,
          () => uploadController.pickAndUpload(context),
        ),
        ChromeMenuEntry(l10n.reloadEmotes, reloadEmotes),
        ChromeMenuEntry(l10n.reconnect, reconnect),
      ],
      buttonStyle: _small(small) ?? const ButtonStyle(),
      trigger: Icon(Icons.more_vert, size: small ? _smallIcon : null),
    );
  }

  /// The island's button row: [leading] (the composer's emote button) and
  /// the chrome buttons on the left, [trailing] (send) on the right. The
  /// island draws the surface, so the row is bare. [withMenu] adds the view
  /// menu, for when the strip that holds it is hidden.
  Widget bottomBar(
    BuildContext context, {
    bool glass = false,
    Widget? leading,
    List<Widget> trailing = const [],
    bool withMenu = false,
    VoidCallback? onCalendar,
  }) {
    final row = Row(
      children: [
        ?leading,
        settingsButton(context),
        overflowMenu(context, glass: glass),
        threadsButton(context),
        mentionsButton(context),
        if (withMenu) chromeMenu(glass: glass, onCalendar: onCalendar),
        const Spacer(),
        ...trailing,
      ],
    );
    // Narrow islands tighten the 48pt buttons so the row still fits.
    final count =
        4 + (withMenu ? 1 : 0) + (leading == null ? 0 : 1) + trailing.length;
    final fitted = LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= count * 48
          ? row
          : Theme(
              data: Theme.of(
                context,
              ).copyWith(visualDensity: VisualDensity.compact),
              child: row,
            ),
    );
    return KeyedSubtree(key: const Key('bottom_chrome_bar'), child: fitted);
  }

  Widget appBar(BuildContext context, {bool transparent = false}) {
    final theme = Theme.of(context);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                const Spacer(),
                _joinButton(),
                mentionsButton(context),
                overflowMenu(context),
                settingsButton(context),
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
