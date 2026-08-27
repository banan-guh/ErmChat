import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'
    show Color, Matrix4, Offset, Shader, Size;
import 'package:http/http.dart' as http;
import '../util/log.dart';
import 'seven_tv_event_client.dart';

class SevenTvPaintStop {
  final double at;
  final Color color;

  const SevenTvPaintStop({required this.at, required this.color});
}

class SevenTvPaintShadow {
  final Color color;
  final double offsetX;
  final double offsetY;
  final double blur;

  const SevenTvPaintShadow({
    required this.color,
    required this.offsetX,
    required this.offsetY,
    required this.blur,
  });
}

sealed class SevenTvPaintLayer {
  /// Per-layer alpha multiplier from the API (usually 1).
  final double opacity;

  const SevenTvPaintLayer({required this.opacity});
}

class SevenTvLinearGradientLayer extends SevenTvPaintLayer {
  final List<SevenTvPaintStop> stops;

  /// CSS-style angle in degrees: 0 points up, increasing clockwise.
  final int angleDegrees;
  final bool repeating;

  const SevenTvLinearGradientLayer({
    required this.stops,
    required this.angleDegrees,
    required this.repeating,
    required super.opacity,
  });
}

class SevenTvRadialGradientLayer extends SevenTvPaintLayer {
  final List<SevenTvPaintStop> stops;
  final bool repeating;
  final bool isCircle;

  const SevenTvRadialGradientLayer({
    required this.stops,
    required this.repeating,
    required this.isCircle,
    required super.opacity,
  });
}

class SevenTvSolidColorLayer extends SevenTvPaintLayer {
  final Color color;

  const SevenTvSolidColorLayer({required this.color, required super.opacity});
}

class SevenTvPaintImage {
  final String url;
  final int width;
  final int height;
  final int scale;

  const SevenTvPaintImage({
    required this.url,
    required this.width,
    required this.height,
    required this.scale,
  });
}

class SevenTvImagePaintLayer extends SevenTvPaintLayer {
  final List<SevenTvPaintImage> images;

  const SevenTvImagePaintLayer({required this.images, required super.opacity});

  /// Picks the smallest texture tall enough to stay crisp at ~3x device
  /// pixel ratio on a chat line, falling back to the largest available so
  /// tiny variants never upscale-blur.
  SevenTvPaintImage? pickVariant() {
    if (images.isEmpty) return null;
    SevenTvPaintImage? best;
    SevenTvPaintImage? largest;
    for (final img in images) {
      if (largest == null || img.height > largest.height) largest = img;
      if (img.height >= 56 && (best == null || img.height < best.height)) {
        best = img;
      }
    }
    return best ?? largest;
  }
}

/// A parsed 7TV name paint. Layers/shadows come from the v4 GraphQL catalog;
/// unsupported layer kinds are dropped at parse time, so [layers] may be
/// empty for paints that cannot be rendered natively.
class SevenTvPaint {
  final String id;
  final String name;
  final List<SevenTvPaintLayer> layers;
  final List<SevenTvPaintShadow> shadows;

  const SevenTvPaint({
    required this.id,
    required this.name,
    required this.layers,
    required this.shadows,
  });

  /// True when the paint can be drawn as a solid text color directly (single
  /// solid layer), skipping the ShaderMask entirely.
  Color? get solidColor {
    final layer = layers.singleOrNull;
    if (layer is! SevenTvSolidColorLayer) return null;
    return layer.color.withValues(alpha: layer.color.a * layer.opacity);
  }

  /// First stop color, used as the fallback tint while an image texture loads.
  Color? get fallbackColor {
    for (final layer in layers) {
      final List<SevenTvPaintStop> stops;
      if (layer is SevenTvLinearGradientLayer) {
        stops = layer.stops;
      } else if (layer is SevenTvRadialGradientLayer) {
        stops = layer.stops;
      } else {
        continue;
      }
      if (stops.isEmpty) continue;
      var best = stops.first;
      for (final stop in stops.skip(1)) {
        if (stop.at < best.at) best = stop;
      }
      return best.color.withValues(alpha: layer.opacity);
    }
    return null;
  }
}

