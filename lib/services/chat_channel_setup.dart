import 'dart:async';

import 'dart:convert';

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../util/constants.dart';
import '../util/log.dart';
import 'base_irc_connection.dart'
    show IrcJoinFailureEvent, IrcReadService, JoinFailureReason;
import 'chat_store.dart';
import 'emote_manager.dart';
import 'seven_tv_event_client.dart';
import 'twitch_api.dart';
import 'twitch_auth.dart';
import 'twitch_badge_service.dart';
import 'twitch_eventsub.dart';
import 'twitch_irc.dart' show IrcRoomStateEvent, IrcService;
import 'user_store.dart';

/// The channel-domain of the pipeline: joining channels and resolving their
/// per-channel data (Helix user IDs, badges, emotes, 7TV sockets) plus the
/// EventSub moderation/widget subscriptions and the chat-status composition
/// from ROOMSTATE tags and periodic stream fetches. Unlike [ChatIngestion]
/// this class owns no stream subscriptions: the manager routes IRC events
/// into [handleRoomState]/[handleJoinFailed], and channel subscriptions run
/// on demand through [subscribeChannel].
class ChatChannelSetup {
  ChatChannelSetup({
    required this.twitchApi,
    required this.eventSub,
    required this.irc,
    required this.ircRead,
    this.sevenTvClient,
    required this.badgeService,
    required this.emoteManager,
    required this.twitchAuth,
    required this.userStore,
    required this.store,
    required this.onSystemMessage,
    required this.connectionStateNotifier,
    this.onUserEmoteSets,
    required this.ensureCurrentUser,
  });

  final TwitchApi twitchApi;
  final EventSubService eventSub;
  final IrcService irc;
  final IrcReadService ircRead;
  final SevenTvEventClient? sevenTvClient;
  final TwitchBadgeService badgeService;
  final EmoteManager emoteManager;
  final TwitchAuth twitchAuth;
  final UserStore userStore;
  final ChatStore store;

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

  // Channels with an active channel.moderate v2 subscription. While present,
  // moderation system messages come from EventSub (richer data) instead of
  // IRC CLEARCHAT/CLEARMSG.
  final _moderationChannels = <String>{};
  // Channels where the channel.moderate v2 subscription was rejected with a 403
  // (not a moderator). Persists across EventSub session reconnects so we don't
  // re-attempt (and re-log) the subscription on every reconnect for the current
  // account.
  final _moderationSkippedChannels = <String>{};
  // Channels with an active hype train / poll / prediction widget subscription
  // (broadcaster-only; see _subscribeWidgets). Same lifecycle as
  // _moderationChannels: cleared when the EventSub session dies.
  final _widgetChannels = <String>{};
  // Channels where the widget subscriptions were rejected with a 403 (not the
  // broadcaster). Persists so we don't re-attempt doomed subscriptions.
  final _widgetSkippedChannels = <String>{};
  // Room-mode tags per channel from ROOMSTATE (merged across partial
  // updates); feeds the chat status splash. Stream info from the periodic
  // Helix fetch is kept separately so ROOMSTATE recomposes don't lose it.
  final _roomStateTags = <String, Map<String, String>>{};
  final _streamStatusParts = <String, List<String>>{};
  Timer? _chatStatusTimer;
  final _chatStatusChannels = <String>{};
  static const _chatStatusInterval = Duration(seconds: 60);
  // Channels a join-failure notice was displayed for. A later ROOMSTATE
  // confirmation clears the entry and announces the (late) success.
  final _joinFailureNotified = <String>{};

