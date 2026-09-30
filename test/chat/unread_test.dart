import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/models/highlight_state.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage _live(
  String id, {
  String login = 'alice',
  bool history = false,
  HighlightType type = HighlightType.username,
}) => TwitchMessage(
  login: login,
  text: 'hello',
  messageId: id,
  channel: 'test',
  isHistory: history,
)..highlight = HighlightState(types: {type});

void main() {
  group('Chat.receive mention and unread counting', () {
    test(
      'mentions mirror always, count only when the channel is unselected',
      () {
        for (final (name, selected, type, counted) in [
          ('unselected channel', false, HighlightType.username, true),
          ('selected channel', true, HighlightType.reply, false),
        ]) {
          final chat = Chat();
          addTearDown(chat.dispose);
          final result = chat.receive(
            'test',
            _live('m1', type: type),
            maxMessages: 10,
            isSelected: selected,
            ownLogin: null,
          );
          expect(result.inserted, isTrue);
          expect(result.mentioned, isTrue);
          expect(result.countMention, counted);
          expect(chat.unreadMentions, counted ? 1 : 0);
          expect(chat.mentionsBump.value, counted ? 1 : 0);
          expect(chat.mentions.items.single.messageId, 'm1', reason: name);
        }
      },
    );

    test('own, history and system rows never count', () {
      for (final (name, msg, ownLogin) in <(String, TwitchMessage, String?)>[
        ('own messages', _live('m1', login: 'me'), 'me'),
        ('history rows', _live('m1', history: true), null),
        (
          'system rows',
          TwitchMessage(
            login: '',
            text: 'slow mode on',
            isSystem: true,
            channel: 'test',
          ),
          null,
        ),
      ]) {
        final chat = Chat();
        addTearDown(chat.dispose);
        final result = chat.receive(
          'test',
          msg,
          maxMessages: 10,
          isSelected: false,
          ownLogin: ownLogin,
        );
        expect(result.inserted, isTrue);
        expect(result.countMention, isFalse);
        expect(result.countUnread, isFalse);
        expect(chat.unreadMentions, 0);
        final unread = chat.channelFor('test')!.unread;
        expect(unread.mentionCount, 0);
        expect(unread.hasUnread, isFalse, reason: name);
      }
    });
  });

  group('Chat.receiveHistory mention mirror', () {
    test('mirrors others mention rows without counting; skips own', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      chat.receiveHistory(
        'test',
        [_live('m1', history: true), _live('m2', login: 'me', history: true)],
        rawHistory: [
          _live('m1', history: true),
          _live('m2', login: 'me', history: true),
        ],
        maxMessages: 10,
        ownLogin: 'me',
      );
      expect(chat.mentions.items.map((m) => m.messageId), ['m1']);
      expect(chat.unreadMentions, 0);
      expect(chat.channelFor('test')!.unread.mentionCount, 0);
    });
  });
}
