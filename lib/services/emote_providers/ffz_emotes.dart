import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import '../../models/generic_emote.dart';
import '../../util/constants.dart';
import '../data_usage.dart';

class FfzEmoteProvider {
  @visibleForTesting
  static GenericEmote? parseEmote(dynamic item, EmoteResolution resolution) =>
      _parseEmote(item, resolution);

  static Future<List<GenericEmote>> fetchGlobal({
    EmoteResolution resolution = EmoteResolution.high,
  }) async {
    final uri = Uri.parse('https://api.frankerfacez.com/v1/set/global');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    DataUsageStats.I.recordJson(res.bodyBytes.length);
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
    DataUsageStats.I.recordJson(res.bodyBytes.length);
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
                isZeroWidth: parsed.isZeroWidth,
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
    // Low=1x, medium/high=2x. 4x used as sheet/menu high-res.
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
    // FFZ modifier flag = zero-width overlay (offsets ignored).
    final isZeroWidth = item['modifier'] == true;
    return GenericEmote(
      id: id,
      code: name,
      type: EmoteType.ffz,
      url: abs(urlPart),
      url1x: url1 == null ? null : abs(url1),
      url3x: url4 == null ? null : abs(url4),
      isAnimated: isAnimated,
      isZeroWidth: isZeroWidth,
    );
  }
}
