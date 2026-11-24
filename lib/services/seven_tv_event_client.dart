import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../util/connectivity.dart';
import 'emote_providers/seven_tv_emotes.dart';
import '../util/constants.dart';
import '../util/log.dart';
import '../util/socket_loop.dart';
import '../util/data_usage.dart';

class SevenTvEmoteUpdateEvent {
  final String emoteSetId;
  final List<SevenTvAddedEmote> added;
  final List<SevenTvRemovedEmote> removed;
  final List<SevenTvRenamedEmote> renamed;
  final String? actor;

  const SevenTvEmoteUpdateEvent({
    required this.emoteSetId,
    this.added = const [],
    this.removed = const [],
    this.renamed = const [],
    this.actor,
  });
}

class SevenTvAddedEmote {
  final String id;
  final String name;
  final Map<String, dynamic> raw;

  const SevenTvAddedEmote({
    required this.id,
    required this.name,
    required this.raw,
  });
}

class SevenTvRemovedEmote {
  final String id;
  final String name;

  const SevenTvRemovedEmote({required this.id, required this.name});
}

class SevenTvRenamedEmote {
  final String id;
  final String oldName;
  final String newName;

  /// Original name when [newName] is an alias, null when they match.
  final String? baseName;

  const SevenTvRenamedEmote({
    required this.id,
    required this.oldName,
    required this.newName,
    this.baseName,
  });
}

class SevenTvUserUpdate {
  final String userId;
  final String newEmoteSetId;
  final String oldEmoteSetId;
  final int connectionIndex;
  final String? actor;

  const SevenTvUserUpdate({
    required this.userId,
    required this.newEmoteSetId,
    required this.oldEmoteSetId,
    required this.connectionIndex,
    this.actor,
  });
}

class SevenTvCosmeticCreateEvent {
  final String cosmeticId;
  final String name;
  final String imageUrl;
  final String? tooltip;

  const SevenTvCosmeticCreateEvent({
    required this.cosmeticId,
    required this.name,
    required this.imageUrl,
    this.tooltip,
  });
}

class SevenTvEntitlementEvent {
  final String cosmeticId;

  /// Dispatch type: entitlement.create or entitlement.delete.
  final String kind;

  /// Cosmetic kind: PAINT, BADGE, or EMOTE_SET.
  final String cosmeticKind;
  final List<String> twitchUserIds;

  const SevenTvEntitlementEvent({
    required this.cosmeticId,
    required this.kind,
    required this.cosmeticKind,
    required this.twitchUserIds,
  });
}

/// A personal 7TV emote set announced over the socket. Contents arrive via
/// later emote_set.update dispatches or a one-time REST fill.
class SevenTvPersonalSetEvent {
  final String setId;

  const SevenTvPersonalSetEvent({required this.setId});
}

/// Why a 7TV emote set is subscribed. Channel and viewer sets outlive the
/// foreign LRU; a set is released only when every owner lets it go.
enum SevenTvEmoteSetOwnerKind { channel, viewer, foreign }

class SevenTvEmoteSetOwner {
  const SevenTvEmoteSetOwner._(this.kind, this.id);

  const SevenTvEmoteSetOwner.channel(String id)
    : this._(SevenTvEmoteSetOwnerKind.channel, id);

  const SevenTvEmoteSetOwner.viewer(String id)
    : this._(SevenTvEmoteSetOwnerKind.viewer, id);

  const SevenTvEmoteSetOwner.foreign(String id)
    : this._(SevenTvEmoteSetOwnerKind.foreign, id);

  final SevenTvEmoteSetOwnerKind kind;
  final String id;

  _EmoteSetOwnerKey get _key => (kind: kind, id: id);
}

typedef _EmoteSetOwnerKey = ({SevenTvEmoteSetOwnerKind kind, String id});

enum SevenTvEventStatus { connected, disconnected }

enum _SubscriptionSend { sent, failed, skipped }

class SevenTvEventClient {
  static const _wsUrl = 'wss://events.7tv.io/v3';
  static const _connectTimeout = Duration(seconds: 10);
  static const _noReconnectCloseCodes = {4001, 4002, 4003, 4004, 4009, 4010};
  static const _reconnectMinDelay = Duration(seconds: 1);
  static const _rateLimitCloseCode = 4005;
  static const _rateLimitMinSeconds = 30;
  static const _rateLimitMaxSeconds = 600;
  static const _maxPendingEmoteSets = 50;
  static const _channelFeedTypes = [
    'cosmetic.create',
    'entitlement.create',
    'entitlement.delete',
    // Personal-set creates/updates for grants in this channel (chatterino7
    // parity): the mapping arrives via entitlement.create, contents here.
    'emote_set.*',
  ];
  static const _healthyWindow = Duration(seconds: 30);
  static const _fatalRetryDelay = Duration(seconds: 2);
  // A reconnect that finishes inside this window is treated as a handoff, not
  // a missed-event gap. The v3 protocol sends no `s` field, so sequence
  // checks are opportunistic and never the only gate.
  static const _gapWindow = Duration(seconds: 5);

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _streamSub;
  Timer? _heartbeatTimer;
  int? _heartbeatInterval;
  DateTime _lastHeartbeat = DateTime.now();
  bool _handshakeComplete = false;
  bool _disposed = false;
  int? _fatalCloseCode;
  bool _rateLimitHit = false;
  bool _rateLimited = false;
  int _rateLimitFailures = 0;
  Timer? _rateLimitRetry;
  Timer? _helloTimer;
  Timer? _healthyTimer;
  Timer? _fatalRetry;

