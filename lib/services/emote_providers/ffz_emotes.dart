import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../models/generic_emote.dart';

class FfzEmoteProvider {
  static Future<List<GenericEmote>> fetchGlobal() async {
    final uri = Uri.parse('https://api.frankerfacez.com/v1/set/global');
    final res = await http.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final sets = data['sets'] as Map<String, dynamic>? ?? {};
    final emotes = <GenericEmote>[];
    for (final setEntry in sets.values) {
      final setMap = setEntry as Map<String, dynamic>;
      final items = setMap['emoticons'] as List<dynamic>? ?? [];
      for (final item in items) {
        final parsed = _parseEmote(item);
        if (parsed != null) emotes.add(parsed);
      }
    }
    return emotes;
  }

  static Future<List<GenericEmote>> fetchChannel(String channelId) async {
    final uri = Uri.parse('https://api.frankerfacez.com/v1/room/$channelId');
    final res = await http.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final sets = data['sets'] as Map<String, dynamic>? ?? {};
    final emotes = <GenericEmote>[];
    for (final setEntry in sets.values) {
      final setMap = setEntry as Map<String, dynamic>;
      final items = setMap['emoticons'] as List<dynamic>? ?? [];
      for (final item in items) {
        final parsed = _parseEmote(item);
        if (parsed != null) {
          emotes.add(
            GenericEmote(
              id: parsed.id,
              code: parsed.code,
              type: parsed.type,
              url: parsed.url,
              isAnimated: parsed.isAnimated,
              scope: EmoteScope.channel,
              ownerChannel: channelId,
            ),
          );
        }
      }
    }
    return emotes;
  }

  static GenericEmote? _parseEmote(dynamic item) {
    final id = item['id']?.toString();
    final name = item['name'] as String?;
    if (id == null || name == null) return null;
    final urls = item['urls'] as Map<String, dynamic>?;
    final url4 = urls?['4'] as String?;
    final url2 = urls?['2'] as String?;
    final url1 = urls?['1'] as String?;
    final urlPart = url4 ?? url2 ?? url1;
    if (urlPart == null) return null;
    final isAnimated = item['animated'] == true;
    return GenericEmote(
      id: id,
      code: name,
      type: EmoteType.ffz,
      url: urlPart.startsWith('http') ? urlPart : 'https:$urlPart',
      isAnimated: isAnimated,
    );
  }
}
