import 'package:ermchat/chat/channel/messages.dart';
import 'package:ermchat/chat/chat.dart';
import 'package:ermchat/models/highlight_state.dart';
import 'package:ermchat/models/moderation_entries.dart';
import 'package:ermchat/models/point_rewards.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:flutter_test/flutter_test.dart';

TwitchMessage live(
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

TwitchMessage reply(String id, String rootId) => TwitchMessage(
  login: 'bob',
  text: 'reply $id',
  messageId: id,
  channel: 'test',
  replyToParentId: rootId,
  replyThreadRootId: rootId,
);

const mention = HighlightState(types: {HighlightType.username});

void main() {
  test('sub-success bump wakes moderation listeners', () {
    final chat = Chat();
    final channel = chat.ensure('test');
    var ticks = 0;
    channel.moderation.version.addListener(() => ticks++);
    channel.moderation.noteSubscribed();
    expect(ticks, 1);
    chat.dispose();
  });

  test('switchAccount clears account state, keeps rows and threads', () {
    final chat = Chat();
    final channel = chat.ensure('test');
    channel.receive(
      live('m1', login: 'me'),
      maxMessages: 100,
      isSelected: true,
      ownLogin: 'me',
    );
    channel.receive(
      live('m2'),
      maxMessages: 100,
      isSelected: true,
      ownLogin: 'me',
    );
    channel.receive(
      live('r1', login: 'alice'),
      maxMessages: 100,
      isSelected: true,
      ownLogin: 'me',
    );
    channel.receive(
      reply('c1', 'r1'),
      maxMessages: 100,
      isSelected: true,
      ownLogin: 'me',
    );
    channel.threads.syncSavedKeys('test', {'test:r1'});
    final mentionMsg = live('m3', highlight: mention);
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
    chat.dispose();
  });

  test('remove drops per-channel state and rebuilds aggregates', () {
    final chat = Chat();
    final channel = chat.ensure('a');
    channel.receive(
      live('m1', channel: 'a', highlight: mention),
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
    chat.dispose();
  });

  test('mass deletes bump once and emit one emitAll', () {
    final messages = Messages(channel: 'test');
    messages.add(live('m1'), maxMessages: 100);
    messages.add(live('m2'), maxMessages: 100);
    messages.add(live('m3', login: 'bob'), maxMessages: 100);
    final emitted = <String?>[];
    var allCount = 0;
    messages.mutations.addListener(emitted.add);
    messages.mutations.addAllListener(() => allCount++);

    final before = messages.version.value;
    expect(messages.markUserDeleted('alice'), isTrue);

    expect(messages.version.value, before + 1);
    expect(allCount, 1);
    expect(emitted, isEmpty);

    messages.markAllDeleted();
    expect(messages.version.value, before + 2);
    expect(allCount, 2);
    expect(emitted, isEmpty);
    messages.dispose();
  });

  test('saved and pinned rows survive the cap through lazy exemptions', () {
    var t = DateTime(2026, 1, 1);
    final messages = Messages(channel: 'test', now: () => t);
    var builds = 0;
    TruncateExemptions build() {
      builds++;
      return const TruncateExemptions(
        savedRootIds: {'r1'},
        pinnedMessageIds: {'c3'},
      );
    }

    messages.add(live('lone'), maxMessages: 2, buildExemptions: build);
    expect(builds, 0);

    for (final m in [
      live('r1'),
      reply('c1', 'r1'),
      reply('c2', 'r1'),
      live('r2'),
      reply('c3', 'r2'),
      live('s1'),
      live('s2'),
      live('s3'),
    ]) {
      t = t.add(const Duration(seconds: 1));
      messages.add(m, maxMessages: 2, buildExemptions: build);
    }

    expect(builds, greaterThan(0));
    for (final id in ['r1', 'c1', 'c2', 'r2', 'c3', 's3', 's2']) {
      expect(messages.byId(id), isNotNull, reason: id);
    }
    expect(messages.byId('s1'), isNull);
    expect(messages.byId('lone'), isNull);
    messages.dispose();
  });
}
