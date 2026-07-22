import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/twitch_badge.dart';
import '../models/twitch_message.dart';

class EventSubService {
  static const _wsUrl = 'wss://eventsub.wss.twitch.tv/ws';

  WebSocketChannel? _channel;
  String? _sessionId;
  Timer? _keepaliveTimer;
  int _keepaliveTimeout = 10;
  var _sessionCompleter = Completer<String?>();
  StreamSubscription<dynamic>? _streamSub;
  bool _reconnecting = false;
  int _reconnectAttempt = 0;
  final _channelUserIds = <String, String>{};

  final _messageController = StreamController<TwitchMessage>.broadcast(
    sync: true,
  );
  final _statusController = StreamController<EventSubStatus>.broadcast(
    sync: true,
  );
  final _deleteController =
      StreamController<
        ({String messageId, String targetUser, String channel})
      >.broadcast(sync: true);
  final _banController =
      StreamController<
        ({
          String user,
          String? reason,
          bool isTimeout,
          String? duration,
          String channel,
        })
      >.broadcast(sync: true);

  bool get isConnected => _channel != null;
  String? get sessionId => _sessionId;

  Stream<TwitchMessage> get onMessage => _messageController.stream;
  Stream<EventSubStatus> get onStatus => _statusController.stream;
  Stream<({String messageId, String targetUser, String channel})>
  get onMessageDeleted => _deleteController.stream;
  Stream<
    ({
      String user,
      String? reason,
      bool isTimeout,
      String? duration,
      String channel,
    })
  >
  get onBan => _banController.stream;

  void setChannelMapping(String broadcasterUserId, String channelName) {
    _channelUserIds[broadcasterUserId] = channelName;
  }

  String? _channelFromPayload(Map<String, dynamic> msg) {
    try {
      final payload = msg['payload'] as Map<String, dynamic>;
      final sub = payload['subscription'] as Map<String, dynamic>;
      final condition = sub['condition'] as Map<String, dynamic>;
      final userId = condition['broadcaster_user_id'] as String;
      return _channelUserIds[userId];
    } catch (_) {
      return null;
    }
  }

  Future<String?> waitForSession() {
    if (_sessionId != null) return Future.value(_sessionId);
    return _sessionCompleter.future;
  }

