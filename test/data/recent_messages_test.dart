import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

    test('parses announcement USERNOTICE with login', () {
      const raw =
          '@msg-id=announcement;msg-param-color=BLUE;login=mm2pl;display-name=Mm2PL;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :my primary color';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.isSystem, isTrue);
      expect(msg.text, 'Mm2PL announced: my primary color');
      expect(msg.login, 'mm2pl');
      expect(msg.systemAccent, const Color(0xFF1F69FF));
    });

    test('announcement without color gets no accent', () {
      const raw =
          '@msg-id=announcement;login=mm2pl;display-name=Mm2PL;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :hello';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.text, 'Mm2PL announced: hello');
      expect(msg.systemAccent, isNull);
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
  });
}
