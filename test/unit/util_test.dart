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
import 'package:ermchat/util/crash_report.dart';
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
        'PRIMARY': Color(0xFF9146FF),
        'BLUE': Color(0xFF1F69FF),
        'GREEN': Color(0xFF00C853),
        'ORANGE': Color(0xFFFF6F00),
        'PURPLE': Color(0xFF9146FF),
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
}
