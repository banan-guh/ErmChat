import 'dart:convert';
import 'dart:isolate';
import 'package:http/http.dart' as http;
import '../../twitch_config.dart';
import '../../emotes/emote.dart';
import '../../util/constants.dart';
import '../../util/log.dart';
import '../../util/data_usage.dart';

class TwitchEmoteProvider {
  static Future<List<Emote>> fetchGlobal({String? accessToken}) {
    return _get(
      Uri.parse('https://api.twitch.tv/helix/chat/emotes/global'),
      channel: false,
      accessToken: accessToken,
    );
  }

  /// Global unlockable catalogue (Prime, Turbo, 2FA, Hype Train,
  /// limited-time). The /global endpoint returns defaults only, so without
  /// this these emotes never reach the picker or autocomplete.
  static Future<List<Emote>> fetchGlobalUnlockable({String? accessToken}) {
    return _get(
      Uri.parse('https://api.twitch.tv/helix/chat/emotes?broadcaster_id=0'),
      channel: false,
      accessToken: accessToken,
    );
  }

  static Future<List<Emote>> fetchChannel(
    String broadcasterId, {
    String? accessToken,
    String? channelName,
  }) {
    return _get(
      Uri.parse(
        'https://api.twitch.tv/helix/chat/emotes?broadcaster_id=$broadcasterId',
      ),
      channel: true,
      channelName: channelName,
      accessToken: accessToken,
    );
  }

  static Future<List<Emote>> _get(
    Uri uri, {
    required bool channel,
    String? channelName,
    String? accessToken,
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
      );
    });
  }

  static Future<Map<String, List<Emote>>> fetchEmoteSets(
    List<String> emoteSetIds, {
    String? accessToken,
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
          final theme = _themeOf(item);
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
                  scales: _scalesFor(id, format, theme, scales),
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
  }) {
    final emotes = <Emote>[];
    for (final item in items) {
      final id = item['id'] as String?;
      final name = item['name'] as String?;
      if (id == null || name == null) continue;
      final formats = (item['format'] as List<dynamic>?)?.cast<String>() ?? [];
      final isAnimated = formats.contains('animated');
      final scales = (item['scale'] as List<dynamic>?)?.cast<String>() ?? [];
      final theme = _themeOf(item);
      final format = isAnimated ? 'animated' : 'static';
      emotes.add(
        Emote(
          id: id,
          code: name,
          meta: _metaFor(
            item: item,
            ownerChannel: channel ? channelName : null,
            ownerId: item['owner_id'] as String?,
          ),
          scales: _scalesFor(id, format, theme, scales),
          isAnimated: isAnimated,
          scope: channel ? EmoteScope.channel : EmoteScope.global,
        ),
      );
    }
    logDebug('Twitch parsed ${emotes.length} emotes');
    return emotes;
  }

  /// Render URL for each scale the API lists, keyed by quality role.
  static Map<EmoteScale, String> _scalesFor(
    String id,
    String format,
    String theme,
    List<String> scales,
  ) {
    String url(String scale) =>
        'https://static-cdn.jtvnw.net/emoticons/v2/$id/$format/$theme/$scale';
    return {
      if (scales.contains('1.0')) EmoteScale.small: url('1.0'),
      if (scales.contains('2.0')) EmoteScale.medium: url('2.0'),
      if (scales.contains('3.0')) EmoteScale.large: url('3.0'),
    };
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
}
