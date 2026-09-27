import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat.dart';
import '../client/session.dart';
import '../composer/composer_controller.dart';
import '../panels/threads.dart';
import '../services/analytics_service.dart';
import '../services/chat_connection_manager.dart';
import '../services/chat_history_controller.dart';
import '../services/emote_manager.dart';
import '../services/ignore_manager.dart';
import '../services/notification_service.dart';
import '../services/ping_manager.dart';
import '../services/recent_messages.dart';
import '../services/stream_player_controller.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_badge_service.dart';
import '../irc/transport/read.dart';
import '../irc/transport/write.dart';
import '../services/user_store.dart';
import '../util/constants.dart';
import '../util/haptics.dart';
import '../util/log.dart';
import '../util/prefs.dart';
import '../widgets/broadcast_widgets.dart';

// Channel membership, history backfill, and selection: the join/leave
// plumbing, robotty history merge, join-queue progress lines, and the
// single selection commit behind swipe-tick focus and settle/tab-tap.
class ChannelManager {
  ChannelManager({
    required this.chat,
    required this.session,
    required this.chatConn,
    required this.irc,
    required this.ircRead,
    required this.twitchAuth,
    required this.emoteManager,
    required this.badgeService,
    required this.analytics,
    required this.streamPlayer,
    required this.userStore,
    required this.pingManager,
    required this.ignoreManager,
    required this.notificationService,
    required this.threads,
    required this.composer,
    required this.broadcastWidgets,
    required this.tileCache,
    required this.channelNotifier,
    required this.selectedTabIndex,
    required this.recentMessagesService,
    required this.mentionsChannel,
    required this.history,
    required this.selectedChannel,
    required this.setSelectedChannel,
    required this.isMounted,
    required this.markDirty,
    required this.mutate,
    required this.closePanel,
    required this.addSystemMessage,
    required this.maxMessages,
    required this.recentMessagesLimit,
    required this.mentionPush,
    required this.atBottomNotifier,
    required this.disposeChannelNotifiers,
    required this.forgetAtBottomNotifier,
    required this.forgetSearch,
    required this.invalidateCaches,
  });

  final Session session;
  final Chat chat;
  final ChatConnectionManager chatConn;
  final IrcService irc;
  final IrcReadService ircRead;
  final TwitchAuth twitchAuth;
  final EmoteManager emoteManager;
  final TwitchBadgeService badgeService;
  final AnalyticsService analytics;
  final StreamPlayerController streamPlayer;
  final UserStore userStore;
  final PingManager pingManager;
  final IgnoreManager ignoreManager;
  final NotificationService notificationService;
  final ThreadPanels threads;
  final ComposerController composer;
  final BroadcastWidgets broadcastWidgets;
  final Map<String, Map<String?, Widget>> tileCache;
  final ValueNotifier<List<String>> channelNotifier;
  final ValueNotifier<int> selectedTabIndex;
  final RecentMessagesService? recentMessagesService;
  final String mentionsChannel;
  final ChatHistoryController history;
  final String? Function() selectedChannel;
  final void Function(String? channel) setSelectedChannel;
  final bool Function() isMounted;
  final VoidCallback markDirty;
  final void Function(void Function() fn) mutate;
  final Future<void> Function() closePanel;
  final void Function(String channel, String text) addSystemMessage;
  final int Function() maxMessages;
  final int Function() recentMessagesLimit;
  final bool Function() mentionPush;
  final ValueNotifier<bool> Function(String channel) atBottomNotifier;
  final void Function(String channel) disposeChannelNotifiers;
  final void Function(String channel) forgetAtBottomNotifier;
  final void Function(String channel) forgetSearch;
  final VoidCallback invalidateCaches;

  bool _channelsLoaded = false;
  final _generations = <String, int>{};
  bool _mentionScanDone = false;

  /// Re-arm the once-per-login mention scan after an account switch.
  void rearmMentionScan() => _mentionScanDone = false;
  late RecentMessagesService recentMessages;
  RecentMessagesConfig recentMessagesConfig = RecentMessagesConfig();

  void truncateChannel(String channel) {
    chat.channelFor(channel)?.truncate(maxMessages());
  }

  Future<void> saveChannels([List<String>? names]) async {
    final prefs = await Prefs.load();
    await prefs.setChannels(List.of(names ?? chat.names));
  }

