import 'dart:async';

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../chat/chat.dart';
import '../client/session.dart';
import '../color_utils.dart' show Color;
import '../l10n/l10n.dart';
import '../util/constants.dart';
import '../util/fake_history.dart';
import '../util/log.dart';
import '../irc/decode/decoder.dart' show IrcChatDecoder;
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
import 'pubsub_service.dart';
import 'user_store.dart';

/// The channel-domain of the pipeline: joining channels and resolving their
/// per-channel data (Helix user IDs, badges, emotes, 7TV sockets) plus the
/// chat-status composition; also owns the emote-sets subscription.
class ChatChannelSetup {
  ChatChannelSetup({
    required this.twitchApi,
    required this.eventSubDecoder,
    required this.eventSubTopics,
    this.pubSub,
    required this.irc,
    required this.ircRead,
    required this.readDecoder,
    this.sevenTvClient,
    required this.badgeService,
    required this.emoteManager,
    required this.twitchAuth,
    required this.userStore,
    required this.session,
    required this.chat,
    required this.onSystemMessage,
    required this.connectionStateNotifier,
    required this.ensureCurrentUser,
    this.strings = englishStrings,
    this.getMaxMessages = _unboundedMessages,
    this.onStreamSeen,
    this.onStreamEnded,
    this.onSubscribed,
  });

  static int _unboundedMessages() => 1 << 30;

  final TwitchApi twitchApi;
  final EventSubDecoder eventSubDecoder;
  final EventSubTopics eventSubTopics;

  /// Null disables PubSub redemption banners for every channel.
  final PubSubService? pubSub;
  final IrcService irc;
  final IrcReadService ircRead;
  final IrcChatDecoder readDecoder;
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

  /// Current-user lookup shared with the manager's connect path; the single
  /// in-flight dedup lives there.
  final Future<Map<String, dynamic>?> Function(TwitchAuth auth)
  ensureCurrentUser;

  final AppLocalizations Function() strings;
  final int Function() getMaxMessages;

  /// Broadcast sightings and ends for the history archive.
  final void Function(
    String channel,
    String id,
    DateTime startedAt,
    String? title,
    String? game,
  )?
  onStreamSeen;
  final void Function(String id, DateTime endedAt)? onStreamEnded;

  /// A channel's id is known and its PubSub topics are listening; runs on
  /// every join and resubscribe.
  final void Function(String channel)? onSubscribed;

  bool _disposed = false;
  final _httpClient = http.Client();

  // Chat status splash: ROOMSTATE mode tags plus periodic Helix stream info.
  late final ChatStatusComposer _status = ChatStatusComposer(
    twitchApi: twitchApi,
    twitchAuth: twitchAuth,
    chat: chat,
    session: session,
    strings: strings,
    getMaxMessages: getMaxMessages,
    onStreamSeen: onStreamSeen,
    onStreamEnded: onStreamEnded,
  );

  /// In-flight 7TV ID lookups by Twitch channel id. Concurrent joins for the
  /// same channel share one GET instead of each firing their own.
  final _sevenTvIdInflight =
      <String, Future<({String userId, String emoteSetId})?>>{};

  /// Sent 7TV triples by Twitch channel id. Cold start races a direct
  /// per-channel subscribe against the socket-edge subscribeAll; both
  /// resolve the same ids and must send once plus log once.
  final _sevenTvSubscribed = <String, ({String userId, String emoteSetId})>{};

  /// Whole resolve-plus-send by Twitch channel id. Concurrent joins for one
  /// channel share it instead of each sending their own.
  final _sevenTvSubInflight = <String, Future<void>>{};

  /// Bumped when a channel is forgotten. A join or 7TV resolve that began
  /// under an older value is stale and stops before its next side effect.
  final _leaveEpochs = <String, int>{};

  int _epochOf(String channel) => _leaveEpochs[channel] ?? 0;

