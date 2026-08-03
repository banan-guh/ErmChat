import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/recent_messages.dart';

void main() {
  group('parseIrcLine', () {
    test('parses basic PRIVMSG', () {
      const raw =
          '@display-name=forsen;color=#FF0000;id=abc-123;rm-received-ts=1700000000000 :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :Hello chat';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.login, 'forsen');
      expect(msg.text, 'Hello chat');
      expect(msg.color, '#FF0000');
      expect(msg.messageId, 'abc-123');
      expect(msg.isHistory, isTrue);
      expect(msg.channel, isNull);
    });

    test('parses message without color tag', () {
      const raw =
          '@display-name=forsen;id=def-456;rm-received-ts=1700000000000 :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :no color';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.login, 'forsen');
      expect(msg.text, 'no color');
      expect(msg.color, isNotNull);
      expect(msg.color!.startsWith('#'), isTrue);
    });

    test('parses reply IRC tags', () {
      const raw =
          '@display-name=forsen;id=ghi-789;rm-received-ts=1700000000000;reply-parent-msg-id=parent-123;reply-parent-display-name=previousUser;reply-parent-msg-body=original%20message :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :@previousUser reply text';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.replyToParentId, 'parent-123');
      expect(msg.replyToUser, 'previousUser');
      expect(msg.replyToText, 'original message');
      expect(msg.text, 'reply text');
    });

    test('strips @User prefix in reply', () {
      const raw =
          '@display-name=forsen;id=xxx-111;rm-received-ts=1700000000000;reply-parent-msg-id=parent-123;reply-parent-display-name=SomeUser;reply-parent-msg-body=hey :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :@SomeUser hello there';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.replyToUser, 'SomeUser');
      expect(msg.text, 'hello there');
    });

    test('handles malformed URI in reply tag', () {
      const raw =
          '@display-name=forsen;id=yyy-222;rm-received-ts=1700000000000;reply-parent-msg-id=parent-456;reply-parent-display-name=User;reply-parent-msg-body=%ZZinvalid :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :@User hi';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.replyToText, '%ZZinvalid');
    });

    test('returns null for JOIN', () {
      const raw = '@display-name=forsen :tmi.twitch.tv JOIN #xqc';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNull);
    });

    test('parses timeout CLEARCHAT', () {
      const raw =
          '@ban-duration=300;target-user-id=974273622;rm-received-ts=1700000000000;historical=1 :tmi.twitch.tv CLEARCHAT #ermugo2 :ermugo1';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.isSystem, isTrue);
      expect(msg.text, 'ermugo1 was timed out for 300s.');
      expect(msg.isHistory, isTrue);
      expect(msg.channel, isNull);
      expect(msg.timestamp.millisecondsSinceEpoch, 1700000000000);
    });

    test('parses ban CLEARCHAT without ban-duration', () {
      const raw =
          '@target-user-id=974273622;rm-received-ts=1700000000000 :tmi.twitch.tv CLEARCHAT #ermugo2 :ermugo1';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.isSystem, isTrue);
      expect(msg.text, 'ermugo1 was banned.');
      expect(msg.isHistory, isTrue);
    });

    test('parses robotty CLEARCHAT without trailing colon', () {
      const raw =
          '@ban-duration=300;target-user-id=974273622;rm-received-ts=1700000000000;historical=1 :tmi.twitch.tv CLEARCHAT #ermugo2 ermugo1';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.text, 'ermugo1 was timed out for 300s.');
      expect(msg.isBanNotice, isTrue);
    });

    test('parses CLEARCHAT with channel parameter', () {
      const raw =
          '@ban-duration=1;rm-received-ts=1700000000000 :tmi.twitch.tv CLEARCHAT #ermugo2 :ermugo1';
      final msg = RecentMessagesService.parseIrcLine(raw, channel: 'ermugo2');
      expect(msg, isNotNull);
      expect(msg!.channel, 'ermugo2');
    });

    test('CLEARCHAT without trailing returns null', () {
      const raw =
          '@ban-duration=300;rm-received-ts=1700000000000 :tmi.twitch.tv CLEARCHAT #ermugo2';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNull);
    });

    test('returns null for empty display-name and text', () {
      const raw =
          '@display-name=;id=zzz-333 :user!user@user.tmi.twitch.tv PRIVMSG #xqc :';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNull);
    });

    test('parses timestamp from rm-received-ts', () {
      const raw =
          '@display-name=test;id=ts-1;rm-received-ts=1700000000000 :test!test@test.tmi.twitch.tv PRIVMSG #xqc :hello';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.timestamp.millisecondsSinceEpoch, 1700000000000);
    });

    test('assigns consistent color from palette', () {
      const raw =
          '@display-name=SomeUser;id=c1;rm-received-ts=1700000000000 :user!user@user.tmi.twitch.tv PRIVMSG #xqc :msg1';
      const raw2 =
          '@display-name=SomeUser;id=c2;rm-received-ts=1700001000000 :user!user@user.tmi.twitch.tv PRIVMSG #xqc :msg2';
      final msg1 = RecentMessagesService.parseIrcLine(raw);
      final msg2 = RecentMessagesService.parseIrcLine(raw2);
      expect(msg1!.color, msg2!.color);
    });

    test('parses reply with emotes without crashing', () {
      // Original text: '@SomeUser hello forsenE' (23 chars)
      // Emote 123456 at original positions 16-22 (inclusive) = 'forsenE'
      // After stripping '@SomeUser ' (10 chars), displayText = 'hello forsenE' (13 chars)
      // Without fix: displayText.substring(16, 23) would throw RangeError
      const raw =
          '@display-name=testuser;id=em-reply-1;rm-received-ts=1700000000000;reply-parent-msg-id=parent-789;reply-parent-display-name=SomeUser;reply-parent-msg-body=hi;emotes=123456:16-22 :testuser!testuser@testuser.tmi.twitch.tv PRIVMSG #xqc :@SomeUser hello forsenE';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.text, 'hello forsenE');
      expect(msg.emotePositions, hasLength(1));
      expect(msg.emotePositions!.first.emoteId, '123456');
      expect(msg.emotePositions!.first.emoteCode, 'forsenE');
      // Adjusted positions: 16-10=6 start, 22-10=12 end (inclusive) → endIndex=13
      expect(msg.emotePositions!.first.startIndex, 6);
      expect(msg.emotePositions!.first.endIndex, 13);
    });

    test('parses non-reply emotes unchanged', () {
      const raw =
          '@display-name=testuser;id=em-noreply-1;rm-received-ts=1700000000000;emotes=123456:6-12 :testuser!testuser@testuser.tmi.twitch.tv PRIVMSG #xqc :hello forsenE';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.text, 'hello forsenE');
      expect(msg.emotePositions, hasLength(1));
      expect(msg.emotePositions!.first.emoteCode, 'forsenE');
      expect(msg.emotePositions!.first.startIndex, 6);
      expect(msg.emotePositions!.first.endIndex, 13);
    });

    test('parses single-word message without trailing colon', () {
      const raw =
          '@display-name=testuser;id=single-1;rm-received-ts=1700000000000 :testuser!testuser@testuser.tmi.twitch.tv PRIVMSG #xqc eerm';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.login, 'testuser');
      expect(msg.text, 'eerm');
    });

    test('parses resub USERNOTICE into a system message', () {
      const raw =
          '@msg-id=resub;system-msg=ronni\\shas\\ssubscribed\\sfor\\s6\\smonths!;login=ronni;display-name=ronni;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :Great stream!';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.isSystem, isTrue);
      expect(msg.text, 'ronni has subscribed for 6 months! "Great stream!"');
      expect(msg.login, isEmpty, reason: 'non-announcement notices drop login');
    });

    test('parses subgift USERNOTICE without user message', () {
      const raw =
          '@msg-id=subgift;system-msg=TWW2\\sgifted\\sa\\sTier\\s1\\ssub\\sto\\sMr_Woodchuck!;login=tww2;display-name=TWW2;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.isSystem, isTrue);
      expect(msg.text, 'TWW2 gifted a Tier 1 sub to Mr_Woodchuck!');
    });

    test('parses announcement USERNOTICE into label with login', () {
      const raw =
          '@msg-id=announcement;msg-param-color=BLUE;login=mm2pl;display-name=Mm2PL;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :my primary color';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.isSystem, isTrue);
      expect(msg.text, 'Announcement');
      expect(msg.login, 'mm2pl');
      expect(msg.systemAccent, const Color(0xFF1F69FF));
    });

    test('announcement without color falls back to PRIMARY', () {
      const raw =
          '@msg-id=announcement;login=mm2pl;display-name=Mm2PL;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :hello';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.text, 'Announcement');
      expect(msg.systemAccent, const Color(0xFF9146FF));
    });

    test('empty announcement still renders the label', () {
      const raw =
          '@msg-id=announcement;msg-param-color=ORANGE;login=mm2pl;display-name=Mm2PL;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.text, 'Announcement');
      expect(msg.systemAccent, const Color(0xFFFF6F00));
    });

    test('non-announcement notices never carry an accent', () {
      const raw =
          '@msg-id=resub;system-msg=ronni\\shas\\ssubscribed!;login=ronni;display-name=ronni;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.isSystem, isTrue);
      expect(msg.systemAccent, isNull);
    });

    test('returns null for USERNOTICE without msg-id', () {
      const raw =
          '@login=ronni;display-name=ronni;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :hello';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNull);
    });

    test('parses NOTICE into a system message', () {
      const raw =
          '@msg-id=slow_on;rm-received-ts=1700000000000 :tmi.twitch.tv NOTICE #xqc :This room is now in slow mode.';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.isSystem, isTrue);
      expect(msg.text, 'This room is now in slow mode.');
      expect(msg.isHistory, isTrue);
    });

    test('returns null for NOTICE without text', () {
      const raw = ':tmi.twitch.tv NOTICE #xqc';
      expect(RecentMessagesService.parseIrcLine(raw), isNull);
    });
  });

  group('parseAnnouncementChild', () {
    test('parses announcement text as a normal chat message', () {
      const raw =
          '@msg-id=announcement;msg-param-color=BLUE;login=mm2pl;display-name=Mm2PL;color=#FF0000;badges=broadcaster/1;id=abc-123;user-id=456;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :my primary color';
      final child = RecentMessagesService.parseAnnouncementChild(raw);
      expect(child, isNotNull);
      expect(child!.isSystem, isFalse);
      expect(child.text, 'my primary color');
      expect(child.login, 'mm2pl');
      expect(child.displayName, 'Mm2PL');
      expect(child.color, '#FF0000');
      expect(child.userId, '456');
      expect(child.messageId, 'abc-123');
      expect(child.badges, hasLength(1));
      expect(child.badges!.single.setId, 'broadcaster');
      expect(child.systemAccent, const Color(0xFF1F69FF));
      expect(child.isHistory, isTrue);
      expect(
        child.timestamp,
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
    });

    test('parses announcement emotes into emote positions', () {
      const raw =
          '@msg-id=announcement;msg-param-color=GREEN;login=mm2pl;display-name=Mm2PL;emotes=emotesv2_123:0-7;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :PogChamp test';
      final child = RecentMessagesService.parseAnnouncementChild(raw);
      expect(child, isNotNull);
      expect(child!.text, 'PogChamp test');
      expect(child.emotePositions, isNotNull);
      expect(child.emotePositions!.single.emoteCode, 'PogChamp');
      expect(child.emotePositions!.single.startIndex, 0);
      expect(child.emotePositions!.single.endIndex, 8);
      expect(child.systemAccent, const Color(0xFF00C853));
    });

    test('returns null for non-announcement USERNOTICE', () {
      const raw =
          '@msg-id=resub;system-msg=ronni\\shas\\ssubscribed!;login=ronni;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :Great stream!';
      expect(RecentMessagesService.parseAnnouncementChild(raw), isNull);
    });

    test('returns null when announcement has no text', () {
      const raw =
          '@msg-id=announcement;msg-param-color=ORANGE;login=mm2pl;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc';
      expect(RecentMessagesService.parseAnnouncementChild(raw), isNull);
    });

    test('returns null for non-USERNOTICE lines', () {
      const raw =
          '@display-name=forsen :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :hi';
      expect(RecentMessagesService.parseAnnouncementChild(raw), isNull);
    });

    test('parses robotty announcement without trailing colon', () {
      // Real robotty line: single-word message, no colon before the text.
      const raw =
          '@color=#0000FF;id=1151c190-4c78-4f31-b436-d75b3003e68c;mod=0;'
          'rm-received-ts=1785668914195;historical=1;system-msg;'
          'msg-id=announcement;msg-param-color=PRIMARY;user-type;'
          'room-id=1468479097;user-id=1468479097;badge-info;login=ermugo2;'
          'tmi-sent-ts=1785668914100;flags;badges=broadcaster/1;vip=0;'
          'subscriber=0;emotes;display-name=ermugo2 '
          ':tmi.twitch.tv USERNOTICE #ermugo2 uuh';

      final label = RecentMessagesService.parseIrcLine(raw);
      expect(label, isNotNull);
      expect(label!.text, 'Announcement');
      expect(label.systemAccent, const Color(0xFF9146FF));

      final child = RecentMessagesService.parseAnnouncementChild(raw);
      expect(child, isNotNull);
      expect(child!.text, 'uuh');
      expect(child.login, 'ermugo2');
      expect(child.messageId, '1151c190-4c78-4f31-b436-d75b3003e68c');
      expect(child.systemAccent, const Color(0xFF9146FF));
      expect(child.badges, hasLength(1));
    });

    test('parses robotty announcement with multi-word colon text', () {
      const raw =
          '@msg-id=announcement;msg-param-color=GREEN;login=mm2pl;'
          'display-name=Mm2PL;rm-received-ts=1700000000000 '
          ':tmi.twitch.tv USERNOTICE #xqc :multi word message';
      final child = RecentMessagesService.parseAnnouncementChild(raw);
      expect(child, isNotNull);
      expect(child!.text, 'multi word message');
      expect(child.systemAccent, const Color(0xFF00C853));
    });
  });

  group('applyBanSweep', () {
    TwitchMessage message(String id, String login, DateTime ts) =>
        TwitchMessage(
          login: login,
          text: 'hi',
          messageId: id,
          timestamp: ts,
          channel: 'xqc',
        );

    TwitchMessage system(
      String text,
      String login,
      DateTime ts, {
      bool isBanNotice = false,
    }) => TwitchMessage(
      login: login,
      text: text,
      messageId: 'sys-$text',
      isSystem: true,
      isBanNotice: isBanNotice,
      timestamp: ts,
      channel: 'xqc',
    );

    test('ban deletes prior messages from the target user', () {
      final t0 = DateTime(2024, 1, 1, 12, 0, 0);
      final messages = [
        message('m1', 'forsen', t0),
        system(
          'forsen was banned.',
          'forsen',
          t0.add(const Duration(seconds: 5)),
          isBanNotice: true,
        ),
      ];
      RecentMessagesService.applyBanSweep(messages);
      expect(messages[0].deleted, isTrue);
    });

    test('announcement does not trigger deletion sweep', () {
      final t0 = DateTime(2024, 1, 1, 12, 0, 0);
      final messages = [
        message('m1', 'mm2pl', t0),
        message('m2', 'mm2pl', t0.add(const Duration(seconds: 2))),
        system('Announcement: hi', 'mm2pl', t0.add(const Duration(seconds: 5))),
      ];
      RecentMessagesService.applyBanSweep(messages);
      expect(
        messages[0].deleted,
        isFalse,
        reason: 'announcements carry a login but are not bans',
      );
      expect(messages[1].deleted, isFalse);
    });

    test('other users are unaffected by a ban', () {
      final t0 = DateTime(2024, 1, 1, 12, 0, 0);
      final messages = [
        message('m1', 'someone_else', t0),
        message('m2', 'forsen', t0.add(const Duration(seconds: 1))),
        system(
          'forsen was banned.',
          'forsen',
          t0.add(const Duration(seconds: 5)),
          isBanNotice: true,
        ),
      ];
      RecentMessagesService.applyBanSweep(messages);
      expect(messages[0].deleted, isFalse);
      expect(messages[1].deleted, isTrue);
    });
  });

  group('clearMsgTargetId / applyMessageDeletions', () {
    test('extracts the deleted message id from CLEARMSG', () {
      expect(
        RecentMessagesService.clearMsgTargetId(
          '@login=ermugo1;target-msg-id=8c41deb9-5d54-47a0-ab0c-fc5b7403c905 '
          ':tmi.twitch.tv CLEARMSG #xqc :kuh',
        ),
        '8c41deb9-5d54-47a0-ab0c-fc5b7403c905',
      );
    });

    test('returns null for non-CLEARMSG lines', () {
      expect(
        RecentMessagesService.clearMsgTargetId(
          '@display-name=forsen :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :hi',
        ),
        isNull,
      );
      expect(
        RecentMessagesService.clearMsgTargetId(
          ':tmi.twitch.tv CLEARMSG #xqc :kuh',
        ),
        isNull,
        reason: 'no target-msg-id tag',
      );
    });

    test('marks matching messages deleted', () {
      final t0 = DateTime(2024, 1, 1, 12, 0, 0);
      final messages = [
        TwitchMessage(
          login: 'a',
          text: 'keep',
          messageId: 'm1',
          timestamp: t0,
          channel: 'xqc',
        ),
        TwitchMessage(
          login: 'b',
          text: 'gone',
          messageId: 'm2',
          timestamp: t0,
          channel: 'xqc',
        ),
      ];
      RecentMessagesService.applyMessageDeletions(messages, ['m2']);
      expect(messages[0].deleted, isFalse);
      expect(messages[1].deleted, isTrue);
    });
  });
}