  void reorderChannels(List<String> reordered) {
    chat.reorder(reordered);
    channelNotifier.value = List.of(chat.names);
    if (selectedChannel() != null) {
      final newIdx = chat.names.indexOf(selectedChannel()!);
      if (newIdx >= 0) selectedTabIndex.value = newIdx;
    }
    if (isMounted()) markDirty();
    saveChannels();
  }

  Future<void> loadChannels() async {
    if (_channelsLoaded) return;
    _channelsLoaded = true;
    final prefs = await Prefs.load();
    final saved = prefs.channels;
    // Registry files outlive joins; sweep ones whose channel is gone.
    unawaited(emoteManager.pruneStaleChannels(saved.toSet()));
    if (saved.isEmpty) return;
    for (final name in saved) {
      if (chat.contains(name)) continue;
      chat.ensure(name);
      atBottomNotifier(name).value = true;
    }
    channelNotifier.value = List.of(chat.names);
    setSelectedChannel(chat.names.first);
    selectedTabIndex.value = 0;
    if (isMounted()) markDirty();
    for (final name in saved) {
      subscribeChannel(name);
      recentMessages
          .fetchRecentPreferWarm(name, limit: recentMessagesLimit())
          .then((rows) {
            if (!isMounted() || !chat.contains(name)) return;
            chat.channelFor(name)?.setHistoryLoaded(true);
            mutate(() {
              if (rows.isEmpty) {
                addSystemMessage(name, 'No chat history available');
              } else {
                history.mergeHistory(name, rows);
              }
            });
            maybeAddConnected(name);
          })
          .catchError((e) {
            if (!isMounted() || !chat.contains(name)) return;
            chat.channelFor(name)?.setHistoryLoaded(true);
            addSystemMessage(
              name,
              e is RecentMessagesException
                  ? e.message
                  : 'Failed to load chat history',
            );
            maybeAddConnected(name);
          });
    }
  }

  void maybeAddConnected(String channel) {
    chatConn.maybeAddConnected(channel);
  }

  void removeLoadingHistoryMessage(String channel) {
    chat.channelFor(channel)?.removeLoadingHistory();
  }

  // "Connected" is emitted as soon as IRC is up, which is usually before
  // the robotty history fetch completes. History messages are then inserted
  // above it, so move the newest connect-state line ("Reconnected" on a
  // reconnect, otherwise "Connected") back to the most recent position to
  // stay visible. No extra bump: the merge already ticked info.version.
  void moveConnectedMessageToTop(String channel) {
    chat.channelFor(channel)?.moveConnectedToTop();
  }

  Future<void> subscribeChannel(String channelName) async {
    chatConn.subscribeChannel(channelName);
  }

  Future<void> addChannel(String channelName) async {
    final name = channelName.trim().toLowerCase();
    if (name.isEmpty || chat.contains(name)) return;
    if (chat.length >= kMaxChannels) return;

    _generations[name] = (_generations[name] ?? 0) + 1;
    mutate(() {
      chat.ensure(name);
      channelNotifier.value = List.of(chat.names);
      atBottomNotifier(name).value = true;
      setSelectedChannel(name);
      selectedTabIndex.value = chat.names.length - 1;
    });
    saveChannels();
    composer.focus();

    chat.channelFor(name)?.addLoadingHistory();

    recentMessages
        .fetchRecentPreferWarm(name, limit: recentMessagesLimit())
        .then((rows) {
          if (!isMounted() || !chat.contains(name)) return;
          chat.channelFor(name)?.setHistoryLoaded(true);
          mutate(() {
            removeLoadingHistoryMessage(name);
            if (rows.isEmpty) {
              addSystemMessage(name, 'No chat history available');
            } else {
              history.mergeHistory(name, rows);
            }
          });
          maybeAddConnected(name);
        })
        .catchError((e) {
          if (!isMounted() || !chat.contains(name)) return;
          chat.channelFor(name)?.setHistoryLoaded(true);
          mutate(() {
            removeLoadingHistoryMessage(name);
            addSystemMessage(
              name,
              e is RecentMessagesException
                  ? e.message
                  : 'Failed to load chat history',
            );
          });
          maybeAddConnected(name);
        });

    logDebug('[HomeScreen] joining channel: $name');
    await subscribeChannel(name);
    chatConn.focusChannel(name);

    if (isMounted()) markDirty();
  }

