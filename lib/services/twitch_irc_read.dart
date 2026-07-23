import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'twitch_irc.dart';

class IrcReadService {
  static const _wsUrl = 'wss://irc-ws.chat.twitch.tv:443';

  final Connectivity? _connectivity;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _streamSub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  final _channels = <String>{};
  String? _username;
  String? _token;
  bool _reconnecting = false;
  bool _connecting = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;
  int _pingsWithoutPong = 0;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _isOnline = true;

  final _ownMessageController = StreamController<IrcMessage>.broadcast();
  final _userColorController = StreamController<String>.broadcast();

  Stream<IrcMessage> get onOwnMessage => _ownMessageController.stream;
  Stream<String> get onUserColor => _userColorController.stream;

  bool get isConnected => _channel != null;

  IrcReadService({this._connectivity});

  Future<void> connect({
    required String username,
    required String accessToken,
  }) async {
    _username = username.toLowerCase();
    _token = accessToken;
    await _connect();
  }

  Future<void> _connect() async {
    if (_connecting) return;
    _connecting = true;
    try {
    _connectivitySub?.cancel();
    if (_connectivity != null) {
      _connectivitySub = _connectivity.onConnectivityChanged.listen((results) {
        final wasOffline = !_isOnline;
        _isOnline = !results.contains(ConnectivityResult.none);
        if (wasOffline && _isOnline && _channel == null && !_connecting) {
          _reconnectAttempt = 0;
          _connect();
        }
      });
    }
    _disconnect();
    _pingsWithoutPong = 0;

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      await _channel!.ready;

      _streamSub = _channel!.stream.listen(
        (raw) => _handleLine(raw as String),
        onError: (e) {
          debugPrint('IRC read stream error: $e');
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint(
            'IRC read stream closed (code: ${_channel?.closeCode}, reason: ${_channel?.closeReason})',
          );
          _scheduleReconnect();
        },
      );

      _send('CAP REQ :twitch.tv/tags twitch.tv/commands');
      _send('PASS oauth:$_token');
      _send('NICK $_username');

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        if (_channel == null) return;
        _pingsWithoutPong++;
        if (_pingsWithoutPong >= 3) {
          debugPrint('IRC read PONG timeout – reconnecting');
          _disconnect();
          _scheduleReconnect();
          return;
        }
        _send('PING :keepalive');
      });

      for (final channel in _channels) {
        _send('JOIN #$channel');
      }
    } catch (e) {
      debugPrint('IRC read connect error: $e');
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
    _channel?.sink.close();
    _channel = null;
    _pingsWithoutPong = 0;
    _reconnectAttempt = 0;
    _reconnecting = false;
  }

  void _scheduleReconnect() {
    if (_reconnecting || _disposed) return;
    if (!_isOnline) return;
    _reconnecting = true;
    _reconnectAttempt++;
    Duration delay;
    if (_reconnectAttempt == 1) {
      delay = Duration.zero;
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
      if (!_disposed && _username != null && _token != null) {
        _connect();
      }
    });
  }

  void _send(String message) {
    _channel?.sink.add(message);
  }

  void _handleLine(String raw) {
    _pingsWithoutPong = 0;
    for (final line in raw.split('\r\n')) {
      if (line.isEmpty) continue;

      if (line.startsWith('PING')) {
        _send(line.replaceFirst('PING', 'PONG'));
        continue;
      }

      if (line.startsWith('PONG')) {
        _reconnectAttempt = 0;
        continue;
      }

      if (line.contains('GLOBALUSERSTATE') || line.contains('USERSTATE')) {
        final msg = parseIrcMessage(line);
        if (msg != null) {
          final color = msg.tags['color'];
          if (color != null && color.isNotEmpty) {
            _userColorController.add(color);
          }
        }
        continue;
      }

      if (line.contains('PRIVMSG ') && _username != null) {
        final msg = parseIrcMessage(line);
        if (msg != null && msg.command == 'PRIVMSG' && msg.prefix != null) {
          final sender = msg.prefix!.contains('!')
              ? msg.prefix!.split('!')[0].toLowerCase()
              : msg.prefix!.toLowerCase();
          if (sender == _username) {
            _ownMessageController.add(msg);
            continue;
          }
        }
      }
    }
  }

  void join(String channel) {
    _channels.add(channel);
    if (_channel != null) {
      _send('JOIN #$channel');
    }
  }

  void part(String channel) {
    _channels.remove(channel);
    if (_channel != null) {
      _send('PART #$channel');
    }
  }

  void dispose() {
    _disposed = true;
    _reconnecting = false;
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _streamSub?.cancel();
    _channel?.sink.close();
    _ownMessageController.close();
    _userColorController.close();
  }
}
