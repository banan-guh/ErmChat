import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/emotes/emote_meta.dart';
import 'package:ermchat/providers/emote_store_providers.dart';
import 'package:ermchat/services/emote_fetch.dart';
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
}
