import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/models/highlight_state.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage _live(String id, {String login = 'alice'}) =>
    TwitchMessage(login: login, text: 'hello', messageId: id, channel: 'test');

void main() {
  group('Chat.receive mention and unread counting', () {
    test('mention in unselected channel bumps mention total and mirrors', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final msg = _live('m1')
        ..highlight = const HighlightState(types: {HighlightType.username});
      final result = chat.receive(
        'test',
        msg,
        maxMessages: 10,
        isSelected: false,
        ownLogin: null,
      );
      expect(result.inserted, isTrue);
      expect(result.mentioned, isTrue);
      expect(result.countMention, isTrue);
      expect(chat.unreadMentions, 1);
      expect(chat.mentionsBump.value, 1);
      expect(chat.mentions.items, hasLength(1));
      expect(chat.mentions.items.single.messageId, 'm1');
    });

    test('mention in selected channel skips counters but still mirrors', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final msg = _live('m1')
        ..highlight = const HighlightState(types: {HighlightType.reply});
      final result = chat.receive(
        'test',
        msg,
        maxMessages: 10,
        isSelected: true,
        ownLogin: null,
      );
      expect(result.inserted, isTrue);
      expect(result.mentioned, isTrue);
      expect(result.countMention, isFalse);
      expect(result.countUnread, isFalse);
      expect(chat.unreadMentions, 0);
      expect(chat.mentionsBump.value, 0);
      expect(chat.mentions.items, hasLength(1));
      expect(chat.mentions.items.single.messageId, 'm1');
    });

    test('own messages never count', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final msg = _live('m1', login: 'me')
        ..highlight = const HighlightState(types: {HighlightType.username});
      final result = chat.receive(
        'test',
        msg,
        maxMessages: 10,
        isSelected: false,
        ownLogin: 'me',
      );
      expect(result.inserted, isTrue);
      expect(result.mentioned, isFalse);
      expect(result.countMention, isFalse);
      expect(result.countUnread, isFalse);
      expect(chat.unreadMentions, 0);
      expect(chat.mentions.isEmpty, isTrue);
      final channel = chat.channelFor('test')!;
      expect(channel.unread.mentionCount, 0);
      expect(channel.unread.hasUnread, isFalse);
    });

    test('history rows never count', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final msg = TwitchMessage(
        login: 'alice',
        text: 'hello',
        messageId: 'm1',
        channel: 'test',
        isHistory: true,
      )..highlight = const HighlightState(types: {HighlightType.username});
      final result = chat.receive(
        'test',
        msg,
        maxMessages: 10,
        isSelected: false,
        ownLogin: null,
      );
      expect(result.inserted, isTrue);
      expect(result.countMention, isFalse);
      expect(result.countUnread, isFalse);
      expect(chat.unreadMentions, 0);
      final channel = chat.channelFor('test')!;
      expect(channel.unread.mentionCount, 0);
      expect(channel.unread.hasUnread, isFalse);
    });

    test('system rows skip bulk unread', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final result = chat.receive(
        'test',
        TwitchMessage(
          login: '',
          text: 'slow mode on',
          isSystem: true,
          channel: 'test',
        ),
        maxMessages: 10,
        isSelected: false,
        ownLogin: null,
      );
      expect(result.inserted, isTrue);
      expect(result.countUnread, isFalse);
      expect(chat.channelFor('test')!.unread.hasUnread, isFalse);
    });
  });

  group('Chat.receiveHistory mention mirror', () {
    TwitchMessage history(String id, {String login = 'alice'}) => TwitchMessage(
      login: login,
      text: 'hello',
      messageId: id,
      channel: 'test',
      isHistory: true,
    )..highlight = const HighlightState(types: {HighlightType.username});

    test('mirrors mention rows and never counts unread', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      chat.receiveHistory(
        'test',
        [history('m1')],
        rawHistory: [history('m1')],
        maxMessages: 10,
        ownLogin: null,
      );
      expect(chat.mentions.items.single.messageId, 'm1');
      expect(chat.unreadMentions, 0);
      expect(chat.channelFor('test')!.unread.mentionCount, 0);
    });

    test('own mention rows are not mirrored', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      chat.receiveHistory(
        'test',
        [history('m1', login: 'me')],
        rawHistory: [history('m1', login: 'me')],
        maxMessages: 10,
        ownLogin: 'me',
      );
      expect(chat.mentions.isEmpty, isTrue);
    });
  });
}
