import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../l10n/l10n.dart';
import '../twitch_config.dart';
import '../util/constants.dart';
import '../util/friendly_error.dart';
import '../models/point_rewards.dart';
import '../models/polls.dart';
import 'twitch_auth.dart';

/// Applies [httpTimeout] to every Helix call. A stalled request throws
/// [TimeoutException], the same shape callers already get from an offline
/// [SocketException], instead of hanging the join/moderation path forever.
class _TimeoutClient extends http.BaseClient {
  _TimeoutClient(http.Client inner) : _inner = inner;

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _inner.send(request).timeout(httpTimeout);
  }

  @override
  void close() => _inner.close();
}

/// One banned or timed-out user from the broadcaster-only list.
/// [expiresAt] is null for permanent bans.
class BannedUser {
  final String userLogin;
  final String? expiresAt;
  final String? reason;
  final String? moderatorName;

  const BannedUser({
    required this.userLogin,
    this.expiresAt,
    this.reason,
    this.moderatorName,
  });

  factory BannedUser.fromJson(Map<String, dynamic> json) {
    final expires = json['expires_at'] as String?;
    final reason = json['reason'] as String?;
    return BannedUser(
      userLogin: json['user_login'] as String? ?? '',
      expiresAt: (expires == null || expires.isEmpty) ? null : expires,
      reason: (reason == null || reason.isEmpty) ? null : reason,
      moderatorName: json['moderator_name'] as String?,
    );
  }
}

/// One unban request in a channel's inbox.
class UnbanRequest {
  final String id;
  final String userLogin;
  final String text;
  final String status;
  final String createdAt;
  final String? resolutionText;
  final String? moderatorName;

  const UnbanRequest({
    required this.id,
    required this.userLogin,
    required this.text,
    required this.status,
    required this.createdAt,
    this.resolutionText,
    this.moderatorName,
  });

  factory UnbanRequest.fromJson(Map<String, dynamic> json) => UnbanRequest(
    id: json['id'] as String? ?? '',
    userLogin: json['user_login'] as String? ?? '',
    text: json['text'] as String? ?? '',
    status: json['status'] as String? ?? 'pending',
    createdAt: json['created_at'] as String? ?? '',
    resolutionText: json['resolution_text'] as String?,
    moderatorName: json['moderator_name'] as String?,
  );
}

/// One public blocked term. Private terms never come through Helix.
class BlockedTerm {
  final String id;
  final String text;
  final String createdAt;
  final String? expiresAt;

  const BlockedTerm({
    required this.id,
    required this.text,
    required this.createdAt,
    this.expiresAt,
  });

  factory BlockedTerm.fromJson(Map<String, dynamic> json) => BlockedTerm(
    id: json['id'] as String? ?? '',
    text: json['text'] as String? ?? '',
    createdAt: json['created_at'] as String? ?? '',
    expiresAt: json['expires_at'] as String?,
  );
}

/// Broadcaster AutoMod settings. Levels are 0-4 per category; [overallLevel]/// is null when the broadcaster customized individual categories.
class AutoModSettings {
  static const List<String> categories = [
    'disability',
    'aggression',
    'sexuality_sex_or_gender',
    'misogyny',
    'bullying',
    'swearing',
    'race_ethnicity_or_religion',
    'sex_based_terms',
  ];

  final int? overallLevel;
  final Map<String, int> levels;

  const AutoModSettings({required this.overallLevel, required this.levels});

  factory AutoModSettings.fromJson(Map<String, dynamic> json) {
    final levels = <String, int>{};
    for (final key in categories) {
      final value = json[key];
      if (value is int) levels[key] = value.clamp(0, 4);
    }
    return AutoModSettings(
      overallLevel: json['overall_level'] as int?,
      levels: levels,
    );
  }
}

/// Failure details of the most recent Helix call in one error scope.
class _ErrorSlot {
  String? error;
  int? status;
  String? helixMessage;

  void clear() {
    error = null;
    status = null;
    helixMessage = null;
  }
}

class TwitchApi {
  static const _base = 'https://api.twitch.tv/helix';
  static final _slotKey = Object();
  final _global = _ErrorSlot();

  _ErrorSlot? get _scoped => Zone.current[_slotKey] as _ErrorSlot?;
  _ErrorSlot get _slot => _scoped ?? _global;

