import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/channel/channel.dart';
import '../chat/chat.dart';
import '../client/session.dart';
import '../color_utils.dart' show streamAccent;
import '../l10n/app_localizations.dart';
import '../util/log.dart';
import 'twitch_api.dart';
import 'twitch_auth.dart';

/// Composes each channel's chat status splash from merged ROOMSTATE mode tags
/// and periodic Helix stream info, writing it to `ChannelInfo.status`.
class ChatStatusComposer {
  ChatStatusComposer({
    required this.twitchApi,
    required this.twitchAuth,
    required this.chat,
    required this.session,
    required this.strings,
    required this.getMaxMessages,
    this.onStreamSeen,
    this.onStreamEnded,
    DateTime Function()? now,
  }) : _now = now ?? clock.now;

  final TwitchApi twitchApi;
  final TwitchAuth twitchAuth;
  final Chat chat;
  final Session session;
  final AppLocalizations Function() strings;
  final int Function() getMaxMessages;

  /// Every poll that sees [channel] live, for the history archive.
  final void Function(
    String channel,
    String id,
    DateTime startedAt,
    String? title,
    String? game,
  )?
  onStreamSeen;

  /// A broadcast's end, at the last poll that saw it live.
  final void Function(String id, DateTime endedAt)? onStreamEnded;
  final DateTime Function() _now;

  // Room-mode tags per channel from ROOMSTATE (merged across partial
  // updates); feeds the chat status splash. Stream info from the periodic
  // Helix fetch is kept separately so ROOMSTATE recomposes don't lose it.
  final _roomStateTags = <String, Map<String, String>>{};

  /// Bumped when a channel's merged ROOMSTATE tags change, so mod mode
  /// toggles re-read them without waiting for a reopen.
  final roomStateVersion = ValueNotifier<int>(0);
  final _streamStatusParts = <String, List<String>>{};
  Timer? _chatStatusTimer;
  final _chatStatusChannels = <String>{};
  final _statusGenerations = <String, int>{};

  /// Latest request per channel, so a slower older poll cannot apply.
  final _requestGenerations = <String, int>{};
  int _nextStatusGeneration = 0;
  int _nextRequestGeneration = 0;
  bool _fetchScheduled = false;
  bool _disposed = false;
  static const _chatStatusInterval = Duration(seconds: 30);

  bool _isCurrent(String channel, int generation) =>
      !_disposed && _statusGenerations[channel] == generation;

  bool _isLatest(String channel, int generation, int request) =>
      _isCurrent(channel, generation) &&
      _requestGenerations[channel] == request;

  void dispose() {
    _disposed = true;
    _chatStatusTimer?.cancel();
    _chatStatusTimer = null;
    _chatStatusChannels.clear();
    _statusGenerations.clear();
    _requestGenerations.clear();
    _roomStateTags.clear();
    _streamStatusParts.clear();
    _offlinePolls.clear();
    _endedStreams.clear();
    _refinedEnds.clear();
    _endRefineAfter.clear();
    roomStateVersion.dispose();
  }

  /// Merges partial ROOMSTATE tags for [channel] and recomposes its status.
  void onRoomState(String channel, Map<String, String> tags) {
    if (_disposed) return;
    _roomStateTags[channel] = {...?_roomStateTags[channel], ...tags};
    roomStateVersion.value++;
    _composeChatStatus(channel);
  }

  /// Starts the periodic status fetch for [channel] and arms the timer.
  void startFor(String channel) {
    if (_disposed) return;
    _chatStatusChannels.add(channel);
    _statusGenerations[channel] = ++_nextStatusGeneration;
    _startChatStatusTimer();
    _scheduleFetch();
  }

  // Coalesces the per-channel starts in one turn into a single batched
  // request; a reconnect starts every channel back to back.
  void _scheduleFetch() {
    if (_fetchScheduled) return;
    _fetchScheduled = true;
    scheduleMicrotask(() {
      _fetchScheduled = false;
      if (_disposed) return;
      unawaited(fetchAllChatStatus());
    });
  }

