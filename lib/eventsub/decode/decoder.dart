import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/point_rewards.dart';
import '../../util/log.dart';
import 'events.dart';

/// Lifts typed domain events out of EventSub notification frames. One
/// instance per transport: it subscribes to the transport's [onNotification]
/// stream and routes each frame by `subscription_type`.
class EventSubDecoder {
  EventSubDecoder(Stream<Map<String, dynamic>> source) {
    _subscription = source.listen(_onNotification);
  }

  late final StreamSubscription<Map<String, dynamic>> _subscription;
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

  /// Test hook into the same router the notification stream uses.
  @visibleForTesting
  void feed(Map<String, dynamic> frame) => _onNotification(frame);

  /// Maps each wire string to its enum once; unknown strings fall through to
  /// the unknown arm with the raw wire kept on the event.
  ModerationAction _moderationAction(String wire) => switch (wire) {
    'ban' => ModerationAction.ban,
    'unban' => ModerationAction.unban,
    'timeout' => ModerationAction.timeout,
    'untimeout' => ModerationAction.untimeout,
    'mod' => ModerationAction.mod,
    'unmod' => ModerationAction.unmod,
    'vip' => ModerationAction.vip,
    'unvip' => ModerationAction.unvip,
    'warn' => ModerationAction.warn,
    'delete' => ModerationAction.delete,
    'slow' => ModerationAction.slow,
    'slowoff' => ModerationAction.slowOff,
    'followers' => ModerationAction.followers,
    'followersoff' => ModerationAction.followersOff,
    'emoteonly' => ModerationAction.emoteOnly,
    'emoteonlyoff' => ModerationAction.emoteOnlyOff,
    'subscribers' => ModerationAction.subscribers,
    'subscribersoff' => ModerationAction.subscribersOff,
    'uniquechat' => ModerationAction.uniqueChat,
    'uniquechatoff' => ModerationAction.uniqueChatOff,
    'raid' => ModerationAction.raid,
    'unraid' => ModerationAction.unraid,
    'clear' => ModerationAction.clear,
    'add_blocked_term' => ModerationAction.addBlockedTerm,
    'remove_blocked_term' => ModerationAction.removeBlockedTerm,
    'add_permitted_term' => ModerationAction.addPermittedTerm,
    'remove_permitted_term' => ModerationAction.removePermittedTerm,
    'approve_unban_request' => ModerationAction.approveUnbanRequest,
    'deny_unban_request' => ModerationAction.denyUnbanRequest,
    _ => ModerationAction.unknown,
  };

  AutomodTermsAction _automodTermsAction(String wire) => switch (wire) {
    'add' => AutomodTermsAction.add,
    'remove' => AutomodTermsAction.remove,
    _ => AutomodTermsAction.unknown,
  };

  HypeTrainKind _hypeTrainKind(String wire) => switch (wire) {
    'begin' => HypeTrainKind.begin,
    'progress' => HypeTrainKind.progress,
    'end' => HypeTrainKind.end,
    _ => HypeTrainKind.unknown,
  };

  PollKind _pollKind(String wire) => switch (wire) {
    'begin' => PollKind.begin,
    'progress' => PollKind.progress,
    'end' => PollKind.end,
    _ => PollKind.unknown,
  };

  PredictionKind _predictionKind(String wire) => switch (wire) {
    'begin' => PredictionKind.begin,
    'progress' => PredictionKind.progress,
    'lock' => PredictionKind.lock,
    'end' => PredictionKind.end,
    _ => PredictionKind.unknown,
  };

