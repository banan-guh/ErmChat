import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'connectivity_service.dart';
import '../util/constants.dart';
import '../util/log.dart';

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

  const SevenTvRenamedEmote({
    required this.id,
    required this.oldName,
    required this.newName,
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
  final String kind;
  final List<String> twitchUserIds;

  const SevenTvEntitlementEvent({
    required this.cosmeticId,
    required this.kind,
    required this.twitchUserIds,
  });
}

enum SevenTvEventStatus { connected, disconnected }

class SevenTvEventClient {
  static const _wsUrl = 'wss://events.7tv.io/v3';
  static const _connectTimeout = Duration(seconds: 10);
  static const _noReconnectCloseCodes = {4001, 4002, 4003, 4004, 4009, 4010};
  static const _maxReconnectAttempts = 8;
  static const _reconnectMinDelay = Duration(seconds: 1);

  final ConnectivityService? _connectivityService;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _streamSub;
  Timer? _heartbeatTimer;
  Timer? _connectTimer;
  int? _heartbeatInterval;
  DateTime _lastHeartbeat = DateTime.now();
  bool _handshakeComplete = false;
  bool _reconnecting = false;
  bool _connecting = false;
  int _reconnectAttempt = 0;
  bool _disposed = false;
  int? _fatalCloseCode;
  VoidCallback? _connectivityListener;
  bool _isOnline = true;

  final _pendingEmoteSets = <String>{};
  final _pendingUsers = <String>{};
  final _pendingChannels = <String>{};

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
  final _statusCtrl = StreamController<SevenTvEventStatus>.broadcast(
    sync: true,
  );

  Stream<SevenTvEmoteUpdateEvent> get onEmoteSetUpdate =>
      _emoteSetUpdateCtrl.stream;
  Stream<SevenTvUserUpdate> get onUserUpdate => _userUpdateCtrl.stream;
  Stream<SevenTvCosmeticCreateEvent> get onCosmeticCreate =>
      _cosmeticCreateCtrl.stream;
  Stream<SevenTvEntitlementEvent> get onEntitlement => _entitlementCtrl.stream;
  Stream<SevenTvEventStatus> get onStatus => _statusCtrl.stream;

  SevenTvEventClient({this._connectivityService});

  bool get isConnected => _channel != null;

  /// True when the socket exists but no heartbeat has arrived for well over
  /// the negotiated interval, i.e. a zombie socket that never errored on its
  /// own (e.g. frozen by the OS while backgrounded).
  bool get isStale {
    if (_channel == null) return false;
    final interval = _heartbeatInterval;
    if (interval == null) return true;
    return DateTime.now().difference(_lastHeartbeat).inMilliseconds >
        3 * interval;
  }

  /// Tears down a (possibly zombie) socket and reconnects. Used on app resume
  /// where [isConnected] alone can't be trusted.
  Future<void> forceReconnect() {
    if (_disposed || _connecting) return Future.value();
    _disconnect();
    return connect();
  }

  Future<void> connect() async {
    if (_disposed || _connecting) return;
    _connecting = true;
    try {
      _fatalCloseCode = null;
      _reconnectAttempt = 0;
      _ensureConnectivityListener();
      _disconnect();
      try {
        _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
        await _waitForReady();

        _streamSub = _channel!.stream.listen(
          (raw) => _handleMessage(raw as String),
          onError: (e) {
            logDebug('7TV event stream error: $e');
            _scheduleReconnect();
          },
          onDone: () {
            final code = _channel?.closeCode;
            final reason = _channel?.closeReason;
            logDebug('7TV event stream closed (code=$code reason="$reason")');
            if (_fatalCloseCode != null) {
              logDebug(
                '7TV: fatal end-of-stream code $_fatalCloseCode - not reconnecting',
              );
              return;
            }
            if (code != null && _noReconnectCloseCodes.contains(code)) {
              logDebug(
                '7TV: close code $code indicates client bug - not reconnecting',
              );
              return;
            }
            _scheduleReconnect();
          },
        );
      } catch (e) {
        logDebug('7TV event connect error: $e');
        // A failed or timed-out handshake must not leave a socket behind,
        // otherwise isConnected stays true and resume-time checks skip it.
        _disconnect();
        _scheduleReconnect();
      }
    } finally {
      _connecting = false;
    }
  }

  void subscribeEmoteSet(String emoteSetId) {
    _pendingEmoteSets.add(emoteSetId);
    if (_handshakeComplete) {
      _sendSubscription('emote_set.update', emoteSetId, subscribe: true);
    }
  }

  void unsubscribeEmoteSet(String emoteSetId) {
    _pendingEmoteSets.remove(emoteSetId);
    _sendSubscription('emote_set.update', emoteSetId, subscribe: false);
  }

  void subscribeUser(String userId) {
    _pendingUsers.add(userId);
    if (_handshakeComplete) {
      _sendSubscription('user.update', userId, subscribe: true);
    }
  }

  void unsubscribeUser(String userId) {
    _pendingUsers.remove(userId);
    _sendSubscription('user.update', userId, subscribe: false);
  }

  void subscribeTwitchChannel(String channelId) {
    _pendingChannels.add(channelId);
    if (_handshakeComplete) {
      _sendChannelSubscription(channelId, subscribe: true);
    }
  }

  void unsubscribeTwitchChannel(String channelId) {
    _pendingChannels.remove(channelId);
    _sendChannelSubscription(channelId, subscribe: false);
  }

  void _sendSubscription(
    String type,
    String objectId, {
    required bool subscribe,
  }) {
    if (objectId.isEmpty) {
      logDebug(
        '7TV: refusing to send $type '
        '${subscribe ? 'subscribe' : 'unsubscribe'} with empty objectId',
      );
      return;
    }
    _send(
      jsonEncode({
        'op': subscribe ? 35 : 36,
        'd': {
          'type': type,
          'condition': {'object_id': objectId},
        },
      }),
    );
  }

  void _sendChannelSubscription(String channelId, {required bool subscribe}) {
    if (channelId.isEmpty) return;
    for (final type in [
      'cosmetic.create',
      'entitlement.create',
      'entitlement.delete',
    ]) {
      _send(
        jsonEncode({
          'op': subscribe ? 35 : 36,
          'd': {
            'type': type,
            'condition': {
              'ctx': 'channel',
              'platform': 'TWITCH',
              'id': channelId,
            },
          },
        }),
      );
    }
  }

  void _flushPendingSubscriptions() {
    for (final id in _pendingEmoteSets) {
      _sendSubscription('emote_set.update', id, subscribe: true);
    }
    for (final id in _pendingUsers) {
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
          _handleDispatch(d ?? {});
        case 2:
          _lastHeartbeat = DateTime.now();
        case 4:
          logDebug('7TV server requested reconnect');
          connect();
        case 5:
          break;
        case 7:
          final code = d?['code'] as int?;
          final message = d?['message'] as String?;
          logDebug('7TV end-of-stream: code=$code message="$message"');
          if (code != null && _noReconnectCloseCodes.contains(code)) {
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

  void _onHello(Map<String, dynamic> d) {
    final interval = d['heartbeat_interval'] as int? ?? 30000;
    _heartbeatInterval = interval;
    _handshakeComplete = true;
    _reconnectAttempt = 0;
    _lastHeartbeat = DateTime.now();
    _statusCtrl.add(SevenTvEventStatus.connected);
    _startHeartbeat();
    _flushPendingSubscriptions();
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
                  return SevenTvRenamedEmote(
                    id: value['id'] as String? ?? '',
                    newName: value['name'] as String? ?? '',
                    oldName: oldValue['name'] as String? ?? '',
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

      case 'user.update':
        final changeMap = body['change_map'] as Map<String, dynamic>? ?? {};
        final connectionIndex =
            (body['connection_index'] as int?) ??
            (changeMap['index'] as int?) ??
            -1;
        final fields = changeMap['fields'] as List<dynamic>? ?? [];
        for (final field in fields) {
          final f = field as Map<String, dynamic>;
          if (f['key'] == 'emote_set_id') {
            final newId = f['value'] as String? ?? '';
            final oldId = f['old_value'] as String? ?? '';
            if (newId.isNotEmpty) {
              _userUpdateCtrl.add(
                SevenTvUserUpdate(
                  userId: d['id'] as String? ?? '',
                  newEmoteSetId: newId,
                  oldEmoteSetId: oldId,
                  connectionIndex: connectionIndex,
                  actor: actor,
                ),
              );
            }
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
        for (final f in files) {
          final file = f as Map<String, dynamic>;
          final fileName = file['name'] as String?;
          if (fileName != null && fileName.startsWith('2x.')) {
            imageUrl = 'https:$hostUrl/$fileName';
            break;
          }
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
        final kind = obj['kind'] as String? ?? '';
        if (cosmeticId.isEmpty || kind != 'BADGE') break;
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
          _disconnect();
          _scheduleReconnect();
          return;
        }
      },
    );
  }

  void _send(String message) {
    _channel?.sink.add(message);
  }

  /// Waits for the WebSocket handshake with an upper bound. The timeout timer
  /// is tracked and cancelled on disconnect/dispose so a torn-down connect
  /// never leaves a pending timer behind.
  Future<void> _waitForReady() {
    final channel = _channel;
    if (channel == null) return Future.value();
    final completer = Completer<void>();
    _connectTimer?.cancel();
    _connectTimer = Timer(_connectTimeout, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('7TV connect timed out'));
      }
    });
    channel.ready.then(
      (_) {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      },
    );
    return completer.future.whenComplete(() {
      _connectTimer?.cancel();
      _connectTimer = null;
    });
  }

  void _scheduleReconnect() {
    if (_reconnecting || _disposed) return;
    if (!_isOnline) return;
    _reconnecting = true;
    _handshakeComplete = false;
    _statusCtrl.add(SevenTvEventStatus.disconnected);
    _reconnectAttempt++;
    if (_reconnectAttempt > _maxReconnectAttempts) {
      logDebug(
        '7TV: max reconnect attempts ($_maxReconnectAttempts) reached - giving up',
      );
      _reconnecting = false;
      return;
    }
    Duration delay;
    if (_reconnectAttempt == 1) {
      delay = _reconnectMinDelay;
    } else {
      final base = Duration(
        seconds: min(pow(2, _reconnectAttempt - 2).toInt(), 30),
      );
      delay = applyReconnectJitter(base);
    }
    logDebug(
      '7TV scheduling reconnect in ${delay.inMilliseconds}ms (attempt $_reconnectAttempt)',
    );
    Timer(delay, () {
      _reconnecting = false;
      if (!_disposed) {
        connect();
      }
    });
  }

  void _ensureConnectivityListener() {
    final service = _connectivityService;
    if (service == null || _connectivityListener != null) return;
    _connectivityListener = () {
      final online = service.isOnline;
      final wasOffline = !_isOnline;
      _isOnline = online;
      if (wasOffline && online && _channel == null && !_reconnecting) {
        connect();
      }
    };
    _isOnline = service.isOnline;
    service.addListener(_connectivityListener!);
  }

  void _disconnect() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    _heartbeatInterval = null;
    _handshakeComplete = false;
    _reconnecting = false;
    _streamSub?.cancel();
    _streamSub = null;
    _channel?.sink.close();
    _channel = null;
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
  int get reconnectAttempt => _reconnectAttempt;

  @visibleForTesting
  bool get isReconnecting => _reconnecting;

  @visibleForTesting
  set isReconnecting(bool value) => _reconnecting = value;

  @visibleForTesting
  bool get isOnline => _isOnline;

  @visibleForTesting
  set isOnline(bool value) => _isOnline = value;

  @visibleForTesting
  void scheduleReconnectForTest() => _scheduleReconnect();

  void dispose() {
    _disposed = true;
    _reconnecting = false;
    final listener = _connectivityListener;
    if (listener != null) _connectivityService?.removeListener(listener);
    _connectivityListener = null;
    _channel = null;
    _heartbeatTimer = null;
    _streamSub = null;
    _disconnect();
    _emoteSetUpdateCtrl.close();
    _userUpdateCtrl.close();
    _cosmeticCreateCtrl.close();
    _entitlementCtrl.close();
    _statusCtrl.close();
  }
}
