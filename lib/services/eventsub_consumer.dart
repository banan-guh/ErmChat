import 'dart:async';
import 'dart:ui' show Color;

import '../chat/channel/moderation.dart';
import '../chat/chat.dart';
import '../eventsub/decode/decoder.dart';
import '../eventsub/decode/events.dart';
import '../eventsub/topics.dart';
import '../util/mod_activity_format.dart' show formatModActivity;
import 'moderation_hub.dart';

/// Applies typed EventSub events to the chat kernel: mod feed complements,
/// warnings, the AutoMod queue, points, and widgets. The `channel.moderate`
/// family is handled by [ModerationHub] so moderation facts have one ingest
/// owner and one precedence decision.
class EventSubConsumer {
  EventSubConsumer({
    required this.chat,
    required this.topics,
    required this.moderation,
    required this.onSystemMessage,
    this.onHypeTrain,
    this.onPoll,
    this.onPrediction,
  });

  final Chat chat;
  final EventSubTopics topics;
  final ModerationHub moderation;
  final void Function(String, String, {Color? accent, String? messageId})
  onSystemMessage;
  final void Function(HypeTrainEvent event)? onHypeTrain;
  final void Function(PollEvent event)? onPoll;
  final void Function(PredictionEvent event)? onPrediction;

  bool _disposed = false;
  final _subscriptions = <StreamSubscription>[];

  /// Subscribes the typed streams and returns the subscriptions.
  /// Re-attaching cancels the previous subscriptions first.
  List<StreamSubscription> attach(EventSubDecoder decoder) {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions
      ..clear()
      ..addAll([
        decoder.onModeration.listen(moderation.onModeration),
        decoder.onAutomodHeld.listen(_onAutomodHeld),
        decoder.onShieldMode.listen(_onShieldModeEvent),
        decoder.onShoutout.listen(_onShoutoutEvent),
        decoder.onWarning.listen(_onWarningEvent),
        decoder.onUnbanRequest.listen(_onUnbanRequestEvent),
        decoder.onAutomodTerms.listen(_onAutomodTermsEvent),
        decoder.onAutomodSettings.listen(_onAutomodSettingsEvent),
        decoder.onSuspiciousUser.listen(_onSuspiciousUserEvent),
        decoder.onPointReward.listen(_onPointRewardEvent),
        decoder.onPointRedemption.listen(_onPointRedemptionEvent),
        decoder.onHypeTrain.listen((event) {
          if (_disposed) return;
          if (!topics.isWidgetActive(event.channel)) return;
          onHypeTrain?.call(event);
        }),
        decoder.onPoll.listen((event) {
          if (_disposed) return;
          if (!topics.isWidgetActive(event.channel)) return;
          onPoll?.call(event);
        }),
        decoder.onPrediction.listen((event) {
          if (_disposed) return;
          if (!topics.isWidgetActive(event.channel)) return;
          onPrediction?.call(event);
        }),
      ]);
    return List.unmodifiable(_subscriptions);
  }

  void dispose() {
    _disposed = true;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
  }

  // Mod-feed complements gated on the feed subscriptions: shield toggles,
  // shoutouts, and warning lifecycle have no channel.moderate equivalent.
  // warning.send is skipped while moderate covers it, to avoid doubles.
  void _onShieldModeEvent(ShieldModeEvent event) {
    if (_disposed) return;
    if (!topics.isFeedActive(event.channel)) return;
    final entry = ModActivityEntry(
      at: DateTime.now(),
      channel: event.channel,
      action: event.active ? 'shield_on' : 'shield_off',
      moderator: event.moderatorName,
    );
    chat.channelFor(event.channel)?.moderation.addFeed(entry);
    onSystemMessage(event.channel, formatModActivity(entry));
  }

  void _onShoutoutEvent(ShoutoutEvent event) {
    if (_disposed) return;
    if (!topics.isFeedActive(event.channel)) return;
    final created = event.kind == ShoutoutKind.create;
    final entry = ModActivityEntry(
      at: DateTime.now(),
      channel: event.channel,
      action: 'shoutout',
      moderator: event.moderatorName,
      target: created ? event.toLogin : event.fromLogin,
    );
    chat.channelFor(event.channel)?.moderation.addFeed(entry);
    onSystemMessage(
      event.channel,
      created
          ? formatModActivity(entry)
          : '${event.fromLogin} shouted out this channel.',
    );
  }