  PointRewardKind _pointRewardKind(String wire) => switch (wire) {
    'add' => PointRewardKind.add,
    'update' => PointRewardKind.update,
    'remove' => PointRewardKind.remove,
    _ => PointRewardKind.unknown,
  };

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
    } else {
      logDebug('EventSub unknown subscription type: $type');
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
        kind: _hypeTrainKind(kind),
        rawKind: kind,
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
        kind: _pollKind(kind),
        rawKind: kind,
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
        kind: _predictionKind(kind),
        rawKind: kind,
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
        kind: created ? ShoutoutKind.create : ShoutoutKind.receive,
        rawKind: created ? 'create' : 'receive',
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
        kind: sent ? WarningKind.send : WarningKind.acknowledge,
        rawKind: sent ? 'send' : 'acknowledge',
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
        kind: created ? UnbanRequestKind.create : UnbanRequestKind.resolve,
        rawKind: created ? 'create' : 'resolve',
        userLogin: event['user_login'] as String? ?? '',
        moderatorName: event['moderator_user_name'] as String? ?? 'A moderator',
        resolutionText: event['resolution_text'] as String?,
      ),
    );
  }

  void _emitAutomodTerms(String channel, Map<String, dynamic> event) {
    final rawTerms = event['terms'];
    final action = event['action'] as String? ?? 'add';
    _automodTermsController.add(
      AutomodTermsEvent(
        channel: channel,
        action: _automodTermsAction(action),
        rawAction: action,
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
        kind: messaged ? SuspiciousUserKind.message : SuspiciousUserKind.update,
        rawKind: messaged ? 'message' : 'update',
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
        kind: _pointRewardKind(kind),
        rawKind: kind,
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
        kind: added ? PointRedemptionKind.add : PointRedemptionKind.update,
        rawKind: added ? 'add' : 'update',
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
    final kind = _moderationAction(baseAction);
    switch (kind) {
      case ModerationAction.ban:
      case ModerationAction.unban:
      case ModerationAction.mod:
      case ModerationAction.unmod:
      case ModerationAction.vip:
      case ModerationAction.unvip:
      case ModerationAction.untimeout:
        targetName = metaObj?['user_name'] as String?;
        reason = metaObj?['reason'] as String?;
        break;
      case ModerationAction.warn:
        targetName = metaObj?['user_name'] as String?;
        reason = metaObj?['reason'] as String?;
        break;
      case ModerationAction.timeout:
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
      case ModerationAction.delete:
        targetName = metaObj?['user_name'] as String?;
        messageId = metaObj?['message_id'] as String?;
        messageBody = metaObj?['message_body'] as String?;
        break;
      case ModerationAction.addBlockedTerm:
      case ModerationAction.removeBlockedTerm:
      case ModerationAction.addPermittedTerm:
      case ModerationAction.removePermittedTerm:
        // Term decisions nest under automod_terms, not under the action.
        final termsObj = event['automod_terms'] as Map<String, dynamic>?;
        final rawTerms = termsObj?['terms'];
        if (rawTerms is List) terms = rawTerms.whereType<String>().toList();
        break;
      case ModerationAction.approveUnbanRequest:
      case ModerationAction.denyUnbanRequest:
        final requestObj =
            event['unban_request'] as Map<String, dynamic>? ?? metaObj;
        targetName = requestObj?['user_name'] as String?;
        reason =
            requestObj?['resolution_text'] as String? ??
            requestObj?['reason'] as String?;
        break;
      case ModerationAction.slow:
      case ModerationAction.slowOff:
      case ModerationAction.followers:
      case ModerationAction.followersOff:
      case ModerationAction.emoteOnly:
      case ModerationAction.emoteOnlyOff:
      case ModerationAction.subscribers:
      case ModerationAction.subscribersOff:
      case ModerationAction.uniqueChat:
      case ModerationAction.uniqueChatOff:
      case ModerationAction.raid:
      case ModerationAction.unraid:
      case ModerationAction.clear:
      case ModerationAction.unknown:
        // Bare actions carry no payload fields; unknown future actions carry
        // nothing this version understands. Either way the action is the story.
        break;
    }

    _moderationController.add(
      ModerationEvent(
        channel: channel,
        action: kind,
        rawAction: baseAction,
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

  void dispose() {
    _subscription.cancel();
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
  }
}
