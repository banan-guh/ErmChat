import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../util/constants.dart';
import '../util/log.dart';

/// Announces the viewer in a channel to 7TV when they chat (chatterino7
/// parity). The server then sends the viewer's badge, paint, and personal
/// emotes to every 7TV client in that channel; without it, other viewers
/// only see them when another 7TV client of ours announces.
///
/// At most one announce per channel a minute: a send blocks the channel for
/// five minutes until it answers, and a success reopens it after one.
class SevenTvPresence {
  SevenTvPresence({this._client, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final http.Client? _client;
  final DateTime Function() _now;

  static const _successGap = Duration(minutes: 1);
  static const _pendingGap = Duration(minutes: 5);

  // Viewer Twitch id -> 7TV user id; null when the viewer has no 7TV account.
  final _sevenTvIds = <String, String?>{};
  final _nextAt = <String, DateTime>{};

  /// Announces [viewerTwitchId] in the channel [channelTwitchId] unless that
  /// channel announced within the last minute. Never throws.
  Future<void> announce({
    required String channelTwitchId,
    required String viewerTwitchId,
  }) async {
    if (channelTwitchId.isEmpty || viewerTwitchId.isEmpty) return;
    final next = _nextAt[channelTwitchId];
    if (next != null && _now().isBefore(next)) return;
    _nextAt[channelTwitchId] = _now().add(_pendingGap);
    try {
      final sevenTvId = await _sevenTvIdFor(viewerTwitchId);
      if (sevenTvId == null) return;
      final res = await _send(
        http.Request(
            'POST',
            Uri.parse('https://7tv.io/v3/users/$sevenTvId/presences'),
          )
          ..headers['content-type'] = 'application/json'
          ..body = jsonEncode({
            'kind': 1,
            'passive': false,
            'data': {'platform': 'TWITCH', 'id': channelTwitchId},
          }),
      );
      if (res.statusCode == 200) {
        _nextAt[channelTwitchId] = _now().add(_successGap);
      }
    } catch (e) {
      logDebug('[SevenTvPresence] announce failed: $e');
    }
  }

  Future<String?> _sevenTvIdFor(String twitchId) async {
    if (_sevenTvIds.containsKey(twitchId)) return _sevenTvIds[twitchId];
    final res = await _send(
      http.Request(
        'GET',
        Uri.parse('https://7tv.io/v3/users/twitch/$twitchId'),
      ),
    );
    // 404 means no 7TV account: remember it. Other failures retry later.
    if (res.statusCode == 404) return _sevenTvIds[twitchId] = null;
    if (res.statusCode != 200) return null;
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final user = data['user'] as Map<String, dynamic>?;
    return _sevenTvIds[twitchId] = user?['id'] as String?;
  }

  Future<http.Response> _send(http.Request request) async {
    final client = _client;
    final streamed =
        await (client == null ? request.send() : client.send(request)).timeout(
          httpTimeout,
        );
    return http.Response.fromStream(streamed).timeout(httpTimeout);
  }
}