  void removeChannel(String channel) {
    chatConn.stopChatStatusTimer(channel);
    chatConn.forgetChannel(channel);
    analytics.resetChannel(channel);
    if (streamPlayer.currentChannel == channel) streamPlayer.closeStream();
    irc.part(channel);
    ircRead.part(channel);
    emoteManager.evictChannel(channel);
    badgeService.clearChannel(channel);
    chat.channelFor(channel)?.clearHeldModeration();
    broadcastWidgets.clearChannel(channel);
    // Same-frame cache clears first so no stale tile survives the unmount.
    tileCache.remove(channel);
    invalidateCaches();
    final generation = (_generations[channel] ?? 0) + 1;
    _generations[channel] = generation;
    mutate(() {
      channelNotifier.value = List.of(chat.names.where((c) => c != channel));
      userStore.removeChannel(channel);
      threads.forgetChannel(channel);
      if (selectedChannel() == channel) {
        final remaining = chat.names.where((c) => c != channel).toList();
        setSelectedChannel(remaining.isNotEmpty ? remaining.last : null);
        if (remaining.isNotEmpty) {
          selectedTabIndex.value = remaining.length - 1;
        }
      }
      // After reselect so the search field syncs to the new channel.
      forgetSearch(channel);
    });
    // Channel disposal lands after the widgets listening to its notifiers
    // have unmounted. The generation guard skips disposal when a rejoin
    // recreated the channel before this callback ran.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isMounted()) return;
      if (_generations[channel] != generation) return;
      if (!chat.contains(channel)) return;
      chat.remove(channel);
      disposeChannelNotifiers(channel);
      forgetAtBottomNotifier(channel);
    });
    saveChannels(chat.names.where((c) => c != channel).toList());
  }

  // Single selection commit for BOTH entry points (swipe-tick focus and
  // settle/tab-tap). Whichever lands first owns the side effects; the shared
  // guard makes the second one a no-op, so bookkeeping runs exactly once per
  // real switch regardless of gesture timing.
  void commitChannelSelection(int index, {required bool rebuild}) {
    final names = chat.names;
    if (index < 0 || index >= names.length) return;
    final channel = names[index];
    if (selectedChannel() == channel) return;
    unawaited(closePanel());
    var clearedUnread = 0;
    void mutate() {
      iosHaptic(HapticFeedback.selectionClick);
      setSelectedChannel(channel);
      composer.refreshCooldown();
      clearedUnread = chat.clearUnread(channel);
      threads.clearOpenThread();
      composer.onChannelChanged();
    }

    if (rebuild) {
      this.mutate(mutate);
    } else {
      mutate();
      // Focus changes (swipes) skip the setState path, so bump the bell's
      // notifier directly to refresh the badge color.
      if (clearedUnread > 0) chat.touchMentions();
    }
    if (clearedUnread > 0 && mentionPush()) {
      unawaited(notificationService.clearMentionNotifications(channel));
    }
    broadcastWidgets.resetPage();
    selectedTabIndex.value = index;
    chatConn.focusChannel(channel);
  }

  // Retroactive mention scan: runs once on login. The history owner evaluates
  // the ping rules and mirrors the hits through the chat root.
  void scanHistoryForMentions() {
    if (_mentionScanDone || session.login == null) return;
    _mentionScanDone = true;
    history.scanForMentions();
  }

  Future<void> loadRecentMessagesConfig() async {
    if (recentMessagesService != null) {
      recentMessages = recentMessagesService!;
      return;
    }
    try {
      final prefs = await Prefs.load();
      recentMessagesConfig = RecentMessagesConfig.fromPrefs(prefs);
    } catch (e) {
      logDebug('Failed to load recent-messages config: $e');
    }
    recentMessages = RecentMessagesService(config: recentMessagesConfig);
  }

  void setRecentMessagesMode(RecentMessagesConfig config) {
    if (recentMessagesService != null) return;
    recentMessagesConfig = config;
    markDirty();
    recentMessages = RecentMessagesService(config: config);
    unawaited(Prefs.load().then((prefs) => config.toPrefs(prefs)));
  }
}
