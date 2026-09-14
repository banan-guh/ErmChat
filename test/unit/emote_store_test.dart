import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/providers/emote_providers.dart';
import 'package:ermchat/services/emote_fetcher.dart';
import 'package:ermchat/services/emote_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Emote _emote(String id, String code, {EmoteType type = EmoteType.bttv}) =>
    Emote(
      id: id,
      code: code,
      meta: switch (type) {
        EmoteType.sevenTv => const SevenTvMeta(),
        EmoteType.twitch => const TwitchMeta(kind: TwitchEmoteKind.standard),
        EmoteType.ffz => const FfzMeta(),
        EmoteType.bttv => const BttvMeta(),
      },
      url: 'https://example.com/$id.png',
    );

void main() {
  test('global commit emits a global full change', () {
    final store = EmoteStore();
    final changes = <EmoteChange>[];
    store.addListener(changes.add);

    final applied = store.commitGlobal(
      store.globalEpoch,
      GlobalEmoteFetch(
        byProvider: {
          EmoteType.bttv: [_emote('g1', 'Global')],
        },
      ),
    );

    expect(applied, isTrue);
    expect(changes, hasLength(1));
    expect(changes.single.channel, isNull);
    expect(changes.single.deltaCodes, isNull);
    expect(store.version, 1);
  });

  test('channel commit emits a channel full change', () {
    final store = EmoteStore();
    final changes = <EmoteChange>[];
    store.addListener(changes.add);

    final applied = store.commitChannel(
      'ch',
      store.channelEpoch('ch'),
      ChannelEmoteFetch(
        byProvider: {
          EmoteType.bttv: [_emote('c1', 'Chan')],
        },
      ),
    );

    expect(applied, isTrue);
    expect(changes.single.channel, 'ch');
    expect(changes.single.deltaCodes, isNull);
    expect(store.version, 1);
  });

  test('7TV delta emits codes without advancing the version', () {
    final store = EmoteStore();
    final changes = <EmoteChange>[];
    store.addListener(changes.add);

    store.updateSevenTvEmotes(
      'ch',
      added: [_emote('a', 'Alpha', type: EmoteType.sevenTv)],
    );

    expect(changes.single.channel, 'ch');
    expect(changes.single.deltaCodes, {'Alpha'});
    expect(store.version, 0);

    // A full channel refetch bumps the version and clears the delta flag.
    store.commitChannel(
      'ch',
      store.channelEpoch('ch'),
      ChannelEmoteFetch(
        byProvider: {
          EmoteType.bttv: [_emote('b', 'Bravo')],
        },
      ),
    );
    expect(store.version, 1);
    expect(changes.last.deltaCodes, isNull);
  });

  test('emoteStateProvider reflects store mutations', () {
    final store = EmoteStore();
    final container = ProviderContainer(
      overrides: [emoteStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    final seen = <EmoteState>[];
    container.listen(
      emoteStateProvider,
      (_, next) => seen.add(next),
      fireImmediately: true,
    );

    store.commitGlobal(
      store.globalEpoch,
      GlobalEmoteFetch(
        byProvider: {
          EmoteType.bttv: [_emote('g1', 'Global')],
        },
      ),
    );

    expect(seen.last.change?.channel, isNull);
    expect(seen.last.version, 1);
  });

  test('global commit resolves global emotes with no channel catalog', () {
    final store = EmoteStore();

    final applied = store.commitGlobal(
      store.globalEpoch,
      GlobalEmoteFetch(
        byProvider: {
          EmoteType.bttv: [_emote('g1', 'Global')],
        },
      ),
    );

    expect(applied, isTrue);
    expect(store.hasGlobalCache, isTrue);
    final lookup = store.byCode('no-catalog-channel');
    expect(lookup, isNotNull);
    expect(lookup!.byCode['Global']?.id, 'g1');
  });

  test('unlocks alone do not mark the global cache attempted', () {
    final store = EmoteStore();
    final unlock = _emote('u1', 'PrimePride', type: EmoteType.twitch);

    final lookup = store.byCode('no-catalog-channel', unlocks: [unlock]);

    expect(lookup?.byCode['PrimePride']?.id, 'u1');
    expect(store.hasGlobalCache, isFalse);
  });

  test('pre-resolve 7TV deltas cannot overwrite a later full commit', () {
    final store = EmoteStore();
    store.updateSevenTvEmotes(
      'ch',
      added: [_emote('a', 'Alpha', type: EmoteType.sevenTv)],
    );
    store.updateSevenTvEmotes(
      'ch',
      added: [_emote('b', 'Bravo', type: EmoteType.sevenTv)],
    );

    store.commitChannel(
      'ch',
      store.channelEpoch('ch'),
      ChannelEmoteFetch(
        byProvider: {
          EmoteType.sevenTv: [
            _emote('a', 'Alpha', type: EmoteType.sevenTv),
            _emote('b', 'Bravo', type: EmoteType.sevenTv),
            _emote('c', 'Charlie', type: EmoteType.sevenTv),
          ],
        },
      ),
    );

    expect(store.byCode('ch')!.suggestions.map((e) => e.code).toList(), [
      'Alpha',
      'Bravo',
      'Charlie',
    ]);
  });

  test('emoteById resolves the account-unlock overlay', () {
    final store = EmoteStore();
    final unlock = _emote('u1', 'PrimePride', type: EmoteType.twitch);

    expect(store.emoteById('u1', unlocks: [unlock])?.code, 'PrimePride');
  });
}
