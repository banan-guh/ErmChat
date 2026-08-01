import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/chat_connection_manager.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/services/twitch_eventsub.dart';
import 'package:ermchat/services/twitch_irc.dart';
import 'package:ermchat/services/twitch_irc_read.dart';
import 'package:ermchat/services/user_store.dart';

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

class _NoopEventSub extends EventSubService {
  @override
  Future<void> connect({String? url}) async {}
}

class _NoopIrc extends IrcService {
  @override
  Future<void> connect({
    required String username,
    required String accessToken,
  }) async {}
}

class _NoopIrcRead extends IrcReadService {
  @override
  Future<void> connect({
    required String username,
    required String accessToken,
  }) async {}
}

ChatConnectionManager _makeConn({
  required Map<String, List<TwitchMessage>> channelMessages,
  required int maxMessages,
}) {
  final api = TwitchApi(client: http.Client());
  return ChatConnectionManager(
    ChatConnectionConfig(
      twitchApi: api,
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
      lastTypedText: {},
      lastSentWireText: {},
      ownMessageIds: {},
      bumpChannel: (channel) {},
      invalidateChannel: (channel) {},
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
      onCommand: (t, c, a) {},
      getReplyToMsg: () => null,
      setReplyToMsg: (v) {},
      onRequestFocus: () {},
      onShowSnackBar: (m) {},
    ),
  );
}

