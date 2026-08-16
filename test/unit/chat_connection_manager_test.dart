import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/models/emote_fetch_tier.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/base_irc_connection.dart';
import 'package:ermchat/services/chat_connection_manager.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/services/twitch_eventsub.dart';
import 'package:ermchat/services/twitch_irc.dart';
import 'package:ermchat/services/twitch_irc_read.dart';
import '../helpers/fake_web_socket.dart';
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

class _StaleEventSub extends _NoopEventSub {
  _StaleEventSub({this.stale = false});

  final bool stale;
  int forceCalls = 0;

  @override
  bool get isConnected => true;

  @override
  bool get isStale => stale;

  @override
  Future<void> forceReconnect() async {
    forceCalls++;
  }
}

class _TestIrc extends IrcService {
  final _statusCtrl = StreamController<IrcConnectionStatus>.broadcast(
    sync: true,
  );
  bool alive = true;
  int connectCalls = 0;
  int openAttempts = 0;
  FakeWebSocketChannel? _stubChannel;

  @override
  Future<void> connect({
    required String username,
    required String accessToken,
  }) async {
    connectCalls++;
    this.username = username.toLowerCase();
    token = accessToken;
  }

  @override
  Future<bool> checkAlive({
    Duration timeout = const Duration(seconds: 5),
  }) async => alive;

  @override
  Future<WebSocketChannel> openChannel() async {
    openAttempts++;
    return _stubChannel ??= FakeWebSocketChannel();
  }

  @override
  Stream<IrcConnectionStatus> get onStatus => _statusCtrl.stream;

  @override
  bool get isConnected => channel != null;

  void emitConnected() {
    channel = _stubChannel ??= FakeWebSocketChannel();
    _statusCtrl.add(IrcConnectionStatus.connected);
  }

  void emitDisconnected() {
    channel = null;
    _statusCtrl.add(IrcConnectionStatus.disconnected);
  }

  @override
  void dispose() {
    _stubChannel?.dispose();
    _statusCtrl.close();
    super.dispose();
  }
}

class _NoopIrcRead extends IrcReadService {
  @override
  Future<void> connect({
    required String username,
    required String accessToken,
  }) async {}
}

/// EmoteManager that surfaces whether [enqueueSeenEmotes] is called and feeds
/// a fake channel cache, so precache behavior is observable without fetching.
class _SpyEmoteManager extends EmoteManager {
  _SpyEmoteManager({required super.tier})
    : super(fetchStagger: Duration.zero, cacheCap: 0);

  static const _emote = GenericEmote(
    id: 'e1',
    code: 'E1',
    type: EmoteType.bttv,
    url: 'https://example.com/e1.png',
  );

  int enqueueSeenCalls = 0;
  final List<String> viewedIds = [];

  @override
  void enqueueSeenEmotes(List<GenericEmote> emotes) {
    enqueueSeenCalls++;
    super.enqueueSeenEmotes(emotes);
  }

  @override
  void markEmoteViewed(GenericEmote emote) {
    viewedIds.add(emote.id);
    super.markEmoteViewed(emote);
  }

  @override
  GenericEmote? emoteById(String id) => id == _emote.id ? _emote : null;

  @override
  ChannelEmotes? byCode(String channel) =>
      ChannelEmotes(byCode: const {'E1': _emote}, suggestions: const [_emote]);
}

ChatConnectionManager _makeConn({
  required Map<String, List<TwitchMessage>> channelMessages,
  required int maxMessages,
  EmoteManager? emoteManager,
  DateTime Function()? truncateNow,
  Duration? truncateCoalesceWindow,
}) {
  final api = TwitchApi(client: http.Client());
  return ChatConnectionManager(
    ChatConnectionConfig(
      twitchApi: api,
      eventSub: EventSubService(),
      irc: IrcService(),
      ircRead: IrcReadService(),
      emoteManager: emoteManager ?? EmoteManager(),
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
      bumpChannel: (channel) {},
      invalidateChannel: (channel) {},
      invalidateMessage: (channel, messageId) {},
      mentionsChannel: '@mentions',
      onRebuild: () {},
      onSystemMessage: (c, t, {Color? accent}) {},
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
      truncateNow: truncateNow,
      truncateCoalesceWindow:
          truncateCoalesceWindow ?? const Duration(milliseconds: 250),
    ),
  );
}

