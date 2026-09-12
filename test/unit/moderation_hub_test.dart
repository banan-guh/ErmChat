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
    hub = ModerationHub(
      chat: chat,
      session: session,
      isModerationActive: (_) => moderationActive,
      onSystemMessage: (c, t) => lines.add((c, t)),
      onAnalyticsModeration: (c, isTimeout) => analytics.add((c, isTimeout)),
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

  test('IRC ban is suppressed while moderate covers it', () {
    moderationActive = true;
    hub.onIrcBan(
      channel: 'test',
      user: 'spammer',
      isTimeout: false,
      duration: null,
    );
    expect(analytics, isEmpty);
    expect(lines, isEmpty);
  });

  test('a ban reported by both sources counts analytics once', () {
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

  test('IRC clear is skipped while moderate is active', () {
    moderationActive = true;
    hub.onIrcClear('test');
    expect(lines, isEmpty);
  });
}
