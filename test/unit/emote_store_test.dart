import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/emotes/emote_catalog.dart';
import 'package:ermchat/models/twitch_message.dart';
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

Emote _followerEmote(String id, String code, String owner) => Emote(
  id: id,
  code: code,
  meta: TwitchMeta(kind: TwitchEmoteKind.follower, ownerChannel: owner),
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

  test('state-cleared emit bumps the version with a global change', () {
    final store = EmoteStore();
    store.emitChange(channel: 'ch');
    final before = store.lastChange!.version;
    final changes = <EmoteChange>[];
    void listener(EmoteChange change) => changes.add(change);
    store.addListener(listener);

    store.notifyCatalogChanged();

    store.removeListener(listener);
    expect(changes, hasLength(1));
    expect(changes.single.channel, isNull);
    expect(changes.single.version, before + 1);
  });

  test('personal-set refresh clears derived lookups and bumps the version', () {
    final store = EmoteStore();
    final first = store.byCode('ch', personal: [_emote('p1', 'OldPersonal')]);
    expect(first?.byCode['OldPersonal']?.id, 'p1');

    store.notifyCatalogChanged();

    final second = store.byCode('ch', personal: [_emote('p2', 'NewPersonal')]);
    expect(second?.byCode['NewPersonal']?.id, 'p2');
    expect(second?.byCode.containsKey('OldPersonal'), isFalse);
    expect(store.version, 1);
  });

  test('foreign refresh clears derived lookups and bumps the version', () {
    final store = EmoteStore();
    final foreign = EmoteLookup(
      byCode: {'Foreign': _emote('f1', 'Foreign')},
      suggestions: [_emote('f1', 'Foreign')],
    );
    final first = store.byCodeForSender('ch', foreign: foreign);
    expect(first?.byCode['Foreign']?.id, 'f1');

    store.notifyCatalogChanged();

    final updatedForeign = EmoteLookup(
      byCode: {'UpdatedForeign': _emote('f2', 'UpdatedForeign')},
      suggestions: [_emote('f2', 'UpdatedForeign')],
    );
    final second = store.byCodeForSender('ch', foreign: updatedForeign);
    expect(second?.byCode['UpdatedForeign']?.id, 'f2');
    expect(store.version, 1);
  });

  test('config refresh leaves the version, visibility bumps it', () {
    final store = EmoteStore();
    final first = store.byCode('ch', personal: [_emote('p1', 'OldPersonal')]);
    expect(first?.byCode['OldPersonal']?.id, 'p1');

    store.notifyConfigChanged();
    expect(store.version, 0);
    final second = store.byCode('ch', personal: [_emote('p2', 'NewPersonal')]);
    expect(second?.byCode['NewPersonal']?.id, 'p2');
    expect(second?.byCode.containsKey('OldPersonal'), isFalse);

    store.notifyVisibilityChanged();
    expect(store.version, 1);
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

  test('subsGrouped keeps only the focused channel followers', () {
    final store = EmoteStore();
    store.storeUserTwitchEmotes({
      'chanA': [
        _followerEmote('fA', 'FolA', 'chanA'),
        _lockedTwitchSub('sA', 'SubA'),
      ],
      'chanB': [
        _followerEmote('fB', 'FolB', 'chanB'),
        _lockedTwitchSub('sB', 'SubB'),
      ],
    });

    final focusedA = store.subsGrouped(pinnedChannel: 'chanA');
    expect(
      focusedA['chanA']!.map((e) => e.code),
      containsAll(['FolA', 'SubA']),
    );
    expect(focusedA['chanB']!.map((e) => e.code), contains('SubB'));
    expect(focusedA['chanB']!.map((e) => e.code), isNot(contains('FolB')));

    final focusedB = store.subsGrouped(pinnedChannel: 'chanB');
    expect(
      focusedB['chanB']!.map((e) => e.code),
      containsAll(['FolB', 'SubB']),
    );
    expect(focusedB['chanA']!.map((e) => e.code), contains('SubA'));
    expect(focusedB['chanA']!.map((e) => e.code), isNot(contains('FolA')));
  });

  test('subsGrouped without focus hides all followers', () {
    final store = EmoteStore();
    store.storeUserTwitchEmotes({
      'chanA': [
        _followerEmote('fA', 'FolA', 'chanA'),
        _lockedTwitchSub('sA', 'SubA'),
      ],
    });

    for (final grouped in [
      store.subsGrouped(),
      store.subsGrouped(pinnedChannel: ''),
    ]) {
      expect(
        grouped.values.expand((e) => e).map((e) => e.code),
        contains('SubA'),
      );
      expect(
        grouped.values.expand((e) => e).map((e) => e.code),
        isNot(contains('FolA')),
      );
    }
  });

  test('subsGrouped matches follower owners case-insensitively', () {
    final store = EmoteStore();
    store.storeUserTwitchEmotes({
      'chanA': [_followerEmote('fA', 'FolA', 'chanA')],
    });

    final grouped = store.subsGrouped(pinnedChannel: 'CHANA');
    expect(
      grouped.values.expand((e) => e).map((e) => e.code),
      contains('FolA'),
    );
  });

  group('canonical pool', () {
    Emote sevenTv(String id, String code) => Emote(
      id: id,
      code: code,
      meta: const SevenTvMeta(),
      scales: {EmoteScale.medium: 'https://example.com/$id.png'},
      scope: EmoteScope.channel,
    );

    void commitChannel(EmoteStore store, String channel, List<Emote> emotes) {
      store.commitChannel(
        channel,
        store.channelEpoch(channel),
        ChannelEmoteFetch(byProvider: {EmoteType.sevenTv: emotes}),
      );
    }

    test('repeated lookups share identical instances', () {
      final store = EmoteStore();
      commitChannel(store, 'ch', [sevenTv('a', 'Alpha')]);

      final first = store.byCode('ch')!;
      final second = store.byCode('ch')!;
      expect(identical(first, second), isTrue);
      expect(identical(first.byCode['Alpha'], second.byCode['Alpha']), isTrue);
      expect(
        identical(
          first.suggestions.singleWhere((e) => e.code == 'Alpha'),
          first.byCode['Alpha'],
        ),
        isTrue,
      );
    });

    test('global tab and merged lookup share the global instance', () {
      final store = EmoteStore();
      store.commitGlobal(
        store.globalEpoch,
        GlobalEmoteFetch(
          byProvider: {
            EmoteType.bttv: [_emote('g1', 'Global')],
          },
        ),
      );

      final merged = store.byCode('ch')!;
      final byProvider = store.globalEmotesByProvider();
      expect(
        identical(
          byProvider.values
              .expand((e) => e)
              .singleWhere((e) => e.code == 'Global'),
          merged.byCode['Global'],
        ),
        isTrue,
      );
    });

    test('subs tab cells are identical to the merged locked entries', () {
      final store = EmoteStore();
      store.storeUserTwitchEmotes({
        'ch': [_lockedTwitchSub('s1', 'Sub')],
      });

      final merged = store.byCode('ch')!;
      final subs = store.subscriberEmotesByChannel()['ch']!;
      expect(identical(subs.single, merged.byCode['Sub']), isTrue);
      expect(identical(store.emoteById('s1'), merged.byCode['Sub']), isTrue);
    });

    test('fallback synthesis interns: unknown tag id resolves identically', () {
      final store = EmoteStore();
      commitChannel(store, 'ch', [sevenTv('a', 'Alpha')]);
      final found = store.matchEmotes(
        channel: 'ch',
        text: 'hello',
        positions: const [
          EmotePosition(
            emoteId: 't1',
            startIndex: 0,
            endIndex: 5,
            emoteCode: 'Hello',
          ),
        ],
      );

      expect(found.single.id, 't1');
      expect(identical(store.emoteById('t1'), found.single), isTrue);
    });

    test(
      'rename replaces the pooled instance, baked rows keep the old one',
      () {
        final store = EmoteStore();
        commitChannel(store, 'ch', [sevenTv('a', 'Alpha')]);
        final before = store.byCode('ch')!.byCode['Alpha']!;

        store.updateSevenTvEmotes(
          'ch',
          renamed: {'a': (newName: 'Beta', oldName: 'Alpha')},
        );

        final after = store.byCode('ch')!.byCode['Beta']!;
        expect(after.id, 'a');
        expect(identical(after, before), isFalse);
        expect(identical(store.emoteById('a'), after), isTrue);
        expect(before.code, 'Alpha');
      },
    );

    test('overlay instances pool with catalog instances', () {
      final store = EmoteStore();
      final personal = sevenTv('p1', 'Mine');
      final lookup = store.byCode('ch', personal: [personal])!;
      // First sight pools the very object: owner lists and lookups converge.
      expect(identical(lookup.byCode['Mine'], personal), isTrue);
      expect(
        identical(
          store.emoteById('p1', personal: [personal]),
          lookup.byCode['Mine'],
        ),
        isTrue,
      );
    });

    test('tokenize intern parameter canonicalizes outputs', () {
      final store = EmoteStore();
      commitChannel(store, 'ch', [sevenTv('a', 'Alpha')]);
      final map = store.byCode('ch')!.byCode;

      final tokens = EmoteStore.tokenize(
        text: 'Alpha',
        positions: null,
        byCode: map,
        intern: store.intern,
      );
      expect(identical(tokens.single.emote, map['Alpha']), isTrue);
    });

    test('emoteById converges through the index without a prior lookup', () {
      final store = EmoteStore();
      commitChannel(store, 'ch', [sevenTv('a', 'Alpha')]);

      // No byCode call: the lazy index rebuild interns and serves pooled.
      final byId = store.emoteById('a')!;
      expect(identical(byId, store.byCode('ch')!.byCode['Alpha']), isTrue);
    });
  });
}