  void _onWarningEvent(WarningEvent event) {
    if (_disposed) return;
    if (!topics.isFeedActive(event.channel)) return;
    if (event.kind == WarningKind.acknowledge) {
      final moderation = chat.channelFor(event.channel)?.moderation;
      moderation?.dismissWarningsFor(event.userLogin);
      final entry = ModActivityEntry(
        at: DateTime.now(),
        channel: event.channel,
        action: 'warn_ack',
        moderator: event.moderatorName,
        target: event.userLogin,
      );
      moderation?.addFeed(entry);
      onSystemMessage(event.channel, formatModActivity(entry));
      return;
    }
    // channel.moderate already reported this warn with the same data.
    if (topics.isModerationActive(event.channel)) return;
    final user = event.userLogin;
    final reason = (event.reason != null && event.reason!.isNotEmpty)
        ? ': "${event.reason}"'
        : '';
    if (user.isNotEmpty) {
      chat
          .channelFor(event.channel)
          ?.moderation
          .addWarning(
            WarnEntry(
              at: DateTime.now(),
              channel: event.channel,
              target: user,
              moderator: event.moderatorName,
              reason: event.reason,
            ),
          );
    }
    final entry = ModActivityEntry(
      at: DateTime.now(),
      channel: event.channel,
      action: 'warn',
      moderator: event.moderatorName,
      target: user.isEmpty ? null : user,
      reason: event.reason,
    );
    chat.channelFor(event.channel)?.moderation.addFeed(entry);
    onSystemMessage(
      event.channel,
      user.isEmpty
          ? '${event.moderatorName} warned $user$reason.'
          : formatModActivity(entry),
    );
  }

  // Inbox complements gated on the inbox subscriptions: unban request
  // create/resolve refresh the inbox tab. Creates get a chat line (no feed
  // row: feed rows always carry a moderator); resolves get both.
  void _onUnbanRequestEvent(UnbanRequestEvent event) {
    if (_disposed) return;
    if (!topics.isInboxActive(event.channel)) return;
    chat.channelFor(event.channel)?.moderation.touchInbox();
    final user = event.userLogin;
    if (event.kind == UnbanRequestKind.create) {
      onSystemMessage(event.channel, '$user requested an unban.');
      return;
    }
    // channel.moderate reports approve/deny with the same data, so the resolve
    // copy is skipped while it is active to avoid a duplicate row.
    if (topics.isModerationActive(event.channel)) return;
    final resolution =
        (event.resolutionText != null && event.resolutionText!.isNotEmpty)
        ? ': "${event.resolutionText}"'
        : '';
    final entry = ModActivityEntry(
      at: DateTime.now(),
      channel: event.channel,
      action: 'unban_resolved',
      moderator: event.moderatorName,
      target: user.isEmpty ? null : user,
      reason: event.resolutionText,
    );
    chat.channelFor(event.channel)?.moderation.addFeed(entry);
    onSystemMessage(
      event.channel,
      user.isEmpty
          ? '${event.moderatorName} resolved $user\'s unban request$resolution.'
          : formatModActivity(entry),
    );
  }

  // Public AutoMod term updates refresh the terms tab. Skipped while
  // channel.moderate covers the same change (it carries the same terms).
  void _onAutomodTermsEvent(AutomodTermsEvent event) {
    if (_disposed) return;
    if (!topics.isInboxActive(event.channel)) return;
    chat.channelFor(event.channel)?.moderation.touchInbox();
    if (topics.isModerationActive(event.channel)) return;
    final adding = event.action != AutomodTermsAction.remove;
    final permitted = event.list == 'permitted';
    final action =
        '${adding ? 'add' : 'remove'}_${permitted ? 'permitted' : 'blocked'}_term';
    final entry = ModActivityEntry(
      at: DateTime.now(),
      channel: event.channel,
      action: action,
      moderator: event.moderatorName,
      terms: event.terms,
    );
    chat.channelFor(event.channel)?.moderation.addFeed(entry);
    onSystemMessage(event.channel, formatModActivity(entry));
  }

