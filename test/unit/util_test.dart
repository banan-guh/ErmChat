import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linkify/linkify.dart';
import 'package:ermchat/color_utils.dart';
import 'package:ermchat/services/suggestion.dart';
import 'package:ermchat/models/twitch_badge.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/panels/search.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/util/mention.dart';
import 'package:ermchat/util/duration_format.dart';
import 'package:ermchat/util/text_bypass.dart';
import 'package:ermchat/main.dart';
import 'package:ermchat/sheets/user_sheet.dart';
import 'package:ermchat/util/timestamp_formatter.dart';
import 'package:ermchat/util/crash_report.dart';
import 'package:flutter/services.dart';
import 'package:ermchat/widgets/predictive_back_handler.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/services/third_party_badge_service.dart';
import 'package:ermchat/widgets/message_builder.dart';
import 'package:ermchat/widgets/emote_text.dart';
import 'package:ermchat/widgets/link_whitelist.dart';
import 'package:ermchat/util/constants.dart';
import 'package:ermchat/util/thread_utils.dart';

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

    test('returns null for invalid colors', () {
      const invalid = <String?>[null, '', '#GGGGGG', '@GGGGGG', '#FFF'];
      for (final input in invalid) {
        expect(parseColor(input), isNull, reason: 'input: $input');
      }
    });
  });

  group('announcementColorFor', () {
    test('maps known colors case-insensitively and returns null otherwise', () {
      const cases = {
        'PRIMARY': Color(0xFF7C47D1),
        'BLUE': Color(0xFF1F69FF),
        'GREEN': Color(0xFF00C853),
        'ORANGE': Color(0xFFFF6F00),
        'PURPLE': Color(0xFF7C47D1),
      };
      cases.forEach((name, color) {
        expect(announcementColorFor(name), color, reason: 'input: $name');
      });
      expect(announcementColorFor('blue'), const Color(0xFF1F69FF));
      expect(announcementColorFor('RAINBOW'), isNull);
      expect(announcementColorFor(null), isNull);
    });
  });

  group('luminance', () {
    test('scores black near zero and white near one', () {
      expect(luminance(Colors.black), closeTo(0, 0.001));
      expect(luminance(Colors.white), closeTo(1, 0.001));
    });
  });

  group('normalizeColor', () {
    test('darkens light colors and brightens dark ones for contrast', () {
      const yellow = Color(0xFFFFFF00);
      final darkened = normalizeColor(yellow, Colors.white);
      // Yellow starts at exactly 0.5 lightness and must drop below it.
      expect(HSLColor.fromColor(darkened).lightness, lessThan(0.5));

      const darkBlue = Color(0xFF00008B);
      final brightened = normalizeColor(darkBlue, Colors.black);
      expect(
        HSLColor.fromColor(brightened).lightness,
        greaterThanOrEqualTo(0.5),
      );
    });
  });

  group('getCurrentWord', () {
    test('returns the word under the cursor across positions', () {
      const cases = [
        ('hello', 5, 0, 5, 'hello'),
        ('', 0, 0, 0, ''),
        ('hello world foo', 8, 6, 11, 'world'),
        ('hello world', 6, 6, 11, 'world'),
        ('hello world', 11, 6, 11, 'world'),
        ('hello world', 0, 0, 5, 'hello'),
        ('hi', 10, 0, 2, 'hi'),
        ('hello  world', 9, 7, 12, 'world'),
      ];
      for (final c in cases) {
        final word = getCurrentWord(c.$1, c.$2);
        expect(word.start, c.$3, reason: 'start for "${c.$1}" at ${c.$2}');
        expect(word.end, c.$4, reason: 'end for "${c.$1}" at ${c.$2}');
        expect(word.text, c.$5, reason: 'text for "${c.$1}" at ${c.$2}');
      }
    });
  });

  group('replaceCurrentWord', () {
    test(
      'replaces the word under the cursor and places the caret after it',
      () {
        const cases = [
          ('hello world', 8, 'foo', 'hello foo ', 10),
          ('hello world', 2, 'hi', 'hi world', 2),
          ('hello world', 11, 'earth', 'hello earth ', 12),
          ('hello', 5, 'hi', 'hi ', 3),
          ('', 0, 'hi', 'hi ', 3),
        ];
        for (final c in cases) {
          final controller = TextEditingController(text: c.$1);
          controller.selection = TextSelection.collapsed(offset: c.$2);
          replaceCurrentWord(controller, c.$3);
          expect(
            controller.text,
            c.$4,
            reason: 'text for "${c.$1}" at ${c.$2}',
          );
          expect(
            controller.selection.baseOffset,
            c.$5,
            reason: 'caret for "${c.$1}" at ${c.$2}',
          );
          controller.dispose();
        }
      },
    );
  });

  group('isMention', () {
    test('matches whole-word mentions case-insensitively', () {
      const cases = [
        ('hello @forsen', 'forsen', true),
        ('hello forsen', 'forsen', true),
        ('hello @Forsen', 'forsen', true),
        ('hello FORSEN', 'forsen', true),
        ('hello world', 'forsen', false),
        ('forsenator', 'forsen', false),
        ('hello @forsen!', 'forsen', true),
        ('(@forsen)', 'forsen', true),
        ('hello forsen.', 'forsen', true),
        ('', 'forsen', false),
        ('hello', '', false),
      ];
      for (final c in cases) {
        expect(
          isMention(c.$1, c.$2),
          c.$3,
          reason: 'text: "${c.$1}" login: "${c.$2}"',
        );
      }
    });
  });

  group('isMentionOf', () {
    test('flags pings and replies while ignoring self and system messages', () {
      final cases = [
        (_msg('hey @forsen'), 'forsen', true),
        (_msg('great point', replyTo: 'forsen'), 'forsen', true),
        (_msg('hey @FORSEN'), 'forsen', true),
        (_msg('hi', replyTo: 'Forsen'), 'forsen', true),
        (_msg('hey @forsen', login: 'forsen'), 'forsen', false),
        (
          TwitchMessage(login: '', text: 'Chat was cleared.', isSystem: true),
          'forsen',
          false,
        ),
        (_msg('hello world'), 'forsen', false),
      ];
      for (final c in cases) {
        expect(
          isMentionOf(c.$1, c.$2),
          c.$3,
          reason: 'text: "${c.$1.text}" login: "${c.$1.login}"',
        );
      }
    });
  });

  group('bypassTextDuplicate', () {
    test('sends new text unchanged on first send or when the text differs', () {
      expect(bypassTextDuplicate('hello', null), 'hello');
      expect(bypassTextDuplicate('hello world', null), 'hello world');
      expect(bypassTextDuplicate('hello', 'goodbye'), 'hello');
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

    test('strips suffix when text already ends with the invisible char', () {
      final wire = bypassTextDuplicate(
        'hello$_invisibleChar',
        'hello$_invisibleChar',
      );
      expect(wire, 'hello');
    });

    test('sends a blank placeholder for empty or whitespace-only text', () {
      const cases = ['', ' '];
      for (final input in cases) {
        expect(
          bypassTextDuplicate(input, null),
          ' $_invisibleChar',
          reason: 'input: "$input"',
        );
      }
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
      expect(kDefaultTimestampFormat, 'HH:mm');
      expect(
        formatTimestamp(DateTime(2026, 8, 6, 9, 7, 0), kDefaultTimestampFormat),
        '09:07',
      );
      final withMillis = DateTime(2026, 8, 6, 15, 5, 9, 123, 456);
      expect(formatTimestamp(withMillis, 'HH:mm:ss'), '15:05:09');
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
  });

  test('presets cover 24h and 12h with and without seconds', () {
    expect(kTimestampFormats, containsAll(['HH:mm', 'hh:mm a', 'HH:mm:ss']));
    expect(kTimestampFormats.length, 8);
  });

  group('formatSeconds', () {
    test('formats compact durations from seconds to days', () {
      const cases = {
        0: '0s',
        -5: '0s',
        45: '45s',
        60: '1m',
        300: '5m',
        3600: '1h',
        86400: '1d',
        302: '5m 2s',
        5400: '1h 30m',
        3661: '1h 1m 1s',
        1209600: '14d',
        90061: '1d 1h 1m 1s',
      };
      cases.forEach((input, expected) {
        expect(formatSeconds(input), expected, reason: 'input: $input');
      });
    });
  });

  group('PanelPredictiveBackHandler', () {
    test('routes the back gesture to the open panel only', () {
      var progressCalls = 0;
      final closed = PanelPredictiveBackHandler(
        isPanelOpen: () => false,
        onProgress: (_) => progressCalls++,
        onCancel: () {},
        onCommit: () {},
      );
      expect(closed.handleStartBackGesture(_event(0.1)), isFalse);
      closed.handleUpdateBackGestureProgress(_event(0.5));
      expect(progressCalls, 0);

      var open = true;
      final progress = <double>[];
      var cancelled = 0;
      var committed = 0;
      final handler = PanelPredictiveBackHandler(
        isPanelOpen: () => open,
        onProgress: progress.add,
        onCancel: () => cancelled++,
        onCommit: () => committed++,
      );
      expect(handler.handleStartBackGesture(_event(0.0)), isTrue);
      handler.handleUpdateBackGestureProgress(_event(0.3));
      handler.handleUpdateBackGestureProgress(_event(0.7));
      expect(progress, [0.3, 0.7]);

      open = false;
      expect(handler.handleStartBackGesture(_event(0.0)), isFalse);
      handler.handleUpdateBackGestureProgress(_event(0.5));
      expect(progress, [0.3, 0.7]);

      open = true;
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
    final v = msg.cachedSpansVersion;
    expect(v, isNotNull);
    expect(spans.any((s) => s is WidgetSpan), isFalse);

    final again = makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);
    expect(identical(again, spans), isTrue);
    expect(msg.cachedSpansVersion, v);
  });

  test('cached spans stay frozen across a live 7TV delta', () {
    final em = EmoteManager();
    final msg = makeMsg();
    final spans = makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);
    expect(spans.any((s) => s is WidgetSpan), isFalse);

    // A live 7TV delta does not bump the version: already-rendered messages
    // keep the emote state they were built with (no retroactive re-render on
    // add/remove).
    final v = msg.cachedSpansVersion;
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
    expect(msg.cachedSpansVersion, v);

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

    final re = makeBuilder(em).buildMessageSpans(msg, 'test', Colors.black);
    expect(identical(re, spans), isFalse);
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

  test('card badges are empty with no badge data', () {
    final msg = makeMsg();
    expect(makeBuilder(EmoteManager()).resolveCardBadges('test', msg), isEmpty);
  });

  test('card badges resolve global sets and drop unknown', () async {
    final badgeService = TwitchBadgeService(
      client: MockClient(
        (_) async => http.Response(
          '{"data": [{"set_id": "moderator", "versions": [{"id": "1", "image_url_4x": "https://example.com/mod.png"}]}]}',
          200,
        ),
      ),
    );
    await badgeService.fetchGlobalBadges(TwitchAuth()..accessToken = 't');
    final builder = MessageBuilder(
      emoteManager: EmoteManager(),
      badgeService: badgeService,
      thirdPartyBadgeService: ThirdPartyBadgeService(),
      onShowEmoteSheet: (_) {},
    );
    final msg = TwitchMessage(
      login: 'user',
      text: 'hi',
      badges: const [
        MessageBadge(setId: 'moderator', versionId: '1'),
        MessageBadge(setId: 'nosuchset', versionId: '1'),
        MessageBadge(setId: 'moderator', versionId: '9'),
      ],
    );
    final resolved = builder.resolveCardBadges('test', msg);
    expect(resolved, hasLength(1));
    expect(resolved.single.url, 'https://example.com/mod.png');
    expect(resolved.single.label, 'moderator');
    expect(resolved.single.circular, isFalse);
  });

  test('giphy toggle off falls back to plain text', () {
    final em = EmoteManager();
    final msg = TwitchMessage(
      login: 'user',
      text: 'hello world',
      channel: 'test',
      messageId: 'gif1',
      gifAttachments: const [
        GifAttachment(
          gifId: 'abc',
          url: 'https://media.giphy.com/media/abc/giphy.gif',
          startIndex: 0,
          endIndex: 5,
        ),
      ],
    );
    final builder = makeBuilder(em)..showGifs = false;
    final spans = builder.buildMessageSpans(msg, 'test', Colors.black);
    expect(spans.any((s) => s is WidgetSpan), isFalse);
  });

  test('giphy toggle on renders inline gif and invalidates cache', () {
    final em = EmoteManager();
    final msg = TwitchMessage(
      login: 'user',
      text: 'hello world',
      channel: 'test',
      messageId: 'gif2',
      gifAttachments: const [
        GifAttachment(
          gifId: 'abc',
          url: 'https://media.giphy.com/media/abc/giphy.gif',
          startIndex: 0,
          endIndex: 5,
        ),
      ],
    );
    final builder = makeBuilder(em)..showGifs = false;
    final textOnly = builder.buildMessageSpans(msg, 'test', Colors.black);
    expect(textOnly.any((s) => s is WidgetSpan), isFalse);

    builder.showGifs = true;
    final withGif = builder.buildMessageSpans(msg, 'test', Colors.black);
    expect(identical(withGif, textOnly), isFalse);
    expect(withGif.any((s) => s is WidgetSpan), isTrue);
    // The gap after the gif range still renders as text.
    expect(
      withGif.whereType<TextSpan>().any(
        (s) => s.text?.contains('world') ?? false,
      ),
      isTrue,
    );
  });

  test('giphy height change invalidates the span cache', () {
    final em = EmoteManager();
    final msg = TwitchMessage(
      login: 'user',
      text: 'hello world',
      channel: 'test',
      messageId: 'gif3',
      gifAttachments: const [
        GifAttachment(
          gifId: 'abc',
          url: 'https://media.giphy.com/media/abc/giphy.gif',
          startIndex: 0,
          endIndex: 5,
        ),
      ],
    );
    final builder = makeBuilder(em)..showGifs = true;
    final first = builder.buildMessageSpans(msg, 'test', Colors.black);
    expect(first.any((s) => s is WidgetSpan), isTrue);

    builder.gifHeight = 200;
    final second = builder.buildMessageSpans(msg, 'test', Colors.black);
    expect(identical(second, first), isFalse);
    expect(second.any((s) => s is WidgetSpan), isTrue);
  });

  group('image embeds', () {
    test('detects image extensions, ignores query and fragment', () {
      expect(isImageEmbedCandidate('https://example.com/a.png'), isTrue);
      expect(isImageEmbedCandidate('https://example.com/a.JPG?x=1#y'), isTrue);
      expect(isImageEmbedCandidate('http://example.com/a.webp'), isTrue);
      expect(isImageEmbedCandidate('https://example.com/a.mp4'), isFalse);
      expect(isImageEmbedCandidate('https://example.com/page'), isFalse);
      expect(isImageEmbedCandidate('https://example.com/a.png/'), isFalse);
    });

    test('treats known hosts as images without an extension', () {
      expect(isImageEmbedCandidate('https://kappa.lol/abc'), isTrue);
      expect(isImageEmbedCandidate('https://sub.kappa.lol/abc'), isTrue);
      expect(isImageEmbedCandidate('https://kappa.lol'), isFalse);
      expect(isImageEmbedCandidate('https://youtu.be/abc'), isFalse);
      expect(isImageEmbedCandidate('not a url'), isFalse);
    });

    test('collects embed urls in order without duplicates', () {
      final urls = collectImageEmbedUrls(
        'see https://kappa.lol/abc and https://example.com/x.jpg '
        'and https://kappa.lol/abc',
      );
      expect(urls, ['https://kappa.lol/abc', 'https://example.com/x.jpg']);
    });

    TwitchMessage imgMsg(String id, String text) =>
        TwitchMessage(login: 'u', text: text, channel: 'test', messageId: id);

    test('icons appear only when enabled with a tap handler', () {
      final em = EmoteManager();
      final builder = makeBuilder(em)..showImages = true;
      final tapped = <String>[];
      final spans = builder.buildMessageSpans(
        imgMsg('img1', 'look https://example.com/a.png ok'),
        'test',
        Colors.black,
        onImageTap: tapped.add,
      );
      expect(spans.any((s) => s is WidgetSpan), isTrue);

      // Plain links get no icon even when enabled.
      final plain = builder.buildMessageSpans(
        imgMsg('img2', 'see https://example.com/page ok'),
        'test',
        Colors.black,
        onImageTap: tapped.add,
      );
      expect(plain.any((s) => s is WidgetSpan), isFalse);

      // Enabled but no tap handler means no icon (nothing to expand).
      final noTap = builder.buildMessageSpans(
        imgMsg('img3', 'look https://example.com/a.png ok'),
        'test',
        Colors.black,
      );
      expect(noTap.any((s) => s is WidgetSpan), isFalse);
    });

    test('showImages toggle invalidates the span cache', () {
      final em = EmoteManager();
      final builder = makeBuilder(em)..showImages = false;
      final msg = imgMsg('img4', 'look https://example.com/a.png ok');
      final off = builder.buildMessageSpans(msg, 'test', Colors.black);

      builder.showImages = true;
      final on = builder.buildMessageSpans(msg, 'test', Colors.black);
      expect(identical(on, off), isFalse);
    });
  });

  group('WhitelistLinkifier split links', () {
    const options = LinkifyOptions(
      humanize: false,
      looseUrl: true,
      defaultToHttps: true,
    );

    List<LinkifyElement> runLinkifier(String text, List<String> whitelist) {
      return WhitelistLinkifier(whitelist).parse([TextElement(text)], options);
    }

    List<UrlElement> urlsOf(String text, List<String> whitelist) =>
        runLinkifier(text, whitelist).whereType<UrlElement>().toList();

    test('links space-before-dot with trailing slash', () {
      final urls = urlsOf('check example .com/ out', ['com']);
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://example.com/');
      expect(urls.single.text, 'example .com/');
    });

    test('links space-after-dot with trailing slash', () {
      final urls = urlsOf('check example. com/ out', ['com']);
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://example.com/');
      expect(urls.single.text, 'example. com/');
    });

    test('links space-after-dot with path', () {
      final urls = urlsOf('see example. com/foo', ['com']);
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://example.com/foo');
    });

    test('links fully spaced domain with path', () {
      final urls = urlsOf('see example . com / foo', ['com']);
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://example.com/foo');
    });

    test('keeps linking space-before-dot without path', () {
      final urls = urlsOf('check example .com out', ['com']);
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://example.com');
    });

    test('links whitelisted domain with split path', () {
      final urls = urlsOf('watch kappa .lol/ABCDE now', ['kappa.lol']);
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://kappa.lol/ABCDE');
    });

    test('links subdomains of whitelisted domains', () {
      final urls = urlsOf('see sub .kappa.lol/x', ['kappa.lol']);
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://sub.kappa.lol/x');
    });

    test('keeps trailing slash without eating the next word', () {
      final urls = urlsOf('see i .nuuls .com/ ABCD', ['i.nuuls.com']);
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://i.nuuls.com/');
    });

    test('does not link sentence boundary without path', () {
      expect(urlsOf('that was nice. gg guys', ['gg']), isEmpty);
      expect(urlsOf('that was cool. lol', ['lol']), isEmpty);
      expect(urlsOf('hello. world', ['world']), isEmpty);
    });

    test('does not link non-whitelisted fractured runs', () {
      expect(urlsOf('check example. com/ out', ['net']), isEmpty);
      expect(urlsOf('check example .com/ out', ['net']), isEmpty);
    });

    test('links bare whitelisted domains stock linkify misses', () {
      final urls = urlsOf('check x.com out', ['x.com']);
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://x.com');
      expect(urls.single.text, 'x.com', reason: 'no scheme shown');
    });

    test('links bare domains via whitelisted TLD', () {
      final urls = urlsOf('check x.com out', ['com']);
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://x.com');
    });

    test('links bare whitelisted domains with paths', () {
      final urls = urlsOf('check kappa.lol/tests out', ['kappa.lol']);
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://kappa.lol/tests');
      expect(urls.single.text, 'kappa.lol/tests');
    });

    test('does not link bare non-whitelisted domains', () {
      expect(urlsOf('check x.com out', ['net']), isEmpty);
    });

    test('bare linking works with fracture detection off', () {
      final elements = WhitelistLinkifier(const [
        'x.com',
      ], fractures: false).parse([TextElement('check x.com out')], options);
      final urls = elements.whereType<UrlElement>().toList();
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://x.com');
    });

    test('fractured runs stay plain with fracture detection off', () {
      final elements = WhitelistLinkifier(
        const ['com'],
        fractures: false,
      ).parse([TextElement('check example .com/ out')], options);
      expect(elements.whereType<UrlElement>(), isEmpty);
    });

    test('leaves emails intact', () {
      expect(urlsOf('mail foo@gmail.com today', ['com']), isEmpty);
      expect(urlsOf('mail foo@gmail.com today', ['gmail.com']), isEmpty);
    });

    test('leaves scheme URLs intact', () {
      expect(urlsOf('visit https://x.com/a today', ['x.com']), isEmpty);
      expect(urlsOf('visit https://example.com/a today', ['com']), isEmpty);
    });

    test('full linkify pipeline keeps scheme URLs whole', () {
      final elements = linkify(
        'visit https://example.com/a today',
        options: options,
        linkifiers: [
          const SafeEmailLinkifier(),
          WhitelistLinkifier(const ['com']),
          const UrlLinkifier(),
        ],
      );
      final urls = elements.whereType<UrlElement>().toList();
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://example.com/a');
    });

    test('does not link lone whitelisted words', () {
      expect(urlsOf('lol that was funny', ['lol']), isEmpty);
    });

    test('empty whitelist passes text through', () {
      final elements = runLinkifier('check example. com/ out', []);
      expect(elements, hasLength(1));
      expect(elements.single, isA<TextElement>());
    });

    test('full linkify pipeline links the split domain once', () {
      final elements = linkify(
        'check example. com/ out',
        options: options,
        linkifiers: [
          const SafeEmailLinkifier(),
          WhitelistLinkifier(const ['com']),
          const UrlLinkifier(),
        ],
      );
      final urls = elements.whereType<UrlElement>().toList();
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://example.com/');
    });

    test('links show without the scheme but keep it for launching', () {
      const humanized = LinkifyOptions(
        humanize: true,
        looseUrl: true,
        defaultToHttps: true,
      );
      final elements = linkify(
        'check https://example.com/x out',
        options: humanized,
        linkifiers: [
          const SafeEmailLinkifier(),
          WhitelistLinkifier(const ['com']),
          const UrlLinkifier(),
        ],
      );
      final urls = elements.whereType<UrlElement>().toList();
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://example.com/x');
      expect(urls.single.text, 'example.com/x');
    });

    test(
      'whitelist linkifier leaves scheme URLs contiguous for stock linkify',
      () {
        final elements = runLinkifier('visit https://example.com/a today', [
          'com',
        ]);
        expect(elements, hasLength(1));
        expect(elements.single, isA<TextElement>());
        expect(elements.single.text, 'visit https://example.com/a today');
      },
    );

    test('prod pipeline highlights the scheme of posted links', () {
      const humanized = LinkifyOptions(
        humanize: true,
        looseUrl: true,
        defaultToHttps: true,
      );
      List<LinkifyElement> runProd(String text, List<String> whitelist) =>
          linkify(
            text,
            options: humanized,
            linkifiers: [
              const SafeEmailLinkifier(),
              const SingleCharDomainLinkifier(),
              WhitelistLinkifier(whitelist),
              const UrlLinkifier(),
            ],
          );
      for (final entry in [
        ('visit https://example.com/a today', ['com']),
        ('visit https://kappa.lol/ABCDE now', ['kappa.lol']),
        ('visit https://user@host.com/x now', ['com']),
      ]) {
        final elements = runProd(entry.$1, entry.$2);
        final urls = elements.whereType<UrlElement>().toList();
        expect(urls, hasLength(1), reason: entry.$1);
        expect(
          urls.single.originText,
          contains('https://'),
          reason: '${entry.$1}: originText keeps the scheme for highlighting',
        );
        expect(
          elements.whereType<TextElement>().any(
            (e) => e.text.contains('https://'),
          ),
          isFalse,
          reason: '${entry.$1}: scheme must not leak into plain text',
        );
      }
    });

    test('prod pipeline links bare domains alongside scheme URLs', () {
      const humanized = LinkifyOptions(
        humanize: true,
        looseUrl: true,
        defaultToHttps: true,
      );
      final elements = linkify(
        'see example.com/a and https://example.com/b',
        options: humanized,
        linkifiers: [
          const SafeEmailLinkifier(),
          const SingleCharDomainLinkifier(),
          WhitelistLinkifier(const ['com']),
          const UrlLinkifier(),
        ],
      );
      final urls = elements.whereType<UrlElement>().toList();
      expect(urls, hasLength(2));
      expect(urls[0].url, 'https://example.com/a');
      expect(urls[1].url, 'https://example.com/b');
      expect(urls[1].originText, 'https://example.com/b');
    });
  });

  group('SingleCharDomainLinkifier', () {
    const options = LinkifyOptions(
      humanize: true,
      looseUrl: true,
      defaultToHttps: true,
    );

    List<UrlElement> runSingle(String text) => const SingleCharDomainLinkifier()
        .parse([TextElement(text)], options)
        .whereType<UrlElement>()
        .toList();

    test('links every known domain bare, no whitelist needed', () {
      for (final domain in SingleCharDomainLinkifier.domains) {
        final urls = runSingle('check $domain/abc out');
        expect(urls, hasLength(1), reason: domain);
        expect(urls.single.url, 'https://$domain/abc', reason: domain);
        expect(urls.single.text, '$domain/abc', reason: domain);
      }
    });

    test('ignores unlisted single-char domains', () {
      expect(runSingle('check y.com/abc out'), isEmpty);
      expect(runSingle('check q.net/abc out'), isEmpty);
    });

    test('leaves longer labels to stock linkify', () {
      expect(runSingle('check ax.com/abc out'), isEmpty);
    });

    test('leaves emails and subdomains whole', () {
      expect(runSingle('mail foo@gmail.com today'), isEmpty);
      expect(runSingle('visit www.x.com/a today'), isEmpty);
      expect(runSingle('visit sub.x.com/a today'), isEmpty);
    });

    test('links scheme URLs stock linkify misses', () {
      final urls = runSingle('visit https://x.com/a today');
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://x.com/a');
      expect(urls.single.text, 'https://x.com/a');
    });

    test('claims uppercase scheme URLs whole', () {
      final elements = const SingleCharDomainLinkifier().parse([
        TextElement('visit HTTPS://X.COM/A today'),
      ], options);
      final urls = elements.whereType<UrlElement>().toList();
      expect(urls, hasLength(1));
      expect(urls.single.originText, 'HTTPS://X.COM/A');
      expect(
        elements.whereType<TextElement>().any(
          (e) => e.text.contains('HTTPS://'),
        ),
        isFalse,
      );
    });

    test('keeps trailing sentence periods out of the link', () {
      final urls = runSingle('visit x.com.');
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://x.com');
      expect(urls.single.text, 'x.com');
    });

    test('prod pipeline links bare x.com with an empty whitelist', () {
      final elements = linkify(
        'check x.com out',
        options: options,
        linkifiers: [
          const SafeEmailLinkifier(),
          const SingleCharDomainLinkifier(),
          WhitelistLinkifier(const []),
          const UrlLinkifier(),
        ],
      );
      final urls = elements.whereType<UrlElement>().toList();
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://x.com');
      expect(urls.single.text, 'x.com');
    });
  });

  group('SafeEmailLinkifier', () {
    const options = LinkifyOptions(
      humanize: true,
      looseUrl: true,
      defaultToHttps: true,
    );

    List<LinkifyElement> runEmail(String text) =>
        const SafeEmailLinkifier().parse([TextElement(text)], options);

    test('claims plain email addresses', () {
      final elements = runEmail('mail foo@gmail.com today');
      final emails = elements.whereType<EmailElement>().toList();
      expect(emails, hasLength(1));
      expect(emails.single.emailAddress, 'foo@gmail.com');
    });

    test('claims multiple email addresses', () {
      final elements = runEmail('a@b.co and c@d.io');
      expect(elements.whereType<EmailElement>().map((e) => e.emailAddress), [
        'a@b.co',
        'c@d.io',
      ]);
    });

    test('leaves scheme URLs with userinfo whole', () {
      const text = 'visit https://user@host.com/x now';
      final elements = runEmail(text);
      expect(elements.whereType<EmailElement>(), isEmpty);
      expect(elements.map((e) => e.text).join(), text);
    });

    test('full pipeline keeps userinfo URLs whole', () {
      final elements = linkify(
        'visit https://user@host.com/x now',
        options: options,
        linkifiers: [
          const SafeEmailLinkifier(),
          WhitelistLinkifier(const ['com']),
          const UrlLinkifier(),
        ],
      );
      final urls = elements.whereType<UrlElement>().toList();
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://user@host.com/x');
      expect(elements.whereType<EmailElement>(), isEmpty);
    });

    test('full pipeline routes plain emails to EmailElement', () {
      final elements = linkify(
        'mail foo@gmail.com today',
        options: options,
        linkifiers: [
          const SafeEmailLinkifier(),
          WhitelistLinkifier(const ['com']),
          const UrlLinkifier(),
        ],
      );
      final emails = elements.whereType<EmailElement>().toList();
      expect(emails, hasLength(1));
      expect(emails.single.emailAddress, 'foo@gmail.com');
      expect(elements.whereType<UrlElement>(), isEmpty);
    });

    test('email spans are tappable and report the address', () {
      String? tapped;
      final spans = parseTextWithLinks(
        'mail foo@gmail.com today',
        onEmailTap: (email) => tapped = email,
      );
      final emailSpan = spans.whereType<TextSpan>().firstWhere(
        (s) => s.recognizer != null,
      );
      expect(emailSpan.text, 'foo@gmail.com');
      expect(emailSpan.style?.color, Colors.blue);
      (emailSpan.recognizer! as TapGestureRecognizer).onTap!();
      expect(tapped, 'foo@gmail.com');
    });
  });

  group('crash_report', () {
    test('reportError forwards to the plugged reporter', () {
      Object? captured;
      StackTrace? capturedStack;
      crashReporter = (e, s) {
        captured = e;
        capturedStack = s;
      };
      reportError('boom', StackTrace.current);
      expect(captured, 'boom');
      expect(capturedStack, isNotNull);
      crashReporter = null;
    });
  });

  group('userSheetNearestDetent', () {
    const minExtent = 0.25;
    const cardExtent = 0.4;
    const maxExtent = 1.0;

    double nearest(double size) => userSheetNearestDetent(
      size,
      minExtent: minExtent,
      cardExtent: cardExtent,
      maxExtent: maxExtent,
    );

    test('detents map to themselves', () {
      expect(nearest(minExtent), minExtent);
      expect(nearest(cardExtent), cardExtent);
      expect(nearest(maxExtent), maxExtent);
    });

    test('between detents picks the nearer one', () {
      expect(nearest(0.3), minExtent);
      expect(nearest(0.6), cardExtent);
      expect(nearest(0.9), maxExtent);
    });
  });

  group('userSheetTargetDetent', () {
    const minExtent = 0.25;
    const cardExtent = 0.4;
    const maxExtent = 1.0;

    double target(double size, double velocityDy) => userSheetTargetDetent(
      size,
      minExtent: minExtent,
      cardExtent: cardExtent,
      maxExtent: maxExtent,
      velocityDy: velocityDy,
    );

    test('slow releases use distance', () {
      expect(target(0.3, 100), minExtent);
      expect(target(0.6, -100), cardExtent);
      expect(target(0.9, 100), maxExtent);
    });

    test('fast upward releases move up one detent', () {
      expect(target(0.3, -1000), cardExtent);
      expect(target(cardExtent, -1000), maxExtent);
      expect(target(0.8, -1000), maxExtent);
    });

    test('fast downward releases move down one detent', () {
      expect(target(maxExtent, 1000), cardExtent);
      expect(target(0.8, 1000), cardExtent);
      expect(target(cardExtent, 1000), minExtent);
      expect(target(0.3, 1000), minExtent);
    });
  });

  group('chat search matching', () {
    TwitchMessage searchMsg(
      String text, {
      String login = 'xqc',
      String? displayName,
      bool isSystem = false,
    }) => TwitchMessage(
      login: login,
      displayName: displayName ?? login,
      text: text,
      channel: 'test',
      isSystem: isSystem,
    );

    test('system rows never match a real query', () {
      const f = ChatSearchFilter(query: 'sys');
      expect(searchMatches(searchMsg('sys', isSystem: true), f), isFalse);
    });

    test('messages scope ignores the sender', () {
      const f = ChatSearchFilter(query: 'bob', scope: ChatSearchScope.messages);
      expect(searchMatches(searchMsg('hi bob'), f), isTrue);
      expect(searchMatches(searchMsg('hi', login: 'bob'), f), isFalse);
    });

    test('chatters scope ignores the text', () {
      const f = ChatSearchFilter(query: 'bob', scope: ChatSearchScope.chatters);
      expect(searchMatches(searchMsg('hi', login: 'bob'), f), isTrue);
      expect(searchMatches(searchMsg('hi bob'), f), isFalse);
    });

    test('chatters scope matches display names case-insensitively', () {
      const f = ChatSearchFilter(
        query: 'kappa',
        scope: ChatSearchScope.chatters,
      );
      expect(
        searchMatches(searchMsg('hi', displayName: 'KappaKid'), f),
        isTrue,
      );
    });
  });

  group('resolveThreadRootId', () {
    test('walks to the root', () {
      expect(resolveThreadRootId('c', {'c': 'b', 'b': 'a'}), 'a');
    });

    test('cycle terminates instead of hanging', () {
      expect(resolveThreadRootId('a', {'a': 'b', 'b': 'a'}), isNotEmpty);
      expect(resolveThreadRootId('a', {'a': 'a'}), 'a');
    });
  });
}
