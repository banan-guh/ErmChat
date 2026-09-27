import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
      (chat.channelFor(channel)?.info.status ?? '').contains('Live');

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

  /// Tiny arrow anchored top-right just below the channel tab strip (see
  /// TabbedLayout). Always visible so the top bar / input can be toggled back
  /// even in fullscreen.
  Widget chromeMenu({bool glass = false}) {
    return ChromeMenuButton(
      glass: glass,
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
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    'ErmChat',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w400),
                  ),
                ),
                const Spacer(),
                ListenableBuilder(
                  listenable: Listenable.merge([
                    chatConn.connectionStateNotifier,
                    networkBusy,
                  ]),
                  builder: (context, _) {
                    final busy =
                        !disableJoinSpinner() &&
                        (chatLoading() || networkBusy.value);
                    return IconButton(
                      icon: busy
                          ? SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: IconTheme.of(context).color,
                              ),
                            )
                          : const Icon(Icons.add),
                      tooltip: busy ? 'Loading...' : 'Join channel',
                      onPressed: busy || chat.length >= kMaxChannels
                          ? null
                          : addChannelDialog,
                    );
                  },
                ),
                ListenableBuilder(
                  listenable: chat.mentionsBump,
                  builder: (context, _) => IconButton(
                    icon: Icon(
                      Icons.notifications_active,
                      color: chat.unreadMentions > 0
                          ? theme.colorScheme.error
                          : null,
                    ),
                    tooltip: 'Mentions',
                    onPressed: _onBellPressed,
                  ),
                ),
                PopupMenuButton<String>(
                  popUpAnimationStyle: const AnimationStyle(
                    duration: Duration(milliseconds: 175),
                  ),
                  onSelected: (value) {
                    switch (value) {
                      case 'threads':
                        threads.showThreadsDashboard(tab: 1);
                        break;
                      case 'upload':
                        uploadController.pickAndUpload(context);
                        break;
                      case 'reload_emotes':
                        reloadEmotes();
                        break;
                      case 'reconnect':
                        reconnect();
                        break;
                      case 'settings':
                        openSettings();
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'settings',
                      child: Row(
                        children: [
                          Icon(Icons.settings, size: 20),
                          SizedBox(width: 12),
                          Text('Settings'),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'threads',
                      child: Text('Threads'),
                    ),
                    const PopupMenuItem(
                      value: 'upload',
                      child: Text('Upload media'),
                    ),
                    const PopupMenuItem(
                      value: 'reload_emotes',
                      child: Text('Reload emotes'),
                    ),
                    const PopupMenuItem(
                      value: 'reconnect',
                      child: Text('Reconnect'),
                    ),
                  ],
                  child: GestureDetector(
                    onLongPress: openSettings,
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.more_vert),
                    ),
                  ),
                ),
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
