import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/color_utils.dart';
import 'package:ermchat/services/suggestion.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/util/mention.dart';
import 'package:ermchat/util/duration_format.dart';
import 'package:ermchat/util/text_bypass.dart';
import 'package:ermchat/main.dart';
import 'package:ermchat/util/timestamp_formatter.dart';
import 'package:flutter/services.dart';
import 'package:ermchat/widgets/predictive_back_handler.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/services/third_party_badge_service.dart';
import 'package:ermchat/widgets/message_builder.dart';

TwitchMessage _msg(String text, {String login = 'otheruser', String? replyTo}) {
  return TwitchMessage(
    login: login,
    text: text,
    isSystem: false,
    replyToUser: replyTo,
  );
}

const _invisibleChar = '\u034F';

PredictiveBackEvent _event(double progress) {
  return PredictiveBackEvent.fromMap({
    'progress': progress,
    'swipeEdge': 0,
    'touchOffset': [10.0, 20.0],
  });
}

void main() {
  group('officialColors', () {
    test('is a non-empty list of hex strings', () {
      expect(officialColors, isNotEmpty);
      for (final c in officialColors) {
        expect(c.startsWith('#'), isTrue);
      }
    });
  });

  group('pickColor', () {
    test('returns a color from officialColors', () {
      final color = pickColor('forsen');
      expect(officialColors, contains(color));
    });

    test('is deterministic for same username', () {
      expect(pickColor('forsen'), pickColor('forsen'));
    });

    test('can return different colors for different usernames', () {
      final results = <String>{};
      for (final name in ['forsen', 'xqc', 'summit1g', 'lirik', 'shroud']) {
        results.add(pickColor(name));
      }
      expect(results.length, greaterThan(1));
    });

    test('handles empty string', () {
      expect(officialColors, contains(pickColor('')));
    });
  });

  group('parseColor', () {
    test('parses valid hex color', () {
      final c = parseColor('#FF0000');
      expect(c, isNotNull);
      expect(c!.toARGB32(), 0xFFFF0000);
    });

    test('returns null for null input', () {
      expect(parseColor(null), isNull);
    });

    test('returns null for empty string', () {
      expect(parseColor(''), isNull);
    });

    test('returns null for invalid hex', () {
      expect(parseColor('#GGGGGG'), isNull);
    });

    test('returns null for short string', () {
      expect(parseColor('#FFF'), isNull);
    });
  });

  group('announcementColorFor', () {
    test('maps all five twitch colors', () {
      expect(announcementColorFor('PRIMARY'), const Color(0xFF9146FF));
      expect(announcementColorFor('BLUE'), const Color(0xFF1F69FF));
      expect(announcementColorFor('GREEN'), const Color(0xFF00C853));
      expect(announcementColorFor('ORANGE'), const Color(0xFFFF6F00));
      expect(announcementColorFor('PURPLE'), const Color(0xFF9146FF));
    });

    test('is case insensitive', () {
      expect(announcementColorFor('blue'), const Color(0xFF1F69FF));
    });

    test('returns null for unknown or absent values', () {
      expect(announcementColorFor('RAINBOW'), isNull);
      expect(announcementColorFor(null), isNull);
    });
  });

  group('luminance', () {
    test('black has luminance 0', () {
      expect(luminance(Colors.black), closeTo(0, 0.001));
    });

    test('white has luminance ~1', () {
      expect(luminance(Colors.white), closeTo(1, 0.001));
    });
  });

  group('normalizeColor', () {
    test('darkens yellow on light background', () {
      const yellow = Color(0xFFFFFF00);
      final c = normalizeColor(yellow, Colors.white);
      final hsl = HSLColor.fromColor(c);
      // Yellow starts at exactly 0.5 lightness; the yellow-hue adjustment
      // must push it below 0.5 on a light background.
      expect(hsl.lightness, lessThan(0.5));
    });

    test('brightens dark blue on dark background', () {
      const darkBlue = Color(0xFF00008B);
      final c = normalizeColor(darkBlue, Colors.black);
      final hsl = HSLColor.fromColor(c);
      expect(hsl.lightness, greaterThanOrEqualTo(0.5));
    });
  });

  group('getCurrentWord', () {
    test('returns full text when cursor at end and no spaces', () {
      final word = getCurrentWord('hello', 5);
      expect(word.start, 0);
      expect(word.end, 5);
      expect(word.text, 'hello');
    });

    test('returns empty when text is empty', () {
      final word = getCurrentWord('', 0);
      expect(word.start, 0);
      expect(word.end, 0);
      expect(word.text, '');
    });

    test('returns word at cursor from middle of text', () {
      final word = getCurrentWord('hello world foo', 8);
      expect(word.start, 6);
      expect(word.end, 11);
      expect(word.text, 'world');
    });

    test('returns word at cursor start of word', () {
      final word = getCurrentWord('hello world', 6);
      expect(word.start, 6);
      expect(word.end, 11);
      expect(word.text, 'world');
    });

    test('returns word at cursor end of word', () {
      final word = getCurrentWord('hello world', 11);
      expect(word.start, 6);
      expect(word.end, 11);
      expect(word.text, 'world');
    });

    test('returns first word when cursor at start', () {
      final word = getCurrentWord('hello world', 0);
      expect(word.start, 0);
      expect(word.end, 5);
      expect(word.text, 'hello');
    });

    test('clamps cursor beyond text length', () {
      final word = getCurrentWord('hi', 10);
      expect(word.start, 0);
      expect(word.end, 2);
      expect(word.text, 'hi');
    });

    test('handles multiple spaces between words', () {
      final word = getCurrentWord('hello  world', 9);
      expect(word.start, 7);
      expect(word.end, 12);
      expect(word.text, 'world');
    });
  });

  group('replaceCurrentWord', () {
    test('replaces single word', () {
      final controller = TextEditingController(text: 'hello world');
      controller.selection = TextSelection.collapsed(offset: 8);
      replaceCurrentWord(controller, 'foo');
      expect(controller.text, 'hello foo ');
      expect(controller.selection.baseOffset, 10);
    });

    test('replaces word at start of text', () {
      final controller = TextEditingController(text: 'hello world');
      controller.selection = TextSelection.collapsed(offset: 2);
      replaceCurrentWord(controller, 'hi');
      expect(controller.text, 'hi world');
      expect(controller.selection.baseOffset, 2);
    });

    test('replaces word at end of text', () {
      final controller = TextEditingController(text: 'hello world');
      controller.selection = TextSelection.collapsed(offset: 11);
      replaceCurrentWord(controller, 'earth');
      expect(controller.text, 'hello earth ');
      expect(controller.selection.baseOffset, 12);
    });

    test('replaces only word in text', () {
      final controller = TextEditingController(text: 'hello');
      controller.selection = TextSelection.collapsed(offset: 5);
      replaceCurrentWord(controller, 'hi');
      expect(controller.text, 'hi ');
      expect(controller.selection.baseOffset, 3);
    });

    test('handles empty text', () {
      final controller = TextEditingController(text: '');
      controller.selection = TextSelection.collapsed(offset: 0);
      replaceCurrentWord(controller, 'hi');
      expect(controller.text, 'hi ');
      expect(controller.selection.baseOffset, 3);
    });
  });

  group('isMention', () {
    test('detects @username mention', () {
      expect(isMention('hello @forsen', 'forsen'), isTrue);
    });

    test('detects username without @', () {
      expect(isMention('hello forsen', 'forsen'), isTrue);
    });

    test('is case-insensitive', () {
      expect(isMention('hello @Forsen', 'forsen'), isTrue);
      expect(isMention('hello FORSEN', 'forsen'), isTrue);
    });

    test('returns false when username not in text', () {
      expect(isMention('hello world', 'forsen'), isFalse);
    });

    test('returns false for substring match', () {
      expect(isMention('forsenator', 'forsen'), isFalse);
    });

    test('handles punctuation around username', () {
      expect(isMention('hello @forsen!', 'forsen'), isTrue);
      expect(isMention('(@forsen)', 'forsen'), isTrue);
      expect(isMention('hello forsen.', 'forsen'), isTrue);
    });

    test('handles empty text', () {
      expect(isMention('', 'forsen'), isFalse);
    });

    test('handles empty login', () {
      expect(isMention('hello', ''), isFalse);
    });
  });

  group('isMentionOf', () {
    test('detects a direct ping', () {
      expect(isMentionOf(_msg('hey @forsen'), 'forsen'), isTrue);
    });

    test('detects a reply to the user', () {
      expect(
        isMentionOf(_msg('great point', replyTo: 'forsen'), 'forsen'),
        isTrue,
      );
    });

    test('is case-insensitive on login and reply target', () {
      expect(isMentionOf(_msg('hey @FORSEN'), 'forsen'), isTrue);
      expect(isMentionOf(_msg('hi', replyTo: 'Forsen'), 'forsen'), isTrue);
    });

    test('false for the user\'s own message', () {
      expect(
        isMentionOf(_msg('hey @forsen', login: 'forsen'), 'forsen'),
        isFalse,
      );
    });

    test('false for system messages', () {
      final msg = TwitchMessage(
        login: '',
        text: 'Chat was cleared.',
        isSystem: true,
      );
      expect(isMentionOf(msg, 'forsen'), isFalse);
    });

    test('false when not a mention', () {
      expect(isMentionOf(_msg('hello world'), 'forsen'), isFalse);
    });
  });

  group('bypassTextDuplicate', () {
    test('first send (no previous wire) sends text unchanged', () {
      expect(bypassTextDuplicate('hello', null), 'hello');
    });

    test('toggles invisible suffix on/off for repeated identical sends', () {
      var wire = bypassTextDuplicate('hello', null);
      expect(wire, 'hello');
      wire = bypassTextDuplicate('hello', wire);
      expect(wire, 'hello $_invisibleChar');
      wire = bypassTextDuplicate('hello', wire);
      expect(wire, 'hello');
      wire = bypassTextDuplicate('hello', wire);
      expect(wire, 'hello $_invisibleChar');
    });

    test('toggles for multi-word text without a visible double space', () {
      var wire = bypassTextDuplicate('hello world', null);
      expect(wire, 'hello world');
      wire = bypassTextDuplicate('hello world', wire);
      expect(wire, 'hello world $_invisibleChar');
      wire = bypassTextDuplicate('hello world', wire);
      expect(wire, 'hello world');
    });

    test('different text from last wire is sent unchanged', () {
      expect(bypassTextDuplicate('hello', 'goodbye'), 'hello');
    });

    test('strips suffix when text already ends with the invisible char', () {
      final wire = bypassTextDuplicate(
        'hello$_invisibleChar',
        'hello$_invisibleChar',
      );
      expect(wire, 'hello');
    });

    test('handles empty string', () {
      expect(bypassTextDuplicate('', null), ' $_invisibleChar');
    });

    test('text with only spaces', () {
      expect(bypassTextDuplicate(' ', null), ' $_invisibleChar');
    });
  });

  group('buildDarkTheme', () {
    test('non-true dark keeps M3 surfaces and no overrides', () {
      final scheme = buildDarkTheme(trueDark: false).colorScheme;
      expect(scheme.surface, isNot(Colors.black));
      expect(scheme.surface, isNot(scheme.surfaceContainer));
      expect(
        scheme.surfaceContainer,
        isNot(scheme.surface),
        reason: 'M3 chrome role stays distinct from the body surface',
      );
      final plain = ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: Brightness.dark,
      );
      expect(scheme.surface, plain.surface);
    });

    test('true dark pins surface and background to pure black', () {
      final scheme = buildDarkTheme(trueDark: true).colorScheme;
      expect(scheme.surface, Colors.black);
      expect(scheme.onSurface, Colors.white);
      expect(
        scheme.surfaceContainer,
        isNot(Colors.black),
        reason: 'chrome stays grey in true dark too',
      );
    });

    test('seed color drives the scheme', () {
      final blue = buildDarkTheme(seedColor: Colors.blue).colorScheme;
      final red = buildDarkTheme(seedColor: Colors.red).colorScheme;
      expect(blue.primary, isNot(red.primary));
    });
  });

  // Fixed local time: 2026-08-06 03:05:09 in the host's local time zone.
  final midnight = DateTime(2026, 8, 6, 0, 5, 9);
  final noon = DateTime(2026, 8, 6, 12, 5, 9);
  final pm = DateTime(2026, 8, 6, 15, 5, 9);

  group('formatTimestamp', () {
    test('24-hour formats', () {
      expect(formatTimestamp(pm, 'H:mm'), '15:05');
      expect(formatTimestamp(pm, 'HH:mm'), '15:05');
      expect(formatTimestamp(midnight, 'H:mm'), '0:05');
      expect(formatTimestamp(midnight, 'HH:mm'), '00:05');
      expect(formatTimestamp(pm, 'H:mm:ss'), '15:05:09');
      expect(formatTimestamp(pm, 'HH:mm:ss'), '15:05:09');
    });

    test('12-hour formats with AM/PM', () {
      expect(formatTimestamp(pm, 'h:mm a'), '3:05 PM');
      expect(formatTimestamp(pm, 'hh:mm a'), '03:05 PM');
      expect(formatTimestamp(midnight, 'h:mm a'), '12:05 AM');
      expect(formatTimestamp(midnight, 'hh:mm a'), '12:05 AM');
      expect(formatTimestamp(noon, 'h:mm:ss a'), '12:05:09 PM');
      expect(formatTimestamp(noon, 'hh:mm:ss a'), '12:05:09 PM');
      expect(formatTimestamp(pm, 'h:mm:ss a'), '3:05:09 PM');
      expect(formatTimestamp(pm, 'hh:mm:ss a'), '03:05:09 PM');
    });

    test('default format is HH:mm', () {
      expect(kDefaultTimestampFormat, 'HH:mm');
      expect(
        formatTimestamp(DateTime(2026, 8, 6, 9, 7, 0), kDefaultTimestampFormat),
        '09:07',
      );
    });

    test('drops milliseconds regardless of input precision', () {
      final withMillis = DateTime(2026, 8, 6, 15, 5, 9, 123, 456);
      expect(formatTimestamp(withMillis, 'HH:mm:ss'), '15:05:09');
    });
  });

  test('presets cover 24h and 12h with and without seconds', () {
    expect(kTimestampFormats, containsAll(['HH:mm', 'hh:mm a', 'HH:mm:ss']));
    expect(kTimestampFormats.length, 8);
  });

  group('formatSeconds', () {
    test('zero and negative formats as 0s', () {
      expect(formatSeconds(0), '0s');
      expect(formatSeconds(-5), '0s');
    });

    test('bare seconds stay plain', () {
      expect(formatSeconds(45), '45s');
    });

    test('skips zero units', () {
      expect(formatSeconds(60), '1m');
      expect(formatSeconds(300), '5m');
      expect(formatSeconds(3600), '1h');
      expect(formatSeconds(86400), '1d');
    });

    test('combines tiers without zero padding', () {
      expect(formatSeconds(302), '5m 2s');
      expect(formatSeconds(5400), '1h 30m');
      expect(formatSeconds(3661), '1h 1m 1s');
    });

    test('caps at days for long timeouts', () {
      expect(formatSeconds(1209600), '14d');
      expect(formatSeconds(90061), '1d 1h 1m 1s');
    });
  });

  group('PanelPredictiveBackHandler', () {
    test('declines the gesture when no panel is open', () {
      var progressCalls = 0;
      final handler = PanelPredictiveBackHandler(
        isPanelOpen: () => false,
        onProgress: (_) => progressCalls++,
        onCancel: () {},
        onCommit: () {},
      );

      expect(handler.handleStartBackGesture(_event(0.1)), isFalse);
      handler.handleUpdateBackGestureProgress(_event(0.5));
      expect(progressCalls, 0);
    });

    test('accepts only when a panel is open and reports progress', () {
      var open = true;
      final progress = <double>[];
      final handler = PanelPredictiveBackHandler(
        isPanelOpen: () => open,
        onProgress: progress.add,
        onCancel: () {},
        onCommit: () {},
      );

      expect(handler.handleStartBackGesture(_event(0.0)), isTrue);
      handler.handleUpdateBackGestureProgress(_event(0.3));
      handler.handleUpdateBackGestureProgress(_event(0.7));
      expect(progress, [0.3, 0.7]);

      // Once declined, progress stops flowing.
      open = false;
      expect(handler.handleStartBackGesture(_event(0.0)), isFalse);
      handler.handleUpdateBackGestureProgress(_event(0.5));
      expect(progress, [0.3, 0.7]);
    });

    test('cancel restores, commit closes', () {
      var cancelled = 0;
      var committed = 0;
      final handler = PanelPredictiveBackHandler(
        isPanelOpen: () => true,
        onProgress: (_) {},
        onCancel: () => cancelled++,
        onCommit: () => committed++,
      );

      expect(handler.handleStartBackGesture(_event(0.0)), isTrue);
      handler.handleUpdateBackGestureProgress(_event(0.4));
      handler.handleCancelBackGesture();
      expect(cancelled, 1);
      expect(committed, 0);

      expect(handler.handleStartBackGesture(_event(0.0)), isTrue);
      handler.handleUpdateBackGestureProgress(_event(0.9));
      handler.handleCommitBackGesture();
      expect(committed, 1);
      expect(cancelled, 1);

      // A second commit after the gesture ended does nothing.
      handler.handleCommitBackGesture();
      expect(committed, 1);
    });
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  MessageBuilder makeBuilder(EmoteManager em) => MessageBuilder(
    emoteManager: em,
    badgeService: TwitchBadgeService(),
    thirdPartyBadgeService: ThirdPartyBadgeService(),
    onShowEmoteSheet: (_) {},
  );

  TwitchMessage makeMsg() => TwitchMessage(
    login: 'user',
    text: 'Pog',
    channel: 'test',
    messageId: 'm1',
  );

  test('cached spans are reused while the emote version is unchanged', () {
    final em = EmoteManager();
    final msg = makeMsg();
    final spans = makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);

    expect(msg.cachedSpans, isNotNull);
    expect(msg.cachedSpansVersion, em.version * 1000003);
    expect(spans.any((s) => s is WidgetSpan), isFalse);

    final again = makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);
    expect(identical(again, spans), isTrue);
  });

  test('cached spans stay frozen across a live 7TV delta', () {
    final em = EmoteManager();
    final msg = makeMsg();
    final spans = makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);
    expect(spans.any((s) => s is WidgetSpan), isFalse);

    // A live 7TV delta does not bump the version: already-rendered messages
    // keep the emote state they were built with (no retroactive re-render on
    // add/remove).
    em.updateSevenTvEmotes(
      'test',
      added: [
        const GenericEmote(
          id: 'e1',
          code: 'Pog',
          type: EmoteType.sevenTv,
          url: 'https://example.com/pog.png',
        ),
      ],
    );
    expect(em.version, msg.cachedSpansVersion);

    final again = makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);
    expect(identical(again, spans), isTrue);
  });

  test('cached spans recompute after a full refetch notify', () async {
    final em = EmoteManager();
    final msg = makeMsg();
    final spans = makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);
    expect(spans.any((s) => s is WidgetSpan), isFalse);

    // A non-delta notify (full refetch) bumps the version and the next build
    // lazily recomputes against the fresh emote data.
    await em.storeUserTwitchEmotes({});
    expect(em.version, greaterThan(0));
    expect(msg.cachedSpansVersion, isNot(em.version * 1000003));

    makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);
    expect(msg.cachedSpansVersion, em.version * 1000003);
  });

  test('cached spans recompute when the text scale changes', () {
    final em = EmoteManager();
    final msg = makeMsg();
    final builder = makeBuilder(em);

    final small = builder.buildMessageSpans(
      msg,
      'test',
      Colors.black,
      textScale: 1.0,
    );
    // Spans embed absolute emote pixel sizes, so a different scale must
    // rebuild them instead of serving the cache (emotes follow the font).
    final cachedSameScale = builder.buildMessageSpans(
      msg,
      'test',
      Colors.black,
      textScale: 1.0,
    );
    expect(identical(cachedSameScale, small), isTrue);
    expect(msg.cachedSpansScale, 1.0);

    final big = builder.buildMessageSpans(
      msg,
      'test',
      Colors.black,
      textScale: 2.0,
    );
    expect(identical(big, small), isFalse);
    expect(msg.cachedSpansScale, 2.0);
  });

  test('colored /me spans keep link styling', () {
    final em = EmoteManager();
    final msg = TwitchMessage(
      login: 'user',
      text: 'see https://example.com now',
      channel: 'test',
      messageId: 'm2',
      isAction: true,
      color: '#FF0000',
    );
    final builder = makeBuilder(em);

    final spans = builder
        .buildMessageSpans(msg, 'test', Colors.white, colored: true)
        .whereType<TextSpan>();

    final link = spans.firstWhere((s) => s.recognizer != null);
    expect(link.style?.color, Colors.blue, reason: 'links stay blue');

    final plain = spans.where((s) => s.recognizer == null).toList();
    expect(plain, isNotEmpty);
    for (final s in plain) {
      expect(s.style?.color, isNot(Colors.blue), reason: '/me tint applies');
    }
  });
}
