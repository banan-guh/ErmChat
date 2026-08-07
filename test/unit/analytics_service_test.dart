import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/analytics_service.dart';
import 'package:ermchat/services/emote_manager.dart';

TwitchMessage msg(
  String login,
  String text, {
  List<EmotePosition>? positions,
  bool isSystem = false,
  bool isHistory = false,
  bool isBackfill = false,
}) {
  return TwitchMessage(
    login: login,
    text: text,
    channel: 'chan',
    emotePositions: positions,
    isSystem: isSystem,
    isHistory: isHistory,
    isBackfill: isBackfill,
  );
}

ChannelEmotes emoteMap(Map<String, GenericEmote> byCode) {
  return ChannelEmotes(byCode: byCode, suggestions: byCode.values.toList());
}

void main() {
  group('AnalyticsService', () {
    test('records totals, unique chatters and top chatters', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('alice', 'hi'));
      service.recordMessage('chan', msg('bob', 'hello'));
      service.recordMessage('chan', msg('alice', 'again'));

      expect(service.totalMessages('chan'), 3);
      expect(service.uniqueChatters('chan'), 2);
      expect(service.trackingStartedAt('chan'), isNotNull);

      final top = service.topChatters('chan', 10);
      expect(top, hasLength(2));
      expect(top.first.name, 'alice');
      expect(top.first.count, 2);
    });

    test('excludes system, history and backfill messages', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('alice', 'real'));
      service.recordMessage('chan', msg('bot', 'sys', isSystem: true));
      service.recordMessage('chan', msg('bot', 'hist', isHistory: true));
      service.recordMessage('chan', msg('bot', 'back', isBackfill: true));

      expect(service.totalMessages('chan'), 1);
      expect(service.uniqueChatters('chan'), 1);
    });

    test('ignores blank logins', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('', 'anon'));

      expect(service.totalMessages('chan'), 1);
      expect(service.uniqueChatters('chan'), 0);
      expect(service.topChatters('chan', 10), isEmpty);
    });

    test('counts twitch emotes from positions and remaining text as words', () {
      final service = AnalyticsService();
      final positions = [
        EmotePosition(
          emoteId: '123',
          startIndex: 0,
          endIndex: 8,
          emoteCode: 'PogChamp',
        ),
      ];
      service.recordMessage(
        'chan',
        msg('alice', 'PogChamp hello', positions: positions),
      );

      final emotes = service.topEmotes('chan', 10);
      expect(emotes, hasLength(1));
      expect(emotes.first.emote.code, 'PogChamp');
      expect(emotes.first.count, 1);
      expect(service.topWords('chan', 10).single.word, 'hello');
    });

    test('counts third-party emotes by token match', () {
      final service = AnalyticsService(
        emoteLookup: (_) => emoteMap({
          'monkaS': GenericEmote(
            id: 'b1',
            code: 'monkaS',
            type: EmoteType.bttv,
            url: 'https://x',
          ),
        }),
      );
      service.recordMessage('chan', msg('alice', 'monkaS monkaS hi'));

      final emotes = service.topEmotes('chan', 10);
      expect(emotes, hasLength(1));
      expect(emotes.first.emote.code, 'monkaS');
      expect(emotes.first.count, 2);
      expect(service.topWords('chan', 10).single.word, 'hi');
    });

    test('twitch positions take precedence over token match', () {
      final service = AnalyticsService(
        emoteLookup: (_) => emoteMap({
          'PogChamp': GenericEmote(
            id: 'b1',
            code: 'PogChamp',
            type: EmoteType.bttv,
            url: 'https://x',
          ),
        }),
      );
      final positions = [
        EmotePosition(
          emoteId: '123',
          startIndex: 0,
          endIndex: 8,
          emoteCode: 'PogChamp',
        ),
        EmotePosition(
          emoteId: '123',
          startIndex: 9,
          endIndex: 17,
          emoteCode: 'PogChamp',
        ),
      ];
      service.recordMessage(
        'chan',
        msg('alice', 'PogChamp PogChamp', positions: positions),
      );

      final emotes = service.topEmotes('chan', 10);
      expect(emotes, hasLength(1));
      expect(emotes.first.emote.id, 'b1');
      expect(emotes.first.count, 2);
      expect(service.topWords('chan', 10), isEmpty);
    });

    test('normalizes words and strips punctuation', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('alice', 'Hello, world!!'));

      final words = service.topWords('chan', 10);
      expect(words, hasLength(2));
      expect(words.any((w) => w.word == 'hello'), isTrue);
      expect(words.any((w) => w.word == 'world'), isTrue);
    });

    test('stopword filter excludes common words', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('alice', 'the cat and dog'));

      final raw = service.topWords('chan', 10);
      expect(raw, hasLength(4));

      final filtered = service.topWords('chan', 10, useStopwords: true);
      final filteredWords = filtered.map((w) => w.word).toList();
      expect(filteredWords, contains('cat'));
      expect(filteredWords, contains('dog'));
      expect(filteredWords, isNot(contains('the')));
      expect(filteredWords, isNot(contains('and')));
    });

    test('messages per minute rolls off after 60 minutes', () {
      var now = DateTime(2024, 1, 1, 12, 0, 0);
      final service = AnalyticsService(now: () => now);

      for (var i = 0; i < 5; i++) {
        service.recordMessage('chan', msg('alice', 'hello'));
      }
      expect(service.messagesPerMinute('chan'), 5.0);

      now = now.add(const Duration(minutes: 61));
      service.recordMessage('chan', msg('alice', 'new hour'));

      final rate = service.messagesPerMinute('chan');
      expect(rate, closeTo(1 / 60, 0.0001));
      expect(service.totalMessages('chan'), 6);
    });

    test('messages per minute is zero without messages', () {
      final service = AnalyticsService();
      expect(service.messagesPerMinute('chan'), 0);
    });

    test('records moderation bans and timeouts', () {
      final service = AnalyticsService();
      service.recordModeration('chan', false);
      service.recordModeration('chan', true);
      service.recordModeration('chan', true);

      expect(service.banCount('chan'), 1);
      expect(service.timeoutCount('chan'), 2);
    });

    test('resets single channel', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('alice', 'hi'));
      service.recordMessage('other', msg('bob', 'yo'));

      service.resetChannel('chan');
      expect(service.isTracking('chan'), isFalse);
      expect(service.totalMessages('chan'), 0);
      expect(service.isTracking('other'), isTrue);
    });

    test('resets all channels', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('alice', 'hi'));
      service.recordMessage('other', msg('bob', 'yo'));

      service.resetAll();
      expect(service.trackedChannels(), isEmpty);
    });

    test('notifies listeners on record', () {
      final service = AnalyticsService();
      var notified = 0;
      service.addListener(() => notified++);

      service.recordMessage('chan', msg('alice', 'hi'));
      service.recordModeration('chan', true);

      expect(notified, 2);
    });

    test('keeps channels isolated', () {
      final service = AnalyticsService();
      service.recordMessage('chan', msg('alice', 'hi'));

      expect(service.totalMessages('other'), 0);
      expect(service.uniqueChatters('other'), 0);
    });
  });
}
