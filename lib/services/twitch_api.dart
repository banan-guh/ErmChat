import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../twitch_config.dart';
import '../util/constants.dart';
import 'twitch_auth.dart';

class TwitchApi {
  static const _base = 'https://api.twitch.tv/helix';

  String? _lastError;
  int? _lastErrorStatus;
  String? _lastHelixMessage;

  String? get lastError => _lastError;

  /// HTTP status of the last failed call, or null when no HTTP error.
  int? get lastErrorStatus => _lastErrorStatus;

  /// Helix error `message`, or null.
  String? get lastHelixMessage => _lastHelixMessage;

  late http.Client _client;

  TwitchApi({http.Client? client}) {
    _client = client ?? http.Client();
  }

  @visibleForTesting
  set client(http.Client c) => _client = c;

  void _clearError() {
    _lastError = null;
    _lastErrorStatus = null;
    _lastHelixMessage = null;
  }

  Future<String?> getUserId(TwitchAuth auth, String login) async {
    _clearError();
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

  Future<Map<String, String?>?> getCurrentUser(TwitchAuth auth) async {
    _clearError();
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
      final raw = list[0] as Map;
      final login = raw['login'] as String? ?? '';
      return {
        'id': raw['id'] as String?,
        'login': login,
        'display_name': raw['display_name'] as String? ?? login,
        'profile_image_url': raw['profile_image_url'] as String?,
      };
    } catch (e) {
      _setError('getCurrentUser: bad response');
      return null;
    }
  }

  /// ID-to-login map via Helix GET /users (batched at 100). Unresolved IDs
  /// are absent.
  Future<Map<String, String>> getUserLoginsByIds(
    TwitchAuth auth,
    List<String> ids,
  ) async {
    _clearError();
    final result = <String, String>{};
    final uniqueIds = ids.toSet().toList();
    // Helix caps at 100 ids per request; chunk accordingly.
    const chunkSize = 100;
    for (var i = 0; i < uniqueIds.length; i += chunkSize) {
      var end = i + chunkSize;
      if (end > uniqueIds.length) end = uniqueIds.length;
      final chunk = uniqueIds.sublist(i, end);
      final query = chunk.map((id) => 'id=$id').join('&');
      final uri = Uri.parse('$_base/users?$query');
      final res = await _client.get(uri, headers: _headers(auth));
      if (res.statusCode != 200) {
        _setError('getUserLoginsByIds', res);
        continue;
      }
      try {
        final data = jsonDecode(res.body) as Map;
        final list = data['data'] as List? ?? [];
        for (final item in list) {
          final id = item['id'] as String?;
          final login = item['login'] as String?;
          if (id != null && login != null) result[id] = login;
        }
      } catch (e) {
        _setError('getUserLoginsByIds: bad response');
      }
    }
    return result;
  }

  Future<bool> createEventSubSubscription({
    required TwitchAuth auth,
    required String sessionId,
    required String type,
    required String version,
    required Map<String, dynamic> condition,
  }) async {
    _clearError();
    final uri = Uri.parse('$_base/eventsub/subscriptions');
    final body = jsonEncode({
      'type': type,
      'version': version,
      'condition': condition,
      'transport': {'method': 'websocket', 'session_id': sessionId},
    });
    final res = await _client.post(uri, headers: _headers(auth), body: body);
    if (res.statusCode == 409) return true;
    if (res.statusCode != 202) {
      _setError('createEventSubSubscription', res);
      return false;
    }
    return true;
  }