  String? get lastError => _slot.error;

  /// HTTP status of the last failed call, or null when no HTTP error.
  int? get lastErrorStatus => _slot.status;

  /// Helix error `message`, or null.
  String? get lastHelixMessage => _slot.helixMessage;

  /// The last failure in words a person can act on: a known status first,
  /// then Twitch's own message (already plain English), then a generic line.
  String get friendlyLastError {
    final l = strings?.call() ?? englishStrings();
    return friendlyHttpStatus(lastErrorStatus, l) ??
        lastHelixMessage ??
        l.errorTwitchRequest;
  }

  /// Runs [body] in its own error scope: the `last*` getters inside it see
  /// only failures from calls it made, so concurrent loads cannot read each
  /// other's status. Failures still reach the unscoped getters as well.
  Future<T> isolateErrors<T>(Future<T> Function() body) =>
      runZoned(body, zoneValues: {_slotKey: _ErrorSlot()});

  late http.Client _client;

  /// Strings for user-facing failure text; English when unset.
  final AppLocalizations Function()? strings;

  TwitchApi({http.Client? client, this.strings}) {
    _client = _TimeoutClient(client ?? http.Client());
  }

  @visibleForTesting
  set client(http.Client c) => _client = _TimeoutClient(c);

  /// Closes the underlying HTTP client; the provider calls this on teardown.
  void close() => _client.close();

  void _clearError() {
    _global.clear();
    _scoped?.clear();
  }

  /// Clears the previous error, runs one request, and records the failure
  /// when the status is not in [ok]. Null tells the caller to return its
  /// empty or false value.
  Future<http.Response?> _send(
    String label,
    Future<http.Response> Function() request, {
    Set<int> ok = const {200},
  }) async {
    _clearError();
    final res = await request();
    if (!ok.contains(res.statusCode)) {
      _setError(label, res);
      return null;
    }
    return res;
  }

  Future<http.Response?> _get(
    String label,
    TwitchAuth auth,
    Uri uri, {
    Set<int> ok = const {200},
  }) => _send(label, () => _client.get(uri, headers: _headers(auth)), ok: ok);

  Future<http.Response?> _post(
    String label,
    TwitchAuth auth,
    Uri uri, {
    String? body,
    Set<int> ok = const {200},
  }) => _send(
    label,
    () => _client.post(uri, headers: _headers(auth), body: body),
    ok: ok,
  );

  Future<http.Response?> _put(
    String label,
    TwitchAuth auth,
    Uri uri, {
    String? body,
    Set<int> ok = const {200},
  }) => _send(
    label,
    () => _client.put(uri, headers: _headers(auth), body: body),
    ok: ok,
  );

  Future<http.Response?> _patch(
    String label,
    TwitchAuth auth,
    Uri uri, {
    String? body,
    Set<int> ok = const {200},
  }) => _send(
    label,
    () => _client.patch(uri, headers: _headers(auth), body: body),
    ok: ok,
  );

  Future<http.Response?> _delete(
    String label,
    TwitchAuth auth,
    Uri uri, {
    Set<int> ok = const {200},
  }) =>
      _send(label, () => _client.delete(uri, headers: _headers(auth)), ok: ok);

  Future<bool> _postOk(
    String label,
    TwitchAuth auth,
    Uri uri, {
    String? body,
    Set<int> ok = const {200},
  }) async => (await _post(label, auth, uri, body: body, ok: ok)) != null;

  Future<bool> _putOk(
    String label,
    TwitchAuth auth,
    Uri uri, {
    String? body,
    Set<int> ok = const {200},
  }) async => (await _put(label, auth, uri, body: body, ok: ok)) != null;

  Future<bool> _patchOk(
    String label,
    TwitchAuth auth,
    Uri uri, {
    String? body,
    Set<int> ok = const {200},
  }) async => (await _patch(label, auth, uri, body: body, ok: ok)) != null;

  Future<bool> _deleteOk(
    String label,
    TwitchAuth auth,
    Uri uri, {
    Set<int> ok = const {200},
  }) async => (await _delete(label, auth, uri, ok: ok)) != null;

