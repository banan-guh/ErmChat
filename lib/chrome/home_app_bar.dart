import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../composer/composer_controller.dart';
import '../panels/mentions.dart';
import '../panels/mod_panel.dart';
import '../panels/threads.dart';
import '../services/chat_connection_manager.dart';
import '../services/chat_store.dart';
import '../services/stream_player_controller.dart';
import '../services/twitch_auth.dart';
import '../util/constants.dart';
import '../widgets/chrome_menu_button.dart';
import '../widgets/media_upload_controller.dart';
import '../widgets/panel_manager.dart';

// Shell-owned state the home app bar reads but does not own.
abstract class HomeAppBarHost extends ShellState {
  bool isMounted();
  void markDirty();
  OverlayPanel get activePanel;
  Future<void> closePanel();
  bool get chatLoading;
  bool get disableJoinSpinner;
  bool get isFullscreen;
  void addChannelDialog();
  void toggleFullscreen();
  void toggleInput();
  void toggleStream();
  void reloadEmotes();
  void reconnect();
  void openSettings();
}

// Top app bar, chrome menu arrow, and their toggle/menu verbs.
class HomeAppBar {
  HomeAppBar({
    required this.chatStore,
    required this.chatConn,
    required this.networkBusy,
    required this.twitchAuth,
    required this.streamPlayer,
    required this.uploadController,
    required this.mentions,
    required this.mod,
    required this.threads,
    required this.host,
  });

  final ChatStore chatStore;
  final ChatConnectionManager chatConn;
  final ValueListenable<bool> networkBusy;
  final TwitchAuth twitchAuth;
  final StreamPlayerController streamPlayer;
  final MediaUploadController uploadController;
  final MentionsPanels mentions;
  final ModPanels mod;
  final ThreadPanels threads;
  final HomeAppBarHost host;

  bool _isChannelLive(String channel) =>
      (chatStore.chatStatus[channel] ?? '').contains('Live');

  void _onBellPressed() {
    chatStore.unreadMentions = 0;
    mentions.clearUnreadWhispers();
    chatStore.channelsWithUnreadMentions.clear();
    chatStore.unreadMentionsPerChannel.clear();
    chatStore.unreadVersion.value++;
    if (host.isMounted()) host.markDirty();
    if (host.activePanel == OverlayPanel.mentions) {
      unawaited(host.closePanel());
    } else {
      mentions.showMentionsView();
    }
  }

  /// Tiny arrow anchored top-right just below the channel tab strip (see
  /// TabbedLayout). Always visible so the top bar / input can be toggled back
  /// even in fullscreen.
  Widget chromeMenu() {
    return ChromeMenuButton(
      onToggleFullscreen: host.toggleFullscreen,
      onToggleInput: host.toggleInput,
      onToggleStream: host.toggleStream,
      showStreamToggle: () =>
          streamPlayer.isActive ||
          !twitchAuth.isConfigured ||
          (host.selectedChannel != null &&
              _isChannelLive(host.selectedChannel!)),
      streamActive: () => streamPlayer.isActive,
    );
  }

  Widget appBar(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainer,
      child: Column(
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
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w400,
                      ),
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
                          !host.disableJoinSpinner &&
                          (host.chatLoading || networkBusy.value);
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
                        onPressed:
                            busy || chatStore.channels.length >= kMaxChannels
                            ? null
                            : host.addChannelDialog,
                      );
                    },
                  ),
                  ListenableBuilder(
                    listenable: chatStore.mentionsBump,
                    builder: (context, _) => IconButton(
                      icon: Icon(
                        Icons.notifications_active,
                        color: chatStore.unreadMentions > 0
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
                        case 'modview':
                          mod.showModView();
                          break;
                        case 'threads':
                          threads.showThreadsDashboard(tab: 1);
                          break;
                        case 'upload':
                          uploadController.pickAndUpload(context);
                          break;
                        case 'reload_emotes':
                          host.reloadEmotes();
                          break;
                        case 'reconnect':
                          host.reconnect();
                          break;
                        case 'settings':
                          host.openSettings();
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
                      if (host.selectedChannel != null)
                        const PopupMenuItem(
                          value: 'modview',
                          child: Row(
                            children: [
                              Icon(Icons.shield_outlined, size: 20),
                              SizedBox(width: 12),
                              Text('Mod view'),
                            ],
                          ),
                        ),
                      const PopupMenuItem(
                        value: 'threads',
                        child: Row(
                          children: [
                            Icon(Icons.forum, size: 20),
                            SizedBox(width: 12),
                            Text('Threads'),
                          ],
                        ),
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
                      onLongPress: host.openSettings,
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
      ),
    );
  }
}
