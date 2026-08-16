import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../models/generic_emote.dart';
import '../../util/constants.dart';

class SevenTvChannelResponse {
  final List<GenericEmote> emotes;
  final String? userId;
  final String? emoteSetId;

  SevenTvChannelResponse({required this.emotes, this.userId, this.emoteSetId});
}

class SevenTvEmoteProvider {
  static const int _zeroWidthFlag = 1 << 8;

  static Future<List<GenericEmote>> fetchGlobal({
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
    final uri = Uri.parse('https://7tv.io/v3/emote-sets/global');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    if (res.statusCode != 200) return [];
    // The global set is ~2MB / thousands of emotes: decode + parse off the
    // main isolate so startup and the 12h rake don't jank the UI thread.
    return Isolate.run(() {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final items = data['emotes'] as List<dynamic>? ?? [];
      return _parseEmotes(items, global: true, resolution: resolution);
    });
  }

  static Future<SevenTvChannelResponse> fetchChannelResponse(
    String channelId, {
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
    final uri = Uri.parse('https://7tv.io/v3/users/twitch/$channelId');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    if (res.statusCode != 200) return SevenTvChannelResponse(emotes: []);
    return Isolate.run(() {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final userId = (data['user'] as Map<String, dynamic>?)?['id'] as String?;
      final emoteSet = data['emote_set'] as Map<String, dynamic>?;
      final emoteSetId = emoteSet?['id'] as String?;
      final items = emoteSet?['emotes'] as List<dynamic>? ?? [];
      return SevenTvChannelResponse(
        emotes: _parseEmotes(items, channel: true, resolution: resolution),
        userId: userId,
        emoteSetId: emoteSetId,
      );
    });
  }

  static GenericEmote? parseSingleEmote(
    Map<String, dynamic> item, {
    bool channel = false,
    EmoteResolution resolution = EmoteResolution.high,
  }) {
    final emotes = _parseEmotes(
      [item],
      channel: channel,
      resolution: resolution,
    );
    return emotes.isNotEmpty ? emotes.first : null;
  }

  static List<GenericEmote> _parseEmotes(
    List<dynamic> items, {
    bool global = false,
    bool channel = false,
    EmoteResolution resolution = EmoteResolution.high,
  }) {
    final emotes = <GenericEmote>[];
    for (final entry in items) {
      Map<String, dynamic> item;
      if (entry is Map<String, dynamic> && entry.containsKey('emote')) {
        item = entry['emote'] as Map<String, dynamic>;
      } else if (entry is Map<String, dynamic>) {
        item = entry;
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

      String? url;
      String? url1x;
      String? url3x;
      bool isAnimated = false;
      double relativeScale = 1.0;
      double aspectRatio = 1.0;
      // host.files are ordered smallest to largest. Chat renders at ~28dp so
      // medium/high prefer the 2x tier; high keeps the largest file at or
      // below 3x (the 4x tier is scrapped) for the sheet/menu.
      String? first;
      String? best2x;
      String? lastLe3;
      for (final fileEntry in baseUrl) {
        final file = fileEntry as Map<String, dynamic>;
        final format = file['format'] as String?;
        final name = file['name'] as String?;
        if (name == null || format != 'WEBP') continue;
        final hostUrl = host['url'] as String? ?? '';
        final fullUrl = 'https:$hostUrl/$name';
        first ??= fullUrl;
        final multiplierStr = name.split('x').first;
        if (multiplierStr == '2') best2x ??= fullUrl;
        final multiplier = int.tryParse(multiplierStr);
        if (multiplier != null && multiplier <= 3) lastLe3 = fullUrl;
        isAnimated = true;
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
      switch (resolution) {
        case EmoteResolution.low:
          url = first;
          url1x = null;
          break;
        case EmoteResolution.medium:
          url = best2x ?? first;
          url1x = best2x != null && first != best2x ? first : null;
          break;
        case EmoteResolution.high:
          url = best2x ?? first;
          url1x = best2x != null && first != best2x ? first : null;
          url3x = lastLe3;
          break;
      }
      if (url == null) continue;

      bool isZeroWidth = false;
      final flags = data['flags'];
      if (flags is int) {
        isZeroWidth = (flags & _zeroWidthFlag) != 0;
      } else if (flags != null) {
        debugPrint(
          '7TV: unexpected flags type: ${flags.runtimeType} (value: $flags)',
        );
      }

      // Alias emotes carry the aliased emote's name in data.name; record it
      // only when it differs from the display name (mirrors dankchat).
      final baseName = data['name'] as String?;
      final owner = data['owner'] as Map<String, dynamic>?;
      final ownerName = owner?['display_name'] as String?;

      emotes.add(
        GenericEmote(
          id: id,
          code: name,
          type: EmoteType.sevenTv,
          url: url,
          url1x: url1x,
          url3x: url3x,
          isAnimated: isAnimated,
          scope: global
              ? EmoteScope.global
              : channel
              ? EmoteScope.channel
              : EmoteScope.global,
          isZeroWidth: isZeroWidth,
          baseName: baseName != null && baseName != name ? baseName : null,
          ownerChannel: ownerName,
          relativeScale: relativeScale,
          aspectRatio: aspectRatio,
        ),
      );
    }
    return emotes;
  }
}