  DateTime? _sessionEndedAt;
  bool _hadEstablishedSession = false;
  bool _cleanReconnect = false;
  bool _gapEvidence = false;
  bool _gapEmitted = false;
  final _lastSequenceByType = <String, int>{};
  final _sequenceTrust = <String, int>{};

  // Completes when the serving socket ends, with how the loop goes on.
  Completer<SocketEnd>? _socketEnd;
  SocketRun? _run;
  late final SocketLoop _loop;

  final _pendingEmoteSets = <String>{};
  final _emoteSetOwners = <String, Set<_EmoteSetOwnerKey>>{};
  final _pendingUsers = <String>{};
  final _pendingChannels = <String>{};

  // Subscription identities sent on the current connection, plus acks. Keys
  // combine the type and condition, so a resend of the same object is one.
  final _sentSubscriptions = <String>{};
  final _ackedSubscriptions = <String>{};
  final _emoteSetSubscriptionKeys = <String, String>{};
  final _skippedSubscriptionKeys = <String>{};
  final _interruptedEmoteSets = <String>{};
  // True once a foreign set was dropped from the replay cap.
  bool _pendingSetsOverflowed = false;
  int? _subscriptionLimit;
  DateTime? _lastDispatch;
  final DateTime Function() _now;

  final _emoteSetUpdateCtrl =
      StreamController<SevenTvEmoteUpdateEvent>.broadcast(sync: true);
  final _userUpdateCtrl = StreamController<SevenTvUserUpdate>.broadcast(
    sync: true,
  );
  final _cosmeticCreateCtrl =
      StreamController<SevenTvCosmeticCreateEvent>.broadcast(sync: true);
  final _entitlementCtrl = StreamController<SevenTvEntitlementEvent>.broadcast(
    sync: true,
  );
  final _personalSetCtrl = StreamController<SevenTvPersonalSetEvent>.broadcast(
    sync: true,
  );
  final _statusCtrl = StreamController<SevenTvEventStatus>.broadcast(
    sync: true,
  );
  final _gapCtrl = StreamController<void>.broadcast(sync: true);

  Stream<SevenTvEmoteUpdateEvent> get onEmoteSetUpdate =>
      _emoteSetUpdateCtrl.stream;
  Stream<SevenTvUserUpdate> get onUserUpdate => _userUpdateCtrl.stream;
  Stream<SevenTvCosmeticCreateEvent> get onCosmeticCreate =>
      _cosmeticCreateCtrl.stream;
  Stream<SevenTvEntitlementEvent> get onEntitlement => _entitlementCtrl.stream;
  Stream<SevenTvPersonalSetEvent> get onPersonalSet => _personalSetCtrl.stream;
  Stream<SevenTvEventStatus> get onStatus => _statusCtrl.stream;

  /// Fires when a dispatch sequence proves events were missed on a live gap.
  Stream<void> get onGapEvidence => _gapCtrl.stream;

  /// Consumes the gap verdict for the socket that just completed hello.
  bool takeMissedEventGap() {
    final gap = _gapEvidence;
    _gapEvidence = false;
    return gap;
  }