/// Resolves 7TV name paints for chatters: downloads the paint catalog once
/// per session, maps Twitch user IDs to equipped paints via batched GraphQL
/// lookups plus live entitlement events, and exposes synchronous lookups for
/// message rendering. Disabled by default; the settings toggle flips it on.
class SevenTvPaintService extends ChangeNotifier {
  static const _gqlUrl = 'https://7tv.io/v4/gql';
  static const _userTtl = Duration(hours: 6);
  static const _negativeTtl = Duration(minutes: 30);
  static const _failureBackoff = Duration(minutes: 5);
  static const _batchDelay = Duration(milliseconds: 250);
  static const _maxBatchSize = 25;

  static const _paintFields =
      'id name '
      // Shadows are a sibling of layers inside data.
      'data { layers { opacity ty { __typename '
      '... on PaintLayerTypeSingleColor { color { hex } } '
      '... on PaintLayerTypeLinearGradient { angle repeating stops { at color { hex } } } '
      '... on PaintLayerTypeRadialGradient { shape repeating stops { at color { hex } } } '
      '... on PaintLayerTypeImage { images { url scale width height } } '
      '} } shadows { blur offsetX offsetY color { hex } } }';

  final Future<Map<String, dynamic>?> Function(String query) _gqlQuery;
  final Future<Uint8List> Function(Uri uri) _fetchBytes;
  final DateTime Function() _now;

