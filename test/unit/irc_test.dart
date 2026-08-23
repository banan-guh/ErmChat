import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:ermchat/services/connectivity_service.dart';
import 'package:ermchat/services/twitch_irc.dart';
import '../helpers/fake_web_socket.dart';
import 'package:ermchat/models/twitch_message.dart';
import 'package:ermchat/services/twitch_eventsub.dart';
import 'package:ermchat/services/seven_tv_event_client.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:ermchat/models/emote_fetch_tier.dart';
import 'package:ermchat/models/generic_emote.dart';
import 'package:ermchat/services/chat_connection_manager.dart';
import 'package:ermchat/services/chat_store.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/services/user_store.dart';
import 'package:http/testing.dart' as http_testing;

class _TestService extends IrcService {
  _TestService(this.channels, {this.onOpen, super.connectivityService});

  final List<FakeWebSocketChannel> channels;
  final void Function()? onOpen;
  int openAttempts = 0;

  @override
  Future<WebSocketChannel> openChannel() async {
    openAttempts++;
    onOpen?.call();
    final idx = (openAttempts - 1).clamp(0, channels.length - 1);
    return channels[idx];
  }
}

Map<String, dynamic> _welcome({String id = 'session-test', int timeout = 10}) =>
    {
      'metadata': {'message_type': 'session_welcome'},
      'payload': {
        'session': {'id': id, 'keepalive_timeout_seconds': timeout},
      },
    };

Map<String, dynamic> _hello({int heartbeatInterval = 30000}) => {
  'op': 1,
  'd': {'heartbeat_interval': heartbeatInterval},
};

Map<String, dynamic> _emoteSetUpdate({
  required String emoteSetId,
  List<Map<String, dynamic>>? pushed,
  List<Map<String, dynamic>>? pulled,
  List<Map<String, dynamic>>? updated,
  String? actor,
}) => {
  'op': 0,
  'd': {
    'type': 'emote_set.update',
    // ignore: use_null_aware_elements
    'body': <String, dynamic>{
      'id': emoteSetId,
      'pushed': ?pushed,
      'pulled': ?pulled,
      'updated': ?updated,
      if (actor != null) 'actor': {'display_name': actor},
    },
  },
};

Map<String, dynamic> _userUpdate({
  required String userId,
  required String newEmoteSetId,
  required String oldEmoteSetId,
  int connectionIndex = 0,
  String? actor,
}) => {
  'op': 0,
  'd': {
    'type': 'user.update',
    'id': userId,
    'body': {
      'connection_index': connectionIndex,
      'change_map': {
        'fields': [
          {
            'key': 'emote_set_id',
            'value': newEmoteSetId,
            'old_value': oldEmoteSetId,
          },
        ],
      },
      if (actor != null) 'actor': {'display_name': actor},
    },
  },
};

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

