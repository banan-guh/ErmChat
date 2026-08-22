import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/recent_messages.dart';
import 'dart:convert';
import 'package:http/testing.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/twitch_config.dart';
import 'package:ermchat/services/twitch_eventsub.dart';
import 'package:ermchat/services/twitch_irc.dart';

import 'package:http/http.dart' as http;

Map<String, dynamic> _moderate({
  required String action,
  Map<String, dynamic>? meta,
  String moderatorName = 'moduser',
  String? moderatorUserId,
}) => <String, dynamic>{
  'metadata': <String, dynamic>{
    'message_type': 'notification',
    'subscription_type': 'channel.moderate',
  },
  'payload': <String, dynamic>{
    'subscription': <String, dynamic>{
      'condition': <String, dynamic>{'broadcaster_user_id': 'broadcaster1'},
    },
    'event': <String, dynamic>{
      'action': action,
      'moderator_user_name': moderatorName,
      'moderator_user_id': moderatorUserId,
      ...?meta,
    },
  },
};

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
          '@display-name=forsen;id=ghi-789;rm-received-ts=1700000000000;reply-parent-msg-id=parent-123;reply-parent-display-name=previousUser;reply-parent-msg-body=original\\smessage :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :@previousUser reply text';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.replyToParentId, 'parent-123');
      expect(msg.replyToUser, 'previousUser');
      expect(msg.replyToText, 'original message');
      expect(msg.text, 'reply text');
    });

    test('handles malformed escape in reply tag', () {
      const raw =
          '@display-name=forsen;id=yyy-222;rm-received-ts=1700000000000;reply-parent-msg-id=parent-456;reply-parent-display-name=User;reply-parent-msg-body=unknown\\qescape :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :@User hi';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.replyToText, r'unknown\qescape');
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
      expect(msg.text, 'ronni has subscribed for 6 months!');
      expect(msg.login, isEmpty, reason: 'non-announcement notices drop login');
      expect(
        msg.systemAccent,
        const Color(0xFF9146FF),
        reason: 'sub notices highlight like a default purple announcement',
      );
    });

    test('parses subgift USERNOTICE without user message', () {
      const raw =
          '@msg-id=subgift;system-msg=TWW2\\sgifted\\sa\\sTier\\s1\\ssub\\sto\\sMr_Woodchuck!;login=tww2;display-name=TWW2;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.isSystem, isTrue);
      expect(msg.text, 'TWW2 gifted a Tier 1 sub to Mr_Woodchuck!');
      expect(msg.systemAccent, const Color(0xFF9146FF));
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

    test('non-sub, non-announcement notices never carry an accent', () {
      const raw =
          '@msg-id=raid;system-msg=ronni\\sis\\sraiding\\sxqc!;login=ronni;display-name=ronni;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc';
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
  });

  group('parseSubChild', () {
    test('parses resub user message as a normal chat message', () {
      const raw =
          '@msg-id=resub;system-msg=ronni\\shas\\ssubscribed\\sfor\\s6\\smonths!;login=ronni;display-name=ronni;color=#0000FF;badges=subscriber/6;id=abc-123;user-id=456;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :Great stream!';
      final child = RecentMessagesService.parseSubChild(raw);
      expect(child, isNotNull);
      expect(child!.isSystem, isFalse);
      expect(child.text, 'Great stream!');
      expect(child.login, 'ronni');
      expect(child.displayName, 'ronni');
      expect(child.color, '#0000FF');
      expect(child.userId, '456');
      expect(child.messageId, 'abc-123');
      expect(child.badges, hasLength(1));
      expect(child.badges!.single.setId, 'subscriber');
      expect(child.systemAccent, const Color(0xFF9146FF));
      expect(child.isHistory, isTrue);
      expect(
        child.timestamp,
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
    });

    test('parses sub user message emotes into emote positions', () {
      const raw =
          '@msg-id=sub;system-msg=ronni\\shas\\ssubscribed!;login=ronni;display-name=ronni;emotes=emotesv2_123:0-7;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :PogChamp test';
      final child = RecentMessagesService.parseSubChild(raw);
      expect(child, isNotNull);
      expect(child!.text, 'PogChamp test');
      expect(child.emotePositions, isNotNull);
      expect(child.emotePositions!.single.emoteCode, 'PogChamp');
      expect(child.emotePositions!.single.startIndex, 0);
      expect(child.emotePositions!.single.endIndex, 8);
      expect(child.systemAccent, const Color(0xFF9146FF));
    });

    test('returns null for non-sub/resub USERNOTICE', () {
      const raw =
          '@msg-id=announcement;msg-param-color=BLUE;login=mm2pl;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :hello';
      expect(RecentMessagesService.parseSubChild(raw), isNull);
    });

    test('returns null when resub has no user message', () {
      const raw =
          '@msg-id=resub;system-msg=ronni\\shas\\ssubscribed!;login=ronni;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc';
      expect(RecentMessagesService.parseSubChild(raw), isNull);
    });

    test('returns null for non-USERNOTICE lines', () {
      const raw =
          '@display-name=forsen :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :hi';
      expect(RecentMessagesService.parseSubChild(raw), isNull);
    });

    test('robotty resub line parses both label and child', () {
      // Real robotty line shape: single-word message, no colon before text.
      const raw =
          '@color=#0000FF;id=abc;mod=0;rm-received-ts=1785668914195;'
          'historical=1;system-msg=ronni\\shas\\ssubscribed!;'
          'msg-id=resub;msg-param-cumulative-months=6;room-id=1;user-id=2;'
          'badge-info;login=ronni;tmi-sent-ts=1785668914100;flags;'
          'badges=subscriber/6;vip=0;subscriber=0;emotes;display-name=ronni '
          ':tmi.twitch.tv USERNOTICE #xqc hello';

      final label = RecentMessagesService.parseIrcLine(raw);
      expect(label, isNotNull);
      expect(label!.text, 'ronni has subscribed!');
      expect(label.systemAccent, const Color(0xFF9146FF));

      final child = RecentMessagesService.parseSubChild(raw);
      expect(child, isNotNull);
      expect(child!.text, 'hello');
      expect(child.login, 'ronni');
      expect(child.systemAccent, const Color(0xFF9146FF));
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

  late TwitchAuth auth;

  setUp(() {
    auth = TwitchAuth();
    auth.accessToken = 'test-token';
  });

  TwitchApi createApi(
    void Function(http.Request request) onRequest, {
    http.Response Function()? respond,
  }) {
    return TwitchApi(
      client: MockClient((request) async {
        onRequest(request);
        return respond?.call() ?? http.Response('', 204);
      }),
    );
  }

  void expectAuthHeaders(http.Request request) {
    expect(request.headers['Client-ID'], TwitchConfig.clientId);
    expect(request.headers['Authorization'], 'Bearer test-token');
    expect(request.headers['Content-Type'], 'application/json');
  }

  group('getUserId', () {
    test('sends GET /helix/users?login= and returns id on 200', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response(
          '{"data": [{"id": "12345", "login": "testuser"}]}',
          200,
        ),
      );

      expect(await api.getUserId(auth, 'testuser'), '12345');

      expect(captured.method, 'GET');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/users?login=testuser',
      );
      expectAuthHeaders(captured);
    });

    test('returns null on non-200', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Not Found', 404),
      );

      expect(await api.getUserId(auth, 'testuser'), isNull);
      expect(api.lastError, contains('getUserId'));
    });

    test('returns null when data list is empty', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('{"data": []}', 200),
      );

      expect(await api.getUserId(auth, 'nonexistent'), isNull);
      expect(api.lastError, contains('not found'));
    });
  });

  group('getCurrentUser', () {
    test('sends GET /helix/users and returns id and login on 200', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response(
          '{"data": [{"id": "1", "login": "currentuser"}]}',
          200,
        ),
      );

      final result = await api.getCurrentUser(auth);
      expect(result, isNotNull);
      expect(result!['id'], '1');
      expect(result['login'], 'currentuser');

      expect(captured.method, 'GET');
      expect(captured.url.toString(), 'https://api.twitch.tv/helix/users');
      expectAuthHeaders(captured);
    });

    test('returns null on non-200', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Unauthorized', 401),
      );

      expect(await api.getCurrentUser(auth), isNull);
      expect(api.lastError, contains('getCurrentUser'));
    });

    test('returns null when data list is empty', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('{"data": []}', 200),
      );

      expect(await api.getCurrentUser(auth), isNull);
      expect(api.lastError, contains('No user associated'));
    });
  });

  group('getUserLoginsByIds', () {
    test('maps ids to logins with GET /helix/users?id=', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response(
          '{"data": [{"id": "1", "login": "alpha"}, {"id": "2", "login": "beta"}]}',
          200,
        ),
      );

      final result = await api.getUserLoginsByIds(auth, ['1', '2']);

      expect(result, {'1': 'alpha', '2': 'beta'});
      expect(captured.method, 'GET');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/users?id=1&id=2',
      );
      expectAuthHeaders(captured);
    });

    test('batches into chunks of 100 and merges results', () async {
      final requests = <String>[];
      final api = TwitchApi(
        client: MockClient((request) async {
          requests.add(request.url.toString());
          final ids = request.url.queryParametersAll['id'] ?? [];
          final data = [
            for (final id in ids) {'id': id, 'login': 'user_$id'},
          ];
          return http.Response(jsonEncode({'data': data}), 200);
        }),
      );
      final ids = [for (var i = 0; i < 150; i++) '$i'];

      final result = await api.getUserLoginsByIds(auth, ids);

      expect(requests.length, 2);
      expect(requests[0], contains('id=0&id=1'));
      expect(requests[1], isNot(contains('id=0')));
      expect(result.length, 150);
      expect(result['149'], 'user_149');
      expect(result['0'], 'user_0');
    });

    test('dedups input ids before building the query', () async {
      final requests = <String>[];
      final api = TwitchApi(
        client: MockClient((request) async {
          requests.add(request.url.toString());
          return http.Response('{"data": []}', 200);
        }),
      );

      await api.getUserLoginsByIds(auth, ['1', '1', '1']);

      expect(requests.single, 'https://api.twitch.tv/helix/users?id=1');
    });

    test('skips failed chunks and returns whatever resolved', () async {
      var call = 0;
      final api = TwitchApi(
        client: MockClient((request) async {
          call++;
          if (call == 1) return http.Response('Error', 500);
          return http.Response(
            '{"data": [{"id": "target2", "login": "beta"}]}',
            200,
          );
        }),
      );
      // 101 distinct ids: the first chunk (100 ids) fails, the second carries
      // "target2".
      final ids = [for (var i = 0; i < 100; i++) 'id$i', 'target2'];

      final result = await api.getUserLoginsByIds(auth, ids);

      expect(result, {'target2': 'beta'});
      expect(api.lastError, contains('getUserLoginsByIds'));
    });
  });

  group('createEventSubSubscription', () {
    test(
      'sends POST /helix/eventsub/subscriptions with generic body',
      () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response('Accepted', 202),
        );

        expect(
          await api.createEventSubSubscription(
            auth: auth,
            sessionId: 's1',
            type: 'channel.moderate',
            version: '2',
            condition: {'broadcaster_user_id': 'b1', 'moderator_user_id': 'u1'},
          ),
          isTrue,
        );

        expect(captured.method, 'POST');
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/eventsub/subscriptions',
        );
        expectAuthHeaders(captured);
        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(body['type'], 'channel.moderate');
        expect(body['version'], '2');
        expect(body['condition'], {
          'broadcaster_user_id': 'b1',
          'moderator_user_id': 'u1',
        });
        expect(body['transport'], {'method': 'websocket', 'session_id': 's1'});
      },
    );

    test('returns true on 409 (already exists)', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Conflict', 409),
      );

      expect(
        await api.createEventSubSubscription(
          auth: auth,
          sessionId: 's1',
          type: 'channel.moderate',
          version: '2',
          condition: {'broadcaster_user_id': 'b1'},
        ),
        isTrue,
      );
    });

    test('returns false on other HTTP error', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Forbidden', 403),
      );

      expect(
        await api.createEventSubSubscription(
          auth: auth,
          sessionId: 's1',
          type: 'channel.moderate',
          version: '2',
          condition: {'broadcaster_user_id': 'b1'},
        ),
        isFalse,
      );
      expect(api.lastError, contains('createEventSubSubscription'));
    });
  });

  group('getUserProfile', () {
    test(
      'sends GET /helix/users?login= and returns profile map on 200',
      () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response(
            '{"data": [{"id": "123", "login": "testuser", "display_name": "TestUser", "created_at": "2020-01-01T00:00:00Z", "profile_image_url": "https://example.com/img.png"}]}',
            200,
          ),
        );

        final result = await api.getUserProfile(auth, 'testuser');
        expect(result, isNotNull);
        expect(result!['id'], '123');
        expect(result['display_name'], 'TestUser');
        expect(result['profile_image_url'], 'https://example.com/img.png');

        expect(captured.method, 'GET');
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/users?login=testuser',
        );
        expectAuthHeaders(captured);
      },
    );

    test('returns null when data list is empty', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('{"data": []}', 200),
      );

      expect(await api.getUserProfile(auth, 'nonexistent'), isNull);
      expect(api.lastError, contains('not found'));
    });

    test('returns null on non-200', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Not Found', 404),
      );

      expect(await api.getUserProfile(auth, 'testuser'), isNull);
      expect(api.lastError, contains('getUserProfile'));
    });
  });

  group('blockUser', () {
    test(
      'sends PUT /helix/users/blocks?target_user_id= and returns true on 204',
      () async {
        late http.Request captured;
        final api = createApi((req) => captured = req);

        expect(await api.blockUser(auth, 'target123'), isTrue);

        expect(captured.method, 'PUT');
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/users/blocks?target_user_id=target123',
        );
        expectAuthHeaders(captured);
      },
    );

    test('returns false on non-204', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Forbidden', 403),
      );

      expect(await api.blockUser(auth, 'target123'), isFalse);
      expect(api.lastError, contains('blockUser'));
    });
  });

  group('sendChatMessage', () {
    test(
      'sends POST /helix/chat/messages with message body and returns id',
      () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response(
            '{"data": [{"message_id": "abc123", "is_sent": true}]}',
            200,
          ),
        );

        final id = await api.sendChatMessage(
          auth,
          broadcasterId: 'b1',
          senderId: 's1',
          message: 'hello chat',
        );
        expect(id, 'abc123');

        expect(captured.method, 'POST');
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/chat/messages',
        );
        expectAuthHeaders(captured);
        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(body, {
          'broadcaster_id': 'b1',
          'sender_id': 's1',
          'message': 'hello chat',
        });
      },
    );

    test('includes reply_parent_message_id when replying', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response(
          '{"data": [{"message_id": "abc123", "is_sent": true}]}',
          200,
        ),
      );

      await api.sendChatMessage(
        auth,
        broadcasterId: 'b1',
        senderId: 's1',
        message: 'reply',
        replyParentMessageId: 'parent1',
      );

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['reply_parent_message_id'], 'parent1');
    });

    test('returns null when message was dropped', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response(
          '{"data": [{"message_id": "abc123", "is_sent": false, "drop_reason": {"code": "BANNED", "message": "banned"}}]}',
          200,
        ),
      );

      expect(
        await api.sendChatMessage(
          auth,
          broadcasterId: 'b1',
          senderId: 's1',
          message: 'hello',
        ),
        isNull,
      );
      expect(api.lastError, contains('dropped'));
    });
  });

  group('getBlockedUsers', () {
    test('returns null set when no cached userId', () async {
      var called = false;
      final api = TwitchApi(
        client: MockClient((request) async {
          called = true;
          return http.Response('', 500);
        }),
      );

      expect(await api.getBlockedUsers(auth), isEmpty);
      expect(called, isFalse);
    });

    test('follows pagination and lowercases logins', () async {
      final requests = <String>[];
      final api = TwitchApi(
        client: MockClient((request) async {
          requests.add(request.url.toString());
          if (!request.url.queryParameters.containsKey('after')) {
            return http.Response(
              '{"data": [{"user_login": "BADUSER", "user_id": "1"}, '
              '{"user_login": "zuck", "user_id": "2"}], '
              '"pagination": {"cursor": "next-page"}}',
              200,
            );
          }
          return http.Response(
            '{"data": [{"user_login": "another", "user_id": "3"}], '
            '"pagination": {}}',
            200,
          );
        }),
      );
      auth.userId = 'me123';

      final blocked = await api.getBlockedUsers(auth);

      expect(blocked, {'baduser', 'zuck', 'another'});
      expect(requests, hasLength(2));
      expect(requests[0], contains('broadcaster_id=me123'));
      expect(requests[0], contains('first=100'));
      expect(requests[0], isNot(contains('after=')));
      expect(requests[1], contains('after=next-page'));
    });

    test('returns empty set on error', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Unauthorized', 401),
      );
      auth.userId = 'me123';

      expect(await api.getBlockedUsers(auth), isEmpty);
      expect(api.lastError, contains('getBlockedUsers'));
    });
  });

  group('unblockUser', () {
    test('sends DELETE /helix/users/blocks and returns true on 204', () async {
      late http.Request captured;
      final api = createApi((req) => captured = req);

      expect(await api.unblockUser(auth, 'target123'), isTrue);

      expect(captured.method, 'DELETE');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/users/blocks?target_user_id=target123',
      );
      expectAuthHeaders(captured);
    });

    test('returns false on non-204', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Forbidden', 403),
      );

      expect(await api.unblockUser(auth, 'target123'), isFalse);
      expect(api.lastError, contains('unblockUser'));
    });
  });

  group('moderators', () {
    test('getModerators follows pagination and returns logins', () async {
      final requests = <String>[];
      final api = TwitchApi(
        client: MockClient((request) async {
          requests.add(request.url.toString());
          if (!request.url.queryParameters.containsKey('after')) {
            return http.Response(
              '{"data": [{"user_login": "alice"}], '
              '"pagination": {"cursor": "next"}}',
              200,
            );
          }
          return http.Response('{"data": [{"user_login": "bob"}]}', 200);
        }),
      );

      final logins = await api.getModerators(auth, 'b1');

      expect(logins, ['alice', 'bob']);
      expect(requests, hasLength(2));
      expect(requests[0], contains('broadcaster_id=b1'));
    });

    test('addModerator POSTs to /helix/moderation/moderators', () async {
      late http.Request captured;
      final api = createApi((req) => captured = req);

      expect(
        await api.addModerator(auth, broadcasterId: 'b1', userId: 'u1'),
        isTrue,
      );

      expect(captured.method, 'POST');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/moderation/moderators?broadcaster_id=b1&user_id=u1',
      );
    });

    test('removeModerator DELETEs /helix/moderation/moderators', () async {
      late http.Request captured;
      final api = createApi((req) => captured = req);

      expect(
        await api.removeModerator(auth, broadcasterId: 'b1', userId: 'u1'),
        isTrue,
      );

      expect(captured.method, 'DELETE');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/moderation/moderators?broadcaster_id=b1&user_id=u1',
      );
    });
  });

  group('vips', () {
    test('getVips returns logins', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response(
          '{"data": [{"user_login": "alice"}, {"user_login": "bob"}]}',
          200,
        ),
      );

      final logins = await api.getVips(auth, 'b1');

      expect(logins, ['alice', 'bob']);
    });

    test('addVip POSTs to /helix/channels/vips', () async {
      late http.Request captured;
      final api = createApi((req) => captured = req);

      expect(await api.addVip(auth, broadcasterId: 'b1', userId: 'u1'), isTrue);

      expect(captured.method, 'POST');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/channels/vips?broadcaster_id=b1&user_id=u1',
      );
    });

    test('removeVip DELETEs /helix/channels/vips', () async {
      late http.Request captured;
      final api = createApi((req) => captured = req);

      expect(
        await api.removeVip(auth, broadcasterId: 'b1', userId: 'u1'),
        isTrue,
      );

      expect(captured.method, 'DELETE');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/channels/vips?broadcaster_id=b1&user_id=u1',
      );
    });
  });

  group('updateChatSettings', () {
    test('PATCHes /helix/chat/settings with the given body', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response('{"data": []}', 200),
      );

      final ok = await api.updateChatSettings(
        auth,
        broadcasterId: 'b1',
        moderatorId: 'm1',
        body: {'slow_mode': true, 'slow_mode_wait_time': 30},
      );

      expect(ok, isTrue);
      expect(captured.method, 'PATCH');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/chat/settings?broadcaster_id=b1&moderator_id=m1',
      );
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['slow_mode'], isTrue);
      expect(body['slow_mode_wait_time'], 30);
    });

    test('returns false on non-200', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response('Forbidden', 403),
      );

      final ok = await api.updateChatSettings(
        auth,
        broadcasterId: 'b1',
        moderatorId: 'm1',
        body: {'slow_mode': true},
      );

      expect(ok, isFalse);
      expect(api.lastError, contains('updateChatSettings'));
    });
  });

  group('commercial / raid / shield / marker / whisper', () {
    test(
      'startCommercial POSTs length to /helix/channels/commercial',
      () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response('{"data": []}', 200),
        );

        expect(
          await api.startCommercial(auth, broadcasterId: 'b1', length: 90),
          isTrue,
        );

        expect(captured.method, 'POST');
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/channels/commercial',
        );
        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(body, {'broadcaster_id': 'b1', 'length': 90});
      },
    );

    test('startRaid POSTs to /helix/raids with both broadcaster ids', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response('{"data": []}', 200),
      );

      expect(
        await api.startRaid(
          auth,
          fromBroadcasterId: 'b1',
          toBroadcasterId: 'b2',
        ),
        isTrue,
      );

      expect(captured.method, 'POST');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/raids?from_broadcaster_id=b1&to_broadcaster_id=b2',
      );
    });

    test('cancelRaid DELETEs /helix/raids', () async {
      late http.Request captured;
      final api = createApi((req) => captured = req);

      expect(await api.cancelRaid(auth, broadcasterId: 'b1'), isTrue);

      expect(captured.method, 'DELETE');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/raids?broadcaster_id=b1',
      );
    });

    test(
      'updateShieldMode PUTs is_active to /helix/moderation/shield_mode',
      () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response('{"data": []}', 200),
        );

        expect(
          await api.updateShieldMode(
            auth,
            broadcasterId: 'b1',
            moderatorId: 'm1',
            active: true,
          ),
          isTrue,
        );

        expect(captured.method, 'PUT');
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/moderation/shield_mode?broadcaster_id=b1&moderator_id=m1',
        );
        expect(jsonDecode(captured.body), {'is_active': true});
      },
    );

    test('createMarker POSTs description to /helix/streams/markers', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response('{"data": []}', 200),
      );

      expect(
        await api.createMarker(auth, broadcasterId: 'b1', description: 'clip'),
        isTrue,
      );

      expect(captured.method, 'POST');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/streams/markers',
      );
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body, {'user_id': 'b1', 'description': 'clip'});
    });

    test(
      'sendWhisper POSTs to /helix/whispers with the message body',
      () async {
        late http.Request captured;
        final api = createApi((req) => captured = req);

        expect(
          await api.sendWhisper(
            auth,
            fromUserId: 'f1',
            toUserId: 't1',
            message: 'hello',
          ),
          isTrue,
        );

        expect(captured.method, 'POST');
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/whispers?from_user_id=f1&to_user_id=t1',
        );
        expect(jsonDecode(captured.body), {'message': 'hello'});
      },
    );
  });

  group('error capture', () {
    test('records status and Helix message for failed calls', () async {
      final api = createApi(
        (_) {},
        respond: () => http.Response(
          '{"error":"Bad Request","status":400,"message":"The user is not banned in this channel."}',
          400,
        ),
      );

      await api.unbanUser(
        auth,
        broadcasterId: 'b1',
        moderatorId: 'm1',
        userId: 'u1',
      );

      expect(api.lastErrorStatus, 400);
      expect(api.lastHelixMessage, 'The user is not banned in this channel.');
    });
  });

  late EventSubService service;

  setUp(() {
    service = EventSubService();
    service.setChannelMapping('broadcaster1', 'testchannel');
  });

  tearDown(() {
    service.dispose();
  });

  group('session_welcome', () {
    test('session_welcome with null timeout defaults to 10', () {
      service.handleRawMessage(<String, dynamic>{
        'metadata': <String, dynamic>{'message_type': 'session_welcome'},
        'payload': <String, dynamic>{
          'session': <String, dynamic>{'id': 'sess-2'},
        },
      });

      expect(service.sessionId, 'sess-2');
    });
  });

  group('notification (channel.moderate)', () {
    test('ban emits ModerationEvent with target and reason', () async {
      final events = <ModerationEvent>[];
      service.onModeration.listen(events.add);

      service.handleRawMessage(
        _moderate(
          action: 'ban',
          meta: {
            'ban': {
              'user_id': 'target1',
              'user_name': 'targetuser',
              'reason': 'spam',
            },
          },
        ),
      );

      expect(events, hasLength(1));
      expect(events[0].channel, 'testchannel');
      expect(events[0].action, 'ban');
      expect(events[0].moderatorName, 'moduser');
      expect(events[0].targetName, 'targetuser');
      expect(events[0].reason, 'spam');
    });

    test('timeout carries duration from expires_at', () async {
      final events = <ModerationEvent>[];
      service.onModeration.listen(events.add);

      final expiresAt = DateTime.now()
          .toUtc()
          .add(const Duration(seconds: 300))
          .toIso8601String();
      service.handleRawMessage(
        _moderate(
          action: 'timeout',
          meta: {
            'timeout': {'user_name': 'targetuser', 'expires_at': expiresAt},
          },
        ),
      );

      expect(events, hasLength(1));
      expect(events[0].action, 'timeout');
      expect(events[0].durationSeconds, closeTo(300, 10));
    });

    test('delete carries message id and body', () async {
      final events = <ModerationEvent>[];
      service.onModeration.listen(events.add);

      service.handleRawMessage(
        _moderate(
          action: 'delete',
          meta: {
            'delete': {
              'user_name': 'targetuser',
              'message_id': 'msg-1',
              'message_body': 'hello',
            },
          },
        ),
      );

      expect(events, hasLength(1));
      expect(events[0].action, 'delete');
      expect(events[0].targetName, 'targetuser');
      expect(events[0].messageId, 'msg-1');
      expect(events[0].messageBody, 'hello');
    });

    test('shared_chat actions map to their base action', () async {
      final events = <ModerationEvent>[];
      service.onModeration.listen(events.add);

      service.handleRawMessage(
        _moderate(
          action: 'shared_chat_ban',
          meta: {
            'shared_chat_ban': {'user_name': 'targetuser'},
          },
        ),
      );

      expect(events, hasLength(1));
      expect(events[0].action, 'ban');
    });

    test('ignores notifications for unknown subscription types', () async {
      final events = <ModerationEvent>[];
      service.onModeration.listen(events.add);

      service.handleRawMessage(<String, dynamic>{
        'metadata': <String, dynamic>{
          'message_type': 'notification',
          'subscription_type': 'channel.chat.message',
        },
        'payload': <String, dynamic>{
          'subscription': <String, dynamic>{
            'condition': <String, dynamic>{
              'broadcaster_user_id': 'broadcaster1',
            },
          },
          'event': <String, dynamic>{'chatter_user_name': 'someone'},
        },
      });

      expect(events, isEmpty);
    });

    test('drops events without a channel mapping', () async {
      final events = <ModerationEvent>[];
      service.onModeration.listen(events.add);

      service.handleRawMessage(<String, dynamic>{
        'metadata': <String, dynamic>{
          'message_type': 'notification',
          'subscription_type': 'channel.moderate',
        },
        'payload': <String, dynamic>{
          'subscription': <String, dynamic>{
            'condition': <String, dynamic>{
              'broadcaster_user_id': 'unknown_broadcaster',
            },
          },
          'event': <String, dynamic>{'action': 'clear'},
        },
      });

      expect(events, isEmpty);
    });

    test('clear emits event without target', () async {
      final events = <ModerationEvent>[];
      service.onModeration.listen(events.add);

      service.handleRawMessage(
        _moderate(action: 'clear', meta: <String, dynamic>{}),
      );

      expect(events, hasLength(1));
      expect(events[0].action, 'clear');
      expect(events[0].targetName, isNull);
    });
  });

  group('session_reconnect and revocation', () {
    test('malformed frames do not crash', () {
      expect(
        () => service.handleRawMessage(<String, dynamic>{}),
        returnsNormally,
      );
      expect(
        () => service.handleRawMessage(<String, dynamic>{
          'metadata': <String, dynamic>{'message_type': 123},
        }),
        returnsNormally,
      );
    });
  });

  Map<String, dynamic> widget(
    String type,
    Map<String, dynamic> event,
  ) => <String, dynamic>{
    'metadata': <String, dynamic>{
      'message_type': 'notification',
      'subscription_type': type,
    },
    'payload': <String, dynamic>{
      'subscription': <String, dynamic>{
        'condition': <String, dynamic>{'broadcaster_user_id': 'broadcaster1'},
      },
      'event': event,
    },
  };

  group('notification (channel.hype_train)', () {
    test(
      'begin emits HypeTrainEvent with level, goal and contributors',
      () async {
        final events = <HypeTrainEvent>[];
        service.onHypeTrain.listen(events.add);

        service.handleRawMessage(
          widget('channel.hype_train.begin', <String, dynamic>{
            'level': 2,
            'progress': 30,
            'total': 100,
            'expires_at': '2030-01-01T00:00:00Z',
            'top_contributions': <Map<String, dynamic>>[
              {'user_name': 'bitsuser', 'type': 'BITS', 'total': 2000},
              {'user_name': 'subuser', 'type': 'SUBS', 'total': 5},
            ],
          }),
        );

        expect(events, hasLength(1));
        final e = events[0];
        expect(e.channel, 'testchannel');
        expect(e.kind, 'begin');
        expect(e.level, 2);
        expect(e.progress, 30);
        expect(e.total, 100);
        expect(e.expiresAt, isNotNull);
        expect(e.topContributions, hasLength(2));
        expect(e.topContributions[0].userName, 'bitsuser');
        expect(e.topContributions[0].type, 'BITS');
      },
    );
  });

  group('notification (channel.poll)', () {
    test('progress emits PollEvent with choices and votes', () async {
      final events = <PollEvent>[];
      service.onPoll.listen(events.add);

      service.handleRawMessage(
        widget('channel.poll.progress', <String, dynamic>{
          'title': 'Best game?',
          'status': 'ACTIVE',
          'choices': <Map<String, dynamic>>[
            {'id': '1', 'title': 'Minecraft', 'votes': 10},
            {'id': '2', 'title': 'Terraria', 'votes': 20},
          ],
        }),
      );

      expect(events, hasLength(1));
      final e = events[0];
      expect(e.channel, 'testchannel');
      expect(e.kind, 'progress');
      expect(e.title, 'Best game?');
      expect(e.choices, hasLength(2));
      expect(e.choices[0].title, 'Minecraft');
      expect(e.choices[0].votes, 10);
      expect(e.choices[1].votes, 20);
    });
  });

  group('notification (channel.prediction)', () {
    test('lock emits PredictionEvent with outcomes', () async {
      final events = <PredictionEvent>[];
      service.onPrediction.listen(events.add);

      service.handleRawMessage(
        widget('channel.prediction.lock', <String, dynamic>{
          'title': 'Will we win?',
          'status': 'LOCKED',
          'outcomes': <Map<String, dynamic>>[
            {
              'id': '1',
              'title': 'Yes',
              'users': 15,
              'channel_points': 300,
              'color': 'BLUE',
            },
            {
              'id': '2',
              'title': 'No',
              'users': 5,
              'channel_points': 100,
              'color': 'PINK',
            },
          ],
        }),
      );

      expect(events, hasLength(1));
      final e = events[0];
      expect(e.channel, 'testchannel');
      expect(e.kind, 'lock');
      expect(e.title, 'Will we win?');
      expect(e.outcomes, hasLength(2));
      expect(e.outcomes[0].title, 'Yes');
      expect(e.outcomes[0].users, 15);
      expect(e.outcomes[0].channelPoints, 300);
    });
  });

  group('parseIrcMessage', () {
    test('parses basic IRC message', () {
      final msg = parseIrcMessage(':tmi.twitch.tv CLEARCHAT #xqc :forsen');
      expect(msg, isNotNull);
      expect(msg!.command, 'CLEARCHAT');
      expect(msg.params, ['#xqc']);
      expect(msg.trailing, 'forsen');
      expect(msg.prefix, 'tmi.twitch.tv');
      expect(msg.tags, isEmpty);
    });

    test('parses CLEARCHAT with tags (timeout)', () {
      const line =
          '@ban-duration=300;target-user-id=12345 :tmi.twitch.tv CLEARCHAT #xqc :forsen';
      final msg = parseIrcMessage(line);
      expect(msg, isNotNull);
      expect(msg!.command, 'CLEARCHAT');
      expect(msg.params, ['#xqc']);
      expect(msg.trailing, 'forsen');
      expect(msg.tags['ban-duration'], '300');
      expect(msg.tags['target-user-id'], '12345');
    });

    test('parses CLEARMSG with target-msg-id and login tags', () {
      const line =
          '@login=forsen;target-msg-id=abc-123;room-id=12345 :tmi.twitch.tv CLEARMSG #xqc :bad message';
      final msg = parseIrcMessage(line);
      expect(msg, isNotNull);
      expect(msg!.command, 'CLEARMSG');
      expect(msg.params, ['#xqc']);
      expect(msg.tags['login'], 'forsen');
      expect(msg.tags['target-msg-id'], 'abc-123');
      expect(msg.trailing, 'bad message');
    });

    test('parses PING message', () {
      final msg = parseIrcMessage('PING :tmi.twitch.tv');
      expect(msg, isNotNull);
      expect(msg!.command, 'PING');
    });

    test('parses message with prefix only', () {
      final msg = parseIrcMessage(
        ':testuser!testuser@testuser.tmi.twitch.tv PRIVMSG #xqc :hello',
      );
      expect(msg, isNotNull);
      expect(msg!.command, 'PRIVMSG');
      expect(msg.prefix, 'testuser!testuser@testuser.tmi.twitch.tv');
      expect(msg.params, ['#xqc']);
      expect(msg.trailing, 'hello');
    });

    test('handles malformed message', () {
      final msg = parseIrcMessage(':');
      expect(msg, isNull);
    });

    test('handles message with spaces in trailing', () {
      final msg = parseIrcMessage(
        ':user!user@user.tmi.twitch.tv PRIVMSG #channel :hello world this is a test',
      );
      expect(msg, isNotNull);
      expect(msg!.trailing, 'hello world this is a test');
    });

    test('parses NOTICE message', () {
      final msg = parseIrcMessage(
        ':tmi.twitch.tv NOTICE #xqc :This room requires a verified email account to chat.',
      );
      expect(msg, isNotNull);
      expect(msg!.command, 'NOTICE');
      expect(msg.params, ['#xqc']);
      expect(
        msg.trailing,
        'This room requires a verified email account to chat.',
      );
    });

    test('parses NOTICE with tags', () {
      const line =
          '@msg-id=slow_mode :tmi.twitch.tv NOTICE #xqc :You are sending messages too fast.';
      final msg = parseIrcMessage(line);
      expect(msg, isNotNull);
      expect(msg!.command, 'NOTICE');
      expect(msg.tags['msg-id'], 'slow_mode');
      expect(msg.trailing, 'You are sending messages too fast.');
    });

    test('parses WHISPER message', () {
      const line =
          '@badges=;color=#FF0000;display-name=SomeUser;emotes=;message-id=whisper-1;thread-id=abc;turbo=0;user-id=999;user-type= :someuser!someuser@someuser.tmi.twitch.tv WHISPER recipient :hey there';
      final msg = parseIrcMessage(line);
      expect(msg, isNotNull);
      expect(msg!.command, 'WHISPER');
      expect(msg.prefix, 'someuser!someuser@someuser.tmi.twitch.tv');
      expect(msg.params, ['recipient']);
      expect(msg.trailing, 'hey there');
      expect(msg.tags['message-id'], 'whisper-1');
      expect(msg.tags['display-name'], 'SomeUser');
      expect(msg.tags['color'], '#FF0000');
      expect(msg.tags['user-id'], '999');
    });
  });

  group('parseIrcEmotePositions', () {
    test('maps tag offset to emote code with no supplementary chars', () {
      const text = 'hey app LUL';
      final positions = parseIrcEmotePositions(
        'emotesv2_1:8-10',
        originalText: text,
        strippedText: text,
      );
      expect(positions, hasLength(1));
      expect(positions!.first.emoteId, 'emotesv2_1');
      expect(positions.first.emoteCode, 'LUL');
      expect(positions.first.startIndex, 8);
      expect(positions.first.endIndex, 11);
    });

    test('adjusts for supplementary characters before the emote', () {
      // '🙂' is a single codepoint occupying 2 UTF-16 units; the tag offset
      // counts it as 1, so the emote (at UTF-16 index 7..10) reads as 6..8
      // in tag space and must be shifted forward by 1 in Dart indexing.
      const text = '🙂 hey LUL';
      final positions = parseIrcEmotePositions(
        'emotesv2_2:6-8',
        originalText: text,
        strippedText: text,
      );
      expect(positions, hasLength(1));
      expect(positions!.first.emoteCode, 'LUL');
      expect(positions.first.startIndex, 7);
      expect(positions.first.endIndex, 10);
    });

    test('returns null for empty or null tag', () {
      expect(
        parseIrcEmotePositions('', originalText: 'x', strippedText: 'x'),
        isNull,
      );
      expect(
        parseIrcEmotePositions(null, originalText: 'x', strippedText: 'x'),
        isNull,
      );
    });

    test('ACTION messages use body-relative positions', () {
      // Twitch reports /me emote positions relative to the message body
      // (after "\x01ACTION "), e.g. emotes=25:0-4 for "\x01ACTION Kappa\x01".
      final positions = parseIrcEmotePositions(
        '25:0-4',
        originalText: '\x01ACTION Kappa\x01',
        strippedText: 'Kappa',
      );
      expect(positions, hasLength(1));
      expect(positions!.first.emoteId, '25');
      expect(positions.first.emoteCode, 'Kappa');
      expect(positions.first.startIndex, 0);
      expect(positions.first.endIndex, 5);
    });

    test('ACTION messages with reply prefix adjust by reply length only', () {
      // Positions stay body-relative (after the wrapper); the reply prefix
      // "@User " is stripped and its length is subtracted separately.
      final positions = parseIrcEmotePositions(
        '25:9-13',
        originalText: '\x01ACTION @User hi Kappa\x01',
        strippedText: 'hi Kappa',
        prefixLen: 6,
      );
      expect(positions, hasLength(1));
      expect(positions!.first.emoteCode, 'Kappa');
      expect(positions.first.startIndex, 3);
      expect(positions.first.endIndex, 8);
    });
  });

  group('subNoticeMsgIds', () {
    test('excludes non-sub notices like announcements and raids', () {
      expect(subNoticeMsgIds, isNot(contains('announcement')));
      expect(subNoticeMsgIds, isNot(contains('raid')));
    });

    test('includes watch streak milestones', () {
      expect(subNoticeMsgIds, contains('viewermilestone'));
    });
  });
}