  bool _isStale(String channel, int epoch) =>
      _disposed || _epochOf(channel) != epoch;

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
    _leaveEpochs[channel] = _epochOf(channel) + 1;
    eventSubTopics.forgetChannel(channel);
    eventSubDecoder.forgetChannel(channel);
    // A rejoin may fail and say so again.
    _joinFailureNotified.remove(channel);
    // Parted channels must not keep server-side 7TV dispatches: lookups run
    // before evictChannel and channelUserIds removal, so IDs are still here.
    _unsubscribeSevenTv(channel);
  }

  void _unsubscribeSevenTv(String channel) {
    final sevenTv = sevenTvClient;
    if (sevenTv == null) return;
    final emoteSetId = emoteManager.getSevenTvEmoteSetId(channel);
    if (emoteSetId != null) sevenTv.unsubscribeEmoteSet(emoteSetId);
    final userId = emoteManager.getSevenTvUserId(channel);
    if (userId != null) sevenTv.unsubscribeUser(userId);
    final twitchId = chat.channelFor(channel)?.info.broadcasterId;
    if (twitchId != null) {
      sevenTv.unsubscribeTwitchChannel(twitchId);
      _sevenTvSubscribed.remove(twitchId);
      _sevenTvSubInflight.remove(twitchId);
    }
  }

  bool _sevenTvEmotes = true;
  bool _sevenTvCosmetics = false;

  /// Matches the 7TV socket to the settings. Emote sets and user updates
  /// follow [emotes]; the channel feed (paints, badges, personal emotes)
  /// stays while either is on, and the socket closes when both are off.
  void applySevenTvSettings({required bool emotes, required bool cosmetics}) {
    if (emotes == _sevenTvEmotes && cosmetics == _sevenTvCosmetics) return;
    _sevenTvEmotes = emotes;
    _sevenTvCosmetics = cosmetics;
    final sevenTv = sevenTvClient;
    if (sevenTv == null) return;
    for (final channel in chat.names) {
      _unsubscribeSevenTv(channel);
      final twitchId = chat.channelFor(channel)?.info.broadcasterId;
      if (twitchId == null || !(emotes || cosmetics)) continue;
      unawaited(
        _resolveSevenTvAndSubscribe(channel, twitchId, _epochOf(channel)),
      );
    }
    sevenTv.enabled = emotes || cosmetics;
  }

  // ---- Status --------------------------------------------------------------

  /// Seconds of the channel's current slow mode from the merged ROOMSTATE
  /// tags; 0 when off (missing/empty/0 all mean off).
  int slowModeSeconds(String channel) => _status.slowModeSeconds(channel);

  void stopChatStatusTimer(String channel) => _status.stopFor(channel);

  // ---- Subscriptions -------------------------------------------------------

  Future<void> subscribeChannel(String channelName) async {
    // Prototype channels never reach IRC, EventSub or Helix.
    if (FakeHistory.isFake(channelName)) return;
    // Only the read socket JOINs: Twitch delivers chat on the socket that sent
    // JOIN, and PRIVMSG sends fine without joining. Joining on the write socket
    // too just wastes the 20/10s budget and (when the limiter was shared) raced
    // the read socket for the single JOIN slot per channel.
    ircRead.join(channelName);
    final epoch = _epochOf(channelName);

    try {
      final auth = twitchAuth;
      // A resubscribe already has the channel id; only resolve it on the
      // first join. ROOMSTATE's room-id carries it for free; logged in,
      // Helix also works the join queue from its back (see _lookupJoinTail).
      var channelUserId = chat.channelFor(channelName)?.info.broadcasterId;
      if (channelUserId == null || channelUserId.isEmpty) {
        final signedIn = auth.accessToken != null;
        if (signedIn) unawaited(Future.microtask(_lookupJoinTail));
        // Joins go out at about 2/s, so a long join queue outlasts 10 s.
        // Signed out there is no Helix fallback, so wait for the queue.
        channelUserId = await _waitForRoomId(
          channelName,
          timeout: signedIn
              ? const Duration(seconds: 10)
              : const Duration(minutes: 2),
        );
        if (_isStale(channelName, epoch)) return;
        // The JOIN never landed (socket down): ask Helix directly.
        if (channelUserId == null && signedIn) {
          channelUserId = await twitchApi.getUserId(auth, channelName);
          if (_isStale(channelName, epoch)) return;
        }
      }
      if (channelUserId == null) return;
      chat.channelFor(channelName)?.info.setBroadcasterId(channelUserId);
      // Unauthenticated redemptions and chat widgets for every viewer.
      // Never awaits: a dead edge degrades to the IRC highlight path.
      try {
        pubSub?.listen(channelName, channelUserId);
      } catch (_) {
        logDebug('[ChatConn] pubsub listen failed for $channelName');
      }
      onSubscribed?.call(channelName);
      // The first join fetches the account's own emotes; later joins
      // attach the fetched ones to this channel.
      unawaited(
        emoteManager.loadUserEmotes(auth, {channelName: channelUserId}),
      );
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

      unawaited(_resolveSevenTvAndSubscribe(channelName, channelUserId, epoch));

      if (session.login == null && auth.accessToken != null) {
        final currentUser = await ensureCurrentUser(auth);
        if (currentUser != null) {
          session.apply(currentUser['login'], userId: currentUser['id']);
        }
        if (_isStale(channelName, epoch)) return;
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

  /// Re-runs the per-channel data loads (badges, emotes) that failed earlier,
  /// updating the retryable failure state. Driven by the UI retry affordance.
  void retryChannelData(String channel) {
    final userId = chat.channelFor(channel)?.info.broadcasterId;
    if (userId == null) return;
    final auth = twitchAuth;
    unawaited(
      badgeService
          .fetchChannelBadges(auth, userId, channel)
          .then((_) => chat.clearLoadFailure(channel, 'badges'))
          .catchError((_) => chat.recordLoadFailure(channel, 'badges')),
    );
    emoteManager.accessToken = auth.accessToken;
    unawaited(
      emoteManager
          .resolveEmotes(channel, userId)
          .then((_) => chat.clearLoadFailure(channel, 'emotes'))
          .catchError((_) => chat.recordLoadFailure(channel, 'emotes')),
    );
  }

  Future<void> _resolveSevenTvAndSubscribe(
    String channelName,
    String twitchChannelId,
    int epoch,
  ) {
    if (sevenTvClient == null) return Future.value();
    final inflight = _sevenTvSubInflight[twitchChannelId];
    if (inflight != null) return inflight;
    final future = _doResolveSevenTvAndSubscribe(
      channelName,
      twitchChannelId,
      epoch,
    );
    _sevenTvSubInflight[twitchChannelId] = future;
    // The copy must not report unhandled errors; awaiters use the original.
    future
        .whenComplete(() => _sevenTvSubInflight.remove(twitchChannelId))
        .ignore();
    return future;
  }

  Future<void> _doResolveSevenTvAndSubscribe(
    String channelName,
    String twitchChannelId,
    int epoch,
  ) async {
    if (!_sevenTvEmotes) {
      // The channel feed alone needs no 7TV ids.
      if (_sevenTvCosmetics) {
        sevenTvClient!.subscribeTwitchChannel(twitchChannelId);
      }
      return;
    }
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
      if (ids == null || _isStale(channelName, epoch)) return;
      finalEmoteSetId = ids.emoteSetId;
      finalUserId = ids.userId;
      // Persisted so forgetChannel can unsubscribe both ids.
      emoteManager.setSevenTvEmoteSetId(channelName, finalEmoteSetId);
      emoteManager.setSevenTvUserId(channelName, finalUserId);
    }

    final known = _sevenTvSubscribed[twitchChannelId];
    if (known != null &&
        known.emoteSetId == finalEmoteSetId &&
        known.userId == finalUserId) {
      return;
    }
    sevenTvClient!.subscribeEmoteSet(finalEmoteSetId);
    sevenTvClient!.subscribeUser(finalUserId);
    sevenTvClient!.subscribeTwitchChannel(twitchChannelId);
    _sevenTvSubscribed[twitchChannelId] = (
      userId: finalUserId,
      emoteSetId: finalEmoteSetId,
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
      // The body carries the whole emote set, megabytes for a big channel:
      // decode off the UI isolate.
      final bytes = res.bodyBytes;
      final (userId, emoteSetId) = await Isolate.run(() {
        final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        return (
          (data['user'] as Map<String, dynamic>?)?['id'] as String?,
          (data['emote_set'] as Map<String, dynamic>?)?['id'] as String?,
        );
      });
      if (userId == null || emoteSetId == null) return null;
      return (userId: userId, emoteSetId: emoteSetId);
    } catch (_) {
      return null;
    }
  }

  // The channel user ID from ROOMSTATE's room-id tag, sent right after
  // JOIN. Waits (bounded) for the ROOMSTATE if it hasn't arrived yet.
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

  void _completeRoomId(String channel, String roomId) {
    final waiters = _roomIdWaiters.remove(channel);
    if (waiters == null) return;
    for (final w in waiters) {
      if (!w.isCompleted) w.complete(roomId);
    }
  }

  bool _tailRunning = false;

  /// Helix lookups for channels whose JOIN is not out yet, last to join
  /// first, while IRC joins from the front; they meet in the middle, so no
  /// channel is looked up twice. Channels the limiter has not queued (the
  /// socket is down) join after the whole queue. Runs after the limiter's
  /// first burst, which lands those channels' ROOMSTATE right away.
  Future<void> _lookupJoinTail() async {
    if (_tailRunning) return;
    _tailRunning = true;
    final tried = <String>{};
    try {
      while (!_disposed && twitchAuth.accessToken != null) {
        final queued = ircRead.queuedJoins;
        int rank(String c) {
          final i = queued.indexOf(c);
          return i < 0 ? queued.length : i;
        }

        String? next;
        for (final c in _roomIdWaiters.keys) {
          if (tried.contains(c) || ircRead.joinSent(c)) continue;
          if (next == null || rank(c) >= rank(next)) next = c;
        }
        if (next == null) return;
        tried.add(next);
        final id = await twitchApi.getUserId(twitchAuth, next);
        if (id != null && !_disposed) _completeRoomId(next, id);
      }
    } finally {
      _tailRunning = false;
    }
  }

  // ---- IRC event handlers (routed by the manager) -------------------------

  /// ROOMSTATE handler: confirms the channel joined, merges the partial mode
  /// tags, completes anonymous room-id waiters and recomposes the status
  /// splash. Returns true because a ROOMSTATE always confirms membership;
  /// the caller records it to gate sends on joins.
  bool handleRoomState(IrcRoomStateEvent event) {
    if (_disposed) return false;
    // A channel whose join previously failed just got in: its failure row
    // goes, and Connected reports the join.
    if (_joinFailureNotified.remove(event.channel)) {
      chat
          .channelFor(event.channel)
          ?.messages
          .removeSystem(_joinFailedId(event.channel));
    }
    _status.onRoomState(event.channel, event.tags);
    final roomId = event.tags['room-id'];
    if (roomId != null && roomId.isNotEmpty) {
      _completeRoomId(event.channel, roomId);
    }
    return true;
  }

  /// The id of [channel]'s join failure row, which its ROOMSTATE removes.
  static String _joinFailedId(String channel) => 'sys_join:$channel:failed';

  /// Posts the one "couldn't join, retrying" line for a JOIN that went
  /// unconfirmed past the timeout. A later ROOMSTATE removes it.
  void handleJoinTimedOut(String channel) {
    if (_disposed || !_joinFailureNotified.add(channel)) return;
    onSystemMessage(
      channel,
      strings().joinTimedOutRetrying(channel),
      messageId: _joinFailedId(channel),
    );
  }

  /// JOIN-failure handler for the write socket (the one ROOMSTATE gates sends
  /// on): suspended/deleted channels get an explicit refusal notice;
  /// everything else surfaces after the fast rejoin sweep gave up. The base
  /// connection keeps retrying either way, so the message says what happened
  /// and that it keeps trying.
  void handleJoinFailed(IrcJoinFailureEvent event) {
    if (_disposed) return;
    // The earlier timeout notice already said this; do not repeat it.
    if (event.reason == JoinFailureReason.noResponse &&
        _joinFailureNotified.contains(event.channel)) {
      return;
    }
    final text = switch (event.reason) {
      // A definitive server signal: the channel really is unavailable.
      JoinFailureReason.suspended => strings().joinFailedSuspended(
        event.channel,
      ),
      // A missing JOIN echo is ambiguous (transient drop, not-yet-joined, or
      // genuinely gone); never claim nonexistence, just report the failure.
      JoinFailureReason.noResponse => strings().joinFailedNoResponse(
        event.channel,
      ),
    };
    _joinFailureNotified.add(event.channel);
    onSystemMessage(
      event.channel,
      text,
      messageId: _joinFailedId(event.channel),
    );
  }
}
