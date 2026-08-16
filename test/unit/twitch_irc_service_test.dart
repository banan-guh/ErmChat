import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/twitch_irc.dart';

void main() {
  late IrcService service;

  setUp(() {
    service = IrcService();
  });

  tearDown(() {
    service.dispose();
  });

  group('channel tracking', () {
    test('join does not crash when not connected', () {
      expect(() => service.join('testchannel'), returnsNormally);
    });

    test('part does not crash when not connected', () {
      expect(() => service.part('testchannel'), returnsNormally);
    });
  });

  group('CLEARMSG', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('emits delete event with messageId, user, and deleted text', () async {
      final events = <IrcMessageDeletedEvent>[];
      service.onMessageDeleted.listen(events.add);

      service.handleLine(
        '@login=forsen;target-msg-id=abc-123 :tmi.twitch.tv CLEARMSG #xqc :bad message',
      );
      await flush();

      expect(events, hasLength(1));
      expect(events[0].channel, 'xqc');
      expect(events[0].messageId, 'abc-123');
      expect(events[0].user, 'forsen');
      expect(events[0].deletedMessageText, 'bad message');
    });

    test('ignores CLEARMSG without target-msg-id', () async {
      final events = <IrcMessageDeletedEvent>[];
      service.onMessageDeleted.listen(events.add);

      service.handleLine(
        '@login=forsen :tmi.twitch.tv CLEARMSG #xqc :bad message',
      );
      await flush();

      expect(events, isEmpty);
    });

    test('defaults user to unknown when login tag missing', () async {
      final events = <IrcMessageDeletedEvent>[];
      service.onMessageDeleted.listen(events.add);

      service.handleLine(
        '@target-msg-id=xyz :tmi.twitch.tv CLEARMSG #xqc :deleted',
      );
      await flush();

      expect(events, hasLength(1));
      expect(events[0].user, 'unknown');
    });
  });

  group('CLEARCHAT', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('emits ban event for permanent ban', () async {
      final events = <IrcBanEvent>[];
      service.onBan.listen(events.add);

      service.handleLine(':tmi.twitch.tv CLEARCHAT #xqc :forsen');
      await flush();

      expect(events, hasLength(1));
      expect(events[0].channel, 'xqc');
      expect(events[0].user, 'forsen');
      expect(events[0].isTimeout, isFalse);
      expect(events[0].duration, isNull);
    });

    test('emits timeout event with duration', () async {
      final events = <IrcBanEvent>[];
      service.onBan.listen(events.add);

      service.handleLine(
        '@ban-duration=300;target-user-id=12345 :tmi.twitch.tv CLEARCHAT #xqc :forsen',
      );
      await flush();

      expect(events, hasLength(1));
      expect(events[0].user, 'forsen');
      expect(events[0].isTimeout, isTrue);
      expect(events[0].duration, 300);
      expect(events[0].userId, '12345');
    });

    test('emits channel clear for full room clear (no target user)', () async {
      final bans = <IrcBanEvent>[];
      final clears = <IrcChannelClearEvent>[];
      service.onBan.listen(bans.add);
      service.onChannelClear.listen(clears.add);

      service.handleLine(':tmi.twitch.tv CLEARCHAT #xqc');
      await flush();

      expect(bans, isEmpty);
      expect(clears, hasLength(1));
      expect(clears[0].channel, 'xqc');
    });
  });

  group('ROOMSTATE', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('parses full room state', () async {
      final states = <IrcRoomStateEvent>[];
      service.onRoomState.listen(states.add);

      service.handleLine(
        '@emote-only=0;followers-only=30;r9k=1;room-id=1;slow=10;subs-only=1 '
        ':tmi.twitch.tv ROOMSTATE #xqc',
      );
      await flush();

      expect(states, hasLength(1));
      expect(states[0].channel, 'xqc');
      expect(states[0].tags['slow'], '10');
      expect(states[0].tags['followers-only'], '30');
      expect(states[0].tags['emote-only'], '0');
      expect(states[0].tags['subs-only'], '1');
      expect(states[0].tags['r9k'], '1');
    });
  });

  group('USERSTATE / GLOBALUSERSTATE', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('lines are safely ignored', () async {
      var messageCount = 0;
      service.onMessage.listen((_) => messageCount++);

      service.handleLine(
        '@badges=moderator/1,vip/1;user-id=123 '
        ':tmi.twitch.tv USERSTATE #xqc',
      );
      service.handleLine('@badges=staff/1 :tmi.twitch.tv GLOBALUSERSTATE');
      await flush();

      expect(messageCount, 0);
    });

    test('emits emote-sets from GLOBALUSERSTATE without channel', () async {
      final sets = <(String?, List<String>)>[];
      service.onUserEmoteSets.listen(sets.add);

      service.handleLine(
        '@emote-sets=0,123456789,987654321 :tmi.twitch.tv GLOBALUSERSTATE',
      );
      await flush();

      expect(sets, hasLength(1));
      expect(sets.single.$1, isNull);
      expect(sets.single.$2, <String>['0', '123456789', '987654321']);
    });

    test('emits channel-scoped emote-sets from USERSTATE', () async {
      final sets = <(String?, List<String>)>[];
      service.onUserEmoteSets.listen(sets.add);

      service.handleLine(
        '@emote-sets=300374079,0 :tmi.twitch.tv USERSTATE #xqc',
      );
      await flush();

      expect(sets, hasLength(1));
      expect(sets.single.$1, 'xqc');
      expect(sets.single.$2, <String>['300374079', '0']);
    });

    test('does not emit when emote-sets tag is missing', () async {
      var emitted = false;
      service.onUserEmoteSets.listen((_) => emitted = true);

      service.handleLine('@badges=staff/1 :tmi.twitch.tv GLOBALUSERSTATE');
      await flush();

      expect(emitted, isFalse);
    });
  });

  group('USERNOTICE', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test(
      'routes to onUserNotice, not onNotice (dispatch regression)',
      () async {
        final notices = <IrcNoticeEvent>[];
        final userNotices = <UserNoticeEvent>[];
        service.onNotice.listen(notices.add);
        service.onUserNotice.listen(userNotices.add);

        service.handleLine(
          '@msg-id=announcement;msg-param-color=PRIMARY;login=mm2pl;'
          'display-name=Mm2PL;system-msg=;'
          ':tmi.twitch.tv USERNOTICE #xqc :test',
        );
        await flush();

        expect(
          notices,
          isEmpty,
          reason: 'USERNOTICE must not be swallowed by the NOTICE handler',
        );
        expect(userNotices, hasLength(1));
        expect(userNotices[0].msgId, 'announcement');
        expect(userNotices[0].text, 'test');
        expect(userNotices[0].announcementColor, 'PRIMARY');
      },
    );

    test('parses announcement emotes into emote positions', () async {
      final userNotices = <UserNoticeEvent>[];
      service.onUserNotice.listen(userNotices.add);

      service.handleLine(
        '@msg-id=announcement;msg-param-color=GREEN;login=mm2pl;'
        'display-name=Mm2PL;emotes=emotesv2_123:0-7;system-msg=;'
        ':tmi.twitch.tv USERNOTICE #xqc :PogChamp test',
      );
      await flush();

      expect(userNotices, hasLength(1));
      expect(userNotices[0].emotePositions, isNotNull);
      expect(userNotices[0].emotePositions!.single.emoteCode, 'PogChamp');
      expect(userNotices[0].emotePositions!.single.startIndex, 0);
      expect(userNotices[0].emotePositions!.single.endIndex, 8);
    });

    test('NOTICE still routes to onNotice', () async {
      final notices = <IrcNoticeEvent>[];
      service.onNotice.listen(notices.add);

      service.handleLine(
        '@msg-id=slow_on :tmi.twitch.tv NOTICE #xqc :This room is now in slow mode.',
      );
      await flush();

      expect(notices, hasLength(1));
      expect(notices[0].msgId, 'slow_on');
      expect(notices[0].message, contains('slow mode'));
    });
  });

  group('WHISPER', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('emits a TwitchMessage via onWhisper', () async {
      final whispers = <TwitchMessage>[];
      service.onWhisper.listen(whispers.add);

      service.handleLine(
        '@badges=;color=#FF0000;display-name=SomeUser;emotes=25:0-4;message-id=whisper-1;thread-id=abc;turbo=0;user-id=999;user-type= :someuser!someuser@someuser.tmi.twitch.tv WHISPER recipient :hey there',
      );
      await flush();

      expect(whispers, hasLength(1));
      final w = whispers[0];
      expect(w.login, 'someuser');
      expect(w.displayName, 'SomeUser');
      expect(w.text, 'hey there');
      expect(w.messageId, 'whisper-1');
      expect(w.channel, isNull);
      expect(w.color, '#FF0000');
    });
  });

  group('dispose', () {
    test('double dispose does not crash', () {
      service.dispose();
      expect(() => service.dispose(), returnsNormally);
    });
  });
}