  Future<Map<String, dynamic>?> getStreamInfo(
    TwitchAuth auth,
    String broadcasterId,
  ) async {
    _clearError();
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

  Future<Map<String, Map<String, dynamic>>> getStreams(
    TwitchAuth auth,
    List<String> broadcasterIds,
  ) async {
    _clearError();
    if (broadcasterIds.isEmpty) return {};
    final query = broadcasterIds.map((id) => 'user_id=$id').join('&');
    final uri = Uri.parse('$_base/streams?$query');
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getStreams', res);
      return {};
    }
    try {
      final data = jsonDecode(res.body) as Map;
      final list = data['data'] as List;
      final byId = <String, Map<String, dynamic>>{};
      for (final item in list) {
        final m = item as Map<String, dynamic>;
        final id = m['user_id'] as String?;
        if (id != null) byId[id] = m;
      }
      return byId;
    } catch (e) {
      _setError('getStreams: bad response');
      return {};
    }
  }

  Future<Map<String, dynamic>?> getUserProfile(
    TwitchAuth auth,
    String login,
  ) async {
    _clearError();
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
    _clearError();
    final uri = Uri.parse('$_base/users/blocks?target_user_id=$targetUserId');
    final res = await _client.put(uri, headers: _headers(auth));
    if (res.statusCode == 204) return true;
    _setError('blockUser', res);
    return false;
  }

  /// Full paginated block list. Lowercased logins; empty on failure.
  Future<Set<String>> getBlockedUsers(TwitchAuth auth) async {
    _clearError();
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
    _clearError();
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
    _clearError();
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
    _clearError();
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
    _clearError();
    final uri = Uri.parse(
      '$_base/moderation/bans?broadcaster_id=$broadcasterId&moderator_id=$moderatorId&user_id=$userId',
    );
    final res = await _client.delete(uri, headers: _headers(auth));
    if (res.statusCode == 204) return true;
    _setError('unbanUser', res);
    return false;
  }

