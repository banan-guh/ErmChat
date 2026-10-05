import 'dart:convert';
import 'dart:io';

import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/emotes/emote_catalog.dart';
import 'package:ermchat/models/emote_fetch_tier.dart';
import 'package:ermchat/services/emote_meta_store.dart';
import 'package:ermchat/services/emote_persistence.dart';
import 'package:ermchat/services/emote_providers/ffz_emotes.dart';
import 'package:ermchat/services/ffz_user_emotes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Emote _ffz(String id, String code, {int? effects}) => Emote(
  id: id,
  code: code,
  meta: FfzMeta(effects: effects),
  scales: {EmoteScale.small: 'https://cdn.frankerfacez.com/emote/$id/1'},
  isZeroWidth: true,
);

void main() {
  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('ermchat_ffz');
    EmoteMetaStore.I.overrideDirectory(dir);
    addTearDown(() => EmoteMetaStore.I.reset());
    addTearDown(() => dir.delete(recursive: true));
  });

  test('user sets reach only their logins and survive a restart', () async {
    final spin = _ffz('1', 'ffzSpin', effects: 129);
    final sets = FfzUserSets(
      logins: {
        '1532818': {'alice'},
      },
      emotes: {
        '1532818': [spin],
      },
    );
    final first = FfzUserEmotes();
    expect(first.known, isFalse);
    await first.apply(sets);

    final restored = FfzUserEmotes();
    await restored.loadPersisted();
    expect(restored.known, isTrue);
    expect(restored.lookupFor('Alice')!.byCode.keys, ['ffzSpin']);
    expect(restored.lookupFor('bob'), isNull, reason: 'not on the list');
    expect(
      ffzEffects(restored.lookupFor('alice')!.byCode['ffzSpin']!),
      129,
      reason: 'flags survive the store',
    );

    // Sender caches key on lookup identity, so merges must be stable.
    final personal = EmoteLookup(byCode: const {}, suggestions: const []);
    final merged = restored.withSender(personal, 'alice');
    expect(identical(merged, restored.withSender(personal, 'alice')), isTrue);
    expect(identical(restored.withSender(personal, 'bob'), personal), isTrue);
  });

  test('a cached FFZ modifier without flags refetches once', () async {
    Future<bool> freshWith(Emote modifier) async {
      await EmoteMetaStore.I.write(
        'emotes5_global',
        jsonEncode({
          'ts': DateTime.now().toIso8601String(),
          'tier': EmoteFetchTier.high.index,
          'emotes': EmoteCatalog(ffzGlobal: [modifier]).toJsonMap(),
        }),
      );
      final persistence = EmotePersistence(
        tier: () => EmoteFetchTier.high,
        isAccountUnlock: (_) => false,
      );
      final loaded = await persistence.load(
        'emotes5_global',
        const Duration(hours: 12),
      );
      return loaded.fresh;
    }

    expect(await freshWith(_ffz('1', 'ffzX')), isFalse, reason: 'old cache');
    expect(await freshWith(_ffz('1', 'ffzX', effects: 3)), isTrue);
  });
}
