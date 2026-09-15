import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import '../../emotes/emote.dart';
import '../../util/constants.dart';
import '../../util/log.dart';
import '../../util/data_usage.dart';

class BttvEmoteProvider {
  // BTTV overlay codes: hardcoded (API doesn't mark them).
  static const _zeroWidthCodes = {
    'SoSnowy',
    'IceCold',
    'SantaHat',
    'TopHat',
    'ReinDeer',
    'CandyCane',
    'cvMask',
    'cvHazmat',
    'cvCompost',
  };

  @visibleForTesting
  static List<Emote> parseEmotes(List<dynamic> items, {bool channel = false}) =>
      _parseEmotes(items, channel: channel);

  static Future<List<Emote>> fetchGlobal() async {
    final uri = Uri.parse('https://api.betterttv.net/3/cached/emotes/global');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    DataUsageStats.I.recordJson(res.bodyBytes.length);
    if (res.statusCode != 200) return [];
    return Isolate.run(() {
      final data = jsonDecode(res.body) as List<dynamic>;
      return _parseEmotes(data);
    });
  }

  static Future<List<Emote>> fetchChannel(String channelId) async {
    final uri = Uri.parse(
      'https://api.betterttv.net/3/cached/users/twitch/$channelId',
    );
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    DataUsageStats.I.recordJson(res.bodyBytes.length);
    if (res.statusCode != 200) return [];
    return Isolate.run(() {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final channelEmotes = data['channelEmotes'] as List<dynamic>? ?? [];
      final sharedEmotes = data['sharedEmotes'] as List<dynamic>? ?? [];
      return [
        ..._parseEmotes(channelEmotes, channel: true),
        ..._parseEmotes(sharedEmotes, channel: true),
      ];
    });
  }

  static List<Emote> _parseEmotes(List<dynamic> items, {bool channel = false}) {
    final emotes = <Emote>[];
    for (final item in items) {
      final id = item['id'] as String?;
      final code = item['code'] as String?;
      if (id == null || code == null) continue;

      final isAnimated = item['imageType'] == 'gif';

      bool isZeroWidth = false;
      final zwField = item['zeroWidth'];
      if (zwField is bool) {
        isZeroWidth = zwField;
      } else if (zwField != null) {
        logDebug(
          'BTTV: unexpected zeroWidth field type: ${zwField.runtimeType}',
        );
      }
      // API never sends zeroWidth; hardcoded list drives overlay rendering.
      isZeroWidth = isZeroWidth || _zeroWidthCodes.contains(code);

      emotes.add(
        Emote(
          id: id,
          code: code,
          meta: const BttvMeta(),
          scales: {
            EmoteScale.small: 'https://cdn.betterttv.net/emote/$id/1x',
            EmoteScale.medium: 'https://cdn.betterttv.net/emote/$id/2x',
            EmoteScale.large: 'https://cdn.betterttv.net/emote/$id/3x',
          },
          isAnimated: isAnimated,
          scope: channel ? EmoteScope.channel : EmoteScope.global,
          isZeroWidth: isZeroWidth,
        ),
      );
    }
    return emotes;
  }
}
