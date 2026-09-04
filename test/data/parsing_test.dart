import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/recent_messages.dart';
import 'dart:convert';
import 'package:http/testing.dart';
import 'package:ermchat/services/mod_actions.dart';
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
    for (final (name, raw, expectedColor) in [
      (
        'parses basic PRIVMSG',
        '@display-name=forsen;color=#FF0000;id=abc-123;rm-received-ts=1700000000000 :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :Hello chat',
        '#FF0000',
      ),
      (
        'parses message without color tag',
        '@display-name=forsen;id=def-456;rm-received-ts=1700000000000 :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :no color',
        null,
      ),
    ]) {
      test(name, () {
        final msg = RecentMessagesService.parseIrcLine(raw);
        expect(msg, isNotNull, reason: name);
        expect(msg!.login, 'forsen', reason: name);
        if (expectedColor != null) {
          expect(msg.color, expectedColor, reason: name);
          expect(msg.messageId, 'abc-123', reason: name);
          expect(msg.isHistory, isTrue, reason: name);
          expect(msg.channel, isNull, reason: name);
        } else {
          expect(msg.color, isNotNull, reason: name);
          expect(msg.color!.startsWith('#'), isTrue, reason: name);
        }
      });
    }

    for (final (name, raw, bits, accent) in [
      (
        'parses cheer PRIVMSG with purple accent',
        '@badges=bits/1000;bits=100;display-name=ronni;id=cheer-1;rm-received-ts=1700000000000 :ronni!ronni@ronni.tmi.twitch.tv PRIVMSG #xqc :Cheer100 take my bits',
        100,
        const Color(0xFF7C47D1),
      ),
      (
        'non-cheer PRIVMSG has no bits amount or accent',
        '@display-name=forsen;id=abc-123;rm-received-ts=1700000000000 :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :Hello chat',
        null,
        null,
      ),
    ]) {
      test(name, () {
        final msg = RecentMessagesService.parseIrcLine(raw);
        expect(msg, isNotNull, reason: name);
        expect(msg!.bitsAmount, bits, reason: name);
        expect(msg.systemAccent, accent, reason: name);
      });
    }

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

    for (final (name, raw, msgId) in [
      (
        'parses highlight-related tags',
        '@msg-id=highlighted-message;custom-reward-id=reward-9;pinned-chat-paid-amount=100;display-name=forsen;id=elev-1 :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :yo',
        'highlighted-message',
      ),
      (
        'plain PRIVMSG has no highlight tags',
        '@display-name=forsen;id=abc-123 :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :Hello chat',
        null,
      ),
    ]) {
      test(name, () {
        final msg = RecentMessagesService.parseIrcLine(raw);
        expect(msg, isNotNull, reason: name);
        expect(msg!.msgId, msgId, reason: name);
        if (msgId != null) {
          expect(msg.customRewardId, 'reward-9', reason: name);
          expect(msg.pinnedPaidAmount, '100', reason: name);
        } else {
          expect(msg.customRewardId, isNull, reason: name);
          expect(msg.pinnedPaidAmount, isNull, reason: name);
        }
      });
    }

    test('handles malformed escape in reply tag', () {
      const raw =
          '@display-name=forsen;id=yyy-222;rm-received-ts=1700000000000;reply-parent-msg-id=parent-456;reply-parent-display-name=User;reply-parent-msg-body=unknown\\qescape :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :@User hi';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.replyToText, r'unknown\qescape');
    });

    for (final (name, raw) in [
      (
        'returns null for JOIN',
        '@display-name=forsen :tmi.twitch.tv JOIN #xqc',
      ),
      (
        'returns null for empty display-name and text',
        '@display-name=;id=zzz-333 :user!user@user.tmi.twitch.tv PRIVMSG #xqc :',
      ),
    ]) {
      test(name, () {
        expect(RecentMessagesService.parseIrcLine(raw), isNull, reason: name);
      });
    }

    for (final (name, raw, text) in [
      (
        'parses timeout CLEARCHAT',
        '@ban-duration=300;target-user-id=974273622;rm-received-ts=1700000000000;historical=1 :tmi.twitch.tv CLEARCHAT #ermugo2 :ermugo1',
        'ermugo1 was timed out for 5m.',
      ),
      (
        'parses ban CLEARCHAT without ban-duration',
        '@target-user-id=974273622;rm-received-ts=1700000000000 :tmi.twitch.tv CLEARCHAT #ermugo2 :ermugo1',
        'ermugo1 was banned.',
      ),
    ]) {
      test(name, () {
        final msg = RecentMessagesService.parseIrcLine(raw);
        expect(msg, isNotNull, reason: name);
        expect(msg!.isSystem, isTrue, reason: name);
        expect(msg.text, text, reason: name);
        expect(msg.isHistory, isTrue, reason: name);
      });
    }

    test('parses robotty CLEARCHAT without trailing colon', () {
      const raw =
          '@ban-duration=300;target-user-id=974273622;rm-received-ts=1700000000000;historical=1 :tmi.twitch.tv CLEARCHAT #ermugo2 ermugo1';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.text, 'ermugo1 was timed out for 5m.');
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

    test(
      'parses non-reply emotes unchanged alongside the reply RangeError regression',
      () {
        const raw =
            '@display-name=testuser;id=em-noreply-1;rm-received-ts=1700000000000;emotes=123456:6-12 :testuser!testuser@testuser.tmi.twitch.tv PRIVMSG #xqc :hello forsenE';
        final msg = RecentMessagesService.parseIrcLine(raw);
        expect(msg, isNotNull);
        expect(msg!.text, 'hello forsenE');
        expect(msg.emotePositions, hasLength(1));
        expect(msg.emotePositions!.first.emoteCode, 'forsenE');
        expect(msg.emotePositions!.first.startIndex, 6);
        expect(msg.emotePositions!.first.endIndex, 13);
      },
    );

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
          '@msg-id=resub;system-msg=ronni\\shas\\ssubscribed\\sfor\\s6\\smonths!;login=ronni;display-name=ronni;id=notice-1;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :Great stream!';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.isSystem, isTrue);
      expect(msg.text, 'ronni has subscribed for 6 months!');
      expect(msg.login, isEmpty, reason: 'non-announcement notices drop login');
      expect(
        msg.systemAccent,
        const Color(0xFF7C47D1),
        reason: 'sub notices highlight like a default purple announcement',
      );
      expect(
        msg.messageId,
        'notice-1:label',
        reason: 'labels carry a namespaced id so live/history dedup works',
      );
    });

    test('USERNOTICE label without an id keeps no messageId', () {
      const raw =
          '@msg-id=resub;system-msg=ronni\\shas\\ssubscribed!;login=ronni;display-name=ronni;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.messageId, isNull);
    });

    for (final (name, raw, text) in [
      (
        'parses subgift USERNOTICE without user message',
        '@msg-id=subgift;system-msg=TWW2\\sgifted\\sa\\sTier\\s1\\ssub\\sto\\sMr_Woodchuck!;login=tww2;display-name=TWW2;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc',
        'TWW2 gifted a Tier 1 sub to Mr_Woodchuck!',
      ),
    ]) {
      test(name, () {
        final msg = RecentMessagesService.parseIrcLine(raw);
        expect(msg, isNotNull, reason: name);
        expect(msg!.isSystem, isTrue, reason: name);
        expect(msg.text, text, reason: name);
        expect(msg.systemAccent, const Color(0xFF7C47D1), reason: name);
      });
    }

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
      expect(msg.systemAccent, const Color(0xFF7C47D1));
    });

    test('empty announcement still renders the label', () {
      const raw =
          '@msg-id=announcement;msg-param-color=ORANGE;login=mm2pl;display-name=Mm2PL;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.text, 'Announcement');
      expect(msg.systemAccent, const Color(0xFFFF6F00));
    });

    for (final (name, raw) in [
      (
        'non-announcement notices highlight with the purple accent',
        '@msg-id=raid;system-msg=ronni\\sis\\sraiding\\sxqc!;login=ronni;display-name=ronni;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc',
      ),
      (
        'payforward notices highlight with the purple accent',
        '@msg-id=standardpayforward;system-msg=ronni\\spaid\\sforward\\sa\\ssub!;login=ronni;display-name=ronni;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc',
      ),
    ]) {
      test(name, () {
        final msg = RecentMessagesService.parseIrcLine(raw);
        expect(msg, isNotNull, reason: name);
        expect(msg!.isSystem, isTrue, reason: name);
        expect(msg.systemAccent, const Color(0xFF7C47D1), reason: name);
      });
    }

    test('returns null for USERNOTICE without msg-id', () {
      const raw =
          '@login=ronni;display-name=ronni;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :hello';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNull);
    });

    for (final (name, raw, text) in [
      (
        'parses NOTICE into a system message',
        '@msg-id=slow_on;rm-received-ts=1700000000000 :tmi.twitch.tv NOTICE #xqc :This room is now in slow mode.',
        'This room is now in slow mode.',
      ),
      (
        'returns null for NOTICE without text',
        ':tmi.twitch.tv NOTICE #xqc',
        null,
      ),
    ]) {
      test(name, () {
        final msg = RecentMessagesService.parseIrcLine(raw);
        if (text == null) {
          expect(msg, isNull, reason: name);
        } else {
          expect(msg, isNotNull, reason: name);
          expect(msg!.isSystem, isTrue, reason: name);
          expect(msg.text, text, reason: name);
          expect(msg.isHistory, isTrue, reason: name);
        }
      });
    }
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

    for (final (name, raw) in [
      (
        'returns null for non-announcement USERNOTICE',
        '@msg-id=resub;system-msg=ronni\\shas\\ssubscribed!;login=ronni;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :Great stream!',
      ),
      (
        'returns null when announcement has no text',
        '@msg-id=announcement;msg-param-color=ORANGE;login=mm2pl;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc',
      ),
      (
        'returns null for non-USERNOTICE lines',
        '@display-name=forsen :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :hi',
      ),
    ]) {
      test(name, () {
        expect(
          RecentMessagesService.parseAnnouncementChild(raw),
          isNull,
          reason: name,
        );
      });
    }

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
      expect(label.systemAccent, const Color(0xFF7C47D1));

      final child = RecentMessagesService.parseAnnouncementChild(raw);
      expect(child, isNotNull);
      expect(child!.text, 'uuh');
      expect(child.login, 'ermugo2');
      expect(child.messageId, '1151c190-4c78-4f31-b436-d75b3003e68c');
      expect(child.systemAccent, const Color(0xFF7C47D1));
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
      expect(child.systemAccent, const Color(0xFF7C47D1));
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
      expect(child.systemAccent, const Color(0xFF7C47D1));
    });

    for (final (name, raw) in [
      (
        'returns null for non-sub/resub USERNOTICE',
        '@msg-id=announcement;msg-param-color=BLUE;login=mm2pl;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc :hello',
      ),
      (
        'returns null when resub has no user message',
        '@msg-id=resub;system-msg=ronni\\shas\\ssubscribed!;login=ronni;rm-received-ts=1700000000000 :tmi.twitch.tv USERNOTICE #xqc',
      ),
      (
        'returns null for non-USERNOTICE lines',
        '@display-name=forsen :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :hi',
      ),
    ]) {
      test(name, () {
        expect(RecentMessagesService.parseSubChild(raw), isNull, reason: name);
      });
    }

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
      expect(label.systemAccent, const Color(0xFF7C47D1));

      final child = RecentMessagesService.parseSubChild(raw);
      expect(child, isNotNull);
      expect(child!.text, 'hello');
      expect(child.login, 'ronni');
      expect(child.systemAccent, const Color(0xFF7C47D1));
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

    for (final (name, raw) in [
      (
        'returns null for non-CLEARMSG lines',
        '@display-name=forsen :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :hi',
      ),
      (
        'returns null for CLEARMSG without target-msg-id tag',
        ':tmi.twitch.tv CLEARMSG #xqc :kuh',
      ),
    ]) {
      test(name, () {
        expect(
          RecentMessagesService.clearMsgTargetId(raw),
          isNull,
          reason: name,
        );
      });
    }

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

  ModActions modActions(
    TwitchApi api, {
    Map<String, String> channels = const {'testchannel': 'broadcaster1'},
    String? moderatorId = 'mod1',
  }) => ModActions(
    twitchApi: api,
    getChannelUserIds: () => channels,
    getCurrentUserId: () => moderatorId,
  );

  TwitchApi stubApi(
    List<http.BaseRequest> seen, {
    Map<String, http.Response> routes = const {},
    String loginId = 'target1',
  }) => TwitchApi(
    client: MockClient((request) async {
      seen.add(request);
      if (request.url.path == '/helix/users') {
        return http.Response(
          '{"data": [{"id": "$loginId", "login": "target"}]}',
          200,
        );
      }
      final key = '${request.method} ${request.url.path}';
      return routes[key] ?? http.Response('', 200);
    }),
  );

  group('getUserId', () {
    for (final (name, status, body, expected) in [
      (
        'sends GET /helix/users?login= and returns id on 200',
        200,
        '{"data": [{"id": "12345", "login": "testuser"}]}',
        '12345',
      ),
      ('returns null on non-200', 404, 'Not Found', null),
      ('returns null when data list is empty', 200, '{"data": []}', null),
    ]) {
      test(name, () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response(body, status),
        );
        expect(await api.getUserId(auth, 'testuser'), expected, reason: name);
        if (expected != null) {
          expect(captured.method, 'GET');
          expect(
            captured.url.toString(),
            'https://api.twitch.tv/helix/users?login=testuser',
          );
          expectAuthHeaders(captured);
        } else {
          expect(api.lastError, isNotNull, reason: name);
        }
      });
    }
  });

  group('getCurrentUser', () {
    for (final (name, status, body, expectUser) in [
      (
        'sends GET /helix/users and returns id and login on 200',
        200,
        '{"data": [{"id": "1", "login": "currentuser"}]}',
        true,
      ),
      ('returns null on non-200', 401, 'Unauthorized', false),
      ('returns null when data list is empty', 200, '{"data": []}', false),
    ]) {
      test(name, () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response(body, status),
        );
        final result = await api.getCurrentUser(auth);
        if (expectUser) {
          expect(result, isNotNull, reason: name);
          expect(result!['id'], '1', reason: name);
          expect(result['login'], 'currentuser', reason: name);
          expect(captured.method, 'GET');
          expect(captured.url.toString(), 'https://api.twitch.tv/helix/users');
          expectAuthHeaders(captured);
        } else {
          expect(result, isNull, reason: name);
          expect(api.lastError, isNotNull, reason: name);
        }
      });
    }
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

    for (final (name, input, expectedUrl) in [
      (
        'dedups input ids before building the query',
        ['1', '1', '1'],
        'https://api.twitch.tv/helix/users?id=1',
      ),
    ]) {
      test(name, () async {
        final requests = <String>[];
        final api = TwitchApi(
          client: MockClient((request) async {
            requests.add(request.url.toString());
            return http.Response('{"data": []}', 200);
          }),
        );
        await api.getUserLoginsByIds(auth, input);
        expect(requests.single, expectedUrl, reason: name);
      });
    }

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

    for (final (name, status, expected) in [
      ('returns true on 409 (already exists)', 409, true),
      ('returns false on other HTTP error', 403, false),
    ]) {
      test(name, () async {
        final api = createApi(
          (_) {},
          respond: () => http.Response('err', status),
        );
        expect(
          await api.createEventSubSubscription(
            auth: auth,
            sessionId: 's1',
            type: 'channel.moderate',
            version: '2',
            condition: {'broadcaster_user_id': 'b1'},
          ),
          expected,
          reason: name,
        );
      });
    }
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

    for (final (name, status, body) in [
      ('returns null when data list is empty', 200, '{"data": []}'),
      ('returns null on non-200', 404, 'Not Found'),
    ]) {
      test(name, () async {
        final api = createApi(
          (_) {},
          respond: () => http.Response(body, status),
        );
        expect(
          await api.getUserProfile(auth, 'testuser'),
          isNull,
          reason: name,
        );
        expect(api.lastError, isNotNull, reason: name);
      });
    }
  });

  group('blockUser', () {
    for (final (name, status, expected) in [
      (
        'sends PUT /helix/users/blocks?target_user_id= and returns true on 204',
        204,
        true,
      ),
      ('returns false on non-204', 403, false),
    ]) {
      test(name, () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response('x', status),
        );
        expect(await api.blockUser(auth, 'target123'), expected, reason: name);
        if (expected) {
          expect(captured.method, 'PUT');
          expect(
            captured.url.toString(),
            'https://api.twitch.tv/helix/users/blocks?target_user_id=target123',
          );
          expectAuthHeaders(captured);
        }
      });
    }
  });

  group('sendChatMessage', () {
    for (final (name, replyId) in [
      (
        'sends POST /helix/chat/messages with message body and returns id',
        null,
      ),
      ('includes reply_parent_message_id when replying', 'parent1'),
    ]) {
      test(name, () async {
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
          replyParentMessageId: replyId,
        );
        expect(id, 'abc123', reason: name);
        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        if (replyId != null) {
          expect(body['reply_parent_message_id'], replyId, reason: name);
        } else {
          expect(body['message'], 'hello chat', reason: name);
        }
      });
    }

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
    for (final (name, status, expected) in [
      ('sends DELETE /helix/users/blocks and returns true on 204', 204, true),
      ('returns false on non-204', 403, false),
    ]) {
      test(name, () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response('x', status),
        );
        expect(
          await api.unblockUser(auth, 'target123'),
          expected,
          reason: name,
        );
        if (expected) {
          expect(captured.method, 'DELETE');
          expect(
            captured.url.toString(),
            'https://api.twitch.tv/helix/users/blocks?target_user_id=target123',
          );
          expectAuthHeaders(captured);
        }
      });
    }
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

    for (final (name, method) in [
      ('addModerator POSTs to /helix/moderation/moderators', 'POST'),
      ('removeModerator DELETEs /helix/moderation/moderators', 'DELETE'),
    ]) {
      test(name, () async {
        late http.Request captured;
        final api = createApi((req) => captured = req);
        final ok = method == 'POST'
            ? await api.addModerator(auth, broadcasterId: 'b1', userId: 'u1')
            : await api.removeModerator(
                auth,
                broadcasterId: 'b1',
                userId: 'u1',
              );
        expect(ok, isTrue, reason: name);
        expect(captured.method, method, reason: name);
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/moderation/moderators?broadcaster_id=b1&user_id=u1',
          reason: name,
        );
      });
    }
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

    for (final (name, method) in [
      ('addVip POSTs to /helix/channels/vips', 'POST'),
      ('removeVip DELETEs /helix/channels/vips', 'DELETE'),
    ]) {
      test(name, () async {
        late http.Request captured;
        final api = createApi((req) => captured = req);
        final ok = method == 'POST'
            ? await api.addVip(auth, broadcasterId: 'b1', userId: 'u1')
            : await api.removeVip(auth, broadcasterId: 'b1', userId: 'u1');
        expect(ok, isTrue, reason: name);
        expect(captured.method, method, reason: name);
        expect(
          captured.url.toString(),
          'https://api.twitch.tv/helix/channels/vips?broadcaster_id=b1&user_id=u1',
          reason: name,
        );
      });
    }
  });

  group('updateChatSettings', () {
    for (final (name, status, expected) in [
      ('PATCHes /helix/chat/settings with the given body', 200, true),
      ('returns false on non-200', 403, false),
    ]) {
      test(name, () async {
        late http.Request captured;
        final api = createApi(
          (req) => captured = req,
          respond: () => http.Response('{"data": []}', status),
        );
        final ok = await api.updateChatSettings(
          auth,
          broadcasterId: 'b1',
          moderatorId: 'm1',
          body: {'slow_mode': true, 'slow_mode_wait_time': 30},
        );
        expect(ok, expected, reason: name);
        if (expected) {
          expect(captured.method, 'PATCH');
          expect(
            captured.url.toString(),
            'https://api.twitch.tv/helix/chat/settings?broadcaster_id=b1&moderator_id=m1',
          );
        }
      });
    }
  });

  group('ModActions', () {
    test('timeoutUser resolves login and posts duration plus reason', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(seen);
      final result = await modActions(api).timeoutUser(
        auth,
        'testchannel',
        login: 'target',
        duration: 600,
        reason: 'spam',
      );
      expect(result.ok, isTrue);
      expect(seen, hasLength(2));
      final post = seen[1] as http.Request;
      expect(post.method, 'POST');
      expect(post.url.path, '/helix/moderation/bans');
      expect(post.url.queryParameters['broadcaster_id'], 'broadcaster1');
      expect(post.url.queryParameters['moderator_id'], 'mod1');
      final body = jsonDecode(post.body)['data'] as Map<String, dynamic>;
      expect(body['user_id'], 'target1');
      expect(body['duration'], 600);
      expect(body['reason'], 'spam');
    });

    test('banUser posts no duration', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(seen);
      final result = await modActions(
        api,
      ).banUser(auth, 'testchannel', login: 'target');
      expect(result.ok, isTrue);
      final post = seen[1] as http.Request;
      expect(post.method, 'POST');
      expect(
        post.url.toString(),
        'https://api.twitch.tv/helix/moderation/bans?broadcaster_id=broadcaster1&moderator_id=mod1',
      );
      final body = jsonDecode(post.body)['data'] as Map<String, dynamic>;
      expect(body.containsKey('duration'), isFalse);
    });

    for (final (name, loginId, failure) in [
      ('refuses self targets', 'mod1', ModFailure.selfTarget),
      (
        'refuses broadcaster targets',
        'broadcaster1',
        ModFailure.broadcasterTarget,
      ),
    ]) {
      test(name, () async {
        final seen = <http.BaseRequest>[];
        final api = stubApi(seen, loginId: loginId);
        final result = await modActions(
          api,
        ).timeoutUser(auth, 'testchannel', login: 'x', duration: 60);
        expect(result.ok, isFalse, reason: name);
        expect(result.failure, failure, reason: name);
        expect(seen, hasLength(1), reason: 'no mod call after guard');
      });
    }

    test('unknown login fails without a mod call', () async {
      final seen = <http.BaseRequest>[];
      final api = TwitchApi(
        client: MockClient((request) async {
          seen.add(request);
          return http.Response('{"data": []}', 200);
        }),
      );
      final result = await modActions(
        api,
      ).banUser(auth, 'testchannel', login: 'ghost');
      expect(result.ok, isFalse);
      expect(result.failure, ModFailure.unknownUser);
      expect(seen, hasLength(1));
    });

    test('missing ids fail as notJoined without HTTP', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(seen);
      final noChannel = await modActions(
        api,
        channels: const {},
      ).clearChat(auth, 'testchannel');
      expect(noChannel.failure, ModFailure.notJoined);
      final noMod = await modActions(
        api,
        moderatorId: null,
      ).clearChat(auth, 'testchannel');
      expect(noMod.failure, ModFailure.notJoined);
      expect(seen, isEmpty);
    });

    test('API 403 surfaces the permission reason', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(
        seen,
        routes: {
          'POST /helix/moderation/bans': http.Response(
            '{"message": "forbidden"}',
            403,
          ),
        },
      );
      final result = await modActions(
        api,
      ).banUser(auth, 'testchannel', login: 'target');
      expect(result.ok, isFalse);
      expect(result.failure, ModFailure.apiError);
      expect(result.reason, contains("don't have permission"));
    });

    test('setSlowMode posts on/off bodies', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(seen);
      final actions = modActions(api);
      expect(
        (await actions.setSlowMode(auth, 'testchannel', enabled: true)).ok,
        isTrue,
      );
      final slowPatch = seen[0] as http.Request;
      expect(slowPatch.method, 'PATCH');
      expect(slowPatch.url.queryParameters['broadcaster_id'], 'broadcaster1');
      expect(slowPatch.url.queryParameters['moderator_id'], 'mod1');
      expect(jsonDecode(slowPatch.body), {
        'slow_mode': true,
        'slow_mode_wait_time': 30,
      });
      expect(
        (await actions.setSlowMode(
          auth,
          'testchannel',
          enabled: true,
          seconds: 120,
        )).ok,
        isTrue,
      );
      expect(jsonDecode((seen[1] as http.Request).body), {
        'slow_mode': true,
        'slow_mode_wait_time': 120,
      });
      expect(
        (await actions.setSlowMode(auth, 'testchannel', enabled: false)).ok,
        isTrue,
      );
      expect(jsonDecode((seen[2] as http.Request).body), {'slow_mode': false});
    });

    test('setFollowersMode omits duration when minutes is null', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(seen);
      final actions = modActions(api);
      await actions.setFollowersMode(auth, 'testchannel', enabled: true);
      expect(jsonDecode((seen[0] as http.Request).body), {
        'follower_mode': true,
      });
      await actions.setFollowersMode(
        auth,
        'testchannel',
        enabled: true,
        minutes: 30,
      );
      expect(jsonDecode((seen[1] as http.Request).body), {
        'follower_mode': true,
        'follower_mode_duration': 30,
      });
    });

    test('emote/subs/unique/shield send the right bodies', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(seen);
      final actions = modActions(api);
      await actions.setEmoteOnly(auth, 'testchannel', enabled: true);
      await actions.setSubscribersOnly(auth, 'testchannel', enabled: false);
      await actions.setUniqueChat(auth, 'testchannel', enabled: true);
      await actions.setShieldMode(auth, 'testchannel', active: true);
      for (var i = 0; i < 3; i++) {
        expect((seen[i] as http.Request).method, 'PATCH');
      }
      expect(jsonDecode((seen[0] as http.Request).body), {'emote_mode': true});
      expect(jsonDecode((seen[1] as http.Request).body), {
        'subscriber_mode': false,
      });
      expect(jsonDecode((seen[2] as http.Request).body), {
        'unique_chat_mode': true,
      });
      final shield = seen[3] as http.Request;
      expect(shield.method, 'PUT');
      expect(shield.url.queryParameters['broadcaster_id'], 'broadcaster1');
      expect(jsonDecode(shield.body), {'is_active': true});
    });

    test('failureReason maps 401, 429, and Helix messages', () async {
      final seen = <http.BaseRequest>[];
      Future<ModResult> banWith(int status, String body) => modActions(
        stubApi(
          seen,
          routes: {'POST /helix/moderation/bans': http.Response(body, status)},
        ),
      ).banUser(auth, 'testchannel', login: 'target');
      expect(
        (await banWith(401, 'Unauthorized')).reason,
        contains('Missing required scope'),
      );
      expect(
        (await banWith(429, 'slow down')).reason,
        contains('rate-limited'),
      );
      expect(
        (await banWith(400, '{"message": "You are timed out."}')).reason,
        'You are timed out.',
      );
    });

    test('deleteMessage targets one id, clearChat targets none', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(
        seen,
        routes: {'DELETE /helix/moderation/chat': http.Response('', 204)},
      );
      final actions = modActions(api);
      expect(
        (await actions.deleteMessage(auth, 'testchannel', 'msg-1')).ok,
        isTrue,
      );
      final del = seen[0] as http.Request;
      expect(del.method, 'DELETE');
      expect(
        del.url.toString(),
        'https://api.twitch.tv/helix/moderation/chat?broadcaster_id=broadcaster1&moderator_id=mod1&message_id=msg-1',
      );
      expect((await actions.clearChat(auth, 'testchannel')).ok, isTrue);
      final clear = seen[1] as http.Request;
      expect(clear.method, 'DELETE');
      expect(
        clear.url.toString(),
        'https://api.twitch.tv/helix/moderation/chat?broadcaster_id=broadcaster1&moderator_id=mod1',
      );
    });

    test('unban and warn hit their endpoints', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(
        seen,
        routes: {'DELETE /helix/moderation/bans': http.Response('', 204)},
      );
      final actions = modActions(api);
      expect(
        (await actions.unbanUser(auth, 'testchannel', login: 'target')).ok,
        isTrue,
      );
      final unban = seen[1] as http.Request;
      expect(unban.method, 'DELETE');
      expect(
        unban.url.toString(),
        'https://api.twitch.tv/helix/moderation/bans?broadcaster_id=broadcaster1&moderator_id=mod1&user_id=target1',
      );
      expect(
        (await actions.warnUser(
          auth,
          'testchannel',
          login: 'target',
          reason: 'r',
        )).ok,
        isTrue,
      );
      final warn = seen[2] as http.Request;
      expect(warn.method, 'POST');
      expect(
        warn.url.toString(),
        'https://api.twitch.tv/helix/moderation/warnings?broadcaster_id=broadcaster1&moderator_id=mod1',
      );
      expect(jsonDecode(warn.body)['data']['reason'], 'r');
    });

    test('setModerator and setVip use POST to add, DELETE to remove', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(
        seen,
        routes: {
          'POST /helix/moderation/moderators': http.Response('', 204),
          'DELETE /helix/moderation/moderators': http.Response('', 204),
          'POST /helix/channels/vips': http.Response('', 204),
          'DELETE /helix/channels/vips': http.Response('', 204),
        },
      );
      final actions = modActions(api);
      await actions.setModerator(auth, 'testchannel', login: 't', add: true);
      final modAdd = seen[1] as http.Request;
      expect(modAdd.method, 'POST');
      expect(
        modAdd.url.toString(),
        'https://api.twitch.tv/helix/moderation/moderators?broadcaster_id=broadcaster1&user_id=target1',
      );
      // Second call reuses the cached user id, so no GET precedes it.
      await actions.setModerator(auth, 'testchannel', login: 't', add: false);
      final modRemove = seen[2] as http.Request;
      expect(modRemove.method, 'DELETE');
      expect(modRemove.url.path, '/helix/moderation/moderators');
      await actions.setVip(auth, 'testchannel', login: 't', add: true);
      final vipAdd = seen[3] as http.Request;
      expect(vipAdd.method, 'POST');
      expect(
        vipAdd.url.toString(),
        'https://api.twitch.tv/helix/channels/vips?broadcaster_id=broadcaster1&user_id=target1',
      );
      await actions.setVip(auth, 'testchannel', login: 't', add: false);
      final vipRemove = seen[4] as http.Request;
      expect(vipRemove.method, 'DELETE');
      expect(vipRemove.url.path, '/helix/channels/vips');
    });

    test('announce, shoutout, commercial, raid, marker', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(
        seen,
        routes: {
          'POST /helix/chat/announcements': http.Response('', 204),
          'POST /helix/chat/shoutouts': http.Response('', 204),
          'DELETE /helix/raids': http.Response('', 204),
        },
      );
      final actions = modActions(api);
      await actions.sendAnnouncement(
        auth,
        'testchannel',
        message: 'hi',
        color: 'blue',
      );
      final announce = seen[0] as http.Request;
      expect(announce.url.path, '/helix/chat/announcements');
      expect(announce.url.queryParameters['broadcaster_id'], 'broadcaster1');
      expect(announce.url.queryParameters['moderator_id'], 'mod1');
      expect(jsonDecode(announce.body)['color'], 'blue');
      expect(
        (await actions.sendShoutout(auth, 'testchannel', login: 'target')).ok,
        isTrue,
      );
      final shoutout = seen[2] as http.Request;
      expect(shoutout.method, 'POST');
      expect(shoutout.body, isEmpty, reason: 'query-only call');
      expect(
        shoutout.url.toString(),
        'https://api.twitch.tv/helix/chat/shoutouts?from_broadcaster_id=broadcaster1&to_broadcaster_id=target1&moderator_id=mod1',
      );
      await actions.startCommercial(auth, 'testchannel', length: 30);
      final commercial = seen[3] as http.Request;
      expect(commercial.method, 'POST');
      expect(
        commercial.url.toString(),
        'https://api.twitch.tv/helix/channels/commercial',
      );
      expect(jsonDecode(commercial.body)['length'], 30);
      // 'target' is cached from the shoutout, so no GET precedes the POST.
      await actions.startRaid(auth, 'testchannel', login: 'target');
      final raid = seen[4] as http.Request;
      expect(raid.method, 'POST');
      expect(
        raid.url.toString(),
        'https://api.twitch.tv/helix/raids?from_broadcaster_id=broadcaster1&to_broadcaster_id=target1',
      );
      await actions.cancelRaid(auth, 'testchannel');
      final unraid = seen[5] as http.Request;
      expect(unraid.method, 'DELETE');
      expect(
        unraid.url.toString(),
        'https://api.twitch.tv/helix/raids?broadcaster_id=broadcaster1',
      );
      await actions.createMarker(auth, 'testchannel', description: 'x' * 200);
      final marker = seen[6] as http.Request;
      expect(marker.method, 'POST');
      expect(marker.url.path, '/helix/streams/markers');
      expect((jsonDecode(marker.body)['description'] as String).length, 140);
    });
  });

  group('commercial / raid / shield / marker / whisper', () {
    for (final (name, run) in <(String, Future<void> Function())>[
      (
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
      ),
      (
        'startRaid POSTs to /helix/raids with both broadcaster ids',
        () async {
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
        },
      ),
      (
        'cancelRaid DELETEs /helix/raids',
        () async {
          late http.Request captured;
          final api = createApi((req) => captured = req);
          expect(await api.cancelRaid(auth, broadcasterId: 'b1'), isTrue);
          expect(captured.method, 'DELETE');
          expect(
            captured.url.toString(),
            'https://api.twitch.tv/helix/raids?broadcaster_id=b1',
          );
        },
      ),
      (
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
      ),
      (
        'createMarker POSTs description to /helix/streams/markers',
        () async {
          late http.Request captured;
          final api = createApi(
            (req) => captured = req,
            respond: () => http.Response('{"data": []}', 200),
          );
          expect(
            await api.createMarker(
              auth,
              broadcasterId: 'b1',
              description: 'clip',
            ),
            isTrue,
          );
          expect(captured.method, 'POST');
          expect(
            captured.url.toString(),
            'https://api.twitch.tv/helix/streams/markers',
          );
          final body = jsonDecode(captured.body) as Map<String, dynamic>;
          expect(body, {'user_id': 'b1', 'description': 'clip'});
        },
      ),
      (
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
      ),
    ]) {
      test(name, () async {
        await run();
      });
    }
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

    for (final (name, action, meta, expectedAction) in [
      (
        'delete carries message id and body',
        'delete',
        {
          'delete': {
            'user_name': 'targetuser',
            'message_id': 'msg-1',
            'message_body': 'hello',
          },
        },
        'delete',
      ),
      (
        'shared_chat actions map to their base action',
        'shared_chat_ban',
        {
          'shared_chat_ban': {'user_name': 'targetuser'},
        },
        'ban',
      ),
      (
        'clear emits event without target',
        'clear',
        <String, dynamic>{},
        'clear',
      ),
    ]) {
      test(name, () async {
        final events = <ModerationEvent>[];
        service.onModeration.listen(events.add);
        service.handleRawMessage(_moderate(action: action, meta: meta));
        expect(events, hasLength(1), reason: name);
        expect(events[0].action, expectedAction, reason: name);
        if (expectedAction == 'delete') {
          expect(events[0].messageId, 'msg-1', reason: name);
          expect(events[0].messageBody, 'hello', reason: name);
        }
        if (expectedAction == 'clear') {
          expect(events[0].targetName, isNull, reason: name);
        }
      });
    }

    for (final (name, type, broadcaster) in [
      (
        'ignores notifications for unknown subscription types',
        'channel.chat.message',
        'broadcaster1',
      ),
      (
        'drops events without a channel mapping',
        'channel.moderate',
        'unknown_broadcaster',
      ),
    ]) {
      test(name, () async {
        final events = <ModerationEvent>[];
        service.onModeration.listen(events.add);
        service.handleRawMessage(<String, dynamic>{
          'metadata': <String, dynamic>{
            'message_type': 'notification',
            'subscription_type': type,
          },
          'payload': <String, dynamic>{
            'subscription': <String, dynamic>{
              'condition': <String, dynamic>{
                'broadcaster_user_id': broadcaster,
              },
            },
            'event': <String, dynamic>{'action': 'clear'},
          },
        });
        expect(events, isEmpty, reason: name);
      });
    }
  });

  group('notification (automod.message.hold/update)', () {
    Map<String, dynamic> automod(
      String type,
      Map<String, dynamic> event, {
      String broadcaster = 'broadcaster1',
    }) => <String, dynamic>{
      'metadata': <String, dynamic>{
        'message_type': 'notification',
        'subscription_type': type,
      },
      'payload': <String, dynamic>{
        'subscription': <String, dynamic>{
          'condition': <String, dynamic>{'broadcaster_user_id': broadcaster},
        },
        'event': event,
      },
    };

    // v2 shape: message and category are nested objects.
    Map<String, dynamic> heldEvent({
      String status = 'held',
      String? category = 'bullying',
      String messageId = 'msg-1',
    }) {
      final event = <String, dynamic>{
        'broadcaster_user_id': 'broadcaster1',
        'user_id': 'u1',
        'user_login': 'spammer',
        'user_name': 'Spammer',
        'message_id': messageId,
        'message': <String, dynamic>{'text': 'bad text here', 'fragments': []},
        'reason': 'automod',
        'held_at': '2026-01-01T00:00:00Z',
      };
      if (category != null) {
        event['automod'] = <String, dynamic>{'category': category, 'level': 4};
      }
      if (status != 'held') event['status'] = status;
      return event;
    }

    test('hold queues with user, text, and category', () async {
      final events = <AutomodHeldEvent>[];
      service.onAutomodHeld.listen(events.add);
      service.handleRawMessage(automod('automod.message.hold', heldEvent()));
      expect(events, hasLength(1));
      expect(events[0].channel, 'testchannel');
      expect(events[0].messageId, 'msg-1');
      expect(events[0].userLogin, 'spammer');
      expect(events[0].text, 'bad text here');
      expect(events[0].category, 'bullying');
      expect(events[0].status, 'held');
    });

    test('blocked-term hold without category falls back to reason', () async {
      final events = <AutomodHeldEvent>[];
      service.onAutomodHeld.listen(events.add);
      final event = heldEvent(category: null)..['reason'] = 'blocked_term';
      service.handleRawMessage(automod('automod.message.hold', event));
      expect(events, hasLength(1));
      expect(events[0].category, 'blocked_term');
    });

    test('v1 shape reads bare message string and top-level category', () async {
      final events = <AutomodHeldEvent>[];
      service.onAutomodHeld.listen(events.add);
      service.handleRawMessage(
        automod('automod.message.hold', <String, dynamic>{
          'broadcaster_user_id': 'broadcaster1',
          'user_login': 'spammer',
          'message_id': 'msg-9',
          'message': 'v1 bad text',
          'category': 'swearing',
          'level': 2,
          'held_at': '2026-01-01T00:00:00Z',
        }),
      );
      expect(events, hasLength(1));
      expect(events[0].text, 'v1 bad text');
      expect(events[0].category, 'swearing');
    });

    test('update lowercases the resolution status', () async {
      final events = <AutomodHeldEvent>[];
      service.onAutomodHeld.listen(events.add);
      service.handleRawMessage(
        automod('automod.message.update', heldEvent(status: 'Approved')),
      );
      expect(events, hasLength(1));
      expect(events[0].status, 'approved');
    });

    test('drops holds without a message id or channel mapping', () async {
      final events = <AutomodHeldEvent>[];
      service.onAutomodHeld.listen(events.add);
      service.handleRawMessage(
        automod('automod.message.hold', heldEvent(messageId: '')),
      );
      service.handleRawMessage(
        automod(
          'automod.message.hold',
          heldEvent(),
          broadcaster: 'unknown_broadcaster',
        ),
      );
      expect(events, isEmpty);
    });
  });

  group('manageHeldAutoModMessages', () {
    test('POSTs moderator, msg id, and ALLOW with no query params', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response('', 204),
      );
      final ok = await api.manageHeldAutoModMessages(
        auth,
        moderatorId: 'mod1',
        messageId: 'msg-1',
        allow: true,
      );
      expect(ok, isTrue);
      expect(captured.method, 'POST');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/moderation/automod/message',
      );
      expect(jsonDecode(captured.body), {
        'user_id': 'mod1',
        'msg_id': 'msg-1',
        'action': 'ALLOW',
      });
      expectAuthHeaders(captured);
    });

    test('DENY posts DENY; non-204 fails', () async {
      http.Request? captured;
      final api = TwitchApi(
        client: MockClient((request) async {
          captured = request;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('', body['action'] == 'DENY' ? 204 : 400);
        }),
      );
      expect(
        await api.manageHeldAutoModMessages(
          auth,
          moderatorId: 'mod1',
          messageId: 'msg-1',
          allow: false,
        ),
        isTrue,
      );
      expect(jsonDecode(captured!.body)['action'], 'DENY');
      expect(
        await api.manageHeldAutoModMessages(
          auth,
          moderatorId: 'mod1',
          messageId: 'msg-1',
          allow: true,
        ),
        isFalse,
      );
      expect(api.lastErrorStatus, 400);
    });
  });

  group('getShieldModeStatus', () {
    test('returns the flag on 200, null on failure', () async {
      late http.Request captured;
      final api = createApi(
        (req) => captured = req,
        respond: () => http.Response(
          '{"data": [{"is_active": true, "moderator_id": "m1"}]}',
          200,
        ),
      );
      expect(
        await api.getShieldModeStatus(
          auth,
          broadcasterId: 'b1',
          moderatorId: 'm1',
        ),
        isTrue,
      );
      expect(captured.method, 'GET');
      expect(
        captured.url.toString(),
        'https://api.twitch.tv/helix/moderation/shield_mode?broadcaster_id=b1&moderator_id=m1',
      );
      final failing = createApi(
        (_) {},
        respond: () => http.Response('[]', 403),
      );
      expect(
        await failing.getShieldModeStatus(
          auth,
          broadcasterId: 'b1',
          moderatorId: 'm1',
        ),
        isNull,
      );
      expect(failing.lastErrorStatus, 403);
    });
  });

  group('ModActions.decideHeldMessage', () {
    test('allow resolves the moderator id from the session getter', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(
        seen,
        routes: {
          'POST /helix/moderation/automod/message': http.Response('', 204),
        },
      );
      final result = await modActions(
        api,
      ).decideHeldMessage(auth, 'testchannel', messageId: 'msg-1', allow: true);
      expect(result.ok, isTrue);
      final post = seen[0] as http.Request;
      expect(post.url.path, '/helix/moderation/automod/message');
      expect(post.url.queryParameters, isEmpty, reason: 'body-only call');
      expect(jsonDecode(post.body), {
        'user_id': 'mod1',
        'msg_id': 'msg-1',
        'action': 'ALLOW',
      });
    });

    test('notJoined without ids, apiError on rejection', () async {
      final seen = <http.BaseRequest>[];
      final api = stubApi(
        seen,
        routes: {
          'POST /helix/moderation/automod/message': http.Response('', 403),
        },
      );
      final noIds = await modActions(
        api,
        moderatorId: null,
      ).decideHeldMessage(auth, 'testchannel', messageId: 'm', allow: false);
      expect(noIds.failure, ModFailure.notJoined);
      final denied = await modActions(
        api,
      ).decideHeldMessage(auth, 'testchannel', messageId: 'm', allow: false);
      expect(denied.failure, ModFailure.apiError);
      expect(seen, hasLength(1));
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

  group('parseIrcMessage', () {
    test('parses PING message', () {
      final msg = parseIrcMessage('PING :tmi.twitch.tv');
      expect(msg, isNotNull);
      expect(msg!.command, 'PING');
    });

    test('handles malformed message', () {
      final msg = parseIrcMessage(':');
      expect(msg, isNull);
    });

    for (final (name, line, command, trailing) in [
      (
        'parses basic IRC message',
        ':tmi.twitch.tv CLEARCHAT #xqc :forsen',
        'CLEARCHAT',
        'forsen',
      ),
      (
        'parses CLEARCHAT with tags (timeout)',
        '@ban-duration=300;target-user-id=12345 :tmi.twitch.tv CLEARCHAT #xqc :forsen',
        'CLEARCHAT',
        'forsen',
      ),
      (
        'parses CLEARMSG with target-msg-id and login tags',
        '@login=forsen;target-msg-id=abc-123;room-id=12345 :tmi.twitch.tv CLEARMSG #xqc :bad message',
        'CLEARMSG',
        'bad message',
      ),
      (
        'parses message with prefix only',
        ':testuser!testuser@testuser.tmi.twitch.tv PRIVMSG #xqc :hello',
        'PRIVMSG',
        'hello',
      ),
      (
        'handles message with spaces in trailing',
        ':user!user@user.tmi.twitch.tv PRIVMSG #channel :hello world this is a test',
        'PRIVMSG',
        'hello world this is a test',
      ),
      (
        'parses NOTICE message',
        ':tmi.twitch.tv NOTICE #xqc :This room requires a verified email account to chat.',
        'NOTICE',
        'This room requires a verified email account to chat.',
      ),
      (
        'parses NOTICE with tags',
        '@msg-id=slow_mode :tmi.twitch.tv NOTICE #xqc :You are sending messages too fast.',
        'NOTICE',
        'You are sending messages too fast.',
      ),
      (
        'parses WHISPER message',
        '@badges=;color=#FF0000;display-name=SomeUser;emotes=;message-id=whisper-1;thread-id=abc;turbo=0;user-id=999;user-type= :someuser!someuser@someuser.tmi.twitch.tv WHISPER recipient :hey there',
        'WHISPER',
        'hey there',
      ),
    ]) {
      test(name, () {
        final msg = parseIrcMessage(line);
        expect(msg, isNotNull, reason: name);
        expect(msg!.command, command, reason: name);
        expect(msg.trailing, trailing, reason: name);
      });
    }
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

    for (final (name, tag, original, stripped, prefix, start, end) in [
      (
        'ACTION messages use body-relative positions',
        '25:0-4',
        '\x01ACTION Kappa\x01',
        'Kappa',
        0,
        0,
        5,
      ),
      (
        'ACTION messages with reply prefix adjust by reply length only',
        '25:9-13',
        '\x01ACTION @User hi Kappa\x01',
        'hi Kappa',
        6,
        3,
        8,
      ),
    ]) {
      test(name, () {
        final positions = parseIrcEmotePositions(
          tag,
          originalText: original,
          strippedText: stripped,
          prefixLen: prefix,
        );
        expect(positions, hasLength(1), reason: name);
        expect(positions!.first.emoteCode, 'Kappa', reason: name);
        expect(positions.first.startIndex, start, reason: name);
        expect(positions.first.endIndex, end, reason: name);
      });
    }
  });

  group('shared chat PRIVMSG marking', () {
    test('mirrored message has sourceBroadcasterId and sourceMessageId', () {
      const raw =
          '@badges=subscriber/1;display-name=Forsen;id=copy-1;'
          'room-id=9999;source-id=orig-1;source-room-id=1234;'
          'user-id=42;color=#FF0000 '
          ':forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :Hello';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.sourceBroadcasterId, '1234');
      expect(msg.sourceMessageId, 'orig-1');
      expect(msg.messageId, 'copy-1');
    });

    for (final (name, raw) in [
      (
        'native message during session has no chip',
        '@badges=subscriber/1;display-name=XQC;id=native-1;room-id=9999;source-room-id=9999;user-id=99;color=#00FF00 :xqc!xqc@xqc.tmi.twitch.tv PRIVMSG #xqc :My own',
      ),
      (
        'plain message with no shared tags has no chip',
        '@badges=subscriber/1;display-name=Forsen;id=abc-123;user-id=42;color=#FF0000 :forsen!forsen@forsen.tmi.twitch.tv PRIVMSG #xqc :Plain',
      ),
    ]) {
      test(name, () {
        final msg = RecentMessagesService.parseIrcLine(raw);
        expect(msg, isNotNull, reason: name);
        expect(msg!.sourceBroadcasterId, isNull, reason: name);
        expect(msg.sourceMessageId, isNull, reason: name);
      });
    }
  });

  group('shared chat USERNOTICE (history)', () {
    for (final (name, raw) in [
      (
        'drops mirrored resub',
        '@msg-id=sharedchatnotice;source-msg-id=resub;login=forsen;system-msg=Resub\\s5\\smonths; :tmi.twitch.tv USERNOTICE #xqc',
      ),
      (
        'drops mirrored bitsbadgetier',
        '@msg-id=sharedchatnotice;source-msg-id=bitsbadgetier;login=forsen;system-msg=New\\sbits\\sbadge; :tmi.twitch.tv USERNOTICE #xqc',
      ),
    ]) {
      test(name, () {
        expect(RecentMessagesService.parseIrcLine(raw), isNull, reason: name);
      });
    }

    test('renders mirrored announcement as system message', () {
      const raw =
          '@msg-id=sharedchatnotice;source-msg-id=announcement;'
          'login=forsen;display-name=Forsen;'
          'msg-param-color=PURPLE; '
          ':tmi.twitch.tv USERNOTICE #xqc :The text';
      final msg = RecentMessagesService.parseIrcLine(raw);
      expect(msg, isNotNull);
      expect(msg!.text, 'Announcement');
      expect(msg.systemAccent, isNotNull);
    });

    test('parseAnnouncementChild accepts mirrored announcements', () {
      const raw =
          '@msg-id=sharedchatnotice;source-msg-id=announcement;'
          'login=forsen;display-name=Forsen;user-id=42;id=c1; '
          ':tmi.twitch.tv USERNOTICE #xqc :Hello';
      final child = RecentMessagesService.parseAnnouncementChild(raw);
      expect(child, isNotNull);
      expect(child!.login, 'forsen');
      expect(child.text, 'Hello');
    });

    test('parseAnnouncementChild rejects non-announcement mirrored', () {
      const raw =
          '@msg-id=sharedchatnotice;source-msg-id=resub;'
          'login=forsen; '
          ':tmi.twitch.tv USERNOTICE #xqc :Some text';
      expect(RecentMessagesService.parseAnnouncementChild(raw), isNull);
    });
  });
}
