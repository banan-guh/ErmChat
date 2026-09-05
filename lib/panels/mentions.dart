import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../composer/composer_controller.dart';
import '../models/twitch_message.dart';
import '../services/chat_connection_manager.dart';
import '../services/chat_store.dart';
import '../services/link_whitelist.dart';
import '../services/twitch_auth.dart';
import '../sheets/message_menu.dart';
import '../sheets/user_sheet.dart';
import '../third_party/flutter_list_view/flutter_list_view.dart';
import '../util/haptics.dart';
import '../widgets/chat_view.dart';
import '../widgets/message_builder.dart';
import '../widgets/panel_manager.dart';

// Shell-owned state the mentions/whispers inbox reads but does not own.
abstract class MentionsPanelsHost extends ShellState {
  bool isMounted();
  void markDirty();
  int get maxMessages;
  void notifyWhisper(TwitchMessage msg);
  @override
  bool get showTimestamps;
  @override
  String get timestampFormat;
  double get chatFontSize;
  bool get checkeredMessages;
  double get highlightOpacity;
  bool get lineSeparator;
  String get sharedChatMode;
  void copyMessage(TwitchMessage msg);
}

// Mentions/whispers inbox and its open/show verbs.
class MentionsPanels {
  MentionsPanels({
    required this.panelManager,
    required this.chatStore,
    required this.chatConn,
    required this.twitchAuth,
    required this.mentionsTab,
    required this.composer,
    required this.messageBuilder,
    required this.userSheets,
    required this.menus,
    required this.mentionsChannel,
    required this.host,
  });

  final PanelManager panelManager;
  final ChatStore chatStore;
  final ChatConnectionManager chatConn;
  final TwitchAuth twitchAuth;
  final TabController Function() mentionsTab;
  final ComposerController composer;
  final MessageBuilder messageBuilder;
  final UserSheets userSheets;
  final MessageMenus menus;
  final String mentionsChannel;
  final MentionsPanelsHost host;

  final whispers = <TwitchMessage>[];
  int unreadWhispers = 0;
  String? whisperTarget;
  final mentionsAtBottom = ValueNotifier(true);
  final mentionsMsgCount = ValueNotifier(0);
  final whispersAtBottom = ValueNotifier(true);
  final whispersMsgCount = ValueNotifier(0);
  final mentionsPanelScrollCtrl = FlutterListViewController();
  final whispersPanelScrollCtrl = FlutterListViewController();

  void dispose() {
    mentionsAtBottom.dispose();
    mentionsMsgCount.dispose();
    whispersAtBottom.dispose();
    whispersMsgCount.dispose();
    mentionsPanelScrollCtrl.dispose();
    whispersPanelScrollCtrl.dispose();
  }

  // Account switch: whispers and the mentions feed belong to the old account.
  void clearForAccountSwitch() {
    whispers.clear();
    unreadWhispers = 0;
    whispersMsgCount.value++;
    mentionsMsgCount.value++;
  }

  // Bell tap: all unread counts go to zero.
  void clearUnreadWhispers() {
    unreadWhispers = 0;
    chatStore.mentionsBump.value++;
  }

  bool get isWhispersTabActive =>
      panelManager.activePanel == OverlayPanel.mentions &&
      mentionsTab().index == 1;

  // Mentions branch of panel data fan-out.
  void refreshOnData() {
    mentionsMsgCount.value++;
    whispersMsgCount.value++;
  }

