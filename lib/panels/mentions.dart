import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat.dart';
import '../client/session.dart';
import '../composer/composer_controller.dart';
import '../models/twitch_message.dart';
import '../services/chat_connection_manager.dart';
import '../services/link_whitelist.dart';
import '../services/twitch_auth.dart';
import '../sheets/message_menu.dart';
import '../sheets/user_sheet.dart';
import '../util/constants.dart' show kWhispersChannel;
import '../util/haptics.dart';
import '../widgets/chat_view.dart';
import '../widgets/message_builder.dart';
import '../widgets/panel_manager.dart';
import '../widgets/tab_drag_focus.dart';

// Mentions/whispers inbox and its open/show verbs.
class MentionsPanels {
  MentionsPanels({
    required this.panelManager,
    required this.chat,
    required this.session,
    required this.chatConn,
    required this.twitchAuth,
    required this.mentionsTab,
    required this.composer,
    required this.messageBuilder,
    required this.userSheets,
    required this.menus,
    required this.mentionsChannel,
    required this.isMounted,
    required this.markDirty,
    required this.maxMessages,
    required this.notifyWhisper,
    required this.showTimestamps,
    required this.timestampFormat,
    required this.chatFontSize,
    required this.checkeredMessages,
    required this.highlightOpacity,
    required this.lineSeparator,
    required this.sharedChatMode,
    required this.copyMessage,
  });

  final PanelManager panelManager;
  final Session session;
  final Chat chat;
  final ChatConnectionManager chatConn;
  final TwitchAuth twitchAuth;
  final TabController Function() mentionsTab;
  final ComposerController composer;
  final MessageBuilder messageBuilder;
  final UserSheets userSheets;
  final MessageMenus menus;
  final String mentionsChannel;
  final bool Function() isMounted;
  final VoidCallback markDirty;
  final int Function() maxMessages;
  final void Function(TwitchMessage msg) notifyWhisper;
  final bool Function() showTimestamps;
  final String Function() timestampFormat;
  final double Function() chatFontSize;
  final bool Function() checkeredMessages;
  final double Function() highlightOpacity;
  final bool Function() lineSeparator;
  final String Function() sharedChatMode;
  final void Function(TwitchMessage msg) copyMessage;

  final whispers = <TwitchMessage>[];
  int unreadWhispers = 0;
  String? whisperTarget;
  final mentionsAtBottom = ValueNotifier(true);
  final mentionsMsgCount = ValueNotifier(0);
  final whispersAtBottom = ValueNotifier(true);
  final whispersMsgCount = ValueNotifier(0);
  final mentionsPanelScrollCtrl = ScrollController();
  final whispersPanelScrollCtrl = ScrollController();

  /// Half-drag focus: crossings report at 50% via [_onMentionsFocus],
  /// settle syncs through [onMentionsTabChanged].
  late final tabDragFocus = TabDragFocus(
    tab: mentionsTab,
    onFocusChanged: _onMentionsFocus,
  );

  void dispose() {
    tabDragFocus.dispose();
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
    chat.touchMentions();
  }

  bool get isWhispersTabActive =>
      panelManager.activePanel == OverlayPanel.mentions &&
      tabDragFocus.effectiveIndex == 1;

  /// Panel close hook: drop a stranded drag focus.
  void onMentionsClosed() => tabDragFocus.reset();

  // Mentions branch of panel data fan-out.
  void refreshOnData() {
    mentionsMsgCount.value++;
    whispersMsgCount.value++;
  }

  Future<void> showMentionsView() async {
    await panelManager.closePanel();
    if (!isMounted()) return;
    tabDragFocus.reset();
    composer.unfocus();
    panelManager.activePanel = OverlayPanel.mentions;
    panelManager.openThreadRoot = null;
    markDirty();
    // The mentions buffer always exists on Chat; no pre-create needed.
    mentionsMsgCount.value++;
    whispersMsgCount.value++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isMounted()) {
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
    if (!isMounted()) return;
    notifyWhisper(msg);
    whispers.insert(0, msg);
    if (whispers.length > maxMessages()) {
      whispers.removeRange(maxMessages(), whispers.length);
    }
    whisperTarget = msg.login;
    whispersMsgCount.value++;
    if (!isWhispersTabActive) {
      unreadWhispers++;
      chat.noteWhisper();
    } else {
      chat.touchMentions();
    }
  }

