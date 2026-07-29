import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/widgets/emote_text.dart';

ChannelEmotes _makeEmotes(Map<String, GenericEmote> byCode) {
  return ChannelEmotes(byCode: byCode, suggestions: byCode.values.toList());
}

GenericEmote _e({
  required String id,
  required String code,
  EmoteType type = EmoteType.bttv,
  bool isZeroWidth = false,
  double relativeScale = 1.0,
}) => GenericEmote(
  id: id,
  code: code,
  type: type,
  url: 'https://example.com/$id.png',
  isZeroWidth: isZeroWidth,
  relativeScale: relativeScale,
);

void main() {
  group('EmoteText.build', () {
    test('plain text with no emotes returns URL-parsed spans', () {
      final spans = EmoteText.build(
        text: 'hello world',
        twitchPositions: null,
        channelEmotes: null,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<TextSpan>());
      expect((spans[0] as TextSpan).text, 'hello world');
    });

    test('plain text with no emote matches returns URL-parsed spans', () {
      final emotes = _makeEmotes(<String, GenericEmote>{});
      final spans = EmoteText.build(
        text: 'hello world',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // Whitespace tokenization splits into: hello, ' ', world
      expect(spans.length, greaterThanOrEqualTo(3));
      expect((spans[0] as TextSpan).text, 'hello');
      expect((spans[1] as TextSpan).text, ' ');
      expect((spans[2] as TextSpan).text, 'world');
    });

    test('single known emote by text match returns WidgetSpan', () {
      final emotes = _makeEmotes({'Kappa': _e(id: '1', code: 'Kappa')});
      final spans = EmoteText.build(
        text: 'Kappa',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
    });

    test('text + emote + text mix returns correct span types', () {
      final emotes = _makeEmotes({'Kappa': _e(id: '1', code: 'Kappa')});
      final spans = EmoteText.build(
        text: 'hi Kappa there',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // Contains at least one WidgetSpan for the emote
      expect(spans.any((s) => s is WidgetSpan), isTrue);
      expect(spans.length, greaterThanOrEqualTo(3));
    });

    test('Twitch emote position overrides text match', () {
      final emotes = _makeEmotes({
        'Kappa': _e(id: '1', code: 'Kappa'),
        'KappaPride': _e(id: '2', code: 'KappaPride', type: EmoteType.twitch),
      });
      final spans = EmoteText.build(
        text: 'KappaPride',
        twitchPositions: [
          EmotePosition(
            emoteId: '2',
            startIndex: 0,
            endIndex: 10,
            emoteCode: 'KappaPride',
          ),
        ],
        channelEmotes: emotes,
      );
      // Should match the Twitch emote (KappaPride), not a text match on Kappa
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
    });

    test('Twitch base emote + BTTV zero-width overlay', () {
      final emotes = _makeEmotes({
        'Sunglasses': _e(
          id: 'tw-1',
          code: 'Sunglasses',
          type: EmoteType.twitch,
        ),
        'EZ': _e(
          id: 'bttv-1',
          code: 'EZ',
          type: EmoteType.bttv,
          isZeroWidth: true,
        ),
      });
      final spans = EmoteText.build(
        text: 'Sunglasses EZ',
        twitchPositions: [
          EmotePosition(
            emoteId: 'tw-1',
            startIndex: 0,
            endIndex: 11,
            emoteCode: 'Sunglasses',
          ),
        ],
        channelEmotes: emotes,
      );
      // Sunglasses (from Twitch positions) should have EZ overlaid on it
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
    });

    test('URL detection in plain text segments', () {
      final emotes = _makeEmotes({'Kappa': _e(id: '1', code: 'Kappa')});
      final spans = EmoteText.build(
        text: 'Kappa check https://example.com',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // Kappa (WidgetSpan) + ' ' + 'check' + ' ' + url (TextSpan with blue style)
      expect(spans.length, greaterThanOrEqualTo(5));
      expect(spans[0], isA<WidgetSpan>());
      expect(spans.last, isA<TextSpan>());
      final urlSpan = spans.last as TextSpan;
      expect(urlSpan.text, 'https://example.com');
      expect(urlSpan.style?.color, Colors.blue);
    });

    test('zero-width emote at start renders standalone', () {
      final emotes = _makeEmotes({
        'EZ': _e(id: '1', code: 'EZ', isZeroWidth: true),
      });
      final spans = EmoteText.build(
        text: 'EZ',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // Zero-width at start with no base should render as standalone WidgetSpan
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
    });

    test('zero-width after plain text breaks chain', () {
      final emotes = _makeEmotes({
        'Kappa': _e(id: '1', code: 'Kappa'),
        'EZ': _e(id: '2', code: 'EZ', isZeroWidth: true),
      });
      final spans = EmoteText.build(
        text: 'hello EZ',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // 'hello' breaks chain, ' ' is space, EZ is standalone
      expect(spans.length, greaterThanOrEqualTo(3));
      expect(spans[0], isA<TextSpan>());
      expect((spans[0] as TextSpan).text, 'hello');
      expect(spans[1], isA<TextSpan>());
      expect(spans.last, isA<WidgetSpan>());
    });

    test('base emote followed by zero-width overlay stacks', () {
      final emotes = _makeEmotes({
        'Kappa': _e(id: '1', code: 'Kappa'),
        'EZ': _e(id: '2', code: 'EZ', isZeroWidth: true),
      });
      final spans = EmoteText.build(
        text: 'Kappa EZ',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // Kappa + EZ overlay → single WidgetSpan
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
    });

    test('base emote followed by two zero-width overlays', () {
      final emotes = _makeEmotes({
        'Kappa': _e(id: '1', code: 'Kappa'),
        'EZ': _e(id: '2', code: 'EZ', isZeroWidth: true),
        'HYPERS': _e(id: '3', code: 'HYPERS', isZeroWidth: true),
      });
      final spans = EmoteText.build(
        text: 'Kappa EZ HYPERS',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // Kappa + EZ + HYPERS → single WidgetSpan with 2 overlays
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
    });

    test('zero-width between two base emotes attaches to first', () {
      final emotes = _makeEmotes({
        'Kappa': _e(id: '1', code: 'Kappa'),
        'EZ': _e(id: '2', code: 'EZ', isZeroWidth: true),
        'PogChamp': _e(id: '3', code: 'PogChamp'),
      });
      final spans = EmoteText.build(
        text: 'Kappa EZ PogChamp',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      // Kappa + EZ (overlay) = WidgetSpan, ' ', PogChamp = WidgetSpan
      expect(spans.length, greaterThanOrEqualTo(2));
      expect(spans[0], isA<WidgetSpan>());
      expect(spans.last, isA<WidgetSpan>());
    });

    test('unknown token renders as plain text', () {
      final emotes = _makeEmotes({'Kappa': _e(id: '1', code: 'Kappa')});
      final spans = EmoteText.build(
        text: 'unknownToken',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<TextSpan>());
      expect((spans[0] as TextSpan).text, 'unknownToken');
    });

    test('sub emote from IRC tag renders via CDN even if not in API map', () {
      final emotes = _makeEmotes({});
      final spans = EmoteText.build(
        text: 'forsenPls',
        twitchPositions: [
          EmotePosition(
            emoteId: '12345',
            startIndex: 0,
            endIndex: 9,
            emoteCode: 'forsenPls',
          ),
        ],
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
    });

    test('null channelEmotes renders as plain text', () {
      final spans = EmoteText.build(
        text: 'Kappa',
        twitchPositions: null,
        channelEmotes: null,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<TextSpan>());
      expect((spans[0] as TextSpan).text, 'Kappa');
    });

    test('small-scale emote renders at scaled size', () {
      final emotes = _makeEmotes({
        'SmallEmote': _e(id: '1', code: 'SmallEmote', relativeScale: 0.625),
      });
      final spans = EmoteText.build(
        text: 'SmallEmote',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
      final widget = (spans[0] as WidgetSpan).child;
      expect(widget, isA<Semantics>());
      final box = (widget as Semantics).child as SizedBox;
      expect(box.width, 28.0 * 0.625);
      expect(box.height, 28.0 * 0.625);
    });

    test('zero-width overlay expands box to fit largest element', () {
      final emotes = _makeEmotes({
        'SmallBase': _e(id: '1', code: 'SmallBase', relativeScale: 0.5),
        'LargeOverlay': _e(id: '2', code: 'LargeOverlay', isZeroWidth: true),
      });
      final spans = EmoteText.build(
        text: 'SmallBase LargeOverlay',
        twitchPositions: null,
        channelEmotes: emotes,
      );
      expect(spans, hasLength(1));
      expect(spans[0], isA<WidgetSpan>());
      final widget = (spans[0] as WidgetSpan).child;
      expect(widget, isA<Semantics>());
      final box = (widget as Semantics).child as SizedBox;
      expect(box.width, 28.0);
      expect(box.height, 28.0);
    });
  });
}
