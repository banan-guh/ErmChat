import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/models/highlight_state.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage _live(String id, {String login = 'alice'}) =>
    TwitchMessage(login: login, text: 'hello', messageId: id, channel: 'test');

void main() {
  group('Channel.receive mention and unread counting', () {
    test('mention in unselected channel bumps mention total and mirrors', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      final msg = _live('m1')
        ..highlight = const HighlightState(types: {HighlightType.username});
      final result = channel.receive(
        msg,
        maxMessages: 10,
        isSelected: false,
        ownLogin: null,
      );
      expect(result.inserted, isTrue);
      expect(result.mentioned, isTrue);
      expect(result.countMention, isTrue);
      // Aggregate step mirrors chat_ingestion.dart: mirror mentions, then
      // count the mention (which implies the bulk unread).
      if (result.mentioned) {
        chat.mentions.add([msg], maxMessages: 10);
      }
      if (result.countMention) {
        chat.noteMention();
      } else if (result.countUnread) {
        chat.noteUnread();
      }
      expect(chat.unreadMentions, 1);
      expect(chat.mentionsBump.value, 1);
      expect(chat.mentions.items, hasLength(1));
      expect(chat.mentions.items.single.messageId, 'm1');
    });

    test('mention in selected channel skips counters but still mirrors', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      final msg = _live('m1')
        ..highlight = const HighlightState(types: {HighlightType.reply});
      final result = channel.receive(
        msg,
        maxMessages: 10,
        isSelected: true,
        ownLogin: null,
      );
      expect(result.inserted, isTrue);
      expect(result.mentioned, isTrue);
      expect(result.countMention, isFalse);
      expect(result.countUnread, isFalse);
      if (result.mentioned) {
        chat.mentions.add([msg], maxMessages: 10);
      }
      if (result.countMention) {
        chat.noteMention();
      } else if (result.countUnread) {
        chat.noteUnread();
      }
      expect(chat.unreadMentions, 0);
      expect(chat.mentionsBump.value, 0);
      expect(chat.mentions.items, hasLength(1));
      expect(chat.mentions.items.single.messageId, 'm1');
    });

    test('own messages never count', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      final msg = _live('m1', login: 'me')
        ..highlight = const HighlightState(types: {HighlightType.username});
      final result = channel.receive(
        msg,
        maxMessages: 10,
        isSelected: false,
        ownLogin: 'me',
      );
      expect(result.inserted, isTrue);
      expect(result.mentioned, isFalse);
      expect(result.countMention, isFalse);
      expect(result.countUnread, isFalse);
      expect(channel.unread.mentionCount, 0);
      expect(channel.unread.hasUnread, isFalse);
    });

    test('history rows never count', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      final msg = TwitchMessage(
        login: 'alice',
        text: 'hello',
        messageId: 'm1',
        channel: 'test',
        isHistory: true,
      )..highlight = const HighlightState(types: {HighlightType.username});
      final result = channel.receive(
        msg,
        maxMessages: 10,
        isSelected: false,
        ownLogin: null,
      );
      expect(result.inserted, isTrue);
      expect(result.countMention, isFalse);
      expect(result.countUnread, isFalse);
      expect(channel.unread.mentionCount, 0);
      expect(channel.unread.hasUnread, isFalse);
    });

    test('system rows skip bulk unread', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      final result = channel.receive(
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
      expect(channel.unread.hasUnread, isFalse);
    });
  });
}
