import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../twitch_config.dart';
import '../models/twitch_badge.dart';
import 'twitch_auth.dart';

class TwitchBadgeService {
  final _globalBadges = <String, BadgeSet>{};
  final _channelBadges = <String, Map<String, BadgeSet>>{};
  final _channelAvatars = <String, String>{};

  bool _globalFetched = false;

  Future<void> fetchGlobalBadges(TwitchAuth auth) async {
    if (_globalFetched) return;
    _globalBadges.addAll(
      await _fetchBadgeSets(
        Uri.parse('https://api.twitch.tv/helix/chat/badges/global'),
        auth,
      ),
    );
    _globalFetched = true;
  }

  Future<void> fetchChannelBadges(
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

  Future<void> fetchChannelAvatar(TwitchAuth auth, String broadcasterId) async {
    if (_channelAvatars.containsKey(broadcasterId)) return;
    try {
      final uri = Uri.parse(
        'https://api.twitch.tv/helix/users?id=$broadcasterId',
      );
      final headers = <String, String>{
        'Client-ID': TwitchConfig.clientId,
        'Authorization': 'Bearer ${auth.accessToken ?? ''}',
      };
      final res = await http.get(uri, headers: headers);
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = data['data'] as List<dynamic>?;
      if (list == null || list.isEmpty) return;
      final user = list[0] as Map<String, dynamic>;
      final avatarUrl = user['profile_image_url'] as String?;
      if (avatarUrl != null) _channelAvatars[broadcasterId] = avatarUrl;
    } catch (e) {
      debugPrint('Channel avatar fetch error: $e');
    }
  }

  void dispose() {
    _globalBadges.clear();
    _channelBadges.clear();
    _channelAvatars.clear();
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
      final res = await http.get(uri, headers: headers);
      if (res.statusCode != 200) {
        debugPrint('Badge fetch failed (${res.statusCode}): ${res.body}');
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
      debugPrint('Badge fetch error: $e');
      return {};
    }
  }
}