  // AutoMod settings changes refresh the Setup tab and land in the feed.
  void _onAutomodSettingsEvent(AutomodSettingsEvent event) {
    if (_disposed) return;
    if (!topics.isTrustActive(event.channel)) return;
    final trustModeration = chat.channelFor(event.channel)?.moderation;
    trustModeration?.touchSettings();
    final entry = ModActivityEntry(
      at: DateTime.now(),
      channel: event.channel,
      action: 'automod_settings',
      moderator: event.moderatorName,
    );
    trustModeration?.addFeed(entry);
    onSystemMessage(event.channel, formatModActivity(entry));
  }

  // Suspicious-user sightings build the per-user flag context (card, Users
  // tab). Message events are silent by design (volume, no actor); status
  // updates get a feed row and a chat line.
  void _onSuspiciousUserEvent(SuspiciousUserEvent event) {
    if (_disposed) return;
    if (!topics.isTrustActive(event.channel)) return;
    final user = event.userLogin;
    if (user.isEmpty) return;
    final suspiciousModeration = chat.channelFor(event.channel)?.moderation;
    suspiciousModeration?.noteSuspicious(
      SuspiciousInfo(
        at: DateTime.now(),
        channel: event.channel,
        login: user,
        status: event.status,
        types: event.types,
        banEvasion: event.banEvasion,
        sharedBanChannelIds: event.sharedBanChannelIds,
      ),
    );
    if (event.kind == SuspiciousUserKind.message) return;
    chat
        .channelFor(event.channel)
        ?.moderation
        .addFeed(
          ModActivityEntry(
            at: DateTime.now(),
            channel: event.channel,
            action: 'suspicious_flag',
            moderator: event.moderatorName,
            target: user,
            reason: event.status.isEmpty ? null : event.status,
          ),
        );
    onSystemMessage(
      event.channel,
      '${event.moderatorName} updated the suspicious status of $user.',
    );
  }

  // Points complements gated on the points subscriptions. Reward edits
  // refresh the reward list; redemption adds queue and updates resolve.
  // Silent by design: redemptions are high-volume and reward edits carry
  // no actor, so neither belongs in the chat or the mod feed.
  void _onPointRewardEvent(PointRewardEvent event) {
    if (_disposed) return;
    if (!topics.isPointsActive(event.channel)) return;
    final points = chat.channelFor(event.channel)?.points;
    if (points == null) return;
    final rewards = [...points.rewards];
    if (event.kind == PointRewardKind.remove) {
      rewards.removeWhere((r) => r.id == event.reward.id);
    } else {
      rewards.removeWhere((r) => r.id == event.reward.id);
      rewards.add(event.reward);
    }
    points.setRewards(rewards);
  }

  void _onPointRedemptionEvent(PointRedemptionEvent event) {
    if (_disposed) return;
    if (!topics.isPointsActive(event.channel)) return;
    final points = chat.channelFor(event.channel)?.points;
    if (event.kind == PointRedemptionKind.add &&
        event.redemption.status == 'UNFULFILLED') {
      points?.upsertRedemption(event.redemption);
    } else {
      points?.resolveRedemption(event.redemption.id);
    }
  }

  // automod.message.hold/update v2 events: hold queues, any resolution
  // (approved/denied/expired, here or by another mod) dequeues. Resolves
  // apply ungated: the idempotent drop is always safe to honor.
  void _onAutomodHeld(AutomodHeldEvent event) {
    if (_disposed) return;
    if (event.status != 'held') {
      chat.channelFor(event.channel)?.moderation.resolveHeld(event.messageId);
      return;
    }
    if (!topics.isAutomodActive(event.channel)) return;
    chat
        .channelFor(event.channel)
        ?.moderation
        .addHeld(
          HeldMessage(
            messageId: event.messageId,
            channel: event.channel,
            userLogin: event.userLogin,
            text: event.text,
            category: event.category,
          ),
        );
  }
}
