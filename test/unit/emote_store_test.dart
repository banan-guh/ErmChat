import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/emotes/emote_catalog.dart';
import 'package:ermchat/services/emote_fetcher.dart';
import 'package:ermchat/services/emote_store.dart';
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

  test('a live 7TV add reports the code for additive healing', () {
    final store = EmoteStore();
    final changes = <EmoteChange>[];
    store.addListener(changes.add);
    store.updateSevenTvEmotes(
      'ch',
      added: [_emote('a', 'Alpha', type: EmoteType.sevenTv)],
    );
    changes.clear();

    store.updateSevenTvEmotes(
      'ch',
      added: [_emote('b', 'Bravo', type: EmoteType.sevenTv)],
    );

    expect(changes.single.addedCodes, {'Bravo'});
    expect(changes.single.deadIds, isNull);
  });

  test('markDead strips the emote and reports it', () {
    final store = EmoteStore();
    final changes = <EmoteChange>[];
    store.addListener(changes.add);
    store.updateSevenTvEmotes(
      'ch',
      added: [_emote('a', 'Alpha', type: EmoteType.sevenTv)],
    );
    expect(store.byCode('ch')!.byCode, contains('Alpha'));

    store.markDead(['a']);

    expect(store.deadIds, contains('a'));
    expect(store.byCode('ch')!.byCode, isNot(contains('Alpha')));
    expect(changes.last.deadIds, {'a'});
    expect(store.emoteById('a'), isNull);
  });

  test('dead ids stay out of cache seeds, full commits and live deltas', () {
    final store = EmoteStore();
    addTearDown(store.dispose);
    final dead = _emote('dead', 'Dead', type: EmoteType.sevenTv);
    final seeded = _emote('seeded', 'Seeded', type: EmoteType.sevenTv);
    final committed = _emote('committed', 'Committed', type: EmoteType.sevenTv);
    final channelSeed = _emote(
      'channel-seed',
      'ChannelSeed',
      type: EmoteType.sevenTv,
    );
    final channelCommit = _emote(
      'channel-commit',
      'ChannelCommit',
      type: EmoteType.sevenTv,
    );
    final delta = _emote('delta', 'Delta', type: EmoteType.sevenTv);
    store.markDead(['dead']);

    expect(
      store.seedGlobalFromCache(
        store.globalEpoch,
        EmoteCatalog(sevenTvGlobal: [dead, seeded]),
      ),
      isTrue,
    );
    expect(store.byCode('ch')!.byCode.keys, ['Seeded']);

    expect(
      store.commitGlobal(
        store.globalEpoch,
        GlobalEmoteFetch(
          byProvider: {
            EmoteType.sevenTv: [dead, committed],
          },
        ),
      ),
      isTrue,
    );
    expect(store.byCode('ch')!.byCode.keys, ['Committed']);

    store.seedChannelFromCache(
      'ch',
      EmoteCatalog(sevenTvChannel: [dead, channelSeed]),
      const [],
    );
    expect(
      store.byCode('ch')!.byCode.keys,
      containsAll(['Committed', 'ChannelSeed']),
    );
    expect(store.byCode('ch')!.byCode, isNot(contains('Dead')));

    expect(
      store.commitChannel(
        'ch',
        store.channelEpoch('ch'),
        ChannelEmoteFetch(
          byProvider: {
            EmoteType.sevenTv: [dead, channelCommit],
          },
        ),
      ),
      isTrue,
    );
    expect(
      store.byCode('ch')!.byCode.keys,
      containsAll(['Committed', 'ChannelCommit']),
    );
    expect(store.byCode('ch')!.byCode, isNot(contains('Dead')));

    expect(store.updateSevenTvEmotes('ch', added: [dead, delta]), isEmpty);
    expect(
      store.byCode('ch')!.byCode.keys,
      containsAll(['Committed', 'ChannelCommit', 'Delta']),
    );
    expect(store.byCode('ch')!.byCode, isNot(contains('Dead')));
  });

  // An early provider marking the catalog complete would freeze rows baked
  // before the rest landed, and they would never heal.
  test('an early provider shows emotes without completing the catalog', () {
    final store = EmoteStore();
    store.commitGlobal(store.globalEpoch, const GlobalEmoteFetch());
    final early = ChannelEmoteFetch(
      byProvider: {
        EmoteType.bttv: [_emote('b', 'Bravo')],
      },
    );

    store.commitChannel('ch', store.channelEpoch('ch'), early, partial: true);
    expect(store.channelCatalog('ch'), isNotNull);
    expect(store.catalogComplete('ch'), isFalse);

    store.commitChannel('ch', store.channelEpoch('ch'), early);
    expect(store.catalogComplete('ch'), isTrue);
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

  test('a channel resolves subs stored under other channels', () {
    final store = EmoteStore();
    expect(store.byCode('late')?.byCode.containsKey('SubA'), isNot(true));

    store.storeUserTwitchEmotes({
      'a': [_lockedTwitchSub('s1', 'SubA')],
      'b': [_followerEmote('f1', 'FollowB', 'b')],
    });
    final lookup = store.byCode('late');
    expect(lookup?.byCode.containsKey('SubA'), isTrue);
    expect(lookup?.byCode.containsKey('FollowB'), isFalse);
    expect(store.byCode('b')?.byCode.containsKey('FollowB'), isTrue);
  });

  test('public channel followers stay out of other channels and subs', () {
    final store = EmoteStore();
    store.commitChannel(
      'a',
      store.channelEpoch('a'),
      ChannelEmoteFetch(
        byProvider: {
          EmoteType.twitch: [
            _followerEmote('f1', 'FollowA', 'a'),
            _lockedTwitchSub('s1', 'SubA'),
          ],
        },
      ),
    );

    expect(store.byCode('a')?.byCode.containsKey('FollowA'), isTrue);
    expect(store.byCode('a')?.byCode.containsKey('SubA'), isTrue);
    expect(store.byCode('b')?.byCode.containsKey('FollowA'), isFalse);
    expect(store.byCode('b')?.byCode.containsKey('SubA'), isTrue);
    expect(
      store.sendableEmotes('b').map((e) => e.code),
      isNot(contains('FollowA')),
      reason: 'autocomplete must not suggest another channel follower',
    );
    final subs = store.subsGrouped(pinnedChannel: 'b');
    expect(subs.values.expand((e) => e).map((e) => e.code), contains('SubA'));
    expect(
      subs.values.expand((e) => e).map((e) => e.code),
      isNot(contains('FollowA')),
    );
  });

  test('shared subs follow a bits commit and an authoritative empty fetch', () {
    final store = EmoteStore();
    expect(store.byCode('late')?.byCode.containsKey('Bits'), isNot(true));

    store.commitChannel(
      'a',
      store.channelEpoch('a'),
      ChannelEmoteFetch(
        byProvider: {
          EmoteType.twitch: [
            Emote(
              id: 'b1',
              code: 'Bits',
              meta: const TwitchMeta(kind: TwitchEmoteKind.bits),
              scales: {EmoteScale.medium: 'https://example.com/b1.png'},
              scope: EmoteScope.channel,
            ),
          ],
        },
      ),
    );
    expect(
      store.byCode('late')?.byCode.containsKey('Bits'),
      isTrue,
      reason: 'a cached lookup of another channel must see the new bits',
    );

    store.storeUserTwitchEmotes({
      'a': [_lockedTwitchSub('s1', 'SubA')],
    });
    expect(store.byCode('late')?.byCode.containsKey('SubA'), isTrue);

    store.storeUserTwitchEmotes({'a': const []});
    expect(
      store.byCode('late')?.byCode.containsKey('SubA'),
      isTrue,
      reason: 'a partial or reconnect store must not wipe valid subs',
    );
    store.storeUserTwitchEmotes({'a': const []}, authoritative: true);
    expect(store.byCode('late')?.byCode.containsKey('SubA'), isFalse);
    expect(store.byCode('late')?.byCode.containsKey('Bits'), isTrue);
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

  test('account switch drops the old 7TV connection indexes', () {
    final store = EmoteStore();
    store.setSevenTvConnectionIndex('ch', 3);
    expect(store.getSevenTvConnectionIndex('ch'), 3);

    store.clearAccountScopedState();

    expect(
      store.getSevenTvConnectionIndex('ch'),
      isNull,
      reason: 'the index belongs to the previous 7TV user connection list',
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

    test(
      'rename replaces the pooled instance, baked rows keep the old one',
      () {
        final store = EmoteStore();
        commitChannel(store, 'ch', [sevenTv('a', 'Alpha')]);
        final before = store.byCode('ch')!.byCode['Alpha']!;

        store.updateSevenTvEmotes(
          'ch',
          renamed: {'a': (newName: 'Beta', oldName: 'Alpha')},
          renamedBaseNames: {'a': 'Alpha'},
        );

        final after = store.byCode('ch')!.byCode['Beta']!;
        expect(after.id, 'a');
        expect(identical(after, before), isFalse);
        expect(identical(store.emoteById('a'), after), isTrue);
        expect(before.code, 'Alpha');
        expect(after.baseName, 'Alpha', reason: 'the rename set the alias');

        store.updateSevenTvEmotes(
          'ch',
          renamed: {'a': (newName: 'Alpha', oldName: 'Beta')},
          renamedBaseNames: {'a': null},
        );
        expect(
          store.byCode('ch')!.byCode['Alpha']!.baseName,
          isNull,
          reason: 'renaming back to the base drops the alias',
        );
      },
    );
  });
}
