import 'dart:async';
import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:ermchat/services/connectivity_service.dart';
import 'package:ermchat/services/join_rate_limiter.dart';
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
import 'package:ermchat/services/chat_channel_setup.dart';
import 'package:ermchat/services/base_irc_connection.dart';
import 'package:ermchat/services/chat_store.dart';
import 'package:ermchat/services/emote_manager.dart';
import 'package:ermchat/services/twitch_api.dart';
import 'package:ermchat/services/twitch_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ermchat/services/twitch_badge_service.dart';
import 'package:ermchat/services/user_store.dart';
import 'package:http/testing.dart' as http_testing;
import 'package:http/testing.dart';
import 'package:ermchat/services/recent_messages.dart';

class _TestService extends IrcService {
  _TestService(
    this.channels, {
    this.onOpen,
    super.connectivityService,
    super.joinBudget,
  });

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

class _TestReadService extends IrcReadService {
  _TestReadService(this.channels, {super.joinBudget});

  final List<FakeWebSocketChannel> channels;

  @override
  Future<WebSocketChannel> openChannel() async => channels.first;
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

class _LiveEventSub extends EventSubService {
  int connectCalls = 0;
  int disconnectCalls = 0;

  @override
  Future<void> connect({String? url}) async {
    connectCalls++;
  }

  @override
  String? get sessionId => connectCalls > 0 ? 'live-session' : null;

  @override
  bool get isConnected => true;

  @override
  void disconnect({bool emitStatus = true}) {
    disconnectCalls++;
  }
}

class _RecordingIrc extends _TestIrc {
  /// (username at send time, text) - exposes which account a PRIVMSG rode.
  final sent = <(String?, String)>[];

  @override
  void sendMessage(
    String channelName,
    String text, {
    String? replyParentMessageId,
  }) {
    sent.add((username, text));
  }
}

class _LoopIrcRead extends IrcReadService {
  _LoopIrcRead(this.socket);

  final FakeWebSocketChannel socket;
  int openAttempts = 0;

  @override
  Future<WebSocketChannel> openChannel() async {
    openAttempts++;
    return socket;
  }
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

  /// Feeds a ROOMSTATE through the real dispatch path so readiness tracking
  /// sees the read side confirm like production traffic.
  void confirmJoin(String channel) {
    username ??= 'testuser';
    handleLine('@room-id=1 :tmi.twitch.tv ROOMSTATE #$channel');
  }
}

class _TestIrcRead extends IrcReadService {
  final _statusCtrl = StreamController<IrcConnectionStatus>.broadcast(
    sync: true,
  );

  bool fakeConnected = false;

  @override
  bool get isConnected => fakeConnected;

