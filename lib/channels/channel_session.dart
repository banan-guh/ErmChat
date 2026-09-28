import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chat/chat.dart';
import '../client/session.dart';
import '../irc/transport/read.dart';
import '../irc/transport/write.dart';
import '../services/analytics_service.dart';
import '../services/chat_connection_manager.dart';
import '../services/chat_history_controller.dart';
import '../services/emote_manager.dart';
import '../services/recent_messages.dart';
import '../services/stream_player_controller.dart';
import '../services/twitch_badge_service.dart';
import '../services/user_store.dart';
import '../util/constants.dart';
import '../util/log.dart';
import '../util/prefs.dart';

// Channel membership, history backfill, and selection without any UI
// dependency. The kernel `Chat` owns the registry itself; this session owns
// the join/leave plumbing, robotty history merge, join-queue progress lines,
// and the single selection commit. The UI half wraps this and reacts to the
// notifier.
class ChannelSession extends ChangeNotifier {
  ChannelSession({
    required this.chat,
    required this.session,
    required this.chatConn,
    required this.irc,
    required this.ircRead,
    required this.emoteManager,
    required this.badgeService,
    required this.analytics,
    required this.streamPlayer,
    required this.userStore,
    required this.history,
    required this.recentMessagesService,
    required this.selectedChannel,
    required this.setSelectedChannel,
    required this.maxMessages,
    required this.recentMessagesLimit,
  });

  final Chat chat;
  final Session session;
  final ChatConnectionManager chatConn;
  final IrcService irc;
  final IrcReadService ircRead;
  final EmoteManager emoteManager;
  final TwitchBadgeService badgeService;
  final AnalyticsService analytics;
  final StreamPlayerController streamPlayer;
  final UserStore userStore;
  final ChatHistoryController history;
  final RecentMessagesService? recentMessagesService;
  final String? Function() selectedChannel;
  final void Function(String? channel) setSelectedChannel;
  final int Function() maxMessages;
  final int Function() recentMessagesLimit;

  bool _disposed = false;
  bool _channelsLoaded = false;
  final _generations = <String, int>{};
  final _leaving = <String>{};
  bool _mentionScanDone = false;

  /// Channel names as the UI should render them: the registry order minus any
  /// channel pending deferred disposal, so a leaving channel unmounts before
  /// the kernel drops it.
  List<String> get channelNames => _leaving.isEmpty
      ? chat.names
      : List.unmodifiable(chat.names.where((c) => !_leaving.contains(c)));

  late RecentMessagesService recentMessages;
  RecentMessagesConfig recentMessagesConfig = RecentMessagesConfig();

  /// Re-arm the once-per-login mention scan after an account switch.
  void rearmMentionScan() => _mentionScanDone = false;

  /// Marks the session disposed so async history continuations skip their
  /// post-await writes. The provider owns the lifecycle.
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void truncateChannel(String channel) {
    chat.channelFor(channel)?.truncate(maxMessages());
  }

  void touchMentions() => chat.touchMentions();

  Future<void> saveChannels([List<String>? names]) async {
    final prefs = await Prefs.load();
    await prefs.setChannels(List.of(names ?? chat.names));
  }