  bool _enabled = false;
  bool get enabled => _enabled;

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (value) {
      unawaited(
        ensureCatalog().then((_) {
          if (_pendingUsers.isNotEmpty) _scheduleFlush();
        }),
      );
    }
    notifyListeners();
    _refreshAllUserNotifiers();
  }

  /// Per-user notifiers so [PaintedUsernameText] subscribes narrowly instead of
  /// to the whole service (which fires on every catalog/image/entitlement
  /// change). Keyed by Twitch user id; created on first lookup and dropped when
  /// it loses its only listener.
  ValueNotifier<SevenTvPaint?> lookupNotifier(String? userId) {
    if (userId == null || userId.isEmpty) {
      return ValueNotifier<SevenTvPaint?>(null);
    }
    final existing = _userNotifiers[userId];
    if (existing != null) {
      lookup(userId);
      return existing;
    }
    final notifier = ValueNotifier<SevenTvPaint?>(lookup(userId));
    _userNotifiers[userId] = notifier;
    return notifier;
  }

  void _refreshUserNotifier(String userId) {
    final notifier = _userNotifiers[userId];
    if (notifier == null) return;
    if (!notifier.hasListeners) {
      _userNotifiers.remove(userId);
      return;
    }
    SevenTvPaint? paint;
    final assignment = _assignments[userId];
    if (assignment != null) paint = _paintsById[assignment.paintId];
    notifier.value = paint;
  }

  void _refreshAllUserNotifiers() {
    for (final userId in List.of(_userNotifiers.keys)) {
      _refreshUserNotifier(userId);
    }
  }

  final _paintsById = <String, SevenTvPaint>{};
  Future<void>? _catalogFuture;

  // twitchUserId -> assigned paint id + when it was confirmed.
  final _assignments = <String, ({String paintId, DateTime at})>{};
  final _negative = <String, DateTime>{};
  final _backoffUntil = <String, DateTime>{};
  final _pendingUsers = <String>{};
  Timer? _flushTimer;
  bool _resolvingBatch = false;

  final _userNotifiers = <String, ValueNotifier<SevenTvPaint?>>{};

  final _images = <String, ui.Image?>{};
  final _imageInflight = <String>{};

  StreamSubscription<SevenTvEntitlementEvent>? _entitlementSub;

  SevenTvPaintService({
    Future<Map<String, dynamic>?> Function(String query)? gqlQuery,
    Future<Uint8List> Function(Uri uri)? fetchBytes,
    DateTime Function()? now,
  }) : _gqlQuery = gqlQuery ?? _defaultGqlQuery,
       _fetchBytes = fetchBytes ?? _defaultFetchBytes,
       _now = now ?? DateTime.now;

  static Future<Map<String, dynamic>?> _defaultGqlQuery(String query) async {
    try {
      final res = await http
          .post(
            Uri.parse(_gqlUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'query': query}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['data'] as Map<String, dynamic>?;
    } catch (e) {
      logDebug('7TV paints gql error: $e');
      return null;
    }
  }

  static Future<Uint8List> _defaultFetchBytes(Uri uri) =>
      http.get(uri).then((res) {
        if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
        return res.bodyBytes;
      });

  /// Subscribes to live entitlement changes so equipping/removing a paint in
  /// a joined channel updates without waiting for the lookup TTL.
  void bindSevenTvEvents(SevenTvEventClient client) {
    _entitlementSub?.cancel();
    _entitlementSub = client.onEntitlement.listen((event) {
      if (event.cosmeticKind != 'PAINT') return;
      var changed = false;
      if (event.kind == 'entitlement.create') {
        for (final userId in event.twitchUserIds) {
          _assignments[userId] = (paintId: event.cosmeticId, at: _now());
          _refreshUserNotifier(userId);
          changed = true;
        }
      } else if (event.kind == 'entitlement.delete') {
        for (final userId in event.twitchUserIds) {
          final existing = _assignments[userId];
          if (existing != null && existing.paintId == event.cosmeticId) {
            _assignments.remove(userId);
            _refreshUserNotifier(userId);
            changed = true;
          }
        }
      }
      if (changed && _enabled) {
        unawaited(_ensurePaint(event.cosmeticId));
        notifyListeners();
      }
    });
  }

  /// Downloads the full paint catalog once per session. Failures reset the
  /// memoized future so the next lookup retries.
  Future<void> ensureCatalog() {
    return _catalogFuture ??= _fetchCatalog();
  }

  Future<void> _fetchCatalog() async {
    try {
      final data = await _gqlQuery('{ paints { paints { $_paintFields } } }');
      final root = data?['paints'] as Map<String, dynamic>?;
      final list = root?['paints'] as List<dynamic>?;
      if (list == null) return;
      final parsed = <String, SevenTvPaint>{};
      for (final item in list) {
        final paint = _parsePaint(item as Map<String, dynamic>);
        if (paint != null) parsed[paint.id] = paint;
      }
      _paintsById.addAll(parsed);
      notifyListeners();
      _refreshAllUserNotifiers();
    } catch (e) {
      logDebug('7TV paint catalog fetch failed: $e');
      _catalogFuture = null;
    }
  }

  /// Synchronous render-time lookup. Enqueues unknown/expired users for the
  /// next batched resolution; returns null until a paint (or a negative
  /// result) is known.
  SevenTvPaint? lookup(String? userId) {
    if (!_enabled || userId == null || userId.isEmpty) return null;
    final now = _now();
    final assignment = _assignments[userId];
    if (assignment != null) {
      if (now.difference(assignment.at) <= _userTtl) {
        final paint = _paintsById[assignment.paintId];
        if (paint == null) unawaited(_ensurePaint(assignment.paintId));
        return paint;
      }
      _assignments.remove(userId);
    }
    if (_pendingUsers.contains(userId)) return null;
    final negAt = _negative[userId];
    if (negAt != null) {
      if (now.difference(negAt) <= _negativeTtl) return null;
      _negative.remove(userId);
    }
    final backoff = _backoffUntil[userId];
    if (backoff != null && now.isBefore(backoff)) return null;
    requestUser(userId);
    return null;
  }

  /// Queues a user for paint resolution; batches flush after [_batchDelay].
  void requestUser(String userId) {
    if (userId.isEmpty || _pendingUsers.contains(userId)) return;
    _pendingUsers.add(userId);
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(_batchDelay, () {
      _flushTimer = null;
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    if (_resolvingBatch) {
      _scheduleFlush();
      return;
    }
    if (!_enabled || _pendingUsers.isEmpty) return;
    final batch = _pendingUsers.toList()..sort();
    final ids = batch.take(_maxBatchSize).toList();
    for (final id in ids) {
      _pendingUsers.remove(id);
    }
    _resolvingBatch = true;
    try {
      final aliases = <String, String>{
        for (var i = 0; i < ids.length; i++) 'u$i': ids[i],
      };
      final selections = aliases.entries
          .map(
            (e) =>
                '${e.key}: userByConnection(platform: TWITCH, platformId: '
                '"${e.value}") { style { activePaint { id } } }',
          )
          .join(' ');
      final data = await _gqlQuery('{ users { $selections } }');
      final users = data?['users'] as Map<String, dynamic>?;
      if (users == null) {
        // Offline or API hiccup: back off so a busy chat cannot hot-loop
        // requests, and drop the users so a later lookup retries.
        final until = _now().add(_failureBackoff);
        for (final id in ids) {
          _backoffUntil[id] = until;
        }
        return;
      }
      final now = _now();
      var changed = false;
      for (final entry in aliases.entries) {
        final node = users[entry.key] as Map<String, dynamic>? ?? {};
        final style = node['style'] as Map<String, dynamic>?;
        final paintId =
            (style?['activePaint'] as Map<String, dynamic>?)?['id'] as String?;
        if (paintId == null || paintId.isEmpty) {
          _negative[entry.value] = now;
        } else {
          _assignments[entry.value] = (paintId: paintId, at: now);
          unawaited(_ensurePaint(paintId));
          changed = true;
        }
        _refreshUserNotifier(entry.value);
      }
      if (changed) notifyListeners();
    } finally {
      _resolvingBatch = false;
      if (_pendingUsers.isNotEmpty) _scheduleFlush();
    }
  }

  // Paint definitions missing from the catalog (created mid-session) are
  // fetched individually; failures back off like user lookups do.
  final _paintFetches = <String>{};
  final _paintBackoff = <String, DateTime>{};

  Future<void> _ensurePaint(String paintId) async {
    if (_paintsById.containsKey(paintId) || _paintFetches.contains(paintId)) {
      return;
    }
    final backoff = _paintBackoff[paintId];
    if (backoff != null && _now().isBefore(backoff)) return;
    _paintFetches.add(paintId);
    try {
      final data = await _gqlQuery(
        '{ paints { paint(id: "$paintId") { $_paintFields } } }',
      );
      final root = data?['paints'] as Map<String, dynamic>?;
      final item = root?['paint'];
      if (item is Map<String, dynamic>) {
        final paint = _parsePaint(item);
        if (paint != null) {
          _paintsById[paint.id] = paint;
          for (final userId in List.of(_userNotifiers.keys)) {
            if (_assignments[userId]?.paintId == paint.id) {
              _refreshUserNotifier(userId);
            }
          }
          if (_enabled) notifyListeners();
        }
      }
      // Unknown id: the catalog refresh will cover it or it never existed.
      if (item is! Map<String, dynamic>) {
        _paintBackoff[paintId] = _now().add(_failureBackoff);
      }
    } finally {
      _paintFetches.remove(paintId);
    }
  }

  SevenTvPaint? _parsePaint(Map<String, dynamic> item) {
    final id = item['id'] as String?;
    final name = item['name'] as String? ?? '';
    if (id == null || id.isEmpty) return null;
    final data = item['data'] as Map<String, dynamic>? ?? {};
    final layers = <SevenTvPaintLayer>[];
    for (final raw in data['layers'] as List<dynamic>? ?? []) {
      final layer = _parseLayer(raw as Map<String, dynamic>);
      if (layer != null) layers.add(layer);
    }
    final shadows = <SevenTvPaintShadow>[];
    for (final raw in data['shadows'] as List<dynamic>? ?? []) {
      final shadow = _parseShadow(raw as Map<String, dynamic>);
      if (shadow != null) shadows.add(shadow);
    }
    return SevenTvPaint(id: id, name: name, layers: layers, shadows: shadows);
  }

  SevenTvPaintLayer? _parseLayer(Map<String, dynamic> raw) {
    final opacity = (raw['opacity'] as num?)?.toDouble() ?? 1.0;
    final ty = raw['ty'] as Map<String, dynamic>?;
    if (ty == null) return null;
    final stops = _parseStops(ty['stops'] as List<dynamic>?);
    switch (ty['__typename']) {
      case 'PaintLayerTypeSingleColor':
        final color = _parseHex(ty['color']?['hex'] as String?);
        if (color == null) return null;
        return SevenTvSolidColorLayer(color: color, opacity: opacity);
      case 'PaintLayerTypeLinearGradient':
        if (stops.isEmpty) return null;
        return SevenTvLinearGradientLayer(
          stops: stops,
          angleDegrees: (ty['angle'] as num?)?.toInt() ?? 0,
          repeating: ty['repeating'] as bool? ?? false,
          opacity: opacity,
        );
      case 'PaintLayerTypeRadialGradient':
        if (stops.isEmpty) return null;
        return SevenTvRadialGradientLayer(
          stops: stops,
          repeating: ty['repeating'] as bool? ?? false,
          isCircle: ty['shape'] == 'CIRCLE',
          opacity: opacity,
        );
      case 'PaintLayerTypeImage':
        final images = <SevenTvPaintImage>[];
        for (final img in ty['images'] as List<dynamic>? ?? []) {
          final m = img as Map<String, dynamic>;
          final url = m['url'] as String?;
          if (url == null || url.isEmpty) continue;
          images.add(
            SevenTvPaintImage(
              url: url,
              width: (m['width'] as num?)?.toInt() ?? 0,
              height: (m['height'] as num?)?.toInt() ?? 0,
              scale: (m['scale'] as num?)?.toInt() ?? 1,
            ),
          );
        }
        if (images.isEmpty) return null;
        return SevenTvImagePaintLayer(images: images, opacity: opacity);
    }
    return null;
  }

  List<SevenTvPaintStop> _parseStops(List<dynamic>? raw) {
    final stops = <SevenTvPaintStop>[];
    for (final entry in raw ?? const []) {
      final m = entry as Map<String, dynamic>;
      final color = _parseHex(m['color']?['hex'] as String?);
      final at = (m['at'] as num?)?.toDouble();
      if (color == null || at == null) continue;
      stops.add(SevenTvPaintStop(at: at.clamp(0.0, 1.0), color: color));
    }
    stops.sort((a, b) => a.at.compareTo(b.at));
    return stops;
  }

  SevenTvPaintShadow? _parseShadow(Map<String, dynamic> raw) {
    final color = _parseHex(raw['color']?['hex'] as String?);
    if (color == null) return null;
    return SevenTvPaintShadow(
      color: color,
      offsetX: (raw['offsetX'] as num?)?.toDouble() ?? 0,
      offsetY: (raw['offsetY'] as num?)?.toDouble() ?? 0,
      blur: (raw['blur'] as num?)?.toDouble() ?? 0,
    );
  }

  static Color? _parseHex(String? hex) {
    if (hex == null) return null;
    final value = hex.replaceFirst('#', '');
    // v4 colors arrive as RRGGBBAA.
    final packed = switch (value.length) {
      8 => int.tryParse(
        value.substring(4, 8) + value.substring(0, 6),
        radix: 16,
      ),
      6 => int.tryParse('ff$value', radix: 16),
      _ => null,
    };
    if (packed == null) return null;
    return Color(packed);
  }

  /// Resolved texture for an image paint layer, kicking off the async load on
  /// first request. Returns null until loaded (callers fall back to
  /// [SevenTvPaint.fallbackColor]).
  ui.Image? imageFor(SevenTvImagePaintLayer layer) {
    final variant = layer.pickVariant();
    if (variant == null) return null;
    final cached = _images[variant.url];
    if (cached != null) return cached;
    if (_imageInflight.add(variant.url)) {
      unawaited(_loadImage(variant));
    }
    return null;
  }

  Future<void> _loadImage(SevenTvPaintImage variant) async {
    ui.Codec? codec;
    try {
      final bytes = await _fetchBytes(Uri.parse(variant.url));
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      _images[variant.url] = frame.image;
      if (_enabled) notifyListeners();
    } catch (e) {
      logDebug('7TV paint image failed: ${variant.url}: $e');
      _images[variant.url] = null;
    } finally {
      codec?.dispose();
      _imageInflight.remove(variant.url);
    }
  }

  /// Builds the fill shader for [paint] across a [size] box. Returns null
  /// when nothing drawable is ready yet (image still loading).
  Shader? shaderFor(SevenTvPaint paint, Size size) {
    final layer = paint.layers.firstOrNull;
    if (layer == null || size.isEmpty) return null;
    final center = Offset(size.width / 2, size.height / 2);

    switch (layer) {
      case SevenTvLinearGradientLayer linear:
        final (colors, stops) = _stopLists(linear.stops, linear.opacity);
        // CSS gradient-line geometry: 0deg points up, clockwise positive.
        final theta = linear.angleDegrees * math.pi / 180.0;
        final dx = math.sin(theta);
        final dy = -math.cos(theta);
        final length = (size.width * dx.abs() + size.height * dy.abs()).abs();
        if (length <= 0) return null;
        return ui.Gradient.linear(
          center - Offset(dx, dy) * length / 2,
          center + Offset(dx, dy) * length / 2,
          colors,
          stops,
          linear.repeating ? ui.TileMode.repeated : ui.TileMode.clamp,
        );

      case SevenTvRadialGradientLayer radial:
        final (colors, stops) = _stopLists(radial.stops, radial.opacity);
        // Elliptical shapes approximate to a circle covering the box.
        final radius = size.longestSide / 2;
        if (radius <= 0) return null;
        return ui.Gradient.radial(
          center,
          radius,
          colors,
          stops,
          radial.repeating ? ui.TileMode.repeated : ui.TileMode.clamp,
        );

      case SevenTvSolidColorLayer solid:
        final color = solid.color.withValues(alpha: solid.opacity);
        return ui.Gradient.linear(center, center, [color, color]);

      case SevenTvImagePaintLayer image:
        final decoded = imageFor(image);
        if (decoded == null) return null;
        final scale = decoded.height > 0 ? size.height / decoded.height : 1.0;
        return ui.ImageShader(
          decoded,
          ui.TileMode.repeated,
          ui.TileMode.repeated,
          Matrix4.diagonal3Values(scale, scale, 1).storage,
        );
    }
  }

  (List<Color>, List<double>) _stopLists(
    List<SevenTvPaintStop> stops,
    double opacity,
  ) {
    final colors = [
      for (final stop in stops)
        stop.color.withValues(alpha: stop.color.a * opacity),
    ];
    final positions = [for (final stop in stops) stop.at];
    // Duplicate positions produce hard edges natively in Skia, matching the
    // extension's CSS behavior.
    return (colors, positions);
  }

  @visibleForTesting
  Future<void> flushForTesting() => _flush();

  @visibleForTesting
  void addPaintForTesting(SevenTvPaint paint) => _paintsById[paint.id] = paint;

  @visibleForTesting
  void assignForTesting(String userId, String paintId) {
    _assignments[userId] = (paintId: paintId, at: _now());
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _entitlementSub?.cancel();
    super.dispose();
  }
}
