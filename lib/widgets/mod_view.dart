import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../chat/chat.dart';
import '../services/mod_actions.dart';
import '../services/twitch_auth.dart';
import 'mod_view/queue_tab.dart';
import 'mod_view/activity_tab.dart';
import 'mod_view/users_tab.dart';
import 'mod_view/requests_tab.dart';
import 'mod_view/terms_tab.dart';
import 'mod_view/setup_tab.dart';
import 'mod_view/channel_tab.dart';
import 'mod_view/modes_tab.dart';
import 'tab_drag_focus.dart';

export 'mod_view/common.dart'
    show modErrorText, showModError, showModTextDialog, showTimeoutDialog;

/// Mod View panel body: Queue / Activity / Modes / Channel / Users /
/// Requests / Terms / Setup tabs. State arrives as channel lookups (not
/// snapshots) so every [refresh] tick re-reads live values; the queue and
/// feed additionally listen to their own versions.
class ModViewPanel extends StatelessWidget {
  const ModViewPanel({
    super.key,
    required this.channel,
    required this.chat,
    required this.modActions,
    required this.auth,
    required this.tabController,
    required this.refresh,
    required this.termsVersion,
    required this.dragFocus,
    required this.isModerationActive,
    required this.isAutomodActive,
    required this.getRoomModes,
    required this.onNotice,
    this.onShowUser,
    this.isBroadcaster = false,
  });

  final String channel;
  final Chat chat;
  final ModActions modActions;
  final TwitchAuth auth;
  final TabController tabController;
  final Listenable refresh;

  /// Bumped when a blocked term is added via the borrowed composer input.
  final ValueListenable<int> termsVersion;

  /// Half-drag focus tracker; the composer morph follows 50% crossings.
  final TabDragFocus dragFocus;
  final bool Function(String channel) isModerationActive;
  final bool Function(String channel) isAutomodActive;
  final Map<String, String> Function(String channel) getRoomModes;

  /// Notice sink for failures; the shell routes these to the inline bar.
  final ValueChanged<String> onNotice;

  /// Opens a user card (queue rows, feed-adjacent user lists).
  final ValueChanged<String>? onShowUser;

  /// Whether the session user owns the channel (Channel and Users gates).
  final bool isBroadcaster;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: refresh,
      builder: (_, _) {
        final moderationActive = isModerationActive(channel);
        final automodActive = isAutomodActive(channel);
        if (!moderationActive && !automodActive) {
          // Scope can flip while a drag is in flight, unmounting the
          // TabBarView below without a ScrollEnd: drop the stranded focus
          // post-frame so the composer gate reads honest state.
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => dragFocus.reset(),
          );
          return const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Mod tools are available where you moderate.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return NotificationListener<ScrollNotification>(
          onNotification: dragFocus.onNotification,
          child: TabBarView(
            controller: tabController,
            // Kept alive so swiping back doesn't refetch every Helix list.
            children: [
              for (final tab in <Widget>[
                QueueTab(
                  channel: channel,
                  chat: chat,
                  modActions: modActions,
                  auth: auth,
                  automodActive: automodActive,
                  scopeReady: moderationActive,
                  scopeStale: auth.scopeStale,
                  onNotice: onNotice,
                  onShowUser: onShowUser,
                ),
                ActivityTab(channel: channel, chat: chat),
                ModesTab(
                  channel: channel,
                  modActions: modActions,
                  auth: auth,
                  roomModes: getRoomModes(channel),
                  moderationActive: moderationActive,
                  onNotice: onNotice,
                ),
                ChannelTab(
                  channel: channel,
                  chat: chat,
                  modActions: modActions,
                  auth: auth,
                  onNotice: onNotice,
                  isBroadcaster: isBroadcaster,
                  isModerationActive: moderationActive,
                ),
                UsersTab(
                  channel: channel,
                  chat: chat,
                  modActions: modActions,
                  auth: auth,
                  onNotice: onNotice,
                  onShowUser: onShowUser,
                ),
                RequestsTab(
                  channel: channel,
                  chat: chat,
                  modActions: modActions,
                  auth: auth,
                  onNotice: onNotice,
                ),
                TermsTab(
                  channel: channel,
                  chat: chat,
                  modActions: modActions,
                  auth: auth,
                  termsVersion: termsVersion,
                  onNotice: onNotice,
                ),
                SetupTab(
                  channel: channel,
                  chat: chat,
                  modActions: modActions,
                  auth: auth,
                  onNotice: onNotice,
                ),
              ])
                _KeepAlive(child: tab),
            ],
          ),
        );
      },
    );
  }
}

class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
