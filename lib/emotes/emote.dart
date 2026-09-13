import 'emote_meta.dart';

enum EmoteType { twitch, bttv, ffz, sevenTv }

enum EmoteScope { global, channel, personal }

/// Image resolution tier for emote fetching. There is no 4x tier: providers
/// expose at most a 3x slot, and FFZ's 4x asset is carried in [Emote.url3x].
enum EmoteResolution {
  /// 1x for the low fetch tier (smallest available).
  low,

  /// 2x for medium/high; chat caches only ever store the 2x asset.
  medium,

  /// Adds an on-demand 3x asset (sheet/menu) on top of 2x.
  high,
}

/// First enum value matching [name], or [fallback] when absent/unknown.
T enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  if (name is String) {
    for (final value in values) {
      if (value.name == name) return value;
    }
  }
  return fallback;
}

/// One token from [EmoteManager.tokenize]: either an emote or plain text.
class EmoteToken {
  final Emote? emote;
  final String text;
  final int start;
  final int end;

  const EmoteToken({
    this.emote,
    required this.text,
    required this.start,
    required this.end,
  });

  bool get isEmote => emote != null;
}

/// url = active render URL. url1x/url3x = scale alternatives for the emote sheet and as cache-fallback placeholders. url3x only set when the provider has a true high-res asset (FFZ maps its 4x here since it lacks 3x).
class Emote {
  final String id;
  final String code;
  final EmoteScope scope;
  final String url;

  /// 1x asset for cache fallbacks and resolution picker. Null if single-scale only.
  final String? url1x;

  /// 3x asset for emote sheet/picker. Null if no high-res available.
  final String? url3x;
  final bool isAnimated;

  /// Overlay emote composited over the preceding base emote.
  final bool isZeroWidth;
  final EmoteMeta meta;

  const Emote({
    required this.id,
    required this.code,
    required this.meta,
    required this.url,
    this.scope = EmoteScope.global,
    this.url1x,
    this.url3x,
    this.isAnimated = false,
    this.isZeroWidth = false,
  });

  EmoteType get type => meta.type;

  Emote copyWith({String? code, EmoteScope? scope}) => Emote(
    id: id,
    code: code ?? this.code,
    meta: meta,
    url: url,
    scope: scope ?? this.scope,
    url1x: url1x,
    url3x: url3x,
    isAnimated: isAnimated,
    isZeroWidth: isZeroWidth,
  );

  /// 7TV alias name, or null for every other provider.
  String? get baseName => switch (meta) {
    SevenTvMeta m => m.baseName,
    _ => null,
  };

  /// 7TV vertical scale, 1.0 for every other provider.
  double get relativeScale => switch (meta) {
    SevenTvMeta m => m.relativeScale,
    _ => 1.0,
  };

  /// 7TV width/height ratio, 1.0 for every other provider.
  double get aspectRatio => switch (meta) {
    SevenTvMeta m => m.aspectRatio,
    _ => 1.0,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'code': code,
    'scope': scope.name,
    'url': url,
    'url1x': url1x,
    'url3x': url3x,
    'isAnimated': isAnimated,
    'isZeroWidth': isZeroWidth,
    'meta': meta.toJson(),
  };

  factory Emote.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final code = json['code'];
    final url = json['url'];
    if (id is! String || code is! String || url is! String) {
      throw FormatException('Invalid emote json: $json');
    }
    final meta = json['meta'];
    return Emote(
      id: id,
      code: code,
      url: url,
      scope: enumByName(EmoteScope.values, json['scope'], EmoteScope.global),
      url1x: json['url1x'] as String?,
      url3x: json['url3x'] as String?,
      isAnimated: json['isAnimated'] as bool? ?? false,
      isZeroWidth: json['isZeroWidth'] as bool? ?? false,
      meta: meta is Map<String, dynamic>
          ? EmoteMeta.fromJson(meta)
          : const BttvMeta(),
    );
  }
}
