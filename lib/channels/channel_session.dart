import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chat/chat.dart';
import '../client/session.dart';
import '../irc/transport/read.dart';
import '../l10n/l10n.dart';
import '../models/twitch_message.dart';
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
import '../util/fake_history.dart';
import '../util/log.dart';
import '../util/prefs.dart';
import '../util/settings.dart';

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
    this.strings = englishStrings,
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
  final AppLocalizations Function() strings;
  final int Function() recentMessagesLimit;

  bool _disposed = false;
  bool _channelsLoaded = false;
  bool _channelsRestored = false;

  /// Saved channels not yet restored, so the chrome opens compact instead
  /// of showing the welcome bar until they join.
  bool get channelsPending =>
      !_channelsRestored && (Prefs.loaded?.channels.isNotEmpty ?? false);
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

  Future<void> saveChannels() async {
    final prefs = await Prefs.load();
    // channelNames skips channels mid-leave, which the kernel still holds.
    await prefs.setChannels(List.of(channelNames));
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
    _channelsRestored = true;
    // Registry files outlive joins; sweep ones whose channel is gone.
    unawaited(emoteManager.pruneStaleChannels(saved.toSet()));
    if (saved.isEmpty) return;
    for (final name in saved) {
      if (chat.contains(name)) continue;
      chat.ensure(name);
    }
    final last = Settings.lastChannel.value;
    setSelectedChannel(
      Settings.reopenLastChannel.value && last != null && chat.contains(last)
          ? last
          : chat.names.first,
    );
    notifyListeners();
    for (final name in saved) {
      subscribeChannel(name);
      final at = history.now();
      _fetchHistory(name)
          .then((rows) {
            if (_disposed || !chat.contains(name)) return;
            chat.channelFor(name)?.setHistoryLoaded(true);
            if (rows.isEmpty) {
              _noteEmptyHistory(name);
            } else {
              history.mergeHistory(name, rows);
            }
            notifyListeners();
            maybeAddConnected(name);
          })
          .catchError((e) {
            if (_disposed || !chat.contains(name)) return;
            chat.channelFor(name)?.setHistoryLoaded(true);
            history.noteFetchFailed(name, at);
            _addSystemMessage(
              name,
              e is RecentMessagesException
                  ? e.message
                  : strings().historyLoadFailed,
            );
            maybeAddConnected(name);
          });
    }
  }

  /// Archived rows first (when an archive is wired), then the network history, which
  /// dedups against them by id.
  Future<List<TwitchMessage>> _fetchHistory(String name) {
    Future<List<TwitchMessage>> fetch() => recentMessages.fetchRecentPreferWarm(
      name,
      limit: recentMessagesLimit(),
    );
    if (history.archive == null) return fetch();
    // Both start now; the network rows wait for the archived ones only so the
    // merge sees them, and so the gap fill knows the last row held.
    final network = fetch();
    return Future.wait<Object?>([
      history.restoreFromArchive(name),
      network,
    ]).then((_) async => history.fillGap(name, await network));
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
    // A channel mid-leave still sits in the kernel until its finalize.
    if (channelNames.length >= kMaxChannels) return false;

    _generations[name] = (_generations[name] ?? 0) + 1;
    chat.ensure(name);
    setSelectedChannel(name);
    notifyListeners();
    saveChannels();

    chat.channelFor(name)?.addLoadingHistory();

    final at = history.now();
    _fetchHistory(name)
        .then((rows) {
          if (_disposed || !chat.contains(name)) return;
          chat.channelFor(name)?.setHistoryLoaded(true);
          removeLoadingHistoryMessage(name);
          if (rows.isEmpty) {
            _noteEmptyHistory(name);
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
          history.noteFetchFailed(name, at);
          _addSystemMessage(
            name,
            e is RecentMessagesException
                ? e.message
                : strings().historyLoadFailed,
          );
          notifyListeners();
          maybeAddConnected(name);
        });

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
    if (!FakeHistory.isFake(channel)) {
      irc.part(channel);
      ircRead.part(channel);
    }
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
    saveChannels();
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
    try {
      final prefs = await Prefs.load();
      recentMessagesConfig = RecentMessagesConfig.fromPrefs(prefs);
    } catch (e) {
      logDebug('Failed to load recent-messages config: $e');
    }
    recentMessages =
        recentMessagesService ??
        RecentMessagesService(strings: strings, ownLogin: () => session.login);
    recentMessages.config = recentMessagesConfig;
  }

  /// Applies a new source setting from the next fetch.
  void setRecentMessagesMode(RecentMessagesConfig config) {
    recentMessagesConfig = config;
    recentMessages.config = config;
    unawaited(Prefs.load().then((prefs) => config.toPrefs(prefs)));
  }

  // Empty fetch: "no history" unless the archive restored chat. Then robotty
  // simply has nothing newer, which is no gap. Partial fetches mark theirs in
  // merge.
  // TODO: mark a likely gap when the newest restored row is older than
  // robotty's retention window, without adding a row on every launch.
  void _noteEmptyHistory(String channel) {
    final restored =
        chat.channelFor(channel)?.messages.items.any((m) => !m.isSystem) ??
        false;
    if (!restored) _addSystemMessage(channel, strings().noChatHistory);
  }

  void _addSystemMessage(String channel, String text) {
    chat
        .channelFor(channel)
        ?.addSystemMessage(text, maxMessages: maxMessages());
  }
}
