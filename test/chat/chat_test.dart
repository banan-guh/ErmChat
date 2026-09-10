import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/models/highlight_state.dart';
import 'package:ermchat/models/moderation_entries.dart';
import 'package:ermchat/models/point_rewards.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage _live(
  String id, {
  String login = 'alice',
  String channel = 'test',
  HighlightState? highlight,
}) => TwitchMessage(
  login: login,
  text: 'hello $id',
  messageId: id,
  channel: channel,
  highlight: highlight,
);

TwitchMessage _reply(String id, String rootId) => TwitchMessage(
  login: 'bob',
  text: 'reply $id',
  messageId: id,
  channel: 'test',
  replyToParentId: rootId,
  replyThreadRootId: rootId,
);

const _mention = HighlightState(types: {HighlightType.username});

void main() {
  group('Chat', () {
    test('sub-success bump wakes moderation listeners', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      var ticks = 0;
      channel.moderation.version.addListener(() => ticks++);
      channel.moderation.noteSubscribed();
      expect(ticks, 1);
    });

    test('switchAccount clears account state, keeps rows and threads', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      channel.receive(
        _live('m1', login: 'me'),
        maxMessages: 100,
        isSelected: true,
        ownLogin: 'me',
      );
      channel.receive(
        _live('m2'),
        maxMessages: 100,
        isSelected: true,
        ownLogin: 'me',
      );
      channel.receive(
        _live('r1', login: 'alice'),
        maxMessages: 100,
        isSelected: true,
        ownLogin: 'me',
      );
      channel.receive(
        _reply('c1', 'r1'),
        maxMessages: 100,
        isSelected: true,
        ownLogin: 'me',
      );
      channel.threads.syncSavedKeys('test', {'test:r1'});
      final mentionMsg = _live('m3', highlight: _mention);
      channel.receive(
        mentionMsg,
        maxMessages: 100,
        isSelected: false,
        ownLogin: 'me',
      );
      chat.noteMention();
      chat.mentions.add([mentionMsg], maxMessages: 100);
      channel.moderation.addHeld(
        const HeldMessage(
          messageId: 'h1',
          channel: 'test',
          userLogin: 'spammer',
          text: 'buy now',
          category: 'spam',
        ),
      );
      final at = DateTime(2026, 1, 1);
      channel.moderation.addFeed(
        ModActivityEntry(
          at: at,
          channel: 'test',
          action: 'ban',
          moderator: 'mod',
          target: 'spammer',
        ),
      );
      channel.moderation.addWarning(
        WarnEntry(at: at, channel: 'test', target: 'spammer', moderator: 'mod'),
      );
      channel.moderation.putBan(
        BanEntry(at: at, channel: 'test', login: 'spammer', moderator: 'mod'),
      );
      channel.moderation.noteSuspicious(
        SuspiciousInfo(
          at: at,
          channel: 'test',
          login: 'spammer',
          status: 'monitored',
        ),
      );
      channel.points.setRewards(const [
        PointReward(
          id: 'r1',
          title: 'Hydrate',
          cost: 100,
          isEnabled: true,
          isPaused: false,
        ),
      ]);
      channel.points.upsertRedemption(
        const PointRedemption(
          id: 'x1',
          userLogin: 'alice',
          rewardId: 'r1',
          rewardTitle: 'Hydrate',
          cost: 100,
          userInput: '',
          status: 'UNFULFILLED',
          redeemedAt: '2026-01-01T00:00:00Z',
        ),
      );

      chat.switchAccount(login: null);

      expect(channel.messages.length, 5);
      expect(channel.threads.threadFor('r1'), hasLength(2));
      expect(channel.unread.mentionCount, 0);
      expect(chat.unreadMentions, 0);
      expect(chat.mentions.isEmpty, isTrue);
      expect(channel.moderation.held, isEmpty);
      expect(channel.moderation.feed, isEmpty);
      expect(channel.moderation.warnings, isEmpty);
      expect(channel.moderation.banFor('spammer'), isNull);
      expect(channel.moderation.suspiciousFor('spammer'), isNull);
      expect(channel.points.rewards, isEmpty);
      expect(channel.points.redemptions, isEmpty);
    });

    test('remove drops per-channel state and rebuilds aggregates', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('a');
      channel.receive(
        _live('m1', channel: 'a', highlight: _mention),
        maxMessages: 100,
        isSelected: false,
        ownLogin: 'me',
      );
      chat.noteMention();
      chat.recordLoadFailure('a', 'emotes');
      expect(chat.loadFailedChannels.value, {'a'});

      chat.remove('a');

      expect(chat.names, isEmpty);
      expect(chat.channelFor('a'), isNull);
      expect(chat.unreadMentions, 0);
      expect(chat.loadFailedChannels.value, isEmpty);
      chat.remove('missing');
    });

    test('clearUnread returns cleared mentions and resets dots', () {
      final chat = Chat();
      addTearDown(chat.dispose);
      final channel = chat.ensure('test');
      final msg = _live('m1', highlight: _mention);
      final result = channel.receive(
        msg,
        maxMessages: 100,
        isSelected: false,
        ownLogin: null,
      );
      if (result.countMention) chat.noteMention();
      expect(chat.unreadMentions, 1);
      expect(channel.unread.mentionCount, 1);
      expect(chat.clearUnread('test'), 1);
      expect(chat.unreadMentions, 0);
      expect(channel.unread.hasUnread, isFalse);
      expect(channel.unread.hasMention, isFalse);
      expect(chat.clearUnread('test'), 0);
      expect(chat.clearUnread('missing'), 0);
    });
  });
}
