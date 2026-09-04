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
        const Color(0xFF9146FF),
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
        const Color(0xFF9146FF),
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
        expect(msg.systemAccent, const Color(0xFF9146FF), reason: name);
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
        expect(msg.systemAccent, const Color(0xFF9146FF), reason: name);
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
