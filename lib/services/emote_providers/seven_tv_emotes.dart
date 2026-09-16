import 'dart:convert';
import 'dart:isolate';
import 'package:http/http.dart' as http;
import '../../emotes/emote.dart';
import '../../util/constants.dart';
import '../../util/log.dart';
import '../../util/data_usage.dart';

class SevenTvChannelResponse {
  final List<Emote> emotes;
  final String? userId;
  final String? emoteSetId;

  SevenTvChannelResponse({required this.emotes, this.userId, this.emoteSetId});
}

class SevenTvEmoteProvider {
  static const int _zeroWidthFlag = 1 << 8;

  /// Only this set kind is usable anywhere; channel and seasonal sets stay
  /// channel-scoped. Observed values: personal 4, channel 0.
  static const int _personalSetFlag = 1 << 2;

  /// Whether a set payload (`user.emote_sets[]` entry or `emote-sets/<id>`
  /// response) is a personal set. Missing flags fail closed.
  static bool isPersonalSet(Map<String, dynamic> data) {
    final flags = data['flags'];
    return flags is int && (flags & _personalSetFlag) != 0;
  }

  static Future<List<Emote>> fetchGlobal() async {
    final uri = Uri.parse('https://7tv.io/v3/emote-sets/global');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    DataUsageStats.I.recordJson(res.bodyBytes.length);
    if (res.statusCode != 200) return [];
    // ~2MB global set: decode off main isolate.
    return Isolate.run(() {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final items = data['emotes'] as List<dynamic>? ?? [];
      return _parseEmotes(items, global: true);
    });
  }

  static Future<SevenTvChannelResponse> fetchChannelResponse(
    String channelId,
  ) async {
    final uri = Uri.parse('https://7tv.io/v3/users/twitch/$channelId');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    DataUsageStats.I.recordJson(res.bodyBytes.length);
    if (res.statusCode != 200) return SevenTvChannelResponse(emotes: []);
    return Isolate.run(() {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final userId = (data['user'] as Map<String, dynamic>?)?['id'] as String?;
      final emoteSet = data['emote_set'] as Map<String, dynamic>?;
      final emoteSetId = emoteSet?['id'] as String?;
      final items = emoteSet?['emotes'] as List<dynamic>? ?? [];
      return SevenTvChannelResponse(
        emotes: _parseEmotes(items, channel: true),
        userId: userId,
        emoteSetId: emoteSetId,
      );
    });
  }

  /// Personal set ids for a Twitch user id (`user.emote_sets`). Channel and
  /// seasonal sets are excluded; contents need a per-set [fetchEmoteSet].
  static Future<List<String>> fetchOwnedSetIds(String twitchId) async {
    final uri = Uri.parse('https://7tv.io/v3/users/twitch/$twitchId');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    DataUsageStats.I.recordJson(res.bodyBytes.length);
    if (res.statusCode != 200) return [];
    return Isolate.run(() {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return parseOwnedSetIds(data);
    });
  }

  static List<String> parseOwnedSetIds(Map<String, dynamic> data) {
    final user = data['user'] as Map<String, dynamic>?;
    final sets = user?['emote_sets'] as List<dynamic>? ?? [];
    return [
      for (final entry in sets)
        if (entry is Map<String, dynamic> &&
            entry['id'] is String &&
            isPersonalSet(entry))
          entry['id'] as String,
    ];
  }

  /// Emotes of one personal set by id. Non-personal sets return empty so a
  /// mistargeted id never leaks channel emotes into the global merge.
  static Future<List<Emote>> fetchEmoteSet(String setId) async {
    final uri = Uri.parse('https://7tv.io/v3/emote-sets/$setId');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    DataUsageStats.I.recordJson(res.bodyBytes.length);
    if (res.statusCode != 200) return [];
    return Isolate.run(() {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (!isPersonalSet(data)) return <Emote>[];
      final items = data['emotes'] as List<dynamic>? ?? [];
      return _parseEmotes(items, personal: true);
    });
  }

