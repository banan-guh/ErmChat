import 'dart:async';

import 'dart:convert';

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../chat/chat.dart';
import '../client/session.dart';
import '../util/constants.dart';
import '../util/log.dart';
import '../irc/decode/events.dart' show IrcRoomStateEvent;
import '../irc/transport/events.dart'
    show IrcJoinFailureEvent, JoinFailureReason;
import '../irc/transport/read.dart' show IrcReadService;
import '../irc/transport/write.dart' show IrcService;
import 'emote_manager.dart';
import 'chat_status_composer.dart';
import 'seven_tv_event_client.dart';
import 'twitch_api.dart';
import 'twitch_auth.dart';
import 'twitch_badge_service.dart';
import '../eventsub/decode/decoder.dart';
import '../eventsub/topics.dart';
import 'user_store.dart';

/// The channel-domain of the pipeline: joining channels and resolving their
/// per-channel data (Helix user IDs, badges, emotes, 7TV sockets) plus the
/// chat-status composition from ROOMSTATE tags and periodic stream fetches.
/// Unlike [ChatIngestion] this class owns no stream subscriptions: the manager
/// routes IRC events into [handleRoomState]/[handleJoinFailed], and channel
/// subscriptions run on demand through [subscribeChannel].
class ChatChannelSetup {
  ChatChannelSetup({
    required this.twitchApi,
    required this.eventSubDecoder,
    required this.eventSubTopics,
    required this.irc,
    required this.ircRead,
    this.sevenTvClient,
    required this.badgeService,
    required this.emoteManager,
    required this.twitchAuth,
    required this.userStore,
    required this.session,
    required this.chat,
    required this.onSystemMessage,
    required this.connectionStateNotifier,
    this.onUserEmoteSets,
    required this.ensureCurrentUser,
  });

  final TwitchApi twitchApi;
  final EventSubDecoder eventSubDecoder;
  final EventSubTopics eventSubTopics;
  final IrcService irc;
  final IrcReadService ircRead;
  final SevenTvEventClient? sevenTvClient;
  final TwitchBadgeService badgeService;
  final EmoteManager emoteManager;
  final TwitchAuth twitchAuth;
  final UserStore userStore;
  final Session session;
  final Chat chat;

  final void Function(
    String channel,
    String text, {
    Color? accent,
    String? messageId,
  })
  onSystemMessage;
  final ValueNotifier<int> connectionStateNotifier;
  final Future<void> Function(String?, List<String>)? onUserEmoteSets;

  /// Current-user lookup shared with the manager's connect path; the single
  /// in-flight dedup lives there.
  final Future<Map<String, dynamic>?> Function(TwitchAuth auth)
  ensureCurrentUser;

  bool _disposed = false;
  final _httpClient = http.Client();

  // Chat status splash: ROOMSTATE mode tags plus periodic Helix stream info.
  late final ChatStatusComposer _status = ChatStatusComposer(
    twitchApi: twitchApi,
    twitchAuth: twitchAuth,
    chat: chat,
    session: session,
  );

  /// In-flight 7TV ID lookups by Twitch channel id. Concurrent joins for the
  /// same channel share one GET instead of each firing their own.
  final _sevenTvIdInflight =
      <String, Future<({String userId, String emoteSetId})?>>{};

  // Channels a join-failure notice was displayed for. A later ROOMSTATE
  // confirmation clears the entry and announces the (late) success.
  final _joinFailureNotified = <String>{};

