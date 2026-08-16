import 'dart:convert';
import 'dart:isolate';
import 'package:http/http.dart' as http;
import '../../models/generic_emote.dart';
import '../../util/constants.dart';
import '../../util/log.dart';

class BttvEmoteProvider {
  static Future<List<GenericEmote>> fetchGlobal({
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
    final uri = Uri.parse('https://api.betterttv.net/3/cached/emotes/global');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    if (res.statusCode != 200) return [];
    return Isolate.run(() {
      final data = jsonDecode(res.body) as List<dynamic>;
      return _parseEmotes(data, global: true, resolution: resolution);
    });
  }

  static Future<List<GenericEmote>> fetchChannel(
    String channelId, {
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
    final uri = Uri.parse(
      'https://api.betterttv.net/3/cached/channels/$channelId',
    );
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
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

  static List<GenericEmote> _parseEmotes(
    List<dynamic> items, {
    bool global = false,
    bool channel = false,
    EmoteResolution resolution = EmoteResolution.high,
  }) {
    final emotes = <GenericEmote>[];
    for (final item in items) {
      final id = item['id'] as String?;
      final code = item['code'] as String?;
      if (id == null || code == null) continue;

      final isAnimated = item['imageType'] == 'gif';
      // Chat renders at ~28dp; low fetches the 1x tier, medium/high the 2x
      // (56px) which covers up to 2x device pixel ratio without the byte cost
      // of 3x. 3x stays for the large sheet/menu on high only. The 1x/3x URLs
      // are always derivable from the pattern, so both scale fields are
      // populated regardless of tier (1x doubles as the cached-fallback
      // placeholder).
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

      emotes.add(
        GenericEmote(
          id: id,
          code: code,
          type: EmoteType.bttv,
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
        ),
      );
    }
    return emotes;
  }
}