ChatConnectionManager _makeReconnectConn({
  required EventSubService eventSub,
  required void Function() onReconnected,
}) {
  final api = TwitchApi(client: http.Client());
  final auth = TwitchAuth();
  auth.accessToken = 'test-token';
  return ChatConnectionManager(
    ChatConnectionConfig(
      twitchApi: api,
      eventSub: eventSub,
      irc: _NoopIrc(),
      ircRead: _NoopIrcRead(),
      emoteManager: EmoteManager(),
      badgeService: TwitchBadgeService(),
      userStore: UserStore(),
      twitchAuth: auth,
      channelMessages: {},
      messageKeys: {},
      chatStatus: {},
      channelsWithUnread: {},
      channelsWithUnreadMentions: {},
      unreadMentionsPerChannel: {},
      channels: [],
      historyLoaded: {},
      channelsEmotesResolved: {},
      channelUserIds: {},
      lastTypedText: {},
      lastSentWireText: {},
      ownMessageIds: {},
      bumpChannel: (channel) {},
      invalidateChannel: (channel) {},
      mentionsChannel: '@mentions',
      onRebuild: () {},
      onSystemMessage: (c, t) {},
      loadUserTwitchEmotes: () async {},
      onReconnected: onReconnected,
      getMaxMessagesPerChannel: () => 100,
      getSelectedChannel: () => null,
      getUnreadMentions: () => 0,
      setUnreadMentions: (v) {},
      getCurrentUserLogin: () => null,
      setCurrentUserLogin: (v) {},
      getCurrentUserId: () => null,
      setCurrentUserId: (v) {},
      onCommand: (t, c, a) {},
      getReplyToMsg: () => null,
      setReplyToMsg: (v) {},
      onRequestFocus: () {},
      onShowSnackBar: (m) {},
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('keeps exactly maxMessages when no threads exist', () {
    // 25 messages, newest first (m24, m23, ..., m0)
    final msgs = <String, List<TwitchMessage>>{
      'test': List.generate(25, (i) => _msg('m${24 - i}', 'msg ${24 - i}')),
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

  test(
    'removes one thread but keeps another when only one is within limit',
    () {
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
    },
  );

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

  group('thread stress', () {
    test('deeply nested chain preserves whole thread', () {
      // 200-message reply chain (r199 → r198 → ... → r0).
      // Latest 100 are non-thread filler, but the chain's leaf (r0) is within
      // the first 50 non-thread slots. The entire 200-message chain must be
      // preserved alongside the 50 non-thread messages.
      const limit = 100;
      const chainLen = 200;
      const fillerCount = 50;
      final msgs = <String, List<TwitchMessage>>{
        'test': [
          for (var i = chainLen - 1; i >= 0; i--)
            _msg(
              'r$i',
              'reply $i',
              replyToParentId: i > 0 ? 'r${i - 1}' : null,
            ),
          for (var i = 0; i < fillerCount; i++) _msg('f$i', 'filler $i'),
        ],
      };
      final conn = _makeConn(channelMessages: msgs, maxMessages: limit);
      conn.truncateChannelMessages('test');

      final remaining = msgs['test']!;
      expect(remaining.length, chainLen + fillerCount);

      // All chain messages are present
      for (var i = 0; i < chainLen; i++) {
        expect(
          remaining.any((m) => m.messageId == 'r$i'),
          true,
          reason: 'chain message r$i missing',
        );
      }
      // All filler messages are present
      for (var i = 0; i < fillerCount; i++) {
        expect(
          remaining.any((m) => m.messageId == 'f$i'),
          true,
          reason: 'filler f$i missing',
        );
      }
    });

    test(
      'deeply nested chain with root past cutoff but visible reply preserves all',
      () {
        // 200-message chain + 100 fillers. A mid-chain reply (r199) is in the
        // first 100 visible slots, which makes the root (r0) active via the
        // reply-chain walk. The entire chain is preserved alongside all fillers.
        const limit = 100;
        const chainLen = 200;
        const fillerCount = 100;
        final msgs = <String, List<TwitchMessage>>{
          'test': [
            for (var i = chainLen - 1; i >= 0; i--)
              _msg(
                'r$i',
                'reply $i',
                replyToParentId: i > 0 ? 'r${i - 1}' : null,
              ),
            for (var i = 0; i < fillerCount; i++) _msg('f$i', 'filler $i'),
          ],
        };
        final conn = _makeConn(channelMessages: msgs, maxMessages: limit);
        conn.truncateChannelMessages('test');

        final remaining = msgs['test']!;
        expect(remaining.length, chainLen + fillerCount);
      },
    );

    test('truncation stays bounded under heavy thread spam', () {
      // 1000 messages: 800 non-thread + 100 threads × 2 msgs each.
      // Many thread leaves are in the first 100 slots, making roots active.
      // Total preserved should not explode (threads + 100 non-thread).
      const limit = 100;
      const threadCount = 100;
      const fillerCount = 800;
      final msgs = <String, List<TwitchMessage>>{
        'test': [
          for (var t = threadCount - 1; t >= 0; t--)
            _msg('t${t}_c', 'child $t', replyToParentId: 't${t}_r'),
          for (var t = threadCount - 1; t >= 0; t--) _msg('t${t}_r', 'root $t'),
          for (var i = 0; i < fillerCount; i++) _msg('f$i', 'filler $i'),
        ],
      };
      final conn = _makeConn(channelMessages: msgs, maxMessages: limit);
      conn.truncateChannelMessages('test');

      final remaining = msgs['test']!;
      // Should NOT balloon to 10000.
      // All 100 leaves are visible (first 100 non-system slots).
      // Each makes its root active → 100 threads × 2 msgs + 100 fillers = 300.
      expect(remaining.length, greaterThan(100));
      expect(
        remaining.length,
        lessThan(500),
        reason: 'should not balloon past ~3x limit',
      );
    });

    test('many small threads with leaves in window all preserved', () {
      // 40 non-thread + 40 threads × 3 messages (root+mid+leaf) = 160.
      // All 40 leafs are within the 100 cutoff. All threads preserved.
      const limit = 100;
      const threadCount = 40;
      const fillerCount = 40;
      final msgs = <String, List<TwitchMessage>>{
        'test': [
          for (var t = threadCount - 1; t >= 0; t--)
            _msg('t${t}_l', 'leaf $t', replyToParentId: 't${t}_m'),
          for (var t = threadCount - 1; t >= 0; t--)
            _msg('t${t}_m', 'mid $t', replyToParentId: 't${t}_r'),
          for (var t = threadCount - 1; t >= 0; t--) _msg('t${t}_r', 'root $t'),
          for (var i = 0; i < fillerCount; i++) _msg('f$i', 'filler $i'),
        ],
      };
      final conn = _makeConn(channelMessages: msgs, maxMessages: limit);
      conn.truncateChannelMessages('test');

      final remaining = msgs['test']!;
      expect(
        remaining.length,
        threadCount * 3 + fillerCount,
        reason: 'all threads + filler should be kept',
      );

      for (var t = 0; t < threadCount; t++) {
        expect(remaining.any((m) => m.messageId == 't${t}_r'), true);
        expect(remaining.any((m) => m.messageId == 't${t}_m'), true);
        expect(remaining.any((m) => m.messageId == 't${t}_l'), true);
      }
    });

    test('orphan thread removed when entirely past cutoff', () {
      // 100 non-thread fillers come first (visible), then a 3-message thread.
      // Thread is past the cutoff window → orphan → removed.
      const limit = 100;
      final msgs = <String, List<TwitchMessage>>{
        'test': [
          for (var i = 0; i < limit; i++) _msg('f$i', 'filler $i'),
          _msg('leaf', 'leaf', replyToParentId: 'mid'),
          _msg('mid', 'mid', replyToParentId: 'root'),
          _msg('root', 'root'),
        ],
      };
      final conn = _makeConn(channelMessages: msgs, maxMessages: limit);
      conn.truncateChannelMessages('test');

      final remaining = msgs['test']!;
      expect(remaining.length, limit);
      expect(remaining.any((m) => m.messageId == 'root'), false);
      expect(remaining.any((m) => m.messageId == 'mid'), false);
      expect(remaining.any((m) => m.messageId == 'leaf'), false);
    });

    test('system messages compete with non-thread for same quota', () {
      // 100 system + 100 non-thread + 1 thread (3 msgs) with leaf visible.
      // System messages share the non-thread quota of 100.
      // Non-thread limit is 100 → 100 non-thread + 3 thread = 103 total.
      const limit = 100;
      final msgs = <String, List<TwitchMessage>>{
        'test': [
          _msg('leaf', 'leaf', replyToParentId: 'mid'),
          _msg('mid', 'mid', replyToParentId: 'root'),
          _msg('root', 'root'),
          for (var i = 0; i < limit; i++) _msg('f$i', 'filler $i'),
          for (var i = 0; i < limit; i++)
            TwitchMessage(
              login: '',
              text: 'sys $i',
              messageId: 's$i',
              channel: 'test',
              isSystem: true,
            ),
        ],
      };
      final conn = _makeConn(channelMessages: msgs, maxMessages: limit);
      conn.truncateChannelMessages('test');

      final remaining = msgs['test']!;
      // Thread (3) + non-thread+system (limit)
      expect(remaining.length, 3 + limit);

      // Thread preserved
      expect(remaining.any((m) => m.messageId == 'root'), true);
      expect(remaining.any((m) => m.messageId == 'mid'), true);
      expect(remaining.any((m) => m.messageId == 'leaf'), true);
    });
  });

  group('lifecycle', () {
    test('dispose sets isDisposed to true', () {
      final conn = _makeConn(channelMessages: {}, maxMessages: 10);
      expect(conn.isDisposed, false);
      conn.dispose();
      expect(conn.isDisposed, true);
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

  group('badge parsing', () {
    test('parses badges from IRC badges tag on own message', () {
      final msgs = <String, List<TwitchMessage>>{'test': []};
      final conn = _makeConn(channelMessages: msgs, maxMessages: 100);

      final ircMsg = IrcMessage(
        tags: {
          'badges': 'broadcaster/1,subscriber/12',
          'display-name': 'TestUser',
          'user-id': '12345',
          'id': 'msg1',
        },
        prefix: 'testuser!testuser@testuser.tmi.twitch.tv',
        command: 'PRIVMSG',
        params: ['#test'],
        trailing: 'hello',
      );

      conn.onOwnIrcMessage(ircMsg);

      expect(msgs['test']!.length, 1);
      final msg = msgs['test']!.first;
      expect(msg.badges, isNotNull);
      expect(msg.badges!.length, 2);
      expect(msg.badges![0].setId, 'broadcaster');
      expect(msg.badges![0].versionId, '1');
      expect(msg.badges![1].setId, 'subscriber');
      expect(msg.badges![1].versionId, '12');
    });

    test('badges is null when badges tag is absent', () {
      final msgs = <String, List<TwitchMessage>>{'test': []};
      final conn = _makeConn(channelMessages: msgs, maxMessages: 100);

      final ircMsg = IrcMessage(
        tags: {'display-name': 'TestUser', 'user-id': '12345', 'id': 'msg2'},
        prefix: 'testuser!testuser@testuser.tmi.twitch.tv',
        command: 'PRIVMSG',
        params: ['#test'],
        trailing: 'hello',
      );

      conn.onOwnIrcMessage(ircMsg);

      expect(msgs['test']!.length, 1);
      final msg = msgs['test']!.first;
      expect(msg.badges, isNull);
    });

    test('handles single badge', () {
      final msgs = <String, List<TwitchMessage>>{'test': []};
      final conn = _makeConn(channelMessages: msgs, maxMessages: 100);

      final ircMsg = IrcMessage(
        tags: {
          'badges': 'vip/1',
          'display-name': 'TestUser',
          'user-id': '12345',
          'id': 'msg3',
        },
        prefix: 'testuser!testuser@testuser.tmi.twitch.tv',
        command: 'PRIVMSG',
        params: ['#test'],
        trailing: 'vip message',
      );

      conn.onOwnIrcMessage(ircMsg);

      expect(msgs['test']!.length, 1);
      final msg = msgs['test']!.first;
      expect(msg.badges, isNotNull);
      expect(msg.badges!.length, 1);
      expect(msg.badges![0].setId, 'vip');
      expect(msg.badges![0].versionId, '1');
    });
  });

  group('reconnect callback', () {
    test('fires on EventSub reconnect but not on first connect', () async {
      final eventSub = _NoopEventSub();
      var calls = 0;
      final conn = _makeReconnectConn(
        eventSub: eventSub,
        onReconnected: () => calls++,
      );
      await conn.connect();

      eventSub.emitConnected();
      expect(calls, 0, reason: 'first connect must not trigger a re-fetch');

      eventSub.disconnect();
      eventSub.emitConnected();
      expect(calls, 1, reason: 'reconnect must trigger a re-fetch');

      // The second emitConnected lands inside the 30s subscribe throttle, so
      // the throttle return is reached after onReconnected already fired.
      eventSub.disconnect();
      eventSub.emitConnected();
      expect(calls, 2);

      conn.dispose();
    });

    test(
      'does not fire on repeated connected status without a disconnect',
      () async {
        final eventSub = _NoopEventSub();
        var calls = 0;
        final conn = _makeReconnectConn(
          eventSub: eventSub,
          onReconnected: () => calls++,
        );
        await conn.connect();

        eventSub.emitConnected();
        eventSub.emitConnected();
        expect(calls, 0);

        conn.dispose();
      },
    );
  });
}