  Future<void> connect({String? url}) async {
    if (url != null) _reconnectAttempt = 0;
    disconnect(emitStatus: false);
    _sessionCompleter = Completer<String?>();
    _statusController.add(EventSubStatus.connecting);

    try {
      _channel = WebSocketChannel.connect(Uri.parse(url ?? _wsUrl));
      await _channel!.ready;

      _streamSub = _channel!.stream.listen(
        (raw) {
          final msg = jsonDecode(raw as String) as Map<String, dynamic>;
          _handleMessage(msg);
        },
        onError: (e) {
          debugPrint('EventSub stream error: $e');
          _safeComplete(null);
          _statusController.add(EventSubStatus.disconnected);
          _scheduleReconnect();
        },
        onDone: () {
          _safeComplete(null);
          _statusController.add(EventSubStatus.disconnected);
          _scheduleReconnect();
        },
      );
    } catch (e) {
      _safeComplete(null);
      _statusController.add(EventSubStatus.disconnected);
      debugPrint('EventSub connect error: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_reconnecting) return;
    _reconnecting = true;
    _reconnectAttempt++;
    final base = Duration(
      seconds: min(pow(2, _reconnectAttempt - 1).toInt(), 30),
    );
    final jitter = 0.75 + Random().nextDouble() * 0.5;
    final delay = Duration(
      milliseconds: (base.inMilliseconds * jitter).toInt(),
    );
    Timer(delay, () {
      _reconnecting = false;
      connect();
    });
  }

  void _safeComplete(String? value) {
    if (!_sessionCompleter.isCompleted) {
      _sessionCompleter.complete(value);
    }
  }

  void _handleMessage(Map<String, dynamic> msg) {
    final meta = msg['metadata'] as Map<String, dynamic>;
    final type = meta['message_type'] as String;
    final subType = meta['subscription_type'] as String?;

    switch (type) {
      case 'session_welcome':
        _onWelcome(msg);
      case 'session_keepalive':
        _onKeepalive();
      case 'notification':
        switch (subType) {
          case 'channel.chat.message_delete':
            _onMessageDeleted(msg);
          case 'channel.ban':
            _onBan(msg);
          default:
            _onNotification(msg);
        }
      case 'session_reconnect':
        _handleReconnect(msg);
      case 'revocation':
        debugPrint('EventSub subscription revoked');
    }

    _resetKeepalive();
  }

  void _onWelcome(Map<String, dynamic> msg) {
    final payload = msg['payload'] as Map<String, dynamic>;
    final session = payload['session'] as Map<String, dynamic>;
    _sessionId = session['id'] as String;
    _safeComplete(_sessionId);
    _keepaliveTimeout = session['keepalive_timeout_seconds'] as int? ?? 10;
    _resetKeepalive();
    _statusController.add(EventSubStatus.connected);
    _reconnectAttempt = 0;
  }

  void _onKeepalive() {}

  void _handleReconnect(Map<String, dynamic> msg) {
    try {
      final payload = msg['payload'] as Map<String, dynamic>;
      final session = payload['session'] as Map<String, dynamic>;
      final reconnectUrl = session['reconnect_url'] as String?;
      if (reconnectUrl != null && reconnectUrl.isNotEmpty) {
        debugPrint('EventSub reconnecting to $reconnectUrl');
        connect(url: reconnectUrl);
      }
    } catch (e) {
      debugPrint('EventSub reconnect failed: $e');
    }
  }

  void _resetKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer(Duration(seconds: _keepaliveTimeout * 2), () {
      debugPrint('EventSub keepalive timeout – reconnecting');
      connect();
    });
  }

  void _onNotification(Map<String, dynamic> msg) {
    final payload = msg['payload'] as Map<String, dynamic>;
    final event = payload['event'] as Map<String, dynamic>;
    final channel = _channelFromPayload(msg);

    final chatter = event['chatter_user_name'] as String? ?? 'unknown';
    final chatterLogin = event['chatter_user_login'] as String?;
    final chatterId = event['chatter_user_id'] as String?;
    final messageData = event['message'] as Map<String, dynamic>?;
    final text = messageData?['text'] as String? ?? '';
    final color = event['color'] as String?;
    final messageId = event['message_id'] as String?;
    final sourceId = event['source_broadcaster_user_id'] as String?;
    final sourceName = event['source_broadcaster_user_name'] as String?;

    final user = TwitchMessage.resolveUser(
      login: chatterLogin ?? chatter,
      displayName: chatter,
    );

    // EventSub wraps /me messages in \x01ACTION ... \x01
    bool isAction = false;
    String displayText = text;
    if (displayText.startsWith('\x01ACTION ') && displayText.endsWith('\x01')) {
      isAction = true;
      displayText = displayText.substring(8, displayText.length - 1);
    }

    String? replyParentId;
    String? replyUser;
    String? replyText;
    final reply = event['reply'] as Map<String, dynamic>?;
    if (reply != null) {
      replyParentId = reply['parent_message_id'] as String?;
      replyUser = reply['parent_user_name'] as String?;
      replyText = reply['parent_message_body'] as String?;
      if (replyUser != null) {
        final prefix = '@${replyUser.toLowerCase()} ';
        final lower = displayText.toLowerCase();
        if (lower.startsWith(prefix)) {
          displayText = displayText.substring(prefix.length);
        }
      }
    }

    // Parse badges from EventSub
    List<MessageBadge>? badges;
    final badgeList = event['badges'] as List<dynamic>?;
    if (badgeList != null && badgeList.isNotEmpty) {
      badges = [];
      for (final b in badgeList) {
        final bMap = b as Map<String, dynamic>;
        final setId = bMap['set_id'] as String?;
        final id = bMap['id'] as String?;
        if (setId != null && id != null) {
          badges.add(MessageBadge(setId: setId, versionId: id));
        }
      }
      if (badges.isEmpty) badges = null;
    }

    // Parse emote fragments from EventSub
    final fragments = messageData?['fragments'] as List<dynamic>?;
    List<EmotePosition>? emotePositions;
    if (fragments != null) {
      emotePositions = [];
      for (final frag in fragments) {
        final fragMap = frag as Map<String, dynamic>;
        if (fragMap['type'] == 'emote') {
          final emoteId =
              (fragMap['emote'] as Map<String, dynamic>?)?['id'] as String?;
          if (emoteId != null) {
            final emoteText = fragMap['text'] as String? ?? '';
            int searchStart = 0;
            while (true) {
              final idx = displayText.indexOf(emoteText, searchStart);
              if (idx == -1) break;
              emotePositions.add(
                EmotePosition(
                  emoteId: emoteId,
                  startIndex: idx,
                  endIndex: idx + emoteText.length,
                  emoteCode: emoteText,
                ),
              );
              searchStart = idx + emoteText.length;
            }
          }
        }
      }
      if (emotePositions.isEmpty) emotePositions = null;
    }

    _messageController.add(
      TwitchMessage(
        login: user.login,
        displayName: user.displayName,
        text: displayText,
        color: color,
        isAction: isAction,
        messageId: messageId,
        channel: channel,
        replyToParentId: replyParentId,
        replyToUser: replyUser,
        replyToText: replyText,
        userId: chatterId,
        emotePositions: emotePositions,
        badges: badges,
        sourceBroadcasterId: sourceId,
        sourceBroadcasterName: sourceName,
      ),
    );
  }

  void _onMessageDeleted(Map<String, dynamic> msg) {
    final payload = msg['payload'] as Map<String, dynamic>;
    final event = payload['event'] as Map<String, dynamic>;
    final channel = _channelFromPayload(msg) ?? '';
    final messageId = event['message_id'] as String?;
    final targetUser = event['target_user_name'] as String? ?? 'unknown';
    if (messageId != null) {
      _deleteController.add((
        messageId: messageId,
        targetUser: targetUser,
        channel: channel,
      ));
    }
  }

  void _onBan(Map<String, dynamic> msg) {
    final payload = msg['payload'] as Map<String, dynamic>;
    final event = payload['event'] as Map<String, dynamic>;
    final channel = _channelFromPayload(msg) ?? '';
    final user = event['user_name'] as String? ?? 'unknown';
    final reason = event['reason'] as String?;
    final endsAt = event['ends_at'] as String?;
    final isTimeout = endsAt != null && endsAt.isNotEmpty;
    String? duration;
    if (isTimeout) {
      try {
        final end = DateTime.parse(endsAt);
        final diff = end.difference(DateTime.now());
        if (diff.inSeconds >= 60) {
          duration = '${diff.inMinutes}m';
        } else {
          duration = '${diff.inSeconds}s';
        }
      } catch (_) {
        duration = null;
      }
    }
    _banController.add((
      user: user,
      reason: reason,
      isTimeout: isTimeout,
      duration: duration,
      channel: channel,
    ));
  }

  void disconnect({bool emitStatus = true}) {
    _reconnecting = false;
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _sessionId = null;
    _streamSub?.cancel();
    _streamSub = null;
    _channel?.sink.close();
    _channel = null;
    _safeComplete(null);
    if (emitStatus) _statusController.add(EventSubStatus.disconnected);
  }

  @visibleForTesting
  void handleRawMessage(Map<String, dynamic> msg) => _handleMessage(msg);

  @visibleForTesting
  void emitConnected() {
    _sessionId = 'test-session-id';
    _keepaliveTimeout = 10;
    _statusController.add(EventSubStatus.connected);
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _statusController.close();
    _deleteController.close();
    _banController.close();
  }
}

enum EventSubStatus { connecting, connected, disconnected }