  void dispose() {
    _disposed = true;
    _status.dispose();
    // Release any anonymous channel-user-ID waiters so their timeout timers
    // don't outlive the manager (and don't trip widget-test teardown).
    for (final waiters in _roomIdWaiters.values) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.complete(null);
      }
    }
    _roomIdWaiters.clear();
    _httpClient.close();
  }

  // ---- State queries -------------------------------------------------------

  /// Whether a join-failure notice was already displayed for the channel
  /// (Twitch's raw refusal NOTICE is suppressed as a duplicate then).
  bool isJoinFailureNotified(String channel) =>
      _joinFailureNotified.contains(channel);

  /// Copy of the merged ROOMSTATE tags for a channel (slow, followers-only,
  /// emote-only, subs-only, r9k). Powers the Mod View mode toggles.
  Map<String, String> roomStateTags(String channel) =>
      _status.roomStateTags(channel);

  /// Failure state is per socket lifetime: the fresh socket runs its own fast
  /// sweep, so it may legitimately fail (and re-announce) again.
  void resetJoinFailureState() => _joinFailureNotified.clear();

  /// Drops per-channel state (channel left) and unsubscribes 7TV.
  void forgetChannel(String channel) {
    eventSubTopics.forgetChannel(channel);
    // Parted channels must not keep server-side 7TV dispatches: lookups run
    // before evictChannel and channelUserIds removal, so IDs are still here.
    final sevenTv = sevenTvClient;
    if (sevenTv != null) {
      final emoteSetId = emoteManager.getSevenTvEmoteSetId(channel);
      if (emoteSetId != null) sevenTv.unsubscribeEmoteSet(emoteSetId);
      final userId = emoteManager.getSevenTvUserId(channel);
      if (userId != null) sevenTv.unsubscribeUser(userId);
      final twitchId = chat.channelFor(channel)?.info.broadcasterId;
      if (twitchId != null) sevenTv.unsubscribeTwitchChannel(twitchId);
    }
  }

  // ---- Status --------------------------------------------------------------

  /// Seconds of the channel's current slow mode from the merged ROOMSTATE
  /// tags; 0 when off (missing/empty/0 all mean off).
  int slowModeSeconds(String channel) => _status.slowModeSeconds(channel);

  void stopChatStatusTimer(String channel) => _status.stopFor(channel);

  // ---- Subscriptions -------------------------------------------------------

  Future<void> subscribeChannel(String channelName) async {
    // Only the read socket JOINs: Twitch delivers chat on the socket that sent
    // JOIN, and PRIVMSG sends fine without joining. Joining on the write socket
    // too just wastes the 20/10s budget and (when the limiter was shared) raced
    // the read socket for the single JOIN slot per channel.
    ircRead.join(channelName);

    try {
      final auth = twitchAuth;
      var channelUserId = auth.accessToken != null
          ? await twitchApi.getUserId(auth, channelName)
          : null;
      // Anonymous: Helix 401s without a token, so the channel user ID comes
      // from the IRC ROOMSTATE room-id tag instead (powers the third-party
      // emote providers and badge fetches).
      channelUserId ??= await _waitForRoomId(channelName);
      if (channelUserId == null) return;
      chat.channelFor(channelName)?.info.setBroadcasterId(channelUserId);
      // Map before any await below: a resubscribe completing in the gap
      // would otherwise deliver events with no channel and drop them.
      eventSubDecoder.setChannelMapping(channelUserId, channelName);
      unawaited(
        badgeService
            .fetchChannelBadges(auth, channelUserId, channelName)
            .then((_) => chat.clearLoadFailure(channelName, 'badges'))
            .catchError((_) {
              chat.recordLoadFailure(channelName, 'badges');
              logDebug('[ChatConn] fetchChannelBadges failed for $channelName');
            }),
      );

      emoteManager.accessToken = auth.accessToken;
      logDebug(
        'subscribeChannel $channelName userId=$channelUserId '
        'hasToken=${auth.accessToken != null} resolved=${emoteManager.emotesResolved(channelName)}',
      );
      if (!emoteManager.emotesResolved(channelName)) {
        emoteManager.markEmotesResolved(channelName);
        unawaited(
          emoteManager
              .resolveEmotes(channelName, channelUserId)
              .then((_) => chat.clearLoadFailure(channelName, 'emotes'))
              .catchError((e) {
                chat.recordLoadFailure(channelName, 'emotes');
                logDebug(
                  '[ChatConn] resolveEmotes failed for $channelName: $e',
                );
              }),
        );
      }

      unawaited(_resolveSevenTvAndSubscribe(channelName, channelUserId));

      if (session.login == null && auth.accessToken != null) {
        final currentUser = await ensureCurrentUser(auth);
        if (currentUser != null) {
          session.apply(currentUser['login'], userId: currentUser['id']);
        }
      }

      eventSubTopics.subscribeChannel(channelName, channelUserId);
    } catch (_) {
      logDebug('[ChatConn] subscribeChannel failed for $channelName');
    }
    connectionStateNotifier.value++;
    _status.startFor(channelName);
  }

  void subscribeAll(List<String> channels) {
    for (final channel in channels) {
      unawaited(subscribeChannel(channel));
    }
  }

  Future<void> _resolveSevenTvAndSubscribe(
    String channelName,
    String twitchChannelId,
  ) async {
    if (sevenTvClient == null) return;

    // Check if EmoteManager already has the IDs from resolveEmotes.
    final cachedEmoteSetId = emoteManager.getSevenTvEmoteSetId(channelName);
    final cachedUserId = emoteManager.getSevenTvUserId(channelName);

    String finalEmoteSetId;
    String finalUserId;

    if (cachedEmoteSetId != null && cachedUserId != null) {
      finalEmoteSetId = cachedEmoteSetId;
      finalUserId = cachedUserId;
    } else {
      // Coalesce concurrent lookups for one channel into a single GET.
      final inflight = _sevenTvIdInflight[twitchChannelId];
      final Future<({String userId, String emoteSetId})?> lookup;
      if (inflight != null) {
        lookup = inflight;
      } else {
        final future = _fetchSevenTvIds(channelName, twitchChannelId);
        _sevenTvIdInflight[twitchChannelId] = future;
        // The copy must not report unhandled errors; awaiters use the original.
        future
            .whenComplete(() => _sevenTvIdInflight.remove(twitchChannelId))
            .ignore();
        lookup = future;
      }
      final ids = await lookup;
      if (ids == null) return;
      finalEmoteSetId = ids.emoteSetId;
      finalUserId = ids.userId;
    }

    sevenTvClient!.subscribeEmoteSet(finalEmoteSetId);
    sevenTvClient!.subscribeUser(finalUserId);
    sevenTvClient!.subscribeTwitchChannel(twitchChannelId);
    logDebug(
      '[7TV] subscribed channel=$channelName emoteSetId=$finalEmoteSetId userId=$finalUserId',
    );
  }

  Future<({String userId, String emoteSetId})?> _fetchSevenTvIds(
    String channelName,
    String twitchChannelId,
  ) async {
    try {
      final uri = Uri.parse('https://7tv.io/v3/users/twitch/$twitchChannelId');
      final res = await _httpClient.get(uri).timeout(httpTimeout);
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final userId = (data['user'] as Map<String, dynamic>?)?['id'] as String?;
      final emoteSetId =
          (data['emote_set'] as Map<String, dynamic>?)?['id'] as String?;
      if (userId == null || emoteSetId == null) return null;
      emoteManager.setSevenTvEmoteSetId(channelName, emoteSetId);
      return (userId: userId, emoteSetId: emoteSetId);
    } catch (_) {
      return null;
    }
  }

  // Anonymous fallback for the channel user ID: ROOMSTATE carries a room-id
  // tag right after JOIN, which Helix normally provides. Waits (bounded) for
  // the ROOMSTATE if it hasn't arrived yet.
  final _roomIdWaiters = <String, List<Completer<String?>>>{};

  Future<String?> _waitForRoomId(
    String channel, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final existing = roomStateTags(channel)['room-id'];
    if (existing != null && existing.isNotEmpty) return existing;
    final completer = Completer<String?>();
    _roomIdWaiters.putIfAbsent(channel, () => []).add(completer);
    try {
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      _roomIdWaiters[channel]?.remove(completer);
      if (_roomIdWaiters[channel]?.isEmpty ?? true) {
        _roomIdWaiters.remove(channel);
      }
    }
  }

  // ---- IRC event handlers (routed by the manager) -------------------------

  /// ROOMSTATE handler: confirms the channel joined, merges the partial mode
  /// tags, completes anonymous room-id waiters and recomposes the status
  /// splash. Returns true because a ROOMSTATE always confirms membership;
  /// the caller records it to gate sends on joins.
  bool handleRoomState(IrcRoomStateEvent event) {
    if (_disposed) return false;
    // A channel whose join previously failed just got in: announce the late
    // success and clear the failure state.
    if (_joinFailureNotified.remove(event.channel)) {
      onSystemMessage(event.channel, 'Joined #${event.channel}.');
    }
    _status.onRoomState(event.channel, event.tags);
    final roomId = event.tags['room-id'];
    if (roomId != null && roomId.isNotEmpty) {
      final waiters = _roomIdWaiters.remove(event.channel);
      if (waiters != null) {
        for (final w in waiters) {
          if (!w.isCompleted) w.complete(roomId);
        }
      }
    }
    return true;
  }

  /// JOIN-failure handler for the write socket (the one ROOMSTATE gates sends
  /// on): suspended/deleted channels get an explicit refusal notice;
  /// everything else surfaces after the fast rejoin sweep gave up. The base
  /// connection keeps retrying either way, so the message says what happened
  /// and that it keeps trying.
  void handleJoinFailed(IrcJoinFailureEvent event) {
    if (_disposed) return;
    final text = switch (event.reason) {
      // A definitive server signal: the channel really is unavailable.
      JoinFailureReason.suspended =>
        'Could not join #${event.channel}: the channel is suspended or deleted.',
      // A missing JOIN echo is ambiguous (transient drop, not-yet-joined, or
      // genuinely gone); never claim nonexistence, just report the failure.
      JoinFailureReason.noResponse =>
        'Could not connect to channel #${event.channel}',
    };
    _joinFailureNotified.add(event.channel);
    onSystemMessage(event.channel, text);
  }
}