  Future<String?> getUserId(TwitchAuth auth, String login) async {
    final uri = Uri.parse('$_base/users?login=$login');
    final res = await _get('getUserId', auth, uri);
    if (res == null) return null;
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
    final uri = Uri.parse('$_base/users');
    final res = await _get('getCurrentUser', auth, uri);
    if (res == null) return null;
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
    final uri = Uri.parse('$_base/eventsub/subscriptions');
    final body = jsonEncode({
      'type': type,
      'version': version,
      'condition': condition,
      'transport': {'method': 'websocket', 'session_id': sessionId},
    });
    final res = await _post(
      'createEventSubSubscription',
      auth,
      uri,
      body: body,
      ok: const {202, 409},
    );
    return res != null;
  }

  Future<Map<String, dynamic>?> getStreamInfo(
    TwitchAuth auth,
    String broadcasterId,
  ) async {
    final uri = Uri.parse('$_base/streams?user_id=$broadcasterId');
    final res = await _get('getStreamInfo', auth, uri);
    if (res == null) return null;
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
    if (broadcasterIds.isEmpty) {
      _clearError();
      return {};
    }
    final query = broadcasterIds.map((id) => 'user_id=$id').join('&');
    final uri = Uri.parse('$_base/streams?$query');
    final res = await _get('getStreams', auth, uri);
    if (res == null) return {};
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
    final uri = Uri.parse('$_base/users?login=$login');
    final res = await _get('getUserProfile', auth, uri);
    if (res == null) return null;
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

  /// Follow date (ISO 8601) of a user in a channel, or null when not
  /// following or on failure. Needs moderator:read:followers.
  Future<String?> getFollowDate(
    TwitchAuth auth, {
    required String broadcasterId,
    required String userId,
  }) async {
    final uri = Uri.parse(
      '$_base/channels/followers?broadcaster_id=$broadcasterId&user_id=$userId',
    );
    final res = await _get('getFollowDate', auth, uri);
    if (res == null) return null;
    try {
      final data = jsonDecode(res.body) as Map;
      final list = data['data'] as List;
      if (list.isEmpty) return null;
      return (list[0] as Map)['followed_at'] as String?;
    } catch (e) {
      _setError('getFollowDate: bad response');
      return null;
    }
  }

  Future<bool> blockUser(TwitchAuth auth, String targetUserId) async {
    final uri = Uri.parse('$_base/users/blocks?target_user_id=$targetUserId');
    return _putOk('blockUser', auth, uri, ok: const {204});
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
    final uri = Uri.parse('$_base/chat/messages');
    final body = <String, dynamic>{
      'broadcaster_id': broadcasterId,
      'sender_id': senderId,
      'message': message,
    };
    if (replyParentMessageId != null) {
      body['reply_parent_message_id'] = replyParentMessageId;
    }
    final res = await _post(
      'sendChatMessage',
      auth,
      uri,
      body: jsonEncode(body),
    );
    if (res == null) return null;
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
    final uri = Uri.parse(
      '$_base/chat/color?user_id=$userId&color=${Uri.encodeComponent(color)}',
    );
    return _putOk('updateUserChatColor', auth, uri, ok: const {204});
  }

  Future<bool> banUser(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String userId,
    int? duration,
    String? reason,
  }) async {
    final uri = Uri.parse(
      '$_base/moderation/bans?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final data = <String, dynamic>{'user_id': userId};
    if (duration != null) data['duration'] = duration;
    if (reason != null && reason.isNotEmpty) data['reason'] = reason;
    final body = jsonEncode({'data': data});
    return _postOk('banUser', auth, uri, body: body);
  }

  Future<bool> unbanUser(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String userId,
  }) async {
    final uri = Uri.parse(
      '$_base/moderation/bans?broadcaster_id=$broadcasterId&moderator_id=$moderatorId&user_id=$userId',
    );
    return _deleteOk('unbanUser', auth, uri, ok: const {204});
  }

