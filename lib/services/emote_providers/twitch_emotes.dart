import 'dart:convert';
import 'dart:isolate';
import 'package:http/http.dart' as http;
import '../../twitch_config.dart';
import '../../emotes/emote.dart';
import '../../util/constants.dart';
import '../../util/log.dart';
import '../../util/data_usage.dart';

class TwitchEmoteProvider {
  static Future<List<Emote>> fetchGlobal({
    String? accessToken,
    EmoteResolution resolution = EmoteResolution.high,
  }) {
    return _get(
      Uri.parse('https://api.twitch.tv/helix/chat/emotes/global'),
      channel: false,
      accessToken: accessToken,
      resolution: resolution,
    );
  }

  /// Global unlockable catalogue (Prime, Turbo, 2FA, Hype Train,
  /// limited-time). The /global endpoint returns defaults only, so without
  /// this these emotes never reach the picker or autocomplete.
  static Future<List<Emote>> fetchGlobalUnlockable({
    String? accessToken,
    EmoteResolution resolution = EmoteResolution.high,
  }) {
    return _get(
      Uri.parse('https://api.twitch.tv/helix/chat/emotes?broadcaster_id=0'),
      channel: false,
      accessToken: accessToken,
      resolution: resolution,
    );
  }

  static Future<List<Emote>> fetchChannel(
    String broadcasterId, {
    String? accessToken,
    String? channelName,
    EmoteResolution resolution = EmoteResolution.high,
  }) {
    return _get(
      Uri.parse(
        'https://api.twitch.tv/helix/chat/emotes?broadcaster_id=$broadcasterId',
      ),
      channel: true,
      channelName: channelName,
      accessToken: accessToken,
      resolution: resolution,
    );
  }

  static Future<List<Emote>> _get(
    Uri uri, {
    required bool channel,
    String? channelName,
    String? accessToken,
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
    final headers = <String, String>{'Client-ID': TwitchConfig.clientId};
    if (accessToken != null) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    final res = await http.get(uri, headers: headers).timeout(httpTimeout);
    logDebug(
      'Twitch emotes $uri: ${res.statusCode} - ${res.body.length} bytes',
    );
    throwOnTransientHttpError(res.statusCode, uri);
    DataUsageStats.I.recordJson(res.bodyBytes.length);
    if (res.statusCode != 200) return [];
    return Isolate.run(() {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return _parseEmotes(
        data['data'] as List<dynamic>? ?? [],
        channel: channel,
        channelName: channelName,
        resolution: resolution,
      );
    });
  }

  static Future<Map<String, List<Emote>>> fetchEmoteSets(
    List<String> emoteSetIds, {
    String? accessToken,
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
    final headers = <String, String>{'Client-ID': TwitchConfig.clientId};
    if (accessToken != null) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    // Chunk to 25 emote_set_id params per request.
    const chunkSize = 25;
    final bodies = <String>[];
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
      DataUsageStats.I.recordJson(res.bodyBytes.length);
      if (res.statusCode != 200) {
        logDebug('Twitch emote set error: ${res.statusCode} ${res.body}');
        continue;
      }
      bodies.add(res.body);
    }
    if (bodies.isEmpty) return {};
    // Decode off main isolate (payload comparable to global set).
    return Isolate.run(() {
      final result = <String, List<Emote>>{};
      for (final body in bodies) {
        final data = jsonDecode(body) as Map<String, dynamic>;
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
          final scales =
              (item['scale'] as List<dynamic>?)?.cast<String>() ?? [];
          final (smallScale, oneXScale, largeScale) = _selectScales(
            scales,
            resolution,
          );
          final theme = _themeOf(item);
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
                Emote(
                  id: id,
                  code: name,
                  meta: _metaFor(
                    item: item,
                    ownerChannel: null,
                    ownerId: ownerId,
                  ),
                  url: url,
                  url1x: url1x,
                  url3x: url3x,
                  isAnimated: isAnimated,
                  scope: ownerId != null && ownerId.isNotEmpty
                      ? EmoteScope.channel
                      : EmoteScope.global,
                ),
              );
        }
      }
      return result;
    });
  }

  static List<Emote> _parseEmotes(
    List<dynamic> items, {
    bool channel = false,
    String? channelName,
    EmoteResolution resolution = EmoteResolution.high,
  }) {
    final emotes = <Emote>[];
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
      final theme = _themeOf(item);
      final format = isAnimated ? 'animated' : 'static';
      final url =
          'https://static-cdn.jtvnw.net/emoticons/v2/$id/$format/$theme/$smallScale';
      final url1x = oneXScale == null
          ? null
          : 'https://static-cdn.jtvnw.net/emoticons/v2/$id/$format/$theme/$oneXScale';
      final url3x = largeScale == null
          ? null
          : 'https://static-cdn.jtvnw.net/emoticons/v2/$id/$format/$theme/$largeScale';
      emotes.add(
        Emote(
          id: id,
          code: name,
          meta: _metaFor(
            item: item,
            ownerChannel: channel ? channelName : null,
            ownerId: item['owner_id'] as String?,
          ),
          url: url,
          url1x: url1x,
          url3x: url3x,
          isAnimated: isAnimated,
          scope: channel ? EmoteScope.channel : EmoteScope.global,
        ),
      );
    }
    logDebug('Twitch parsed ${emotes.length} emotes');
    return emotes;
  }

  /// Builds the Twitch meta, mapping the API's tier/emote_type into the render
  /// status gate. `tier` is parsed defensively: an unparseable value leaves
  /// [TwitchMeta.subTier] null but still marks the emote as a sub.
  static TwitchMeta _metaFor({
    required Map<String, dynamic> item,
    String? ownerChannel,
    String? ownerId,
  }) {
    final tier = item['tier'] as String?;
    final emoteType = (item['emote_type'] ?? item['emoteType']) as String?;
    final TwitchEmoteKind kind;
    if (tier != null || emoteType == 'subscriptions') {
      kind = TwitchEmoteKind.sub;
    } else if (emoteType == 'follower') {
      kind = TwitchEmoteKind.follower;
    } else if (emoteType == 'bitstier') {
      kind = TwitchEmoteKind.bits;
    } else {
      kind = TwitchEmoteKind.standard;
    }
    return TwitchMeta(
      kind: kind,
      subTier: tier == null ? null : int.tryParse(tier),
      ownerChannel: ownerChannel,
      ownerId: ownerId,
    );
  }

  /// First string in the `theme_mode` list, or `dark` when absent.
  static String _themeOf(Map<String, dynamic> item) {
    final modes = item['theme_mode'];
    if (modes is List) {
      for (final mode in modes) {
        if (mode is String) return mode;
      }
    }
    return 'dark';
  }

  /// Selects scale tiers: 2x for chat, largest for sheet (high only).
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
        final chat = scales.contains('2.0') ? '2.0' : smallest;
        final large = scales.lastOrNull ?? '3.0';
        // Do not emit a 3x slot identical to the chat asset.
        return (chat, oneX, large == chat ? null : large);
    }
  }
}
