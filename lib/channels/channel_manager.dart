import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../composer/composer_controller.dart';
import '../panels/threads.dart';
import '../services/notification_service.dart';
import '../services/recent_messages.dart';
import '../util/haptics.dart';
import '../widgets/broadcast_widgets.dart';
import 'channel_session.dart';

// UI half of channel membership: the tab list, selection index, tile cache,
// composer focus, and panel/search side effects. The non-UI rules live in
// `ChannelSession`; this adapter reacts to its notifier and never re-implements
// them.
class ChannelManager {
  ChannelManager({
    required this.session,
    required this.composer,
    required this.threads,
    required this.broadcastWidgets,
    required this.tileCache,
    required this.channelNotifier,
    required this.selectedTabIndex,
    required this.isMounted,
    required this.markDirty,
    required this.mutate,
    required this.closePanel,
    required this.atBottomNotifier,
    required this.disposeChannelNotifiers,
    required this.forgetAtBottomNotifier,
    required this.forgetSearch,
    required this.invalidateCaches,
    required this.notificationService,
    required this.mentionPush,
  }) {
    session.addListener(_onSessionChanged);
  }

  final ChannelSession session;
  final ComposerController composer;
  final ThreadPanels threads;
  final BroadcastWidgets broadcastWidgets;
  final Map<String, Map<String?, Widget>> tileCache;
  final ValueNotifier<List<String>> channelNotifier;
  final ValueNotifier<int> selectedTabIndex;
  final bool Function() isMounted;
  final VoidCallback markDirty;
  final void Function(void Function() fn) mutate;
  final Future<void> Function() closePanel;
  final ValueNotifier<bool> Function(String channel) atBottomNotifier;
  final void Function(String channel) disposeChannelNotifiers;
  final void Function(String channel) forgetAtBottomNotifier;
  final void Function(String channel) forgetSearch;
  final VoidCallback invalidateCaches;
  final NotificationService notificationService;
  final bool Function() mentionPush;

  // A remove that leaves the selection alone must not resync the tab index:
  // the original path leaves it untouched, and the visible highlight already
  // derives from the live channel list.
  bool _suppressSelectionSync = false;
  bool _focusAfterAdd = false;

  void dispose() {
    session.removeListener(_onSessionChanged);
  }

  // Reacts to the session's list and selection changes. Content-only notifies
  // (history merges) still rebuild, mirroring the old setState.
  void _onSessionChanged() {
    final names = List.of(session.channelNames);
    final previous = channelNotifier.value;
    if (!listEquals(names, previous)) {
      for (final name in names) {
        if (!previous.contains(name)) atBottomNotifier(name).value = true;
      }
      channelNotifier.value = names;
      if (!_suppressSelectionSync) {
        final selected = session.selectedChannel();
        if (selected != null) {
          final index = names.indexOf(selected);
          if (index >= 0) selectedTabIndex.value = index;
        }
      }
    }
    if (_focusAfterAdd) {
      _focusAfterAdd = false;
      composer.focus();
    }
    if (isMounted()) markDirty();
  }

  void reorderChannels(List<String> reordered) {
    session.reorderChannels(reordered);
  }

  Future<void> addChannel(String channelName) async {
    _focusAfterAdd = true;
    final added = await session.addChannel(channelName);
    if (!added) _focusAfterAdd = false;
  }

  /// Swaps [from] for [to] at the same tab position. False when [to] is
  /// empty, unchanged, or already joined.
  Future<bool> renameChannel(String from, String to) async {
    final name = to.trim().toLowerCase();
    final names = session.channelNames;
    final index = names.indexOf(from);
    if (index < 0 || name.isEmpty || names.contains(name)) return false;
    removeChannel(from);
    // The join registers the channel before its first await, so the reorder
    // lands in the same frame and the tab never shows at the end.
    final joined = session.addChannel(name);
    final reordered = List.of(session.channelNames)
      ..remove(name)
      ..insert(index, name);
    session.reorderChannels(reordered);
    return joined;
  }

  void removeChannel(String channel) {
    _suppressSelectionSync = session.selectedChannel() != channel;
    final generation = session.beginRemove(channel);
    _suppressSelectionSync = false;

    broadcastWidgets.clearChannel(channel);
    // Same-frame cache clears first so no stale tile survives the unmount.
    tileCache.remove(channel);
    invalidateCaches();
    threads.forgetChannel(channel);
    // After reselect so the search field syncs to the new channel.
    forgetSearch(channel);

    // Channel disposal lands after the widgets listening to its notifiers
    // have unmounted. The generation guard skips disposal when a rejoin
    // recreated the channel before this callback ran.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isMounted()) return;
      if (!session.finalizeRemove(channel, generation)) return;
      disposeChannelNotifiers(channel);
      forgetAtBottomNotifier(channel);
    });
  }

  // Single selection commit for BOTH entry points (swipe-tick focus and
  // settle/tab-tap). Whichever lands first owns the side effects; the shared
  // guard makes the second one a no-op, so bookkeeping runs exactly once per
  // real switch regardless of gesture timing.
  void commitChannelSelection(int index, {required bool rebuild}) {
    final names = session.channelNames;
    if (index < 0 || index >= names.length) return;
    final channel = names[index];
    if (session.selectedChannel() == channel) return;
    unawaited(closePanel());
    var clearedUnread = 0;
    void mutate() {
      iosHaptic(HapticFeedback.selectionClick);
      clearedUnread = session.selectChannel(channel) ?? 0;
      composer.refreshCooldown();
      threads.clearOpenThread();
      composer.onChannelChanged();
    }

    if (rebuild) {
      this.mutate(mutate);
    } else {
      mutate();
      // Focus changes (swipes) skip the setState path, so bump the bell's
      // notifier directly to refresh the badge color.
      if (clearedUnread > 0) session.touchMentions();
    }
    if (clearedUnread > 0 && mentionPush()) {
      unawaited(notificationService.clearMentionNotifications(channel));
    }
    broadcastWidgets.resetPage();
    selectedTabIndex.value = index;
    session.focusChannel(channel);
  }

  // Retroactive mention scan: runs once on login.
  void scanHistoryForMentions() => session.scanHistoryForMentions();

  void rearmMentionScan() => session.rearmMentionScan();

  void truncateChannel(String channel) => session.truncateChannel(channel);

  Future<void> loadChannels() => session.loadChannels();

  Future<void> loadRecentMessagesConfig() => session.loadRecentMessagesConfig();

  void setRecentMessagesMode(RecentMessagesConfig config) {
    if (session.recentMessagesService != null) return;
    session.setRecentMessagesMode(config);
    markDirty();
  }
}