  void dispose() {
    _disposed = true;
    _chatStatusTimer?.cancel();
    _chatStatusTimer = null;
    _chatStatusChannels.clear();
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

  /// Whether the EventSub channel.moderate v2 subscription is active for a
  /// channel; while it is, IRC moderation echoes and room-mode NOTICEs are
  /// suppressed in favor of the richer EventSub copies.
  bool isModerationActive(String channel) =>
      _moderationChannels.contains(channel);

  /// Whether the broadcaster-only widget subscriptions are active for a
  /// channel; while they are, EventSub hype train/poll/prediction events are
  /// surfaced instead of being dropped as unsolicited.
  bool isWidgetActive(String channel) => _widgetChannels.contains(channel);

  /// Whether a join-failure notice was already displayed for the channel
  /// (Twitch's raw refusal NOTICE is suppressed as a duplicate then).
  bool isJoinFailureNotified(String channel) =>
      _joinFailureNotified.contains(channel);

  /// Failure state is per socket lifetime: the fresh socket runs its own fast
  /// sweep, so it may legitimately fail (and re-announce) again.
  void resetJoinFailureState() => _joinFailureNotified.clear();

  /// Session-scoped subscription state dies with the EventSub session; IRC
  /// fallback resumes until [resubscribeEventSubChannels] runs again.
  void clearSessionState() {
    _moderationChannels.clear();
    _widgetChannels.clear();
  }

  /// 403 skip sets are account-scoped: a non-mod account's rejection must not
  /// permanently disable moderation/widgets for a mod account on the same
  /// channel after a switch.
  void resetAccountScope() {
    _moderationSkippedChannels.clear();
    _widgetSkippedChannels.clear();
  }

  // ---- Status --------------------------------------------------------------

  /// Seconds of the channel's current slow mode from the merged ROOMSTATE
  /// tags; 0 when off (missing/empty/0 all mean off).
  int slowModeSeconds(String channel) =>
      int.tryParse(_roomStateTags[channel]?['slow'] ?? '') ?? 0;

  Future<void> fetchChatStatus(String channel) async {
    final auth = twitchAuth;
    if (!auth.isConfigured) return;

    final userId = store.channelUserIds[channel];
    if (userId == null || store.session.userId == null) return;

    // Timer-driven: a network blip (or the client being closed in dispose)
    // must not surface as an unhandled async exception every 60s per channel.
    final Map<String, dynamic>? stream;
    try {
      stream = await twitchApi.getStreamInfo(auth, userId);
    } catch (e) {
      logDebug('[ChatConn] fetchChatStatus failed for $channel: $e');
      return;
    }
    _applyStreamStatus(channel, stream);
  }

  Future<void> fetchAllChatStatus() async {
    final auth = twitchAuth;
    if (!auth.isConfigured) return;
    final ids = <String>[];
    for (final channel in _chatStatusChannels) {
      final userId = store.channelUserIds[channel];
      if (userId != null) ids.add(userId);
    }
    if (ids.isEmpty) return;
    Map<String, Map<String, dynamic>> streams;
    try {
      streams = await twitchApi.getStreams(auth, ids);
    } catch (e) {
      logDebug('[ChatConn] fetchAllChatStatus failed: $e');
      return;
    }
    for (final channel in _chatStatusChannels) {
      final userId = store.channelUserIds[channel];
      _applyStreamStatus(channel, userId != null ? streams[userId] : null);
    }
  }

  void _applyStreamStatus(String channel, Map<String, dynamic>? stream) {
    final parts = <String>[];
    if (stream != null && stream['type'] == 'live') {
      final viewers = stream['viewer_count'] ?? 0;
      final started = stream['started_at'] as String?;
      if (started != null) {
        final dur = DateTime.now().difference(DateTime.parse(started));
        final h = dur.inHours;
        final m = dur.inMinutes.remainder(60);
        parts.add('Live with $viewers viewers for ${h}h ${m}m');
      } else {
        parts.add('Live with $viewers viewers');
      }
    }
    _streamStatusParts[channel] = parts;
    _composeChatStatus(channel);
  }

  // Room modes come from ROOMSTATE (instant, broadcast to everyone on IRC);
  // this replaces the old Helix getChatSettings polling.
  void _composeChatStatus(String channel) {
    final parts = <String>[];
    final tags = _roomStateTags[channel];
    if (tags != null) {
      final slow = int.tryParse(tags['slow'] ?? '') ?? 0;
      if (slow > 0) parts.add('Slow (${slow}s)');
      final followers = tags['followers-only'];
      if (followers != null && followers != '-1') {
        parts.add(
          followers == '0'
              ? 'Followers-only'
              : 'Followers-only (${followers}m)',
        );
      }
      if (tags['emote-only'] == '1') parts.add('Emote-only');
      if (tags['subs-only'] == '1') parts.add('Subscribers-only');
      if (tags['r9k'] == '1') parts.add('Unique chat');
    }
    parts.addAll(_streamStatusParts[channel] ?? const []);
    final newStatus = parts.isNotEmpty ? parts.join(' · ') : '';
    if (store.chatStatus[channel] == newStatus) return;
    store.chatStatus[channel] = newStatus;
    store.touchChannel(channel);
  }

  void stopChatStatusTimer(String channel) {
    _chatStatusChannels.remove(channel);
    if (_chatStatusChannels.isEmpty) {
      _chatStatusTimer?.cancel();
      _chatStatusTimer = null;
    }
    _roomStateTags.remove(channel);
    _streamStatusParts.remove(channel);
  }

  // ---- Subscriptions -------------------------------------------------------

  Future<void> subscribeChannel(String channelName) async {
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
      store.channelUserIds[channelName] = channelUserId;
      badgeService.fetchChannelBadges(auth, channelUserId, channelName);

      emoteManager.accessToken = auth.accessToken;
      logDebug(
        'subscribeChannel $channelName userId=$channelUserId '
        'hasToken=${auth.accessToken != null} resolved=${store.channelsEmotesResolved.contains(channelName)}',
      );
      if (!store.channelsEmotesResolved.contains(channelName)) {
        store.channelsEmotesResolved.add(channelName);
        unawaited(
          emoteManager
              .resolveEmotes(channelName, channelUserId)
              .catchError(
                (e) => logDebug(
                  '[ChatConn] resolveEmotes failed for $channelName: $e',
                ),
              ),
        );
      }

      unawaited(_resolveSevenTvAndSubscribe(channelName, channelUserId));

      if (store.session.login == null && auth.accessToken != null) {
        final currentUser = await ensureCurrentUser(auth);
        if (currentUser != null) {
          store.applyLogin(currentUser['login']);
          store.session.userId = currentUser['id'];
        }
      }

      if (store.session.login != null && store.session.userId != null) {
        eventSub.setChannelMapping(channelUserId, channelName);
        unawaited(_subscribeModeration(channelName, channelUserId));
        unawaited(_subscribeWidgets(channelName, channelUserId));
      }
    } catch (_) {
      logDebug('[ChatConn] subscribeChannel failed for $channelName');
    }
    connectionStateNotifier.value++;
    fetchChatStatus(channelName);
    _chatStatusChannels.add(channelName);
    _startChatStatusTimer();
  }