  SevenTvEventClient({
    ConnectivityService? connectivityService,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _loop = SocketLoop(
      name: '7TV',
      attempt: _attempt,
      // The first retry waits a flat second, then 2^(n-2) capped 30s with
      // jitter.
      backoff: (failures) => failures == 1
          ? _reconnectMinDelay
          : applyReconnectJitter(
              Duration(seconds: min(pow(2, failures - 2).toInt(), 30)),
            ),
      connectivity: connectivityService,
      connectTimeout: _connectTimeout,
    );
  }

  /// True once the socket survived 7TV's hello, not merely the upgrade.
  bool get isConnected => _channel != null && _handshakeComplete;

  /// Down, but the loop is already dialing or waiting to retry.
  bool get isReconnecting => !isConnected && (_loop.running || _rateLimited);

  /// Waiting out a server rate limit before the next dial.
  bool get isRateLimited => _rateLimited;

  int _subscriptionSends = 0;

  /// Subscription frames handed to the socket. Test hook for dedup
  /// assertions; frames drop when no socket is connected.
  @visibleForTesting
  int get subscriptionSends => _subscriptionSends;

  /// Distinct subscriptions sent on the current connection.
  int get subscriptionSentCount => _sentSubscriptions.length;

  /// Distinct subscriptions acknowledged on the current connection.
  int get subscriptionAckCount => _ackedSubscriptions.length;

  /// Subscriptions sent but not yet acknowledged on the current connection.
  int get pendingSubscriptionAcks =>
      _sentSubscriptions.difference(_ackedSubscriptions).length;

  /// Subscriptions the pending sets want on the current connection, including
  /// ones the cap or a dead socket kept from being sent.
  int get intendedSubscriptionCount =>
      _pendingEmoteSets.length +
      _pendingUsers.length +
      _pendingChannels.length * _channelFeedTypes.length;

  /// Intended subscriptions this connection never sent. Zero once every
  /// pending identity is on the wire.
  int get missingSubscriptionCount {
    final missing = intendedSubscriptionCount - _sentSubscriptions.length;
    return missing > 0 ? missing : 0;
  }

  /// True once the foreign-set cap dropped a subscription.
  bool get pendingSetsOverflowed => _pendingSetsOverflowed;

  /// Whether the pending subscription set already holds this emote set.
  bool hasEmoteSetSubscription(String emoteSetId) =>
      _pendingEmoteSets.contains(emoteSetId);

  /// Whether the pending subscription set already holds this 7TV user.
  bool hasUserSubscription(String userId) => _pendingUsers.contains(userId);

  /// Whether the pending subscription set already holds this channel feed.
  bool hasTwitchChannelSubscription(String channelId) =>
      _pendingChannels.contains(channelId);

  /// Server cap on active subscriptions from the last hello, null when the
  /// server sent none (or zero, meaning no cap).
  int? get subscriptionLimit => _subscriptionLimit;

  /// Time of the last dispatch (op 0), null before the first one.
  DateTime? get lastDispatch => _lastDispatch;

  /// True when socket exists but no heartbeat arrived for >3x the interval
  /// (zombie, e.g. OS-frozen while backgrounded).
  bool get isStale {
    if (_channel == null || !_handshakeComplete) return false;
    final interval = _heartbeatInterval;
    if (interval == null) return true;
    return DateTime.now().difference(_lastHeartbeat).inMilliseconds >
        3 * interval;
  }

  /// Tears down a (possibly zombie) socket and reconnects. Used on app resume
  /// where [isConnected] alone can't be trusted.
  Future<void> forceReconnect() {
    if (_disposed) return Future.value();
    return connect();
  }

  bool _enabled = true;

  /// Off closes the socket and keeps it closed (every 7TV feature is off);
  /// back on reconnects and replays the pending subscriptions.
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (value == _enabled || _disposed) return;
    _enabled = value;
    if (value) {
      unawaited(connect());
    } else {
      _cancelRateLimitRetry();
      _loop.stop();
      _dropSocket();
    }
  }

  /// Opens a new socket, replacing any socket or retry in flight.
  /// Completes once the first handshake opened or failed.
  Future<void> connect() {
    if (_disposed || !_enabled) return Future.value();
    _fatalRetry?.cancel();
    _fatalRetry = null;
    _cancelRateLimitRetry();
    _disconnect();
    return _loop.start();
  }

  /// Opens a new socket; overridable in tests.
  @visibleForTesting
  Future<WebSocketChannel> openChannel() async =>
      WebSocketChannel.connect(Uri.parse(_wsUrl));

  /// One socket: dials, serves it until it ends, and says how the loop goes
  /// on.
  Future<SocketEnd> _attempt(SocketRun run) async {
    _run = run;
    _fatalCloseCode = null;
    _rateLimitHit = false;
    _handshakeComplete = false;
    WebSocketChannel? opened;
    try {
      opened = await openChannel();
      await run.ready(opened);
    } catch (e) {
      // A timed-out handshake must not leave its socket open.
      opened?.sink.close();
      if (!run.live) return SocketEnd.dropped;
      logDebug('7TV event connect error: $e');
      _statusCtrl.add(SevenTvEventStatus.disconnected);
      return SocketEnd.dropped;
    }
    final channel = opened;
    _channel = channel;
    _helloTimer?.cancel();
    _helloTimer = Timer(_connectTimeout, () {
      if (!identical(_channel, channel) || _handshakeComplete) return;
      logDebug('7TV event hello timeout - reconnecting');
      _endSocket(SocketEnd.dropped);
    });
    final end = Completer<SocketEnd>();
    _socketEnd = end;
    _streamSub = channel.stream.listen(
      (raw) {
        DataUsageStats.I.recordEvent(DataUsageStats.utf8Length(raw as String));
        _handleMessage(raw);
      },
      onError: (e) {
        logDebug('7TV event stream error: $e');
        if (_rateLimitHit) {
          _rateLimitHit = false;
          _endSocket(SocketEnd.fatal);
          if (!_rateLimited) _scheduleRateLimitRetry();
        } else {
          _endSocket(SocketEnd.dropped);
        }
      },
      onDone: () {
        final code = channel.closeCode;
        final reason = channel.closeReason ?? '';
        logDebug(
          '7TV event stream closed (code=$code '
          'reason="${channel.closeReason}")',
        );
        if (_isRateLimited(code, reason)) {
          _rateLimitHit = false;
          _endSocket(SocketEnd.fatal);
          if (!_rateLimited) _scheduleRateLimitRetry();
        } else if (_fatalCloseCode != null) {
          logDebug(
            '7TV: fatal end-of-stream code $_fatalCloseCode - not reconnecting',
          );
          _endSocket(SocketEnd.fatal);
        } else if (code != null && _noReconnectCloseCodes.contains(code)) {
          logDebug(
            '7TV: close code $code indicates client bug - not reconnecting',
          );
          _endSocket(SocketEnd.fatal);
        } else {
          _endSocket(SocketEnd.dropped);
        }
      },
    );
    final how = await end.future;
    // A disconnect or restart already tore this socket down.
    if (!run.live) return SocketEnd.dropped;
    // A fatal end leaves the socket released and reported down, so
    // [isConnected] is false and recovery can start from scratch.
    _dropSocket();
    if (how == SocketEnd.fatal && !_rateLimited) {
      // A rate limit already scheduled its own backoff; a quick retry here
      // would keep the limit alive and replay the whole subscription batch.
      _scheduleFatalRetry();
    }
    return how;
  }

