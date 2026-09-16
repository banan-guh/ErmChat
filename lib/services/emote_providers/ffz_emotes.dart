import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import '../../emotes/emote.dart';
import '../../util/constants.dart';
import '../../util/data_usage.dart';

class FfzEmoteProvider {
  @visibleForTesting
  static Emote? parseEmote(dynamic item, {String? ownerChannel}) =>
      _parseEmote(item, ownerChannel: ownerChannel);

  static Future<List<Emote>> fetchGlobal() async {
    final uri = Uri.parse('https://api.frankerfacez.com/v1/set/global');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    DataUsageStats.I.recordJson(res.bodyBytes.length);
    if (res.statusCode != 200) return [];
    return Isolate.run(() {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final sets = data['sets'] as Map<String, dynamic>? ?? {};
      // Only default sets are usable by everyone; other sets are allowlisted
      // per user (FFZ `users` map) and must not leak into the global list.
      // Missing field keeps old behavior so an API change cannot wipe globals.
      final defaultSets = data['default_sets'] as List<dynamic>?;
      final allowed = defaultSets?.map((e) => e.toString()).toSet();
      final emotes = <Emote>[];
      for (final setEntry in sets.entries) {
        if (allowed != null && !allowed.contains(setEntry.key)) continue;
        final setMap = setEntry.value as Map<String, dynamic>;
        final items = setMap['emoticons'] as List<dynamic>? ?? [];
        for (final item in items) {
          final parsed = _parseEmote(item);
          if (parsed != null) emotes.add(parsed);
        }
      }
      return emotes;
    });
  }

  static Future<List<Emote>> fetchChannel(String channelId) async {
    final uri = Uri.parse('https://api.frankerfacez.com/v1/room/id/$channelId');
    final res = await http.get(uri).timeout(httpTimeout);
    throwOnTransientHttpError(res.statusCode, uri);
    DataUsageStats.I.recordJson(res.bodyBytes.length);
    if (res.statusCode != 200) return [];
    return Isolate.run(() {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final sets = data['sets'] as Map<String, dynamic>? ?? {};
      final emotes = <Emote>[];
      for (final setEntry in sets.values) {
        final setMap = setEntry as Map<String, dynamic>;
        final items = setMap['emoticons'] as List<dynamic>? ?? [];
        for (final item in items) {
          final owner = item['owner'] is Map
              ? (item['owner'] as Map)['display_name'] as String?
              : null;
          final parsed = _parseEmote(item, ownerChannel: owner);
          if (parsed != null) {
            emotes.add(parsed.copyWith(scope: EmoteScope.channel));
          }
        }
      }
      return emotes;
    });
  }

  static Emote? _parseEmote(dynamic item, {String? ownerChannel}) {
    final id = item['id']?.toString();
    final name = item['name'] as String?;
    if (id == null || name == null) return null;
    // `animated` is a per-scale URL map when the emote animates, null
    // otherwise (never a bool on live data). Prefer animated art when set.
    final animatedUrls = item['animated'] is Map
        ? Map<String, dynamic>.from(item['animated'] as Map)
        : null;
    final urls =
        (animatedUrls != null && animatedUrls.isNotEmpty
                ? animatedUrls
                : item['urls'])
            as Map<String, dynamic>?;
    final url1 = urls?['1'] as String?;
    final url2 = urls?['2'] as String?;
    final url4 = urls?['4'] as String?;
    String abs(String url) => url.startsWith('http') ? url : 'https:$url';
    final scales = <EmoteScale, String>{
      if (url1 != null) EmoteScale.small: abs(url1),
      if (url2 != null) EmoteScale.medium: abs(url2),
      if (url4 != null) EmoteScale.large: abs(url4),
    };
    if (scales.isEmpty) return null;
    final isAnimated = animatedUrls != null && animatedUrls.isNotEmpty;
    // FFZ modifier flag = zero-width overlay (offsets ignored).
    final isZeroWidth = item['modifier'] == true;
    return Emote(
      id: id,
      code: name,
      meta: FfzMeta(ownerChannel: ownerChannel),
      scales: scales,
      isAnimated: isAnimated,
      isZeroWidth: isZeroWidth,
    );
  }
}