  Future<void> showMentionsView() async {
    await panelManager.closePanel();
    if (!host.isMounted()) return;
    composer.unfocus();
    panelManager.activePanel = OverlayPanel.mentions;
    panelManager.openThreadRoot = null;
    host.markDirty();
    // Pre-create the mentions buffer so the ChatView's list reference stays
    // stable across the first mirrorMentions insertion.
    chatStore.channelMessages.putIfAbsent(mentionsChannel, () => []);
    mentionsMsgCount.value++;
    whispersMsgCount.value++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (host.isMounted()) {
        panelManager.animateRatio(
          panelManager.mentionsSheetRatio,
          0.0,
          PanelManager.fullHeightFraction,
          PanelManager.sheetAnimDuration,
        );
      }
    });
  }

  void onWhisper(TwitchMessage msg) {
    if (!host.isMounted()) return;
    host.notifyWhisper(msg);
    whispers.insert(0, msg);
    if (whispers.length > host.maxMessages) {
      whispers.removeRange(host.maxMessages, whispers.length);
    }
    whisperTarget = msg.login;
    whispersMsgCount.value++;
    if (!isWhispersTabActive) {
      unreadWhispers++;
      chatStore.unreadMentions++;
    }
    chatStore.mentionsBump.value++;
  }

  void addWhisperSystemMessage(String channel, String text) {
    whispers.insert(
      0,
      TwitchMessage(login: '', text: text, isSystem: true, channel: null),
    );
    if (whispers.length > host.maxMessages) {
      whispers.removeRange(host.maxMessages, whispers.length);
    }
    whispersMsgCount.value++;
    chatStore.mentionsBump.value++;
  }

  void onWhisperSent(String target, String message) {
    final login = chatStore.session.login;
    if (login == null) return;
    whisperTarget = target;
    whispers.insert(
      0,
      TwitchMessage(
        login: login,
        displayName: login,
        text: message,
        channel: null,
      ),
    );
    if (whispers.length > host.maxMessages) {
      whispers.removeRange(host.maxMessages, whispers.length);
    }
    whispersMsgCount.value++;
    chatStore.mentionsBump.value++;
  }

  void onMentionsTabChanged() {
    // TabController notifies on every animation tick while a swipe is in
    // progress; rebuilding the whole screen per frame is wasted work.
    if (mentionsTab().indexIsChanging) return;
    iosHaptic(HapticFeedback.selectionClick);
    if (mentionsTab().index == 1 && unreadWhispers > 0) {
      chatStore.unreadMentions -= unreadWhispers;
      if (chatStore.unreadMentions < 0) chatStore.unreadMentions = 0;
      unreadWhispers = 0;
      chatStore.mentionsBump.value++;
    }
    host.markDirty();
  }

  void showWhispersForUser(String login) {
    whisperTarget = login;
    if (panelManager.activePanel != OverlayPanel.mentions) {
      unawaited(showMentionsView());
    }
    mentionsTab().animateTo(1);
    chatStore.unreadMentions -= unreadWhispers;
    if (chatStore.unreadMentions < 0) chatStore.unreadMentions = 0;
    unreadWhispers = 0;
    chatStore.mentionsBump.value++;
    composer.focus();
  }

  Widget mentionsPanel(
    BuildContext context, {
    required Widget Function({
      required bool offstage,
      required ValueNotifier<double> ratio,
      required Widget header,
      required Widget body,
    })
    overlaySheet,
    required VoidCallback closePanel,
  }) {
    return overlaySheet(
      offstage: panelManager.activePanel != OverlayPanel.mentions,
      ratio: panelManager.mentionsSheetRatio,
      header: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                  onPressed: closePanel,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Mentions / Whispers',
                    style: TextStyle(
                      fontSize: 20,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
          TabBar(
            controller: mentionsTab(),
            padding: EdgeInsets.fromLTRB(100.0, 0.0, 100.0, 0.0),
            tabs: const [
              Tab(text: 'Mentions'),
              Tab(text: 'Whispers'),
            ],
          ),
          Divider(height: 1, color: Theme.of(context).dividerColor),
        ],
      ),
      body: TabBarView(
        controller: mentionsTab(),
        children: [
          ChatView(
            key: const ValueKey('mentions_panel'),
            channel: mentionsChannel,
            messages: chatStore.channelMessages[mentionsChannel] ?? const [],
            atBottomNotifier: mentionsAtBottom,
            messageNotifier: mentionsMsgCount,
            scrollController: mentionsPanelScrollCtrl,
            messageBuilder: messageBuilder,
            linkWhitelist: LinkWhitelist.instance,
            showTimestamp: host.showTimestamps,
            timestampFormat: host.timestampFormat,
            chatFontScale: host.chatFontSize / 14.0,
            checkeredMessages: host.checkeredMessages,
            highlightOpacity: host.highlightOpacity,
            lineSeparator: host.lineSeparator,
            sharedChatMode: host.sharedChatMode,
            physics: const ClampingScrollPhysics(),
            onShowUserProfile: (login, userId, {displayName}) =>
                userSheets.showUserProfile(
                  context,
                  login,
                  userId,
                  displayName: displayName,
                ),
            onShowMessageMenu: (msg) =>
                menus.showPanelMessageMenu(context, msg),
            onCopyMessage: host.copyMessage,
            showReplyIndicators: false,
            fadeDeleted: false,
            emptyText: 'No mentions or whispers',
          ),
          ChatView(
            key: const ValueKey('whispers_panel'),
            channel: '@whispers',
            messages: whispers,
            atBottomNotifier: whispersAtBottom,
            messageNotifier: whispersMsgCount,
            scrollController: whispersPanelScrollCtrl,
            messageBuilder: messageBuilder,
            linkWhitelist: LinkWhitelist.instance,
            showTimestamp: host.showTimestamps,
            timestampFormat: host.timestampFormat,
            chatFontScale: host.chatFontSize / 14.0,
            checkeredMessages: host.checkeredMessages,
            highlightOpacity: host.highlightOpacity,
            lineSeparator: host.lineSeparator,
            sharedChatMode: host.sharedChatMode,
            physics: const ClampingScrollPhysics(),
            onShowUserProfile: (login, userId, {displayName}) =>
                userSheets.showUserProfile(
                  context,
                  login,
                  userId,
                  displayName: displayName,
                ),
            onShowMessageMenu: (msg) =>
                menus.showPanelMessageMenu(context, msg),
            onCopyMessage: host.copyMessage,
            showReplyIndicators: false,
            emptyText: 'No whispers',
          ),
        ],
      ),
    );
  }
}
