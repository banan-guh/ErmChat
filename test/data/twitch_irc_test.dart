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
