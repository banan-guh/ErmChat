import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/client/session.dart';
import 'package:ermchat/eventsub/decode/events.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/moderation_hub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Chat chat;
  late Session session;
  late List<(String, String)> lines;
  late List<(String, bool)> analytics;
  late Map<String, DateTime> armed;
  late Set<String> cleared;
  late bool moderationActive;
  late List<String> archived;
  late ModerationHub hub;

  setUp(() {
    chat = Chat();
    chat.ensure('test');
    session = Session();
    lines = [];
    analytics = [];
    armed = {};
    cleared = {};
    moderationActive = false;
    archived = [];
    hub = ModerationHub(
      chat: chat,
      session: session,
      isModerationActive: (_) => moderationActive,
      onSystemMessage: (c, t) => lines.add((c, t)),
      onAnalyticsModeration: (c, isTimeout) => analytics.add((c, isTimeout)),
      onArchiveModeration: (c, login, from, to) =>
          archived.add('$c $login ${from.toUtc()}'),
      onSelfTimeoutArmed: (c, until) => armed[c] = until,
      onSelfTimeoutCleared: (c) => cleared.add(c),
    );
  });

  test('IRC ban reports analytics and a line when moderate is off', () {
    hub.onIrcBan(
      channel: 'test',
      user: 'spammer',
      isTimeout: false,
      duration: null,
    );
    expect(analytics, [('test', false)]);
    expect(lines, hasLength(1));
    expect(lines.single.$2, contains('banned'));
  });

  test('a ban reported by both sources counts analytics once', () {
    chat.receive(
      'test',
      TwitchMessage(
        login: 'spammer',
        text: 'buy followers',
        messageId: 'm1',
        timestamp: DateTime.utc(2026, 10, 13, 12),
      ),
      maxMessages: 100,
      isSelected: true,
      ownLogin: null,
    );
    moderationActive = true;
    hub.onModeration(
      ModerationEvent(
        channel: 'test',
        action: ModerationAction.ban,
        rawAction: 'ban',
        moderatorName: 'moduser',
        targetName: 'spammer',
      ),
    );
    hub.onIrcBan(
      channel: 'test',
      user: 'spammer',
      isTimeout: false,
      duration: null,
    );
    expect(analytics, [('test', false)]);
    expect(lines.where((l) => l.$2.contains('banned')), hasLength(1));
    expect(archived, [
      'test spammer 2026-10-13 12:00:00.000Z',
    ], reason: 'one archived clear per ban, from the oldest buffered row');
  });

  test('self timeout arms from the IRC copy even while moderate is active', () {
    moderationActive = true;
    session.seed('me', userId: '1');
    hub.onIrcBan(channel: 'test', user: 'me', isTimeout: true, duration: 60);
    expect(armed, contains('test'));
  });

  test(
    'IRC delete marks the row but skips the line while moderate is active',
    () {
      final msg = TwitchMessage(
        login: 'a',
        text: 'hi',
        messageId: 'm1',
        channel: 'test',
      );
      chat.receive(
        'test',
        msg,
        maxMessages: 10,
        isSelected: true,
        ownLogin: null,
      );
      moderationActive = true;
      hub.onIrcDelete(channel: 'test', messageId: 'm1', user: 'a', text: 'hi');
      expect(chat.channelFor('test')!.messages.byId('m1')!.deleted, isTrue);
      expect(lines, isEmpty);
    },
  );

  test(
    'a repeat ban posts a fresh line once its first row left the buffer',
    () {
      var now = DateTime(2026, 1, 1);
      final channel = chat.channelFor('test')!;
      final clocked = ModerationHub(
        chat: chat,
        session: session,
        isModerationActive: (_) => false,
        onSystemMessage: (c, t) => channel.messages.addSystem(t),
        onSelfTimeoutArmed: (c, until) => armed[c] = until,
        onSelfTimeoutCleared: (c) => cleared.add(c),
        now: () => now,
      );
      void ban() => clocked.onIrcBan(
        channel: 'test',
        user: 'spammer',
        isTimeout: false,
        duration: null,
      );
      ban();
      channel.messages.removeWhere((_) => true);
      expect(channel.messages.items, isEmpty);
      now = now.add(const Duration(seconds: 5));
      ban();
      expect(
        channel.messages.items,
        hasLength(1),
        reason: 'stacked ban whose first row is gone must post again',
      );
      now = now.add(const Duration(seconds: 11));
      ban();
      expect(channel.messages.items.first.text, isNot(contains('2')));
    },
  );

  test('IRC ban and clear are suppressed while moderate covers them', () {
    moderationActive = true;
    hub.onIrcBan(
      channel: 'test',
      user: 'spammer',
      isTimeout: false,
      duration: null,
    );
    hub.onIrcClear('test');
    expect(analytics, isEmpty);
    expect(lines, isEmpty);
  });
}
