import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_twitch_app/models/twitch_message.dart';
import 'package:flutter_twitch_app/services/chat_connection_manager.dart';
import 'package:flutter_twitch_app/services/emote_manager.dart';
import 'package:flutter_twitch_app/services/twitch_auth.dart';
import 'package:flutter_twitch_app/services/twitch_badge_service.dart';
import 'package:flutter_twitch_app/services/twitch_eventsub.dart';
import 'package:flutter_twitch_app/services/twitch_irc.dart';
import 'package:flutter_twitch_app/services/twitch_irc_read.dart';
import 'package:flutter_twitch_app/services/user_store.dart';

TwitchMessage _msg(String id, String text, {String? replyToParentId}) =>
    TwitchMessage(
      login: 'user',
      text: text,
      messageId: id,
      channel: 'test',
      replyToParentId: replyToParentId,
      replyToUser: replyToParentId != null ? 'parent' : null,
      replyToText: replyToParentId != null ? 'parent text' : null,
    );

ChatConnectionManager _makeConn({
  required Map<String, List<TwitchMessage>> channelMessages,
  required int maxMessages,
}) {
  return ChatConnectionManager(
    eventSub: EventSubService(),
    irc: IrcService(),
    ircRead: IrcReadService(),
    emoteManager: EmoteManager(),
    badgeService: TwitchBadgeService(),
    userStore: UserStore(),
    twitchAuth: TwitchAuth(),
    channelMessages: channelMessages,
    messageKeys: {},
    chatStatus: {},
    channelsWithUnread: {},
    channelsWithUnreadMentions: {},
    unreadMentionsPerChannel: {},
    channels: ['test'],
    historyLoaded: {},
    channelsEmotesResolved: {},
    channelUserIds: {},
    pendingLocals: {},
    lastTypedText: {},
    lastSentWireText: {},
    ownMessageIds: {},
    chatVersion: ValueNotifier(0),
    mentionsChannel: '@mentions',
    onRebuild: () {},
    onSystemMessage: (c, t) {},
    loadUserTwitchEmotes: () async {},
    getMaxMessagesPerChannel: () => maxMessages,
    getSelectedChannel: () => null,
    getUnreadMentions: () => 0,
    setUnreadMentions: (v) {},
    getCurrentUserLogin: () => null,
    setCurrentUserLogin: (v) {},
    getCurrentUserId: () => null,
    setCurrentUserId: (v) {},
    getCurrentUserColor: () => null,
    setCurrentUserColor: (v) {},
    onCommand: (t, c, a) {},
    getReplyToMsg: () => null,
    setReplyToMsg: (v) {},
    onRequestFocus: () {},
    onShowSnackBar: (m) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('keeps exactly maxMessages when no threads exist', () {
    // 25 messages, newest first (m24, m23, ..., m0)
    final msgs = <String, List<TwitchMessage>>{
      'test': List.generate(
        25,
        (i) => _msg('m${24 - i}', 'msg ${24 - i}'),
      ),
    };
    final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
    conn.truncateChannelMessages('test');
    expect(msgs['test']!.length, 10);
    expect(msgs['test']!.first.messageId, 'm24');
    expect(msgs['test']!.last.messageId, 'm15');
  });

  test('preserves thread root when child is within limit', () {
    // 9 non-thread + parent + child = 11, limit 10
    // child at index 9 (within limit), parent at index 10 (past limit)
    final msgs = <String, List<TwitchMessage>>{
      'test': [
        ...List.generate(9, (i) => _msg('f$i', 'filler $i')),
        _msg('child', 'reply', replyToParentId: 'parent'),
        _msg('parent', 'root'),
      ],
    };
    final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
    conn.truncateChannelMessages('test');
    expect(msgs['test']!.length, 11);
    final ids = msgs['test']!.map((m) => m.messageId).toSet();
    expect(ids.contains('parent'), true);
    expect(ids.contains('child'), true);
  });

  test('removes entire thread when child is past limit', () {
    // 10 non-thread + parent + child = 12, limit 10
    // child at index 10 (past limit), parent at 11 (past limit)
    final msgs = <String, List<TwitchMessage>>{
      'test': [
        ...List.generate(10, (i) => _msg('f$i', 'filler $i')),
        _msg('child', 'reply', replyToParentId: 'parent'),
        _msg('parent', 'root'),
      ],
    };
    final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
    conn.truncateChannelMessages('test');
    expect(msgs['test']!.length, 10);
    final ids = msgs['test']!.map((m) => m.messageId).toSet();
    expect(ids.contains('parent'), false);
    expect(ids.contains('child'), false);
  });

  test('preserves multi-level thread when leaf is within limit', () {
    // 8 non-thread + grandchild + child + parent = 11, limit 10
    // grandchild at index 8 (within), child at 9 (within), parent at 10 (past)
    final msgs = <String, List<TwitchMessage>>{
      'test': [
        ...List.generate(8, (i) => _msg('f$i', 'filler $i')),
        _msg('grand', 'leaf', replyToParentId: 'child'),
        _msg('child', 'mid', replyToParentId: 'parent'),
        _msg('parent', 'root'),
      ],
    };
    final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
    conn.truncateChannelMessages('test');
    expect(msgs['test']!.length, 11);
    final ids = msgs['test']!.map((m) => m.messageId).toSet();
    expect(ids.contains('parent'), true);
    expect(ids.contains('child'), true);
    expect(ids.contains('grand'), true);
  });

  test('removes multi-level thread when all ancestors are past limit', () {
    // 10 non-thread + grandchild + child + parent = 13, limit 10
    final msgs = <String, List<TwitchMessage>>{
      'test': [
        ...List.generate(10, (i) => _msg('f$i', 'filler $i')),
        _msg('grand', 'leaf', replyToParentId: 'child'),
        _msg('child', 'mid', replyToParentId: 'parent'),
        _msg('parent', 'root'),
      ],
    };
    final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
    conn.truncateChannelMessages('test');
    expect(msgs['test']!.length, 10);
    final ids = msgs['test']!.map((m) => m.messageId).toSet();
    expect(ids.contains('parent'), false);
    expect(ids.contains('child'), false);
    expect(ids.contains('grand'), false);
  });

  test('handles multiple independent threads', () {
    // 6 non-thread + threadA(parent+child=2) + threadB(parent+child=2) = 10, limit 10
    // Both threads within limit
    final msgs = <String, List<TwitchMessage>>{
      'test': [
        ...List.generate(6, (i) => _msg('f$i', 'filler $i')),
        _msg('aChild', 'reply', replyToParentId: 'aParent'),
        _msg('aParent', 'root A'),
        _msg('bChild', 'reply', replyToParentId: 'bParent'),
        _msg('bParent', 'root B'),
      ],
    };
    final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
    conn.truncateChannelMessages('test');
    final ids = msgs['test']!.map((m) => m.messageId).toSet();
    expect(ids.contains('aParent'), true);
    expect(ids.contains('aChild'), true);
    expect(ids.contains('bParent'), true);
    expect(ids.contains('bChild'), true);
  });

  test('removes one thread but keeps another when only one is within limit', () {
    // 8 non-thread + threadA(2) + threadB(2) = 12, limit 10
    // threadA at indices 8-9 (within limit), threadB at 10-11 (past)
    final msgs = <String, List<TwitchMessage>>{
      'test': [
        ...List.generate(8, (i) => _msg('f$i', 'filler $i')),
        _msg('aChild', 'reply', replyToParentId: 'aParent'),
        _msg('aParent', 'root A'),
        _msg('bChild', 'reply', replyToParentId: 'bParent'),
        _msg('bParent', 'root B'),
      ],
    };
    final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
    conn.truncateChannelMessages('test');
    final ids = msgs['test']!.map((m) => m.messageId).toSet();
    expect(ids.contains('aParent'), true);
    expect(ids.contains('aChild'), true);
    expect(ids.contains('bParent'), false);
    expect(ids.contains('bChild'), false);
  });

  test('thread root alone (no children) is treated as non-thread', () {
    // 11 non-thread messages, limit 10
    // Root has no children -> no children entry in reply graph -> not active
    final msgs = <String, List<TwitchMessage>>{
      'test': List.generate(11, (i) => _msg('m$i', 'msg $i')),
    };
    final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
    conn.truncateChannelMessages('test');
    expect(msgs['test']!.length, 10);
  });

  test('no-op when under limit', () {
    final msgs = <String, List<TwitchMessage>>{
      'test': List.generate(5, (i) => _msg('m$i', 'msg $i')),
    };
    final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
    conn.truncateChannelMessages('test');
    expect(msgs['test']!.length, 5);
  });

  group('lifecycle', () {
    test('dispose sets mounted to false', () {
      final conn = _makeConn(channelMessages: {}, maxMessages: 10);
      expect(conn.mounted, true);
      conn.dispose();
      expect(conn.mounted, false);
    });

    test('double dispose does not crash', () {
      final conn = _makeConn(channelMessages: {}, maxMessages: 10);
      conn.dispose();
      expect(() => conn.dispose(), returnsNormally);
    });

    test('connect after dispose is no-op', () async {
      final conn = _makeConn(channelMessages: {}, maxMessages: 10);
      conn.dispose();
      // Should return without setting up listeners or connecting
      expect(() => conn.connect(), returnsNormally);
    });
  });
}