/// Modern Twitch-style reply: carries the explicit thread-root tag the store
/// indexes on, in addition to the direct-parent reference.
TwitchMessage _taggedMsg(
  String id,
  String text, {
  required String rootId,
  String? parentId,
}) => TwitchMessage(
  login: 'user',
  text: text,
  messageId: id,
  channel: 'test',
  replyToParentId: parentId ?? rootId,
  replyToUser: 'parent',
  replyThreadRootId: rootId,
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

class _TestIrcRead extends IrcReadService {
  final _statusCtrl = StreamController<IrcConnectionStatus>.broadcast(
    sync: true,
  );

  @override
  Future<void> connect({
    required String username,
    required String accessToken,
  }) async {}

  @override
  Stream<IrcConnectionStatus> get onStatus => _statusCtrl.stream;

  void emitConnected() {
    _statusCtrl.add(IrcConnectionStatus.connected);
  }

  void emitDisconnected() {
    _statusCtrl.add(IrcConnectionStatus.disconnected);
  }

  @override
  void dispose() {
    _statusCtrl.close();
    super.dispose();
  }
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
      store: ChatStore(
        channels: ['test'],
        channelMessages: channelMessages,
        messageKeys: {},
        chatStatus: {},
        channelsWithUnread: {},
        channelsWithUnreadMentions: {},
        unreadMentionsPerChannel: {},
        historyLoaded: {},
        channelsEmotesResolved: {},
        channelUserIds: {},
        lastSentWireText: {},
      ),
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
  IrcReadService? ircRead,
  List<String>? channels,
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
      ircRead: ircRead ?? _NoopIrcRead(),
      emoteManager: EmoteManager(),
      badgeService: TwitchBadgeService(),
      userStore: UserStore(),
      twitchAuth: auth,
      store: ChatStore(
        channels: channels ?? [],
        channelMessages: channelMessages ?? {},
        messageKeys: {},
        chatStatus: chatStatus ?? {},
        channelsWithUnread: {},
        channelsWithUnreadMentions: {},
        unreadMentionsPerChannel: {},
        historyLoaded: {},
        channelsEmotesResolved: {},
        channelUserIds: {},
        lastSentWireText: {},
      ),
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
  group('reconnect backoff', () {
    test('delays grow 1s, 2s, 4s, then cap at 8s and never give up', () {
      fakeAsync((async) {
        final times = <Duration>[];
        final service = _TestService(
          List.generate(12, (_) => FakeWebSocketChannel(failReady: true)),
          onOpen: () => times.add(async.elapsed),
        );
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();
        expect(times, hasLength(1));

        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(times.length, greaterThanOrEqualTo(6), reason: 'keeps retrying');

        final gaps = [
          for (var i = 1; i < times.length; i++) times[i] - times[i - 1],
        ];
        // 1s, 2s, 4s, then 8s (all with ±25% jitter).
        expect(gaps[0].inMilliseconds, inInclusiveRange(700, 1300));
        expect(gaps[1].inMilliseconds, inInclusiveRange(1400, 2600));
        expect(gaps[2].inMilliseconds, inInclusiveRange(2800, 5200));
        expect(gaps[3].inMilliseconds, inInclusiveRange(5600, 10400));
        expect(
          gaps[4].inMilliseconds,
          inInclusiveRange(5600, 10400),
          reason: 'capped at 8s',
        );

        // Never gives up: keeps retrying long after the old 8-attempt cap.
        async.elapse(const Duration(seconds: 60));
        expect(times.length, greaterThan(8));

        service.dispose();
      });
    });

    test('success resets the counter (next failure retries at ~1s)', () {
      fakeAsync((async) {
        final service = _TestService([
          FakeWebSocketChannel(failReady: true),
          FakeWebSocketChannel(failReady: true),
          FakeWebSocketChannel(failReady: true),
          FakeWebSocketChannel(),
        ]);
        final statuses = <IrcConnectionStatus>[];
        service.onStatus.listen(statuses.add);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        async.elapse(const Duration(milliseconds: 1250));
        expect(service.openAttempts, 2);
        async.elapse(const Duration(milliseconds: 2600));
        expect(service.openAttempts, 3);
        // 4th attempt succeeds.
        async.elapse(const Duration(milliseconds: 5200));
        expect(service.openAttempts, 4);
        expect(statuses, contains(IrcConnectionStatus.connected));

        // Kill the healthy socket: next retry is ~1s, not 8s.
        final channel = service.channels.last;
        channel.failNow();
        async.flushMicrotasks();
        expect(statuses, contains(IrcConnectionStatus.disconnected));
        async.elapse(const Duration(milliseconds: 1250));
        expect(service.openAttempts, 5);

        service.dispose();
        channel.dispose();
      });
    });

    test('a failed connect does not leave a zombie socket behind', () {
      fakeAsync((async) {
        final service = _TestService([FakeWebSocketChannel(failReady: true)]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();
        expect(
          service.isConnected,
          isFalse,
          reason: 'failed handshake must not look connected',
        );

        async.elapse(const Duration(milliseconds: 1250));
        expect(
          service.openAttempts,
          2,
          reason: 'reconnect must not bail on the stale socket',
        );

        service.dispose();
      });
    });
  });

  group('PING/PONG keepalive', () {
    test('sends keepalive PING and reconnects when no PONG arrives', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        final statuses = <IrcConnectionStatus>[];
        service.onStatus.listen(statuses.add);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();
        expect(service.openAttempts, 1);

        // Tick 1 (~60s): sends a keepalive PING.
        async.elapse(const Duration(seconds: 61));
        expect(channel.sent, contains('PING :keepalive'));
        expect(statuses, isNot(contains(IrcConnectionStatus.disconnected)));

        // The dedicated PONG timer (30s) reconnects without waiting for the
        // next keepalive tick.
        async.elapse(const Duration(seconds: 31));
        expect(statuses, contains(IrcConnectionStatus.disconnected));
        async.elapse(const Duration(milliseconds: 1250));
        expect(service.openAttempts, 2);

        service.dispose();
        channel.dispose();
      });
    });

    test('PONG within the pong window keeps the connection alive', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        final statuses = <IrcConnectionStatus>[];
        service.onStatus.listen(statuses.add);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 61));
        expect(channel.sent, contains('PING :keepalive'));

        channel.push('PONG :keepalive');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 31));
        expect(statuses, isNot(contains(IrcConnectionStatus.disconnected)));

        service.dispose();
        channel.dispose();
      });
    });

    test('incoming PONG clears awaitingPong', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        service.awaitingPong = true;
        channel.push('PONG :tmi.twitch.tv');
        async.flushMicrotasks();
        expect(service.awaitingPong, isFalse);

        service.dispose();
        channel.dispose();
      });
    });
  });

  group('RECONNECT command', () {
    test('reconnects when the server asks for it', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        final statuses = <IrcConnectionStatus>[];
        service.onStatus.listen(statuses.add);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();
        expect(service.openAttempts, 1);

        service.handleLine(':tmi.twitch.tv RECONNECT');
        async.flushMicrotasks();
        expect(statuses, contains(IrcConnectionStatus.disconnected));
        async.elapse(const Duration(milliseconds: 1250));
        expect(service.openAttempts, 2);

        service.dispose();
        channel.dispose();
      });
    });
  });

  group('checkAlive', () {
    test('returns true when a PONG echoes the probe token', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        bool? result;
        service.checkAlive().then((value) => result = value);
        async.flushMicrotasks();
        expect(channel.sent, contains('PING :alive-check-0'));
        expect(result, isNull);

        channel.push(':tmi.twitch.tv PONG tmi.twitch.tv :alive-check-0');
        async.flushMicrotasks();
        expect(result, isTrue);

        service.dispose();
        channel.dispose();
      });
    });

    test('a stale keepalive PONG does not satisfy an in-flight probe', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        bool? result;
        service.checkAlive().then((value) => result = value);
        async.flushMicrotasks();

        // A PONG left over from a keepalive PING (or Twitch's bare-ping
        // answer) must not be mistaken for a response to the probe.
        channel.push('PONG :tmi.twitch.tv');
        async.flushMicrotasks();
        expect(result, isNull);

        channel.push(':tmi.twitch.tv PONG tmi.twitch.tv :alive-check-0');
        async.flushMicrotasks();
        expect(result, isTrue);

        service.dispose();
        channel.dispose();
      });
    });

    test('returns false on timeout when no PONG arrives', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        bool? result;
        service.checkAlive().then((value) => result = value);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();
        expect(result, isFalse);

        service.dispose();
        channel.dispose();
      });
    });

    test('returns false when there is no socket', () async {
      final service = _TestService([FakeWebSocketChannel()]);
      expect(await service.checkAlive(), isFalse);
      service.dispose();
    });
  });

  group('forceReconnect', () {
    test('closes the zombie socket and reconnects immediately', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        final statuses = <IrcConnectionStatus>[];
        service.onStatus.listen(statuses.add);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();
        expect(service.openAttempts, 1);

        service.forceReconnect();
        async.flushMicrotasks();
        expect(statuses, contains(IrcConnectionStatus.disconnected));
        // The loop restarts right away (no backoff) on a fresh generation.
        expect(service.openAttempts, 2);
        expect(service.isConnected, isTrue);

        service.dispose();
        channel.dispose();
      });
    });
  });

  group('disconnect status clears the socket first', () {
    // The type bar hint renders the "connected" state whenever isConnected is
    // true at rebuild time. Every disconnect path must therefore null the
    // socket BEFORE emitting `disconnected`, or the hint flickers to
    // "connected" for a frame during a disconnect (disconnect -> connect ->
    // disconnect).
    void expectDisconnectedWithSocketCleared(
      void Function(FakeAsync async, _TestService service) trigger,
    ) {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        final connectedAtDisconnect = <bool>[];
        service.onStatus.listen((s) {
          if (s == IrcConnectionStatus.disconnected) {
            connectedAtDisconnect.add(service.isConnected);
          }
        });
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        trigger(async, service);
        async.flushMicrotasks();

        expect(connectedAtDisconnect, isNotEmpty);
        expect(
          connectedAtDisconnect,
          everyElement(isFalse),
          reason: 'type bar must not read "connected" when disconnect fires',
        );

        service.dispose();
        channel.dispose();
      });
    }

    test('stream error', () {
      expectDisconnectedWithSocketCleared((_, service) {
        service.channels.last.failNow();
      });
    });

    test('RECONNECT command', () {
      expectDisconnectedWithSocketCleared((_, service) {
        service.handleLine(':tmi.twitch.tv RECONNECT');
      });
    });

    test('PONG timeout', () {
      expectDisconnectedWithSocketCleared((async, _) {
        async.elapse(const Duration(seconds: 61));
        async.elapse(const Duration(seconds: 31));
      });
    });

    test('forceReconnect', () {
      expectDisconnectedWithSocketCleared((_, service) {
        service.forceReconnect();
      });
    });
  });

  group('handshake does not report connected early', () {
    test('isConnected stays false while the handshake is pending', () {
      fakeAsync((async) {
        final ready = Completer<void>();
        final channel = FakeWebSocketChannel(readyCompleter: ready);
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        // openChannel resolved and assigned nothing yet: the handshake is
        // still in flight, so the socket must not look connected yet.
        expect(
          service.isConnected,
          isFalse,
          reason: 'type bar hint must not flip to connected mid-handshake',
        );

        ready.complete();
        async.flushMicrotasks();
        expect(service.isConnected, isTrue);

        service.dispose();
        channel.dispose();
      });
    });

    test('a hung handshake times out, releases the lock and retries', () {
      fakeAsync((async) {
        final ready = Completer<void>();
        final hanging = FakeWebSocketChannel(readyCompleter: ready);
        final service = _TestService([hanging, FakeWebSocketChannel()]);
        final statuses = <IrcConnectionStatus>[];
        service.onStatus.listen(statuses.add);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();
        expect(service.openAttempts, 1);

        // The handshake never completes; the 10s connect timeout fails the
        // attempt cleanly instead of hanging `_connecting` forever.
        async.elapse(const Duration(seconds: 11));
        expect(statuses, contains(IrcConnectionStatus.disconnected));

        async.elapse(const Duration(milliseconds: 1250));
        expect(service.openAttempts, 2);
        expect(
          service.isConnected,
          isTrue,
          reason: 'the next attempt connects because the lock was released',
        );

        service.dispose();
        hanging.dispose();
      });
    });
  });

  group('JOIN rate limiting', () {
    test('JOINs are batched at the tick rate, not fired in a burst', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        // 25 channels exceed the per-tick burst cap.
        for (var i = 0; i < 25; i++) {
          service.join('c$i');
        }
        async.flushMicrotasks();

        List<String> joins() =>
            channel.sent.where((l) => l.startsWith('JOIN')).toList();

        // First flush sends up to the burst cap immediately...
        expect(joins(), hasLength(20));
        // ...the rest wait for the next tick.
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(joins(), hasLength(25));

        service.dispose();
        channel.dispose();
      });
    });

    test('a duplicate join is not queued twice', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        service.join('abc');
        service.join('abc');
        async.flushMicrotasks();

        final joins = channel.sent.where((l) => l == 'JOIN #abc').toList();
        expect(joins, hasLength(1));

        service.dispose();
        channel.dispose();
      });
    });

    test('JOINs queued before connect are sent once the socket opens', () {
      // Regression: channels are joined before/around connect() (socket still
      // coming up), which pre-loads the queue but cannot flush yet. The
      // dedup guard must not strand them, or the channel is never joined and
      // the read socket stays dead on initial connect.
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.join('awootismm');
        service.join('ermugo2');
        async.flushMicrotasks();
        expect(channel.sent, isEmpty, reason: 'nothing sent before connect');

        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        expect(channel.sent, contains('JOIN #awootismm'));
        expect(channel.sent, contains('JOIN #ermugo2'));

        service.dispose();
        channel.dispose();
      });
    });
  });

  group('ROOMSTATE rejoin sweep', () {
    test('re-sends unconfirmed JOINs and stops once confirmed', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel();
        final service = _TestService([channel]);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        service.join('abc');
        async.flushMicrotasks();
        List<String> joins() =>
            channel.sent.where((l) => l == 'JOIN #abc').toList();
        expect(joins(), hasLength(1));

        // No ROOMSTATE echoed: the sweep re-JOINs after the confirm window.
        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();
        expect(joins(), hasLength(2));

        // ROOMSTATE confirms the JOIN: the sweep stops re-sending.
        channel.push('@room-id=1 :tmi.twitch.tv ROOMSTATE #abc');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 22));
        async.flushMicrotasks();
        expect(
          joins(),
          hasLength(2),
          reason: 'a confirmed channel is never re-sent',
        );

        service.dispose();
        channel.dispose();
      });
    });
  });

  group('JOIN failures', () {
    test('suspended notice emits once and stops all re-JOINs', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel(autoPong: true);
        final service = _TestService([channel]);
        final failures = <IrcJoinFailureEvent>[];
        service.onJoinFailed.listen(failures.add);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        service.join('dead');
        async.flushMicrotasks();
        List<String> joins() =>
            channel.sent.where((l) => l == 'JOIN #dead').toList();
        expect(joins(), hasLength(1));

        channel.push(
          '@msg-id=msg_channel_suspended :tmi.twitch.tv NOTICE #dead '
          ':This channel has been suspended or closed.',
        );
        async.flushMicrotasks();
        expect(failures, hasLength(1));
        expect(failures.single.channel, 'dead');
        expect(failures.single.reason, JoinFailureReason.suspended);

        // A repeated refusal must not re-emit...
        channel.push(
          '@msg-id=msg_channel_suspended :tmi.twitch.tv NOTICE #dead '
          ':This channel has been suspended or closed.',
        );
        async.flushMicrotasks();
        expect(
          failures,
          hasLength(1),
          reason: 'one refusal per channel per socket',
        );

        // ...and neither the sweep nor the slow retry re-sends a refused
        // JOIN: every retry would only repeat the notice.
        async.elapse(const Duration(seconds: 200));
        expect(joins(), hasLength(1));

        service.dispose();
        channel.dispose();
      });
    });

    test('unconfirmed JOINs surface after the sweep gives up, then retry', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel(autoPong: true);
        final service = _TestService([channel]);
        final failures = <IrcJoinFailureEvent>[];
        service.onJoinFailed.listen(failures.add);
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        service.join('ghost');
        async.flushMicrotasks();
        List<String> joins() =>
            channel.sent.where((l) => l == 'JOIN #ghost').toList();

        // Fast sweep: 4 re-JOIN rounds (t=10s..40s), no failure yet.
        async.elapse(const Duration(seconds: 45));
        expect(joins(), hasLength(5));
        expect(failures, isEmpty, reason: 'still inside the fast sweep');

        // Round 5 (t=50s) gives up and reports instead of going silent.
        async.elapse(const Duration(seconds: 6));
        expect(failures, hasLength(1));
        expect(failures.single.channel, 'ghost');
        expect(failures.single.reason, JoinFailureReason.noResponse);

        // The slow retry probes through the rate-limited JOIN queue (first
        // tick t=110s), five attempts in total.
        async.elapse(const Duration(seconds: 60)); // t=111
        expect(joins(), hasLength(6));

        async.elapse(const Duration(seconds: 299)); // t=410: cap tick
        expect(joins(), hasLength(10));
        expect(failures, hasLength(1), reason: 'the failure is reported once');

        // Capped out: goes silent until a fresh socket restarts the cycle.
        async.elapse(const Duration(minutes: 10));
        expect(joins(), hasLength(10));

        service.dispose();
        channel.dispose();
      });
    });

    test('slow retry stops early once ROOMSTATE confirms', () {
      fakeAsync((async) {
        final channel = FakeWebSocketChannel(autoPong: true);
        final service = _TestService([channel]);
        service.onJoinFailed.listen((_) {});
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        service.join('ghost');
        async.flushMicrotasks();
        List<String> joins() =>
            channel.sent.where((l) => l == 'JOIN #ghost').toList();

        // Exhaust the fast sweep (failure at t=50s), first slow retry at
        // t=110s.
        async.elapse(const Duration(seconds: 111));
        expect(joins(), hasLength(6));

        // Confirmation ends the probing early.
        channel.push('@room-id=1 :tmi.twitch.tv ROOMSTATE #ghost');
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 20));
        expect(
          joins(),
          hasLength(6),
          reason: 'a confirmed channel is never retried',
        );

        service.dispose();
        channel.dispose();
      });
    });
  });

  group('connectivity accelerator', () {
    test('coming back online wakes the backoff sleep early', () {
      fakeAsync((async) {
        final conn = ConnectivityService();
        conn.debugSetResults(const [ConnectivityResult.none]);
        final times = <Duration>[];
        final service = _TestService(
          [FakeWebSocketChannel(failReady: true)],
          connectivityService: conn,
          onOpen: () => times.add(async.elapsed),
        );
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();
        expect(times, hasLength(1));

        // Still offline: the next attempt waits on the backoff timer.
        async.elapse(const Duration(milliseconds: 200));
        expect(times, hasLength(1));

        // Back online: the sleep is woken immediately and the retry fires now.
        conn.debugSetResults(const [ConnectivityResult.wifi]);
        async.flushMicrotasks();
        expect(times, hasLength(2));
        expect(
          times[1],
          lessThan(const Duration(milliseconds: 900)),
          reason: 'the backoff wait must be shortened, not run out',
        );

        service.dispose();
        conn.dispose();
      });
    });

    test('an offline blip does not stop the retry loop (no gate)', () {
      fakeAsync((async) {
        final conn = ConnectivityService();
        conn.debugSetResults(const [ConnectivityResult.none]);
        final times = <Duration>[];
        final service = _TestService(
          [FakeWebSocketChannel(failReady: true)],
          connectivityService: conn,
          onOpen: () => times.add(async.elapsed),
        );
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        // Even fully offline, the loop keeps retrying on its own schedule.
        async.elapse(const Duration(seconds: 30));
        expect(times.length, greaterThanOrEqualTo(4));

        service.dispose();
        conn.dispose();
      });
    });
  });

  late IrcService service;

  setUp(() {
    service = IrcService();
  });

  tearDown(() {
    service.dispose();
  });

  group('channel tracking', () {
    test('join does not crash when not connected', () {
      expect(() => service.join('testchannel'), returnsNormally);
    });

    test('part does not crash when not connected', () {
      expect(() => service.part('testchannel'), returnsNormally);
    });
  });

  group('CLEARMSG', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('emits delete event with messageId, user, and deleted text', () async {
      final events = <IrcMessageDeletedEvent>[];
      service.onMessageDeleted.listen(events.add);

      service.handleLine(
        '@login=forsen;target-msg-id=abc-123 :tmi.twitch.tv CLEARMSG #xqc :bad message',
      );
      await flush();

      expect(events, hasLength(1));
      expect(events[0].channel, 'xqc');
      expect(events[0].messageId, 'abc-123');
      expect(events[0].user, 'forsen');
      expect(events[0].deletedMessageText, 'bad message');
    });

    test('ignores CLEARMSG without target-msg-id', () async {
      final events = <IrcMessageDeletedEvent>[];
      service.onMessageDeleted.listen(events.add);

      service.handleLine(
        '@login=forsen :tmi.twitch.tv CLEARMSG #xqc :bad message',
      );
      await flush();

      expect(events, isEmpty);
    });

    test('defaults user to unknown when login tag missing', () async {
      final events = <IrcMessageDeletedEvent>[];
      service.onMessageDeleted.listen(events.add);

      service.handleLine(
        '@target-msg-id=xyz :tmi.twitch.tv CLEARMSG #xqc :deleted',
      );
      await flush();

      expect(events, hasLength(1));
      expect(events[0].user, 'unknown');
    });
  });

  group('CLEARCHAT', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('emits ban event for permanent ban', () async {
      final events = <IrcBanEvent>[];
      service.onBan.listen(events.add);

      service.handleLine(':tmi.twitch.tv CLEARCHAT #xqc :forsen');
      await flush();

      expect(events, hasLength(1));
      expect(events[0].channel, 'xqc');
      expect(events[0].user, 'forsen');
      expect(events[0].isTimeout, isFalse);
      expect(events[0].duration, isNull);
    });

    test('emits timeout event with duration', () async {
      final events = <IrcBanEvent>[];
      service.onBan.listen(events.add);

      service.handleLine(
        '@ban-duration=300;target-user-id=12345 :tmi.twitch.tv CLEARCHAT #xqc :forsen',
      );
      await flush();

      expect(events, hasLength(1));
      expect(events[0].user, 'forsen');
      expect(events[0].isTimeout, isTrue);
      expect(events[0].duration, 300);
      expect(events[0].userId, '12345');
    });

    test('emits channel clear for full room clear (no target user)', () async {
      final bans = <IrcBanEvent>[];
      final clears = <IrcChannelClearEvent>[];
      service.onBan.listen(bans.add);
      service.onChannelClear.listen(clears.add);

      service.handleLine(':tmi.twitch.tv CLEARCHAT #xqc');
      await flush();

      expect(bans, isEmpty);
      expect(clears, hasLength(1));
      expect(clears[0].channel, 'xqc');
    });
  });

  group('ROOMSTATE', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('parses full room state', () async {
      final states = <IrcRoomStateEvent>[];
      service.onRoomState.listen(states.add);

      service.handleLine(
        '@emote-only=0;followers-only=30;r9k=1;room-id=1;slow=10;subs-only=1 '
        ':tmi.twitch.tv ROOMSTATE #xqc',
      );
      await flush();

      expect(states, hasLength(1));
      expect(states[0].channel, 'xqc');
      expect(states[0].tags['slow'], '10');
      expect(states[0].tags['followers-only'], '30');
      expect(states[0].tags['emote-only'], '0');
      expect(states[0].tags['subs-only'], '1');
      expect(states[0].tags['r9k'], '1');
    });
  });

  group('USERSTATE / GLOBALUSERSTATE', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('lines are safely ignored', () async {
      var messageCount = 0;
      service.onMessage.listen((_) => messageCount++);

      service.handleLine(
        '@badges=moderator/1,vip/1;user-id=123 '
        ':tmi.twitch.tv USERSTATE #xqc',
      );
      service.handleLine('@badges=staff/1 :tmi.twitch.tv GLOBALUSERSTATE');
      await flush();

      expect(messageCount, 0);
    });

    test('emits emote-sets from GLOBALUSERSTATE without channel', () async {
      final sets = <(String?, List<String>)>[];
      service.onUserEmoteSets.listen(sets.add);

      service.handleLine(
        '@emote-sets=0,123456789,987654321 :tmi.twitch.tv GLOBALUSERSTATE',
      );
      await flush();

      expect(sets, hasLength(1));
      expect(sets.single.$1, isNull);
      expect(sets.single.$2, <String>['0', '123456789', '987654321']);
    });

    test('emits channel-scoped emote-sets from USERSTATE', () async {
      final sets = <(String?, List<String>)>[];
      service.onUserEmoteSets.listen(sets.add);

      service.handleLine(
        '@emote-sets=300374079,0 :tmi.twitch.tv USERSTATE #xqc',
      );
      await flush();

      expect(sets, hasLength(1));
      expect(sets.single.$1, 'xqc');
      expect(sets.single.$2, <String>['300374079', '0']);
    });

    test('does not emit when emote-sets tag is missing', () async {
      var emitted = false;
      service.onUserEmoteSets.listen((_) => emitted = true);

      service.handleLine('@badges=staff/1 :tmi.twitch.tv GLOBALUSERSTATE');
      await flush();

      expect(emitted, isFalse);
    });
  });

  group('USERNOTICE', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test(
      'routes to onUserNotice, not onNotice (dispatch regression)',
      () async {
        final notices = <IrcNoticeEvent>[];
        final userNotices = <UserNoticeEvent>[];
        service.onNotice.listen(notices.add);
        service.onUserNotice.listen(userNotices.add);

        service.handleLine(
          '@msg-id=announcement;msg-param-color=PRIMARY;login=mm2pl;'
          'display-name=Mm2PL;system-msg=;'
          ':tmi.twitch.tv USERNOTICE #xqc :test',
        );
        await flush();

        expect(
          notices,
          isEmpty,
          reason: 'USERNOTICE must not be swallowed by the NOTICE handler',
        );
        expect(userNotices, hasLength(1));
        expect(userNotices[0].msgId, 'announcement');
        expect(userNotices[0].text, 'test');
        expect(userNotices[0].announcementColor, 'PRIMARY');
      },
    );

    test('parses announcement emotes into emote positions', () async {
      final userNotices = <UserNoticeEvent>[];
      service.onUserNotice.listen(userNotices.add);

      service.handleLine(
        '@msg-id=announcement;msg-param-color=GREEN;login=mm2pl;'
        'display-name=Mm2PL;emotes=emotesv2_123:0-7;system-msg=;'
        ':tmi.twitch.tv USERNOTICE #xqc :PogChamp test',
      );
      await flush();

      expect(userNotices, hasLength(1));
      expect(userNotices[0].emotePositions, isNotNull);
      expect(userNotices[0].emotePositions!.single.emoteCode, 'PogChamp');
      expect(userNotices[0].emotePositions!.single.startIndex, 0);
      expect(userNotices[0].emotePositions!.single.endIndex, 8);
    });

    test('NOTICE still routes to onNotice', () async {
      final notices = <IrcNoticeEvent>[];
      service.onNotice.listen(notices.add);

      service.handleLine(
        '@msg-id=slow_on :tmi.twitch.tv NOTICE #xqc :This room is now in slow mode.',
      );
      await flush();

      expect(notices, hasLength(1));
      expect(notices[0].msgId, 'slow_on');
      expect(notices[0].message, contains('slow mode'));
    });
  });

  group('WHISPER', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('emits a TwitchMessage via onWhisper', () async {
      final whispers = <TwitchMessage>[];
      service.onWhisper.listen(whispers.add);

      service.handleLine(
        '@badges=;color=#FF0000;display-name=SomeUser;emotes=25:0-4;message-id=whisper-1;thread-id=abc;turbo=0;user-id=999;user-type= :someuser!someuser@someuser.tmi.twitch.tv WHISPER recipient :hey there',
      );
      await flush();

      expect(whispers, hasLength(1));
      final w = whispers[0];
      expect(w.login, 'someuser');
      expect(w.displayName, 'SomeUser');
      expect(w.text, 'hey there');
      expect(w.messageId, 'whisper-1');
      expect(w.channel, isNull);
      expect(w.color, '#FF0000');
    });
  });

  group('dispose', () {
    test('double dispose does not crash', () {
      service.dispose();
      expect(() => service.dispose(), returnsNormally);
    });
  });

  late EventSubService esService;

  setUp(() {
    esService = EventSubService();
  });

  tearDown(() {
    esService.dispose();
  });

  group('session lifecycle', () {
    test('handleRawMessage welcome sets sessionId and emits connected', () {
      final statuses = <EventSubStatus>[];
      esService.onStatus.listen(statuses.add);

      esService.handleRawMessage(_welcome(id: 'sess-lifecycle'));

      expect(esService.sessionId, 'sess-lifecycle');
      expect(statuses, contains(EventSubStatus.connected));
    });

    test('second welcome overwrites sessionId', () {
      esService.handleRawMessage(_welcome(id: 'sess-a'));
      expect(esService.sessionId, 'sess-a');

      esService.handleRawMessage(_welcome(id: 'sess-b'));
      expect(esService.sessionId, 'sess-b');
    });

    test('disconnect clears sessionId', () {
      esService.handleRawMessage(_welcome(id: 'sess-clear'));
      expect(esService.sessionId, 'sess-clear');

      esService.disconnect();
      expect(esService.sessionId, isNull);
    });

    test('welcome after disconnect sets sessionId again', () {
      esService.handleRawMessage(_welcome(id: 'first'));
      expect(esService.sessionId, 'first');

      esService.disconnect();
      expect(esService.sessionId, isNull);

      esService.handleRawMessage(_welcome(id: 'second'));
      expect(esService.sessionId, 'second');
    });
  });

  group('session completer', () {
    test('waitForSession completes after welcome', () async {
      final future = esService.waitForSession();

      esService.handleRawMessage(_welcome(id: 'sess-completer'));

      final result = await future;
      expect(result, 'sess-completer');
    });

    test('waitForSession returns immediately if session already set', () async {
      esService.emitConnected();

      final result = await esService.waitForSession();
      expect(result, 'test-session-id');
    });
  });

  late SevenTvEventClient client;
  late List<SevenTvEmoteUpdateEvent> emoteEvents;
  late List<SevenTvUserUpdate> userEvents;
  late List<SevenTvEventStatus> statusEvents;

  setUp(() {
    client = SevenTvEventClient();
    emoteEvents = [];
    userEvents = [];
    statusEvents = [];
    client.onEmoteSetUpdate.listen((e) => emoteEvents.add(e));
    client.onUserUpdate.listen((e) => userEvents.add(e));
    client.onStatus.listen((e) => statusEvents.add(e));
  });

  tearDown(() {
    client.dispose();
  });

  group('subscription queueing', () {
    test('subscribeEmoteSet does not trigger stream events before Hello', () {
      client.subscribeEmoteSet('set1');
      expect(emoteEvents, isEmpty);
      expect(userEvents, isEmpty);
    });

    test('Hello emits connected status', () {
      client.handleRawMessage(_hello());
      expect(statusEvents, hasLength(1));
      expect(statusEvents.first, SevenTvEventStatus.connected);
    });
  });

  group('dispatch events', () {
    setUp(() {
      client.handleRawMessage(_hello());
      emoteEvents.clear();
      userEvents.clear();
      statusEvents.clear();
    });

    test('emote_set.update parses added emote', () {
      client.handleRawMessage(
        _emoteSetUpdate(
          emoteSetId: 'set123',
          pushed: [
            {
              'value': {'id': 'abc', 'name': 'KEKW'},
            },
          ],
          actor: 'streamer',
        ),
      );

      expect(emoteEvents, hasLength(1));
      expect(emoteEvents[0].emoteSetId, 'set123');
      expect(emoteEvents[0].added, hasLength(1));
      expect(emoteEvents[0].added[0].id, 'abc');
      expect(emoteEvents[0].added[0].name, 'KEKW');
      expect(emoteEvents[0].added[0].raw['id'], 'abc');
      expect(emoteEvents[0].actor, 'streamer');
      expect(emoteEvents[0].removed, isEmpty);
      expect(emoteEvents[0].renamed, isEmpty);
    });

    test('emote_set.update parses removed emote', () {
      client.handleRawMessage(
        _emoteSetUpdate(
          emoteSetId: 'set123',
          pulled: [
            {
              'old_value': {'id': 'xyz', 'name': 'PogU'},
            },
          ],
        ),
      );

      expect(emoteEvents, hasLength(1));
      expect(emoteEvents[0].added, isEmpty);
      expect(emoteEvents[0].removed, hasLength(1));
      expect(emoteEvents[0].removed[0].id, 'xyz');
      expect(emoteEvents[0].removed[0].name, 'PogU');
      expect(emoteEvents[0].renamed, isEmpty);
    });

    test('emote_set.update parses renamed emote', () {
      client.handleRawMessage(
        _emoteSetUpdate(
          emoteSetId: 'set123',
          updated: [
            {
              'value': {'id': 'def', 'name': 'NewName'},
              'old_value': {'id': 'def', 'name': 'OldName'},
            },
          ],
        ),
      );

      expect(emoteEvents, hasLength(1));
      expect(emoteEvents[0].added, isEmpty);
      expect(emoteEvents[0].removed, isEmpty);
      expect(emoteEvents[0].renamed, hasLength(1));
      expect(emoteEvents[0].renamed[0].id, 'def');
      expect(emoteEvents[0].renamed[0].newName, 'NewName');
      expect(emoteEvents[0].renamed[0].oldName, 'OldName');
    });

    test('emote_set.update handles multiple changes at once', () {
      client.handleRawMessage(
        _emoteSetUpdate(
          emoteSetId: 'set123',
          pushed: [
            {
              'value': {'id': 'a1', 'name': 'Emote1'},
            },
            {
              'value': {'id': 'a2', 'name': 'Emote2'},
            },
          ],
          pulled: [
            {
              'old_value': {'id': 'r1', 'name': 'Removed1'},
            },
          ],
          updated: [
            {
              'value': {'id': 'u1', 'name': 'RenamedNew'},
              'old_value': {'id': 'u1', 'name': 'RenamedOld'},
            },
          ],
          actor: 'mod',
        ),
      );

      expect(emoteEvents, hasLength(1));
      final event = emoteEvents[0];
      expect(event.emoteSetId, 'set123');
      expect(event.added, hasLength(2));
      expect(event.removed, hasLength(1));
      expect(event.renamed, hasLength(1));
      expect(event.actor, 'mod');
    });

    test('emote_set.update handles empty body gracefully', () {
      client.handleRawMessage({
        'op': 0,
        'd': {'type': 'emote_set.update', 'id': 'set123'},
      });

      expect(emoteEvents, hasLength(1));
      expect(emoteEvents[0].added, isEmpty);
      expect(emoteEvents[0].removed, isEmpty);
      expect(emoteEvents[0].renamed, isEmpty);
      expect(emoteEvents[0].actor, isNull);
    });

    test('user.update parses emote set switch', () {
      client.handleRawMessage(
        _userUpdate(
          userId: 'user123',
          newEmoteSetId: 'newset',
          oldEmoteSetId: 'oldset',
          connectionIndex: 0,
          actor: 'streamer',
        ),
      );

      expect(userEvents, hasLength(1));
      expect(userEvents[0].userId, 'user123');
      expect(userEvents[0].newEmoteSetId, 'newset');
      expect(userEvents[0].oldEmoteSetId, 'oldset');
      expect(userEvents[0].connectionIndex, 0);
      expect(userEvents[0].actor, 'streamer');
    });

    test('user.update handles missing actor', () {
      client.handleRawMessage(
        _userUpdate(
          userId: 'user456',
          newEmoteSetId: 'setA',
          oldEmoteSetId: 'setB',
        ),
      );

      expect(userEvents, hasLength(1));
      expect(userEvents[0].actor, isNull);
    });

    test('user.update ignores non-emote_set_id fields', () {
      client.handleRawMessage({
        'op': 0,
        'd': {
          'type': 'user.update',
          'id': 'user789',
          'body': {
            'connection_index': 0,
            'change_map': {
              'fields': [
                {'key': 'other_field', 'value': 'foo', 'old_value': 'bar'},
              ],
            },
          },
        },
      });

      expect(userEvents, isEmpty);
    });

    test('user.update ignores empty new emote set id', () {
      client.handleRawMessage({
        'op': 0,
        'd': {
          'type': 'user.update',
          'id': 'userx',
          'body': {
            'change_map': {
              'fields': [
                {'key': 'emote_set_id', 'value': '', 'old_value': 'old'},
              ],
            },
          },
        },
      });

      expect(userEvents, isEmpty);
    });
  });

  group('status events', () {
    test('emitDisconnected sets disconnected status', () {
      client.emitDisconnected();
      expect(statusEvents, hasLength(1));
      expect(statusEvents.first, SevenTvEventStatus.disconnected);
    });

    test('handleRawMessage ignores unknown op codes gracefully', () {
      client.handleRawMessage({'op': 99, 'd': {}});
      expect(emoteEvents, isEmpty);
      expect(userEvents, isEmpty);
      expect(statusEvents, isEmpty);
    });
  });

  group('unsubscribe', () {
    setUp(() {
      client.handleRawMessage(_hello());
    });

    test('unsubscribeEmoteSet does not affect event streams', () {
      client.subscribeEmoteSet('setX');
      client.unsubscribeEmoteSet('setX');
      expect(emoteEvents, isEmpty);
    });
  });

  group('heartbeat', () {
    test('op 2 heartbeat does not emit any events', () {
      client.handleRawMessage(_hello());
      statusEvents.clear();

      client.handleRawMessage({
        'op': 2,
        'd': {'count': 1},
      });

      expect(emoteEvents, isEmpty);
      expect(userEvents, isEmpty);
      expect(statusEvents, isEmpty);
    });
  });

  group('op 4 reconnect request', () {
    test('op 4 message is handled gracefully', () {
      client.handleRawMessage({'op': 4, 'd': {}});
      expect(emoteEvents, isEmpty);
      expect(userEvents, isEmpty);
    });
  });

  group('op 5 and op 7 ignored', () {
    setUp(() {
      client.handleRawMessage(_hello());
      emoteEvents.clear();
      userEvents.clear();
      statusEvents.clear();
    });

    test('ack message (op 5) is ignored', () {
      client.handleRawMessage({'op': 5, 'd': {}});
      expect(emoteEvents, isEmpty);
      expect(userEvents, isEmpty);
      expect(statusEvents, isEmpty);
    });

    test('end of stream message (op 7) is ignored', () {
      client.handleRawMessage({'op': 7, 'd': {}});
      expect(emoteEvents, isEmpty);
      expect(userEvents, isEmpty);
      expect(statusEvents, isEmpty);
    });
  });

  group('dispose', () {
    test('onEmoteSetUpdate stream completes after dispose', () async {
      final events = <SevenTvEmoteUpdateEvent>[];
      final sub = client.onEmoteSetUpdate.listen(events.add);

      client.handleRawMessage(_hello());
      client.handleRawMessage(
        _emoteSetUpdate(
          emoteSetId: 's1',
          pushed: [
            {
              'value': {'id': 'e1', 'name': 'Test'},
            },
          ],
        ),
      );

      expect(events, hasLength(1));

      client.dispose();

      expect(
        () => client.handleRawMessage(_emoteSetUpdate(emoteSetId: 's2')),
        returnsNormally,
      );

      await sub.cancel();
    });
  });

  group('reconnect and connectivity', () {
    test('hello resets reconnectAttempt to 0', () {
      // Simulate several reconnect attempts
      for (var i = 0; i < 5; i++) {
        client.scheduleReconnectForTest();
        client.isReconnecting = false;
      }
      expect(client.reconnectAttempt, 5);

      client.handleRawMessage(_hello());
      expect(client.reconnectAttempt, 0);
    });

    test('scheduleReconnect increments reconnectAttempt', () {
      client.scheduleReconnectForTest();
      expect(client.reconnectAttempt, 1);
      expect(client.isReconnecting, true);
    });

    test('scheduleReconnect returns early when isReconnecting is true', () {
      client.scheduleReconnectForTest();
      expect(client.reconnectAttempt, 1);

      client.scheduleReconnectForTest();
      expect(client.reconnectAttempt, 1);
    });

    test('scheduleReconnect returns early when isOnline is false', () {
      final offlineClient = SevenTvEventClient();
      offlineClient.isOnline = false;
      offlineClient.scheduleReconnectForTest();
      expect(offlineClient.reconnectAttempt, 0);
      expect(offlineClient.isReconnecting, false);
    });

    test(
      'reconnectAttempt capped after max and resets reconnecting on each call',
      () {
        final client2 = SevenTvEventClient();
        for (var i = 0; i < 8; i++) {
          client2.scheduleReconnectForTest();
          client2.isReconnecting = false;
        }
        client2.scheduleReconnectForTest();
        expect(client2.reconnectAttempt, 9);
        expect(client2.isReconnecting, false);

        client2.scheduleReconnectForTest();
        expect(client2.reconnectAttempt, 10);
        expect(client2.isReconnecting, false);
      },
    );
  });

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

  group('thread store', () {
    test('ingested reply indexes entry and links root from buffer', () {
      final root = _msg('r1', 'root');
      final child = _taggedMsg('c1', 'child', rootId: 'r1');
      final msgs = <String, List<TwitchMessage>>{
        'test': [root, child],
      };
      final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
      conn.indexThreadMembers('test', [root, child]);

      final thread = conn.threadFor('test', 'r1');
      expect(thread, isNotNull);
      expect(thread!.map((m) => m.messageId), ['r1', 'c1']);
    });

    test('orphan reply indexes without root and adopts a late root', () {
      final child = _taggedMsg('c1', 'child', rootId: 'r1');
      final msgs = <String, List<TwitchMessage>>{
        'test': [child],
      };
      final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
      conn.indexThreadMembers('test', [child]);

      var thread = conn.threadFor('test', 'r1')!;
      expect(thread.map((m) => m.messageId), ['c1']);

      // The root shows up later (late history batch, slow fetch) and must
      // link into the waiting entry.
      final root = _msg('r1', 'root');
      conn.indexThreadMembers('test', [root]);
      thread = conn.threadFor('test', 'r1')!;
      expect(thread.map((m) => m.messageId), ['r1', 'c1']);
    });

    test('indexing is idempotent across live/history double delivery', () {
      final root = _msg('r1', 'root');
      final child = _taggedMsg('c1', 'child', rootId: 'r1');
      final msgs = <String, List<TwitchMessage>>{
        'test': [root, child],
      };
      final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
      conn.indexThreadMembers('test', [root, child]);
      conn.indexThreadMembers('test', [root, child]);

      final thread = conn.threadFor('test', 'r1')!;
      expect(thread.map((m) => m.messageId), ['r1', 'c1']);
    });

    test('live ingestion indexes threads through the message pipeline', () {
      final msgs = <String, List<TwitchMessage>>{'test': <TwitchMessage>[]};
      final conn = _makeConn(channelMessages: msgs, maxMessages: 100);
      conn.onMessage(_msg('r1', 'root'));
      conn.onMessage(_taggedMsg('c1', 'child', rootId: 'r1'));

      expect(conn.threadFor('test', 'r1')!.map((m) => m.messageId), [
        'r1',
        'c1',
      ]);
    });

    test('decay drops evicted replies but keeps the pinned root openable', () {
      final root = _msg('r1', 'root');
      final c1 = _taggedMsg('c1', 'child 1', rootId: 'r1');
      final c2 = _taggedMsg('c2', 'child 2', rootId: 'r1');
      final msgs = <String, List<TwitchMessage>>{
        'test': [root, c1, c2],
      };
      final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
      conn.indexThreadMembers('test', [root, c1, c2]);

      // Everything (root included) gets evicted from the chat buffer.
      conn.decayThreadMembers('test', [c1, c2, root]);

      final thread = conn.threadFor('test', 'r1')!;
      expect(
        thread.map((m) => m.messageId),
        ['r1'],
        reason: 'replies decay out; pinned root keeps the thread viewable',
      );
    });

    test('truncation keeps the store in sync with the trimmed buffer', () {
      const limit = 5;
      final root = _msg('r1', 'root');
      final child = _taggedMsg('c1', 'child', rootId: 'r1');
      // Newest-first: five fillers push both thread messages past the window.
      final msgs = <String, List<TwitchMessage>>{
        'test': [
          for (var i = 4; i >= 0; i--) _msg('f$i', 'filler $i'),
          child,
          root,
        ],
      };
      final conn = _makeConn(channelMessages: msgs, maxMessages: limit);
      conn.indexThreadMembers('test', [root, child]);
      conn.truncateChannelMessages('test');

      final remaining = msgs['test']!;
      expect(remaining.any((m) => m.messageId == 'c1'), false);
      expect(remaining.any((m) => m.messageId == 'r1'), false);

      // Buffer is empty of the thread, yet reopening still serves the root.
      expect(conn.threadFor('test', 'r1')!.map((m) => m.messageId), ['r1']);
    });

    test('clearChannelThreads drops entries for the channel', () {
      final root = _msg('r1', 'root');
      final child = _taggedMsg('c1', 'child', rootId: 'r1');
      final msgs = <String, List<TwitchMessage>>{
        'test': [root, child],
      };
      final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
      conn.indexThreadMembers('test', [root, child]);
      conn.clearChannelThreads('test');

      expect(conn.threadFor('test', 'r1'), isNull);
    });

    test('per-channel entry count stays under the LRU cap', () {
      final msgs = <String, List<TwitchMessage>>{'test': <TwitchMessage>[]};
      final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
      for (var t = 0; t < 80; t++) {
        conn.indexThreadMembers('test', [
          _msg('r$t', 'root $t'),
          _taggedMsg('c$t', 'child $t', rootId: 'r$t'),
        ]);
      }

      // 80 threads were created; only the newest 64 remain touchable. The
      // exact cap is an implementation detail - assert the bound holds.
      var remainingThreads = 0;
      for (var t = 0; t < 80; t++) {
        if (conn.threadFor('test', 'r$t') != null) remainingThreads++;
      }
      expect(remainingThreads, lessThanOrEqualTo(64));
      expect(conn.threadFor('test', 'r79'), isNotNull);
      expect(conn.threadFor('test', 'r0'), isNull);
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

  group('cheer highlighting', () {
    test('cheer PRIVMSG carries bits amount and purple accent', () {
      final msgs = <String, List<TwitchMessage>>{'test': []};
      final conn = _makeConn(channelMessages: msgs, maxMessages: 100);

      conn.onOwnIrcMessage(
        IrcMessage(
          tags: {
            'badges': 'bits/1000',
            'bits': '100',
            'display-name': 'ronni',
            'user-id': '12345',
            'id': 'msg-cheer',
          },
          prefix: 'ronni!ronni@ronni.tmi.twitch.tv',
          command: 'PRIVMSG',
          params: ['#test'],
          trailing: 'Cheer100 take my bits',
        ),
      );

      expect(msgs['test']!.length, 1);
      final msg = msgs['test']!.first;
      expect(msg.bitsAmount, 100);
      expect(msg.systemAccent, const Color(0xFF9146FF));
      expect(msg.text, 'Cheer100 take my bits');
    });

    test('non-cheer PRIVMSG stays unaccented', () {
      final msgs = <String, List<TwitchMessage>>{'test': []};
      final conn = _makeConn(channelMessages: msgs, maxMessages: 100);

      conn.onOwnIrcMessage(
        IrcMessage(
          tags: {
            'display-name': 'ronni',
            'user-id': '12345',
            'id': 'msg-plain',
          },
          prefix: 'ronni!ronni@ronni.tmi.twitch.tv',
          command: 'PRIVMSG',
          params: ['#test'],
          trailing: 'hello',
        ),
      );

      final msg = msgs['test']!.first;
      expect(msg.bitsAmount, isNull);
      expect(msg.systemAccent, isNull);
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

  group('JOIN failure surfacing', () {
    test(
      'suspended channel shows one clear message; late success announces',
      () async {
        final irc = _TestIrc();
        final texts = <String>[];
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          onReconnected: () {},
          onSystemMessage: (c, t, {Color? accent}) => texts.add(t),
        );
        await conn.connect();
        irc.emitConnected();

        // Queue the channel, then deliver the refusal notice.
        irc.join('test');
        irc.handleLine(
          '@msg-id=msg_channel_suspended :tmi.twitch.tv NOTICE #test '
          ':This channel has been suspended or closed.',
        );
        await Future<void>.delayed(Duration.zero);

        expect(
          texts,
          contains(
            'Could not join #test: '
            'the channel is suspended or deleted.',
          ),
        );
        expect(
          texts.any((t) => t.contains('suspended or closed')),
          isFalse,
          reason: "Twitch's raw refusal notice must not duplicate ours",
        );

        // A later ROOMSTATE means the channel joined after all.
        irc.handleLine('@room-id=123 :tmi.twitch.tv ROOMSTATE #test');
        await Future<void>.delayed(Duration.zero);
        expect(texts.last, 'Joined #test.');

        conn.dispose();
        irc.dispose();
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

    test('resub with text renders label plus child message', () async {
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
        'display-name=ronni;color=#0000FF;badges=subscriber/6;id=abc;'
        'emotes=emotesv2_123:0-4;user-id=456;'
        ':tmi.twitch.tv USERNOTICE #test :Great Kappa!',
      );

      expect(systemMessages, hasLength(1));
      expect(systemMessages[0].$1, 'test');
      expect(systemMessages[0].$2, 'ronni has subscribed!');
      expect(systemMessages[0].$3, const Color(0xFF9146FF));

      // Child message renders as a normal chat message on the same accent,
      // carrying the emotes parsed from the USERNOTICE line.
      final child = channelMessages['test']!.first;
      expect(child.isSystem, isFalse);
      expect(child.text, 'Great Kappa!');
      expect(child.login, 'ronni');
      expect(child.displayName, 'ronni');
      expect(child.color, '#0000FF');
      expect(child.userId, '456');
      expect(child.messageId, 'abc');
      expect(child.systemAccent, const Color(0xFF9146FF));
      expect(child.badges, hasLength(1));
      expect(child.emotePositions, isNotNull);
      expect(child.emotePositions!.single.emoteCode, 'Great');

      conn.dispose();
    });

    test('resub without text stays a single system message', () async {
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
        '@msg-id=subgift;system-msg=TWW2\\sgifted\\sa\\sTier\\s1\\ssub\\sto\\sMr_Woodchuck!;'
        'login=tww2;display-name=TWW2;'
        ':tmi.twitch.tv USERNOTICE #test',
      );

      expect(systemMessages, hasLength(1));
      expect(systemMessages[0].$2, 'TWW2 gifted a Tier 1 sub to Mr_Woodchuck!');
      expect(systemMessages[0].$3, const Color(0xFF9146FF));
      expect(
        channelMessages['test'],
        isNull,
        reason: 'notices without a user message never produce a child',
      );

      conn.dispose();
    });

    test('watch streak notice highlights with the purple accent', () async {
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
        '@msg-id=viewermilestone;system-msg=ronni\\shas\\sreached\\sa\\swatch\\sstreak\\sof\\s3!;'
        'login=ronni;display-name=ronni;'
        ':tmi.twitch.tv USERNOTICE #test',
      );

      expect(systemMessages, hasLength(1));
      expect(systemMessages[0].$2, 'ronni has reached a watch streak of 3!');
      expect(systemMessages[0].$3, const Color(0xFF9146FF));
      expect(
        channelMessages['test'],
        isNull,
        reason: 'watch streaks carry no user message',
      );

      conn.dispose();
    });

    test('bits badge tier notice highlights with the purple accent', () async {
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
        '@msg-id=bitsbadgetier;system-msg=ronni\\ssent\\s100\\sbits!;'
        'login=ronni;display-name=ronni;'
        ':tmi.twitch.tv USERNOTICE #test',
      );

      expect(systemMessages, hasLength(1));
      expect(systemMessages[0].$3, const Color(0xFF9146FF));
      expect(
        channelMessages['test'],
        isNull,
        reason: 'bits badge tier notices carry no user message',
      );

      conn.dispose();
    });

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

  group('send cooldowns', () {
    Future<(ChatConnectionManager, _TestIrc)> makeConn() async {
      final irc = _TestIrc();
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        onReconnected: () {},
        channels: ['test'],
        currentUserLogin: 'viewer',
      );
      await conn.connect();
      irc.emitConnected();
      return (conn, irc);
    }

    test('slow mode arms a countdown after your own message', () async {
      final (conn, irc) = await makeConn();
      irc.handleLine('@room-id=1;slow=30 :tmi.twitch.tv ROOMSTATE #test');
      expect(
        conn.remainingSlowCooldown('test'),
        isNull,
        reason: 'no countdown before you send anything',
      );

      await conn.doSendMessage('hi', 'test');

      expect(conn.remainingSlowCooldown('test'), inInclusiveRange(25, 30));
      conn.dispose();
    });

    test('slow-exempt badges skip the slow-mode countdown', () async {
      final (conn, irc) = await makeConn();
      irc.handleLine('@room-id=1;slow=30 :tmi.twitch.tv ROOMSTATE #test');
      irc.selfBadges['test'] = {'moderator'};

      await conn.doSendMessage('hi', 'test');

      expect(conn.remainingSlowCooldown('test'), isNull);
      conn.dispose();
    });

    test('own timeout arms the countdown, other timeouts do not', () async {
      final (conn, irc) = await makeConn();

      irc.handleLine('@ban-duration=60 :tmi.twitch.tv CLEARCHAT #test :forsen');
      await Future<void>.delayed(Duration.zero);
      expect(conn.remainingSelfTimeout('test'), isNull);

      irc.handleLine(
        '@ban-duration=600 :tmi.twitch.tv CLEARCHAT #test :viewer',
      );
      await Future<void>.delayed(Duration.zero);
      expect(conn.remainingSelfTimeout('test'), inInclusiveRange(595, 600));
      conn.dispose();
    });

    test(
      'an already-elapsed timeout clears instead of counting down',
      () async {
        final (conn, irc) = await makeConn();

        irc.handleLine(
          '@ban-duration=0 :tmi.twitch.tv CLEARCHAT #test :viewer',
        );
        await Future<void>.delayed(Duration.zero);
        expect(conn.remainingSelfTimeout('test'), isNull);
        conn.dispose();
      },
    );
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
        // forceReconnect restarts the loop immediately (no backoff).
        expect(irc.openAttempts, 1);
        expect(irc.isConnected, isTrue);

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

  group('read socket status', () {
    test('read outage surfaces as Chat reconnecting... then Reconnected', () {
      fakeAsync((async) {
        final messages = <(String, String)>[];
        final ircRead = _TestIrcRead();
        final irc = _TestIrc();
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          ircRead: ircRead,
          onReconnected: () {},
          channels: const ['test'],
          currentUserLogin: 'testuser',
          onSystemMessage: (c, t, {Color? accent}) => messages.add((c, t)),
        );

        conn.connect();
        async.flushMicrotasks();

        // The read socket dies alone (write stays up): an explicit marker is
        // emitted so the outage is not invisible.
        ircRead.emitDisconnected();
        async.flushMicrotasks();
        expect(messages, contains(('test', 'Chat reconnecting...')));

        // Recovery is announced and the marker is not re-emitted for a
        // repeated connected status.
        ircRead.emitConnected();
        async.flushMicrotasks();
        expect(messages, contains(('test', 'Reconnected')));

        ircRead.emitConnected();
        async.flushMicrotasks();
        expect(
          messages.where((m) => m.$2 == 'Reconnected').length,
          1,
          reason: 'repeated connected must not re-announce recovery',
        );

        conn.dispose();
      });
    });

    test('read outage before a channel joins emits nothing for it', () {
      fakeAsync((async) {
        final messages = <(String, String)>[];
        final ircRead = _TestIrcRead();
        final irc = _TestIrc();
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          ircRead: ircRead,
          onReconnected: () {},
          channels: const [],
          currentUserLogin: 'testuser',
          onSystemMessage: (c, t, {Color? accent}) => messages.add((c, t)),
        );

        conn.connect();
        async.flushMicrotasks();

        // No channels yet: a disconnect is invisible (nothing to mark).
        ircRead.emitDisconnected();
        async.flushMicrotasks();
        expect(messages, isEmpty);

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

  group('TwitchBadgeService shared-chat identity', () {
    late TwitchBadgeService badgeService;

    setUp(() {
      badgeService = TwitchBadgeService(
        client: http_testing.MockClient((request) async {
          final url = request.url.toString();
          if (url.contains('/helix/users')) {
            return http.Response(
              '{"data":[{"id":"1234","login":"forsen",'
              '"display_name":"Forsen",'
              '"profile_image_url":"https://example.com/avatar.png"}]}',
              200,
            );
          }
          return http.Response('Not found', 404);
        }),
      );
    });

    tearDown(() {
      badgeService.dispose();
    });

    test('resolves login and display name after avatar fetch', () async {
      final auth = TwitchAuth()..accessToken = 'fake-token';
      await badgeService.fetchChannelAvatar(auth, '1234');
      expect(badgeService.resolveChannelLogin('1234'), 'forsen');
      expect(badgeService.resolveChannelDisplayName('1234'), 'Forsen');
      expect(badgeService.version, greaterThan(0));
    });

    test('returns null before fetch completes', () {
      expect(badgeService.resolveChannelLogin('1234'), isNull);
      expect(badgeService.resolveChannelDisplayName('1234'), isNull);
    });
  });
}