  void _endSocket(SocketEnd how) {
    final end = _socketEnd;
    _socketEnd = null;
    if (end != null && !end.isCompleted) end.complete(how);
  }

  bool _isRateLimited(int? code, String reason) =>
      _rateLimitHit ||
      code == _rateLimitCloseCode ||
      reason.toLowerCase().contains('rate limit');

  /// Stops the socket loop and retries after a growing wait, so a rate limit
  /// cannot turn into a connect loop that keeps the limit alive.
  void _scheduleRateLimitRetry() {
    if (_disposed || !_enabled) return;
    _rateLimitFailures++;
    final delay = _nextRateLimitDelay();
    _rateLimited = true;
    _rateLimitRetry?.cancel();
    logDebug('7TV: rate limited - retrying in ${delay.inSeconds}s');
    _rateLimitRetry = Timer(delay, () {
      _rateLimitRetry = null;
      if (_disposed || !_enabled) return;
      unawaited(connect());
    });
  }

  Duration _nextRateLimitDelay() {
    final step = min(_rateLimitFailures - 1, 5);
    final seconds = min(
      _rateLimitMinSeconds * pow(2, step).toInt(),
      _rateLimitMaxSeconds,
    );
    return applyReconnectJitter(Duration(seconds: seconds));
  }

  void _cancelRateLimitRetry() {
    _rateLimitRetry?.cancel();
    _rateLimitRetry = null;
    _rateLimited = false;
  }

  /// A heartbeat or dispatch means the socket survived its hello, so the
  /// next rate limit starts from the shortest wait again.
  void _healthy() {
    if (_rateLimitFailures == 0 && !_rateLimited) return;
    _cancelRateLimitRetry();
    _rateLimitFailures = 0;
  }

  // Some 7TV deployments add an `s` sequence. Trust it only after two clean
  // increments for one dispatch type, so a per-session counter cannot trigger
  // a false gap after reconnect.
  void _trackDispatchSequence(String type, Object? raw) {
    if (raw is! int) return;
    final last = _lastSequenceByType[type];
    final trust = _sequenceTrust[type] ?? 0;
    if (last == null) {
      _lastSequenceByType[type] = raw;
      _sequenceTrust[type] = 0;
      return;
    }
    if (raw > last) {
      if (trust >= 1 && raw > last + 1 && !_gapEmitted) {
        _gapEmitted = true;
        _gapEvidence = true;
        _gapCtrl.add(null);
      }
      _sequenceTrust[type] = raw == last + 1 ? min(trust + 1, 2) : 0;
    } else {
      // A reset means the sequence is session-scoped, not comparable.
      _sequenceTrust[type] = 0;
    }
    _lastSequenceByType[type] = raw;
  }

  /// Adds [owner] to the set's owners. A repeat from a foreign owner refreshes
  /// its LRU position; a protected owner is never evicted by foreign sets.
  void subscribeEmoteSet(String emoteSetId, {SevenTvEmoteSetOwner? owner}) {
    if (emoteSetId.isEmpty) return;
    final key = (owner ?? SevenTvEmoteSetOwner.foreign(emoteSetId))._key;
    final owners = _emoteSetOwners.putIfAbsent(emoteSetId, () => {});
    final addedOwner = owners.add(key);
    final wasPending = _pendingEmoteSets.contains(emoteSetId);
    // Resubscribes move the set to the newest end, without a second frame.
    _pendingEmoteSets
      ..remove(emoteSetId)
      ..add(emoteSetId);
    if (addedOwner && !wasPending && _handshakeComplete) {
      _sendSubscription('emote_set.update', emoteSetId, subscribe: true);
    }
    _trimForeignEmoteSets();
  }

  /// Releases one owner. The socket frame goes out only when no other owner
  /// still needs the set.
  void unsubscribeEmoteSet(String emoteSetId, {SevenTvEmoteSetOwner? owner}) {
    final owners = _emoteSetOwners[emoteSetId];
    if (owners == null) return;
    owners.remove((owner ?? SevenTvEmoteSetOwner.foreign(emoteSetId))._key);
    if (owners.isNotEmpty) return;
    _forgetEmoteSet(emoteSetId, unsubscribe: true);
  }

