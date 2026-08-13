import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../models/generic_emote.dart';
import '../../util/constants.dart';

class BttvEmoteProvider {
  static Future<List<GenericEmote>> fetchGlobal() async {
    final uri = Uri.parse('https://api.betterttv.net/3/cached/emotes/global');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body) as List<dynamic>;
    return _parseEmotes(data, global: true);
  }

  static Future<List<GenericEmote>> fetchChannel(String channelId) async {
    final uri = Uri.parse(
      'https://api.betterttv.net/3/cached/channels/$channelId',
    );
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final channelEmotes = data['channelEmotes'] as List<dynamic>? ?? [];
    final sharedEmotes = data['sharedEmotes'] as List<dynamic>? ?? [];
    return [
      ..._parseEmotes(channelEmotes, channel: true),
      ..._parseEmotes(sharedEmotes, channel: true),
    ];
  }

  static List<GenericEmote> _parseEmotes(
    List<dynamic> items, {
    bool global = false,
    bool channel = false,
  }) {
    final emotes = <GenericEmote>[];
    for (final item in items) {
      final id = item['id'] as String?;
      final code = item['code'] as String?;
      if (id == null || code == null) continue;

      final isAnimated = item['imageType'] == 'gif';
      // Chat renders at ~28dp; 2x (56px) covers up to 2x device pixel ratio
      // without the byte cost of 3x. 3x stays for the larger sheet/menu.
      final url = 'https://cdn.betterttv.net/emote/$id/2x';
      final urlLarge = 'https://cdn.betterttv.net/emote/$id/3x';

      bool isZeroWidth = false;
      final zwField = item['zeroWidth'];
      if (zwField is bool) {
        isZeroWidth = zwField;
      } else if (zwField != null) {
        debugPrint(
          'BTTV: unexpected zeroWidth field type: ${zwField.runtimeType}',
        );
      }

      emotes.add(
        GenericEmote(
          id: id,
          code: code,
          type: EmoteType.bttv,
          url: url,
          urlLarge: urlLarge,
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
