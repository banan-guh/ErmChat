import 'dart:convert';
import 'dart:isolate';
import 'package:http/http.dart' as http;
import '../../models/generic_emote.dart';
import '../../util/constants.dart';

class FfzEmoteProvider {
  static Future<List<GenericEmote>> fetchGlobal({
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
    final uri = Uri.parse('https://api.frankerfacez.com/v1/set/global');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    if (res.statusCode != 200) return [];
    return Isolate.run(() {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final sets = data['sets'] as Map<String, dynamic>? ?? {};
      final emotes = <GenericEmote>[];
      for (final setEntry in sets.values) {
        final setMap = setEntry as Map<String, dynamic>;
        final items = setMap['emoticons'] as List<dynamic>? ?? [];
        for (final item in items) {
          final parsed = _parseEmote(item, resolution);
          if (parsed != null) emotes.add(parsed);
        }
      }
      return emotes;
    });
  }

  static Future<List<GenericEmote>> fetchChannel(
    String channelId, {
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
    final uri = Uri.parse('https://api.frankerfacez.com/v1/room/$channelId');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    if (res.statusCode != 200) return [];
    return Isolate.run(() {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final sets = data['sets'] as Map<String, dynamic>? ?? {};
      final emotes = <GenericEmote>[];
      for (final setEntry in sets.values) {
        final setMap = setEntry as Map<String, dynamic>;
        final items = setMap['emoticons'] as List<dynamic>? ?? [];
        for (final item in items) {
          final parsed = _parseEmote(item, resolution);
          if (parsed != null) {
            emotes.add(
              GenericEmote(
                id: parsed.id,
                code: parsed.code,
                type: parsed.type,
                url: parsed.url,
                url1x: parsed.url1x,
                url3x: parsed.url3x,
                isAnimated: parsed.isAnimated,
                scope: EmoteScope.channel,
                ownerChannel: channelId,
              ),
            );
          }
        }
      }
      return emotes;
    });
  }

  static GenericEmote? _parseEmote(dynamic item, EmoteResolution resolution) {
    final id = item['id']?.toString();
    final name = item['name'] as String?;
    if (id == null || name == null) return null;
    final urls = item['urls'] as Map<String, dynamic>?;
    // Chat renders at ~28dp; low prefers the 1x tier, medium/high the 2x. FFZ
    // has no 3x size; its largest is 4x, which is used as the high-res
    // sheet/menu asset (url3x) since the sheet needs something sharper than 2x.
    final url1 = urls?['1'] as String?;
    final url2 = urls?['2'] as String?;
    final url4 = urls?['4'] as String?;
    final String? urlPart;
    switch (resolution) {
      case EmoteResolution.low:
        urlPart = url1 ?? url2;
        break;
      case EmoteResolution.medium:
      case EmoteResolution.high:
        urlPart = url2 ?? url1;
        break;
    }
    if (urlPart == null) return null;
    String abs(String url) => url.startsWith('http') ? url : 'https:$url';
    final isAnimated = item['animated'] == true;
    return GenericEmote(
      id: id,
      code: name,
      type: EmoteType.ffz,
      url: abs(urlPart),
      url1x: url1 == null ? null : abs(url1),
      url3x: url4 == null ? null : abs(url4),
      isAnimated: isAnimated,
    );
  }
}