  void _startChatStatusTimer() {
    _chatStatusTimer ??= Timer.periodic(
      _chatStatusInterval,
      (_) => fetchAllChatStatus(),
    );
  }

  void subscribeAll(List<String> channels) {
    for (final channel in channels) {
      unawaited(subscribeChannel(channel));
    }
  }

  // Chat messages come from IRC PRIVMSG; EventSub is only used for
  // channel.moderate v2 (moderation actions), subscribed per channel when the
  // session is up. Twitch rejects non-moderators (403), in which case IRC
  // CLEARCHAT/CLEARMSG remain the moderation source.
  Future<void> _subscribeModeration(
    String channelName,
    String channelUserId,
  ) async {
    try {
      final auth = twitchAuth;
      if (!auth.isConfigured || store.session.userId == null) return;
      // Already known to be rejected with 403 (not a moderator); skip so we
      // don't re-attempt and re-log on every reconnect.
      if (_moderationSkippedChannels.contains(channelName)) return;
      // Not a retry loop: the subscription is attempted at most once. The
      // loop only bounds the wait (~3s) for the EventSub websocket session
      // to appear; a session that never shows up just skips this channel.
      for (int attempt = 0; attempt < 3; attempt++) {
        final sessionId = eventSub.sessionId;
        if (sessionId == null) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        if (attempt > 0) await Future.delayed(const Duration(seconds: 1));
        final ok = await twitchApi.createEventSubSubscription(
          auth: auth,
          sessionId: sessionId,
          type: 'channel.moderate',
          version: '2',
          condition: {
            'broadcaster_user_id': channelUserId,
            'moderator_user_id': store.session.userId!,
          },
        );
        if (ok) {
          _moderationChannels.add(channelName);
          return;
        }
        if (twitchApi.lastErrorStatus == 403) {
          // Expected when the user isn't a moderator in this channel; not an
          // actionable error, so skip it silently and don't retry it.
          _moderationSkippedChannels.add(channelName);
          return;
        }
        logDebug(
          '[ChatConn] channel.moderate subscription failed for $channelName (${twitchApi.lastError ?? "unknown"})',
        );
        return;
      }
    } catch (_) {
      logDebug('[ChatConn] subscribeModeration failed for $channelName');
    }
  }

  // Hype train / poll / prediction widgets are broadcaster-only: the EventSub
  // subscription types require channel:read:hype_train/polls/predictions, which
  // Twitch only issues to the channel owner. Skip every other channel up front
  // so we don't fire a dozen doomed Helix calls per join.
  Future<void> _subscribeWidgets(
    String channelName,
    String channelUserId,
  ) async {
    try {
      final auth = twitchAuth;
      if (!auth.isConfigured || store.session.userId == null) return;
      if (store.session.userId != channelUserId) return;
      if (_widgetSkippedChannels.contains(channelName)) return;
      // Same shape as _subscribeModeration: one attempt max, the loop only
      // bounds the wait for the EventSub session.
      for (int attempt = 0; attempt < 3; attempt++) {
        final sessionId = eventSub.sessionId;
        if (sessionId == null) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        if (attempt > 0) await Future.delayed(const Duration(seconds: 1));
        const types = [
          ('channel.hype_train.begin', '2'),
          ('channel.hype_train.progress', '2'),
          ('channel.hype_train.end', '2'),
          ('channel.poll.begin', '1'),
          ('channel.poll.progress', '1'),
          ('channel.poll.end', '1'),
          ('channel.prediction.begin', '1'),
          ('channel.prediction.progress', '1'),
          ('channel.prediction.lock', '1'),
          ('channel.prediction.end', '1'),
        ];
        var failed = false;
        for (final (type, version) in types) {
          final ok = await twitchApi.createEventSubSubscription(
            auth: auth,
            sessionId: sessionId,
            type: type,
            version: version,
            condition: {'broadcaster_user_id': channelUserId},
          );
          if (!ok) {
            if (twitchApi.lastErrorStatus == 403) {
              // Expected when the user isn't the broadcaster; skip silently.
              _widgetSkippedChannels.add(channelName);
            } else {
              logDebug(
                '[ChatConn] $type subscription failed for $channelName (${twitchApi.lastError ?? "unknown"})',
              );
            }
            failed = true;
            break;
          }
        }
        if (!failed) {
          _widgetChannels.add(channelName);
        }
        return;
      }
    } catch (_) {
      logDebug('[ChatConn] subscribeWidgets failed for $channelName');
    }
  }

