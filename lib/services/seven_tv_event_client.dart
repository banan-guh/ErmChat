import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

enum SevenTvEventStatus { connected, disconnected }

class SevenTvEventClient {
  static const _wsUrl = 'wss://events.7tv.io/v3';
  static const _noReconnectCloseCodes = {4001, 4002, 4003, 4004, 4009, 4010};
  static const _maxReconnectAttempts = 8;
  static const _reconnectMinDelay = Duration(seconds: 1);

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _streamSub;
  Timer? _heartbeatTimer;
  int? _heartbeatInterval;
  DateTime _lastHeartbeat = DateTime.now();
  bool _handshakeComplete = false;
  bool _reconnecting = false;
  int _reconnectAttempt = 0;
  bool _disposed = false;
  int? _fatalCloseCode;

  final _pendingEmoteSets = <String>{};
  final _pendingUsers = <String>{};

  final _emoteSetUpdateCtrl =
      StreamController<SevenTvEmoteUpdateEvent>.broadcast(sync: true);
  final _userUpdateCtrl =
      StreamController<SevenTvUserUpdate>.broadcast(sync: true);
  final _statusCtrl =
      StreamController<SevenTvEventStatus>.broadcast(sync: true);

  Stream<SevenTvEmoteUpdateEvent> get onEmoteSetUpdate =>
      _emoteSetUpdateCtrl.stream;
  Stream<SevenTvUserUpdate> get onUserUpdate => _userUpdateCtrl.stream;
  Stream<SevenTvEventStatus> get onStatus => _statusCtrl.stream;

  bool get isConnected => _channel != null;

  Future<void> connect() async {
    if (_disposed) return;
    _fatalCloseCode = null;
    _disconnect();
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      await _channel!.ready;

      _streamSub = _channel!.stream.listen(
        (raw) => _handleMessage(raw as String),
        onError: (e) {
          debugPrint('7TV event stream error: $e');
          _scheduleReconnect();
        },
        onDone: () {
          final code = _channel?.closeCode;
          final reason = _channel?.closeReason;
          debugPrint('7TV event stream closed (code=$code reason="$reason")');
          if (_fatalCloseCode != null) {
            debugPrint(
              '7TV: fatal end-of-stream code $_fatalCloseCode — not reconnecting',
            );
            return;
          }
          if (code != null && _noReconnectCloseCodes.contains(code)) {
            debugPrint(
              '7TV: close code $code indicates client bug — not reconnecting',
            );
            return;
          }
          _scheduleReconnect();
        },
      );
    } catch (e) {
      debugPrint('7TV event connect error: $e');
      _scheduleReconnect();
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

  void _sendSubscription(String type, String objectId, {required bool subscribe}) {
    if (objectId.isEmpty) {
      debugPrint(
        '7TV: refusing to send $type '
        '${subscribe ? 'subscribe' : 'unsubscribe'} with empty objectId',
      );
      return;
    }
    _send(jsonEncode({
      'op': subscribe ? 35 : 36,
      'd': {
        'type': type,
        'condition': {'object_id': objectId},
      },
    }));
  }

  void _flushPendingSubscriptions() {
    for (final id in _pendingEmoteSets) {
      _sendSubscription('emote_set.update', id, subscribe: true);
    }
    for (final id in _pendingUsers) {
      _sendSubscription('user.update', id, subscribe: true);
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
          debugPrint('7TV server requested reconnect');
          connect();
        case 5:
          break;
        case 7:
          final code = d?['code'] as int?;
          final message = d?['message'] as String?;
          debugPrint('7TV end-of-stream: code=$code message="$message"');
          if (code != null && _noReconnectCloseCodes.contains(code)) {
            _fatalCloseCode = code;
            debugPrint('7TV: end-of-stream code $code is fatal — will not reconnect');
          }
          break;
      }
    } catch (e) {
      debugPrint('7TV event parse error: $e');
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
        final pushed = (body['pushed'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map((e) {
              final value = e['value'] as Map<String, dynamic>? ?? e;
              return SevenTvAddedEmote(
                id: value['id'] as String? ?? '',
                name: value['name'] as String? ?? '',
                raw: value,
              );
            }).where((e) => e.id.isNotEmpty).toList() ??
            [];

        final pulled = (body['pulled'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map((e) {
              final oldValue = e['old_value'] as Map<String, dynamic>? ?? e;
              return SevenTvRemovedEmote(
                id: oldValue['id'] as String? ?? '',
                name: oldValue['name'] as String? ?? '',
              );
            }).where((e) => e.id.isNotEmpty).toList() ??
            [];

        final updated = (body['updated'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map((e) {
              final value = e['value'] as Map<String, dynamic>? ?? {};
              final oldValue = e['old_value'] as Map<String, dynamic>? ?? {};
              return SevenTvRenamedEmote(
                id: value['id'] as String? ?? '',
                newName: value['name'] as String? ?? '',
                oldName: oldValue['name'] as String? ?? '',
              );
            }).where((e) => e.id.isNotEmpty).toList() ??
            [];

        _emoteSetUpdateCtrl.add(
          SevenTvEmoteUpdateEvent(
            emoteSetId: d['id'] as String? ?? '',
            added: pushed,
            removed: pulled,
            renamed: updated,
            actor: actor,
          ),
        );

      case 'user.update':
        final changeMap =
            body['change_map'] as Map<String, dynamic>? ?? {};
        final connectionIndex =
            (body['connection_index'] as int?) ?? (changeMap['index'] as int?) ?? -1;
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
          debugPrint('7TV heartbeat timeout — reconnecting');
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

  void _scheduleReconnect() {
    if (_reconnecting || _disposed) return;
    _reconnecting = true;
    _handshakeComplete = false;
    _statusCtrl.add(SevenTvEventStatus.disconnected);
    _reconnectAttempt++;
    if (_reconnectAttempt > _maxReconnectAttempts) {
      debugPrint(
        '7TV: max reconnect attempts ($_maxReconnectAttempts) reached — giving up',
      );
      return;
    }
    Duration delay;
    if (_reconnectAttempt == 1) {
      delay = _reconnectMinDelay;
    } else {
      final base = Duration(
        seconds: min(pow(2, _reconnectAttempt - 2).toInt(), 30),
      );
      final jitter = 0.75 + Random().nextDouble() * 0.5;
      delay = Duration(milliseconds: (base.inMilliseconds * jitter).toInt());
    }
    debugPrint('7TV scheduling reconnect in ${delay.inMilliseconds}ms (attempt $_reconnectAttempt)');
    Timer(delay, () {
      _reconnecting = false;
      if (!_disposed) {
        connect();
      }
    });
  }

  void _disconnect() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatInterval = null;
    _handshakeComplete = false;
    _streamSub?.cancel();
    _streamSub = null;
    _channel?.sink.close();
    _channel = null;
  }

  @visibleForTesting
  void handleRawMessage(Map<String, dynamic> msg) => _handleMessage(jsonEncode(msg));

  @visibleForTesting
  void emitDisconnected() {
    _handshakeComplete = false;
    _statusCtrl.add(SevenTvEventStatus.disconnected);
  }

  void dispose() {
    _disposed = true;
    _reconnecting = false;
    _disconnect();
    _emoteSetUpdateCtrl.close();
    _userUpdateCtrl.close();
    _statusCtrl.close();
  }
}
