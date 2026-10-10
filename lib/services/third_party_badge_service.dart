import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../util/constants.dart';
import '../util/log.dart';
import 'seven_tv_event_client.dart';

class ThirdPartyBadgeService {
  ThirdPartyBadgeService({this._client, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final http.Client? _client;
  final DateTime Function() _now;

  // FFZ: badgeId -> {name, imageUrl}
  final _ffzBadges = <String, _FfzBadge>{};
  // FFZ: twitchUserId -> badgeId
  final _ffzUsers = <String, String>{};
  // BTTV: twitchUserId -> badge
  final _bttvUsers = <String, ThirdPartyBadge>{};
  // 7TV: cosmeticId -> badge
  final _sevenTvBadges = <String, ThirdPartyBadge>{};
  // 7TV: twitchUserId -> cosmeticId
  final _sevenTvUsers = <String, String>{};

  // Limerino: badgeId -> badge (catalog), and per-user answers. The API only
  // answers per user, so unknown users queue for a batched lookup.
  final _limerinoBadges = <String, ThirdPartyBadge>{};
  final _limerinoUsers = <String, ({String? badgeId, DateTime at})>{};
  final _limerinoPending = <String>{};
  // Off until the app starts the catalog fetch, so bare renders (tests,
  // previews) never queue network lookups.
  bool _limerinoEnabled = false;
  Timer? _limerinoFlushTimer;
  bool _limerinoInflight = false;
  bool _limerinoCatalogInflight = false;
  DateTime? _limerinoCatalogAt;
  DateTime? _limerinoBlockedUntil;
  DateTime? _limerinoLastLookup;
  Duration _limerinoBackoff = Duration.zero;

  static const _limerinoApi = 'https://api.limerino.com/v1/badges';
  // Limits and cache lifetimes follow limerino.com/developers/badges.
  static const _limerinoBatchDelay = Duration(milliseconds: 250);
  static const _limerinoMaxBatch = 100;
  static const _limerinoLookupGap = Duration(seconds: 2);
  static const _limerinoHitTtl = Duration(minutes: 10);
  static const _limerinoMissTtl = Duration(minutes: 30);
  static const _limerinoCatalogTtl = Duration(minutes: 10);
  static const _limerinoMaxUsers = 10000;
  static const _limerinoMaxBackoff = Duration(minutes: 10);

  // Static-list providers: one catalog each, every badge naming its users.
  // provider -> (twitchUserId -> badge), filled once per launch.
  final _listUsers = <_ListProvider, Map<String, ThirdPartyBadge>>{};
  final _listInflight = <_ListProvider>{};

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
      _sevenTvBadges[event.cosmeticId] = (
        url: event.imageUrl,
        name: event.tooltip ?? event.name,
      );
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
        final imageUrl =
            (urls?['4'] ?? urls?['2'] ?? urls?['1'] ?? b['image']) as String?;
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
          _bttvUsers[providerId] = (
            url: svg,
            name: badge?['description'] as String? ?? '',
          );
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

  /// Loads the Chatterino, DankChat, Chatsen and Chatterino Homies badge
  /// lists.
  Future<void> fetchListBadges() =>
      Future.wait([for (final p in _ListProvider.values) _fetchList(p)]);

  Future<void> _fetchList(_ListProvider provider) async {
    if (_listUsers.containsKey(provider) || !_listInflight.add(provider)) {
      return;
    }
    try {
      final res = await _get(Uri.parse(provider.url));
      if (res.statusCode != 200) return;
      _listUsers[provider] = _parseList(provider, jsonDecode(res.body));
      _version++;
    } catch (e) {
      logDebug('${provider.name} badge fetch error: $e');
    } finally {
      _listInflight.remove(provider);
    }
  }

  static Map<String, ThirdPartyBadge> _parseList(
    _ListProvider provider,
    Object? body,
  ) {
    final entries = switch (provider) {
      _ListProvider.dankchat || _ListProvider.chatsen => body as List<dynamic>,
      _ =>
        (body as Map<String, dynamic>)['badges'] as List<dynamic>? ?? const [],
    };
    final users = <String, ThirdPartyBadge>{};
    for (final raw in entries) {
      if (raw is! Map<String, dynamic>) continue;
      final (url, name) = switch (provider) {
        // Largest art throughout: the 18dp slot is ~54px on a 3x screen.
        _ListProvider.chatterino ||
        _ListProvider.homies ||
        _ListProvider.homiesLegacy ||
        _ListProvider.homiesLegacy2 => (
          (raw['image3'] ?? raw['image2'] ?? raw['image1']) as String?,
          raw['tooltip'] as String?,
        ),
        _ListProvider.dankchat => (
          raw['url'] as String?,
          raw['type'] as String?,
        ),
        _ListProvider.chatsen => (
          switch (raw['mipmap']) {
            final List<dynamic> m when m.isNotEmpty => m.last as String?,
            _ => null,
          },
          raw['name'] as String?,
        ),
      };
      if (url == null || url.isEmpty) continue;
      final badge = (url: url, name: name ?? '');
      // Homies names one user per entry; the rest list them.
      final ids = raw['users'] as List<dynamic>? ?? [?raw['userId']];
      for (final id in ids) {
        if (id.toString().isEmpty) continue;
        users.putIfAbsent(id.toString(), () => badge);
      }
    }
    return users;
  }

  /// Loads the Limerino badge catalog (names and art). Refreshes when older
  /// than its TTL or when a user answer names an unknown badge.
  Future<void> fetchLimerinoBadges({bool force = false}) async {
    _limerinoEnabled = true;
    if (_limerinoCatalogInflight) return;
    final at = _limerinoCatalogAt;
    if (!force && at != null && _now().difference(at) < _limerinoCatalogTtl) {
      return;
    }
    _limerinoCatalogInflight = true;
    try {
      final res = await _get(Uri.parse(_limerinoApi));
      if (res.statusCode != 200) return;
      _limerinoCatalogAt = _now();
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      for (final raw in data['badges'] as List<dynamic>? ?? const []) {
        final badge = _parseLimerinoBadge(raw);
        if (badge != null) _limerinoBadges[badge.$1] = badge.$2;
      }
      _version++;
    } catch (e) {
      logDebug('Limerino badge catalog error: $e');
    } finally {
      _limerinoCatalogInflight = false;
    }
  }

  static (String, ThirdPartyBadge)? _parseLimerinoBadge(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final data = raw['data'] as Map<String, dynamic>? ?? const {};
    final id = (raw['id'] ?? data['id']) as String? ?? '';
    final host = data['host'] as Map<String, dynamic>? ?? const {};
    final hostUrl = host['url'] as String? ?? '';
    if (id.isEmpty || hostUrl.isEmpty) return null;
    final names = [
      for (final f in host['files'] as List<dynamic>? ?? const [])
        if (f is Map<String, dynamic>) f['name'] as String? ?? '',
    ];
    // 4x is sharp on dense screens; every badge ships a 2x.png fallback.
    final file = const [
      '4x.webp',
      '4x.png',
      '2x.webp',
      '2x.png',
    ].where(names.contains).followedBy(names).firstOrNull;
    if (file == null || file.isEmpty) return null;
    final base = hostUrl.startsWith('//') ? 'https:$hostUrl' : hostUrl;
    return (
      id,
      (
        url: '$base/$file',
        name: data['tooltip'] as String? ?? data['name'] as String? ?? '',
      ),
    );
  }

  /// The user's Limerino badge, queueing a batched lookup when the cached
  /// answer is missing or expired.
  ThirdPartyBadge? _limerinoBadgeFor(String userId) {
    if (!_limerinoEnabled) return null;
    final answer = _limerinoUsers[userId];
    if (answer == null ||
        _now().difference(answer.at) >
            (answer.badgeId == null ? _limerinoMissTtl : _limerinoHitTtl)) {
      _queueLimerino(userId);
    }
    final badgeId = answer?.badgeId;
    return badgeId == null ? null : _limerinoBadges[badgeId];
  }

  void _queueLimerino(String userId) {
    if (userId.isEmpty || !_limerinoPending.add(userId)) return;
    _limerinoFlushTimer ??= Timer(_limerinoBatchDelay, () {
      _limerinoFlushTimer = null;
      unawaited(_flushLimerino());
    });
  }

  Future<void> _flushLimerino() async {
    if (_limerinoInflight || _limerinoPending.isEmpty) return;
    // Backoff, or the documented "at most one every 2 seconds" lookup pace.
    final last = _limerinoLastLookup;
    final paced = last?.add(_limerinoLookupGap);
    final backoff = _limerinoBlockedUntil;
    final blocked = paced == null || (backoff != null && backoff.isAfter(paced))
        ? backoff
        : paced;
    if (blocked != null && _now().isBefore(blocked)) {
      _limerinoFlushTimer ??= Timer(blocked.difference(_now()), () {
        _limerinoFlushTimer = null;
        unawaited(_flushLimerino());
      });
      return;
    }
    final batch = _limerinoPending.take(_limerinoMaxBatch).toList();
    _limerinoPending.removeAll(batch);
    _limerinoInflight = true;
    _limerinoLastLookup = _now();
    var retry = false;
    try {
      final res = await _post(
        Uri.parse('$_limerinoApi/users'),
        jsonEncode({'twitch_ids': batch}),
      );
      if (res.statusCode == 429 || res.statusCode >= 500) {
        _limerinoPending.addAll(batch);
        _backOffLimerino(res.headers['retry-after']);
        retry = true;
        return;
      }
      if (res.statusCode != 200) return;
      _limerinoBackoff = Duration.zero;
      final users =
          (jsonDecode(res.body) as Map<String, dynamic>)['users']
              as Map<String, dynamic>? ??
          const {};
      final at = _now();
      var changed = false;
      var unknownBadge = false;
      for (final userId in batch) {
        final ids = users[userId];
        final badgeId = ids is List && ids.isNotEmpty
            ? ids.first.toString()
            : null;
        final before = _limerinoUsers.remove(userId)?.badgeId;
        _limerinoUsers[userId] = (badgeId: badgeId, at: at);
        if (before != badgeId) changed = true;
        if (badgeId != null && !_limerinoBadges.containsKey(badgeId)) {
          unknownBadge = true;
        }
      }
      while (_limerinoUsers.length > _limerinoMaxUsers) {
        _limerinoUsers.remove(_limerinoUsers.keys.first);
      }
      if (unknownBadge) {
        unawaited(fetchLimerinoBadges(force: true));
      } else {
        unawaited(fetchLimerinoBadges());
      }
      if (changed) _version++;
    } catch (e) {
      _limerinoPending.addAll(batch);
      _backOffLimerino(null);
      retry = true;
      logDebug('Limerino badge lookup error: $e');
    } finally {
      _limerinoInflight = false;
      if (!retry && _limerinoPending.isNotEmpty) {
        _limerinoFlushTimer ??= Timer(_limerinoBatchDelay, () {
          _limerinoFlushTimer = null;
          unawaited(_flushLimerino());
        });
      } else if (retry) {
        unawaited(_flushLimerino());
      }
    }
  }

  // Waits retry-after (60s when unreadable), doubling per consecutive
  // failure up to the documented ~10 minute cap.
  void _backOffLimerino(String? retryAfter) {
    final hinted = int.tryParse(retryAfter ?? '');
    final base = Duration(seconds: hinted ?? 60);
    final next = _limerinoBackoff == Duration.zero
        ? base
        : _limerinoBackoff * 2;
    _limerinoBackoff = next > _limerinoMaxBackoff ? _limerinoMaxBackoff : next;
    _limerinoBlockedUntil = _now().add(_limerinoBackoff);
  }

  Future<http.Response> _get(Uri uri) =>
      (_client?.get(uri) ?? http.get(uri)).timeout(httpTimeout);

  Future<http.Response> _post(Uri uri, String body) {
    const headers = {'content-type': 'application/json'};
    return (_client?.post(uri, headers: headers, body: body) ??
            http.post(uri, headers: headers, body: body))
        .timeout(httpTimeout);
  }

  /// The user's one third-party badge: FFZ, BTTV, 7TV, the static-list
  /// providers in [_ListProvider] order, then Limerino. Every call keeps the
  /// Limerino answer fresh, so a user with another badge still gets looked
  /// up once.
  ThirdPartyBadge? resolveBadge(String userId) {
    final limerino = _limerinoBadgeFor(userId);
    final ffz = _ffzBadges[_ffzUsers[userId]];
    if (ffz != null) return (url: ffz.imageUrl, name: ffz.name);
    ThirdPartyBadge? listed;
    for (final p in _ListProvider.values) {
      listed = _listUsers[p]?[userId];
      if (listed != null) break;
    }
    return _bttvUsers[userId] ??
        _sevenTvBadges[_sevenTvUsers[userId]] ??
        listed ??
        limerino;
  }

  void dispose() {
    _limerinoFlushTimer?.cancel();
    _limerinoFlushTimer = null;
    _limerinoPending.clear();
    _limerinoUsers.clear();
    _limerinoBadges.clear();
    _cosmeticSub?.cancel();
    _entitlementSub?.cancel();
    _ffzBadges.clear();
    _ffzUsers.clear();
    _bttvUsers.clear();
    _sevenTvBadges.clear();
    _sevenTvUsers.clear();
    _listUsers.clear();
  }
}

/// Providers that publish one badge list naming every user up front.
enum _ListProvider {
  chatterino('https://api.chatterino.com/badges'),
  dankchat('https://flxrs.com/api/badges'),
  chatsen('https://api.chatsen.app/account/badges'),
  // Chatterino Homies: the live per-user API, then the fork's older lists.
  homies('https://chatterinohomies.com/api/badges/list'),
  homiesLegacy('https://itzalex.github.io/badges'),
  homiesLegacy2('https://itzalex.github.io/badges2');

  const _ListProvider(this.url);
  final String url;
}

/// A third-party badge image and its display name (may be empty).
typedef ThirdPartyBadge = ({String url, String name});

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