  /// Broadcaster-only banned/timeout list (broadcaster_id must match the
  /// token). Paginated; empty on failure.
  Future<List<BannedUser>> getBannedUsers(
    TwitchAuth auth,
    String broadcasterId,
  ) async {
    _clearError();
    final out = <BannedUser>[];
    String? cursor;
    while (true) {
      final query = <String, String>{
        'broadcaster_id': broadcasterId,
        'first': '100',
      };
      if (cursor != null) query['after'] = cursor;
      final uri = Uri.parse(
        '$_base/moderation/banned',
      ).replace(queryParameters: query);
      final res = await _client.get(uri, headers: _headers(auth));
      if (res.statusCode != 200) {
        _setError('getBannedUsers', res);
        return out;
      }
      try {
        final data = jsonDecode(res.body) as Map;
        for (final item in data['data'] as List) {
          out.add(BannedUser.fromJson(item as Map<String, dynamic>));
        }
        cursor = ((data['pagination'] as Map?)?['cursor']) as String?;
      } catch (e) {
        _setError('getBannedUsers: bad response');
        return out;
      }
      if (cursor == null || cursor.isEmpty) return out;
    }
  }

  /// Unban requests for a channel, newest first. Empty on failure. [status]
  /// is pending/approved/denied/etc; null leaves the server default.
  Future<List<UnbanRequest>> getUnbanRequests(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    String? status,
  }) async {
    final query = <String, String>{
      'broadcaster_id': broadcasterId,
      'moderator_id': moderatorId,
    };
    if (status != null && status.isNotEmpty) query['status'] = status;
    final uri = Uri.parse(
      '$_base/moderation/unban_requests',
    ).replace(queryParameters: query);
    final res = await _get('getUnbanRequests', auth, uri);
    if (res == null) return const [];
    try {
      final data = jsonDecode(res.body) as Map;
      return [
        for (final item in data['data'] as List)
          UnbanRequest.fromJson(item as Map<String, dynamic>),
      ];
    } catch (e) {
      _setError('getUnbanRequests: bad response');
      return const [];
    }
  }

  /// Approves or denies one unban request. Resolution text is optional
  /// (500 chars max). True on 200.
  Future<bool> resolveUnbanRequest(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String requestId,
    required bool approved,
    String? resolutionText,
  }) async {
    final query = <String, String>{
      'broadcaster_id': broadcasterId,
      'moderator_id': moderatorId,
      'unban_request_id': requestId,
      'status': approved ? 'approved' : 'denied',
    };
    if (resolutionText != null && resolutionText.isNotEmpty) {
      query['resolution_text'] = resolutionText;
    }
    final uri = Uri.parse(
      '$_base/moderation/unban_requests',
    ).replace(queryParameters: query);
    return _patchOk('resolveUnbanRequest', auth, uri);
  }

  /// Public blocked terms for a channel. Empty on failure. Private terms
  /// are dashboard-only and never appear here.
  Future<List<BlockedTerm>> getBlockedTerms(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
  }) async {
    final uri = Uri.parse(
      '$_base/moderation/blocked_terms?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final res = await _get('getBlockedTerms', auth, uri);
    if (res == null) return const [];
    try {
      final data = jsonDecode(res.body) as Map;
      return [
        for (final item in data['data'] as List)
          BlockedTerm.fromJson(item as Map<String, dynamic>),
      ];
    } catch (e) {
      _setError('getBlockedTerms: bad response');
      return const [];
    }
  }

  /// Adds a public blocked term (2-500 chars, `*` wildcard at an edge).
  /// Returns the created term, or null on failure.
  Future<BlockedTerm?> addBlockedTerm(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String text,
  }) async {
    final uri = Uri.parse(
      '$_base/moderation/blocked_terms?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final res = await _post(
      'addBlockedTerm',
      auth,
      uri,
      body: jsonEncode({'text': text}),
    );
    if (res == null) return null;
    try {
      final data = jsonDecode(res.body) as Map;
      final list = data['data'] as List;
      if (list.isEmpty) return null;
      return BlockedTerm.fromJson(list[0] as Map<String, dynamic>);
    } catch (e) {
      _setError('addBlockedTerm: bad response');
      return null;
    }
  }

  /// Removes a public blocked term by id. True on 204.
  Future<bool> removeBlockedTerm(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String termId,
  }) async {
    final uri = Uri.parse(
      '$_base/moderation/blocked_terms?broadcaster_id=$broadcasterId&moderator_id=$moderatorId&id=$termId',
    );
    return _deleteOk('removeBlockedTerm', auth, uri, ok: const {204});
  }

  /// Broadcaster AutoMod settings, or null on failure.
  Future<AutoModSettings?> getAutoModSettings(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
  }) async {
    final uri = Uri.parse(
      '$_base/moderation/automod/settings?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final res = await _get('getAutoModSettings', auth, uri);
    if (res == null) return null;
    try {
      final data = jsonDecode(res.body) as Map;
      final list = data['data'] as List;
      if (list.isEmpty) return null;
      return AutoModSettings.fromJson(list[0] as Map<String, dynamic>);
    } catch (e) {
      _setError('getAutoModSettings: bad response');
      return null;
    }
  }

  /// Updates AutoMod settings. Either `{'overall_level': n}` (preset, resets
  /// every category to the preset defaults) or individual category levels
  /// 0-4, never both. Returns the applied settings, or null on failure.
  Future<AutoModSettings?> updateAutoModSettings(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required Map<String, int> levels,
  }) async {
    final uri = Uri.parse(
      '$_base/moderation/automod/settings?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final res = await _put(
      'updateAutoModSettings',
      auth,
      uri,
      body: jsonEncode(levels),
    );
    if (res == null) return null;
    try {
      final data = jsonDecode(res.body) as Map;
      final list = data['data'] as List;
      if (list.isEmpty) return null;
      return AutoModSettings.fromJson(list[0] as Map<String, dynamic>);
    } catch (e) {
      _setError('updateAutoModSettings: bad response');
      return null;
    }
  }

  /// Flags a chatter as monitored or restricted. True on 200.
  Future<bool> addSuspiciousStatus(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String userId,
    required bool restricted,
  }) async {
    final uri = Uri.parse(
      '$_base/moderation/suspicious_users?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    return _postOk(
      'addSuspiciousStatus',
      auth,
      uri,
      body: jsonEncode({
        'user_id': userId,
        'status': restricted ? 'RESTRICTED' : 'ACTIVE_MONITORING',
      }),
    );
  }

  /// Clears a chatter's suspicious flag. True on 200/204.
  Future<bool> removeSuspiciousStatus(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String userId,
  }) async {
    final uri = Uri.parse(
      '$_base/moderation/suspicious_users?broadcaster_id=$broadcasterId&moderator_id=$moderatorId&user_id=$userId',
    );
    return _deleteOk('removeSuspiciousStatus', auth, uri, ok: const {200, 204});
  }

  /// Custom rewards for a broadcaster's channel. Rewards created by other
  /// client ids are read-only (updates/redemptions 403). Empty on failure.
  Future<List<PointReward>> getCustomRewards(
    TwitchAuth auth, {
    required String broadcasterId,
  }) async {
    final uri = Uri.parse(
      '$_base/channel_points/custom_rewards?broadcaster_id=$broadcasterId',
    );
    final res = await _get('getCustomRewards', auth, uri);
    if (res == null) return const [];
    try {
      final data = jsonDecode(res.body) as Map;
      return [
        for (final item in data['data'] as List)
          PointReward.fromJson(item as Map<String, dynamic>),
      ];
    } catch (e) {
      _setError('getCustomRewards: bad response');
      return const [];
    }
  }

  /// Pauses or resumes a custom reward. Only works for rewards this app's
  /// client id created. True on 200.
  Future<bool> setRewardPaused(
    TwitchAuth auth, {
    required String broadcasterId,
    required String rewardId,
    required bool paused,
  }) async {
    final uri = Uri.parse(
      '$_base/channel_points/custom_rewards?broadcaster_id=$broadcasterId&id=$rewardId',
    );
    return _patchOk(
      'setRewardPaused',
      auth,
      uri,
      body: jsonEncode({'is_paused': paused}),
    );
  }

  /// UNFULFILLED redemptions for one reward, oldest first. Rewards created
  /// by other client ids 403 here. Empty on failure.
  Future<List<PointRedemption>> getRedemptions(
    TwitchAuth auth, {
    required String broadcasterId,
    required String rewardId,
  }) async {
    final uri = Uri.parse(
      '$_base/channel_points/custom_rewards/redemptions'
      '?broadcaster_id=$broadcasterId&reward_id=$rewardId&status=UNFULFILLED',
    );
    final res = await _get('getRedemptions', auth, uri);
    if (res == null) return const [];
    try {
      final data = jsonDecode(res.body) as Map;
      return [
        for (final item in data['data'] as List)
          PointRedemption.fromJson(item as Map<String, dynamic>),
      ];
    } catch (e) {
      _setError('getRedemptions: bad response');
      return const [];
    }
  }

  /// Fulfills or refunds (cancels) one redemption. Only works for rewards
  /// this app's client id created. True on 200.
  Future<bool> updateRedemptionStatus(
    TwitchAuth auth, {
    required String broadcasterId,
    required String rewardId,
    required String redemptionId,
    required bool fulfilled,
  }) async {
    final uri = Uri.parse(
      '$_base/channel_points/custom_rewards/redemptions'
      '?broadcaster_id=$broadcasterId&reward_id=$rewardId&id=$redemptionId',
    );
    return _patchOk(
      'updateRedemptionStatus',
      auth,
      uri,
      body: jsonEncode({'status': fulfilled ? 'FULFILLED' : 'CANCELED'}),
    );
  }

  /// Warns a user. Arrives as an EventSub/IRC moderation event.
  Future<bool> warnUser(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String userId,
    String? reason,
  }) async {
    final uri = Uri.parse(
      '$_base/moderation/warnings?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final data = <String, String>{'user_id': userId};
    if (reason != null && reason.isNotEmpty) data['reason'] = reason;
    final body = jsonEncode({'data': data});
    return _postOk('warnUser', auth, uri, body: body);
  }

  /// Allows or denies an AutoMod-held message. [moderatorId] is the acting
  /// moderator (must match the token user); the held message is addressed
  /// by [messageId] alone. 204 on success.
  Future<bool> manageHeldAutoModMessages(
    TwitchAuth auth, {
    required String moderatorId,
    required String messageId,
    required bool allow,
  }) async {
    final uri = Uri.parse('$_base/moderation/automod/message');
    final body = jsonEncode({
      'user_id': moderatorId,
      'msg_id': messageId,
      'action': allow ? 'ALLOW' : 'DENY',
    });
    return _postOk(
      'manageHeldAutoModMessages',
      auth,
      uri,
      body: body,
      ok: const {204},
    );
  }

  Future<bool> deleteChatMessage(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    String? messageId,
  }) async {
    var url =
        '$_base/moderation/chat?broadcaster_id=$broadcasterId&moderator_id=$moderatorId';
    if (messageId != null) url += '&message_id=$messageId';
    final uri = Uri.parse(url);
    return _deleteOk('deleteChatMessage', auth, uri, ok: const {204});
  }

  /// Pins [messageId] until the stream ends; replaces any current mod pin.
  Future<bool> pinChatMessage(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String messageId,
  }) {
    final uri = Uri.parse(
      '$_base/chat/pins?broadcaster_id=$broadcasterId&moderator_id=$moderatorId&message_id=$messageId',
    );
    return _putOk('pinChatMessage', auth, uri, ok: const {204});
  }

  /// Unpins [messageId], the pinned chat message's own id.
  Future<bool> unpinChatMessage(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String messageId,
  }) {
    final uri = Uri.parse(
      '$_base/chat/pins?broadcaster_id=$broadcasterId&moderator_id=$moderatorId&message_id=$messageId',
    );
    return _deleteOk('unpinChatMessage', auth, uri, ok: const {204});
  }

  Future<bool> sendChatAnnouncement(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String message,
    String color = 'primary',
  }) async {
    final uri = Uri.parse(
      '$_base/chat/announcements?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final body = jsonEncode({'message': message, 'color': color});
    return _postOk(
      'sendChatAnnouncement',
      auth,
      uri,
      body: body,
      ok: const {204},
    );
  }

  /// Query-only call with an empty body; 204 on success.
  Future<bool> sendShoutout(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required String targetUserId,
  }) async {
    final uri = Uri.parse(
      '$_base/chat/shoutouts?from_broadcaster_id=$broadcasterId&to_broadcaster_id=$targetUserId&moderator_id=$moderatorId',
    );
    return _postOk('sendShoutout', auth, uri, ok: const {204});
  }

  Future<bool> unblockUser(TwitchAuth auth, String targetUserId) async {
    final uri = Uri.parse('$_base/users/blocks?target_user_id=$targetUserId');
    return _deleteOk('unblockUser', auth, uri, ok: const {204});
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
    final uri = Uri.parse(
      '$_base/moderation/moderators?broadcaster_id=$broadcasterId&user_id=$userId',
    );
    return _postOk('addModerator', auth, uri, ok: const {204});
  }

  Future<bool> removeModerator(
    TwitchAuth auth, {
    required String broadcasterId,
    required String userId,
  }) async {
    final uri = Uri.parse(
      '$_base/moderation/moderators?broadcaster_id=$broadcasterId&user_id=$userId',
    );
    return _deleteOk('removeModerator', auth, uri, ok: const {204});
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
    final uri = Uri.parse(
      '$_base/channels/vips?broadcaster_id=$broadcasterId&user_id=$userId',
    );
    return _postOk('addVip', auth, uri, ok: const {204});
  }

  Future<bool> removeVip(
    TwitchAuth auth, {
    required String broadcasterId,
    required String userId,
  }) async {
    final uri = Uri.parse(
      '$_base/channels/vips?broadcaster_id=$broadcasterId&user_id=$userId',
    );
    return _deleteOk('removeVip', auth, uri, ok: const {204});
  }

  /// PATCHes chat settings (slow, follower, emote, subscriber, unique mode).
  Future<bool> updateChatSettings(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required Map<String, dynamic> body,
  }) async {
    final uri = Uri.parse(
      '$_base/chat/settings?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    return _patchOk('updateChatSettings', auth, uri, body: jsonEncode(body));
  }

  Future<bool> startCommercial(
    TwitchAuth auth, {
    required String broadcasterId,
    required int length,
  }) async {
    final uri = Uri.parse('$_base/channels/commercial');
    final body = jsonEncode({
      'broadcaster_id': broadcasterId,
      'length': length,
    });
    return _postOk('startCommercial', auth, uri, body: body);
  }

  Future<bool> startRaid(
    TwitchAuth auth, {
    required String fromBroadcasterId,
    required String toBroadcasterId,
  }) async {
    final uri = Uri.parse(
      '$_base/raids?from_broadcaster_id=$fromBroadcasterId&to_broadcaster_id=$toBroadcasterId',
    );
    return _postOk('startRaid', auth, uri);
  }

  Future<bool> cancelRaid(
    TwitchAuth auth, {
    required String broadcasterId,
  }) async {
    final uri = Uri.parse('$_base/raids?broadcaster_id=$broadcasterId');
    return _deleteOk('cancelRaid', auth, uri, ok: const {204});
  }

  Future<bool> updateShieldMode(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
    required bool active,
  }) async {
    final uri = Uri.parse(
      '$_base/moderation/shield_mode?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final body = jsonEncode({'is_active': active});
    return _putOk('updateShieldMode', auth, uri, body: body);
  }

  /// Shield Mode flag; null on failure (check [lastErrorStatus]).
  Future<bool?> getShieldModeStatus(
    TwitchAuth auth, {
    required String broadcasterId,
    required String moderatorId,
  }) async {
    final uri = Uri.parse(
      '$_base/moderation/shield_mode?broadcaster_id=$broadcasterId&moderator_id=$moderatorId',
    );
    final res = await _get('getShieldModeStatus', auth, uri);
    if (res == null) return null;
    try {
      final data = jsonDecode(res.body) as Map;
      final list = data['data'] as List;
      if (list.isEmpty) return null;
      return (list[0] as Map)['is_active'] as bool?;
    } catch (e) {
      _setError('getShieldModeStatus: bad response');
      return null;
    }
  }

  Future<bool> createMarker(
    TwitchAuth auth, {
    required String broadcasterId,
    String? description,
  }) async {
    final uri = Uri.parse('$_base/streams/markers');
    final body = <String, dynamic>{'user_id': broadcasterId};
    if (description != null && description.isNotEmpty) {
      body['description'] = description;
    }
    return _postOk('createMarker', auth, uri, body: jsonEncode(body));
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
    final uri = Uri.parse('$_base/polls');
    final body = jsonEncode({
      'broadcaster_id': broadcasterId,
      'title': title,
      'choices': [
        for (final c in choices) {'title': c},
      ],
      'duration': durationSeconds,
    });
    return _postOk('createPoll', auth, uri, body: body);
  }

  /// Ends a poll. TERMINATED shows results; ARCHIVED does not.
  Future<bool> endPoll(
    TwitchAuth auth, {
    required String broadcasterId,
    required String pollId,
    required bool archive,
  }) async {
    final uri = Uri.parse('$_base/polls');
    return _patchOk(
      'endPoll',
      auth,
      uri,
      body: jsonEncode({
        'broadcaster_id': broadcasterId,
        'id': pollId,
        'status': archive ? 'ARCHIVED' : 'TERMINATED',
      }),
    );
  }

  /// Channel polls, newest first. Empty on failure.
  Future<List<Poll>> getPolls(TwitchAuth auth, String broadcasterId) async {
    final uri = Uri.parse('$_base/polls?broadcaster_id=$broadcasterId');
    final res = await _get('getPolls', auth, uri);
    if (res == null) return const [];
    try {
      final data = jsonDecode(res.body)['data'] as List<dynamic>;
      return [
        for (final p in data.cast<Map<String, dynamic>>()) Poll.fromJson(p),
      ];
    } catch (_) {
      _setError('getPolls: bad response');
      return const [];
    }
  }

  /// Creates a prediction (2-10 outcomes; window 30-1800 seconds).
  Future<bool> createPrediction(
    TwitchAuth auth, {
    required String broadcasterId,
    required String title,
    required List<String> outcomes,
    required int windowSeconds,
  }) async {
    final uri = Uri.parse('$_base/predictions');
    final body = jsonEncode({
      'broadcaster_id': broadcasterId,
      'title': title,
      'outcomes': [
        for (final o in outcomes) {'title': o},
      ],
      'prediction_window': windowSeconds,
    });
    return _postOk('createPrediction', auth, uri, body: body);
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
    final uri = Uri.parse('$_base/predictions');
    final body = <String, dynamic>{
      'broadcaster_id': broadcasterId,
      'id': predictionId,
      'status': status,
      'winning_outcome_id': ?winningOutcomeId,
    };
    return _patchOk('endPrediction', auth, uri, body: jsonEncode(body));
  }

  /// Channel predictions, newest first.
  Future<List<Prediction>> getPredictions(
    TwitchAuth auth,
    String broadcasterId,
  ) async {
    final uri = Uri.parse('$_base/predictions?broadcaster_id=$broadcasterId');
    final res = await _get('getPredictions', auth, uri);
    if (res == null) return const [];
    try {
      final data = jsonDecode(res.body)['data'] as List<dynamic>;
      return [
        for (final p in data.cast<Map<String, dynamic>>())
          Prediction.fromJson(p),
      ];
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
    final uri = Uri.parse(
      '$_base/whispers?from_user_id=$fromUserId&to_user_id=$toUserId',
    );
    final body = jsonEncode({'message': message});
    return _postOk('sendWhisper', auth, uri, body: body, ok: const {204});
  }

  Map<String, String> _headers(TwitchAuth auth) => {
    'Client-ID': TwitchConfig.clientId,
    'Authorization': 'Bearer ${auth.accessToken ?? ''}',
    'Content-Type': 'application/json',
  };

  /// Validates the token. Returns login/userId/expiresIn/scopes on success.
  /// Null on failure; check [lastErrorStatus] -- only 401 is definitive.
  Future<({String login, String userId, int expiresIn, List<String> scopes})?>
  validateToken(TwitchAuth auth) async {
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
      final rawScopes = data['scopes'];
      return (
        login: data['login'] as String? ?? '',
        userId: data['user_id'] as String? ?? '',
        expiresIn: data['expires_in'] as int? ?? 0,
        scopes: rawScopes is List
            ? rawScopes.whereType<String>().toList()
            : const <String>[],
      );
    } catch (e) {
      _recordError('validateToken: $e');
      return null;
    }
  }

  void _setError(String label, [http.Response? res]) {
    _recordError(
      res != null ? '$label failed (${res.statusCode}): ${res.body}' : label,
      status: res?.statusCode,
      helixMessage: _parseHelixMessage(res),
    );
  }

  void _recordError(String error, {int? status, String? helixMessage}) {
    for (final slot in [_global, ?_scoped]) {
      slot
        ..error = error
        ..status = status
        ..helixMessage = helixMessage;
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