  /// Stops tracking [channel] and drops its accumulated status bits.
  void stopFor(String channel) {
    if (_disposed) return;
    final userId = chat.channelFor(channel)?.info.broadcasterId;
    if (userId != null) {
      _endedStreams.remove(userId);
      _refinedEnds.remove(userId);
      _endRefineAfter.remove(userId);
    }
    _chatStatusChannels.remove(channel);
    _statusGenerations.remove(channel);
    _requestGenerations.remove(channel);
    if (_chatStatusChannels.isEmpty) {
      _chatStatusTimer?.cancel();
      _chatStatusTimer = null;
    }
    if (_roomStateTags.remove(channel) != null) {
      roomStateVersion.value++;
    }
    _streamStatusParts.remove(channel);
  }

  /// Seconds of the channel's current slow mode from the merged ROOMSTATE
  /// tags; 0 when off (missing/empty/0 all mean off).
  int slowModeSeconds(String channel) =>
      int.tryParse(_roomStateTags[channel]?['slow'] ?? '') ?? 0;

  /// Copy of the merged ROOMSTATE tags for a channel (slow, followers-only,
  /// emote-only, subs-only, r9k). Powers the Mod View mode toggles.
  Map<String, String> roomStateTags(String channel) =>
      Map.of(_roomStateTags[channel] ?? const {});

  Future<void> fetchChatStatus(String channel) async {
    final generation = _statusGenerations[channel];
    if (generation == null) return;
    final request = _requestGenerations[channel] = ++_nextRequestGeneration;
    final auth = twitchAuth;
    if (!auth.isConfigured) return;

    final userId = chat.channelFor(channel)?.info.broadcasterId;
    if (userId == null || session.userId == null) return;

    // Timer-driven: a network blip (or the client being closed in dispose)
    // must not surface as an unhandled async exception every 60s per channel.
    final Map<String, dynamic>? stream;
    try {
      stream = await twitchApi.getStreamInfo(auth, userId);
    } catch (e) {
      logDebug('[ChatConn] fetchChatStatus failed for $channel: $e');
      return;
    }
    if (!_isLatest(channel, generation, request)) return;
    _applyStreamStatus(channel, stream);
    await _applyStreamMarkers({userId: (channel, generation, request, stream)});
  }

