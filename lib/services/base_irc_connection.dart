import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

abstract class BaseIrcConnection {
  static const _wsUrl = 'wss://irc-ws.chat.twitch.tv:443';
  static const _maxReconnectAttempts = 8;

  final Connectivity? connectivity;

  WebSocketChannel? channel;
  String? username;
  String? token;
  bool _reconnecting = false;
  bool _connecting = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;
  int _pingsWithoutPong = 0;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _isOnline = true;
  final _channels = <String>{};

  StreamSubscription<dynamic>? _streamSub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;

  bool get isConnected => channel != null;

  String get debugPrefix;

  BaseIrcConnection({this.connectivity});

  Future<void> connect({
    required String username,
    required String accessToken,
  }) async {
    this.username = username.toLowerCase();
    token = accessToken;
    await _connect();
  }

  Future<void> _connect() async {
    if (_connecting) return;
    _connecting = true;
    try {
      if (isConnected) {
        debugPrint('[$debugPrefix] already connected, skipping reconnect');
        return;
      }
      _connectivitySub?.cancel();
      final conn = connectivity;
      if (conn != null) {
        _connectivitySub = conn.onConnectivityChanged.listen(
          (results) {
            final wasOffline = !_isOnline;
            _isOnline = !results.contains(ConnectivityResult.none);
            if (wasOffline && _isOnline && channel == null && !_connecting) {
              _reconnectAttempt = 0;
              _connect();
            }
          },
        );
      }
      _disconnect();
      _pingsWithoutPong = 0;

      try {
        channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
        await channel!.ready;

        _streamSub = channel!.stream.listen(
          (raw) => _handleLine(raw as String),
          onError: (e) {
            debugPrint('$debugPrefix stream error: $e');
            _disconnect();
            _scheduleReconnect();
          },
          onDone: () {
            debugPrint(
              '$debugPrefix stream closed '
              '(code: ${channel?.closeCode}, '
              'reason: ${channel?.closeReason})',
            );
            _disconnect();
            _scheduleReconnect();
          },
        );

        sendLine('CAP REQ :twitch.tv/tags twitch.tv/commands');
        sendLine('PASS oauth:$token');
        sendLine('NICK $username');
        debugPrint(
          '[$debugPrefix] connected, re-joining '
          '${_channels.length} channels: $_channels',
        );

        for (final channel in _channels) {
          sendLine('JOIN #$channel');
        }

        _pingTimer?.cancel();
        _pingTimer = Timer.periodic(const Duration(seconds: 300), (_) {
          if (channel == null) return;
          if (_pingsWithoutPong > 0) {
            debugPrint('$debugPrefix PONG timeout – reconnecting');
            _disconnect();
            _scheduleReconnect();
            return;
          }
          sendLine('PING :keepalive');
          _pingsWithoutPong = 1;
        });
      } catch (e) {
        debugPrint('$debugPrefix connect error: $e');
        _scheduleReconnect();
      }
    } finally {
      _connecting = false;
    }
  }

  void _disconnect() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _streamSub?.cancel();
    _streamSub = null;
    channel?.sink.close();
    channel = null;
    _pingsWithoutPong = 0;
    _reconnecting = false;
  }

  void _scheduleReconnect() {
    if (_reconnecting || _disposed) return;
    if (!_isOnline) return;
    if (_reconnectAttempt >= _maxReconnectAttempts) {
      debugPrint(
        '[$debugPrefix] max reconnect attempts reached – giving up',
      );
      return;
    }
    _reconnecting = true;
    _reconnectAttempt++;
    Duration delay;
    if (_reconnectAttempt == 1) {
      delay = const Duration(seconds: 1);
    } else {
      final base = Duration(
        seconds: min(pow(2, _reconnectAttempt - 2).toInt(), 30),
      );
      final jitter = 0.75 + Random().nextDouble() * 0.5;
      delay = Duration(milliseconds: (base.inMilliseconds * jitter).toInt());
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      _reconnecting = false;
      if (!_disposed && username != null && token != null) {
        _connect();
      }
    });
  }

  void sendLine(String message) {
    channel?.sink.add(message);
  }

  void _handleLine(String raw) {
    _pingsWithoutPong = 0;
    for (final line in raw.split('\r\n')) {
      if (line.isEmpty) continue;

      if (line.startsWith('PING')) {
        sendLine(line.replaceFirst('PING', 'PONG'));
        continue;
      }

      if (line.startsWith('PONG')) {
        _reconnectAttempt = 0;
        continue;
      }

      dispatchLine(line);
    }
  }

  void dispatchLine(String line);

  void join(String channel) {
    debugPrint('[$debugPrefix] join channel=$channel');
    _channels.add(channel);
    if (this.channel != null) {
      sendLine('JOIN #$channel');
    }
  }

  void part(String channel) {
    debugPrint('[$debugPrefix] part channel=$channel');
    _channels.remove(channel);
    if (this.channel != null) {
      sendLine('PART #$channel');
    }
  }

  @mustCallSuper
  void dispose() {
    _disposed = true;
    _reconnecting = false;
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _streamSub?.cancel();
    channel?.sink.close();
  }
}