ChatConnectionManager _makeReconnectConn({
  required EventSubService eventSub,
  required IrcService irc,
  required void Function() onReconnected,
  Map<String, List<TwitchMessage>>? channelMessages,
  Map<String, String>? chatStatus,
  void Function(String, String, {Color? accent})? onSystemMessage,
  String? currentUserLogin,
  void Function(HypeTrainEvent event)? onHypeTrain,
  Future<void> Function(String?, List<String>)? onUserEmoteSets,
}) {
  final api = TwitchApi(client: http.Client());
  final auth = TwitchAuth();
  auth.accessToken = 'test-token';
  return ChatConnectionManager(
    ChatConnectionConfig(
      twitchApi: api,
      eventSub: eventSub,
      irc: irc,
      ircRead: _NoopIrcRead(),
      emoteManager: EmoteManager(),
      badgeService: TwitchBadgeService(),
      userStore: UserStore(),
      twitchAuth: auth,
      channelMessages: channelMessages ?? {},
      messageKeys: {},
      chatStatus: chatStatus ?? {},
      channelsWithUnread: {},
      channelsWithUnreadMentions: {},
      unreadMentionsPerChannel: {},
      channels: [],
      historyLoaded: {},
      channelsEmotesResolved: {},
      channelUserIds: {},
      lastTypedText: {},
      lastSentWireText: {},
      bumpChannel: (channel) {},
      invalidateChannel: (channel) {},
      invalidateMessage: (channel, messageId) {},
      mentionsChannel: '@mentions',
      onRebuild: () {},
      onSystemMessage: onSystemMessage ?? (c, t, {Color? accent}) {},
      onReconnected: onReconnected,
      getMaxMessagesPerChannel: () => 100,
      getSelectedChannel: () => null,
      getUnreadMentions: () => 0,
      setUnreadMentions: (v) {},
      getCurrentUserLogin: () => currentUserLogin,
      setCurrentUserLogin: (v) {},
      getCurrentUserId: () => null,
      setCurrentUserId: (v) {},
      onCommand: (t, c, a) {},
      getReplyToMsg: () => null,
      setReplyToMsg: (v) {},
      onRequestFocus: () {},
      onShowSnackBar: (m) {},
      onHypeTrain: onHypeTrain,
      onUserEmoteSets: onUserEmoteSets,
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

  group('truncate coalescing', () {
    test('defers the full pass while messages arrive within the window', () {
      var t = DateTime(2026, 1, 1, 12);
      final msgs = <String, List<TwitchMessage>>{
        'test': List.generate(11, (i) => _msg('m${10 - i}', 'msg ${10 - i}')),
      };
      final conn = _makeConn(
        channelMessages: msgs,
        maxMessages: 10,
        truncateNow: () => t,
      );
      // Direct truncate seeds the last-full-pass timestamp.
      conn.truncateChannelMessages('test');
      expect(msgs['test']!.length, 10);

      // Within the window: message inserts but truncation is deferred.
      t = t.add(const Duration(milliseconds: 100));
      conn.onMessage(_msg('new1', 'new one'));
      expect(msgs['test']!.length, 11);
    });

    test('runs the full pass on the first message after the window', () {
      var t = DateTime(2026, 1, 1, 12);
      final msgs = <String, List<TwitchMessage>>{
        'test': List.generate(11, (i) => _msg('m${10 - i}', 'msg ${10 - i}')),
      };
      final conn = _makeConn(
        channelMessages: msgs,
        maxMessages: 10,
        truncateNow: () => t,
      );
      conn.truncateChannelMessages('test');
      expect(msgs['test']!.length, 10);

      // Past the window: the message triggers the full pass.
      t = t.add(const Duration(milliseconds: 300));
      conn.onMessage(_msg('new1', 'new one'));
      expect(msgs['test']!.length, 10);
    });

    test('runs the full pass immediately when the hard cap is exceeded', () {
      var t = DateTime(2026, 1, 1, 12);
      final msgs = <String, List<TwitchMessage>>{
        'test': List.generate(11, (i) => _msg('m${10 - i}', 'msg ${10 - i}')),
      };
      final conn = _makeConn(
        channelMessages: msgs,
        maxMessages: 10,
        truncateNow: () => t,
      );
      conn.truncateChannelMessages('test');
      expect(msgs['test']!.length, 10);

      // 11 messages within the window push past 2x the cap (20): the full
      // pass runs even though the window has not elapsed.
      t = t.add(const Duration(milliseconds: 100));
      for (var i = 1; i <= 11; i++) {
        conn.onMessage(_msg('b$i', 'burst $i'));
      }
      expect(msgs['test']!.length, 10);
    });

    test('keeps the buffer bounded between passes', () {
      var t = DateTime(2026, 1, 1, 12);
      final msgs = <String, List<TwitchMessage>>{
        'test': List.generate(11, (i) => _msg('m${10 - i}', 'msg ${10 - i}')),
      };
      final conn = _makeConn(
        channelMessages: msgs,
        maxMessages: 10,
        truncateNow: () => t,
      );
      conn.truncateChannelMessages('test');
      expect(msgs['test']!.length, 10);

      // 4 deferred messages stay in the buffer (hard cap not reached).
      t = t.add(const Duration(milliseconds: 100));
      for (var i = 1; i <= 4; i++) {
        conn.onMessage(_msg('b$i', 'burst $i'));
      }
      expect(msgs['test']!.length, 14);
    });
  });

  group('lifecycle', () {
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
  });

  group('own /me messages', () {
    test('strips ACTION wrapper and sets isAction', () {
      final msgs = <String, List<TwitchMessage>>{'test': []};
      final conn = _makeConn(channelMessages: msgs, maxMessages: 100);

      final ircMsg = IrcMessage(
        tags: {'display-name': 'TestUser', 'user-id': '12345', 'id': 'msg-me'},
        prefix: 'testuser!testuser@testuser.tmi.twitch.tv',
        command: 'PRIVMSG',
        params: ['#test'],
        trailing: '\x01ACTION waves at chat\x01',
      );

      conn.onOwnIrcMessage(ircMsg);

      expect(msgs['test']!.length, 1);
      final msg = msgs['test']!.first;
      expect(msg.text, 'waves at chat');
      expect(msg.isAction, isTrue);
    });

    test('adjusts emote positions for the stripped ACTION prefix', () {
      final msgs = <String, List<TwitchMessage>>{'test': []};
      final conn = _makeConn(channelMessages: msgs, maxMessages: 100);

      final ircMsg = IrcMessage(
        tags: {
          'display-name': 'TestUser',
          'user-id': '12345',
          'id': 'msg-me2',
          // Twitch reports ACTION positions relative to the message body
          // (after the \x01ACTION wrapper), not the raw PRIVMSG text.
          'emotes': '123:0-7',
        },
        prefix: 'testuser!testuser@testuser.tmi.twitch.tv',
        command: 'PRIVMSG',
        params: ['#test'],
        trailing: '\x01ACTION PogChamp hi\x01',
      );

      conn.onOwnIrcMessage(ircMsg);

      final msg = msgs['test']!.first;
      expect(msg.text, 'PogChamp hi');
      expect(msg.emotePositions, isNotNull);
      expect(msg.emotePositions!.single.startIndex, 0);
      expect(msg.emotePositions!.single.endIndex, 8);
      expect(msg.emotePositions!.single.emoteCode, 'PogChamp');
    });
  });

  group('reconnect callback', () {
    test('fires on IRC reconnect but not on first connect', () async {
      final irc = _TestIrc();
      var calls = 0;
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        onReconnected: () => calls++,
      );
      await conn.connect();

      irc.emitConnected();
      expect(calls, 0, reason: 'first connect must not trigger a re-fetch');

      irc.emitDisconnected();
      irc.emitConnected();
      expect(calls, 1, reason: 'reconnect must trigger a re-fetch');

      // The second emitConnected lands inside the 30s subscribe throttle, so
      // the throttle return is reached after onReconnected already fired.
      irc.emitDisconnected();
      irc.emitConnected();
      expect(calls, 2);

      conn.dispose();
    });

    test(
      'does not fire on repeated connected status without a disconnect',
      () async {
        final irc = _TestIrc();
        var calls = 0;
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          onReconnected: () => calls++,
        );
        await conn.connect();

        irc.emitConnected();
        irc.emitConnected();
        expect(calls, 0);

        conn.dispose();
      },
    );
  });

  group('USERNOTICE routing', () {
    test('announcement renders label plus child message', () async {
      final irc = _TestIrc();
      final systemMessages = <(String, String, Color?)>[];
      final channelMessages = <String, List<TwitchMessage>>{};
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        onReconnected: () {},
        channelMessages: channelMessages,
        onSystemMessage: (c, t, {Color? accent}) {
          systemMessages.add((c, t, accent));
        },
      );
      await conn.connect();
      irc.emitConnected();

      // Real captured USERNOTICE line (BLUE announcement).
      irc.handleLine(
        '@badge-info=;badges=broadcaster/1;color=#0000FF;display-name=ermugo2;'
        'emotes=emotesv2_123:0-4;flags=;id=abc;login=ermugo2;mod=0;'
        'msg-id=announcement;'
        'msg-param-color=BLUE;room-id=1468479097;subscriber=0;system-msg=;'
        'tmi-sent-ts=1785666523751;user-id=1468479097;user-type=;vip=0 '
        ':tmi.twitch.tv USERNOTICE #test :hello world',
      );

      expect(systemMessages, hasLength(1));
      expect(systemMessages[0].$1, 'test');
      expect(systemMessages[0].$2, 'Announcement');
      expect(systemMessages[0].$3, const Color(0xFF1F69FF));

      // Child message rendered as a normal chat message on the same accent,
      // carrying the emotes parsed from the USERNOTICE line.
      final child = channelMessages['test']!.first;
      expect(child.isSystem, isFalse);
      expect(child.text, 'hello world');
      expect(child.login, 'ermugo2');
      expect(child.displayName, 'ermugo2');
      expect(child.color, '#0000FF');
      expect(child.userId, '1468479097');
      expect(child.messageId, 'abc');
      expect(child.systemAccent, const Color(0xFF1F69FF));
      expect(child.badges, hasLength(1));
      expect(child.badges!.single.setId, 'broadcaster');
      expect(child.emotePositions, isNotNull);
      expect(child.emotePositions!.single.emoteCode, 'hello');

      conn.dispose();
    });

    test('missing color falls back to PRIMARY', () async {
      final irc = _TestIrc();
      final systemMessages = <(String, String, Color?)>[];
      final channelMessages = <String, List<TwitchMessage>>{};
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        onReconnected: () {},
        channelMessages: channelMessages,
        onSystemMessage: (c, t, {Color? accent}) {
          systemMessages.add((c, t, accent));
        },
      );
      await conn.connect();
      irc.emitConnected();

      irc.handleLine(
        '@msg-id=announcement;login=mm2pl;display-name=Mm2PL;system-msg=;'
        ':tmi.twitch.tv USERNOTICE #test :hi',
      );

      expect(systemMessages.single.$2, 'Announcement');
      expect(systemMessages.single.$3, const Color(0xFF9146FF));
      expect(
        channelMessages['test']!.first.systemAccent,
        const Color(0xFF9146FF),
      );

      conn.dispose();
    });

    test('announcement without text renders only the label', () async {
      final irc = _TestIrc();
      final systemMessages = <(String, String, Color?)>[];
      final channelMessages = <String, List<TwitchMessage>>{};
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        onReconnected: () {},
        channelMessages: channelMessages,
        onSystemMessage: (c, t, {Color? accent}) {
          systemMessages.add((c, t, accent));
        },
      );
      await conn.connect();
      irc.emitConnected();

      irc.handleLine(
        '@msg-id=announcement;msg-param-color=ORANGE;login=mm2pl;'
        'display-name=Mm2PL;system-msg=;'
        ':tmi.twitch.tv USERNOTICE #test',
      );

      expect(systemMessages.single.$2, 'Announcement');
      expect(systemMessages.single.$3, const Color(0xFFFF6F00));
      expect(
        channelMessages['test'],
        isNull,
        reason: 'no child message without announcement text',
      );

      conn.dispose();
    });

    test(
      'resub notice stays a single system message with the purple accent',
      () async {
        final irc = _TestIrc();
        final systemMessages = <(String, String, Color?)>[];
        final channelMessages = <String, List<TwitchMessage>>{};
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          onReconnected: () {},
          channelMessages: channelMessages,
          onSystemMessage: (c, t, {Color? accent}) {
            systemMessages.add((c, t, accent));
          },
        );
        await conn.connect();
        irc.emitConnected();

        irc.handleLine(
          '@msg-id=resub;system-msg=ronni\\shas\\ssubscribed!;login=ronni;'
          'display-name=ronni;'
          ':tmi.twitch.tv USERNOTICE #test :Great stream!',
        );

        expect(systemMessages, hasLength(1));
        expect(systemMessages[0].$1, 'test');
        expect(systemMessages[0].$2, 'ronni has subscribed! "Great stream!"');
        expect(systemMessages[0].$3, const Color(0xFF9146FF));
        expect(
          channelMessages['test'],
          isNull,
          reason: 'non-announcements never produce a child message',
        );

        conn.dispose();
      },
    );

    test(
      'non-sub notices stay a single system message without accent',
      () async {
        final irc = _TestIrc();
        final systemMessages = <(String, String, Color?)>[];
        final channelMessages = <String, List<TwitchMessage>>{};
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          onReconnected: () {},
          channelMessages: channelMessages,
          onSystemMessage: (c, t, {Color? accent}) {
            systemMessages.add((c, t, accent));
          },
        );
        await conn.connect();
        irc.emitConnected();

        irc.handleLine(
          '@msg-id=raid;system-msg=ronni\\sis\\sraiding\\sxqc!;login=ronni;'
          'display-name=ronni;'
          ':tmi.twitch.tv USERNOTICE #test',
        );

        expect(systemMessages, hasLength(1));
        expect(systemMessages[0].$2, 'ronni is raiding xqc!');
        expect(systemMessages[0].$3, isNull);
        expect(
          channelMessages['test'],
          isNull,
          reason: 'non-announcements never produce a child message',
        );

        conn.dispose();
      },
    );
  });

  group('IRC channel clear', () {
    test('renders cleared message and marks all messages deleted', () async {
      final irc = _TestIrc();
      final systemMessages = <(String, String, Color?)>[];
      final channelMessages = <String, List<TwitchMessage>>{
        'test': [
          TwitchMessage(
            login: 'a',
            text: 'msg1',
            messageId: 'm1',
            channel: 'test',
          ),
          TwitchMessage(
            login: 'b',
            text: 'msg2',
            messageId: 'm2',
            channel: 'test',
          ),
        ],
      };
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        onReconnected: () {},
        channelMessages: channelMessages,
        onSystemMessage: (c, t, {Color? accent}) {
          systemMessages.add((c, t, accent));
        },
      );
      await conn.connect();
      irc.emitConnected();

      irc.handleLine(':tmi.twitch.tv CLEARCHAT #test');

      expect(systemMessages, hasLength(1));
      expect(systemMessages[0].$2, 'Chat was cleared.');
      expect(channelMessages['test']![0].deleted, isTrue);
      expect(channelMessages['test']![1].deleted, isTrue);

      conn.dispose();
    });

    test('ban CLEARCHAT does not trigger the clear path', () async {
      final irc = _TestIrc();
      final systemMessages = <(String, String, Color?)>[];
      final channelMessages = <String, List<TwitchMessage>>{
        'test': [
          TwitchMessage(
            login: 'forsen',
            text: 'msg1',
            messageId: 'm1',
            channel: 'test',
          ),
        ],
      };
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        onReconnected: () {},
        channelMessages: channelMessages,
        onSystemMessage: (c, t, {Color? accent}) {
          systemMessages.add((c, t, accent));
        },
      );
      await conn.connect();
      irc.emitConnected();

      irc.handleLine(':tmi.twitch.tv CLEARCHAT #test :forsen');
      await Future<void>.delayed(Duration.zero);

      expect(systemMessages.single.$2, 'forsen was banned.');
      expect(
        channelMessages['test']!.single.deleted,
        isTrue,
        reason: 'the banned user\'s message is deleted, not the whole chat',
      );

      conn.dispose();
    });
  });

  group('ROOMSTATE splash', () {
    test('updates the chat status splash and merges partial updates', () async {
      final irc = _TestIrc();
      final chatStatus = <String, String>{};
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        onReconnected: () {},
        chatStatus: chatStatus,
      );
      await conn.connect();
      irc.emitConnected();

      irc.handleLine(
        '@emote-only=1;followers-only=30;r9k=1;room-id=1;slow=10;subs-only=0 '
        ':tmi.twitch.tv ROOMSTATE #test',
      );
      expect(
        chatStatus['test'],
        'Slow (10s) · Followers-only (30m) · Emote-only · Unique chat',
      );

      // Partial update: only slow mode changed.
      irc.handleLine('@room-id=1;slow=0 :tmi.twitch.tv ROOMSTATE #test');
      expect(
        chatStatus['test'],
        'Followers-only (30m) · Emote-only · Unique chat',
      );

      conn.dispose();
    });
  });

  group('reconnectIfNecessary', () {
    test('does not reconnect a healthy connection', () {
      fakeAsync((async) {
        final irc = _TestIrc();
        irc.alive = true;
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          onReconnected: () {},
          currentUserLogin: 'testuser',
        );

        irc.connect(username: 'testuser', accessToken: 'token');
        irc.emitConnected();
        conn.reconnectIfNecessary();
        async.flushMicrotasks();
        expect(
          irc.connectCalls,
          1,
          reason: 'healthy socket must not be reconnected on resume',
        );

        conn.dispose();
      });
    });

    test('forces a reconnect when checkAlive fails (zombie socket)', () {
      fakeAsync((async) {
        final irc = _TestIrc();
        irc.alive = false;
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          onReconnected: () {},
          currentUserLogin: 'testuser',
        );

        irc.connect(username: 'testuser', accessToken: 'token');
        irc.emitConnected();
        conn.reconnectIfNecessary();
        async.flushMicrotasks();
        // forceReconnect schedules a retry; it must not open a socket yet.
        expect(irc.openAttempts, 0);
        async.elapse(const Duration(milliseconds: 1250));
        expect(
          irc.openAttempts,
          1,
          reason: 'unhealthy socket must be replaced after resume',
        );

        conn.dispose();
      });
    });

    test('connects when the socket is missing entirely', () {
      fakeAsync((async) {
        final irc = _TestIrc();
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          onReconnected: () {},
          currentUserLogin: 'testuser',
        );

        conn.reconnectIfNecessary();
        async.flushMicrotasks();
        expect(irc.connectCalls, 1);

        conn.dispose();
      });
    });

    test('reconnects a stale EventSub session on resume', () {
      fakeAsync((async) {
        final irc = _TestIrc();
        irc.alive = true;
        final eventSub = _StaleEventSub(stale: true);
        final conn = _makeReconnectConn(
          eventSub: eventSub,
          irc: irc,
          onReconnected: () {},
          currentUserLogin: 'testuser',
        );

        irc.connect(username: 'testuser', accessToken: 'token');
        irc.emitConnected();
        conn.reconnectIfNecessary();
        async.flushMicrotasks();
        expect(
          eventSub.forceCalls,
          1,
          reason: 'a zombie EventSub session must be torn down on resume',
        );

        conn.dispose();
      });
    });

    test('does not reconnect a healthy EventSub session on resume', () {
      fakeAsync((async) {
        final irc = _TestIrc();
        irc.alive = true;
        final eventSub = _StaleEventSub(stale: false);
        final conn = _makeReconnectConn(
          eventSub: eventSub,
          irc: irc,
          onReconnected: () {},
          currentUserLogin: 'testuser',
        );

        irc.connect(username: 'testuser', accessToken: 'token');
        irc.emitConnected();
        conn.reconnectIfNecessary();
        async.flushMicrotasks();
        expect(
          eventSub.forceCalls,
          0,
          reason: 'a live session must not be torn down on every resume',
        );

        conn.dispose();
      });
    });
  });

  group('broadcaster-only chat widgets', () {
    test('drops widget events without an active widget subscription', () async {
      final eventSub = _NoopEventSub();
      eventSub.setChannelMapping('broadcaster1', 'test');
      final hypeTrains = <HypeTrainEvent>[];
      final conn = _makeReconnectConn(
        eventSub: eventSub,
        irc: _TestIrc(),
        onReconnected: () {},
        onHypeTrain: hypeTrains.add,
      );
      await conn.connect();

      eventSub.handleRawMessage(<String, dynamic>{
        'metadata': <String, dynamic>{
          'message_type': 'notification',
          'subscription_type': 'channel.hype_train.begin',
        },
        'payload': <String, dynamic>{
          'subscription': <String, dynamic>{
            'condition': <String, dynamic>{
              'broadcaster_user_id': 'broadcaster1',
            },
          },
          'event': <String, dynamic>{'level': 1, 'progress': 0, 'total': 100},
        },
      });

      expect(
        hypeTrains,
        isEmpty,
        reason: 'a non-broadcaster viewer must never surface widget events',
      );
      conn.dispose();
    });
  });

  group('IRC emote-sets', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('forwards GLOBALUSERSTATE emote-sets to onUserEmoteSets', () async {
      final received = <(String?, List<String>)>[];
      final irc = _TestIrc();
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        onReconnected: () {},
        onUserEmoteSets: (channel, ids) async => received.add((channel, ids)),
      );
      await conn.connect();
      await flush();

      irc.handleLine('@emote-sets=0,123456789 :tmi.twitch.tv GLOBALUSERSTATE');
      await flush();

      expect(received, hasLength(1));
      expect(received.single.$1, isNull);
      expect(received.single.$2, <String>['0', '123456789']);
      conn.dispose();
    });

    test('does not call onUserEmoteSets when tag is missing', () async {
      var called = false;
      final irc = _TestIrc();
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        onReconnected: () {},
        onUserEmoteSets: (_, _) async => called = true,
      );
      await conn.connect();
      await flush();

      irc.handleLine('@badges=staff/1 :tmi.twitch.tv GLOBALUSERSTATE');
      await flush();

      expect(called, isFalse);
      conn.dispose();
    });
  });

  group('message emote precache', () {
    test('nothing tier skips precaching entirely', () {
      final emoteManager = _SpyEmoteManager(tier: EmoteFetchTier.nothing);
      final msgs = <String, List<TwitchMessage>>{'test': []};
      final conn = _makeConn(
        channelMessages: msgs,
        maxMessages: 100,
        emoteManager: emoteManager,
      );

      conn.precacheMessageEmotes(_msg('m1', 'E1 hello'), 'test');

      expect(
        emoteManager.enqueueSeenCalls,
        0,
        reason: 'nothing tier must never precache or touch usage',
      );
      conn.dispose();
    });

    test('live messages feed the usage registry through emote positions', () {
      final emoteManager = _SpyEmoteManager(tier: EmoteFetchTier.high);
      final msgs = <String, List<TwitchMessage>>{'test': []};
      final conn = _makeConn(
        channelMessages: msgs,
        maxMessages: 100,
        emoteManager: emoteManager,
      );

      final msg = TwitchMessage(
        login: 'user',
        text: 'E1 E1',
        messageId: 'm1',
        channel: 'test',
        emotePositions: const [
          EmotePosition(
            emoteId: 'e1',
            startIndex: 0,
            endIndex: 2,
            emoteCode: 'E1',
          ),
          EmotePosition(
            emoteId: 'e1',
            startIndex: 3,
            endIndex: 5,
            emoteCode: 'E1',
          ),
        ],
      );
      conn.onMessage(msg);

      expect(emoteManager.viewedIds, ['e1', 'e1']);
      conn.dispose();
    });

    test('history messages do not feed the usage registry', () {
      final emoteManager = _SpyEmoteManager(tier: EmoteFetchTier.high);
      final msgs = <String, List<TwitchMessage>>{'test': []};
      final conn = _makeConn(
        channelMessages: msgs,
        maxMessages: 100,
        emoteManager: emoteManager,
      );

      conn.onMessage(
        TwitchMessage(
          login: 'user',
          text: 'E1',
          messageId: 'm1',
          channel: 'test',
          isHistory: true,
          emotePositions: const [
            EmotePosition(
              emoteId: 'e1',
              startIndex: 0,
              endIndex: 2,
              emoteCode: 'E1',
            ),
          ],
        ),
      );

      expect(emoteManager.viewedIds, isEmpty);
      conn.dispose();
    });
  });
}
