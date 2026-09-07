import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/point_rewards.dart';
import 'connectivity_service.dart';
import '../util/constants.dart';
import '../util/log.dart';

/// A channel.moderate v2 event. `action` is ban, timeout, delete, mod, etc.
/// Mode toggles (slow, followers, ...) and term decisions carry no target;
/// term actions carry [terms]; everything else follows the old fields.
class ModerationEvent {
  final String channel;
  final String action;
  final String moderatorName;
  final String? targetName;
  final String? reason;
  final int? durationSeconds;
  final String? messageId;
  final String? messageBody;
  final List<String> terms;

  ModerationEvent({
    required this.channel,
    required this.action,
    required this.moderatorName,
    this.targetName,
    this.reason,
    this.durationSeconds,
    this.messageId,
    this.messageBody,
    this.terms = const [],
  });
}

/// An AutoMod queue event. [status] is held (new) or the resolution that
/// removed it from the queue: approved, denied, expired.
class AutomodHeldEvent {
  final String channel;
  final String messageId;
  final String userLogin;
  final String text;
  final String category;
  final String status;

  AutomodHeldEvent({
    required this.channel,
    required this.messageId,
    required this.userLogin,
    required this.text,
    required this.category,
    required this.status,
  });
}

/// A shield mode toggle. [active] is true on begin, false on end.
class ShieldModeEvent {
  final String channel;
  final bool active;
  final String moderatorName;

  ShieldModeEvent({
    required this.channel,
    required this.active,
    required this.moderatorName,
  });
}

/// A shoutout. [kind] is create (this channel shouted someone out) or
/// receive (this channel was shouted out).
class ShoutoutEvent {
  final String channel;
  final String kind;
  final String fromLogin;
  final String toLogin;
  final String moderatorName;

  ShoutoutEvent({
    required this.channel,
    required this.kind,
    required this.fromLogin,
    required this.toLogin,
    required this.moderatorName,
  });
}

/// A warning lifecycle event. [kind] is send or acknowledge.
class WarningEvent {
  final String channel;
  final String kind;
  final String moderatorName;
  final String userLogin;
  final String? reason;

  WarningEvent({
    required this.channel,
    required this.kind,
    required this.moderatorName,
    required this.userLogin,
    this.reason,
  });
}

/// An unban request event. [kind] is create or resolve.
class UnbanRequestEvent {
  final String channel;
  final String kind;
  final String userLogin;
  final String moderatorName;
  final String? resolutionText;

  UnbanRequestEvent({
    required this.channel,
    required this.kind,
    required this.userLogin,
    required this.moderatorName,
    this.resolutionText,
  });
}

/// A public AutoMod terms change. Private-term changes never arrive.
class AutomodTermsEvent {
  final String channel;

  /// add or remove.
  final String action;

  /// blocked or permitted.
  final String list;
  final List<String> terms;
  final String moderatorName;

  AutomodTermsEvent({
    required this.channel,
    required this.action,
    required this.list,
    required this.terms,
    required this.moderatorName,
  });
}

/// An AutoMod settings change.
class AutomodSettingsEvent {
  final String channel;
  final String moderatorName;

  AutomodSettingsEvent({required this.channel, required this.moderatorName});
}

/// A suspicious-user sighting or flag change. [kind] is message or update.
class SuspiciousUserEvent {
  final String channel;
  final String kind;
  final String userLogin;
  final String status;
  final List<String> types;
  final String? banEvasion;
  final List<String> sharedBanChannelIds;
  final String moderatorName;

  SuspiciousUserEvent({
    required this.channel,
    required this.kind,
    required this.userLogin,
    required this.status,
    this.types = const [],
    this.banEvasion,
    this.sharedBanChannelIds = const [],
    required this.moderatorName,
  });
}

/// A custom reward change. [kind] is add, update, or remove.
class PointRewardEvent {
  final String channel;
  final String kind;
  final PointReward reward;

  PointRewardEvent({
    required this.channel,
    required this.kind,
    required this.reward,
  });
}

/// A custom-reward redemption. [kind] is add or update.
class PointRedemptionEvent {
  final String channel;
  final String kind;
  final PointRedemption redemption;

  PointRedemptionEvent({
    required this.channel,
    required this.kind,
    required this.redemption,
  });
}

