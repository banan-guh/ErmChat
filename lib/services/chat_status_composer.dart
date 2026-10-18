import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
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
  final _streamStatusParts = <String, List<String>>{};
  Timer? _chatStatusTimer;
  final _chatStatusChannels = <String>{};
  bool _fetchScheduled = false;
  static const _chatStatusInterval = Duration(seconds: 30);

  void dispose() {
    _chatStatusTimer?.cancel();
    _chatStatusTimer = null;
    _chatStatusChannels.clear();
  }

  /// Merges partial ROOMSTATE tags for [channel] and recomposes its status.
  void onRoomState(String channel, Map<String, String> tags) {
    _roomStateTags[channel] = {...?_roomStateTags[channel], ...tags};
    _composeChatStatus(channel);
  }

  /// Starts the periodic status fetch for [channel] and arms the timer.
  void startFor(String channel) {
    _chatStatusChannels.add(channel);
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
      unawaited(fetchAllChatStatus());
    });
  }

  /// Stops tracking [channel] and drops its accumulated status bits.
  void stopFor(String channel) {
    _chatStatusChannels.remove(channel);
    if (_chatStatusChannels.isEmpty) {
      _chatStatusTimer?.cancel();
      _chatStatusTimer = null;
    }
    _roomStateTags.remove(channel);
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
    _applyStreamStatus(channel, stream);
    await _applyStreamMarkers({userId: (channel, stream)});
  }

  Future<void> fetchAllChatStatus() async {
    final auth = twitchAuth;
    if (!auth.isConfigured) return;
    final ids = <String>[];
    for (final channel in _chatStatusChannels) {
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
    for (final channel in _chatStatusChannels) {
      final userId = chat.channelFor(channel)?.info.broadcasterId;
      _applyStreamStatus(channel, userId != null ? streams[userId] : null);
    }
    final polls = <String, (String, Map<String, dynamic>?)>{};
    for (final channel in _chatStatusChannels) {
      final id = chat.channelFor(channel)?.info.broadcasterId;
      if (id != null) polls[id] = (channel, streams[id]);
    }
    await _applyStreamMarkers(polls);
  }

  // Consecutive offline polls per broadcaster. Helix can briefly list a live
  // stream as gone, so an end needs two.
  final _offlinePolls = <String, int>{};

  static String _markerKey(String userId) => 'stream_marker.$userId';

  /// Writes "Stream started" and "Stream ended" rows from stream transitions.
  /// The last seen stream (id, started_at, last live poll, ended) persists per
  /// broadcaster so a restart neither repeats a start nor loses an end, and an
  /// ended id seen live again takes its end back. A start sits at its
  /// `started_at` position even when that is older than the buffer;
  /// truncation drops it with the other old rows.
  Future<void> _applyStreamMarkers(
    Map<String, (String, Map<String, dynamic>?)> polls,
  ) async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      logDebug('[ChatConn] stream markers skipped: $e');
      return;
    }
    final now = _now();
    for (final MapEntry(key: userId, value: (channel, stream))
        in polls.entries) {
      final target = chat.channelFor(channel);
      if (target == null) continue;
      final saved = _readMarker(prefs, userId);
      final id = stream?['id'] as String?;
      final live = stream != null && stream['type'] == 'live' && id != null;
      if (!live) {
        if (saved == null || saved.ended) continue;
        final polls = (_offlinePolls[userId] ?? 0) + 1;
        _offlinePolls[userId] = polls;
        if (polls < 2) continue;
        _offlinePolls.remove(userId);
        _writeEnded(target, saved);
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
      if (saved != null && saved.id != id && !saved.ended) {
        _writeEnded(target, saved);
      }
      if (saved != null && saved.id == id && saved.ended) {
        target.messages.removeSystem('sys_stream:$id:end');
      }
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
    final started = marker.startedAt;
    String? duration;
    if (started != null && marker.seenAt.isAfter(started)) {
      final d = marker.seenAt.difference(started);
      duration = d.inHours > 0
          ? strings().streamDurationHm(d.inHours, d.inMinutes.remainder(60))
          : strings().streamDurationM(d.inMinutes);
    }
    target.addSystemMessageAt(
      [strings().streamEnded, ?duration].join(' - '),
      messageId: 'sys_stream:${marker.id}:end',
      at: marker.seenAt,
      accent: streamAccent,
      maxMessages: getMaxMessages(),
    );
  }

  void _applyStreamStatus(String channel, Map<String, dynamic>? stream) {
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
