import 'dart:async';

import '../chat/chat.dart';
import '../client/session.dart';
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
  });

  final TwitchApi twitchApi;
  final TwitchAuth twitchAuth;
  final Chat chat;
  final Session session;

  // Room-mode tags per channel from ROOMSTATE (merged across partial
  // updates); feeds the chat status splash. Stream info from the periodic
  // Helix fetch is kept separately so ROOMSTATE recomposes don't lose it.
  final _roomStateTags = <String, Map<String, String>>{};
  final _streamStatusParts = <String, List<String>>{};
  Timer? _chatStatusTimer;
  final _chatStatusChannels = <String>{};
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
    fetchChatStatus(channel);
    _chatStatusChannels.add(channel);
    _startChatStatusTimer();
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
    chat.channelFor(channel)?.info.setStatus(newStatus);
  }

  void _startChatStatusTimer() {
    _chatStatusTimer ??= Timer.periodic(
      _chatStatusInterval,
      (_) => fetchAllChatStatus(),
    );
  }
}