/// A hype train event. [kind] is begin, progress, or end.
class HypeTrainEvent {
  final String channel;
  final String kind;
  final int level;
  final int progress;
  final int total;
  final DateTime? expiresAt;
  final List<HypeTrainContribution> topContributions;

  HypeTrainEvent({
    required this.channel,
    required this.kind,
    required this.level,
    required this.progress,
    required this.total,
    this.expiresAt,
    this.topContributions = const [],
  });
}

class HypeTrainContribution {
  final String userName;
  final String type;
  final int total;

  HypeTrainContribution({
    required this.userName,
    required this.type,
    required this.total,
  });
}

/// A channel poll event. [kind] is begin, progress, or end.
class PollEvent {
  final String channel;
  final String kind;
  final String title;
  final List<PollChoice> choices;
  final String status;

  PollEvent({
    required this.channel,
    required this.kind,
    required this.title,
    required this.choices,
    required this.status,
  });
}

class PollChoice {
  final String title;
  final int votes;

  PollChoice({required this.title, required this.votes});
}

/// A channel prediction event. [kind] is begin, progress, lock, or end.
class PredictionEvent {
  final String channel;
  final String kind;
  final String title;
  final List<PredictionOutcome> outcomes;
  final String status;

  PredictionEvent({
    required this.channel,
    required this.kind,
    required this.title,
    required this.outcomes,
    required this.status,
  });
}

class PredictionOutcome {
  final String title;
  final int users;
  final int channelPoints;

  PredictionOutcome({
    required this.title,
    required this.users,
    required this.channelPoints,
  });
}

class EventSubService {
  static const _wsUrl = 'wss://eventsub.wss.twitch.tv/ws';
  static const _maxReconnectAttempts = 8;
  static const _connectTimeout = Duration(seconds: 10);

  final ConnectivityService? _connectivityService;

  WebSocketChannel? _channel;
  String? _sessionId;
  // Last frame arrival time; used by [isStale].
  DateTime _lastActivity = DateTime.now();
  Timer? _keepaliveTimer;
  Timer? _reconnectTimer;
  Timer? _connectTimer;
  int _keepaliveTimeout = 10;
  var _sessionCompleter = Completer<String?>();
  StreamSubscription<dynamic>? _streamSub;
  bool _reconnecting = false;
  bool _connecting = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;
  VoidCallback? _connectivityListener;
  bool _isOnline = true;
  final _channelUserIds = <String, String>{};

  final _moderationController = StreamController<ModerationEvent>.broadcast(
    sync: true,
  );
  final _automodHeldController = StreamController<AutomodHeldEvent>.broadcast(
    sync: true,
  );
  final _hypeTrainController = StreamController<HypeTrainEvent>.broadcast(
    sync: true,
  );
  final _pollController = StreamController<PollEvent>.broadcast(sync: true);
  final _predictionController = StreamController<PredictionEvent>.broadcast(
    sync: true,
  );
  final _shieldModeController = StreamController<ShieldModeEvent>.broadcast(
    sync: true,
  );
  final _shoutoutController = StreamController<ShoutoutEvent>.broadcast(
    sync: true,
  );
  final _warningController = StreamController<WarningEvent>.broadcast(
    sync: true,
  );
  final _unbanRequestController = StreamController<UnbanRequestEvent>.broadcast(
    sync: true,
  );
  final _automodTermsController = StreamController<AutomodTermsEvent>.broadcast(
    sync: true,
  );
  final _automodSettingsController =
      StreamController<AutomodSettingsEvent>.broadcast(sync: true);
  final _suspiciousUserController =
      StreamController<SuspiciousUserEvent>.broadcast(sync: true);
  final _pointRewardController = StreamController<PointRewardEvent>.broadcast(
    sync: true,
  );
  final _pointRedemptionController =
      StreamController<PointRedemptionEvent>.broadcast(sync: true);
  final _statusController = StreamController<EventSubStatus>.broadcast(
    sync: true,
  );

  bool get isConnected => _channel != null;
  String? get sessionId => _sessionId;

  /// True when socket exists but no frame arrived for >1.5x keepalive
  /// (zombie).
  bool get isStale {
    if (_channel == null) return false;
    final timeoutSeconds = (_keepaliveTimeout * 1.5).round();
    return DateTime.now().difference(_lastActivity).inSeconds > timeoutSeconds;
  }