  /// Feeds a ROOMSTATE line through the real dispatch path so the manager's
  /// read-side tracking sees it exactly like production traffic.
  void confirmJoin(String channel) {
    username ??= 'testuser';
    handleLine('@room-id=1 :tmi.twitch.tv ROOMSTATE #$channel');
  }

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
  IrcService? irc,
  IrcReadService? ircRead,
  JoinRateLimiter? joinBudget,
  void Function(String channel, JoinProgress? info)? onJoinProgress,
}) {
  final api = TwitchApi(client: http.Client());
  return ChatConnectionManager(
    ChatConnectionConfig(
      services: ChatServices(
        twitchApi: api,
        eventSub: EventSubService(),
        irc: irc ?? IrcService(),
        ircRead: ircRead ?? IrcReadService(),
        emoteManager: emoteManager ?? EmoteManager(),
        badgeService: TwitchBadgeService(),
        userStore: UserStore(),
        twitchAuth: TwitchAuth(),
        joinBudget: joinBudget,
      ),
      store: ChatStore(
        now: truncateNow,
        truncateCoalesceWindow:
            truncateCoalesceWindow ?? const Duration(milliseconds: 250),
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
      bridge: ChatViewBridge(
        mentionsChannel: '@mentions',
        onSystemMessage: (c, t, {Color? accent, String? messageId}) {},
        getSelectedChannel: () => null,
        getMaxMessagesPerChannel: () => maxMessages,
        onJoinProgress: onJoinProgress,
      ),
      sinks: ChatSinks(
        onCommand: (t, c, a) {},
        getReplyToMsg: () => null,
        setReplyToMsg: (v) {},
      ),
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
  void Function(String, String, {Color? accent, String? messageId})?
  onSystemMessage,
  String? currentUserLogin,
  void Function(HypeTrainEvent event)? onHypeTrain,
  Future<void> Function(String?, List<String>)? onUserEmoteSets,
  TwitchAuth? auth,
  ChatStore? store,
  http.Client? client,
}) {
  final api = TwitchApi(client: client ?? http.Client());
  final effectiveAuth = auth ?? TwitchAuth();
  if (auth == null) {
    effectiveAuth.accessToken = 'test-token';
  }
  final effectiveStore =
      store ??
      ChatStore(
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
      );
  effectiveStore.session.login = currentUserLogin;
  return ChatConnectionManager(
    ChatConnectionConfig(
      services: ChatServices(
        twitchApi: api,
        eventSub: eventSub,
        irc: irc,
        ircRead: ircRead ?? _NoopIrcRead(),
        emoteManager: EmoteManager(),
        badgeService: TwitchBadgeService(),
        userStore: UserStore(),
        twitchAuth: effectiveAuth,
      ),
      store: effectiveStore,
      bridge: ChatViewBridge(
        mentionsChannel: '@mentions',
        onSystemMessage:
            onSystemMessage ?? (c, t, {Color? accent, String? messageId}) {},
        getSelectedChannel: () => null,
        getMaxMessagesPerChannel: () => 100,
      ),
      sinks: ChatSinks(
        onCommand: (t, c, a) {},
        getReplyToMsg: () => null,
        setReplyToMsg: (v) {},
        onReconnected: onReconnected,
        onHypeTrain: onHypeTrain,
        onUserEmoteSets: onUserEmoteSets,
      ),
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
    for (final (name, answer) in [
      ('sends keepalive PING and reconnects when no PONG arrives', false),
      ('PONG within the pong window keeps the connection alive', true),
    ]) {
      test(name, () {
        fakeAsync((async) {
          final channel = FakeWebSocketChannel();
          final service = _TestService([channel]);
          final statuses = <IrcConnectionStatus>[];
          service.onStatus.listen(statuses.add);
          service.connect(username: 'user', accessToken: 'token');
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 61));
          expect(channel.sent, contains('PING :keepalive'), reason: name);
          if (answer) {
            channel.push('PONG :keepalive');
            async.flushMicrotasks();
          }
          async.elapse(const Duration(seconds: 31));
          if (answer) {
            expect(
              statuses,
              isNot(contains(IrcConnectionStatus.disconnected)),
              reason: name,
            );
          } else {
            expect(
              statuses,
              contains(IrcConnectionStatus.disconnected),
              reason: name,
            );
            async.elapse(const Duration(milliseconds: 1250));
            expect(service.openAttempts, 2, reason: name);
          }
          service.dispose();
          channel.dispose();
        });
      });
    }

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
    for (final (name, push, expectTrue) in [
      (
        'returns true when a PONG echoes the probe token',
        ':tmi.twitch.tv PONG tmi.twitch.tv :alive-check-0',
        true,
      ),
      (
        'a stale keepalive PONG does not satisfy an in-flight probe',
        'PONG :tmi.twitch.tv',
        null,
      ),
      ('returns false on timeout when no PONG arrives', null, false),
    ]) {
      test(name, () {
        fakeAsync((async) {
          final channel = FakeWebSocketChannel();
          final service = _TestService([channel]);
          service.connect(username: 'user', accessToken: 'token');
          async.flushMicrotasks();
          bool? result;
          service.checkAlive().then((value) => result = value);
          async.flushMicrotasks();
          expect(channel.sent, contains('PING :alive-check-0'), reason: name);
          if (push != null && expectTrue == true) {
            channel.push(push);
            async.flushMicrotasks();
            expect(result, isTrue, reason: name);
          } else if (push != null) {
            channel.push(push);
            async.flushMicrotasks();
            expect(result, isNull, reason: name);
            channel.push(':tmi.twitch.tv PONG tmi.twitch.tv :alive-check-0');
            async.flushMicrotasks();
            expect(result, isTrue, reason: name);
          } else {
            async.elapse(const Duration(seconds: 6));
            async.flushMicrotasks();
            expect(result, isFalse, reason: name);
          }
          service.dispose();
          channel.dispose();
        });
      });
    }

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

    for (final (name, trigger)
        in <(String, void Function(FakeAsync, _TestService))>[
          (
            'stream error',
            (_, service) {
              service.channels.last.failNow();
            },
          ),
          (
            'RECONNECT command',
            (_, service) {
              service.handleLine(':tmi.twitch.tv RECONNECT');
            },
          ),
          (
            'PONG timeout',
            (async, _) {
              async.elapse(const Duration(seconds: 61));
              async.elapse(const Duration(seconds: 31));
            },
          ),
          (
            'forceReconnect',
            (_, service) {
              service.forceReconnect();
            },
          ),
        ]) {
      test(name, () {
        expectDisconnectedWithSocketCleared(trigger);
      });
    }
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
    test('JOINs are paced by the token bucket, not fired in a burst', () {
      fakeAsync((async) {
        // The bucket meters itself off an injected clock: fakeAsync advances
        // its own virtual time, not DateTime.now().
        var fakeNow = DateTime(2026, 1, 1);
        final channel = FakeWebSocketChannel();
        final service = _TestService([
          channel,
        ], joinBudget: JoinRateLimiter(now: () => fakeNow));
        service.connect(username: 'user', accessToken: 'token');
        async.flushMicrotasks();

        // 25 channels exceed the bucket's 20-channel capacity.
        for (var i = 0; i < 25; i++) {
          service.join('c$i');
        }
        async.flushMicrotasks();

        int joinedChannels() {
          var count = 0;
          for (final line in channel.sent) {
            if (!line.startsWith('JOIN #')) continue;
            count += line
                .substring('JOIN #'.length)
                .split(',')
                .where((c) => c.isNotEmpty)
                .map((c) => c.startsWith('#') ? c.substring(1) : c)
                .length;
          }
          return count;
        }

        // Send-cap: at most six channels per pump tick (batched into one line).
        expect(joinedChannels(), 6);
        // ...and the rest drip out at ~2 channels per second. ROOMSTATE echoes
        // are fed back so the rejoin sweep never pollutes the count.
        for (var step = 0; step < 60; step++) {
          fakeNow = fakeNow.add(const Duration(milliseconds: 500));
          async.elapse(const Duration(milliseconds: 500));
          async.flushMicrotasks();
          for (final line in channel.sent.toList()) {
            if (!line.startsWith('JOIN #')) continue;
            final rest = line.substring('JOIN #'.length);
            for (final ch in rest.split(',')) {
              channel.push('@room-id=1 :tmi.twitch.tv ROOMSTATE #$ch');
            }
          }
        }
        // Every channel must be joined at least once (sweeps may re-send an
        // unconfirmed channel under the fakeAsync clock, so count distinct).
        final joined = <String>{};
        for (final line in channel.sent.where((l) => l.startsWith('JOIN #'))) {
          joined.addAll(
            line
                .substring('JOIN #'.length)
                .split(',')
                .map((c) => c.startsWith('#') ? c.substring(1) : c),
          );
        }
        expect(joined.length, 25);

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

        // JOINs are batched into a single line; check the joined channel tokens.
        expect(channel.sent.join('\n'), contains('#awootismm'));
        expect(channel.sent.join('\n'), contains('#ermugo2'));

        service.dispose();
        channel.dispose();
      });
    });
  });

  group('join progress surfacing', () {
    test(
      'queued channel shows a countdown that retires on ROOMSTATE and clears on disconnect',
      () {
        fakeAsync((async) {
          var fakeNow = DateTime(2026, 1, 1);
          final budget = JoinRateLimiter(now: () => fakeNow);
          final channel = FakeWebSocketChannel();
          final irc = _TestService([channel], joinBudget: budget);
          final ircRead = _TestIrcRead();
          ircRead.fakeConnected = true;
          final events = <(String, JoinProgress?)>[];
          final conn = _makeConn(
            channelMessages: {},
            maxMessages: 10,
            irc: irc,
            ircRead: ircRead,
            joinBudget: budget,
            onJoinProgress: (c, i) => events.add((c, i)),
          );
          for (var i = 0; i < 22; i++) {
            irc.join('filler$i');
          }
          irc.join('test');
          conn.connect();
          async.flushMicrotasks();
          ircRead.emitConnected();
          fakeNow = fakeNow.add(const Duration(seconds: 1));
          async.elapse(const Duration(milliseconds: 3100));
          final waits = events
              .where(
                (e) => e.$1 == 'test' && e.$2 != null && e.$2!.position > 0,
              )
              .toList();
          expect(
            waits,
            isNotEmpty,
            reason: 'a queued channel shows a countdown',
          );
          ircRead.emitRoomState('test', {'room-id': '1'});
          fakeNow = fakeNow.add(const Duration(seconds: 1));
          async.elapse(const Duration(milliseconds: 3100));
          expect(events.last.$1, 'test');
          expect(events.last.$2, isNull);
          irc.forceReconnect();
          async.flushMicrotasks();
          fakeNow = fakeNow.add(const Duration(seconds: 1));
          async.elapse(const Duration(milliseconds: 3100));
          expect(
            events.where((e) => e.$1 == 'test' && e.$2 == null),
            isNotEmpty,
            reason: 'the countdown must not outlive its socket',
          );
          conn.dispose();
        });
      },
    );
  });

  group('shared join rate limiter', () {
    test('the shared bucket paces JOINs across both sockets', () {
      fakeAsync((async) {
        var fakeNow = DateTime(2026, 1, 1);
        final budget = JoinRateLimiter(now: () => fakeNow);
        final writeChannel = FakeWebSocketChannel();
        final readChannel = FakeWebSocketChannel();
        final write = _TestService([writeChannel], joinBudget: budget);
        final read = _TestReadService([readChannel], joinBudget: budget);
        write.connect(username: 'user', accessToken: 'token');
        read.connect(username: 'ruser', accessToken: 'token');
        async.flushMicrotasks();

        // Each socket joins its OWN 12 channels: 24 disjoint units sharing one
        // bucket, so the cap applies to their combined JOINs (not per-socket).
        // Enqueue per socket so same-role units are contiguous (batched).
        for (var i = 0; i < 12; i++) {
          write.join('w$i');
        }
        for (var i = 0; i < 12; i++) {
          read.join('r$i');
        }
        async.flushMicrotasks();

        int totalJoinedChannels() {
          int from(String line) => line.startsWith('JOIN #')
              ? line
                    .substring('JOIN #'.length)
                    .split(',')
                    .where((c) => c.isNotEmpty)
                    .map((c) => c.startsWith('#') ? c.substring(1) : c)
                    .length
              : 0;
          return writeChannel.sent.fold(0, (s, l) => s + from(l)) +
              readChannel.sent.fold(0, (s, l) => s + from(l));
        }

        // Send-cap starts with at most six channels (one shared bucket, one
        // batched line per pump tick).
        expect(
          totalJoinedChannels(),
          6,
          reason: 'the shared bucket caps both sockets',
        );

        // Echo ROOMSTATE like the real server so sweeps stay quiet.
        void confirmEchoes() {
          for (final line in writeChannel.sent) {
            if (!line.startsWith('JOIN #')) continue;
            for (final ch in line.substring('JOIN #'.length).split(',')) {
              final name = ch.startsWith('#') ? ch.substring(1) : ch;
              writeChannel.push('@room-id=1 :tmi.twitch.tv ROOMSTATE #$name');
            }
          }
          for (final line in readChannel.sent) {
            if (!line.startsWith('JOIN #')) continue;
            for (final ch in line.substring('JOIN #'.length).split(',')) {
              final name = ch.startsWith('#') ? ch.substring(1) : ch;
              readChannel.push('@room-id=1 :tmi.twitch.tv ROOMSTATE #$name');
            }
          }
        }

        // The remaining channels drip out at ~2 per second across both sockets.
        for (var step = 0; step < 30; step++) {
          fakeNow = fakeNow.add(const Duration(milliseconds: 500));
          async.elapse(const Duration(milliseconds: 500));
          async.flushMicrotasks();
          confirmEchoes();
        }
        // A sweep firing mid-step can legitimately re-send a just-dispatched
        // channel whose echo has not been fed back yet; stabilize with extra
        // confirmed rounds before counting.
        for (var step = 0; step < 8; step++) {
          fakeNow = fakeNow.add(const Duration(milliseconds: 500));
          async.elapse(const Duration(milliseconds: 500));
          async.flushMicrotasks();
          confirmEchoes();
        }
        // Sweeps may legitimately re-send a channel whose echo had not been
        // fed back yet; every channel must be joined at least once.
        final joinedWrite = <String>{};
        for (final line in writeChannel.sent.where(
          (l) => l.startsWith('JOIN #'),
        )) {
          joinedWrite.addAll(
            line
                .substring('JOIN #'.length)
                .split(',')
                .map((c) => c.startsWith('#') ? c.substring(1) : c),
          );
        }
        final joinedRead = <String>{};
        for (final line in readChannel.sent.where(
          (l) => l.startsWith('JOIN #'),
        )) {
          joinedRead.addAll(
            line
                .substring('JOIN #'.length)
                .split(',')
                .map((c) => c.startsWith('#') ? c.substring(1) : c),
          );
        }
        expect(joinedWrite.length, 12);
        expect(joinedRead.length, 12);

        write.dispose();
        read.dispose();
        writeChannel.dispose();
        readChannel.dispose();
      });
    });

    test(
      'a unit whose sockets all fail stays queued without consuming tokens',
      () {
        fakeAsync((async) {
          final clock = DateTime(2026, 1, 1);
          var fakeNow = clock;
          final budget = JoinRateLimiter(now: () => fakeNow);
          var attempts = 0;
          budget.registerHandler(IrcSocketRole.write, (_) {
            attempts++;
            return false; // socket down
          });

          budget.enqueue('chan', IrcSocketRole.write);
          async.flushMicrotasks();
          expect(attempts, 1, reason: 'the pump attempted the unit');
          expect(
            budget.positionOf('chan'),
            1,
            reason: 'failed units stay queued, not stranded',
          );
          expect(
            budget.availableTokens,
            20,
            reason: 'a failed send must not consume a token',
          );

          // The socket comes back: the SAME unit completes on a later pump.
          budget.registerHandler(IrcSocketRole.write, (_) {
            attempts++;
            return true;
          });
          fakeNow = fakeNow.add(const Duration(milliseconds: 3100));
          async.elapse(const Duration(milliseconds: 3100));
          async.flushMicrotasks();

          expect(attempts, 2);
          expect(budget.positionOf('chan'), isNull);
          expect(budget.availableTokens, closeTo(19, 0.001));
        });
      },
    );

    for (final (name, run) in <(String, Future<void> Function())>[
      (
        'position and eta track FIFO order and refill rate',
        () async {
          final clock = DateTime(2026, 1, 1);
          final budget = JoinRateLimiter(now: () => clock);
          budget.registerHandler(IrcSocketRole.write, (_) => true);
          for (var i = 0; i < 25; i++) {
            budget.enqueue('c$i', IrcSocketRole.write);
          }
          await pumpEventQueue();
          expect(budget.pending(), hasLength(19));
          expect(budget.positionOf('c0'), isNull);
          expect(budget.positionOf('c6'), 1);
          expect(budget.etaSecondsForChannel('c6'), 0);
          expect(budget.etaSecondsForChannel('c24'), 12);
        },
      ),
      (
        'eta counts outstanding channel commands ahead of the channel',
        () async {
          final budget = JoinRateLimiter(
            capacity: 3,
            window: const Duration(milliseconds: 10500),
            now: () => DateTime(2026, 1, 1),
          );
          budget.registerHandler(IrcSocketRole.write, (_) => true);
          for (final c in ['a', 'b', 'c']) {
            budget.enqueue(c, IrcSocketRole.write);
          }
          budget.enqueue('last', IrcSocketRole.write);
          expect(budget.etaSecondsForChannel('b'), 0);
          expect(budget.etaSecondsForChannel('c'), 0);
          expect(budget.etaSecondsForChannel('last'), 4);
        },
      ),
    ]) {
      test(name, () async {
        await run();
      });
    }

    test('a channel enqueued before its socket is ready waits then sends', () {
      fakeAsync((async) {
        var fakeNow = DateTime(2026, 1, 1);
        final budget = JoinRateLimiter(now: () => fakeNow);
        var readReady = false;
        budget.registerHandler(IrcSocketRole.read, (_) => readReady);

        // Enqueued while the socket refuses: stays queued, no token spent.
        budget.enqueue('chan', IrcSocketRole.read);
        async.flushMicrotasks();
        expect(budget.positionOf('chan'), 1);
        expect(budget.availableTokens, 20);

        // The socket comes up: the SAME unit sends in place on a later pump.
        readReady = true;
        fakeNow = fakeNow.add(const Duration(milliseconds: 3100));
        async.elapse(const Duration(milliseconds: 3100));
        async.flushMicrotasks();
        expect(budget.positionOf('chan'), isNull);
      });
    });

    test('a channel enqueued before its socket is ready keeps its slot', () {
      fakeAsync((async) {
        final budget = JoinRateLimiter(now: () => DateTime(2026, 1, 1));
        final sent = <IrcSocketRole>[];
        // Socket registered but refusing until it is ready.
        budget.registerHandler(IrcSocketRole.read, (channel) {
          sent.add(IrcSocketRole.read);
          return false;
        });

        budget.enqueue('first', IrcSocketRole.read);
        async.flushMicrotasks();

        // Attempted once, refused, and kept at its original slot (not dropped).
        expect(sent, [IrcSocketRole.read]);
        expect(budget.positionOf('first'), 1);

        var readReady = false;
        budget.registerHandler(IrcSocketRole.read, (channel) {
          sent.add(IrcSocketRole.read);
          return readReady;
        });
        readReady = true;
        async.elapse(const Duration(milliseconds: 3100));
        async.flushMicrotasks();

        // The join completed IN PLACE: it was never dropped or re-queued.
        expect(budget.positionOf('first'), isNull);
        expect(
          sent.where((r) => r == IrcSocketRole.read).length,
          greaterThanOrEqualTo(2),
        );
        expect(budget.pending(), isEmpty);
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
    test(
      'coming back online wakes the backoff early while an offline blip never stops the retry loop',
      () {
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
          async.elapse(const Duration(milliseconds: 200));
          expect(times, hasLength(1));
          conn.debugSetResults(const [ConnectivityResult.wifi]);
          async.flushMicrotasks();
          expect(times, hasLength(2));
          expect(
            times[1],
            lessThan(const Duration(milliseconds: 900)),
            reason: 'the backoff wait must be shortened, not run out',
          );
          conn.debugSetResults(const [ConnectivityResult.none]);
          async.elapse(const Duration(seconds: 30));
          expect(times.length, greaterThanOrEqualTo(4));
          service.dispose();
          conn.dispose();
        });
      },
    );
  });

  late IrcReadService service;

  setUp(() {
    service = IrcReadService();
  });

  tearDown(() {
    service.dispose();
  });

  group('channel tracking', () {
    for (final (name, run) in [
      (
        'join does not crash when not connected',
        (IrcReadService s) =>
            () => s.join('testchannel'),
      ),
      (
        'part does not crash when not connected',
        (IrcReadService s) =>
            () => s.part('testchannel'),
      ),
    ]) {
      test(name, () {
        expect(run(service), returnsNormally, reason: name);
      });
    }
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

    for (final (name, line, user) in [
      (
        'ignores CLEARMSG without target-msg-id',
        '@login=forsen :tmi.twitch.tv CLEARMSG #xqc :bad message',
        null,
      ),
      (
        'defaults user to unknown when login tag missing',
        '@target-msg-id=xyz :tmi.twitch.tv CLEARMSG #xqc :deleted',
        'unknown',
      ),
    ]) {
      test(name, () async {
        final events = <IrcMessageDeletedEvent>[];
        service.onMessageDeleted.listen(events.add);
        service.handleLine(line);
        await flush();
        if (user == null) {
          expect(events, isEmpty, reason: name);
        } else {
          expect(events, hasLength(1), reason: name);
          expect(events[0].user, user, reason: name);
        }
      });
    }
  });

  group('CLEARCHAT', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    for (final (name, line, timeout, duration) in [
      (
        'emits ban event for permanent ban',
        ':tmi.twitch.tv CLEARCHAT #xqc :forsen',
        false,
        null,
      ),
      (
        'emits timeout event with duration',
        '@ban-duration=300;target-user-id=12345 :tmi.twitch.tv CLEARCHAT #xqc :forsen',
        true,
        300,
      ),
    ]) {
      test(name, () async {
        final events = <IrcBanEvent>[];
        service.onBan.listen(events.add);
        service.handleLine(line);
        await flush();
        expect(events, hasLength(1), reason: name);
        expect(events[0].user, 'forsen', reason: name);
        expect(events[0].isTimeout, timeout, reason: name);
        expect(events[0].duration, duration, reason: name);
      });
    }

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

    for (final (name, line, channel, ids) in [
      (
        'emits emote-sets from GLOBALUSERSTATE without channel',
        '@emote-sets=0,123456789,987654321 :tmi.twitch.tv GLOBALUSERSTATE',
        null,
        ['0', '123456789', '987654321'],
      ),
      (
        'emits channel-scoped emote-sets from USERSTATE',
        '@emote-sets=300374079,0 :tmi.twitch.tv USERSTATE #xqc',
        'xqc',
        ['300374079', '0'],
      ),
      (
        'does not emit when emote-sets tag is missing',
        '@badges=staff/1 :tmi.twitch.tv GLOBALUSERSTATE',
        'missing',
        <String>[],
      ),
    ]) {
      test(name, () async {
        final sets = <(String?, List<String>)>[];
        service.onUserEmoteSets.listen(sets.add);
        service.handleLine(line);
        await flush();
        if (channel == 'missing') {
          expect(sets, isEmpty, reason: name);
        } else {
          expect(sets, hasLength(1), reason: name);
          expect(sets.single.$1, channel, reason: name);
          expect(sets.single.$2, ids, reason: name);
        }
      });
    }
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

    for (final (name, line, code) in [
      (
        'parses announcement emotes into emote positions',
        '@msg-id=announcement;msg-param-color=GREEN;login=mm2pl;display-name=Mm2PL;emotes=emotesv2_123:0-7;system-msg=;:tmi.twitch.tv USERNOTICE #xqc :PogChamp test',
        'PogChamp',
      ),
      (
        'NOTICE still routes to onNotice',
        '@msg-id=slow_on :tmi.twitch.tv NOTICE #xqc :This room is now in slow mode.',
        'slow_on',
      ),
    ]) {
      test(name, () async {
        if (name.startsWith('parses')) {
          final userNotices = <UserNoticeEvent>[];
          service.onUserNotice.listen(userNotices.add);
          service.handleLine(line);
          await flush();
          expect(userNotices, hasLength(1), reason: name);
          expect(
            userNotices[0].emotePositions!.single.emoteCode,
            code,
            reason: name,
          );
        } else {
          final notices = <IrcNoticeEvent>[];
          service.onNotice.listen(notices.add);
          service.handleLine(line);
          await flush();
          expect(notices, hasLength(1), reason: name);
          expect(notices[0].msgId, code, reason: name);
        }
      });
    }
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
    for (final (name, run) in <(String, Future<void> Function())>[
      (
        'handleRawMessage welcome sets sessionId and emits connected',
        () async {
          final statuses = <EventSubStatus>[];
          esService.onStatus.listen(statuses.add);
          esService.handleRawMessage(_welcome(id: 'sess-lifecycle'));
          expect(esService.sessionId, 'sess-lifecycle');
          expect(statuses, contains(EventSubStatus.connected));
        },
      ),
      (
        'second welcome overwrites sessionId',
        () async {
          esService.handleRawMessage(_welcome(id: 'sess-a'));
          expect(esService.sessionId, 'sess-a');
          esService.handleRawMessage(_welcome(id: 'sess-b'));
          expect(esService.sessionId, 'sess-b');
        },
      ),
      (
        'disconnect clears sessionId',
        () async {
          esService.handleRawMessage(_welcome(id: 'sess-clear'));
          expect(esService.sessionId, 'sess-clear');
          esService.disconnect();
          expect(esService.sessionId, isNull);
        },
      ),
      (
        'welcome after disconnect sets sessionId again',
        () async {
          esService.handleRawMessage(_welcome(id: 'first'));
          expect(esService.sessionId, 'first');
          esService.disconnect();
          expect(esService.sessionId, isNull);
          esService.handleRawMessage(_welcome(id: 'second'));
          expect(esService.sessionId, 'second');
        },
      ),
      (
        'waitForSession completes after welcome',
        () async {
          final future = esService.waitForSession();
          esService.handleRawMessage(_welcome(id: 'sess-completer'));
          expect(await future, 'sess-completer');
        },
      ),
      (
        'waitForSession returns immediately if session already set',
        () async {
          esService.emitConnected();
          expect(await esService.waitForSession(), 'test-session-id');
        },
      ),
    ]) {
      test(name, () async {
        await run();
      });
    }
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
    test(
      'subscribe before Hello stays quiet and Hello emits connected status',
      () {
        client.subscribeEmoteSet('set1');
        expect(emoteEvents, isEmpty);
        expect(userEvents, isEmpty);
        client.handleRawMessage(_hello());
        expect(statusEvents, hasLength(1));
        expect(statusEvents.first, SevenTvEventStatus.connected);
      },
    );
  });

  group('dispatch events', () {
    setUp(() {
      client.handleRawMessage(_hello());
      emoteEvents.clear();
      userEvents.clear();
      statusEvents.clear();
    });

    for (final (name, pushed, pulled, updated) in [
      (
        'emote_set.update parses added emote',
        [
          {
            'value': {'id': 'abc', 'name': 'KEKW'},
          },
        ],
        <Map<String, dynamic>>[],
        <Map<String, dynamic>>[],
      ),
      (
        'emote_set.update parses removed emote',
        <Map<String, dynamic>>[],
        [
          {
            'old_value': {'id': 'xyz', 'name': 'PogU'},
          },
        ],
        <Map<String, dynamic>>[],
      ),
      (
        'emote_set.update parses renamed emote',
        <Map<String, dynamic>>[],
        <Map<String, dynamic>>[],
        [
          {
            'value': {'id': 'def', 'name': 'NewName'},
            'old_value': {'id': 'def', 'name': 'OldName'},
          },
        ],
      ),
    ]) {
      test(name, () {
        client.handleRawMessage(
          _emoteSetUpdate(
            emoteSetId: 'set123',
            pushed: pushed,
            pulled: pulled,
            updated: updated,
          ),
        );
        expect(emoteEvents, hasLength(1), reason: name);
        final e = emoteEvents.single;
        expect(e.emoteSetId, 'set123', reason: name);
        if (name.contains('added')) {
          expect(e.added.single.id, 'abc', reason: name);
          expect(e.added.single.name, 'KEKW', reason: name);
          expect(e.removed, isEmpty, reason: name);
          expect(e.renamed, isEmpty, reason: name);
        } else if (name.contains('removed')) {
          expect(e.removed.single.id, 'xyz', reason: name);
          expect(e.added, isEmpty, reason: name);
        } else {
          expect(e.renamed.single.newName, 'NewName', reason: name);
          expect(e.renamed.single.oldName, 'OldName', reason: name);
        }
      });
    }

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

    for (final (name, fields) in [
      (
        'user.update ignores non-emote_set_id fields',
        [
          {'key': 'other_field', 'value': 'foo', 'old_value': 'bar'},
        ],
      ),
      (
        'user.update ignores empty new emote set id',
        [
          {'key': 'emote_set_id', 'value': '', 'old_value': 'old'},
        ],
      ),
    ]) {
      test(name, () {
        client.handleRawMessage({
          'op': 0,
          'd': {
            'type': 'user.update',
            'id': 'userx',
            'body': {
              'change_map': {'fields': fields},
            },
          },
        });
        expect(userEvents, isEmpty, reason: name);
      });
    }
  });

  group('status events', () {
    test('emitDisconnected sets disconnected status', () {
      client.emitDisconnected();
      expect(statusEvents, hasLength(1));
      expect(statusEvents.first, SevenTvEventStatus.disconnected);
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

  group('ignored ops', () {
    setUp(() {
      client.handleRawMessage(_hello());
      emoteEvents.clear();
      userEvents.clear();
      statusEvents.clear();
    });

    for (final (name, op) in [
      ('op 2 heartbeat does not emit any events', 2),
      ('op 4 message is handled gracefully', 4),
      ('ack message (op 5) is ignored', 5),
      ('end of stream message (op 7) is ignored', 7),
      ('handleRawMessage ignores unknown op codes gracefully', 99),
    ]) {
      test(name, () {
        client.handleRawMessage({'op': op, 'd': {}});
        expect(emoteEvents, isEmpty, reason: name);
        expect(userEvents, isEmpty, reason: name);
        expect(statusEvents, isEmpty, reason: name);
      });
    }
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
      for (var i = 0; i < 5; i++) {
        client.scheduleReconnectForTest();
        client.isReconnecting = false;
      }
      expect(client.reconnectAttempt, 5);

      client.handleRawMessage(_hello());
      expect(client.reconnectAttempt, 0);
    });

    for (final (name, online, busy, expected) in [
      ('scheduleReconnect increments reconnectAttempt', true, false, 1),
      (
        'scheduleReconnect returns early when isReconnecting is true',
        true,
        true,
        1,
      ),
      (
        'scheduleReconnect returns early when isOnline is false',
        false,
        false,
        0,
      ),
      (
        'reconnectAttempt capped after max and resets reconnecting on each call',
        true,
        false,
        10,
      ),
    ]) {
      test(name, () {
        if (name.startsWith('reconnectAttempt capped')) {
          final client2 = SevenTvEventClient();
          for (var i = 0; i < 10; i++) {
            client2.scheduleReconnectForTest();
            client2.isReconnecting = false;
          }
          expect(client2.reconnectAttempt, expected, reason: name);
          return;
        }
        final c = SevenTvEventClient();
        c.isOnline = online;
        if (busy) {
          c.scheduleReconnectForTest();
          expect(c.reconnectAttempt, 1, reason: name);
          c.scheduleReconnectForTest();
          expect(c.reconnectAttempt, expected, reason: name);
        } else {
          c.scheduleReconnectForTest();
          expect(c.reconnectAttempt, expected, reason: name);
        }
        c.dispose();
      });
    }
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (name, count, expected) in [
    ('keeps exactly maxMessages when no threads exist', 25, 10),
    ('no-op when under limit', 5, 5),
  ]) {
    test(name, () {
      final msgs = <String, List<TwitchMessage>>{
        'test': List.generate(count, (i) => _msg('m$i', 'msg $i')),
      };
      final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
      conn.store.truncateChannel('test', maxMessages: 10);
      expect(msgs['test']!.length, expected, reason: name);
    });
  }

  for (final (name, fillers, keepParent) in [
    ('preserves multi-level thread when leaf is within limit', 8, true),
    ('removes multi-level thread when all ancestors are past limit', 10, false),
  ]) {
    test(name, () {
      final msgs = <String, List<TwitchMessage>>{
        'test': [
          ...List.generate(fillers, (i) => _msg('f$i', 'filler $i')),
          _msg('grand', 'leaf', replyToParentId: 'child'),
          _msg('child', 'mid', replyToParentId: 'parent'),
          _msg('parent', 'root'),
        ],
      };
      final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
      conn.store.truncateChannel('test', maxMessages: 10);
      final ids = msgs['test']!.map((m) => m.messageId).toSet();
      expect(ids.contains('parent'), keepParent, reason: name);
      expect(ids.contains('child'), keepParent, reason: name);
      expect(ids.contains('grand'), keepParent, reason: name);
    });
  }

  test(
    'handles multiple independent threads with one inside and one outside the limit',
    () {
      for (final (fillers, keepB) in [(6, true), (8, false)]) {
        final msgs = <String, List<TwitchMessage>>{
          'test': [
            ...List.generate(fillers, (i) => _msg('f$i', 'filler $i')),
            _msg('aChild', 'reply', replyToParentId: 'aParent'),
            _msg('aParent', 'root A'),
            _msg('bChild', 'reply', replyToParentId: 'bParent'),
            _msg('bParent', 'root B'),
          ],
        };
        final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
        conn.store.truncateChannel('test', maxMessages: 10);
        final ids = msgs['test']!.map((m) => m.messageId).toSet();
        expect(ids.contains('aParent'), isTrue, reason: 'thread A stays');
        expect(ids.contains('bParent'), keepB, reason: 'thread B keeps $keepB');
      }
    },
  );

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
      conn.store.truncateChannel('test', maxMessages: limit);

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
      conn.store.truncateChannel('test', maxMessages: limit);

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
      conn.store.truncateChannel('test', maxMessages: limit);

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
      conn.store.indexMessages('test', [root, child]);

      final thread = conn.store.threadFor('test', 'r1');
      expect(thread, isNotNull);
      expect(thread!.map((m) => m.messageId), ['r1', 'c1']);
    });

    test('orphan reply indexes without root and adopts a late root', () {
      final child = _taggedMsg('c1', 'child', rootId: 'r1');
      final msgs = <String, List<TwitchMessage>>{
        'test': [child],
      };
      final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
      conn.store.indexMessages('test', [child]);

      var thread = conn.store.threadFor('test', 'r1')!;
      expect(thread.map((m) => m.messageId), ['c1']);

      // The root shows up later (late history batch, slow fetch) and must
      // link into the waiting entry.
      final root = _msg('r1', 'root');
      conn.store.indexMessages('test', [root]);
      thread = conn.store.threadFor('test', 'r1')!;
      expect(thread.map((m) => m.messageId), ['r1', 'c1']);
    });

    test('live ingestion indexes threads through the message pipeline', () {
      final msgs = <String, List<TwitchMessage>>{'test': <TwitchMessage>[]};
      final conn = _makeConn(channelMessages: msgs, maxMessages: 100);
      conn.onMessage(_msg('r1', 'root'));
      conn.onMessage(_taggedMsg('c1', 'child', rootId: 'r1'));

      expect(conn.store.threadFor('test', 'r1')!.map((m) => m.messageId), [
        'r1',
        'c1',
      ]);

      // Double delivery stays idempotent.
      conn.store.indexMessages('test', [
        _msg('r1', 'root'),
        _taggedMsg('c1', 'child', rootId: 'r1'),
      ]);
      expect(conn.store.threadFor('test', 'r1')!.map((m) => m.messageId), [
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
      conn.store.indexMessages('test', [root, c1, c2]);

      // Everything (root included) gets evicted from the chat buffer.
      conn.store.decayEvicted('test', [c1, c2, root]);

      final thread = conn.store.threadFor('test', 'r1')!;
      expect(thread.map((m) => m.messageId), [
        'r1',
      ], reason: 'replies decay out; pinned root keeps the thread viewable');
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
      conn.store.indexMessages('test', [root, child]);
      conn.store.truncateChannel('test', maxMessages: limit);

      final remaining = msgs['test']!;
      expect(remaining.any((m) => m.messageId == 'c1'), false);
      expect(remaining.any((m) => m.messageId == 'r1'), false);

      // Buffer is empty of the thread, yet reopening still serves the root.
      expect(conn.store.threadFor('test', 'r1')!.map((m) => m.messageId), [
        'r1',
      ]);
    });

    test('per-channel entry count stays under the LRU cap', () {
      final msgs = <String, List<TwitchMessage>>{'test': <TwitchMessage>[]};
      final conn = _makeConn(channelMessages: msgs, maxMessages: 10);
      for (var t = 0; t < 80; t++) {
        conn.store.indexMessages('test', [
          _msg('r$t', 'root $t'),
          _taggedMsg('c$t', 'child $t', rootId: 'r$t'),
        ]);
      }

      // 80 threads were created; only the newest 64 remain touchable. The
      // exact cap is an implementation detail - assert the bound holds.
      var remainingThreads = 0;
      for (var t = 0; t < 80; t++) {
        if (conn.store.threadFor('test', 'r$t') != null) remainingThreads++;
      }
      expect(remainingThreads, lessThanOrEqualTo(64));
      expect(conn.store.threadFor('test', 'r79'), isNotNull);
      expect(conn.store.threadFor('test', 'r0'), isNull);
    });
  });

  group('truncate coalescing', () {
    test(
      'defers within the window, runs after it, forces on hard cap and stays bounded',
      () {
        var t = DateTime(2026, 1, 1, 12);
        Map<String, List<TwitchMessage>> fresh() =>
            <String, List<TwitchMessage>>{
              'test': List.generate(
                11,
                (i) => _msg('m${10 - i}', 'msg ${10 - i}'),
              ),
            };

        var msgs = fresh();
        var conn = _makeConn(
          channelMessages: msgs,
          maxMessages: 10,
          truncateNow: () => t,
        );
        conn.store.truncateChannel('test', maxMessages: 10);
        t = t.add(const Duration(milliseconds: 100));
        conn.onMessage(_msg('new1', 'new one'));
        expect(msgs['test']!.length, 11);

        t = DateTime(2026, 1, 1, 12);
        msgs = fresh();
        conn = _makeConn(
          channelMessages: msgs,
          maxMessages: 10,
          truncateNow: () => t,
        );
        conn.store.truncateChannel('test', maxMessages: 10);
        t = t.add(const Duration(milliseconds: 300));
        conn.onMessage(_msg('new1', 'new one'));
        expect(msgs['test']!.length, 10);

        t = DateTime(2026, 1, 1, 12);
        msgs = fresh();
        conn = _makeConn(
          channelMessages: msgs,
          maxMessages: 10,
          truncateNow: () => t,
        );
        conn.store.truncateChannel('test', maxMessages: 10);
        t = t.add(const Duration(milliseconds: 100));
        for (var i = 1; i <= 11; i++) {
          conn.onMessage(_msg('b$i', 'burst $i'));
        }
        expect(msgs['test']!.length, 10);

        t = DateTime(2026, 1, 1, 12);
        msgs = fresh();
        conn = _makeConn(
          channelMessages: msgs,
          maxMessages: 10,
          truncateNow: () => t,
        );
        conn.store.truncateChannel('test', maxMessages: 10);
        t = t.add(const Duration(milliseconds: 100));
        for (var i = 1; i <= 4; i++) {
          conn.onMessage(_msg('b$i', 'burst $i'));
        }
        expect(msgs['test']!.length, 14);
      },
    );
  });

  group('badge parsing', () {
    for (final (name, tags, expectBadges) in [
      (
        'parses badges from IRC badges tag on own message',
        {
          'badges': 'broadcaster/1,subscriber/12',
          'display-name': 'TestUser',
          'user-id': '12345',
          'id': 'msg1',
        },
        true,
      ),
      (
        'badges is null when badges tag is absent',
        {'display-name': 'TestUser', 'user-id': '12345', 'id': 'msg2'},
        false,
      ),
    ]) {
      test(name, () {
        final msgs = <String, List<TwitchMessage>>{'test': []};
        final conn = _makeConn(channelMessages: msgs, maxMessages: 100);
        conn.onOwnIrcMessage(
          IrcMessage(
            tags: tags,
            prefix: 'testuser!testuser@testuser.tmi.twitch.tv',
            command: 'PRIVMSG',
            params: ['#test'],
            trailing: 'hello',
          ),
        );
        final msg = msgs['test']!.first;
        if (expectBadges) {
          expect(msg.badges, isNotNull, reason: name);
          expect(msg.badges!.length, 2, reason: name);
          expect(msg.badges![0].setId, 'broadcaster', reason: name);
        } else {
          expect(msg.badges, isNull, reason: name);
        }
      });
    }
  });

  group('own /me messages', () {
    test(
      'strips ACTION wrapper, sets isAction and adjusts emote positions',
      () {
        var msgs = <String, List<TwitchMessage>>{'test': []};
        var conn = _makeConn(channelMessages: msgs, maxMessages: 100);
        conn.onOwnIrcMessage(
          IrcMessage(
            tags: {
              'display-name': 'TestUser',
              'user-id': '12345',
              'id': 'msg-me',
            },
            prefix: 'testuser!testuser@testuser.tmi.twitch.tv',
            command: 'PRIVMSG',
            params: ['#test'],
            trailing: '\x01ACTION waves at chat\x01',
          ),
        );
        expect(msgs['test']!.first.text, 'waves at chat');
        expect(msgs['test']!.first.isAction, isTrue);

        msgs = <String, List<TwitchMessage>>{'test': []};
        conn = _makeConn(channelMessages: msgs, maxMessages: 100);
        conn.onOwnIrcMessage(
          IrcMessage(
            tags: {
              'display-name': 'TestUser',
              'user-id': '12345',
              'id': 'msg-me2',
              'emotes': '123:0-7',
            },
            prefix: 'testuser!testuser@testuser.tmi.twitch.tv',
            command: 'PRIVMSG',
            params: ['#test'],
            trailing: '\x01ACTION PogChamp hi\x01',
          ),
        );
        final msg = msgs['test']!.first;
        expect(msg.text, 'PogChamp hi');
        expect(msg.emotePositions!.single.emoteCode, 'PogChamp');
        expect(msg.emotePositions!.single.startIndex, 0);
        expect(msg.emotePositions!.single.endIndex, 8);
      },
    );
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

  group('account switch', () {
    var helixChatSends = 0;
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      helixChatSends = 0;
    });

    // Hermetic Helix stubs: /validate echoes the token's owner, chat sends
    // succeed, user lookups resolve.
    http.Response stub(http.Request request) {
      final url = request.url.toString();
      if (url.contains('oauth2/validate')) {
        final isBob = request.headers['Authorization'] == 'Bearer token_b';
        return http.Response(
          isBob
              ? '{"login":"bob","user_id":"222","expires_in":60}'
              : '{"login":"alice","user_id":"111","expires_in":60}',
          200,
        );
      }
      if (url.contains('/helix/chat/messages')) {
        helixChatSends++;
        return http.Response(
          '{"data":[{"is_sent":true,"message_id":"mid-1"}]}',
          200,
        );
      }
      if (url.contains('/helix/users')) {
        return http.Response(
          '{"data":[{"id":"999","login":"test","display_name":"Test"}]}',
          200,
        );
      }
      return http.Response('{}', 200);
    }

    test('switch drops old joins and per-account state, and takes the full '
        'connect edge under the new identity', () async {
      final irc = _RecordingIrc();
      final auth = TwitchAuth();
      auth.setCredentials(accessToken: 'token_a');
      auth.setUser('alice', '111');
      auth.setCredentials(accessToken: 'token_b');
      auth.setUser('bob', '222');
      await auth.switchTo('alice');

      var reconnects = 0;
      final system = <String>[];
      final store = ChatStore(
        channels: ['test'],
        channelMessages: {},
        messageKeys: {},
        chatStatus: {},
        channelsWithUnread: {},
        channelsWithUnreadMentions: {},
        unreadMentionsPerChannel: {},
        historyLoaded: {},
        channelsEmotesResolved: {},
        channelUserIds: {'test': '999'},
        lastSentWireText: {},
      );
      final readConn = _NoopIrcRead();
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        ircRead: readConn,
        onReconnected: () => reconnects++,
        onSystemMessage: (c, t, {Color? accent, String? messageId}) =>
            system.add(t),
        currentUserLogin: 'alice',
        auth: auth,
        store: store,
        client: http_testing.MockClient((request) async => stub(request)),
      );
      await conn.connect();

      // First connect edge: no backfill, one Connected line. "Connected"
      // waits for BOTH sockets' JOIN confirmations now.
      irc.emitConnected();
      irc.handleLine('@room-id=1 :tmi.twitch.tv ROOMSTATE #test');
      readConn.confirmJoin('test');
      await Future<void>.delayed(Duration.zero);
      expect(reconnects, 0);
      expect(system.where((t) => t == 'Connected'), hasLength(1));

      // Alice's session state accrues.
      irc.handleLine('@room-id=1 :tmi.twitch.tv ROOMSTATE #test');
      await Future<void>.delayed(Duration.zero);
      readConn.selfBadges['test'] = {'moderator'};
      store.lastSentWireText['test'] = 'seed';
      await conn.doSendMessage('hi', 'test');
      expect(irc.sent.single.$1, 'alice', reason: 'baseline send as alice');

      // Switch to bob the way HomeScreen drives it.
      conn.session.login = null;
      conn.session.userId = null;
      await auth.switchTo('bob');
      await conn.connect();

      expect(irc.username, 'bob');
      expect(
        readConn.selfBadges,
        isEmpty,
        reason: "alice's badges must not bypass bob's slow mode",
      );
      expect(store.lastSentWireText, isEmpty);

      // The new socket is up but #test is not re-joined yet. The write socket
      // never JOINs, so a send rides it directly as bob (no Helix, no JOIN).
      irc.emitConnected();
      await Future<void>.delayed(Duration.zero);
      await conn.doSendMessage('hello', 'test');
      expect(irc.sent, hasLength(2), reason: 'send rides the write IRC socket');
      expect(irc.sent.last.$1, 'bob');
      expect(helixChatSends, 0, reason: 'chat send must never use Helix');

      // The deliberate swap still takes the full connect edge: backfill +
      // a fresh Connected line once bob's JOIN confirms on both sockets.
      irc.handleLine('@room-id=1 :tmi.twitch.tv ROOMSTATE #test');
      readConn.confirmJoin('test');
      await Future<void>.delayed(Duration.zero);
      expect(reconnects, 1);
      expect(system.where((t) => t == 'Connected'), hasLength(2));

      conn.dispose();
    });

    test(
      're-subscribe clears stale readiness so the input stays disabled',
      () async {
        final irc = _RecordingIrc();
        final auth = TwitchAuth();
        auth.setUser('alice', '111');
        auth.setCredentials(accessToken: 'token_a');
        final readConn = _NoopIrcRead();
        final store = ChatStore(
          channels: ['test'],
          channelMessages: {},
          messageKeys: {},
          chatStatus: {},
          channelsWithUnread: {},
          channelsWithUnreadMentions: {},
          unreadMentionsPerChannel: {},
          historyLoaded: {},
          channelsEmotesResolved: {},
          channelUserIds: {'test': '999'},
          lastSentWireText: {},
        );
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          ircRead: readConn,
          currentUserLogin: 'alice',
          auth: auth,
          store: store,
          onReconnected: () {},
          client: http_testing.MockClient(
            (request) async => http.Response(
              '{"data":[{"id":"999","login":"test","display_name":"Test"}]}',
              200,
            ),
          ),
        );
        await conn.connect();
        irc.emitConnected();
        irc.handleLine('@room-id=1 :tmi.twitch.tv ROOMSTATE #test');
        readConn.confirmJoin('test');
        await Future<void>.delayed(Duration.zero);
        expect(
          conn.isChannelChatReady('test'),
          isTrue,
          reason: 'ready once the read JOIN confirms',
        );

        // Re-subscribe must drop stale membership so the composer stays disabled
        // during the pending re-join instead of letting a PRIVMSG vanish.
        await conn.subscribeChannel('test');
        expect(
          conn.isChannelChatReady('test'),
          isFalse,
          reason: 'stale readiness cleared on re-subscribe',
        );

        conn.dispose();
      },
    );

    test(
      'forceReconnect starts a connection when the socket is already down',
      () async {
        final irc = _RecordingIrc();
        // Simulate a socket that died: creds present but no live channel.
        irc.username = 'alice';
        irc.token = 'token';
        expect(irc.isConnected, isFalse);
        final before = irc.connectCalls;
        irc.forceReconnect();
        expect(
          irc.connectCalls,
          greaterThan(before),
          reason: 'manual reconnect must restart the loop when already down',
        );
        irc.dispose();
      },
    );

    test('read-socket auth failure triggers re-auth', () async {
      final irc = _RecordingIrc();
      final auth = TwitchAuth();
      auth.setUser('alice', '111');
      auth.setCredentials(accessToken: 'token_a');
      final readConn = _NoopIrcRead();
      final store = ChatStore(
        channels: ['test'],
        channelMessages: {},
        messageKeys: {},
        chatStatus: {},
        channelsWithUnread: {},
        channelsWithUnreadMentions: {},
        unreadMentionsPerChannel: {},
        historyLoaded: {},
        channelsEmotesResolved: {},
        channelUserIds: {'test': '999'},
        lastSentWireText: {},
      );
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        ircRead: readConn,
        currentUserLogin: 'alice',
        auth: auth,
        store: store,
        onReconnected: () {},
        client: http_testing.MockClient(
          (request) async => http.Response(
            '{"data":[{"id":"999","login":"test","display_name":"Test"}]}',
            200,
          ),
        ),
      );
      await conn.connect();
      readConn.handleLine(
        ':tmi.twitch.tv NOTICE * :Login authentication failed',
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        auth.isActiveExpired,
        isTrue,
        reason: 'read-side login failure must mark the token expired',
      );
      conn.dispose();
    });

    test('foreground watchdog re-arms a dead socket loop', () async {
      final irc = _RecordingIrc();
      final auth = TwitchAuth();
      auth.setUser('alice', '111');
      auth.setCredentials(accessToken: 'token_a');
      final readConn = _NoopIrcRead();
      final store = ChatStore(
        channels: ['test'],
        channelMessages: {},
        messageKeys: {},
        chatStatus: {},
        channelsWithUnread: {},
        channelsWithUnreadMentions: {},
        unreadMentionsPerChannel: {},
        historyLoaded: {},
        channelsEmotesResolved: {},
        channelUserIds: {'test': '999'},
        lastSentWireText: {},
      );
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        ircRead: readConn,
        currentUserLogin: 'alice',
        auth: auth,
        store: store,
        onReconnected: () {},
        client: http_testing.MockClient(
          (request) async => http.Response(
            '{"data":[{"id":"999","login":"test","display_name":"Test"}]}',
            200,
          ),
        ),
      );
      await conn.connect();
      // Simulate a socket whose reconnect loop died (no follow-up connect):
      // the only thing that can revive it is reconnectIfNecessary, which the
      // foreground watchdog invokes on its timer.
      irc.emitDisconnected();
      final before = irc.connectCalls;
      conn.reconnectIfNecessary();
      expect(
        irc.connectCalls,
        greaterThan(before),
        reason: 'watchdog must reconnect a socket whose loop died',
      );
      conn.dispose();
    });

    test('join failure wording never claims nonexistence', () {
      final messages = <String>[];
      final setup = ChatChannelSetup(
        twitchApi: TwitchApi(client: http.Client()),
        eventSub: EventSubService(),
        irc: IrcService(),
        ircRead: IrcReadService(),
        badgeService: TwitchBadgeService(),
        emoteManager: EmoteManager(),
        twitchAuth: TwitchAuth(),
        userStore: UserStore(),
        store: ChatStore(
          channels: [],
          channelMessages: {},
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
        onSystemMessage: (c, t, {Color? accent, String? messageId}) =>
            messages.add(t),
        connectionStateNotifier: ValueNotifier(0),
        ensureCurrentUser: (_) async => null,
      );
      setup.handleJoinFailed(
        IrcJoinFailureEvent(
          channel: 'foo',
          reason: JoinFailureReason.noResponse,
        ),
      );
      setup.handleJoinFailed(
        IrcJoinFailureEvent(
          channel: 'bar',
          reason: JoinFailureReason.suspended,
        ),
      );
      expect(messages, contains('Could not connect to channel #foo'));
      expect(
        messages,
        contains('Could not join #bar: the channel is suspended or deleted.'),
      );
      expect(messages.join(' '), isNot(contains('does not exist')));
      setup.dispose();
    });

    test('write-socket send rejections surface as system messages', () async {
      final irc = _RecordingIrc();
      final auth = TwitchAuth();
      auth.setUser('alice', '111');
      auth.setCredentials(accessToken: 'token_a');
      final system = <String>[];
      final readConn = _NoopIrcRead();
      final store = ChatStore(
        channels: ['test'],
        channelMessages: {},
        messageKeys: {},
        chatStatus: {},
        channelsWithUnread: {},
        channelsWithUnreadMentions: {},
        unreadMentionsPerChannel: {},
        historyLoaded: {},
        channelsEmotesResolved: {},
        channelUserIds: {'test': '999'},
        lastSentWireText: {},
      );
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        ircRead: readConn,
        onSystemMessage: (c, t, {Color? accent, String? messageId}) =>
            system.add(t),
        currentUserLogin: 'alice',
        auth: auth,
        store: store,
        onReconnected: () {},
        client: http_testing.MockClient(
          (request) async => http.Response(
            '{"data":[{"id":"999","login":"test","display_name":"Test"}]}',
            200,
          ),
        ),
      );
      await conn.connect();
      // Twitch replies to a PRIVMSG with a NOTICE on the write socket.
      irc.handleLine(':tmi.twitch.tv NOTICE #test :This room is in slow mode.');
      await Future<void>.delayed(Duration.zero);
      expect(
        system,
        contains('This room is in slow mode.'),
        reason: 'send rejection NOTICE must be shown',
      );
      conn.dispose();
    });

    test('logging out tears down the live EventSub session', () async {
      final eventSub = _LiveEventSub();
      final auth = TwitchAuth();
      auth.accessToken = 'token_a';
      final conn = _makeReconnectConn(
        eventSub: eventSub,
        irc: _TestIrc(),
        onReconnected: () {},
        currentUserLogin: 'alice',
        auth: auth,
      );
      await conn.connect();
      expect(eventSub.connectCalls, 1);
      expect(eventSub.disconnectCalls, 0);

      await auth.clear();
      await conn.connect();

      expect(
        eventSub.disconnectCalls,
        1,
        reason: 'the departed account must not keep receiving events',
      );

      conn.dispose();
    });
  });

  group('read socket fatal auth', () {
    for (final (name, notice, fatal) in [
      (
        'NOTICE * :Login authentication failed stops the retry loop',
        ':tmi.twitch.tv NOTICE * :Login authentication failed',
        true,
      ),
      (
        'other NOTICE * messages do not stop the read loop',
        ':tmi.twitch.tv NOTICE * :Some other notice',
        false,
      ),
    ]) {
      test(name, () {
        fakeAsync((async) {
          final socket = FakeWebSocketChannel();
          final service = _LoopIrcRead(socket);
          final statuses = <IrcConnectionStatus>[];
          service.onStatus.listen(statuses.add);
          service.connect(username: 'alice', accessToken: 'token');
          async.flushMicrotasks();
          final attemptsBefore = service.openAttempts;
          socket.push(notice);
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 5));
          if (fatal) {
            expect(service.openAttempts, attemptsBefore, reason: name);
            expect(
              statuses.last,
              IrcConnectionStatus.disconnected,
              reason: name,
            );
            expect(service.isConnected, isFalse, reason: name);
          } else {
            expect(service.openAttempts, 1, reason: name);
            expect(service.isConnected, isTrue, reason: name);
          }
          service.dispose();
          socket.dispose();
        });
      });
    }
  });

  group('reconnect callback', () {
    test(
      'fires on IRC reconnect but not on first connect or repeated status',
      () async {
        var calls = 0;
        final irc = _TestIrc();
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          onReconnected: () => calls++,
        );
        await conn.connect();
        irc.emitConnected();
        expect(calls, 0, reason: 'first connect must not trigger a re-fetch');
        irc.emitConnected();
        expect(calls, 0, reason: 'repeated status must not fire');
        irc.emitDisconnected();
        irc.emitConnected();
        expect(calls, 1, reason: 'reconnect must trigger a re-fetch');
        conn.dispose();
      },
    );
  });

  group('USERNOTICE routing', () {
    test('announcement renders label plus child message', () async {
      final irc = _TestIrc();
      final ircRead = _TestIrcRead();
      final systemMessages = <(String, String, Color?)>[];
      final channelMessages = <String, List<TwitchMessage>>{};
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        ircRead: ircRead,
        onReconnected: () {},
        channelMessages: channelMessages,
        onSystemMessage: (c, t, {Color? accent, String? messageId}) {
          systemMessages.add((c, t, accent));
        },
      );
      await conn.connect();
      ircRead.emitConnected();

      // Real captured USERNOTICE line (BLUE announcement).
      ircRead.handleLine(
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

    for (final (name, line, accent, hasChild) in [
      (
        'missing color falls back to PRIMARY',
        '@msg-id=announcement;login=mm2pl;display-name=Mm2PL;system-msg=;'
            ':tmi.twitch.tv USERNOTICE #test :hi',
        const Color(0xFF9146FF),
        true,
      ),
      (
        'announcement without text renders only the label',
        '@msg-id=announcement;msg-param-color=ORANGE;login=mm2pl;'
            'display-name=Mm2PL;system-msg=;'
            ':tmi.twitch.tv USERNOTICE #test',
        const Color(0xFFFF6F00),
        false,
      ),
    ]) {
      test(name, () async {
        final irc = _TestIrc();
        final ircRead = _TestIrcRead();
        final systemMessages = <(String, String, Color?)>[];
        final channelMessages = <String, List<TwitchMessage>>{};
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          ircRead: ircRead,
          onReconnected: () {},
          channelMessages: channelMessages,
          onSystemMessage: (c, t, {Color? accent, String? messageId}) {
            systemMessages.add((c, t, accent));
          },
        );
        await conn.connect();
        ircRead.emitConnected();
        ircRead.handleLine(line);
        expect(systemMessages.single.$2, 'Announcement', reason: name);
        expect(systemMessages.single.$3, accent, reason: name);
        if (hasChild) {
          expect(
            channelMessages['test']!.first.systemAccent,
            accent,
            reason: name,
          );
        } else {
          expect(channelMessages['test'], isNull, reason: name);
        }
        conn.dispose();
      });
    }

    test('resub with text renders label plus child message', () async {
      final irc = _TestIrc();
      final ircRead = _TestIrcRead();
      final systemMessages = <(String, String, Color?)>[];
      final channelMessages = <String, List<TwitchMessage>>{};
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        ircRead: ircRead,
        onReconnected: () {},
        channelMessages: channelMessages,
        onSystemMessage: (c, t, {Color? accent, String? messageId}) {
          systemMessages.add((c, t, accent));
        },
      );
      await conn.connect();
      ircRead.emitConnected();

      ircRead.handleLine(
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
      final ircRead = _TestIrcRead();
      final systemMessages = <(String, String, Color?)>[];
      final channelMessages = <String, List<TwitchMessage>>{};
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        ircRead: ircRead,
        onReconnected: () {},
        channelMessages: channelMessages,
        onSystemMessage: (c, t, {Color? accent, String? messageId}) {
          systemMessages.add((c, t, accent));
        },
      );
      await conn.connect();
      ircRead.emitConnected();

      ircRead.handleLine(
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

    for (final (name, line, text) in [
      (
        'watch streak notice highlights with the purple accent',
        '@msg-id=viewermilestone;system-msg=ronni\\shas\\sreached\\sa\\swatch\\sstreak\\sof\\s3!;login=ronni;display-name=ronni;:tmi.twitch.tv USERNOTICE #test',
        'ronni has reached a watch streak of 3!',
      ),
      (
        'bits badge tier notice highlights with the purple accent',
        '@msg-id=bitsbadgetier;system-msg=ronni\\ssent\\s100\\sbits!;login=ronni;display-name=ronni;:tmi.twitch.tv USERNOTICE #test',
        null,
      ),
      (
        'non-announcement notices highlight with the purple accent',
        '@msg-id=raid;system-msg=ronni\\sis\\sraiding\\sxqc!;login=ronni;display-name=ronni;:tmi.twitch.tv USERNOTICE #test',
        'ronni is raiding xqc!',
      ),
    ]) {
      test(name, () async {
        final irc = _TestIrc();
        final ircRead = _TestIrcRead();
        final systemMessages = <(String, String, Color?)>[];
        final channelMessages = <String, List<TwitchMessage>>{};
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          ircRead: ircRead,
          onReconnected: () {},
          channelMessages: channelMessages,
          onSystemMessage: (c, t, {Color? accent, String? messageId}) {
            systemMessages.add((c, t, accent));
          },
        );
        await conn.connect();
        ircRead.emitConnected();
        ircRead.handleLine(line);
        expect(systemMessages, hasLength(1), reason: name);
        expect(systemMessages[0].$3, const Color(0xFF9146FF), reason: name);
        if (text != null) {
          expect(systemMessages[0].$2, text, reason: name);
        }
        expect(channelMessages['test'], isNull, reason: name);
        conn.dispose();
      });
    }
  });

  group('IRC channel clear', () {
    test('renders cleared message and marks all messages deleted', () async {
      final irc = _TestIrc();
      final ircRead = _TestIrcRead();
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
        ircRead: ircRead,
        onReconnected: () {},
        channelMessages: channelMessages,
        onSystemMessage: (c, t, {Color? accent, String? messageId}) {
          systemMessages.add((c, t, accent));
        },
      );
      await conn.connect();
      irc.emitConnected();
      ircRead.emitConnected();

      ircRead.handleLine(':tmi.twitch.tv CLEARCHAT #test');

      expect(systemMessages, hasLength(1));
      expect(systemMessages[0].$2, 'Chat was cleared.');
      expect(channelMessages['test']![0].deleted, isTrue);
      expect(channelMessages['test']![1].deleted, isTrue);

      conn.dispose();
    });
  });

  group('ROOMSTATE splash', () {
    test('updates the chat status splash and merges partial updates', () async {
      final irc = _TestIrc();
      final ircRead = _TestIrcRead();
      final chatStatus = <String, String>{};
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        ircRead: ircRead,
        onReconnected: () {},
        chatStatus: chatStatus,
      );
      await conn.connect();
      ircRead.emitConnected();

      ircRead.handleLine(
        '@emote-only=1;followers-only=30;r9k=1;room-id=1;slow=10;subs-only=0 '
        ':tmi.twitch.tv ROOMSTATE #test',
      );
      expect(
        chatStatus['test'],
        'Slow (10s) · Followers-only (30m) · Emote-only · Unique chat',
      );

      // Partial update: only slow mode changed.
      ircRead.handleLine('@room-id=1;slow=0 :tmi.twitch.tv ROOMSTATE #test');
      expect(
        chatStatus['test'],
        'Followers-only (30m) · Emote-only · Unique chat',
      );

      conn.dispose();
    });
  });

  group('send cooldowns', () {
    Future<(ChatConnectionManager, _TestIrcRead)> makeConn() async {
      final irc = _TestIrc();
      final ircRead = _TestIrcRead();
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        ircRead: ircRead,
        onReconnected: () {},
        channels: ['test'],
        currentUserLogin: 'viewer',
      );
      await conn.connect();
      ircRead.emitConnected();
      return (conn, ircRead);
    }

    for (final (name, badge, expectCooldown) in [
      ('slow mode arms a countdown after your own message', null, true),
      ('slow-exempt badges skip the slow-mode countdown', 'moderator', false),
    ]) {
      test(name, () async {
        final (conn, ircRead) = await makeConn();
        ircRead.handleLine('@room-id=1;slow=30 :tmi.twitch.tv ROOMSTATE #test');
        if (badge != null) {
          ircRead.selfBadges['test'] = {badge};
        }
        await conn.doSendMessage('hi', 'test');
        if (expectCooldown) {
          expect(
            conn.remainingSlowCooldown('test'),
            inInclusiveRange(25, 31),
            reason: name,
          );
        } else {
          expect(conn.remainingSlowCooldown('test'), isNull, reason: name);
        }
        conn.dispose();
      });
    }

    test('own timeout arms the countdown, other timeouts do not', () async {
      final (conn, ircRead) = await makeConn();

      ircRead.handleLine(
        '@ban-duration=60 :tmi.twitch.tv CLEARCHAT #test :forsen',
      );
      await Future<void>.delayed(Duration.zero);
      expect(conn.remainingSelfTimeout('test'), isNull);

      ircRead.handleLine(
        '@ban-duration=600 :tmi.twitch.tv CLEARCHAT #test :viewer',
      );
      await Future<void>.delayed(Duration.zero);
      expect(conn.remainingSelfTimeout('test'), inInclusiveRange(595, 601));
      conn.dispose();
    });

    test('the send grace outlives the raw timeout expiry', () async {
      final (conn, ircRead) = await makeConn();
      ircRead.handleLine(
        '@ban-duration=1 :tmi.twitch.tv CLEARCHAT #test :viewer',
      );
      await Future<void>.delayed(Duration.zero);
      expect(conn.remainingSelfTimeout('test'), inInclusiveRange(1, 2));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(conn.remainingSelfTimeout('test'), isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(conn.remainingSelfTimeout('test'), isNull);

      // An already-elapsed timeout clears instead of counting down.
      ircRead.handleLine(
        '@ban-duration=0 :tmi.twitch.tv CLEARCHAT #test :viewer',
      );
      await Future<void>.delayed(Duration.zero);
      expect(conn.remainingSelfTimeout('test'), isNull);

      // A successful own-message echo heals a stale self-timeout gate.
      ircRead.handleLine(
        '@ban-duration=600 :tmi.twitch.tv CLEARCHAT #test :viewer',
      );
      await Future<void>.delayed(Duration.zero);
      expect(conn.remainingSelfTimeout('test'), isNotNull);
      ircRead.emitOwnMessage(
        parseIrcMessage(
          ':viewer!viewer@viewer.tmi.twitch.tv PRIVMSG #test :hello',
        )!,
      );
      await Future<void>.delayed(Duration.zero);
      expect(conn.remainingSelfTimeout('test'), isNull);
      conn.dispose();
    });
  });

  group('reconnectIfNecessary', () {
    for (final (name, alive, connected) in [
      ('does not reconnect a healthy connection', true, true),
      ('forces a reconnect when checkAlive fails (zombie socket)', false, true),
      ('connects when the socket is missing entirely', true, false),
    ]) {
      test(name, () {
        fakeAsync((async) {
          final irc = _TestIrc();
          irc.alive = alive;
          final conn = _makeReconnectConn(
            eventSub: _NoopEventSub(),
            irc: irc,
            onReconnected: () {},
            currentUserLogin: 'testuser',
          );
          if (connected) {
            irc.connect(username: 'testuser', accessToken: 'token');
            irc.emitConnected();
          }
          conn.reconnectIfNecessary();
          async.flushMicrotasks();
          if (name.startsWith('does not')) {
            expect(irc.connectCalls, 1, reason: name);
          } else if (name.startsWith('forces')) {
            expect(irc.openAttempts, 1, reason: name);
            expect(irc.isConnected, isTrue, reason: name);
          } else {
            expect(irc.connectCalls, 1, reason: name);
          }
          conn.dispose();
        });
      });
    }

    for (final (name, stale, calls) in [
      ('reconnects a stale EventSub session on resume', true, 1),
      ('does not reconnect a healthy EventSub session on resume', false, 0),
    ]) {
      test(name, () {
        fakeAsync((async) {
          final irc = _TestIrc();
          irc.alive = true;
          final eventSub = _StaleEventSub(stale: stale);
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
          expect(eventSub.forceCalls, calls, reason: name);
          conn.dispose();
        });
      });
    }
  });

  group('read socket status', () {
    test(
      'read-side JOIN lag gates readiness until its ROOMSTATE lands',
      () async {
        final ircRead = _TestIrcRead();
        // A live read socket makes its per-channel JOIN required for readiness.
        ircRead.fakeConnected = true;
        ircRead.username = 'testuser';
        final irc = _TestIrc();
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          ircRead: ircRead,
          onReconnected: () {},
          channels: const ['test'],
          currentUserLogin: 'testuser',
        );

        await conn.connect();

        expect(conn.isChannelChatReady('test'), isFalse);

        // Write side confirms first: still not ready, the echo rides the read
        // socket and its JOIN has not landed yet.
        irc.handleLine('@room-id=1 :tmi.twitch.tv ROOMSTATE #test');
        await pumpEventQueue();
        expect(conn.isChannelChatReady('test'), isFalse);

        // The read socket's JOIN confirms: now the channel is fully usable.
        ircRead.confirmJoin('test');
        await pumpEventQueue();
        expect(conn.isChannelChatReady('test'), isTrue);

        conn.dispose();
      },
    );

    test('a dead read socket never gates an anonymous session', () async {
      final ircRead = _TestIrcRead();
      // fakeConnected stays false: no live read socket to wait for. The
      // session is anonymous, so there is nothing to echo and the read side
      // cannot gate readiness at all.
      final irc = _TestIrc();
      final conn = _makeReconnectConn(
        eventSub: _NoopEventSub(),
        irc: irc,
        ircRead: ircRead,
        onReconnected: () {},
        channels: const ['test'],
      );

      await conn.connect();
      irc.emitConnected();

      irc.handleLine('@room-id=1 :tmi.twitch.tv ROOMSTATE #test');
      await pumpEventQueue();
      expect(conn.isChannelChatReady('test'), isTrue);

      conn.dispose();
    });

    test(
      'read outage surfaces as Chat reconnecting then Reconnected and stays silent before any join',
      () {
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
            onSystemMessage: (c, t, {Color? accent, String? messageId}) =>
                messages.add((c, t)),
          );
          conn.connect();
          async.flushMicrotasks();
          ircRead.emitDisconnected();
          async.flushMicrotasks();
          expect(messages, contains(('test', 'Chat reconnecting...')));
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

          final empty = <(String, String)>[];
          final conn2 = _makeReconnectConn(
            eventSub: _NoopEventSub(),
            irc: _TestIrc(),
            ircRead: _TestIrcRead(),
            onReconnected: () {},
            channels: const [],
            currentUserLogin: 'testuser',
            onSystemMessage: (c, t, {Color? accent, String? messageId}) =>
                empty.add((c, t)),
          );
          conn2.connect();
          async.flushMicrotasks();
          expect(empty, isEmpty);
          conn2.dispose();
        });
      },
    );
  });

  group('IRC emote-sets', () {
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    for (final (name, line, expectCall) in [
      (
        'forwards GLOBALUSERSTATE emote-sets to onUserEmoteSets',
        '@emote-sets=0,123456789 :tmi.twitch.tv GLOBALUSERSTATE',
        true,
      ),
      (
        'does not call onUserEmoteSets when tag is missing',
        '@badges=staff/1 :tmi.twitch.tv GLOBALUSERSTATE',
        false,
      ),
    ]) {
      test(name, () async {
        var called = false;
        final received = <(String?, List<String>)>[];
        final irc = _TestIrc();
        final ircRead = _TestIrcRead();
        final conn = _makeReconnectConn(
          eventSub: _NoopEventSub(),
          irc: irc,
          ircRead: ircRead,
          onReconnected: () {},
          onUserEmoteSets: (channel, ids) async {
            called = true;
            received.add((channel, ids));
          },
        );
        await conn.connect();
        await flush();
        ircRead.handleLine(line);
        irc.handleLine(line);
        await flush();
        expect(called, expectCall, reason: name);
        if (expectCall) {
          expect(received.single.$2, <String>['0', '123456789'], reason: name);
        }
        conn.dispose();
      });
    }
  });

  group('message emote precache', () {
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
      badgeService.resetCaches();
    });

    test(
      'resolves login and display name after avatar fetch and returns null before it',
      () async {
        expect(badgeService.resolveChannelLogin('1234'), isNull);
        expect(badgeService.resolveChannelDisplayName('1234'), isNull);
        final auth = TwitchAuth()..accessToken = 'fake-token';
        await badgeService.fetchChannelAvatar(auth, '1234');
        expect(badgeService.resolveChannelLogin('1234'), 'forsen');
        expect(badgeService.resolveChannelDisplayName('1234'), 'Forsen');
        expect(badgeService.version, greaterThan(0));
      },
    );
  });

  group('RecentMessagesService', () {
    const privmsgLine =
        '@rm-received-ts=1566417979914;historical=1;id=3c33033a;'
        'display-name=Alice;color=#9ACD32;user-id=42239452 '
        ':alice!alice@alice.tmi.twitch.tv PRIVMSG #test :hello world';

    http.Response okBody() => http.Response(
      jsonEncode({
        'messages': [privmsgLine],
        'error': null,
        'error_code': null,
      }),
      200,
    );

    group('error handling', () {
      test(
        '200 with channel_not_joined still parses whatever history exists',
        () async {
          final calls = <Uri>[];
          final service = RecentMessagesService(
            client: MockClient((request) async {
              calls.add(request.url);
              return http.Response(
                jsonEncode({
                  'messages': [privmsgLine],
                  'error':
                      'The bot is currently not joined to this channel '
                      '(in progress or failed previously)',
                  'error_code': 'channel_not_joined',
                }),
                200,
              );
            }),
          );

          final messages = await service.fetchRecent('test');

          expect(calls, hasLength(1), reason: 'informational error: no mirror');
          expect(messages, hasLength(1));
          expect(messages.single.text, 'hello world');
        },
      );

      test(
        'maps definitive channel errors without trying the mirror',
        () async {
          const cases = [
            (
              400,
              'invalid_channel_login',
              'Invalid channel login `this_is_wrong`',
              'this_is_wrong',
              'Invalid channel name',
            ),
            (
              403,
              'channel_ignored',
              'The channel login `x` is excluded from this service',
              'x',
              'History unavailable: channel excluded from the history service',
            ),
          ];
          for (final (status, code, error, channel, message) in cases) {
            final calls = <Uri>[];
            final service = RecentMessagesService(
              client: MockClient((request) async {
                calls.add(request.url);
                return http.Response(
                  jsonEncode({
                    'status': status,
                    'error': error,
                    'error_code': code,
                  }),
                  status,
                );
              }),
            );

            await expectLater(
              service.fetchRecent(channel),
              throwsA(
                isA<RecentMessagesException>()
                    .having((e) => e.message, 'message', message)
                    .having((e) => e.definitive, 'definitive', isTrue),
              ),
              reason: 'code: $code',
            );
            expect(calls, hasLength(1), reason: 'definitive error: no mirror');
          }
        },
      );

      test(
        'falls back on server errors and fails clean when all fail',
        () async {
          final fallback = RecentMessagesService(
            client: MockClient((request) async {
              if (request.url.host.contains('robotty')) {
                return http.Response('internal error', 500);
              }
              return okBody();
            }),
          );

          final messages = await fallback.fetchRecent('test');
          expect(messages.single.text, 'hello world');

          final generic = RecentMessagesService(
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({'error_code': 'something_new'}),
                503,
              ),
            ),
          );

          // 503 is not definitive: the mirror also fails, surfacing the generic
          // message from whichever attempt threw last.
          await expectLater(
            generic.fetchRecent('test'),
            throwsA(
              isA<RecentMessagesException>().having(
                (e) => e.message,
                'message',
                'Failed to load chat history',
              ),
            ),
          );
        },
      );
    });

    group('provider modes', () {
      test(
        'queries only the selected provider in single provider modes',
        () async {
          final robottyCalls = <Uri>[];
          final robotty = RecentMessagesService(
            config: RecentMessagesConfig(mode: RecentMessagesMode.robotty),
            client: MockClient((request) async {
              robottyCalls.add(request.url);
              return http.Response('internal error', 500);
            }),
          );
          await expectLater(
            robotty.fetchRecent('test'),
            throwsA(isA<RecentMessagesException>()),
          );
          expect(robottyCalls, hasLength(1));
          expect(robottyCalls.single.host, contains('robotty'));

          final zneixCalls = <Uri>[];
          final zneix = RecentMessagesService(
            config: RecentMessagesConfig(mode: RecentMessagesMode.zneix),
            client: MockClient((request) async {
              zneixCalls.add(request.url);
              if (request.url.host.contains('robotty')) {
                fail('robotty should not be queried in zneix-only mode');
              }
              return okBody();
            }),
          );
          final zneixMessages = await zneix.fetchRecent('test');
          expect(zneixMessages.single.text, 'hello world');
          expect(zneixCalls, hasLength(1));
          expect(zneixCalls.single.host, contains('zneix'));

          final customCalls = <Uri>[];
          const customUrl = 'https://custom.example.com/api/v2/recent-messages';
          final custom = RecentMessagesService(
            config: RecentMessagesConfig(
              mode: RecentMessagesMode.custom,
              customUrl: customUrl,
            ),
            client: MockClient((request) async {
              customCalls.add(request.url);
              if (!request.url.toString().startsWith(customUrl)) {
                fail('only the custom URL should be queried');
              }
              return okBody();
            }),
          );
          final customMessages = await custom.fetchRecent('test');
          expect(customMessages.single.text, 'hello world');
          expect(customCalls, hasLength(1));
        },
      );

      test('auto tries both providers before giving up', () async {
        final calls = <Uri>[];
        final service = RecentMessagesService(
          client: MockClient((request) async {
            calls.add(request.url);
            return http.Response(jsonEncode({'error_code': 'boom'}), 503);
          }),
        );
        await expectLater(
          service.fetchRecent('test'),
          throwsA(isA<RecentMessagesException>()),
        );
        expect(calls, hasLength(2));
        expect(calls[0].host, contains('robotty'));
        expect(calls[1].host, contains('zneix'));
      });
    });
  });
}
