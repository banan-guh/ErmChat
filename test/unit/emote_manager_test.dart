import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/models/twitch_message.dart';

GenericEmote _e({
  required String id,
  required String code,
  EmoteType type = EmoteType.bttv,
  bool isZeroWidth = false,
  EmoteScope scope = EmoteScope.global,
  String? ownerChannel,
  double relativeScale = 1.0,
}) => GenericEmote(
  id: id,
  code: code,
  type: type,
  url: 'https://example.com/$id.png',
  isZeroWidth: isZeroWidth,
  scope: scope,
  ownerChannel: ownerChannel,
  relativeScale: relativeScale,
);

void main() {
  group('GenericEmote', () {
    test('creates with required fields', () {
      final e = _e(id: '1', code: 'Kappa');
      expect(e.id, '1');
      expect(e.code, 'Kappa');
      expect(e.type, EmoteType.bttv);
      expect(e.isZeroWidth, false);
      expect(e.scope, EmoteScope.global);
      expect(e.ownerChannel, isNull);
    });

    test('creates with zero-width flag', () {
      final e = _e(id: '2', code: 'EZ', isZeroWidth: true);
      expect(e.isZeroWidth, true);
    });

    test('creates with channel scope', () {
      final e = _e(
        id: '3',
        code: 'Kappa',
        scope: EmoteScope.channel,
        ownerChannel: 'forsen',
      );
      expect(e.scope, EmoteScope.channel);
      expect(e.ownerChannel, 'forsen');
    });
  });

  group('GenericEmote JSON round-trip', () {
    test('serializes and deserializes', () {
      final original = _e(
        id: 'test-id',
        code: 'TestEmote',
        type: EmoteType.sevenTv,
        isZeroWidth: true,
        scope: EmoteScope.channel,
        ownerChannel: 'testuser',
        relativeScale: 0.625,
      );
      final json = original.toJson();
      final restored = GenericEmote.fromJson(json);
      expect(restored.id, original.id);
      expect(restored.code, original.code);
      expect(restored.type, original.type);
      expect(restored.isZeroWidth, original.isZeroWidth);
      expect(restored.scope, original.scope);
      expect(restored.ownerChannel, original.ownerChannel);
      expect(restored.url, original.url);
      expect(restored.relativeScale, original.relativeScale);
    });

    test('deserializes with defaults for missing fields', () {
      final json = <String, dynamic>{
        'id': 'test-id',
        'code': 'TestEmote',
        'type': 0,
        'url': 'https://example.com/test.png',
      };
      final restored = GenericEmote.fromJson(json);
      expect(restored.id, 'test-id');
      expect(restored.isZeroWidth, false);
      expect(restored.scope, EmoteScope.global);
      expect(restored.isAnimated, false);
      expect(restored.ownerChannel, isNull);
      expect(restored.relativeScale, 1.0);
    });

    test('handles all EmoteType values', () {
      for (final type in EmoteType.values) {
        final e = GenericEmote(
          id: '${type.index}',
          code: 'Test',
          type: type,
          url: '',
        );
        final json = e.toJson();
        final restored = GenericEmote.fromJson(json);
        expect(restored.type, type);
      }
    });

    test('handles all EmoteScope values', () {
      for (final scope in EmoteScope.values) {
        final e = GenericEmote(
          id: '1',
          code: 'Test',
          type: EmoteType.bttv,
          url: '',
          scope: scope,
        );
        final json = e.toJson();
        final restored = GenericEmote.fromJson(json);
        expect(restored.scope, scope);
      }
    });
  });

  group('EmotePosition', () {
    test('creates with all fields', () {
      final pos = EmotePosition(
        emoteId: '123',
        startIndex: 0,
        endIndex: 5,
        emoteCode: 'Kappa',
      );
      expect(pos.emoteId, '123');
      expect(pos.startIndex, 0);
      expect(pos.endIndex, 5);
      expect(pos.emoteCode, 'Kappa');
    });
  });
}
