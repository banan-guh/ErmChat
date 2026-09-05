import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../composer/composer_controller.dart';
import '../models/twitch_message.dart';
import '../panels/threads.dart';
import '../services/analytics_service.dart';
import '../services/chat_connection_manager.dart';
import '../services/chat_store.dart';
import '../services/emote_manager.dart';
import '../services/ignore_manager.dart';
import '../services/notification_service.dart';
import '../services/ping_manager.dart';
import '../services/recent_messages.dart';
import '../services/stream_player_controller.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_badge_service.dart';
import '../services/twitch_irc.dart';
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
  ValueNotifier<int> versionNotifier(String channel);
  ValueNotifier<int> messageNotifier(String channel);
  ValueNotifier<bool> atBottomNotifier(String channel);
  void disposeChannelNotifiers(String channel);
  void forgetAtBottomNotifier(String channel);
}

// Channel membership, history backfill, and selection: the join/leave
// plumbing, robotty history merge, join-queue progress lines, and the
// single selection commit behind swipe-tick focus and settle/tab-tap.
class ChannelManager {
  ChannelManager({
    required this.chatStore,
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

  final ChatStore chatStore;
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
  bool _mentionScanDone = false;

  /// Re-arm the once-per-login mention scan after an account switch.
  void rearmMentionScan() => _mentionScanDone = false;
  late RecentMessagesService recentMessages;
  RecentMessagesConfig recentMessagesConfig = RecentMessagesConfig();

  void truncateChannel(String channel) {
    chatStore.truncateChannel(channel, maxMessages: host.maxMessages);
  }

  Future<void> saveChannels() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('channels', List.of(chatStore.channels));
  }

  void reorderChannels(List<String> reordered) {
    chatStore.channels
      ..clear()
      ..addAll(reordered);
    channelNotifier.value = List.of(chatStore.channels);
    if (host.selectedChannel != null) {
      final newIdx = chatStore.channels.indexOf(host.selectedChannel!);
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
      if (chatStore.channels.contains(name)) continue;
      chatStore.channels.add(name);
      chatStore.channelMessages.putIfAbsent(name, () => []);
      host.atBottomNotifier(name).value = true;
    }
    channelNotifier.value = List.of(chatStore.channels);
    host.selectedChannel = chatStore.channels.first;
    selectedTabIndex.value = 0;
    if (host.isMounted()) host.markDirty();
    for (final name in saved) {
      subscribeChannel(name);
      recentMessages
          .fetchRecentPreferWarm(name, limit: host.recentMessagesLimit)
          .then((history) {
            if (!host.isMounted()) return;
            chatStore.historyLoaded.add(name);
            host.mutate(() {
              if (history.isEmpty) {
                host.addSystemMessage(name, 'No chat history available');
              } else {
                mergeHistoryIntoChannel(name, history);
              }
            });
            maybeAddConnected(name);
          })
          .catchError((e) {
            if (!host.isMounted()) return;
            chatStore.historyLoaded.add(name);
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

  // Merges robotty history into the channel message list (newest-first).
  // Messages whose messageId is already on screen are discarded as duplicates,
  // mentions are surfaced in the mentions panel, and a gap note is inserted at
  // the history boundary when the fetched window doesn't reach back to the
  // messages already displayed (only possible on reconnect re-fetches).
  // The merged list is sorted by timestamp (DankChat-style) so re-fetched
  // history slots below messages that arrived after it - live messages are
  // never pushed under older history.
  void mergeHistoryIntoChannel(String channel, List<TwitchMessage> history) {
    final existing = chatStore.channelMessages[channel]!;
    final existingIds = existing.map((m) => m.messageId).toSet();
    var hasExistingNonSystem = false;
    for (final m in existing) {
      if (!m.isSystem) {
        hasExistingNonSystem = true;
        break;
      }
    }
    final insertedIds = <String?>{};
    final insertedMsgs = <TwitchMessage>[];
    final mentionHits = <TwitchMessage>[];
    var insertedCount = 0;
    for (final msg in history) {
      // Locally ignored users' history never renders (matches the live gate).
      if (!msg.isSystem && ignoreManager.isIgnored(msg.login)) continue;
      if (!msg.isSystem && msg.login.isNotEmpty) {
        final preferred =
            msg.displayName.toLowerCase() == msg.login.toLowerCase()
            ? msg.displayName
            : msg.login;
        userStore.addUser(channel, preferred);
      }
      final id = msg.messageId;
      // Ban lines and NOTICEs carry no message id, so a backfill that
      // overlaps what already arrived live would double them up. Fold an
      // id-less system row into an identical row near the same time.
      if (id == null &&
          msg.isSystem &&
          _isDuplicateIdlessSystemRow(existing, insertedMsgs, msg)) {
        continue;
      }
      final isNew =
          id == null ||
          (!existingIds.contains(id) && !insertedIds.contains(id));
      if (isNew) {
        if (msg.isSystem && chatStore.session.login != null) {
          final selfLogin = chatStore.session.login!.toLowerCase();
          if (msg.login.toLowerCase() == selfLogin) {
            msg.text = msg.text.replaceFirst(
              RegExp(RegExp.escape(msg.login), caseSensitive: false),
              'You',
            );
            msg.text = msg.text.replaceFirst('was', 'were');
          }
        }
        if (id != null) insertedIds.add(id);
        existing.add(msg);
        insertedMsgs.add(msg);
        insertedCount++;
      }
      if (msg.messageId != null) {
        chatStore.messageKeys.add('$channel:${msg.messageId}');
      }
      // Evaluate rules even while logged out: custom/user/badge/event rules
      // need no account, and live ingestion already evaluates anonymously.
      if (msg.highlight == null) {
        final state = pingManager.evaluate(msg);
        if (state != null && state.hasMention) {
          msg.highlight = state;
          mentionHits.add(msg);
        }
      }
    }
    if (mentionHits.isNotEmpty) {
      chatStore.mirrorMentions(
        mentionsChannel,
        mentionHits,
        maxMessages: host.maxMessages,
      );
    }
    if (hasExistingNonSystem &&
        insertedCount > 0 &&
        !history.any(
          (m) => m.messageId != null && existingIds.contains(m.messageId),
        )) {
      // 1ms before the oldest fetched message so the note sorts directly
      // below the history block.
      final oldestHistory = history
          .map((m) => m.timestamp)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      existing.add(
        TwitchMessage(
          login: '',
          text: 'History: Not all messages retrieved',
          isSystem: true,
          channel: channel,
          timestamp: oldestHistory.subtract(const Duration(milliseconds: 1)),
        ),
      );
    }
    // Chronological order, newest first (index 0 = newest).
    existing.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    truncateChannel(channel);
    // Index freshly fetched rows into the thread store so threads recovered
    // by backfill (cold start, reconnect) stay viewable past buffer trimming.
    // Runs after the merge so roots inserted in the same batch link up.
    if (insertedMsgs.isNotEmpty) {
      chatStore.indexMessages(channel, insertedMsgs);
    }
    chatStore.touchChannel(channel);
    moveConnectedMessageToTop(channel);
  }

  /// True when an id-less system row from history duplicates a system row
  /// already on screen or just inserted from this batch: identical text and
  /// a timestamp inside [_systemDedupWindow]. Robotty's receive timestamp
  /// and the live arrival clock differ by at most a couple of seconds, so
  /// true copies land well inside the window while distinct repeats of the
  /// same line stay out.
  static const _systemDedupWindow = Duration(seconds: 10);

  bool _isDuplicateIdlessSystemRow(
    List<TwitchMessage> existing,
    List<TwitchMessage> inserted,
    TwitchMessage candidate,
  ) {
    for (final row in existing) {
      if (_isSameSystemEvent(row, candidate)) return true;
    }
    for (final row in inserted) {
      if (_isSameSystemEvent(row, candidate)) return true;
    }
    return false;
  }

  bool _isSameSystemEvent(TwitchMessage a, TwitchMessage b) {
    return a.isSystem &&
        a.text == b.text &&
        a.timestamp.difference(b.timestamp).abs() <= _systemDedupWindow;
  }

  void onReconnected() {
    for (final channel in List.of(chatStore.channels)) {
      unawaited(refetchHistory(channel));
    }
  }

  Future<void> refetchHistory(String channel) async {
    if (!chatStore.historyLoaded.contains(channel) ||
        _refetchingChannels.contains(channel)) {
      return;
    }
    _refetchingChannels.add(channel);
    try {
      final history = await recentMessages.fetchRecent(
        channel,
        limit: host.recentMessagesLimit,
      );
      if (!host.isMounted() || !chatStore.channels.contains(channel)) return;
      final existing = chatStore.channelMessages[channel];
      if (existing == null || history.isEmpty) return;
      // Messages recovered from history after a reconnect gap are marked as
      // backfill so they render greyed out, distinct from live chat.
      for (final msg in history) {
        msg.isBackfill = true;
      }
      host.mutate(() {
        mergeHistoryIntoChannel(channel, history);
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
    var changed = false;
    if (info == null) {
      changed = chatStore.removeSystemMessage(channel, id);
    } else {
      final text = info.position <= 0
          ? 'Joining #$channel...'
          : info.etaSeconds <= 0
          ? 'Joining: position ${info.position}'
          : 'Joining: position ${info.position}, ~${info.etaSeconds}s';
      changed = chatStore.upsertSystemMessage(channel, text, messageId: id);
    }
    if (!changed) return;
    // Upsert mutates the row's text in place: drop the cached tile or the
    // list keeps rendering the first countdown values forever.
    tileCache[channel]?.remove(id);
    truncateChannel(channel);
    chatStore.noteNewMessage(channel);
  }

  void maybeAddConnected(String channel) {
    chatConn.maybeAddConnected(channel);
  }

  void removeLoadingHistoryMessage(String channel) {
    chatStore.channelMessages[channel]?.removeWhere(
      (m) => m.isSystem && m.text == 'Loading chat history...',
    );
  }

  // "Connected" is emitted as soon as IRC is up, which is usually before
  // the robotty history fetch completes. History messages are then inserted
  // above it, so move the newest connect-state line ("Reconnected" on a
  // reconnect, otherwise "Connected") back to the most recent position to
  // stay visible.
  void moveConnectedMessageToTop(String channel) {
    final msgs = chatStore.channelMessages[channel];
    if (msgs == null || msgs.length < 2) return;
    int idx = msgs.indexWhere((m) => m.isSystem && m.text == 'Reconnected');
    if (idx < 0) {
      idx = msgs.indexWhere(
        (m) =>
            m.isSystem &&
            (m.text == 'Connected' || m.text == 'Connected to IRC'),
      );
    }
    if (idx <= 0) return;
    final msg = msgs.removeAt(idx);
    msgs.insert(0, msg);
    chatStore.touchChannel(channel);
  }

  Future<void> subscribeChannel(String channelName) async {
    chatConn.subscribeChannel(channelName);
  }

  Future<void> addChannel(String channelName) async {
    final name = channelName.trim().toLowerCase();
    if (name.isEmpty || chatStore.channels.contains(name)) return;
    if (chatStore.channels.length >= kMaxChannels) return;

    host.mutate(() {
      chatStore.channels.add(name);
      channelNotifier.value = List.of(chatStore.channels);
      chatStore.channelMessages.putIfAbsent(name, () => []);
      host.atBottomNotifier(name).value = true;
      host.selectedChannel = name;
      selectedTabIndex.value = chatStore.channels.length - 1;
    });
    saveChannels();
    composer.focus();

    final loadingMsg = TwitchMessage(
      login: '',
      text: 'Loading chat history...',
      isSystem: true,
      channel: name,
    );
    chatStore.channelMessages[name]!.insert(0, loadingMsg);

    recentMessages
        .fetchRecentPreferWarm(name, limit: host.recentMessagesLimit)
        .then((history) {
          if (!host.isMounted()) return;
          chatStore.historyLoaded.add(name);
          host.mutate(() {
            removeLoadingHistoryMessage(name);
            if (history.isEmpty) {
              host.addSystemMessage(name, 'No chat history available');
            } else {
              mergeHistoryIntoChannel(name, history);
            }
          });
          maybeAddConnected(name);
        })
        .catchError((e) {
          if (!host.isMounted()) return;
          chatStore.historyLoaded.add(name);
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
    chatStore.channelsEmotesResolved.remove(channel);
    chatStore.historyLoaded.remove(channel);
    // Sync, unlike forgetChannel below: the global heldVersion has no
    // per-channel listeners to protect, so the queue dies with the channel.
    chatStore.clearHeldMessages(channel);
    chatStore.channelUserIds.remove(channel);
    chatStore.lastSentWireText.remove(channel);
    chatStore.chatStatus.remove(channel);
    broadcastWidgets.clearChannel(channel);
    // Per-channel notifiers and tile state must die with the channel: a
    // re-joined channel would otherwise reuse stale notifiers and an old
    // frozen snapshot, and the maps would grow for the session.
    tileCache.remove(channel);
    host.mutate(() {
      chatStore.channels.remove(channel);
      channelNotifier.value = List.of(chatStore.channels);
      chatStore.channelMessages.remove(channel);
      userStore.removeChannel(channel);
      host.disposeChannelNotifiers(channel);
      chatStore.channelsWithUnread.remove(channel);
      chatStore.channelsWithUnreadMentions.remove(channel);
      chatStore.unreadVersion.value++;
      final removedUnread =
          chatStore.unreadMentionsPerChannel.remove(channel) ?? 0;
      if (removedUnread > 0) {
        chatStore.unreadMentions -= removedUnread;
        if (chatStore.unreadMentions < 0) chatStore.unreadMentions = 0;
      }
      chatStore.messageKeys.removeWhere((k) => k.startsWith('$channel:'));
      threads.forgetChannel(channel);
      if (host.selectedChannel == channel) {
        host.selectedChannel = chatStore.channels.isNotEmpty
            ? chatStore.channels.last
            : null;
        if (chatStore.channels.isNotEmpty) {
          selectedTabIndex.value = chatStore.channels.length - 1;
        }
      }
    });
    // Notifier disposal must land after the widgets listening to them have
    // actually unmounted (the frame the mutate above schedules); disposing
    // earlier makes their removeListener hit a disposed notifier in debug
    // builds when leaving a channel.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!host.isMounted()) return;
      host.forgetAtBottomNotifier(channel);
      chatStore.forgetChannel(channel);
    });
    saveChannels();
  }

  // Single selection commit for BOTH entry points (swipe-tick focus and
  // settle/tab-tap). Whichever lands first owns the side effects; the shared
  // guard makes the second one a no-op, so bookkeeping runs exactly once per
  // real switch regardless of gesture timing.
  void commitChannelSelection(int index, {required bool rebuild}) {
    final channel = chatStore.channels[index];
    if (host.selectedChannel == channel) return;
    unawaited(host.closePanel());
    var clearedUnread = 0;
    void mutate() {
      iosHaptic(HapticFeedback.selectionClick);
      host.selectedChannel = channel;
      composer.refreshCooldown();
      chatStore.channelsWithUnread.remove(channel);
      chatStore.channelsWithUnreadMentions.remove(channel);
      chatStore.unreadVersion.value++;
      clearedUnread = chatStore.unreadMentionsPerChannel.remove(channel) ?? 0;
      if (clearedUnread > 0) {
        chatStore.unreadMentions -= clearedUnread;
        if (chatStore.unreadMentions < 0) chatStore.unreadMentions = 0;
      }
      threads.clearOpenThread();
      composer.onChannelChanged();
    }

    if (rebuild) {
      host.mutate(mutate);
    } else {
      mutate();
      // Focus changes (swipes) skip the setState path, so bump the bell's
      // notifier directly to refresh the badge color.
      if (clearedUnread > 0) chatStore.mentionsBump.value++;
    }
    if (clearedUnread > 0 && host.mentionPush) {
      unawaited(notificationService.clearMentionNotifications(channel));
    }
    broadcastWidgets.resetPage();
    selectedTabIndex.value = index;
    chatConn.focusChannel(channel);
  }

  // Retroactive mention scan: runs once on login. Hits are batched and
  // mirrored through ChatStore, which sorts the mentions buffer newest-first
  // regardless of the (newest-first) channel-buffer iteration order.
  void scanHistoryForMentions() {
    if (_mentionScanDone || chatStore.session.login == null) return;
    _mentionScanDone = true;
    final hits = <TwitchMessage>[];
    for (final entry in chatStore.channelMessages.entries) {
      if (entry.key == mentionsChannel) continue;
      for (final msg in entry.value) {
        if (msg.highlight != null) continue;
        final state = pingManager.evaluate(msg);
        if (state == null || !state.hasMention) continue;
        msg.highlight = state;
        hits.add(msg);
      }
    }
    if (hits.isNotEmpty) {
      chatStore.mirrorMentions(
        mentionsChannel,
        hits,
        maxMessages: host.maxMessages,
      );
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