  void _forgetEmoteSet(
    String emoteSetId, {
    required bool unsubscribe,
    bool interrupted = false,
  }) {
    _emoteSetOwners.remove(emoteSetId);
    if (!_pendingEmoteSets.remove(emoteSetId)) return;
    if (interrupted) _interruptedEmoteSets.add(emoteSetId);
    if (unsubscribe && _handshakeComplete) {
      _sendSubscription('emote_set.update', emoteSetId, subscribe: false);
    }
  }

  /// Emote sets whose subscription was unacked, skipped by the server cap, or
  /// dropped by the foreign LRU before this socket ended. Used to narrow REST
  /// healing to sets that may have missed events.
  Set<String> takeInterruptedEmoteSetIds() {
    final ids = <String>{..._interruptedEmoteSets};
    _interruptedEmoteSets.clear();
    if (ids.isNotEmpty) _gapEvidence = true;
    return ids;
  }

  void _captureInterruptedIds() {
    for (final key in _sentSubscriptions.difference(_ackedSubscriptions)) {
      final id = _emoteSetSubscriptionKeys[key];
      if (id != null) _interruptedEmoteSets.add(id);
    }
    for (final key in _skippedSubscriptionKeys) {
      final id = _emoteSetSubscriptionKeys[key];
      if (id != null) _interruptedEmoteSets.add(id);
    }
  }

  bool _isProtectedEmoteSet(String emoteSetId) =>
      _emoteSetOwners[emoteSetId]?.any(
        (key) => key.kind != SevenTvEmoteSetOwnerKind.foreign,
      ) ??
      false;

  void _trimForeignEmoteSets() {
    while (_pendingEmoteSets.where(_isForeignEmoteSet).length >
        _maxPendingEmoteSets) {
      final dropped = _pendingEmoteSets.firstWhere(_isForeignEmoteSet);
      _forgetEmoteSet(dropped, unsubscribe: true, interrupted: true);
      _pendingSetsOverflowed = true;
      logDebug('7TV: foreign set cap dropped $dropped');
    }
  }

  bool _isForeignEmoteSet(String emoteSetId) =>
      !_isProtectedEmoteSet(emoteSetId);

  void subscribeUser(String userId) =>
      _setSubscribed(_pendingUsers, 'user.update', userId, subscribe: true);

  void unsubscribeUser(String userId) =>
      _setSubscribed(_pendingUsers, 'user.update', userId, subscribe: false);

  // Subscribers wait for the handshake; unsubscribes send only for what this
  // socket subscribed, since 7TV closes with 4010 (fatal) on an unknown one.
  // Repeat subscribes are no-ops: the pending set already holds the id and
  // the handshake flush covers the pre-handshake case.
  void _setSubscribed(
    Set<String> pending,
    String type,
    String objectId, {
    required bool subscribe,
  }) {
    if (subscribe) {
      if (!pending.add(objectId)) return;
      if (_handshakeComplete) {
        _sendSubscription(type, objectId, subscribe: true);
      }
    } else {
      if (pending.remove(objectId) && _handshakeComplete) {
        _sendSubscription(type, objectId, subscribe: false);
      }
    }
  }

  void subscribeTwitchChannel(String channelId) {
    if (!_pendingChannels.add(channelId)) return;
    if (_handshakeComplete) {
      _sendChannelSubscription(channelId, subscribe: true);
    }
  }

  void unsubscribeTwitchChannel(String channelId) {
    if (_pendingChannels.remove(channelId) && _handshakeComplete) {
      _sendChannelSubscription(channelId, subscribe: false);
    }
  }

  _SubscriptionSend _sendSubscription(
    String type,
    String objectId, {
    required bool subscribe,
  }) {
    if (objectId.isEmpty) {
      logDebug(
        '7TV: refusing to send $type '
        '${subscribe ? 'subscribe' : 'unsubscribe'} with empty objectId',
      );
      return _SubscriptionSend.failed;
    }
    final condition = {'object_id': objectId};
    final key = _subscriptionKey(type, condition);
    if (type == 'emote_set.update' && subscribe) {
      _emoteSetSubscriptionKeys[key] = objectId;
    }
    final result = _sendSubscriptionFrame(
      type,
      condition,
      subscribe: subscribe,
    );
    if (type == 'emote_set.update' &&
        subscribe &&
        result == _SubscriptionSend.failed) {
      _interruptedEmoteSets.add(objectId);
    }
    return result;
  }

  void _sendChannelSubscription(String channelId, {required bool subscribe}) {
    if (channelId.isEmpty) return;
    for (final type in _channelFeedTypes) {
      _sendSubscriptionFrame(type, {
        'ctx': 'channel',
        'platform': 'TWITCH',
        'id': channelId,
      }, subscribe: subscribe);
    }
  }