  /// Tears down zombie session and reconnects. Used on app resume.
  Future<void> forceReconnect() {
    if (_disposed || _connecting) return Future.value();
    disconnect();
    return connect();
  }

  EventSubService({this._connectivityService});

  Stream<ModerationEvent> get onModeration => _moderationController.stream;
  Stream<AutomodHeldEvent> get onAutomodHeld => _automodHeldController.stream;
  Stream<HypeTrainEvent> get onHypeTrain => _hypeTrainController.stream;
  Stream<PollEvent> get onPoll => _pollController.stream;
  Stream<PredictionEvent> get onPrediction => _predictionController.stream;
  Stream<ShieldModeEvent> get onShieldMode => _shieldModeController.stream;
  Stream<ShoutoutEvent> get onShoutout => _shoutoutController.stream;
  Stream<WarningEvent> get onWarning => _warningController.stream;
  Stream<UnbanRequestEvent> get onUnbanRequest =>
      _unbanRequestController.stream;
  Stream<AutomodTermsEvent> get onAutomodTerms =>
      _automodTermsController.stream;
  Stream<AutomodSettingsEvent> get onAutomodSettings =>
      _automodSettingsController.stream;
  Stream<SuspiciousUserEvent> get onSuspiciousUser =>
      _suspiciousUserController.stream;
  Stream<PointRewardEvent> get onPointReward => _pointRewardController.stream;
  Stream<PointRedemptionEvent> get onPointRedemption =>
      _pointRedemptionController.stream;
  Stream<EventSubStatus> get onStatus => _statusController.stream;

  void setChannelMapping(String broadcasterUserId, String channelName) {
    _channelUserIds[broadcasterUserId] = channelName;
  }

  String? _channelFromPayload(Map<String, dynamic> msg) {
    final payload = msg['payload'] as Map<String, dynamic>?;
    final sub = payload?['subscription'] as Map<String, dynamic>?;
    final condition = sub?['condition'] as Map<String, dynamic>?;
    final userId = condition?['broadcaster_user_id'] as String?;
    if (userId == null) return null;
    return _channelUserIds[userId];
  }

  @visibleForTesting
  Future<String?> waitForSession() {
    if (_sessionId != null) return Future.value(_sessionId);
    return _sessionCompleter.future;
  }

  Future<void> connect({String? url}) async {
    if (_connecting || _disposed) return;
    _connecting = true;
    try {
      _ensureConnectivityListener();
      if (url != null) _reconnectAttempt = 0;
      disconnect(emitStatus: false);
      _sessionCompleter = Completer<String?>();
      _statusController.add(EventSubStatus.connecting);

      try {
        _channel = WebSocketChannel.connect(Uri.parse(url ?? _wsUrl));
        await _waitForReady();

        _streamSub = _channel!.stream.listen(
          (raw) {
            if (raw is! String) return;
            try {
              final msg = jsonDecode(raw) as Map<String, dynamic>;
              _handleMessage(msg);
            } catch (e) {
              logDebug('EventSub frame parse error: $e');
            }
          },
          onError: (e) {
            logDebug('EventSub stream error: $e');
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
        // Prevent stale socket from keeping isConnected true on resume.
        _channel = null;
        _streamSub = null;
        _statusController.add(EventSubStatus.disconnected);
        logDebug('EventSub connect error: $e');
        _scheduleReconnect();
      }
    } finally {
      _connecting = false;
    }
  }

  // Exponential backoff (2^(n-1)), capped 30s with jitter.
  void _scheduleReconnect() {
    if (_reconnecting || _disposed) return;
    if (!_isOnline) return;
    if (_reconnectAttempt >= _maxReconnectAttempts) {
      logDebug('EventSub max reconnect attempts reached - giving up');
      return;
    }
    _reconnecting = true;
    _reconnectAttempt++;
    final base = Duration(
      seconds: min(pow(2, _reconnectAttempt - 1).toInt(), 30),
    );
    final delay = applyReconnectJitter(base);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      _reconnecting = false;
      connect();
    });
  }

  void _safeComplete(String? value) {
    if (!_sessionCompleter.isCompleted) {
      _sessionCompleter.complete(value);
    }
  }

