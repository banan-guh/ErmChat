import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/emotes/emote_catalog.dart';
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
      scales: {EmoteScale.medium: 'https://example.com/$id.png'},
    );

Emote _channelEmote(String id, String code) => Emote(
  id: id,
  code: code,
  meta: const BttvMeta(),
  scales: {EmoteScale.medium: 'https://example.com/$id.png'},
  scope: EmoteScope.channel,
);

Emote _lockedTwitchSub(String id, String code) => Emote(
  id: id,
  code: code,
  meta: const TwitchMeta(kind: TwitchEmoteKind.sub),
  scales: {EmoteScale.medium: 'https://example.com/$id.png'},
  scope: EmoteScope.channel,
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

  test('overlay change keeps the version and is flagged', () {
    final store = EmoteStore();
    store.emitChange(channel: 'ch');
    final before = store.lastChange!.version;
    final changes = <EmoteChange>[];
    void listener(EmoteChange change) => changes.add(change);
    store.addListener(listener);

    store.notifyOverlayChanged();

    store.removeListener(listener);
    expect(changes, hasLength(1));
    expect(changes.single.overlay, isTrue);
    expect(changes.single.channel, isNull);
    expect(changes.single.version, before);
  });

  test(
    'personal-set resolution refresh bumps the version for all consumers',
    () {
      final store = EmoteStore();
      final first = store.byCode('ch', personal: [_emote('p1', 'OldPersonal')]);
      expect(first?.byCode['OldPersonal']?.id, 'p1');

      store.notifyResolutionChanged();

      final second = store.byCode(
        'ch',
        personal: [_emote('p2', 'NewPersonal')],
      );
      expect(second?.byCode['NewPersonal']?.id, 'p2');
      expect(second?.byCode.containsKey('OldPersonal'), isFalse);
      expect(store.version, 1);
      expect(store.lastChange?.overlay, isFalse);
    },
  );

  test('foreign resolution refresh bumps the version for all consumers', () {
    final store = EmoteStore();
    final foreign = EmoteLookup(
      byCode: {'Foreign': _emote('f1', 'Foreign')},
      suggestions: [_emote('f1', 'Foreign')],
    );
    final first = store.byCodeForSender('ch', foreign: foreign);
    expect(first?.byCode['Foreign']?.id, 'f1');

    store.notifyResolutionChanged();

    final updatedForeign = EmoteLookup(
      byCode: {'UpdatedForeign': _emote('f2', 'UpdatedForeign')},
      suggestions: [_emote('f2', 'UpdatedForeign')],
    );
    final second = store.byCodeForSender('ch', foreign: updatedForeign);
    expect(second?.byCode['UpdatedForeign']?.id, 'f2');
    expect(store.version, 1);
    expect(store.lastChange?.overlay, isFalse);
  });

  test('config refresh stays overlay-only, visibility bumps the version', () {
    final store = EmoteStore();
    final first = store.byCode('ch', personal: [_emote('p1', 'OldPersonal')]);
    expect(first?.byCode['OldPersonal']?.id, 'p1');

    store.notifyConfigChanged();
    expect(store.version, 0);
    expect(store.lastChange?.overlay, isTrue);
    final second = store.byCode('ch', personal: [_emote('p2', 'NewPersonal')]);
    expect(second?.byCode['NewPersonal']?.id, 'p2');
    expect(second?.byCode.containsKey('OldPersonal'), isFalse);

    store.notifyVisibilityChanged();
    expect(store.version, 1);
    expect(store.lastChange?.overlay, isFalse);
    final third = store.byCode(
      'ch',
      personal: [_emote('p3', 'NewestPersonal')],
    );
    expect(third?.byCode['NewestPersonal']?.id, 'p3');
    expect(third?.byCode.containsKey('NewPersonal'), isFalse);
  });

  test('unchanged subscription restores notify only changed channels', () {
    final store = EmoteStore();
    final changes = <EmoteChange>[];
    store.addListener(changes.add);

    store.storeUserTwitchEmotes({
      'ch': [_emote('s1', 'Sub', type: EmoteType.twitch)],
    });
    expect(changes.map((change) => change.channel), ['ch']);
    expect(changes.every((change) => !change.isGlobal), isTrue);
    expect(store.version, 1);

    store.storeUserTwitchEmotes({
      'ch': [_emote('s1', 'Sub', type: EmoteType.twitch)],
    });
    expect(changes, hasLength(1));
    expect(store.version, 1);

    store.storeUserTwitchEmotes({
      'ch': [_emote('s1', 'FreshSub', type: EmoteType.twitch)],
    });
    expect(changes.map((change) => change.channel), ['ch', 'ch']);
    expect(store.version, 2);
  });

  test('no-op 7TV deltas emit no changes', () {
    final store = EmoteStore();
    final changes = <EmoteChange>[];
    store.addListener(changes.add);

    store.commitChannel(
      'ch',
      store.channelEpoch('ch'),
      ChannelEmoteFetch(
        byProvider: {
          EmoteType.sevenTv: [_emote('a', 'Alpha', type: EmoteType.sevenTv)],
        },
      ),
    );
    final version = store.version;
    changes.clear();

    final evicted = store.updateSevenTvEmotes(
      'ch',
      added: [_emote('a', 'Alpha', type: EmoteType.sevenTv)],
      removedIds: const ['missing'],
      renamed: const {'missing': (newName: 'X', oldName: 'Y')},
    );

    expect(evicted, isEmpty);
    expect(changes, isEmpty);
    expect(store.version, version);
  });

  test('channel tab slices the same base mixer chat renders from', () {
    final store = EmoteStore();
    store.commitChannel(
      'ch',
      store.channelEpoch('ch'),
      ChannelEmoteFetch(
        byProvider: {
          EmoteType.bttv: [_channelEmote('c1', 'ChanOnly')],
          EmoteType.twitch: [_lockedTwitchSub('t1', 'LockedSub')],
        },
      ),
    );

    final base = store.byCode('ch')!;
    final tab = store.channelTabEmotes('ch');

    expect(base.byCode['ChanOnly']?.id, 'c1');
    expect(tab.map((e) => e.code), contains('ChanOnly'));
    // Same objects, not copies: one supply for chat, typing, and picker.
    expect(
      tab.singleWhere((e) => e.code == 'ChanOnly'),
      same(base.byCode['ChanOnly']),
    );
    expect(
      tab.map((e) => e.code),
      isNot(contains('LockedSub')),
      reason: 'locked Twitch renders by tag only, never as a tab pick',
    );
  });

  test('channel tab respects the same visibility as chat', () {
    final store = EmoteStore();
    store.commitChannel(
      'ch',
      store.channelEpoch('ch'),
      ChannelEmoteFetch(
        byProvider: {
          EmoteType.bttv: [_channelEmote('c1', 'ChanBttv')],
        },
      ),
    );
    expect(
      store.channelTabEmotes('ch').map((e) => e.code),
      contains('ChanBttv'),
    );

    store.setProviderVisibility({EmoteType.bttv}, false);
    store.notifyVisibilityChanged();

    expect(store.byCode('ch')?.byCode.containsKey('ChanBttv'), isFalse);
    expect(store.channelTabEmotes('ch'), isEmpty);
  });
}