  /// Warns a user. Arrives as an EventSub/IRC moderation event.
  Future<bool> warnUser(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String userId,
    String? reason,
  }) async {
    _clearError();
    final uri = Uri.parse(
      '$_base/moderation/warnings?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final data = <String, String>{'user_id': userId};
    if (reason != null && reason.isNotEmpty) data['reason'] = reason;
    final body = jsonEncode({'data': data});
    final res = await _client.post(uri, headers: _headers(auth), body: body);
    if (res.statusCode == 200) return true;
    _setError('warnUser', res);
    return false;
  }

  Future<bool> deleteChatMessage(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    String? messageId,
  }) async {
    _clearError();
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
    _clearError();
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
    _clearError();
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

  Future<bool> unblockUser(TwitchAuth auth, String targetUserId) async {
    _clearError();
    final uri = Uri.parse('$_base/users/blocks?target_user_id=$targetUserId');
    final res = await _client.delete(uri, headers: _headers(auth));
    if (res.statusCode == 204) return true;
    _setError('unblockUser', res);
    return false;
  }

  /// Paginated moderator logins; empty on failure.
  Future<List<String>> getModerators(
    TwitchAuth auth,
    String broadcasterId,
  ) async {
    _clearError();
    final logins = <String>[];
    String? cursor;
    while (true) {
      final query = <String, String>{
        'broadcaster_id': broadcasterId,
        'first': '100',
      };
      if (cursor != null) query['after'] = cursor;
      final uri = Uri.parse(
        '$_base/moderation/moderators',
      ).replace(queryParameters: query);
      final res = await _client.get(uri, headers: _headers(auth));
      if (res.statusCode != 200) {
        _setError('getModerators', res);
        return logins;
      }
      try {
        final data = jsonDecode(res.body) as Map;
        for (final item in data['data'] as List) {
          final login = (item as Map)['user_login'] as String?;
          if (login != null) logins.add(login);
        }
        cursor = ((data['pagination'] as Map?)?['cursor']) as String?;
      } catch (e) {
        _setError('getModerators: bad response');
        return logins;
      }
      if (cursor == null || cursor.isEmpty) return logins;
    }
  }

  Future<bool> addModerator(
    TwitchAuth auth, {
    required String broadcasterId,
    required String userId,
  }) async {
    _clearError();
    final uri = Uri.parse(
      '$_base/moderation/moderators?broadcaster_id=$broadcasterId&user_id=$userId',
    );
    final res = await _client.post(uri, headers: _headers(auth));
    if (res.statusCode == 204) return true;
    _setError('addModerator', res);
    return false;
  }

  Future<bool> removeModerator(
    TwitchAuth auth, {
    required String broadcasterId,
    required String userId,
  }) async {
    _clearError();
    final uri = Uri.parse(
      '$_base/moderation/moderators?broadcaster_id=$broadcasterId&user_id=$userId',
    );
    final res = await _client.delete(uri, headers: _headers(auth));
    if (res.statusCode == 204) return true;
    _setError('removeModerator', res);
    return false;
  }

  /// Paginated VIP logins; empty on failure.
  Future<List<String>> getVips(TwitchAuth auth, String broadcasterId) async {
    _clearError();
    final logins = <String>[];
    String? cursor;
    while (true) {
      final query = <String, String>{
        'broadcaster_id': broadcasterId,
        'first': '100',
      };
      if (cursor != null) query['after'] = cursor;
      final uri = Uri.parse(
        '$_base/channels/vips',
      ).replace(queryParameters: query);
      final res = await _client.get(uri, headers: _headers(auth));
      if (res.statusCode != 200) {
        _setError('getVips', res);
        return logins;
      }
      try {
        final data = jsonDecode(res.body) as Map;
        for (final item in data['data'] as List) {
          final login = (item as Map)['user_login'] as String?;
          if (login != null) logins.add(login);
        }
        cursor = ((data['pagination'] as Map?)?['cursor']) as String?;
      } catch (e) {
        _setError('getVips: bad response');
        return logins;
      }
      if (cursor == null || cursor.isEmpty) return logins;
    }
  }

  Future<bool> addVip(
    TwitchAuth auth, {
    required String broadcasterId,
    required String userId,
  }) async {
    _clearError();
    final uri = Uri.parse(
      '$_base/channels/vips?broadcaster_id=$broadcasterId&user_id=$userId',
    );
    final res = await _client.post(uri, headers: _headers(auth));
    if (res.statusCode == 204) return true;
    _setError('addVip', res);
    return false;
  }

  Future<bool> removeVip(
    TwitchAuth auth, {
    required String broadcasterId,
    required String userId,
  }) async {
    _clearError();
    final uri = Uri.parse(
      '$_base/channels/vips?broadcaster_id=$broadcasterId&user_id=$userId',
    );
    final res = await _client.delete(uri, headers: _headers(auth));
    if (res.statusCode == 204) return true;
    _setError('removeVip', res);
    return false;
  }

  /// PATCHes chat settings (slow, follower, emote, subscriber, unique mode).
  Future<bool> updateChatSettings(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required Map<String, dynamic> body,
  }) async {
    _clearError();
    final uri = Uri.parse(
      '$_base/chat/settings?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final res = await _client.patch(
      uri,
      headers: _headers(auth),
      body: jsonEncode(body),
    );
    if (res.statusCode == 200) return true;
    _setError('updateChatSettings', res);
    return false;
  }

  Future<bool> startCommercial(
    TwitchAuth auth, {
    required String broadcasterId,
    required int length,
  }) async {
    _clearError();
    final uri = Uri.parse('$_base/channels/commercial');
    final body = jsonEncode({
      'broadcaster_id': broadcasterId,
      'length': length,
    });
    final res = await _client.post(uri, headers: _headers(auth), body: body);
    if (res.statusCode == 200) return true;
    _setError('startCommercial', res);
    return false;
  }

  Future<bool> startRaid(
    TwitchAuth auth, {
    required String fromBroadcasterId,
    required String toBroadcasterId,
  }) async {
    _clearError();
    final uri = Uri.parse(
      '$_base/raids?from_broadcaster_id=$fromBroadcasterId&to_broadcaster_id=$toBroadcasterId',
    );
    final res = await _client.post(uri, headers: _headers(auth));
    if (res.statusCode == 200) return true;
    _setError('startRaid', res);
    return false;
  }

  Future<bool> cancelRaid(
    TwitchAuth auth, {
    required String broadcasterId,
  }) async {
    _clearError();
    final uri = Uri.parse('$_base/raids?broadcaster_id=$broadcasterId');
    final res = await _client.delete(uri, headers: _headers(auth));
    if (res.statusCode == 204) return true;
    _setError('cancelRaid', res);
    return false;
  }

  Future<bool> updateShieldMode(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required bool active,
  }) async {
    _clearError();
    final uri = Uri.parse(
      '$_base/moderation/shield_mode?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final body = jsonEncode({'is_active': active});
    final res = await _client.put(uri, headers: _headers(auth), body: body);
    if (res.statusCode == 200) return true;
    _setError('updateShieldMode', res);
    return false;
  }

  Future<bool> createMarker(
    TwitchAuth auth, {
    required String broadcasterId,
    String? description,
  }) async {
    _clearError();
    final uri = Uri.parse('$_base/streams/markers');
    final body = <String, dynamic>{'user_id': broadcasterId};
    if (description != null && description.isNotEmpty) {
      body['description'] = description;
    }
    final res = await _client.post(
      uri,
      headers: _headers(auth),
      body: jsonEncode(body),
    );
    if (res.statusCode == 200) return true;
    _setError('createMarker', res);
    return false;
  }

  // Broadcaster-only; 403s surface via the shared failure-notice path.

  /// Creates a poll (2-5 choices, 15-1800s duration enforced by the caller).
  Future<bool> createPoll(
    TwitchAuth auth, {
    required String broadcasterId,
    required String title,
    required List<String> choices,
    required int durationSeconds,
  }) async {
    _clearError();
    final uri = Uri.parse('$_base/polls');
    final body = jsonEncode({
      'broadcaster_id': broadcasterId,
      'title': title,
      'choices': [
        for (final c in choices) {'title': c},
      ],
      'duration': durationSeconds,
    });
    final res = await _client.post(uri, headers: _headers(auth), body: body);
    if (res.statusCode == 200) return true;
    _setError('createPoll', res);
    return false;
  }

  /// Ends a poll. TERMINATED shows results; ARCHIVED does not.
  Future<bool> endPoll(
    TwitchAuth auth, {
    required String broadcasterId,
    required String pollId,
    required bool archive,
  }) async {
    _clearError();
    final uri = Uri.parse('$_base/polls');
    final res = await _client.patch(
      uri,
      headers: _headers(auth),
      body: jsonEncode({
        'broadcaster_id': broadcasterId,
        'id': pollId,
        'status': archive ? 'ARCHIVED' : 'TERMINATED',
      }),
    );
    if (res.statusCode == 200) return true;
    _setError('endPoll', res);
    return false;
  }

  /// Channel polls, newest first. Empty on failure.
  Future<List<Map<String, dynamic>>> getPolls(
    TwitchAuth auth,
    String broadcasterId,
  ) async {
    _clearError();
    final uri = Uri.parse('$_base/polls?broadcaster_id=$broadcasterId');
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getPolls', res);
      return const [];
    }
    try {
      final data = jsonDecode(res.body)['data'] as List<dynamic>;
      return data.cast<Map<String, dynamic>>();
    } catch (_) {
      _setError('getPolls: bad response');
      return const [];
    }
  }

  /// Creates a prediction (2-11 outcomes; window in seconds).
  Future<bool> createPrediction(
    TwitchAuth auth, {
    required String broadcasterId,
    required String title,
    required List<String> outcomes,
    required int windowSeconds,
  }) async {
    _clearError();
    final uri = Uri.parse('$_base/predictions');
    final body = jsonEncode({
      'broadcaster_id': broadcasterId,
      'title': title,
      'outcomes': [
        for (final o in outcomes) {'title': o},
      ],
      'prediction_window': windowSeconds,
    });
    final res = await _client.post(uri, headers: _headers(auth), body: body);
    if (res.statusCode == 200) return true;
    _setError('createPrediction', res);
    return false;
  }

  /// Ends a prediction. LOCKED/CANCELED/RESOLVED; RESOLVED needs
  /// [winningOutcomeId].
  Future<bool> endPrediction(
    TwitchAuth auth, {
    required String broadcasterId,
    required String predictionId,
    required String status,
    String? winningOutcomeId,
  }) async {
    _clearError();
    final uri = Uri.parse('$_base/predictions');
    final body = <String, dynamic>{
      'broadcaster_id': broadcasterId,
      'id': predictionId,
      'status': status,
      'winning_outcome_id': ?winningOutcomeId,
    };
    final res = await _client.patch(
      uri,
      headers: _headers(auth),
      body: jsonEncode(body),
    );
    if (res.statusCode == 200) return true;
    _setError('endPrediction', res);
    return false;
  }

  /// Channel predictions, newest first.
  Future<List<Map<String, dynamic>>> getPredictions(
    TwitchAuth auth,
    String broadcasterId,
  ) async {
    _clearError();
    final uri = Uri.parse('$_base/predictions?broadcaster_id=$broadcasterId');
    final res = await _client.get(uri, headers: _headers(auth));
    if (res.statusCode != 200) {
      _setError('getPredictions', res);
      return const [];
    }
    try {
      final data = jsonDecode(res.body)['data'] as List<dynamic>;
      return data.cast<Map<String, dynamic>>();
    } catch (_) {
      _setError('getPredictions: bad response');
      return const [];
    }
  }

  Future<bool> sendWhisper(
    TwitchAuth auth, {
    required String fromUserId,
    required String toUserId,
    required String message,
  }) async {
    _clearError();
    final uri = Uri.parse(
      '$_base/whispers?from_user_id=$fromUserId&to_user_id=$toUserId',
    );
    final body = jsonEncode({'message': message});
    final res = await _client.post(uri, headers: _headers(auth), body: body);
    if (res.statusCode == 204) return true;
    _setError('sendWhisper', res);
    return false;
  }

  Map<String, String> _headers(TwitchAuth auth) => {
    'Client-ID': TwitchConfig.clientId,
    'Authorization': 'Bearer ${auth.accessToken ?? ''}',
    'Content-Type': 'application/json',
  };

  /// Validates the token. Returns login/userId/expiresIn on success. Null on
  /// failure; check [lastErrorStatus] -- only 401 is definitive.
  Future<({String login, String userId, int expiresIn})?> validateToken(
    TwitchAuth auth,
  ) async {
    _clearError();
    final uri = Uri.parse('https://id.twitch.tv/oauth2/validate');
    try {
      final res = await _client
          .get(
            uri,
            headers: {'Authorization': 'Bearer ${auth.accessToken ?? ''}'},
          )
          .timeout(httpTimeout);
      if (res.statusCode != 200) {
        _setError('validateToken', res);
        return null;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return (
        login: data['login'] as String? ?? '',
        userId: data['user_id'] as String? ?? '',
        expiresIn: data['expires_in'] as int? ?? 0,
      );
    } catch (e) {
      _lastError = 'validateToken: $e';
      return null;
    }
  }

  void _setError(String label, [http.Response? res]) {
    _lastErrorStatus = res?.statusCode;
    _lastHelixMessage = _parseHelixMessage(res);
    if (res != null) {
      _lastError = '$label failed (${res.statusCode}): ${res.body}';
    } else {
      _lastError = label;
    }
  }

  static String? _parseHelixMessage(http.Response? res) {
    if (res == null) return null;
    try {
      final data = jsonDecode(res.body);
      if (data is Map) {
        final message = data['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    } catch (e) {
      // Body is not JSON; nothing useful to extract.
    }
    return null;
  }
}