  static Emote? parseSingleEmote(
    Map<String, dynamic> item, {
    bool channel = false,
    bool personal = false,
  }) {
    final emotes = _parseEmotes([item], channel: channel, personal: personal);
    return emotes.isNotEmpty ? emotes.first : null;
  }

  static List<Emote> _parseEmotes(
    List<dynamic> items, {
    bool global = false,
    bool channel = false,
    bool personal = false,
  }) {
    final emotes = <Emote>[];
    for (final entry in items) {
      Map<String, dynamic> item;
      if (entry is! Map<String, dynamic>) continue;
      final nested = entry['emote'];
      if (nested == null) {
        item = entry;
      } else if (nested is Map<String, dynamic>) {
        item = nested;
      } else {
        continue;
      }

      final id = item['id'] as String?;
      final name = item['name'] as String?;
      if (id == null || name == null) continue;

      final data = item['data'] as Map<String, dynamic>? ?? item;

      final host = data['host'] as Map<String, dynamic>?;
      if (host == null) continue;
      final baseUrl = host['files'] as List<dynamic>?;
      if (baseUrl == null || baseUrl.isEmpty) continue;

      final scales = <EmoteScale, String>{};
      bool isAnimated = false;
      double relativeScale = 1.0;
      double aspectRatio = 1.0;
      for (final fileEntry in baseUrl) {
        if (fileEntry is! Map<String, dynamic>) continue;
        final file = fileEntry;
        final format = file['format'] as String?;
        final name = file['name'] as String?;
        if (name == null || format != 'WEBP') continue;
        final hostUrl = host['url'] as String? ?? '';
        final fullUrl = 'https:$hostUrl/$name';
        final multiplierStr = name.split('x').first;
        final multiplier = int.tryParse(multiplierStr);
        if (multiplierStr == '1') {
          scales.putIfAbsent(EmoteScale.small, () => fullUrl);
        } else if (multiplierStr == '2') {
          scales.putIfAbsent(EmoteScale.medium, () => fullUrl);
        } else if (multiplierStr == '3') {
          // 3x backs large only until a 4x file replaces it.
          scales.putIfAbsent(EmoteScale.large, () => fullUrl);
        } else if (multiplierStr == '4') {
          scales[EmoteScale.large] = fullUrl;
        }
        // Static emotes are WEBP too; only the payload flag marks animation.
        isAnimated = data['animated'] == true;
        final fileWidth = file['width'] as int?;
        final fileHeight = file['height'] as int?;
        if (fileHeight != null) {
          if (multiplier != null && multiplier > 0) {
            relativeScale = fileHeight / (multiplier * 32.0);
          }
        }
        if (fileWidth != null && fileHeight != null && fileHeight > 0) {
          aspectRatio = fileWidth / fileHeight;
        }
      }
      if (scales.isEmpty) continue;

      bool isZeroWidth = false;
      final flags = data['flags'];
      if (flags is int) {
        isZeroWidth = (flags & _zeroWidthFlag) != 0;
      } else if (flags != null) {
        logDebug(
          '7TV: unexpected flags type: ${flags.runtimeType} (value: $flags)',
        );
      }

      // Alias name recorded when it differs from display name.
      final baseName = data['name'] as String?;
      final owner = data['owner'] as Map<String, dynamic>?;
      final ownerName = owner?['display_name'] as String?;

      // Unlisted flag parsed; EmoteManager owns visibility (no refetch needed).
      final listed = data['listed'];

      emotes.add(
        Emote(
          id: id,
          code: name,
          meta: SevenTvMeta(
            creator: ownerName,
            baseName: baseName != null && baseName != name ? baseName : null,
            unlisted: listed is bool && !listed,
            relativeScale: relativeScale,
            aspectRatio: aspectRatio,
          ),
          scales: scales,
          isAnimated: isAnimated,
          scope: personal
              ? EmoteScope.personal
              : global
              ? EmoteScope.global
              : channel
              ? EmoteScope.channel
              : EmoteScope.global,
          isZeroWidth: isZeroWidth,
        ),
      );
    }
    return emotes;
  }
}
