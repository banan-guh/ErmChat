import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../twitch_config.dart';
import 'twitch_auth.dart';

class TwitchApi {
  static const _base = 'https://api.twitch.tv/helix';

  String? _lastError;

  String? get lastError => _lastError;

  late http.Client _client;

  TwitchApi({http.Client? client}) {
    _client = client ?? http.Client();
  }

  @visibleForTesting
  set client(http.Client c) => _client = c;

  Future<String?> getUserId(TwitchAuth auth, String login) async {
    _lastError = null;
    final uri = Uri.parse('$_base/users?login=$login');
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getUserId', res);
      return null;
    }
    try {
      final data = jsonDecode(res.body) as Map;
      final list = data['data'] as List;
      if (list.isEmpty) {
        _setError('User "$login" not found');
        return null;
      }
      return list[0]['id'] as String;
    } catch (e) {
      _setError('getUserId: bad response');
      return null;
    }
  }

  Future<String?> getUserLoginById(TwitchAuth auth, String userId) async {
    _lastError = null;
    final uri = Uri.parse('$_base/users?id=$userId');
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getUserLoginById', res);
      return null;
    }
    try {
      final data = jsonDecode(res.body) as Map;
      final list = data['data'] as List;
      if (list.isEmpty) return null;
      return list[0]['login'] as String;
    } catch (e) {
      _setError('getUserLoginById: bad response');
      return null;
    }
  }

  Future<Map<String, String>> getUserLoginsByIds(
    TwitchAuth auth,
    List<String> userIds,
  ) async {
    final result = <String, String>{};
    if (userIds.isEmpty) return result;
    for (var i = 0; i < userIds.length; i += 100) {
      final batch = userIds.sublist(i, (i + 100).clamp(0, userIds.length));
      final params = batch.map((id) => 'id=$id').join('&');
      final uri = Uri.parse('$_base/users?$params');
      final res = await _client.get(uri, headers: _headers(auth));
      if (res.statusCode != 200) continue;
      final data = jsonDecode(res.body) as Map;
      for (final u in (data['data'] as List<dynamic>? ?? [])) {
        final uid = u['id'] as String?;
        final login = u['login'] as String?;
        if (uid != null && login != null) {
          result[uid] = login;
        }
      }
    }
    return result;
  }

  Future<Map<String, String>?> getCurrentUser(TwitchAuth auth) async {
    _lastError = null;
    final uri = Uri.parse('$_base/users');
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getCurrentUser', res);
      return null;
    }
    try {
      final data = jsonDecode(res.body) as Map;
      final list = data['data'] as List;
      if (list.isEmpty) {
        _setError('No user associated with token');
        return null;
      }
      return {
        'id': list[0]['id'] as String,
        'login': list[0]['login'] as String,
      };
    } catch (e) {
      _setError('getCurrentUser: bad response');
      return null;
    }
  }

  Future<bool> createSubscription({
    required TwitchAuth auth,
    required String sessionId,
    required String broadcasterUserId,
    required String userId,
  }) async {
    _lastError = null;
    final uri = Uri.parse('$_base/eventsub/subscriptions');
    final body = jsonEncode({
      'type': 'channel.chat.message',
      'version': '1',
      'condition': {
        'broadcaster_user_id': broadcasterUserId,
        'user_id': userId,
      },
      'transport': {'method': 'websocket', 'session_id': sessionId},
    });
    final res = await _client.post(uri, headers: _headers(auth), body: body);
    if (res.statusCode == 409) return true;
    if (res.statusCode != 202) {
      _setError('createSubscription', res);
      return false;
    }
    return true;
  }

  Future<Map<String, dynamic>?> getChatSettings(
    TwitchAuth auth,
    String broadcasterId,
    String moderatorId,
  ) async {
    _lastError = null;
    final uri = Uri.parse(
      '$_base/chat/settings?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getChatSettings', res);
      return null;
    }
    try {
      final data = jsonDecode(res.body) as Map;
      final list = data['data'] as List;
      if (list.isEmpty) return null;
      return list[0] as Map<String, dynamic>;
    } catch (e) {
      _setError('getChatSettings: bad response');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getStreamInfo(
    TwitchAuth auth,
    String broadcasterId,
  ) async {
    _lastError = null;
    final uri = Uri.parse('$_base/streams?user_id=$broadcasterId');
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getStreamInfo', res);
      return null;
    }
    try {
      final data = jsonDecode(res.body) as Map;
      final list = data['data'] as List;
      if (list.isEmpty) return null;
      return list[0] as Map<String, dynamic>;
    } catch (e) {
      _setError('getStreamInfo: bad response');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getUserProfile(
    TwitchAuth auth,
    String login,
  ) async {
    _lastError = null;
    final uri = Uri.parse('$_base/users?login=$login');
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getUserProfile', res);
      return null;
    }
    try {
      final data = jsonDecode(res.body) as Map;
      final list = data['data'] as List;
      if (list.isEmpty) {
        _setError('User "$login" not found');
        return null;
      }
      return list[0] as Map<String, dynamic>;
    } catch (e) {
      _setError('getUserProfile: bad response');
      return null;
    }
  }

  Future<bool> blockUser(TwitchAuth auth, String targetUserId) async {
    _lastError = null;
    final uri = Uri.parse('$_base/users/blocks?target_user_id=$targetUserId');
    final res = await _client.put(uri, headers: _headers(auth));
    if (res.statusCode == 204) return true;
    _setError('blockUser', res);
    return false;
  }

  /// Fetches the account's full block list, following pagination (100/page).
  /// Returns lowercased blocked user logins; empty on failure (fail-open).
  Future<Set<String>> getBlockedUsers(TwitchAuth auth) async {
    _lastError = null;
    final logins = <String>{};
    if (auth.userId == null) return logins;
    String? cursor;
    while (true) {
      final query = <String, String>{
        'broadcaster_id': auth.userId!,
        'first': '100',
      };
      if (cursor != null) query['after'] = cursor;
      final uri = Uri.parse(
        '$_base/users/blocks',
      ).replace(queryParameters: query);
      final res = await _client.get(uri, headers: _headers(auth));
      if (res.statusCode != 200) {
        _setError('getBlockedUsers', res);
        return logins;
      }
      try {
        final data = jsonDecode(res.body) as Map;
        for (final item in data['data'] as List) {
          final login = (item as Map)['user_login'] as String?;
          if (login != null) logins.add(login.toLowerCase());
        }
        cursor = ((data['pagination'] as Map?)?['cursor']) as String?;
      } catch (e) {
        _setError('getBlockedUsers: bad response');
        return logins;
      }
      if (cursor == null || cursor.isEmpty) return logins;
    }
  }

  Future<String?> sendChatMessage(
    TwitchAuth auth, {
    required String broadcasterId,
    required String senderId,
    required String message,
    String? replyParentMessageId,
  }) async {
    _lastError = null;
    final uri = Uri.parse('$_base/chat/messages');
    final body = <String, dynamic>{
      'broadcaster_id': broadcasterId,
      'sender_id': senderId,
      'message': message,
    };
    if (replyParentMessageId != null) {
      body['reply_parent_message_id'] = replyParentMessageId;
    }
    final res = await _client.post(
      uri,
      headers: _headers(auth),
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      _setError('sendChatMessage', res);
      return null;
    }
    try {
      final data = jsonDecode(res.body) as Map;
      final list = data['data'] as List;
      if (list.isEmpty) return null;
      final item = list[0] as Map<String, dynamic>;
      if (item['is_sent'] != true) {
        final dropReason = item['drop_reason'] as Map<String, dynamic>?;
        _setError(
          'sendChatMessage dropped: ${dropReason?['message'] ?? "unknown"}',
        );
        return null;
      }
      return item['message_id'] as String;
    } catch (e) {
      _setError('sendChatMessage: bad response');
      return null;
    }
  }

  Future<bool> updateUserChatColor(
    TwitchAuth auth, {
    required String userId,
    required String color,
  }) async {
    _lastError = null;
    final uri = Uri.parse(
      '$_base/chat/color?user_id=$userId&color=${Uri.encodeComponent(color)}',
    );
    final res = await _client.put(uri, headers: _headers(auth));
    if (res.statusCode == 204) return true;
    _setError('updateUserChatColor', res);
    return false;
  }

  Future<bool> banUser(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String userId,
    int? duration,
    String? reason,
  }) async {
    _lastError = null;
    final uri = Uri.parse(
      '$_base/moderation/bans?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final data = <String, String>{'user_id': userId};
    if (duration != null) data['duration'] = duration.toString();
    if (reason != null && reason.isNotEmpty) data['reason'] = reason;
    final body = jsonEncode({'data': data});
    final res = await _client.post(uri, headers: _headers(auth), body: body);
    if (res.statusCode == 200) return true;
    _setError('banUser', res);
    return false;
  }

  Future<bool> unbanUser(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String userId,
  }) async {
    _lastError = null;
    final uri = Uri.parse(
      '$_base/moderation/bans?broadcaster_id=$broadcasterId&moderator_id=$moderatorId&user_id=$userId',
    );
    final res = await _client.delete(uri, headers: _headers(auth));
    if (res.statusCode == 204) return true;
    _setError('unbanUser', res);
    return false;
  }

  Future<bool> deleteChatMessage(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    String? messageId,
  }) async {
    _lastError = null;
    var url =
        '$_base/moderation/chat?broadcaster_id=$broadcasterId&moderator_id=$moderatorId';
    if (messageId != null) url += '&message_id=$messageId';
    final uri = Uri.parse(url);
    final res = await _client.delete(uri, headers: _headers(auth));
    if (res.statusCode == 204) return true;
    _setError('deleteChatMessage', res);
    return false;
  }

  Future<bool> sendChatAnnouncement(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String message,
    String color = 'primary',
  }) async {
    _lastError = null;
    final uri = Uri.parse(
      '$_base/chat/announcements?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final body = jsonEncode({'message': message, 'color': color});
    final res = await _client.post(uri, headers: _headers(auth), body: body);
    if (res.statusCode == 204) return true;
    _setError('sendChatAnnouncement', res);
    return false;
  }

  Future<bool> sendShoutout(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String targetUserId,
  }) async {
    _lastError = null;
    final uri = Uri.parse('$_base/chat/shoutouts');
    final body = jsonEncode({
      'from_broadcaster_id': broadcasterId,
      'to_broadcaster_id': targetUserId,
      'moderator_id': moderatorId,
    });
    final res = await _client.post(uri, headers: _headers(auth), body: body);
    if (res.statusCode == 200) return true;
    _setError('sendShoutout', res);
    return false;
  }

  Map<String, String> _headers(TwitchAuth auth) => {
    'Client-ID': TwitchConfig.clientId,
    'Authorization': 'Bearer ${auth.accessToken ?? ''}',
    'Content-Type': 'application/json',
  };

  void _setError(String label, [http.Response? res]) {
    if (res != null) {
      _lastError = '$label failed (${res.statusCode}): ${res.body}';
    } else {
      _lastError = label;
    }
  }
}
