import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/chat.dart';
import '../client/session.dart';
import '../composer/composer_controller.dart';
import '../models/twitch_message.dart';
import '../panels/threads.dart';
import '../services/analytics_service.dart';
import '../services/chat_connection_manager.dart';
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
import '../widgets/broadcast_widgets.dart';

// Shell-owned state the channel manager reads but does not own.
abstract class ChannelManagerHost extends ShellState {
  @override
  String? get selectedChannel;
  set selectedChannel(String? value);
  bool isMounted();
  void markDirty();
  void mutate(void Function() fn);
  Future<void> closePanel();
  void addSystemMessage(String channel, String text);
  int get maxMessages;
  int get recentMessagesLimit;
  bool get mentionPush;
  ValueNotifier<bool> atBottomNotifier(String channel);
  void disposeChannelNotifiers(String channel);
  void forgetAtBottomNotifier(String channel);
  void forgetSearch(String channel);
  void invalidateCaches();
}

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
    required this.host,
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
  final ChannelManagerHost host;

  bool _channelsLoaded = false;
  final _refetchingChannels = <String>{};
  final _generations = <String, int>{};
  bool _mentionScanDone = false;

  /// Re-arm the once-per-login mention scan after an account switch.
  void rearmMentionScan() => _mentionScanDone = false;
  late RecentMessagesService recentMessages;
  RecentMessagesConfig recentMessagesConfig = RecentMessagesConfig();

  void truncateChannel(String channel) {
    chat.channelFor(channel)?.truncate(host.maxMessages);
  }

  Future<void> saveChannels([List<String>? names]) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('channels', List.of(names ?? chat.names));
  }

  void reorderChannels(List<String> reordered) {
    chat.reorder(reordered);
    channelNotifier.value = List.of(chat.names);
    if (host.selectedChannel != null) {
      final newIdx = chat.names.indexOf(host.selectedChannel!);
      if (newIdx >= 0) selectedTabIndex.value = newIdx;
    }
    if (host.isMounted()) host.markDirty();
    saveChannels();
  }

  Future<void> loadChannels() async {
    if (_channelsLoaded) return;
    _channelsLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('channels');
    // Registry files outlive joins; sweep ones whose channel is gone.
    unawaited(emoteManager.pruneStaleChannels(saved?.toSet() ?? const {}));
    if (saved == null || saved.isEmpty) return;
    for (final name in saved) {
      if (chat.contains(name)) continue;
      chat.ensure(name);
      host.atBottomNotifier(name).value = true;
    }
    channelNotifier.value = List.of(chat.names);
    host.selectedChannel = chat.names.first;
    selectedTabIndex.value = 0;
    if (host.isMounted()) host.markDirty();
    for (final name in saved) {
      subscribeChannel(name);
      recentMessages
          .fetchRecentPreferWarm(name, limit: host.recentMessagesLimit)
          .then((history) {
            if (!host.isMounted()) return;
            chat.channelFor(name)?.info.setHistoryLoaded(true);
            host.mutate(() {
              if (history.isEmpty) {
                host.addSystemMessage(name, 'No chat history available');
              } else {
                mergeHistory(name, history);
              }
            });
            maybeAddConnected(name);
          })
          .catchError((e) {
            if (!host.isMounted()) return;
            chat.channelFor(name)?.info.setHistoryLoaded(true);
            host.addSystemMessage(
              name,
              e is RecentMessagesException
                  ? e.message
                  : 'Failed to load chat history',
            );
            maybeAddConnected(name);
          });
    }
  }

  // Merges robotty history into the channel buffer (newest-first). Single
  // owner for the history checklist: ignore filter, user learning, the
  // You/were rewrite, mention-only ping tint, then the channel verb which
  // owns dedup, id-less fold, sort, gap note, truncate, and thread index.
  // All three paths (boot, join, refetch) call this helper.
  void mergeHistory(String channel, List<TwitchMessage> history) {
    final prepared = <TwitchMessage>[];
    for (final msg in history) {
      if (!msg.isSystem && ignoreManager.isIgnored(msg.login)) continue;
      if (!msg.isSystem && msg.login.isNotEmpty) {
        final preferred =
            msg.displayName.toLowerCase() == msg.login.toLowerCase()
            ? msg.displayName
            : msg.login;
        userStore.addUser(channel, preferred);
      }
      if (msg.isSystem && session.login != null) {
        final selfLogin = session.login!.toLowerCase();
        if (msg.login.toLowerCase() == selfLogin) {
          msg.text = msg.text.replaceFirst(
            RegExp(RegExp.escape(msg.login), caseSensitive: false),
            'You',
          );
          msg.text = msg.text.replaceFirst('was', 'were');
        }
      }
      if (msg.highlight == null) {
        final state = pingManager.evaluate(msg);
        if (state != null && state.hasMention) {
          msg.highlight = state;
        }
      }
      prepared.add(msg);
    }
    final c = chat.ensure(channel);
    final inserted = c.receiveHistory(
      prepared,
      rawHistory: history,
      maxMessages: host.maxMessages,
    );
    final mirrored = [
      for (final m in inserted)
        if (m.highlight?.hasMention ?? false) m,
    ];
    if (mirrored.isNotEmpty) {
      chat.mentions.add(mirrored, maxMessages: host.maxMessages);
    }
    c.info.touch();
    c.moveConnectedToTop();
  }

  void onReconnected() {
    for (final channel in List.of(chat.names)) {
      unawaited(refetchHistory(channel));
    }
  }

  Future<void> refetchHistory(String channel) async {
    if (!(chat.channelFor(channel)?.info.historyLoaded ?? false) ||
        _refetchingChannels.contains(channel)) {
      return;
    }
    _refetchingChannels.add(channel);
    try {
      final history = await recentMessages.fetchRecent(
        channel,
        limit: host.recentMessagesLimit,
      );
      if (!host.isMounted() || !chat.contains(channel)) return;
      final existing = chat.channelFor(channel)?.messages;
      if (existing == null || history.isEmpty) return;
      // Messages recovered from history after a reconnect gap are marked as
      // backfill so they render greyed out, distinct from live chat.
      for (final msg in history) {
        msg.isBackfill = true;
      }
      host.mutate(() {
        mergeHistory(channel, history);
      });
    } catch (e) {
      logDebug('[HomeScreen] history re-fetch failed for $channel: $e');
    } finally {
      _refetchingChannels.remove(channel);
    }
  }

  /// Translates join-queue progress into a live countdown system line
  /// ("Joining: position 12, ~14s"); position 0 means numbers are over
  /// (sent, awaiting echo) and the line degrades to a plain marker; a null
  /// [info] retires the line.
  void onJoinProgress(String channel, JoinProgress? info) {
    final id = 'join_wait_$channel';
    final messages = chat.channelFor(channel)?.messages;
    if (messages == null) return;
    var changed = false;
    if (info == null) {
      changed = messages.removeSystem(id);
    } else {
      final text = info.position <= 0
          ? 'Joining #$channel...'
          : info.etaSeconds <= 0
          ? 'Joining: position ${info.position}'
          : 'Joining: position ${info.position}, ~${info.etaSeconds}s';
      changed = messages.upsertSystem(text, messageId: id);
    }
    if (!changed) return;
    // Upsert bumps plus emits the id itself; tile eviction follows the
    // mutation fan-out, so no manual tile drop or extra signal here.
    truncateChannel(channel);
  }

  void maybeAddConnected(String channel) {
    chatConn.maybeAddConnected(channel);
  }

  void removeLoadingHistoryMessage(String channel) {
    chat.channelFor(channel)?.messages.removeLoadingHistory();
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
    host.mutate(() {
      chat.ensure(name);
      channelNotifier.value = List.of(chat.names);
      host.atBottomNotifier(name).value = true;
      host.selectedChannel = name;
      selectedTabIndex.value = chat.names.length - 1;
    });
    saveChannels();
    composer.focus();

    chat.channelFor(name)?.messages.addSystem('Loading chat history...');

    recentMessages
        .fetchRecentPreferWarm(name, limit: host.recentMessagesLimit)
        .then((history) {
          if (!host.isMounted()) return;
          chat.channelFor(name)?.info.setHistoryLoaded(true);
          host.mutate(() {
            removeLoadingHistoryMessage(name);
            if (history.isEmpty) {
              host.addSystemMessage(name, 'No chat history available');
            } else {
              mergeHistory(name, history);
            }
          });
          maybeAddConnected(name);
        })
        .catchError((e) {
          if (!host.isMounted()) return;
          chat.channelFor(name)?.info.setHistoryLoaded(true);
          host.mutate(() {
            removeLoadingHistoryMessage(name);
            host.addSystemMessage(
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

    if (host.isMounted()) host.markDirty();
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
    chat.channelFor(channel)?.moderation.clearHeld();
    chatConn.lastSentWireText.remove(channel);
    broadcastWidgets.clearChannel(channel);
    // Same-frame cache clears first so no stale tile survives the unmount.
    tileCache.remove(channel);
    host.invalidateCaches();
    final generation = (_generations[channel] ?? 0) + 1;
    _generations[channel] = generation;
    host.mutate(() {
      channelNotifier.value = List.of(chat.names.where((c) => c != channel));
      userStore.removeChannel(channel);
      threads.forgetChannel(channel);
      if (host.selectedChannel == channel) {
        final remaining = chat.names.where((c) => c != channel).toList();
        host.selectedChannel = remaining.isNotEmpty ? remaining.last : null;
        if (remaining.isNotEmpty) {
          selectedTabIndex.value = remaining.length - 1;
        }
      }
      // After reselect so the search field syncs to the new channel.
      host.forgetSearch(channel);
    });
    // Channel disposal lands after the widgets listening to its notifiers
    // have unmounted. The generation guard skips disposal when a rejoin
    // recreated the channel before this callback ran.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!host.isMounted()) return;
      if (_generations[channel] != generation) return;
      if (!chat.contains(channel)) return;
      chat.remove(channel);
      host.disposeChannelNotifiers(channel);
      host.forgetAtBottomNotifier(channel);
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
    if (host.selectedChannel == channel) return;
    unawaited(host.closePanel());
    var clearedUnread = 0;
    void mutate() {
      iosHaptic(HapticFeedback.selectionClick);
      host.selectedChannel = channel;
      composer.refreshCooldown();
      clearedUnread = chat.clearUnread(channel);
      threads.clearOpenThread();
      composer.onChannelChanged();
    }

    if (rebuild) {
      host.mutate(mutate);
    } else {
      mutate();
      // Focus changes (swipes) skip the setState path, so bump the bell's
      // notifier directly to refresh the badge color.
      if (clearedUnread > 0) chat.touchMentions();
    }
    if (clearedUnread > 0 && host.mentionPush) {
      unawaited(notificationService.clearMentionNotifications(channel));
    }
    broadcastWidgets.resetPage();
    selectedTabIndex.value = index;
    chatConn.focusChannel(channel);
  }

  // Retroactive mention scan: runs once on login. Hits are batched and
  // mirrored through Mentions, which sorts newest-first regardless of the
  // (newest-first) channel-buffer iteration order.
  void scanHistoryForMentions() {
    if (_mentionScanDone || session.login == null) return;
    _mentionScanDone = true;
    final hits = <TwitchMessage>[];
    for (final name in chat.names) {
      if (name == mentionsChannel) continue;
      final items = chat.channelFor(name)?.messages.items;
      if (items == null) continue;
      for (final msg in items) {
        if (msg.highlight != null) continue;
        final state = pingManager.evaluate(msg);
        if (state == null || !state.hasMention) continue;
        msg.highlight = state;
        hits.add(msg);
      }
    }
    if (hits.isNotEmpty) {
      chat.mentions.add(hits, maxMessages: host.maxMessages);
    }
  }

  Future<void> loadRecentMessagesConfig() async {
    if (recentMessagesService != null) {
      recentMessages = recentMessagesService!;
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      recentMessagesConfig = RecentMessagesConfig.fromPrefs(prefs);
    } catch (e) {
      logDebug('Failed to load recent-messages config: $e');
    }
    recentMessages = RecentMessagesService(config: recentMessagesConfig);
  }

  void setRecentMessagesMode(RecentMessagesConfig config) {
    if (recentMessagesService != null) return;
    recentMessagesConfig = config;
    host.markDirty();
    recentMessages = RecentMessagesService(config: config);
    unawaited(
      SharedPreferences.getInstance().then((prefs) => config.toPrefs(prefs)),
    );
  }
}
