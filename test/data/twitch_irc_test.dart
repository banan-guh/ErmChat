import 'package:flutter_test/flutter_test.dart';
import 'package:ermchat/services/twitch_irc.dart';

void main() {
  group('parseIrcMessage', () {
    test('parses basic IRC message', () {
      final msg = parseIrcMessage(':tmi.twitch.tv CLEARCHAT #xqc :forsen');
      expect(msg, isNotNull);
      expect(msg!.command, 'CLEARCHAT');
      expect(msg.params, ['#xqc']);
      expect(msg.trailing, 'forsen');
      expect(msg.prefix, 'tmi.twitch.tv');
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

    test('parses CLEARCHAT without tags (permanent ban)', () {
      const line = ':tmi.twitch.tv CLEARCHAT #xqc :forsen';
      final msg = parseIrcMessage(line);
      expect(msg, isNotNull);
      expect(msg!.tags, isEmpty);
      expect(msg.trailing, 'forsen');
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

    test('ACTION messages with emote mid-body', () {
      final positions = parseIrcEmotePositions(
        '25:6-10',
        originalText: '\x01ACTION hello Kappa\x01',
        strippedText: 'hello Kappa',
      );
      expect(positions, hasLength(1));
      expect(positions!.first.emoteCode, 'Kappa');
      expect(positions.first.startIndex, 6);
      expect(positions.first.endIndex, 11);
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
    test('covers sub, gift sub and upgrade msg-ids', () {
      expect(
        subNoticeMsgIds,
        containsAll(<String>[
          'sub',
          'resub',
          'subgift',
          'anonsubgift',
          'communitygift',
          'submysterygift',
          'giftpaidupgrade',
          'anongiftpaidupgrade',
          'primepaidupgrade',
        ]),
      );
    });

    test('excludes non-sub notices like announcements and raids', () {
      expect(subNoticeMsgIds, isNot(contains('announcement')));
      expect(subNoticeMsgIds, isNot(contains('raid')));
    });
  });
}
