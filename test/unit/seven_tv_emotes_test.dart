import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/emote_providers/seven_tv_emotes.dart';

Map<String, dynamic> _host(String name, {int width = 32, int height = 32}) => {
  'url': '//cdn.7tv.app/emote/1/1x',
  'files': [
    {'name': name, 'format': 'WEBP', 'width': width, 'height': height},
  ],
};

void main() {
  group('SevenTvEmoteProvider', () {
    test('parses a plain emote without baseName', () {
      final emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-1',
        'name': 'PogChamp',
        'data': {'name': 'PogChamp', 'host': _host('1x.webp')},
      });
      expect(emote, isNotNull);
      expect(emote!.id, 'emote-1');
      expect(emote.code, 'PogChamp');
      expect(emote.baseName, isNull);
      expect(emote.type, EmoteType.sevenTv);
    });

    test('records baseName for alias emotes (name != data.name)', () {
      final emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-2',
        'name': 'ALIAS',
        'data': {'name': 'BaseEmote', 'host': _host('1x.webp')},
      });
      expect(emote, isNotNull);
      expect(emote!.code, 'ALIAS');
      expect(emote.baseName, 'BaseEmote');
    });

    test('parses owner display_name into ownerChannel', () {
      final emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-3',
        'name': 'Cope',
        'data': {
          'name': 'Cope',
          'owner': {'display_name': 'CopeQueen'},
          'host': _host('1x.webp'),
        },
      });
      expect(emote, isNotNull);
      expect(emote!.ownerChannel, 'CopeQueen');
    });

    test('marks channel emotes with channel scope', () {
      final emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-4',
        'name': 'xqcL',
        'data': {'name': 'xqcL', 'host': _host('1x.webp')},
      }, channel: true);
      expect(emote, isNotNull);
      expect(emote!.scope, EmoteScope.channel);
    });

    test('parses zero-width flag', () {
      final emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-5',
        'name': 'EZ',
        'data': {'name': 'EZ', 'flags': 1 << 8, 'host': _host('1x.webp')},
      });
      expect(emote, isNotNull);
      expect(emote!.isZeroWidth, isTrue);
    });

    test('picks 2x for chat and largest for large surfaces', () {
      final emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-6',
        'name': 'Size',
        'data': {
          'name': 'Size',
          'host': {
            'url': '//cdn.7tv.app/emote/size',
            'files': [
              {'name': '1x.webp', 'format': 'WEBP', 'width': 32, 'height': 32},
              {'name': '2x.webp', 'format': 'WEBP', 'width': 64, 'height': 64},
              {'name': '3x.webp', 'format': 'WEBP', 'width': 96, 'height': 96},
            ],
          },
        },
      });
      expect(emote, isNotNull);
      expect(emote!.url, 'https://cdn.7tv.app/emote/size/2x.webp');
      expect(emote.urlLarge, 'https://cdn.7tv.app/emote/size/3x.webp');
      expect(emote.relativeScale, 1.0);
    });

    test('falls back to smallest file when no 2x tier exists', () {
      final emote = SevenTvEmoteProvider.parseSingleEmote({
        'id': 'emote-7',
        'name': 'Small',
        'data': {'name': 'Small', 'host': _host('1x.webp')},
      });
      expect(emote, isNotNull);
      expect(emote!.url, 'https://cdn.7tv.app/emote/1/1x/1x.webp');
      expect(emote.urlLarge, 'https://cdn.7tv.app/emote/1/1x/1x.webp');
    });
  });
}