  void reorderChannels(List<String> reordered) {
    chat.reorder(reordered);
    notifyListeners();
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
    }
    setSelectedChannel(chat.names.first);
    notifyListeners();
    for (final name in saved) {
      subscribeChannel(name);
      recentMessages
          .fetchRecentPreferWarm(name, limit: recentMessagesLimit())
          .then((rows) {
            if (_disposed || !chat.contains(name)) return;
            chat.channelFor(name)?.setHistoryLoaded(true);
            if (rows.isEmpty) {
              _addSystemMessage(name, 'No chat history available');
            } else {
              history.mergeHistory(name, rows);
            }
            notifyListeners();
            maybeAddConnected(name);
          })
          .catchError((e) {
            if (_disposed || !chat.contains(name)) return;
            chat.channelFor(name)?.setHistoryLoaded(true);
            _addSystemMessage(
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

  Future<void> subscribeChannel(String channelName) async {
    chatConn.subscribeChannel(channelName);
  }

  void focusChannel(String channel) => chatConn.focusChannel(channel);

  /// Joins [channelName] and starts its history backfill. Returns false when
  /// the name is empty, already joined, or the channel cap is reached.
  Future<bool> addChannel(String channelName) async {
    final name = channelName.trim().toLowerCase();
    if (name.isEmpty || chat.contains(name)) return false;
    if (chat.length >= kMaxChannels) return false;

    _generations[name] = (_generations[name] ?? 0) + 1;
    chat.ensure(name);
    setSelectedChannel(name);
    notifyListeners();
    saveChannels();

    chat.channelFor(name)?.addLoadingHistory();

    recentMessages
        .fetchRecentPreferWarm(name, limit: recentMessagesLimit())
        .then((rows) {
          if (_disposed || !chat.contains(name)) return;
          chat.channelFor(name)?.setHistoryLoaded(true);
          removeLoadingHistoryMessage(name);
          if (rows.isEmpty) {
            _addSystemMessage(name, 'No chat history available');
          } else {
            history.mergeHistory(name, rows);
          }
          notifyListeners();
          maybeAddConnected(name);
        })
        .catchError((e) {
          if (_disposed || !chat.contains(name)) return;
          chat.channelFor(name)?.setHistoryLoaded(true);
          removeLoadingHistoryMessage(name);
          _addSystemMessage(
            name,
            e is RecentMessagesException
                ? e.message
                : 'Failed to load chat history',
          );
          notifyListeners();
          maybeAddConnected(name);
        });

    logDebug('[HomeScreen] joining channel: $name');
    await subscribeChannel(name);
    chatConn.focusChannel(name);
    if (!_disposed) notifyListeners();
    return true;
  }

  /// Non-UI half of leaving [channel]: parts the sockets and tears down the
  /// channel-scoped services. The UI half clears its caches, then calls
  /// [finalizeRemove] post-frame so disposal lands after the widgets that
  /// listen to the channel's notifiers have unmounted. Returns the generation
  /// that [finalizeRemove] must still match, so a rejoin wins the race.
  int beginRemove(String channel) {
    chatConn.stopChatStatusTimer(channel);
    chatConn.forgetChannel(channel);
    analytics.resetChannel(channel);
    if (streamPlayer.currentChannel == channel) streamPlayer.closeStream();
    irc.part(channel);
    ircRead.part(channel);
    emoteManager.evictChannel(channel);
    badgeService.clearChannel(channel);
    chat.channelFor(channel)?.clearHeldModeration();
    _leaving.add(channel);
    final generation = (_generations[channel] ?? 0) + 1;
    _generations[channel] = generation;
    userStore.removeChannel(channel);
    if (selectedChannel() == channel) {
      final remaining = chat.names.where((c) => c != channel).toList();
      setSelectedChannel(remaining.isNotEmpty ? remaining.last : null);
    }
    notifyListeners();
    saveChannels(chat.names.where((c) => c != channel).toList());
    return generation;
  }

  /// Drops [channel] from the kernel when no rejoin recreated it. Returns
  /// false when the generation moved on or the channel is already gone.
  bool finalizeRemove(String channel, int generation) {
    if (_generations[channel] != generation) return false;
    _leaving.remove(channel);
    if (!chat.contains(channel)) return false;
    chat.remove(channel);
    return true;
  }

  /// Commits [channel] as the selected channel and returns the unread mention
  /// count it cleared, or null when [channel] was already selected.
  int? selectChannel(String channel) {
    if (selectedChannel() == channel) return null;
    setSelectedChannel(channel);
    return chat.clearUnread(channel);
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
    recentMessages = RecentMessagesService(config: config);
    unawaited(Prefs.load().then((prefs) => config.toPrefs(prefs)));
  }

  void _addSystemMessage(String channel, String text) {
    chat
        .channelFor(channel)
        ?.addSystemMessage(text, maxMessages: maxMessages());
  }
}
