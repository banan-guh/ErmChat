import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../models/generic_emote.dart';

class SevenTvChannelResponse {
  final List<GenericEmote> emotes;
  final String? userId;
  final String? emoteSetId;

  SevenTvChannelResponse({
    required this.emotes,
    this.userId,
    this.emoteSetId,
  });
}

class SevenTvEmoteProvider {
  static const int _zeroWidthFlag = 1 << 8;

  static Future<List<GenericEmote>> fetchGlobal() async {
    final uri = Uri.parse('https://7tv.io/v3/emote-sets/global');
    final res = await http.get(uri);
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final items = data['emotes'] as List<dynamic>? ?? [];
    return _parseEmotes(items, global: true);
  }

  static Future<SevenTvChannelResponse> fetchChannelResponse(String channelId) async {
    final uri = Uri.parse('https://7tv.io/v3/users/twitch/$channelId');
    final res = await http.get(uri);
    if (res.statusCode != 200) return SevenTvChannelResponse(emotes: []);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final userId = (data['user'] as Map<String, dynamic>?)?['id'] as String?;
    final emoteSet = data['emote_set'] as Map<String, dynamic>?;
    final emoteSetId = emoteSet?['id'] as String?;
    final items = emoteSet?['emotes'] as List<dynamic>? ?? [];
    final emotes = _parseEmotes(items, channel: true);
    return SevenTvChannelResponse(
      emotes: emotes,
      userId: userId,
      emoteSetId: emoteSetId,
    );
  }

  static Future<List<GenericEmote>> fetchChannel(String channelId) async {
    final resp = await fetchChannelResponse(channelId);
    return resp.emotes;
  }

  static GenericEmote? parseSingleEmote(
    Map<String, dynamic> item, {
    bool channel = false,
  }) {
    final emotes = _parseEmotes([item], channel: channel);
    return emotes.isNotEmpty ? emotes.first : null;
  }

  static List<GenericEmote> _parseEmotes(
    List<dynamic> items, {
    bool global = false,
    bool channel = false,
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
      bool isAnimated = false;
      double relativeScale = 1.0;
      double aspectRatio = 1.0;
      for (final fileEntry in baseUrl.reversed) {
        final file = fileEntry as Map<String, dynamic>;
        final format = file['format'] as String?;
        final name = file['name'] as String?;
        if (name == null) continue;
        if (format == 'WEBP') {
          final hostUrl = host['url'] as String? ?? '';
          url = 'https:$hostUrl/$name';
          isAnimated = true;
          final fileWidth = file['width'] as int?;
          final fileHeight = file['height'] as int?;
          if (fileHeight != null) {
            final multiplierStr = name.split('x').first;
            final multiplier = int.tryParse(multiplierStr);
            if (multiplier != null && multiplier > 0) {
              relativeScale = fileHeight / (multiplier * 32.0);
            }
          }
          if (fileWidth != null && fileHeight != null && fileHeight > 0) {
            aspectRatio = fileWidth / fileHeight;
          }
          break;
        }
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

      emotes.add(
        GenericEmote(
          id: id,
          code: name,
          type: EmoteType.sevenTv,
          url: url,
          isAnimated: isAnimated,
          scope: global
              ? EmoteScope.global
              : channel
              ? EmoteScope.channel
              : EmoteScope.global,
          isZeroWidth: isZeroWidth,
          relativeScale: relativeScale,
          aspectRatio: aspectRatio,
        ),
      );
    }
    return emotes;
  }
}