  void addWhisperSystemMessage(String channel, String text) {
    whispers.insert(
      0,
      TwitchMessage(login: '', text: text, isSystem: true, channel: null),
    );
    if (whispers.length > maxMessages()) {
      whispers.removeRange(maxMessages(), whispers.length);
    }
    whispersMsgCount.value++;
    chat.touchMentions();
  }

  void onWhisperSent(String target, String message) {
    final login = session.login;
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
    if (whispers.length > maxMessages()) {
      whispers.removeRange(maxMessages(), whispers.length);
    }
    whispersMsgCount.value++;
    chat.touchMentions();
  }

  void onMentionsTabChanged() {
    // TabController notifies on every animation tick while a swipe is in
    // progress; the drag tracker owns crossings, this only settles.
    if (mentionsTab().indexIsChanging) return;
    tabDragFocus.syncFromController();
  }

  void _onMentionsFocus(int index) {
    iosHaptic(HapticFeedback.selectionClick);
    if (index == 1 && unreadWhispers > 0) {
      chat.markWhispersSeen(unreadWhispers);
      unreadWhispers = 0;
    }
    // Live crossings rebuild through notifiers alone (badge, composer);
    // settle keeps the full rebuild for tab-tap parity.
    if (tabDragFocus.dragFocus.value == null) markDirty();
  }

  void showWhispersForUser(String login) {
    whisperTarget = login;
    if (panelManager.activePanel != OverlayPanel.mentions) {
      unawaited(showMentionsView());
    }
    mentionsTab().animateTo(1);
    chat.markWhispersSeen(unreadWhispers);
    unreadWhispers = 0;
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
      body: NotificationListener<ScrollNotification>(
        onNotification: tabDragFocus.onNotification,
        child: TabBarView(
          controller: mentionsTab(),
          children: [
            ChatView(
              key: const ValueKey('mentions_panel'),
              channel: mentionsChannel,
              messages: chat.mentions.items,
              atBottomNotifier: mentionsAtBottom,
              messageNotifier: mentionsMsgCount,
              scrollController: mentionsPanelScrollCtrl,
              messageBuilder: messageBuilder,
              linkWhitelist: LinkWhitelist.instance,
              showTimestamp: showTimestamps(),
              timestampFormat: timestampFormat(),
              chatFontScale: chatFontSize() / 14.0,
              checkeredMessages: checkeredMessages(),
              highlightOpacity: highlightOpacity(),
              lineSeparator: lineSeparator(),
              sharedChatMode: sharedChatMode(),
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
              onCopyMessage: copyMessage,
              showReplyIndicators: false,
              fadeDeleted: false,
              showChannel: true,
              emptyText: 'No mentions or whispers',
            ),
            ChatView(
              key: const ValueKey('whispers_panel'),
              channel: kWhispersChannel,
              messages: whispers,
              atBottomNotifier: whispersAtBottom,
              messageNotifier: whispersMsgCount,
              scrollController: whispersPanelScrollCtrl,
              messageBuilder: messageBuilder,
              linkWhitelist: LinkWhitelist.instance,
              showTimestamp: showTimestamps(),
              timestampFormat: timestampFormat(),
              chatFontScale: chatFontSize() / 14.0,
              checkeredMessages: checkeredMessages(),
              highlightOpacity: highlightOpacity(),
              lineSeparator: lineSeparator(),
              sharedChatMode: sharedChatMode(),
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
              onCopyMessage: copyMessage,
              showReplyIndicators: false,
              emptyText: 'No whispers',
            ),
          ],
        ),
      ),
    );
  }
}
