import 'dart:convert';
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
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final items = data['emotes'] as List<dynamic>? ?? [];
    return _parseEmotes(items, global: true, resolution: resolution);
  }

  static Future<SevenTvChannelResponse> fetchChannelResponse(
    String channelId, {
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
    final uri = Uri.parse('https://7tv.io/v3/users/twitch/$channelId');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    if (res.statusCode != 200) return SevenTvChannelResponse(emotes: []);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final userId = (data['user'] as Map<String, dynamic>?)?['id'] as String?;
    final emoteSet = data['emote_set'] as Map<String, dynamic>?;
    final emoteSetId = emoteSet?['id'] as String?;
    final items = emoteSet?['emotes'] as List<dynamic>? ?? [];
    final emotes = _parseEmotes(items, channel: true, resolution: resolution);
    return SevenTvChannelResponse(
      emotes: emotes,
      userId: userId,
      emoteSetId: emoteSetId,
    );
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
      String? urlLarge;
      bool isAnimated = false;
      double relativeScale = 1.0;
      double aspectRatio = 1.0;
      // host.files are ordered smallest to largest. AVIF is preferred (7TV
      // serves every emote as AVIF and it is smaller than WEBP); WEBP is the
      // fallback. Chat renders at ~28dp so medium/high prefer the 2x tier;
      // high keeps the largest file at or below 3x (the 4x tier is scrapped)
      // for the sheet/menu.
      final firstUrls = <String, String>{};
      final best2xUrls = <String, String>{};
      final lastLe3Urls = <String, String>{};
      for (final fileEntry in baseUrl) {
        final file = fileEntry as Map<String, dynamic>;
        final format = file['format'] as String?;
        final name = file['name'] as String?;
        if (name == null) continue;
        if (format == 'GIF') {
          // Animated emotes always carry a GIF variant; the renderer sniffs
          // bytes anyway, but the flag keeps metadata honest.
          isAnimated = true;
          continue;
        }
        if (format != 'AVIF' && format != 'WEBP') continue;
        final f = format!;
        final hostUrl = host['url'] as String? ?? '';
        final fullUrl = 'https:$hostUrl/$name';
        firstUrls.putIfAbsent(f, () => fullUrl);
        final multiplierStr = name.split('x').first;
        if (multiplierStr == '2') best2xUrls.putIfAbsent(f, () => fullUrl);
        final multiplier = int.tryParse(multiplierStr);
        if (multiplier != null && multiplier <= 3) {
          lastLe3Urls[f] = fullUrl;
        }
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
      final fmt = firstUrls.containsKey('AVIF') ? 'AVIF' : 'WEBP';
      final first = firstUrls[fmt];
      final best2x = best2xUrls[fmt];
      final lastLe3 = lastLe3Urls[fmt];
      switch (resolution) {
        case EmoteResolution.low:
          url = first;
          break;
        case EmoteResolution.medium:
          url = best2x ?? first;
          break;
        case EmoteResolution.high:
          url = best2x ?? first;
          urlLarge = lastLe3;
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
          urlLarge: urlLarge,
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