  _SubscriptionSend _sendSubscriptionFrame(
    String type,
    Map<String, dynamic> condition, {
    required bool subscribe,
  }) {
    final key = _subscriptionKey(type, condition);
    if (subscribe) {
      if (!_hasSubscriptionRoom(key)) {
        _skippedSubscriptionKeys.add(key);
        return _SubscriptionSend.skipped;
      }
      _skippedSubscriptionKeys.remove(key);
    } else if (!_sentSubscriptions.contains(key)) {
      // 7TV closes 4010 on an unsubscribe it never saw, so a subscription the
      // cap skipped gets no unsubscribe either.
      return _SubscriptionSend.skipped;
    }
    final sent = _send(
      jsonEncode({
        'op': subscribe ? 35 : 36,
        'd': {'type': type, 'condition': condition},
      }),
    );
    if (!sent) return _SubscriptionSend.failed;
    if (subscribe) {
      _sentSubscriptions.add(key);
    } else {
      _sentSubscriptions.remove(key);
      _ackedSubscriptions.remove(key);
    }
    return _SubscriptionSend.sent;
  }

  bool _hasSubscriptionRoom(String key) {
    final limit = _subscriptionLimit;
    if (limit == null ||
        _sentSubscriptions.contains(key) ||
        _sentSubscriptions.length < limit) {
      return true;
    }
    logDebug('7TV: subscription limit $limit reached, skipping $key');
    return false;
  }

  /// A stable identity for a subscription, independent of JSON key order.
  String _subscriptionKey(String type, Map<String, dynamic> condition) {
    final keys = condition.keys.toList()..sort();
    return '$type ${jsonEncode({for (final key in keys) key: condition[key]})}';
  }

  void _flushPendingSubscriptions() {
    // Protected sets go first so a small server subscription limit cannot
    // crowd out the channels and viewer that are still open.
    final orderedSets = [
      ..._pendingEmoteSets.where(_isProtectedEmoteSet),
      ..._pendingEmoteSets.where(_isForeignEmoteSet),
    ];
    final failedSets = <String>[];
    for (final id in orderedSets) {
      final result = _sendSubscription('emote_set.update', id, subscribe: true);
      if (result == _SubscriptionSend.failed) failedSets.add(id);
    }
    for (final id in failedSets) {
      _sendSubscription('emote_set.update', id, subscribe: true);
    }
    final failedUsers = <String>[];
    for (final id in _pendingUsers) {
      final result = _sendSubscription('user.update', id, subscribe: true);
      if (result == _SubscriptionSend.failed) failedUsers.add(id);
    }
    for (final id in failedUsers) {
      _sendSubscription('user.update', id, subscribe: true);
    }
    for (final id in _pendingChannels) {
      _sendChannelSubscription(id, subscribe: true);
    }
  }

  void _handleMessage(String raw) {
    try {
      final msg = jsonDecode(raw) as Map<String, dynamic>;
      final op = msg['op'] as int?;
      final d = msg['d'] as Map<String, dynamic>?;

      switch (op) {
        case 1:
          _onHello(d ?? {});
        case 0:
          _healthy();
          _lastDispatch = _now();
          _trackDispatchSequence(d?['type'] as String? ?? '', msg['s']);
          _handleDispatch(d ?? {});
        case 2:
          _healthy();
          _lastHeartbeat = DateTime.now();
        case 4:
          logDebug('7TV server requested reconnect');
          _cleanReconnect = true;
          _endSocket(SocketEnd.reconnectNow);
        case 5:
          _onAck(d ?? {});
        case 6:
          final errorCode = d?['code'];
          final errorMessage = d?['message'];
          logDebug(
            '7TV error: code=${errorCode ?? '?'} '
            'message="${errorMessage ?? '?'}"',
          );
        case 7:
          final code = d?['code'] as int?;
          final message = d?['message'] as String?;
          logDebug('7TV end-of-stream: code=$code message="$message"');
          if (code == _rateLimitCloseCode) {
            _rateLimitHit = true;
          } else if (code != null && _noReconnectCloseCodes.contains(code)) {
            _fatalCloseCode = code;
            logDebug(
              '7TV: end-of-stream code $code is fatal - will not reconnect',
            );
          }
          break;
      }
    } catch (e) {
      logDebug('7TV event parse error: $e');
    }
  }

  void _onAck(Map<String, dynamic> d) {
    final command = d['command'];
    // Unsubscribe acks have nothing pending to mark.
    if (command is! String || command.toLowerCase() != 'subscribe') return;
    final data = d['data'];
    if (data is! Map) return;
    final type = data['type'];
    final condition = data['condition'];
    if (type is! String || condition is! Map) return;
    final key = _subscriptionKey(type, Map<String, dynamic>.from(condition));
    if (!_sentSubscriptions.contains(key)) return;
    _ackedSubscriptions.add(key);
  }

