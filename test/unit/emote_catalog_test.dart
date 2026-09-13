import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/emotes/emote.dart';
import 'package:ermchat/emotes/emote_catalog.dart';
import 'package:ermchat/emotes/emote_meta.dart';

Emote _emote(
  String id,
  String code,
  EmoteType type, {
  EmoteScope scope = EmoteScope.global,
  bool unlisted = false,
}) => Emote(
  id: id,
  code: code,
  meta: switch (type) {
    EmoteType.twitch => const TwitchMeta(kind: TwitchEmoteKind.standard),
    EmoteType.bttv => const BttvMeta(),
    EmoteType.ffz => const FfzMeta(),
    EmoteType.sevenTv => SevenTvMeta(unlisted: unlisted),
  },
  url: 'https://example.com/$id.png',
  scope: scope,
);

void main() {
  group('Emote.copyWith', () {
    test('renames the code and preserves the meta and assets', () {
      final original = Emote(
        id: 'e1',
        code: 'OldName',
        meta: const SevenTvMeta(
          creator: 'Creator',
          baseName: 'Base',
          unlisted: true,
          relativeScale: 0.625,
        ),
        url: 'https://example.com/2x.webp',
        url1x: 'https://example.com/1x.webp',
        url3x: 'https://example.com/3x.webp',
        isAnimated: true,
        isZeroWidth: true,
        scope: EmoteScope.channel,
      );

      final renamed = original.copyWith(code: 'NewName');

      expect(renamed.code, 'NewName');
      expect(renamed.id, 'e1');
      expect(renamed.meta, same(original.meta));
      expect(renamed.url, original.url);
      expect(renamed.url1x, original.url1x);
      expect(renamed.url3x, original.url3x);
      expect(renamed.isAnimated, isTrue);
      expect(renamed.isZeroWidth, isTrue);
      expect(renamed.scope, EmoteScope.channel);
    });

    test('without a code keeps the original', () {
      final original = _emote('e1', 'Keep', EmoteType.bttv);
      expect(original.copyWith().code, 'Keep');
    });
  });

  group('mergeEmoteLookup precedence', () {
    test('channel scope beats global scope', () {
      final global = EmoteCatalog(
        twitchGlobal: [_emote('g', 'Clash', EmoteType.twitch)],
      );
      final channel = EmoteCatalog(
        twitchChannel: [
          _emote('c', 'Clash', EmoteType.twitch, scope: EmoteScope.channel),
        ],
      );

      final lookup = mergeEmoteLookup(global: global, channel: channel);

      expect(lookup.byCode['Clash']!.id, 'c');
    });

    test('within a scope 7TV beats BTTV beats FFZ beats Twitch', () {
      final all = EmoteCatalog(
        twitchGlobal: [_emote('tw', 'Clash', EmoteType.twitch)],
        ffzGlobal: [_emote('ffz', 'Clash', EmoteType.ffz)],
        bttvGlobal: [_emote('bttv', 'Clash', EmoteType.bttv)],
        sevenTvGlobal: [_emote('7tv', 'Clash', EmoteType.sevenTv)],
      );
      expect(mergeEmoteLookup(global: all).byCode['Clash']!.id, '7tv');

      final no7tv = EmoteCatalog(
        twitchGlobal: all.twitchGlobal,
        ffzGlobal: all.ffzGlobal,
        bttvGlobal: all.bttvGlobal,
      );
      expect(mergeEmoteLookup(global: no7tv).byCode['Clash']!.id, 'bttv');

      final noBttv = EmoteCatalog(
        twitchGlobal: all.twitchGlobal,
        ffzGlobal: all.ffzGlobal,
      );
      expect(mergeEmoteLookup(global: noBttv).byCode['Clash']!.id, 'ffz');

      final twitchOnly = EmoteCatalog(twitchGlobal: all.twitchGlobal);
      expect(mergeEmoteLookup(global: twitchOnly).byCode['Clash']!.id, 'tw');
    });

    test('personal 7TV emotes fill gaps but base codes win conflicts', () {
      final global = EmoteCatalog(
        twitchGlobal: [_emote('g', 'Shared', EmoteType.twitch)],
      );
      final personal = [
        _emote('p1', 'Mine', EmoteType.sevenTv, scope: EmoteScope.personal),
        _emote('p2', 'Shared', EmoteType.sevenTv, scope: EmoteScope.personal),
      ];

      final lookup = mergeEmoteLookup(global: global, personal: personal);

      expect(lookup.byCode['Mine']!.id, 'p1');
      expect(lookup.byCode['Shared']!.id, 'g');
    });

    test('account unlocks replace the matching Twitch global', () {
      final global = EmoteCatalog(
        twitchGlobal: [_emote('old', 'PrimePride', EmoteType.twitch)],
      );
      final unlock = Emote(
        id: 'old',
        code: 'PrimePride',
        meta: const TwitchMeta(kind: TwitchEmoteKind.standard),
        url: 'https://example.com/unlock.png',
      );

      final lookup = mergeEmoteLookup(global: global, accountUnlocks: [unlock]);

      expect(lookup.byCode['PrimePride']!.url, unlock.url);
    });

    test('disabled providers and hidden unlisted 7TV are filtered', () {
      final global = EmoteCatalog(
        bttvGlobal: [_emote('b', 'BttvE', EmoteType.bttv)],
        sevenTvGlobal: [
          _emote('s', 'Secret', EmoteType.sevenTv, unlisted: true),
          _emote('v', 'Visible', EmoteType.sevenTv),
        ],
      );

      final hidden = mergeEmoteLookup(global: global);
      expect(hidden.byCode.keys, ['BttvE', 'Visible']);
      expect(hidden.byCode.containsKey('Secret'), isFalse);

      final disabled = mergeEmoteLookup(
        global: global,
        disabledProviders: {EmoteType.bttv},
      );
      expect(disabled.byCode.containsKey('BttvE'), isFalse);

      final allowed = mergeEmoteLookup(global: global, allowUnlisted7tv: true);
      expect(allowed.byCode.keys, containsAll(['Secret', 'Visible']));
    });

    test('suggestions are sorted by code', () {
      final global = EmoteCatalog(
        bttvGlobal: [
          _emote('1', 'Zeta', EmoteType.bttv),
          _emote('2', 'Alpha', EmoteType.bttv),
          _emote('3', 'Mid', EmoteType.bttv),
        ],
      );
      expect(mergeEmoteLookup(global: global).suggestions.map((e) => e.code), [
        'Alpha',
        'Mid',
        'Zeta',
      ]);
    });
  });
}
