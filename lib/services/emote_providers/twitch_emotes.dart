import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../twitch_config.dart';
import '../../models/generic_emote.dart';
import '../../util/constants.dart';

class TwitchEmoteProvider {
  static Future<List<GenericEmote>> fetchGlobal({
    String? accessToken,
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
    final uri = Uri.parse('https://api.twitch.tv/helix/chat/emotes/global');
    final headers = <String, String>{'Client-ID': TwitchConfig.clientId};
    if (accessToken != null) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    final res = await http.get(uri, headers: headers).timeout(httpTimeout);
    debugPrint(
      'Twitch global emotes: ${res.statusCode} - ${res.body.length} bytes',
    );
    throwOnTransientHttpError(res.statusCode, uri);
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return _parseEmotes(
      data['data'] as List<dynamic>? ?? [],
      resolution: resolution,
    );
  }

  static Future<List<GenericEmote>> fetchChannel(
    String broadcasterId, {
    String? accessToken,
    String? channelName,
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
    final uri = Uri.parse(
      'https://api.twitch.tv/helix/chat/emotes?broadcaster_id=$broadcasterId',
    );
    final headers = <String, String>{'Client-ID': TwitchConfig.clientId};
    if (accessToken != null) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    final res = await http.get(uri, headers: headers).timeout(httpTimeout);
    if (res.statusCode != 200) {
      debugPrint('Twitch channel emotes error: ${res.statusCode}');
    }
    throwOnTransientHttpError(res.statusCode, uri);
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return _parseEmotes(
      data['data'] as List<dynamic>? ?? [],
      channel: true,
      channelName: channelName,
      resolution: resolution,
    );
  }

  static Future<Map<String, List<GenericEmote>>> fetchEmoteSets(
    List<String> emoteSetIds, {
    String? accessToken,
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
    final result = <String, List<GenericEmote>>{};
    final headers = <String, String>{'Client-ID': TwitchConfig.clientId};
    if (accessToken != null) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    // Twitch accepts up to 25 emote_set_id params per request; chunk so a
    // batch with many sets doesn't spawn one request per set.
    const chunkSize = 25;
    for (var i = 0; i < emoteSetIds.length; i += chunkSize) {
      var end = i + chunkSize;
      if (end > emoteSetIds.length) end = emoteSetIds.length;
      final chunk = emoteSetIds.sublist(i, end);
      final query = chunk.map((id) => 'emote_set_id=$id').join('&');
      final uri = Uri.parse(
        'https://api.twitch.tv/helix/chat/emotes/set?$query',
      );
      final res = await http.get(uri, headers: headers).timeout(httpTimeout);
      throwOnTransientHttpError(res.statusCode, uri);
      if (res.statusCode != 200) {
        debugPrint('Twitch emote set error: ${res.statusCode} ${res.body}');
        continue;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final items = data['data'] as List<dynamic>? ?? [];
      for (final item in items) {
        final id = item['id'] as String?;
        final name = item['name'] as String?;
        final ownerId = item['owner_id'] as String?;
        if (id == null || name == null) continue;
        final formats =
            (item['format'] as List<dynamic>?)?.cast<String>() ?? [];
        final isAnimated = formats.contains('animated');
        final format = isAnimated ? 'animated' : 'static';
        final scales = (item['scale'] as List<dynamic>?)?.cast<String>() ?? [];
        final (smallScale, oneXScale, largeScale) = _selectScales(
          scales,
          resolution,
        );
        final theme =
            (item['theme_mode'] as List<dynamic>?)?.firstOrNull as String? ??
            'dark';
        final url =
            'https://static-cdn.jtvnw.net/emoticons/v2/$id/$format/$theme/$smallScale';
        final url1x = oneXScale == null
            ? null
            : 'https://static-cdn.jtvnw.net/emoticons/v2/$id/$format/$theme/$oneXScale';
        final url3x = largeScale == null
            ? null
            : 'https://static-cdn.jtvnw.net/emoticons/v2/$id/$format/$theme/$largeScale';
        result
            .putIfAbsent(ownerId ?? '', () => [])
            .add(
              GenericEmote(
                id: id,
                code: name,
                type: EmoteType.twitch,
                url: url,
                url1x: url1x,
                url3x: url3x,
                isAnimated: isAnimated,
                scope: ownerId != null && ownerId.isNotEmpty
                    ? EmoteScope.channel
                    : EmoteScope.global,
                tier: item['tier'] as String?,
                emoteType: item['emote_type'] as String?,
              ),
            );
      }
    }
    return result;
  }

  static List<GenericEmote> _parseEmotes(
    List<dynamic> items, {
    bool channel = false,
    String? channelName,
    EmoteResolution resolution = EmoteResolution.high,
  }) {
    final emotes = <GenericEmote>[];
    for (final item in items) {
      final id = item['id'] as String?;
      final name = item['name'] as String?;
      if (id == null || name == null) continue;
      final formats = (item['format'] as List<dynamic>?)?.cast<String>() ?? [];
      final isAnimated = formats.contains('animated');
      final scales = (item['scale'] as List<dynamic>?)?.cast<String>() ?? [];
      final (smallScale, oneXScale, largeScale) = _selectScales(
        scales,
        resolution,
      );
      final theme =
          (item['theme_mode'] as List<dynamic>?)?.firstOrNull as String? ??
          'dark';
      final format = isAnimated ? 'animated' : 'static';
      final url =
          'https://static-cdn.jtvnw.net/emoticons/v2/$id/$format/$theme/$smallScale';
      final url1x = oneXScale == null
          ? null
          : 'https://static-cdn.jtvnw.net/emoticons/v2/$id/$format/$theme/$oneXScale';
      final url3x = largeScale == null
          ? null
          : 'https://static-cdn.jtvnw.net/emoticons/v2/$id/$format/$theme/$largeScale';
      final tier = item['tier'] as String?;
      emotes.add(
        GenericEmote(
          id: id,
          code: name,
          type: EmoteType.twitch,
          url: url,
          url1x: url1x,
          url3x: url3x,
          isAnimated: isAnimated,
          scope: channel ? EmoteScope.channel : EmoteScope.global,
          tier: tier,
          ownerChannel: channel ? channelName : null,
        ),
      );
    }
    debugPrint('Twitch parsed ${emotes.length} emotes');
    return emotes;
  }

  /// Selects the small/1x/large scale tiers for the given resolution. The
  /// per-item `scale` list is ordered ascending. Chat renders at ~28dp so
  /// medium/high prefer the 2.0 tier; high additionally keeps the largest
  /// (typically 3.0) for the larger sheet/menu. `url1x` (the 1.0 scale, when
  /// the list has one) is kept as a cached-fallback placeholder candidate.
  static (String, String?, String?) _selectScales(
    List<String> scales,
    EmoteResolution resolution,
  ) {
    final smallest = scales.firstOrNull ?? '1.0';
    final oneX = scales.contains('1.0') ? '1.0' : null;
    switch (resolution) {
      case EmoteResolution.low:
        return (scales.contains('1.0') ? '1.0' : smallest, oneX, null);
      case EmoteResolution.medium:
        return (scales.contains('2.0') ? '2.0' : smallest, oneX, null);
      case EmoteResolution.high:
        return (
          scales.contains('2.0') ? '2.0' : smallest,
          oneX,
          scales.lastOrNull ?? '3.0',
        );
    }
  }
}