  void _onHello(Map<String, dynamic> d) {
    final interval = d['heartbeat_interval'] as int? ?? 30000;
    _subscriptionLimit = _parseSubscriptionLimit(d['subscription_limit']);
    // Subscription accounting is per connection; the flush below starts it.
    _sentSubscriptions.clear();
    _ackedSubscriptions.clear();
    _skippedSubscriptionKeys.clear();
    _helloTimer?.cancel();
    _helloTimer = null;
    _heartbeatInterval = interval;
    _handshakeComplete = true;
    final run = _run;
    final socket = _channel;
    _healthyTimer?.cancel();
    _healthyTimer = Timer(_healthyWindow, () {
      if (identical(_run, run) &&
          identical(_channel, socket) &&
          _handshakeComplete) {
        run?.opened();
      }
    });
    final ended = _sessionEndedAt;
    if (_hadEstablishedSession &&
        (ended == null || _now().difference(ended) >= _gapWindow)) {
      _gapEvidence = true;
    }
    _sessionEndedAt = null;
    _hadEstablishedSession = false;
    _gapEmitted = false;
    _lastHeartbeat = DateTime.now();
    _statusCtrl.add(SevenTvEventStatus.connected);
    _startHeartbeat();
    _flushPendingSubscriptions();
  }

  static int? _parseSubscriptionLimit(Object? raw) {
    final value = raw is num ? raw.toInt() : int.tryParse('$raw');
    return value == null || value <= 0 ? null : value;
  }