  Future<void> fetchAllChatStatus() async {
    if (_disposed) return;
    final generations = <String, int>{};
    final requests = <String, int>{};
    for (final channel in _chatStatusChannels) {
      final generation = _statusGenerations[channel];
      if (generation == null) continue;
      final request = ++_nextRequestGeneration;
      generations[channel] = generation;
      requests[channel] = request;
      _requestGenerations[channel] = request;
    }
    final auth = twitchAuth;
    if (!auth.isConfigured) return;
    final ids = <String>[];
    for (final channel in generations.keys) {
      final userId = chat.channelFor(channel)?.info.broadcasterId;
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
    if (_disposed) return;
    for (final MapEntry(key: channel, value: generation)
        in generations.entries) {
      if (!_isLatest(channel, generation, requests[channel]!)) continue;
      final userId = chat.channelFor(channel)?.info.broadcasterId;
      _applyStreamStatus(channel, userId != null ? streams[userId] : null);
    }
    final polls = <String, (String, int, int, Map<String, dynamic>?)>{};
    for (final MapEntry(key: channel, value: generation)
        in generations.entries) {
      if (!_isLatest(channel, generation, requests[channel]!)) continue;
      final id = chat.channelFor(channel)?.info.broadcasterId;
      if (id != null) {
        polls[id] = (channel, generation, requests[channel]!, streams[id]);
      }
    }
    await _applyStreamMarkers(polls);
  }

  // Consecutive offline polls per broadcaster. Helix can briefly list a live
  // stream as gone, so an end needs two.
  final _offlinePolls = <String, int>{};

  /// Ended ids independent of buffer residency, so a truncated marker can
  /// still gain the archive's real end time.
  final _endedStreams = <String, String>{};
  final _refinedEnds = <String, ({String id, DateTime endedAt})>{};
  final _endRefineAfter = <String, DateTime>{};
  static const _endRefineRetry = Duration(minutes: 5);

  static String _markerKey(String userId) => 'stream_marker.$userId';

  /// Writes "Stream started" and "Stream ended" rows from stream transitions.
  /// The last seen stream (id, started_at, last live poll, ended) persists per
  /// broadcaster so a restart neither repeats a start nor loses an end, and an
  /// ended id seen live again takes its end back. A start sits at its
  /// `started_at` position even when that is older than the buffer;
  /// truncation drops it with the other old rows.
  Future<void> _applyStreamMarkers(
    Map<String, (String, int, int, Map<String, dynamic>?)> polls,
  ) async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      logDebug('[ChatConn] stream markers skipped: $e');
      return;
    }
    if (_disposed) return;
    final now = _now();
    for (final MapEntry(
          key: userId,
          value: (channel, generation, request, stream),
        )
        in polls.entries) {
      if (!_isLatest(channel, generation, request)) continue;
      final target = chat.channelFor(channel);
      if (target == null) continue;
      final saved = _readMarker(prefs, userId);
      final id = stream?['id'] as String?;
      final live = stream != null && stream['type'] == 'live' && id != null;
      if (!live) {
        if (saved == null) continue;
        if (saved.ended) {
          _endedStreams[userId] = saved.id;
          final refined = _refinedEnds[userId];
          if (refined?.id == saved.id) continue;
          final after = _endRefineAfter[userId];
          if (after == null || !now.isBefore(after)) {
            _scheduleEndRefine(channel, userId, saved.id, generation);
          }
          continue;
        }
        final polls = (_offlinePolls[userId] ?? 0) + 1;
        _offlinePolls[userId] = polls;
        if (polls < 2) continue;
        _offlinePolls.remove(userId);
        _endedStreams[userId] = saved.id;
        _writeEnded(target, saved);
        _scheduleEndRefine(channel, userId, saved.id, generation);
        await prefs.setString(
          _markerKey(userId),
          jsonEncode({
            'id': saved.id,
            'startedAt': saved.startedAt?.toIso8601String(),
            'seenAt': saved.seenAt.toIso8601String(),
            'ended': true,
          }),
        );
        continue;
      }
      _offlinePolls.remove(userId);
      _endedStreams.remove(userId);
      _refinedEnds.remove(userId);
      if (saved != null && saved.id != id && !saved.ended) {
        _endedStreams[userId] = saved.id;
        _writeEnded(target, saved);
        _scheduleEndRefine(channel, userId, saved.id, generation);
      }
      target.messages.removeSystem('sys_stream:$id:end');
      final startedAt = DateTime.tryParse(
        stream['started_at'] as String? ?? '',
      );
      onStreamSeen?.call(
        channel,
        id,
        startedAt ?? now,
        (stream['title'] as String?)?.trim(),
        (stream['game_name'] as String?)?.trim(),
      );
      if (saved?.id != id) {
        final details = [
          for (final k in const ['title', 'game_name'])
            if ((stream[k] as String?)?.trim() case final v? when v.isNotEmpty)
              v,
        ];
        target.addSystemMessageAt(
          details.isEmpty
              ? strings().streamStarted
              : strings().streamStartedWith(details.join(' - ')),
          messageId: 'sys_stream:$id:start',
          at: startedAt?.toLocal() ?? now,
          accent: streamAccent,
          maxMessages: getMaxMessages(),
        );
      }
      await prefs.setString(
        _markerKey(userId),
        jsonEncode({
          'id': id,
          'startedAt': startedAt?.toIso8601String(),
          'seenAt': now.toIso8601String(),
        }),
      );
    }
  }

  ({String id, DateTime? startedAt, DateTime seenAt, bool ended})? _readMarker(
    SharedPreferences prefs,
    String userId,
  ) {
    final raw = prefs.getString(_markerKey(userId));
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map;
      final seenAt = DateTime.tryParse(m['seenAt'] as String? ?? '');
      final id = m['id'] as String?;
      if (id == null || seenAt == null) return null;
      return (
        id: id,
        startedAt: DateTime.tryParse(m['startedAt'] as String? ?? ''),
        seenAt: seenAt.toLocal(),
        ended: m['ended'] == true,
      );
    } catch (_) {
      // A malformed status entry is skipped.
      return null;
    }
  }

  // The end sits at the last poll that saw the stream live; the duration is
  // omitted when the start time is unknown.
  void _writeEnded(
    Channel target,
    ({String id, DateTime? startedAt, DateTime seenAt, bool ended}) marker,
  ) {
    onStreamEnded?.call(marker.id, marker.seenAt);
    target.addSystemMessageAt(
      [
        strings().streamEnded,
        ?_durationText(marker.startedAt, marker.seenAt),
      ].join(' - '),
      messageId: 'sys_stream:${marker.id}:end',
      at: marker.seenAt,
      accent: streamAccent,
      maxMessages: getMaxMessages(),
    );
  }

  void _scheduleEndRefine(
    String channel,
    String userId,
    String streamId,
    int generation,
  ) {
    _endRefineAfter[userId] = _now().add(_endRefineRetry);
    unawaited(_refineEnd(channel, userId, streamId, generation));
  }

  /// Moves [streamId]'s end to the archive video's real end when Twitch
  /// publishes it. Failures, missing videos and reopened ids keep the
  /// current row.
  Future<void> _refineEnd(
    String channel,
    String userId,
    String streamId,
    int generation,
  ) async {
    if (!_isCurrent(channel, generation)) return;
    final auth = twitchAuth;
    if (!auth.isConfigured) return;
    ({String vodId, String streamId, DateTime startedAt, DateTime endedAt})?
    video;
    try {
      video = await twitchApi.getLatestArchiveVideo(auth, userId);
    } catch (e) {
      logDebug('[ChatConn] archive end lookup failed for $channel: $e');
      return;
    }
    if (!_isCurrent(channel, generation)) return;
    if (video == null || video.streamId != streamId) return;
    final target = chat.channelFor(channel);
    // Reopening the same id clears this state before removing its end row.
    if (target == null || _endedStreams[userId] != streamId) return;
    final refined = _refinedEnds[userId];
    if (refined?.id == streamId && refined?.endedAt == video.endedAt) return;
    onStreamEnded?.call(streamId, video.endedAt);
    _refinedEnds[userId] = (id: streamId, endedAt: video.endedAt);
    target.messages.removeSystem('sys_stream:$streamId:end');
    target.addSystemMessageAt(
      [
        strings().streamEnded,
        ?_durationText(video.startedAt, video.endedAt),
      ].join(' - '),
      messageId: 'sys_stream:$streamId:end',
      at: video.endedAt.toLocal(),
      accent: streamAccent,
      maxMessages: getMaxMessages(),
    );
  }

  // The duration text for a start and end pair, absent when the start is
  // unknown or does not precede the end.
  String? _durationText(DateTime? started, DateTime ended) {
    if (started == null || !ended.isAfter(started)) return null;
    final d = ended.difference(started);
    return d.inHours > 0
        ? strings().streamDurationHm(d.inHours, d.inMinutes.remainder(60))
        : strings().streamDurationM(d.inMinutes);
  }

  void _applyStreamStatus(String channel, Map<String, dynamic>? stream) {
    if (_disposed || !_chatStatusChannels.contains(channel)) return;
    final parts = <String>[];
    if (stream != null && stream['type'] == 'live') {
      final viewers = (stream['viewer_count'] as num?)?.toInt() ?? 0;
      final started = DateTime.tryParse(stream['started_at'] as String? ?? '');
      if (started != null) {
        final dur = _now().difference(started);
        final h = dur.inHours;
        final m = dur.inMinutes.remainder(60);
        parts.add(strings().liveWithViewersFor(viewers, h, m));
      } else {
        parts.add(strings().liveWithViewers(viewers));
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
      if (slow > 0) parts.add(strings().roomSlow(slow));
      final followers = tags['followers-only'];
      if (followers != null && followers != '-1') {
        parts.add(
          followers == '0'
              ? strings().roomFollowersOnly
              : strings().roomFollowersOnlyMinutes(followers),
        );
      }
      if (tags['emote-only'] == '1') parts.add(strings().roomEmoteOnly);
      if (tags['subs-only'] == '1') parts.add(strings().roomSubscribersOnly);
      if (tags['r9k'] == '1') parts.add(strings().roomUniqueChat);
    }
    final stream = _streamStatusParts[channel] ?? const [];
    chat
        .channelFor(channel)
        ?.info
        .setStatus(stream.join(' · '), live: stream.isNotEmpty, modes: parts);
  }

  void _startChatStatusTimer() {
    _chatStatusTimer ??= Timer.periodic(
      _chatStatusInterval,
      (_) => fetchAllChatStatus(),
    );
  }
}