  /// Re-creates the session-scoped EventSub subscriptions after a new session
  /// comes up (session_reconnect / keepalive reconnect). Skip sets and the
  /// already-subscribed sets are respected by the per-channel methods.
  void resubscribeEventSubChannels(List<String> channels) {
    final uid = store.session.userId;
    if (uid == null) return;
    for (final channel in channels) {
      final channelUserId = store.channelUserIds[channel];
      if (channelUserId == null) continue;
      if (!_moderationChannels.contains(channel)) {
        unawaited(_subscribeModeration(channel, channelUserId));
      }
      if (uid == channelUserId && !_widgetChannels.contains(channel)) {
        unawaited(_subscribeWidgets(channel, channelUserId));
      }
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
      try {
        final uri = Uri.parse(
          'https://7tv.io/v3/users/twitch/$twitchChannelId',
        );
        final res = await _httpClient.get(uri).timeout(httpTimeout);
        if (res.statusCode != 200) return;
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final userId =
            (data['user'] as Map<String, dynamic>?)?['id'] as String?;
        final emoteSetId =
            (data['emote_set'] as Map<String, dynamic>?)?['id'] as String?;
        if (userId == null || emoteSetId == null) return;
        emoteManager.setSevenTvEmoteSetId(channelName, emoteSetId);
        finalUserId = userId;
        finalEmoteSetId = emoteSetId;
      } catch (_) {
        return;
      }
    }

    sevenTvClient!.subscribeEmoteSet(finalEmoteSetId);
    sevenTvClient!.subscribeUser(finalUserId);
    sevenTvClient!.subscribeTwitchChannel(twitchChannelId);
    logDebug(
      '[7TV] subscribed channel=$channelName emoteSetId=$finalEmoteSetId userId=$finalUserId',
    );
  }

  // Anonymous fallback for the channel user ID: ROOMSTATE carries a room-id
  // tag right after JOIN, which Helix normally provides. Waits (bounded) for
  // the ROOMSTATE if it hasn't arrived yet.
  final _roomIdWaiters = <String, List<Completer<String?>>>{};

  Future<String?> _waitForRoomId(
    String channel, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final existing = _roomStateTags[channel]?['room-id'];
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
    // A channel whose join previously failed (and announced "Retrying.")
    // just got in: announce the late success and clear the failure state.
    if (_joinFailureNotified.remove(event.channel)) {
      onSystemMessage(event.channel, 'Joined #${event.channel}.');
    }
    // ROOMSTATE updates are partial (only the changed tags): merge with
    // the previous state before recomposing the status splash.
    _roomStateTags[event.channel] = {
      ...?_roomStateTags[event.channel],
      ...event.tags,
    };
    final roomId = event.tags['room-id'];
    if (roomId != null && roomId.isNotEmpty) {
      final waiters = _roomIdWaiters.remove(event.channel);
      if (waiters != null) {
        for (final w in waiters) {
          if (!w.isCompleted) w.complete(roomId);
        }
      }
    }
    _composeChatStatus(event.channel);
    return true;
  }

  /// JOIN-failure handler for the write socket (the one ROOMSTATE gates sends
  /// on): suspended/deleted channels get an explicit refusal notice;
  /// everything else surfaces after the fast rejoin sweep gave up. The base
  /// connection keeps retrying either way, so the message says what happened
  /// and that it keeps trying.
  void handleJoinFailed(IrcJoinFailureEvent event) {
    if (_disposed) return;
    final detail = switch (event.reason) {
      JoinFailureReason.suspended => 'the channel is suspended or deleted',
      JoinFailureReason.noResponse => 'the server never confirmed the join',
    };
    final suffix = event.reason == JoinFailureReason.noResponse
        ? ' Retrying.'
        : '';
    _joinFailureNotified.add(event.channel);
    onSystemMessage(
      event.channel,
      'Could not join #${event.channel}: $detail.$suffix',
    );
  }
}