  void _handleDispatch(Map<String, dynamic> d) {
    final type = d['type'] as String?;
    final body = d['body'] as Map<String, dynamic>? ?? {};
    final actor = body['actor']?['display_name'] as String?;

    switch (type) {
      case 'emote_set.update':
        final pushed =
            (body['pushed'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map((e) {
                  final value = e['value'] as Map<String, dynamic>? ?? e;
                  return SevenTvAddedEmote(
                    id: value['id'] as String? ?? '',
                    name: value['name'] as String? ?? '',
                    raw: value,
                  );
                })
                .where((e) => e.id.isNotEmpty)
                .toList() ??
            [];

        final pulled =
            (body['pulled'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map((e) {
                  final oldValue = e['old_value'] as Map<String, dynamic>? ?? e;
                  return SevenTvRemovedEmote(
                    id: oldValue['id'] as String? ?? '',
                    name: oldValue['name'] as String? ?? '',
                  );
                })
                .where((e) => e.id.isNotEmpty)
                .toList() ??
            [];

        final updated =
            (body['updated'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map((e) {
                  final value = e['value'] as Map<String, dynamic>? ?? {};
                  final oldValue =
                      e['old_value'] as Map<String, dynamic>? ?? {};
                  final newName = value['name'] as String? ?? '';
                  final data = value['data'] as Map<String, dynamic>?;
                  final base = data?['name'] as String?;
                  return SevenTvRenamedEmote(
                    id: value['id'] as String? ?? '',
                    newName: newName,
                    oldName: oldValue['name'] as String? ?? '',
                    baseName: base != null && base != newName ? base : null,
                  );
                })
                .where((e) => e.id.isNotEmpty)
                .toList() ??
            [];

        _emoteSetUpdateCtrl.add(
          SevenTvEmoteUpdateEvent(
            emoteSetId: body['id'] as String? ?? '',
            added: pushed,
            removed: pulled,
            renamed: updated,
            actor: actor,
          ),
        );

      case 'emote_set.create':
        final created = body['object'] as Map<String, dynamic>? ?? body;
        final createdId = created['id'] as String? ?? '';
        if (createdId.isEmpty) break;
        // Fail closed like the REST path: only personal sets are tracked.
        if (!SevenTvEmoteProvider.isPersonalSet(created)) break;
        _personalSetCtrl.add(SevenTvPersonalSetEvent(setId: createdId));

      case 'user.update':
        final userId = body['id'] as String? ?? d['id'] as String? ?? '';
        // Each updated connection nests the new active set id.
        final emitted = <String>{};
        for (final change in body['updated'] as List<dynamic>? ?? const []) {
          if (change is! Map<String, dynamic> ||
              change['key'] != 'connections') {
            continue;
          }
          final nested = change['value'];
          if (nested is! List<dynamic>) continue;
          for (final field in nested) {
            if (field is! Map<String, dynamic> ||
                field['key'] != 'emote_set_id') {
              continue;
            }
            final newId = field['value'] as String? ?? '';
            if (newId.isEmpty || !emitted.add(newId)) continue;
            _userUpdateCtrl.add(
              SevenTvUserUpdate(
                userId: userId,
                newEmoteSetId: newId,
                oldEmoteSetId: field['old_value'] as String? ?? '',
                connectionIndex: (change['index'] as int?) ?? -1,
                actor: actor,
              ),
            );
          }
        }

      case 'cosmetic.create':
        final obj = body['object'] as Map<String, dynamic>? ?? {};
        final kind = obj['kind'] as String?;
        if (kind != 'BADGE') break;
        final data = obj['data'] as Map<String, dynamic>? ?? {};
        final cosmeticId = data['id'] as String? ?? '';
        if (cosmeticId.isEmpty) break;
        final name = data['name'] as String? ?? '';
        final tooltip = data['tooltip'] as String?;
        final host = data['host'] as Map<String, dynamic>? ?? {};
        final hostUrl = host['url'] as String? ?? '';
        final files = host['files'] as List<dynamic>? ?? [];
        String imageUrl = '';
        // 4x is sharp on dense screens; 2x when a badge lacks it.
        for (final size in const ['4x.', '2x.']) {
          for (final f in files) {
            final fileName = (f as Map<String, dynamic>)['name'] as String?;
            if (fileName != null && fileName.startsWith(size)) {
              imageUrl = 'https:$hostUrl/$fileName';
              break;
            }
          }
          if (imageUrl.isNotEmpty) break;
        }
        if (imageUrl.isEmpty && files.isNotEmpty) {
          final first = files.first as Map<String, dynamic>;
          final fileName = first['name'] as String? ?? '';
          imageUrl = 'https:$hostUrl/$fileName';
        }
        if (imageUrl.isNotEmpty) {
          _cosmeticCreateCtrl.add(
            SevenTvCosmeticCreateEvent(
              cosmeticId: cosmeticId,
              name: name,
              imageUrl: imageUrl,
              tooltip: tooltip,
            ),
          );
        }

      case 'entitlement.create':
      case 'entitlement.delete':
        final obj = body['object'] as Map<String, dynamic>? ?? {};
        final cosmeticId = obj['ref_id'] as String? ?? '';
        final cosmeticKind = obj['kind'] as String? ?? '';
        if (cosmeticId.isEmpty ||
            (cosmeticKind != 'BADGE' &&
                cosmeticKind != 'PAINT' &&
                cosmeticKind != 'EMOTE_SET')) {
          break;
        }
        final userObj = obj['user'] as Map<String, dynamic>? ?? {};
        final connections = userObj['connections'] as List<dynamic>? ?? [];
        final twitchIds = <String>[];
        for (final conn in connections) {
          final c = conn as Map<String, dynamic>;
          if (c['platform'] == 'TWITCH') {
            final id = c['id'] as String? ?? '';
            if (id.isNotEmpty) twitchIds.add(id);
          }
        }
        if (twitchIds.isNotEmpty) {
          _entitlementCtrl.add(
            SevenTvEntitlementEvent(
              cosmeticId: cosmeticId,
              kind: type!,
              cosmeticKind: cosmeticKind,
              twitchUserIds: twitchIds,
            ),
          );
        }
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    if (_heartbeatInterval == null) return;
    _heartbeatTimer = Timer.periodic(
      Duration(milliseconds: _heartbeatInterval!),
      (_) {
        if (_channel == null) return;
        final elapsed = DateTime.now().difference(_lastHeartbeat);
        if (elapsed.inMilliseconds > 3 * _heartbeatInterval!) {
          logDebug('7TV heartbeat timeout - reconnecting');
          _endSocket(SocketEnd.dropped);
          return;
        }
      },
    );
  }

  bool _send(String message) {
    final channel = _channel;
    if (channel == null) return false;
    try {
      channel.sink.add(message);
      _subscriptionSends++;
      return true;
    } catch (e) {
      logDebug('7TV event send failed: $e');
      return false;
    }
  }

  /// Releases the socket and reports it down, so [isConnected] is false.
  void _dropSocket() {
    _disconnect();
    if (_disposed) return;
    _statusCtrl.add(SevenTvEventStatus.disconnected);
  }

  void _disconnect() {
    if (_handshakeComplete) {
      _captureInterruptedIds();
      if (!_cleanReconnect) {
        _sessionEndedAt = _now();
        _hadEstablishedSession = true;
      }
    }
    _cleanReconnect = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatInterval = null;
    _helloTimer?.cancel();
    _helloTimer = null;
    _healthyTimer?.cancel();
    _healthyTimer = null;
    _fatalRetry?.cancel();
    _fatalRetry = null;
    _handshakeComplete = false;
    _streamSub?.cancel();
    _streamSub = null;
    _channel?.sink.close();
    _channel = null;
    _endSocket(SocketEnd.dropped);
  }

  void _scheduleFatalRetry() {
    if (_disposed || !_enabled) return;
    _fatalRetry?.cancel();
    _fatalRetry = Timer(_fatalRetryDelay, () {
      _fatalRetry = null;
      if (_disposed || !_enabled) return;
      logDebug('7TV: retrying after a fatal close');
      unawaited(connect());
    });
  }

  @visibleForTesting
  void handleRawMessage(Map<String, dynamic> msg) =>
      _handleMessage(jsonEncode(msg));

  @visibleForTesting
  void emitDisconnected() {
    _handshakeComplete = false;
    _statusCtrl.add(SevenTvEventStatus.disconnected);
  }

  @visibleForTesting
  void enterRateLimitForTest() => _scheduleRateLimitRetry();

  @visibleForTesting
  int get reconnectAttempt => _loop.failures;

  void dispose() {
    _disposed = true;
    _cancelRateLimitRetry();
    _loop.dispose();
    _disconnect();
    _emoteSetUpdateCtrl.close();
    _userUpdateCtrl.close();
    _cosmeticCreateCtrl.close();
    _entitlementCtrl.close();
    _personalSetCtrl.close();
    _statusCtrl.close();
    _gapCtrl.close();
  }
}