  /// Waits for handshake with a timeout; timer cleaned up on
  /// disconnect/dispose.
  Future<void> _waitForReady() {
    final channel = _channel;
    if (channel == null) return Future.value();
    final completer = Completer<void>();
    _connectTimer?.cancel();
    _connectTimer = Timer(_connectTimeout, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('EventSub connect timed out'));
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

  void _handleMessage(Map<String, dynamic> msg) {
    try {
      final meta = msg['metadata'] as Map<String, dynamic>?;
      final type = meta?['message_type'] as String?;
      if (type == null) return;

      switch (type) {
        case 'session_welcome':
          _onWelcome(msg);
        case 'notification':
          _onNotification(msg);
        case 'session_reconnect':
          _handleReconnect(msg);
        case 'revocation':
          logDebug('EventSub subscription revoked');
      }

      _resetKeepalive();
    } catch (e) {
      logDebug('EventSub message parse error: $e');
    }
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

  void _handleReconnect(Map<String, dynamic> msg) {
    try {
      final payload = msg['payload'] as Map<String, dynamic>;
      final session = payload['session'] as Map<String, dynamic>;
      final reconnectUrl = session['reconnect_url'] as String?;
      if (reconnectUrl != null && reconnectUrl.isNotEmpty) {
        logDebug('EventSub reconnecting to $reconnectUrl');
        connect(url: reconnectUrl);
      }
    } catch (e) {
      logDebug('EventSub reconnect failed: $e');
    }
  }

  // Reset on any message (Twitch may skip keepalives). 1.5x grace period.
  void _resetKeepalive() {
    _lastActivity = DateTime.now();
    _keepaliveTimer?.cancel();
    final timeoutSeconds = (_keepaliveTimeout * 1.5).round();
    _keepaliveTimer = Timer(Duration(seconds: timeoutSeconds), () {
      logDebug('EventSub keepalive timeout - reconnecting');
      _scheduleReconnect();
    });
  }

  /// Routes notifications into typed events. Mod is channel-agnostic;
  /// hype/poll/prediction are broadcaster-only.
  void _onNotification(Map<String, dynamic> msg) {
    final meta = msg['metadata'] as Map<String, dynamic>;
    final type = meta['subscription_type'] as String? ?? '';
    final payload = msg['payload'] as Map<String, dynamic>;
    final event = payload['event'] as Map<String, dynamic>;
    final channel = _channelFromPayload(msg);

    if (type.startsWith('channel.hype_train.')) {
      if (channel == null) return;
      _emitHypeTrain(
        channel,
        event,
        type.substring('channel.hype_train.'.length),
      );
    } else if (type.startsWith('channel.poll.')) {
      if (channel == null) return;
      _emitPoll(channel, event, type.substring('channel.poll.'.length));
    } else if (type.startsWith('channel.prediction.')) {
      if (channel == null) return;
      _emitPrediction(
        channel,
        event,
        type.substring('channel.prediction.'.length),
      );
    } else if (type == 'channel.moderate') {
      _emitModeration(channel, event);
    } else if (type == 'channel.shield_mode.begin' ||
        type == 'channel.shield_mode.end') {
      if (channel == null) return;
      _emitShieldMode(channel, event, type.endsWith('.begin'));
    } else if (type == 'channel.shoutout.create' ||
        type == 'channel.shoutout.receive') {
      if (channel == null) return;
      _emitShoutout(channel, event, type.endsWith('.create'));
    } else if (type == 'channel.warning.send' ||
        type == 'channel.warning.acknowledge') {
      if (channel == null) return;
      _emitWarning(channel, event, type.endsWith('.send'));
    } else if (type == 'channel.unban_request.create' ||
        type == 'channel.unban_request.resolve') {
      if (channel == null) return;
      _emitUnbanRequest(channel, event, type.endsWith('.create'));
    } else if (type == 'automod.terms.update') {
      if (channel == null) return;
      _emitAutomodTerms(channel, event);
    } else if (type == 'automod.settings.update') {
      if (channel == null) return;
      _emitAutomodSettings(channel, event);
    } else if (type == 'channel.suspicious_user.message' ||
        type == 'channel.suspicious_user.update') {
      if (channel == null) return;
      _emitSuspiciousUser(channel, event, type.endsWith('.message'));
    } else if (type == 'channel.channel_points_custom_reward.add' ||
        type == 'channel.channel_points_custom_reward.update' ||
        type == 'channel.channel_points_custom_reward.remove') {
      if (channel == null) return;
      _emitPointReward(channel, event, type.split('.').last);
    } else if (type == 'channel.channel_points_custom_reward_redemption.add' ||
        type == 'channel.channel_points_custom_reward_redemption.update') {
      if (channel == null) return;
      _emitPointRedemption(channel, event, type.endsWith('.add'));
    } else if (type == 'automod.message.hold') {
      if (channel == null) return;
      _emitAutomodHeld(channel, event, 'held');
    } else if (type == 'automod.message.update') {
      if (channel == null) return;
      final status = (event['status'] as String?)?.toLowerCase() ?? 'updated';
      _emitAutomodHeld(channel, event, status);
    }
  }

  void _emitAutomodHeld(
    String channel,
    Map<String, dynamic> event,
    String status,
  ) {
    final messageId = event['message_id'] as String?;
    if (messageId == null || messageId.isEmpty) return;
    // v1 sends message as a bare string; v2 nests it in a message object.
    final message = event['message'];
    final text = message is String
        ? message
        : (message as Map?)?['text'] as String? ?? '';
    // v2 nests the category in the automod object; blocked-term holds have
    // no category, so the reason ('blocked_term') stands in.
    final automod = event['automod'] as Map?;
    _automodHeldController.add(
      AutomodHeldEvent(
        channel: channel,
        messageId: messageId,
        userLogin: event['user_login'] as String? ?? '',
        text: text,
        category:
            automod?['category'] as String? ??
            event['category'] as String? ??
            event['reason'] as String? ??
            'automod',
        status: status,
      ),
    );
  }

  void _emitHypeTrain(String channel, Map<String, dynamic> event, String kind) {
    DateTime? expiresAt;
    final exp = event['expires_at'] as String?;
    if (exp != null) expiresAt = DateTime.tryParse(exp);

    final contributions = <HypeTrainContribution>[];
    for (final c in (event['top_contributions'] as List? ?? const [])) {
      final m = c as Map<String, dynamic>;
      contributions.add(
        HypeTrainContribution(
          userName: m['user_name'] as String? ?? 'Anonymous',
          type: m['type'] as String? ?? '',
          total: m['total'] as int? ?? 0,
        ),
      );
    }

    _hypeTrainController.add(
      HypeTrainEvent(
        channel: channel,
        kind: kind,
        level: event['level'] as int? ?? 1,
        progress: event['progress'] as int? ?? 0,
        total: event['total'] as int? ?? 0,
        expiresAt: expiresAt,
        topContributions: contributions,
      ),
    );
  }

  void _emitPoll(String channel, Map<String, dynamic> event, String kind) {
    final choices = <PollChoice>[];
    for (final c in (event['choices'] as List? ?? const [])) {
      final m = c as Map<String, dynamic>;
      choices.add(
        PollChoice(
          title: m['title'] as String? ?? '',
          votes: m['votes'] as int? ?? 0,
        ),
      );
    }
    _pollController.add(
      PollEvent(
        channel: channel,
        kind: kind,
        title: event['title'] as String? ?? '',
        choices: choices,
        status: event['status'] as String? ?? '',
      ),
    );
  }

  void _emitPrediction(
    String channel,
    Map<String, dynamic> event,
    String kind,
  ) {
    final outcomes = <PredictionOutcome>[];
    for (final o in (event['outcomes'] as List? ?? const [])) {
      final m = o as Map<String, dynamic>;
      outcomes.add(
        PredictionOutcome(
          title: m['title'] as String? ?? '',
          users: m['users'] as int? ?? 0,
          channelPoints: m['channel_points'] as int? ?? 0,
        ),
      );
    }
    _predictionController.add(
      PredictionEvent(
        channel: channel,
        kind: kind,
        title: event['title'] as String? ?? '',
        outcomes: outcomes,
        status: event['status'] as String? ?? '',
      ),
    );
  }

  void _emitShieldMode(
    String channel,
    Map<String, dynamic> event,
    bool active,
  ) {
    _shieldModeController.add(
      ShieldModeEvent(
        channel: channel,
        active: active,
        moderatorName: event['moderator_user_name'] as String? ?? 'A moderator',
      ),
    );
  }

  void _emitShoutout(String channel, Map<String, dynamic> event, bool created) {
    // Create fires on the sender's channel (broadcaster -> to_broadcaster);
    // receive fires on the target's channel (from_broadcaster -> broadcaster).
    final from =
        event['from_broadcaster_user_login'] as String? ??
        event['broadcaster_user_login'] as String? ??
        '';
    final to =
        event['to_broadcaster_user_login'] as String? ??
        event['broadcaster_user_login'] as String? ??
        '';
    _shoutoutController.add(
      ShoutoutEvent(
        channel: channel,
        kind: created ? 'create' : 'receive',
        fromLogin: from,
        toLogin: to,
        moderatorName: event['moderator_user_name'] as String? ?? 'A moderator',
      ),
    );
  }

  void _emitWarning(String channel, Map<String, dynamic> event, bool sent) {
    _warningController.add(
      WarningEvent(
        channel: channel,
        kind: sent ? 'send' : 'acknowledge',
        moderatorName: event['moderator_user_name'] as String? ?? 'A moderator',
        userLogin: event['user_login'] as String? ?? '',
        reason: event['reason'] as String?,
      ),
    );
  }

  void _emitUnbanRequest(
    String channel,
    Map<String, dynamic> event,
    bool created,
  ) {
    _unbanRequestController.add(
      UnbanRequestEvent(
        channel: channel,
        kind: created ? 'create' : 'resolve',
        userLogin: event['user_login'] as String? ?? '',
        moderatorName: event['moderator_user_name'] as String? ?? 'A moderator',
        resolutionText: event['resolution_text'] as String?,
      ),
    );
  }

  void _emitAutomodTerms(String channel, Map<String, dynamic> event) {
    final rawTerms = event['terms'];
    _automodTermsController.add(
      AutomodTermsEvent(
        channel: channel,
        action: event['action'] as String? ?? 'add',
        list: event['list'] as String? ?? 'blocked',
        terms: rawTerms is List
            ? rawTerms.whereType<String>().toList()
            : const [],
        moderatorName: event['moderator_user_name'] as String? ?? 'A moderator',
      ),
    );
  }

  void _emitAutomodSettings(String channel, Map<String, dynamic> event) {
    _automodSettingsController.add(
      AutomodSettingsEvent(
        channel: channel,
        moderatorName: event['moderator_user_name'] as String? ?? 'A moderator',
      ),
    );
  }

  void _emitSuspiciousUser(
    String channel,
    Map<String, dynamic> event,
    bool messaged,
  ) {
    final rawTypes = event['types'];
    final rawShared = event['shared_ban_channel_ids'];
    _suspiciousUserController.add(
      SuspiciousUserEvent(
        channel: channel,
        kind: messaged ? 'message' : 'update',
        userLogin: event['user_login'] as String? ?? '',
        status:
            ((event['low_trust_status'] ?? event['status']) as String?)
                ?.toLowerCase() ??
            '',
        types: rawTypes is List
            ? rawTypes.whereType<String>().toList()
            : const [],
        banEvasion: event['ban_evasion_evaluation'] as String?,
        sharedBanChannelIds: rawShared is List
            ? rawShared.whereType<String>().toList()
            : const [],
        moderatorName: event['moderator_user_name'] as String? ?? 'A moderator',
      ),
    );
  }

  void _emitPointReward(
    String channel,
    Map<String, dynamic> event,
    String kind,
  ) {
    // add/update/remove carry the reward object, sometimes nested.
    final rewardObj = event['reward'] as Map<String, dynamic>? ?? event;
    _pointRewardController.add(
      PointRewardEvent(
        channel: channel,
        kind: kind,
        reward: PointReward.fromJson(rewardObj),
      ),
    );
  }

  void _emitPointRedemption(
    String channel,
    Map<String, dynamic> event,
    bool added,
  ) {
    _pointRedemptionController.add(
      PointRedemptionEvent(
        channel: channel,
        kind: added ? 'add' : 'update',
        redemption: PointRedemption.fromJson(event),
      ),
    );
  }

  void _emitModeration(String? channel, Map<String, dynamic> event) {
    if (channel == null) return;

    final action = event['action'] as String? ?? '';
    if (action.isEmpty) return;
    final moderatorName =
        event['moderator_user_name'] as String? ?? 'A moderator';

    // Map shared_chat_* actions to their base action.
    var baseAction = action;
    if (action.startsWith('shared_chat_')) {
      baseAction = action.substring('shared_chat_'.length);
    }

    String? targetName;
    String? reason;
    int? durationSeconds;
    String? messageId;
    String? messageBody;
    var terms = const <String>[];

    final metaObj =
        event[baseAction] as Map<String, dynamic>? ??
        (baseAction == action ? null : event[action] as Map<String, dynamic>?);
    switch (baseAction) {
      case 'ban':
      case 'unban':
      case 'mod':
      case 'unmod':
      case 'vip':
      case 'unvip':
      case 'untimeout':
        targetName = metaObj?['user_name'] as String?;
        reason = metaObj?['reason'] as String?;
        break;
      case 'warn':
        targetName = metaObj?['user_name'] as String?;
        reason = metaObj?['reason'] as String?;
        break;
      case 'timeout':
        targetName = metaObj?['user_name'] as String?;
        reason = metaObj?['reason'] as String?;
        final expiresAt = metaObj?['expires_at'] as String?;
        if (expiresAt != null) {
          final parsed = DateTime.tryParse(expiresAt);
          if (parsed != null) {
            durationSeconds = parsed
                .difference(DateTime.now().toUtc())
                .inSeconds
                .clamp(0, 1 << 30);
          }
        }
        break;
      case 'delete':
        targetName = metaObj?['user_name'] as String?;
        messageId = metaObj?['message_id'] as String?;
        messageBody = metaObj?['message_body'] as String?;
        break;
      case 'add_blocked_term':
      case 'remove_blocked_term':
      case 'add_permitted_term':
      case 'remove_permitted_term':
        // Term decisions nest under automod_terms, not under the action.
        final termsObj = event['automod_terms'] as Map<String, dynamic>?;
        final rawTerms = termsObj?['terms'];
        if (rawTerms is List) terms = rawTerms.whereType<String>().toList();
        break;
      case 'approve_unban_request':
      case 'deny_unban_request':
        final requestObj =
            event['unban_request'] as Map<String, dynamic>? ?? metaObj;
        targetName = requestObj?['user_name'] as String?;
        reason =
            requestObj?['resolution_text'] as String? ??
            requestObj?['reason'] as String?;
        break;
      case 'slow':
      case 'slowoff':
      case 'followers':
      case 'followersoff':
      case 'emoteonly':
      case 'emoteonlyoff':
      case 'subscribers':
      case 'subscribersoff':
      case 'uniquechat':
      case 'uniquechatoff':
      case 'raid':
      case 'unraid':
      case 'clear':
        // Bare actions: no payload fields, the action is the whole story.
        break;
    }

    _moderationController.add(
      ModerationEvent(
        channel: channel,
        action: baseAction,
        moderatorName: moderatorName,
        targetName: targetName,
        reason: reason,
        durationSeconds: durationSeconds,
        messageId: messageId,
        messageBody: messageBody,
        terms: terms,
      ),
    );
  }

  void _ensureConnectivityListener() {
    final service = _connectivityService;
    if (service == null || _connectivityListener != null) return;
    _connectivityListener = () {
      final online = service.isOnline;
      final wasOffline = !_isOnline;
      _isOnline = online;
      if (wasOffline && online && _channel == null && !_connecting) {
        _reconnectAttempt = 0;
        connect();
      }
    };
    _isOnline = service.isOnline;
    service.addListener(_connectivityListener!);
  }

  void disconnect({bool emitStatus = true}) {
    _reconnecting = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    _sessionId = null;
    _streamSub?.cancel();
    _streamSub = null;
    _channel?.sink.close();
    _channel = null;
    _reconnectAttempt = 0;
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
    _disposed = true;
    disconnect();
    final listener = _connectivityListener;
    if (listener != null) _connectivityService?.removeListener(listener);
    _connectivityListener = null;
    _moderationController.close();
    _automodHeldController.close();
    _hypeTrainController.close();
    _pollController.close();
    _predictionController.close();
    _shieldModeController.close();
    _shoutoutController.close();
    _warningController.close();
    _unbanRequestController.close();
    _automodTermsController.close();
    _automodSettingsController.close();
    _suspiciousUserController.close();
    _pointRewardController.close();
    _pointRedemptionController.close();
    _statusController.close();
  }
}

enum EventSubStatus { connecting, connected, disconnected }
