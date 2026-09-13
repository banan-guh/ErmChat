import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import '../../emotes/emote.dart';
import '../../emotes/emote_meta.dart';
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
  static List<Emote> parseEmotes(
    List<dynamic> items, {
    bool channel = false,
    EmoteResolution resolution = EmoteResolution.high,
  }) => _parseEmotes(items, channel: channel, resolution: resolution);

  static Future<List<Emote>> fetchGlobal({
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
    final uri = Uri.parse('https://api.betterttv.net/3/cached/emotes/global');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    DataUsageStats.I.recordJson(res.bodyBytes.length);
    if (res.statusCode != 200) return [];
    return Isolate.run(() {
      final data = jsonDecode(res.body) as List<dynamic>;
      return _parseEmotes(data, resolution: resolution);
    });
  }

  static Future<List<Emote>> fetchChannel(
    String channelId, {
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
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
        ..._parseEmotes(channelEmotes, channel: true, resolution: resolution),
        ..._parseEmotes(sharedEmotes, channel: true, resolution: resolution),
      ];
    });
  }

  static List<Emote> _parseEmotes(
    List<dynamic> items, {
    bool channel = false,
    EmoteResolution resolution = EmoteResolution.high,
  }) {
    final emotes = <Emote>[];
    for (final item in items) {
      final id = item['id'] as String?;
      final code = item['code'] as String?;
      if (id == null || code == null) continue;

      final isAnimated = item['imageType'] == 'gif';
      // Low=1x, medium/high=2x. 3x for sheet on high only.
      final url = resolution == EmoteResolution.low
          ? 'https://cdn.betterttv.net/emote/$id/1x'
          : 'https://cdn.betterttv.net/emote/$id/2x';
      final url1x = 'https://cdn.betterttv.net/emote/$id/1x';
      final url3x = resolution == EmoteResolution.high
          ? 'https://cdn.betterttv.net/emote/$id/3x'
          : null;

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
          url: url,
          url1x: url1x,
          url3x: url3x,
          isAnimated: isAnimated,
          scope: channel ? EmoteScope.channel : EmoteScope.global,
          isZeroWidth: isZeroWidth,
        ),
      );
    }
    return emotes;
  }
}
