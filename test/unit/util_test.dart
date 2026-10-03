import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linkify/linkify.dart';
import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/color_utils.dart';
import 'package:ermchat/composer/suggestion.dart';
import 'package:ermchat/models/twitch_badge.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/panels/search.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/util/mention.dart';
import 'package:ermchat/util/duration_format.dart';
import 'package:ermchat/util/chat_text.dart';
import 'package:ermchat/main.dart';
import 'package:ermchat/sheets/user_sheet.dart';
import 'package:ermchat/util/timestamp_formatter.dart';
import 'package:flutter/services.dart';
import 'package:ermchat/widgets/predictive_back_handler.dart';
import 'package:ermchat/emotes/emote.dart';
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
  group('pickColor', () {
    test('returns an official color, including for empty input', () {
      expect(officialColors, contains(pickColor('forsen')));
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

  test('luminance and normalizeColor keep text readable', () {
    expect(luminance(Colors.black), closeTo(0, 0.001));
    expect(luminance(Colors.white), closeTo(1, 0.001));

    const yellow = Color(0xFFFFFF00);
    final darkened = normalizeColor(yellow, Colors.white);
    expect(HSLColor.fromColor(darkened).lightness, lessThan(0.5));

    const darkBlue = Color(0xFF00008B);
    final brightened = normalizeColor(darkBlue, Colors.black);
    expect(HSLColor.fromColor(brightened).lightness, greaterThanOrEqualTo(0.5));
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

    test('autocomplete appends a trailing space at the end of the text', () {
      const cases = [
        ('Kapp', 4, 'Kappa', 'Kappa ', 6),
        ('', 0, 'Kappa', 'Kappa ', 6),
        ('hello wor', 9, 'world', 'hello world ', 12),
        ('hello Kapp world', 10, 'Kappa', 'hello Kappa world', 11),
        ('hello Kappworld', 10, 'Kappa', 'hello Kappa world', 12),
      ];
      for (final c in cases) {
        final controller = TextEditingController(text: c.$1);
        controller.selection = TextSelection.collapsed(offset: c.$2);
        replaceCurrentWord(controller, c.$3, extendRight: false);
        expect(controller.text, c.$4, reason: 'text for "${c.$1}" at ${c.$2}');
        expect(
          controller.selection.baseOffset,
          c.$5,
          reason: 'caret for "${c.$1}" at ${c.$2}',
        );
        controller.dispose();
      }
    });
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
    emoteSource: em,
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

  test('spans are cached and stay frozen across catalog changes', () async {
    final em = EmoteManager();
    final msg = makeMsg();
    final builder = makeBuilder(em);
    final spans = builder.buildMessageSpans(msg, 'test', Colors.black);
    expect(builder.bodyIsCached(msg, spans), isTrue);
    expect(spans.any((s) => s is WidgetSpan), isFalse);
    expect(
      identical(builder.buildMessageSpans(msg, 'test', Colors.black), spans),
      isTrue,
    );

    // A live 7TV delta and a full refetch never retroactively re-render.
    em.updateSevenTvEmotes(
      'test',
      added: [
        const Emote(
          id: 'e1',
          code: 'Pog',
          meta: SevenTvMeta(),
          scales: {EmoteScale.medium: 'https://example.com/pog.png'},
        ),
      ],
    );
    expect(
      identical(builder.buildMessageSpans(msg, 'test', Colors.black), spans),
      isTrue,
    );

    await em.storeUserTwitchEmotes({
      'test': [
        const Emote(
          id: 's1',
          code: 'Sub',
          meta: TwitchMeta(kind: TwitchEmoteKind.sub),
          scales: {EmoteScale.medium: 'https://example.com/s1.png'},
          scope: EmoteScope.channel,
        ),
      ],
    });
    expect(em.version, greaterThan(0));
    expect(
      identical(builder.buildMessageSpans(msg, 'test', Colors.black), spans),
      isTrue,
    );
  });

  test('spans rebuild when a restamp reassigns the tokens', () {
    final em = EmoteManager();
    final msg = makeMsg()..emoteTokens = const [];
    final builder = makeBuilder(em);
    final spans = builder.buildMessageSpans(msg, 'test', Colors.black);
    expect(spans.any((s) => s is WidgetSpan), isFalse);

    // A history restamp assigns a new token list: same catalog version,
    // new identity, so the memo drops and the emote renders.
    em.updateSevenTvEmotes(
      'test',
      added: [
        const Emote(
          id: 'e1',
          code: 'Pog',
          meta: SevenTvMeta(),
          scales: {EmoteScale.medium: 'https://example.com/pog.png'},
        ),
      ],
    );
    msg.emoteTokens = em.parseMessageEmotes(msg, lookupChannel: 'test');

    final re = builder.buildMessageSpans(msg, 'test', Colors.black);
    expect(identical(re, spans), isFalse);
    expect(re.any((s) => s is WidgetSpan), isTrue);
  });

  test('spans recompute when the text scale changes', () {
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

    final big = builder.buildMessageSpans(
      msg,
      'test',
      Colors.black,
      textScale: 2.0,
    );
    expect(identical(big, small), isFalse);
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

  test('cached /me spans recolor only when the surface changes', () {
    final builder = makeBuilder(EmoteManager());
    final msg = TwitchMessage(
      login: 'user',
      text: 'Pog',
      channel: 'test',
      messageId: 'm3',
      isAction: true,
      color: '#0000FF',
    );
    List<InlineSpan> build(Color surface) =>
        builder.buildMessageSpans(msg, 'test', surface, colored: true);

    final dark = build(Colors.black);
    expect(builder.bodyIsCached(msg, dark), isTrue);
    expect(identical(build(Colors.black), dark), isTrue, reason: 'memoized');
    final light = build(Colors.white);
    expect(
      (light.single as TextSpan).style?.color,
      isNot((dark.single as TextSpan).style?.color),
      reason: 'a theme flip renormalizes the sender color',
    );
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
      emoteSource: EmoteManager(),
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
    expect(resolved.single.label, 'Moderator');
    expect(resolved.single.circular, isFalse);
  });

  test('card badges prefer the Helix title for the label', () async {
    final badgeService = TwitchBadgeService(
      client: MockClient(
        (_) async => http.Response(
          '{"data": [{"set_id": "subscriber", "versions": [{"id": "6", "title": "6-Month Subscriber", "image_url_4x": "https://example.com/sub.png"}]}, {"set_id": "sub-gifter", "versions": [{"id": "1", "image_url_4x": "https://example.com/gift.png"}]}]}',
          200,
        ),
      ),
    );
    await badgeService.fetchGlobalBadges(TwitchAuth()..accessToken = 't');
    final builder = MessageBuilder(
      emoteSource: EmoteManager(),
      badgeService: badgeService,
      thirdPartyBadgeService: ThirdPartyBadgeService(),
      onShowEmoteSheet: (_) {},
    );
    final msg = TwitchMessage(
      login: 'user',
      text: 'hi',
      badges: const [
        MessageBadge(setId: 'subscriber', versionId: '6'),
        MessageBadge(setId: 'sub-gifter', versionId: '1'),
      ],
    );
    expect(builder.resolveCardBadges('test', msg).map((b) => b.label), [
      '6-Month Subscriber',
      'Sub gifter',
    ]);
  });

  test('giphy toggle and height rebuild spans; off falls back to text', () {
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
    final builder = makeBuilder(EmoteManager())..showGifs = false;
    final textOnly = builder.buildMessageSpans(msg, 'test', Colors.black);
    expect(textOnly.any((s) => s is WidgetSpan), isFalse);

    builder.showGifs = true;
    final withGif = builder.buildMessageSpans(msg, 'test', Colors.black);
    expect(identical(withGif, textOnly), isFalse);
    expect(withGif.any((s) => s is WidgetSpan), isTrue);
    expect(
      withGif.whereType<TextSpan>().any(
        (s) => s.text?.contains('world') ?? false,
      ),
      isTrue,
      reason: 'the gap after the gif range still renders as text',
    );

    builder.gifHeight = 200;
    final resized = builder.buildMessageSpans(msg, 'test', Colors.black);
    expect(identical(resized, withGif), isFalse);
    expect(resized.any((s) => s is WidgetSpan), isTrue);
  });

  group('image embeds', () {
    test('detects image urls by extension or known host', () {
      const yes = [
        'https://example.com/a.png',
        'https://example.com/a.JPG?x=1#y',
        'http://example.com/a.webp',
        'https://kappa.lol/abc',
        'https://sub.kappa.lol/abc',
        'https://kappa.lol/abc.gif',
      ];
      const no = [
        'https://example.com/a.mp4',
        'https://example.com/page',
        'https://example.com/a.png/',
        'https://kappa.lol',
        'https://kappa.lol/abc.mp4',
        'https://youtu.be/abc',
        'not a url',
      ];
      for (final url in yes) {
        expect(isImageEmbedCandidate(url), isTrue, reason: url);
      }
      for (final url in no) {
        expect(isImageEmbedCandidate(url), isFalse, reason: url);
      }
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

      // Toggling the setting rebuilds a cached message.
      final msg = imgMsg('img4', 'look https://example.com/a.png ok');
      final off = (makeBuilder(em)..showImages = false).buildMessageSpans(
        msg,
        'test',
        Colors.black,
        onImageTap: tapped.add,
      );
      expect(off.any((s) => s is WidgetSpan), isFalse);
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

    test('links split and spaced domains to one url', () {
      const cases = [
        (
          'check example .com/ out',
          ['com'],
          'https://example.com/',
          'example .com/',
        ),
        (
          'check example. com/ out',
          ['com'],
          'https://example.com/',
          'example. com/',
        ),
        ('see example. com/foo', ['com'], 'https://example.com/foo', null),
        ('see example . com / foo', ['com'], 'https://example.com/foo', null),
        ('check example .com out', ['com'], 'https://example.com', null),
        (
          'watch kappa .lol/ABCDE now',
          ['kappa.lol'],
          'https://kappa.lol/ABCDE',
          null,
        ),
        (
          'see sub .kappa.lol/x',
          ['kappa.lol'],
          'https://sub.kappa.lol/x',
          null,
        ),
        (
          'see i .nuuls .com/ ABCD',
          ['i.nuuls.com'],
          'https://i.nuuls.com/',
          null,
        ),
      ];
      for (final (text, whitelist, url, shown) in cases) {
        final urls = urlsOf(text, whitelist);
        expect(urls, hasLength(1), reason: text);
        expect(urls.single.url, url, reason: text);
        if (shown != null) expect(urls.single.text, shown, reason: text);
      }
    });

    test('links bare whitelisted domains and paths', () {
      final bare = urlsOf('check x.com out', ['x.com']);
      expect(bare.single.url, 'https://x.com');
      expect(bare.single.text, 'x.com', reason: 'no scheme shown');
      expect(urlsOf('check x.com out', ['com']).single.url, 'https://x.com');
      final path = urlsOf('check kappa.lol/tests out', ['kappa.lol']);
      expect(path.single.url, 'https://kappa.lol/tests');
      expect(path.single.text, 'kappa.lol/tests');
    });

    test('bare linking works, fractures need detection on', () {
      final bare = WhitelistLinkifier(const [
        'x.com',
      ], fractures: false).parse([TextElement('check x.com out')], options);
      expect(bare.whereType<UrlElement>().single.url, 'https://x.com');
      final fractured = WhitelistLinkifier(
        const ['com'],
        fractures: false,
      ).parse([TextElement('check example .com/ out')], options);
      expect(fractured.whereType<UrlElement>(), isEmpty);
    });

    test('leaves non-links, emails and scheme URLs alone', () {
      const cases = [
        ('that was nice. gg guys', ['gg']),
        ('that was cool. lol', ['lol']),
        ('hello. world', ['world']),
        ('lol that was funny', ['lol']),
        ('check example. com/ out', ['net']),
        ('check example .com/ out', ['net']),
        ('check x.com out', ['net']),
        ('mail foo@gmail.com today', ['com']),
        ('mail foo@gmail.com today', ['gmail.com']),
        ('visit https://x.com/a today', ['x.com']),
        ('visit https://example.com/a today', ['com']),
      ];
      for (final (text, whitelist) in cases) {
        expect(urlsOf(text, whitelist), isEmpty, reason: text);
      }
      final empty = runLinkifier('check example. com/ out', []);
      expect(empty.single, isA<TextElement>());
      final scheme = runLinkifier('visit https://example.com/a today', ['com']);
      expect(scheme.single.text, 'visit https://example.com/a today');
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

    test('leaves unlisted domains, longer labels, emails and subdomains', () {
      const cases = [
        'check y.com/abc out',
        'check q.net/abc out',
        'check ax.com/abc out',
        'mail foo@gmail.com today',
        'visit www.x.com/a today',
        'visit sub.x.com/a today',
      ];
      for (final text in cases) {
        expect(runSingle(text), isEmpty, reason: text);
      }
    });

    test('links scheme URLs and trims trailing sentence periods', () {
      final scheme = runSingle('visit https://x.com/a today');
      expect(scheme.single.url, 'https://x.com/a');
      expect(scheme.single.text, 'https://x.com/a');
      final dotted = runSingle('visit x.com.');
      expect(dotted.single.url, 'https://x.com');
      expect(dotted.single.text, 'x.com');
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

    test('claims plain and multiple email addresses', () {
      final one = runEmail('mail foo@gmail.com today');
      expect(
        one.whereType<EmailElement>().single.emailAddress,
        'foo@gmail.com',
      );
      final two = runEmail('a@b.co and c@d.io');
      expect(two.whereType<EmailElement>().map((e) => e.emailAddress), [
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

    test('drops duplicate-bypass marks so they cannot wrap alone', () {
      String plain(List<InlineSpan> spans) =>
          spans.map((s) => (s as TextSpan).text).join();
      // Real message: two spaces then a CGJ from a 7TV dedupe suffix.
      expect(plain(parseTextWithLinks('Bussin eat  \u034F')), 'Bussin eat ');
      expect(plain(parseTextWithLinks('hi \u{E0000}')), 'hi ');
      // Emoji ZWJ sequences keep their joiners.
      const family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}';
      expect(plain(parseTextWithLinks('hey $family')), 'hey $family');
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

  group('user sheet detents', () {
    const minExtent = 0.25;
    const cardExtent = 0.4;
    const maxExtent = 1.0;

    test('nearest detent snaps to the closest', () {
      double nearest(double size) => userSheetNearestDetent(
        size,
        minExtent: minExtent,
        cardExtent: cardExtent,
        maxExtent: maxExtent,
      );
      for (final d in [minExtent, cardExtent, maxExtent]) {
        expect(nearest(d), d);
      }
      expect(nearest(0.3), minExtent);
      expect(nearest(0.6), cardExtent);
      expect(nearest(0.9), maxExtent);
    });

    // A sheet left between detents eases to the nearer of card and max.
    test('rest target eases between detents and stays on a detent', () {
      double? rest(double size) => userSheetRestTarget(
        size,
        minExtent: 0,
        cardExtent: 0.4,
        maxExtent: 1.0,
      );
      expect(rest(0.55), 0.4);
      expect(rest(0.8), 1.0);
      expect(rest(0.2), 0.4);
      for (final d in [0.4, 1.0, 0.0]) {
        expect(rest(d), isNull);
      }
    });

    test('release target uses distance when slow, velocity when fast', () {
      double target(double size, double velocityDy) => userSheetTargetDetent(
        size,
        minExtent: minExtent,
        cardExtent: cardExtent,
        maxExtent: maxExtent,
        velocityDy: velocityDy,
      );
      expect(target(0.3, 100), minExtent);
      expect(target(0.6, -100), cardExtent);
      expect(target(0.9, 100), maxExtent);
      expect(target(0.3, -1000), cardExtent);
      expect(target(cardExtent, -1000), maxExtent);
      expect(target(0.8, -1000), maxExtent);
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

    test('scopes decide whether text or sender is matched', () {
      const any = ChatSearchFilter(query: 'sys');
      expect(searchMatches(searchMsg('sys', isSystem: true), any), isFalse);

      const messages = ChatSearchFilter(
        query: 'bob',
        scope: ChatSearchScope.messages,
      );
      expect(searchMatches(searchMsg('hi bob'), messages), isTrue);
      expect(searchMatches(searchMsg('hi', login: 'bob'), messages), isFalse);

      const chatters = ChatSearchFilter(
        query: 'bob',
        scope: ChatSearchScope.chatters,
      );
      expect(searchMatches(searchMsg('hi', login: 'bob'), chatters), isTrue);
      expect(searchMatches(searchMsg('hi bob'), chatters), isFalse);

      const kappa = ChatSearchFilter(
        query: 'kappa',
        scope: ChatSearchScope.chatters,
      );
      expect(
        searchMatches(searchMsg('hi', displayName: 'KappaKid'), kappa),
        isTrue,
        reason: 'display names match case-insensitively',
      );
    });

    test('visibleMessages reflects a message inserted mid-search', () {
      final chat = Chat();
      chat.ensure('test');
      TwitchMessage row(String text, String id) =>
          TwitchMessage(login: 'bob', text: text, messageId: id);
      chat.receive(
        'test',
        row('hello', '1'),
        maxMessages: 100,
        isSelected: true,
        ownLogin: 'me',
      );
      final search = SearchPanels(
        chat: chat,
        selectedChannel: () => 'test',
        isMounted: () => true,
        markDirty: () {},
        showInput: () => false,
        setShowInput: (_) {},
        emoteSheetOpen: () => false,
        closeEmoteSheet: () async {},
        clearComposerSuggestions: () {},
        composerFocusNode: FocusNode(),
      );
      search.open = true;
      search.setQuery('test', 'hello');
      expect(search.visibleMessages('test').length, 1);

      chat.receive(
        'test',
        row('hello again', '2'),
        maxMessages: 100,
        isSelected: true,
        ownLogin: 'me',
      );
      expect(search.visibleMessages('test').length, 2);
    });
  });

  test('resolveThreadRootId walks to the root and survives cycles', () {
    expect(resolveThreadRootId('c', {'c': 'b', 'b': 'a'}), 'a');
    expect(resolveThreadRootId('a', {'a': 'b', 'b': 'a'}), isNotEmpty);
    expect(resolveThreadRootId('a', {'a': 'a'}), 'a');
  });
}
