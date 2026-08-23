import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../util/constants.dart';
import '../util/log.dart';
import 'seven_tv_event_client.dart';

class ThirdPartyBadgeService {
  // FFZ: badgeId -> {name, imageUrl}
  final _ffzBadges = <String, _FfzBadge>{};
  // FFZ: twitchUserId -> badgeId
  final _ffzUsers = <String, String>{};
  // BTTV: twitchUserId -> badgeSvgUrl
  final _bttvUsers = <String, String>{};
  // 7TV: cosmeticId -> imageUrl
  final _sevenTvBadges = <String, String>{};
  // 7TV: twitchUserId -> cosmeticId
  final _sevenTvUsers = <String, String>{};

  bool _ffzFetched = false;
  bool _bttvFetched = false;
  int _version = 0;

  bool _ffzInflight = false;
  bool _bttvInflight = false;

  int get version => _version;

  StreamSubscription<void>? _cosmeticSub;
  StreamSubscription<void>? _entitlementSub;

  void bindSevenTvEvents(SevenTvEventClient client) {
    _cosmeticSub?.cancel();
    _entitlementSub?.cancel();
    _cosmeticSub = client.onCosmeticCreate.listen((event) {
      _sevenTvBadges[event.cosmeticId] = event.imageUrl;
      _version++;
    });
    _entitlementSub = client.onEntitlement.listen((event) {
      if (event.cosmeticKind != 'BADGE') return;
      final isCreate = event.kind == 'entitlement.create';
      for (final userId in event.twitchUserIds) {
        if (isCreate) {
          _sevenTvUsers[userId] = event.cosmeticId;
        } else {
          _sevenTvUsers.remove(userId);
        }
      }
      _version++;
    });
  }

  Future<void> fetchFfzBadges() async {
    if (_ffzFetched || _ffzInflight) return;
    _ffzInflight = true;
    try {
      final uri = Uri.parse('https://api.frankerfacez.com/v1/badges/ids');
      final res = await http.get(uri).timeout(httpTimeout);
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;

      final badgesList = data['badges'] as List<dynamic>? ?? [];
      for (final entry in badgesList) {
        final b = entry as Map<String, dynamic>;
        final id = b['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final urls = b['urls'] as Map<String, dynamic>?;
        final imageUrl = (urls?['2'] ?? urls?['1'] ?? b['image']) as String?;
        if (imageUrl == null) continue;
        _ffzBadges[id] = _FfzBadge(
          id: id,
          name: b['title'] as String? ?? b['name'] as String? ?? '',
          imageUrl: imageUrl,
        );
      }

      final usersMap = data['users'] as Map<String, dynamic>? ?? {};
      for (final entry in usersMap.entries) {
        final badgeId = entry.key;
        final userIds = entry.value as List<dynamic>? ?? [];
        for (final uid in userIds) {
          _ffzUsers[uid.toString()] = badgeId;
        }
      }
      _ffzFetched = true;
      _version++;
    } catch (e) {
      logDebug('FFZ badge fetch error: $e');
    } finally {
      _ffzInflight = false;
    }
  }

  Future<void> fetchBttvBadges() async {
    if (_bttvFetched || _bttvInflight) return;
    _bttvInflight = true;
    try {
      final uri = Uri.parse('https://api.betterttv.net/3/cached/badges/twitch');
      final res = await http.get(uri).timeout(httpTimeout);
      if (res.statusCode != 200) return;
      final list = jsonDecode(res.body) as List<dynamic>? ?? [];
      for (final entry in list) {
        final item = entry as Map<String, dynamic>;
        final providerId = item['providerId'] as String? ?? '';
        final badge = item['badge'] as Map<String, dynamic>?;
        final svg = badge?['svg'] as String? ?? '';
        if (providerId.isNotEmpty && svg.isNotEmpty) {
          _bttvUsers[providerId] = svg;
        }
      }
      _bttvFetched = true;
      _version++;
    } catch (e) {
      logDebug('BTTV badge fetch error: $e');
    } finally {
      _bttvInflight = false;
    }
  }

  String? resolveFfzBadgeUrl(String userId) {
    final badgeId = _ffzUsers[userId];
    if (badgeId == null) return null;
    return _ffzBadges[badgeId]?.imageUrl;
  }

  String? resolveBttvBadgeUrl(String userId) => _bttvUsers[userId];

  String? resolveSevenTvBadgeUrl(String userId) {
    final cosmeticId = _sevenTvUsers[userId];
    if (cosmeticId == null) return null;
    return _sevenTvBadges[cosmeticId];
  }

  void dispose() {
    _cosmeticSub?.cancel();
    _entitlementSub?.cancel();
    _ffzBadges.clear();
    _ffzUsers.clear();
    _bttvUsers.clear();
    _sevenTvBadges.clear();
    _sevenTvUsers.clear();
  }
}

class _FfzBadge {
  final String id;
  final String name;
  final String imageUrl;

  const _FfzBadge({
    required this.id,
    required this.name,
    required this.imageUrl,
  });
}
