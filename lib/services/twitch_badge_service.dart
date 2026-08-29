import 'dart:convert';
import 'package:http/http.dart' as http;
import '../twitch_config.dart';
import '../models/twitch_badge.dart';
import '../util/constants.dart';
import '../util/log.dart';
import 'twitch_auth.dart';

class TwitchBadgeService {
  TwitchBadgeService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  final _globalBadges = <String, BadgeSet>{};
  final _channelBadges = <String, Map<String, BadgeSet>>{};
  final _channelAvatars = <String, String>{};
  // broadcasterId -> login / display name (shared-chat source channels).
  final _channelLogins = <String, String>{};
  final _channelDisplayNames = <String, String>{};

  int _version = 0;

  /// Bumps on avatar/login/displayName changes for cache invalidation.
  int get version => _version;

  bool _globalFetched = false;
  // In-flight dedup: concurrent fetches for the same resource are coalesced.
  Future<void>? _inflightGlobal;
  final _inflightChannelBadges = <String, Future<void>>{};
  final _inflightAvatars = <String, Future<void>>{};

  Future<void> fetchGlobalBadges(TwitchAuth auth) async {
    if (_globalFetched) return;
    _inflightGlobal ??= () async {
      final sets = await _fetchBadgeSets(
        Uri.parse('https://api.twitch.tv/helix/chat/badges/global'),
        auth,
      );
      if (sets.isEmpty) {
        // Don't latch failures; retry on next call.
        return;
      }
      _globalBadges.addAll(sets);
      _globalFetched = true;
    }();
    try {
      await _inflightGlobal!;
    } finally {
      _inflightGlobal = null;
    }
  }

  Future<void> fetchChannelBadges(
    TwitchAuth auth,
    String broadcasterId,
    String channel,
  ) async {
    final existing = _inflightChannelBadges[channel];
    if (existing != null) return existing;
    final future = _doFetchChannelBadges(auth, broadcasterId, channel);
    _inflightChannelBadges[channel] = future;
    try {
      await future;
    } finally {
      _inflightChannelBadges.remove(channel);
    }
  }

  Future<void> _doFetchChannelBadges(
    TwitchAuth auth,
    String broadcasterId,
    String channel,
  ) async {
    final sets = await _fetchBadgeSets(
      Uri.parse(
        'https://api.twitch.tv/helix/chat/badges?broadcaster_id=$broadcasterId',
      ),
      auth,
    );
    if (sets.isNotEmpty) {
      _channelBadges[channel] = sets;
    }
  }

  String? resolveBadgeUrl(String channel, String setId, String versionId) {
    // Check channel badges first (override global for same setId)
    final channelSets = _channelBadges[channel];
    if (channelSets != null) {
      final set = channelSets[setId];
      if (set != null) {
        final version = set.versions[versionId];
        if (version != null) return version.imageUrl;
      }
    }
    // Fall back to global
    final globalSet = _globalBadges[setId];
    if (globalSet != null) {
      final version = globalSet.versions[versionId];
      if (version != null) return version.imageUrl;
    }
    return null;
  }

  void clearChannel(String channel) {
    _channelBadges.remove(channel);
  }

  String? resolveChannelAvatar(String broadcasterId) {
    return _channelAvatars[broadcasterId];
  }

  /// Resolved IRC login for [broadcasterId]; keys shared-chat source channels.
  String? resolveChannelLogin(String broadcasterId) {
    return _channelLogins[broadcasterId];
  }

  /// Display name for [broadcasterId].
  String? resolveChannelDisplayName(String broadcasterId) {
    return _channelDisplayNames[broadcasterId];
  }

  Future<void> fetchChannelAvatar(TwitchAuth auth, String broadcasterId) async {
    if (_channelAvatars.containsKey(broadcasterId)) return;
    final existing = _inflightAvatars[broadcasterId];
    if (existing != null) return existing;
    final future = _doFetchChannelAvatar(auth, broadcasterId);
    _inflightAvatars[broadcasterId] = future;
    try {
      await future;
    } finally {
      _inflightAvatars.remove(broadcasterId);
    }
  }

  Future<void> _doFetchChannelAvatar(
    TwitchAuth auth,
    String broadcasterId,
  ) async {
    try {
      final uri = Uri.parse(
        'https://api.twitch.tv/helix/users?id=$broadcasterId',
      );
      final headers = <String, String>{
        'Client-ID': TwitchConfig.clientId,
        'Authorization': 'Bearer ${auth.accessToken ?? ''}',
      };
      final res = await _client.get(uri, headers: headers).timeout(httpTimeout);
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = data['data'] as List<dynamic>?;
      if (list == null || list.isEmpty) return;
      final user = list[0] as Map<String, dynamic>;
      final avatarUrl = user['profile_image_url'] as String?;
      final login = user['login'] as String?;
      final displayName = user['display_name'] as String?;
      if (avatarUrl != null) _channelAvatars[broadcasterId] = avatarUrl;
      if (login != null && login.isNotEmpty) {
        _channelLogins[broadcasterId] = login.toLowerCase();
      }
      if (displayName != null && displayName.isNotEmpty) {
        _channelDisplayNames[broadcasterId] = displayName;
      }
      _version++;
    } catch (e) {
      logDebug('Channel avatar fetch error: $e');
    }
  }

  /// Runtime cache reset (account switch), not teardown.
  void resetCaches() {
    _globalBadges.clear();
    _channelBadges.clear();
    _channelAvatars.clear();
    _channelLogins.clear();
    _channelDisplayNames.clear();
    _globalFetched = false;
  }

  Future<Map<String, BadgeSet>> _fetchBadgeSets(
    Uri uri,
    TwitchAuth auth,
  ) async {
    try {
      final headers = <String, String>{
        'Client-ID': TwitchConfig.clientId,
        'Authorization': 'Bearer ${auth.accessToken ?? ''}',
      };
      final res = await _client.get(uri, headers: headers).timeout(httpTimeout);
      if (res.statusCode != 200) {
        logDebug('Badge fetch failed (${res.statusCode}): ${res.body}');
        return {};
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = data['data'] as List<dynamic>? ?? [];
      final sets = <String, BadgeSet>{};
      for (final item in list) {
        final itemMap = item as Map<String, dynamic>;
        final setId = itemMap['set_id'] as String?;
        final versionsList = itemMap['versions'] as List<dynamic>?;
        if (setId == null || versionsList == null) continue;
        final versions = <String, BadgeVersion>{};
        for (final v in versionsList) {
          final vMap = v as Map<String, dynamic>;
          final id = vMap['id'] as String?;
          final imageUrl =
              (vMap['image_url_4x'] ??
                      vMap['image_url_2x'] ??
                      vMap['image_url_1x'])
                  as String?;
          if (id == null || imageUrl == null) continue;
          versions[id] = BadgeVersion(imageUrl: imageUrl);
        }
        if (versions.isNotEmpty) {
          sets[setId] = BadgeSet(versions: versions);
        }
      }
      return sets;
    } catch (e) {
      logDebug('Badge fetch error: $e');
      return {};
    }
  }
}
