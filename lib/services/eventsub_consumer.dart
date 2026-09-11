import 'dart:async';
import 'dart:ui' show Color;

import '../chat/channel/moderation.dart';
import '../chat/chat.dart';
import '../client/session.dart';
import '../eventsub/decode/decoder.dart';
import '../eventsub/decode/events.dart';
import '../eventsub/topics.dart';
import '../util/duration_format.dart';
import '../util/mod_activity_format.dart' show formatTermAction;

/// Applies typed EventSub events to the chat kernel: moderation system lines,
/// feed rows, warn/ban/suspicious state, points, and the AutoMod queue.
class EventSubConsumer {
  EventSubConsumer({
    required this.chat,
    required this.session,
    required this.topics,
    required this.onSystemMessage,
    this.onAnalyticsModeration,
    this.onHypeTrain,
    this.onPoll,
    this.onPrediction,
    required this.onSelfTimeoutArmed,
    required this.onSelfTimeoutCleared,
  });

  final Chat chat;
  final Session session;
  final EventSubTopics topics;
  final void Function(String, String, {Color? accent, String? messageId})
  onSystemMessage;
  final void Function(String channel, bool isTimeout)? onAnalyticsModeration;
  final void Function(HypeTrainEvent event)? onHypeTrain;
  final void Function(PollEvent event)? onPoll;
  final void Function(PredictionEvent event)? onPrediction;

  /// Arms the manager-owned send gate when our own timeout lands.
  final void Function(String channel, DateTime until) onSelfTimeoutArmed;

  /// Clears the manager-owned send gate on unban/untimeout.
  final void Function(String channel) onSelfTimeoutCleared;

  bool _disposed = false;
  final _subscriptions = <StreamSubscription>[];

  /// Subscribes the 14 typed streams and returns the subscriptions.
  /// Re-attaching cancels the previous subscriptions first.
  List<StreamSubscription> attach(EventSubDecoder decoder) {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions
      ..clear()
      ..addAll([
        decoder.onModeration.listen(_onModerationEvent),
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

  // channel.moderate v2 events in channels with an active subscription:
  // renders moderation system messages, applies message deletions, tracks
  // the ban roster and warn log, and logs every action to the feed.
  void _onModerationEvent(ModerationEvent event) {
    if (_disposed) return;
    if (!topics.isModerationActive(event.channel)) return;

    final mod = event.moderatorName;
    final target = event.targetName;
    final selfLogin = session.login?.toLowerCase();
    final isSelfTarget =
        target != null &&
        selfLogin != null &&
        target.toLowerCase() == selfLogin;
    final reason = (event.reason != null && event.reason!.isNotEmpty)
        ? ': "${event.reason}"'
        : '';

    void feed() => chat
        .channelFor(event.channel)
        ?.moderation
        .addFeed(
          ModActivityEntry(
            at: DateTime.now(),
            channel: event.channel,
            action: event.rawAction,
            moderator: mod,
            target: target,
            reason: event.reason,
            durationSeconds: event.durationSeconds,
            terms: event.terms,
          ),
        );

    switch (event.action) {
      case ModerationAction.delete:
        if (event.messageId != null) {
          chat
              .channelFor(event.channel)
              ?.messages
              .markDeleted(event.messageId!);
        }
        final body =
            (event.messageBody != null && event.messageBody!.isNotEmpty)
            ? ': "${event.messageBody}"'
            : '';
        onSystemMessage(
          event.channel,
          '$mod deleted a message from $target$body.',
        );
        feed();
        break;
      case ModerationAction.clear:
        chat.channelFor(event.channel)?.messages.markAllDeleted();
        onSystemMessage(event.channel, '$mod cleared the chat.');
        feed();
        break;
      case ModerationAction.ban:
      case ModerationAction.timeout:
        onAnalyticsModeration?.call(
          event.channel,
          event.action == ModerationAction.timeout,
        );
        if (target != null) {
          chat.channelFor(event.channel)?.messages.markUserDeleted(target);
          chat
              .channelFor(event.channel)
              ?.moderation
              .putBan(
                BanEntry(
                  at: DateTime.now(),
                  channel: event.channel,
                  login: target,
                  expiresAt:
                      event.action == ModerationAction.timeout &&
                          event.durationSeconds != null
                      ? DateTime.now().add(
                          Duration(seconds: event.durationSeconds!),
                        )
                      : null,
                  reason: event.reason,
                  moderator: mod,
                ),
              );
        }
        final duration = event.durationSeconds != null
            ? ' for ${formatSeconds(event.durationSeconds!)}'
            : '';
        if (isSelfTarget &&
            event.action == ModerationAction.timeout &&
            event.durationSeconds != null &&
            // Zero-length timeouts are already spent - no gate to arm.
            event.durationSeconds! > 0) {
          onSelfTimeoutArmed(
            event.channel,
            DateTime.now().add(Duration(seconds: event.durationSeconds!)),
          );
        }
        onSystemMessage(
          event.channel,
          isSelfTarget
              ? 'You were ${event.action == ModerationAction.timeout ? 'timed out$duration' : 'banned'}$reason by $mod.'
              : '$mod ${event.action == ModerationAction.timeout ? 'timed out' : 'banned'} $target$duration$reason.',
        );
        feed();
        break;
      case ModerationAction.unban:
      case ModerationAction.untimeout:
        if (isSelfTarget) onSelfTimeoutCleared(event.channel);
        if (target != null) {
          chat.channelFor(event.channel)?.moderation.removeBan(target);
        }
        onSystemMessage(
          event.channel,
          isSelfTarget
              ? 'You were unbanned by $mod.'
              : '$mod unbanned $target.',
        );
        feed();
        break;
      case ModerationAction.mod:
        onSystemMessage(event.channel, '$mod modded $target.');
        feed();
        break;
      case ModerationAction.unmod:
        onSystemMessage(event.channel, '$mod unmodded $target.');
        feed();
        break;
      case ModerationAction.vip:
        onSystemMessage(event.channel, '$mod added $target as a VIP.');
        feed();
        break;
      case ModerationAction.unvip:
        onSystemMessage(event.channel, '$mod removed $target as a VIP.');
        feed();
        break;
      case ModerationAction.warn:
        if (target != null && target.isNotEmpty) {
          chat
              .channelFor(event.channel)
              ?.moderation
              .addWarning(
                WarnEntry(
                  at: DateTime.now(),
                  channel: event.channel,
                  target: target,
                  moderator: mod,
                  reason: event.reason,
                ),
              );
        }
        onSystemMessage(event.channel, '$mod warned $target$reason.');
        feed();
        break;
      case ModerationAction.slow:
      case ModerationAction.slowOff:
        feed();
        onSystemMessage(
          event.channel,
          event.action == ModerationAction.slow
              ? '$mod enabled slow mode.'
              : '$mod disabled slow mode.',
        );
        break;
      case ModerationAction.followers:
      case ModerationAction.followersOff:
        feed();
        onSystemMessage(
          event.channel,
          event.action == ModerationAction.followers
              ? '$mod enabled followers-only mode.'
              : '$mod disabled followers-only mode.',
        );
        break;
      case ModerationAction.emoteOnly:
      case ModerationAction.emoteOnlyOff:
        feed();
        onSystemMessage(
          event.channel,
          event.action == ModerationAction.emoteOnly
              ? '$mod enabled emote-only mode.'
              : '$mod disabled emote-only mode.',
        );
        break;
      case ModerationAction.subscribers:
      case ModerationAction.subscribersOff:
        feed();
        onSystemMessage(
          event.channel,
          event.action == ModerationAction.subscribers
              ? '$mod enabled subscribers-only mode.'
              : '$mod disabled subscribers-only mode.',
        );
        break;
      case ModerationAction.uniqueChat:
      case ModerationAction.uniqueChatOff:
        feed();
        onSystemMessage(
          event.channel,
          event.action == ModerationAction.uniqueChat
              ? '$mod enabled unique chat.'
              : '$mod disabled unique chat.',
        );
        break;
      case ModerationAction.raid:
        feed();
        onSystemMessage(event.channel, '$mod started a raid.');
        break;
      case ModerationAction.unraid:
        feed();
        onSystemMessage(event.channel, '$mod cancelled the raid.');
        break;
      case ModerationAction.addBlockedTerm:
      case ModerationAction.removeBlockedTerm:
      case ModerationAction.addPermittedTerm:
      case ModerationAction.removePermittedTerm:
        feed();
        onSystemMessage(
          event.channel,
          formatTermAction(mod, event.rawAction, event.terms),
        );
        break;
      case ModerationAction.approveUnbanRequest:
      case ModerationAction.denyUnbanRequest:
        feed();
        final verb = event.action == ModerationAction.approveUnbanRequest
            ? 'approved'
            : 'denied';
        onSystemMessage(
          event.channel,
          target != null && target.isNotEmpty
              ? '$mod $verb $target\'s unban request$reason.'
              : '$mod $verb an unban request$reason.',
        );
        break;
      case ModerationAction.unknown:
        // Future actions still land in the feed under their wire name.
        feed();
        break;
    }
  }

  // Mod-feed complements gated on the feed subscriptions: shield toggles,
  // shoutouts, and warning lifecycle have no channel.moderate equivalent.
  // warning.send is skipped while moderate covers it, to avoid doubles.
  void _onShieldModeEvent(ShieldModeEvent event) {
    if (_disposed) return;
    if (!topics.isFeedActive(event.channel)) return;
    chat
        .channelFor(event.channel)
        ?.moderation
        .addFeed(
          ModActivityEntry(
            at: DateTime.now(),
            channel: event.channel,
            action: event.active ? 'shield_on' : 'shield_off',
            moderator: event.moderatorName,
          ),
        );
    onSystemMessage(
      event.channel,
      event.active
          ? '${event.moderatorName} enabled Shield Mode.'
          : '${event.moderatorName} disabled Shield Mode.',
    );
  }

  void _onShoutoutEvent(ShoutoutEvent event) {
    if (_disposed) return;
    if (!topics.isFeedActive(event.channel)) return;
    final created = event.kind == ShoutoutKind.create;
    chat
        .channelFor(event.channel)
        ?.moderation
        .addFeed(
          ModActivityEntry(
            at: DateTime.now(),
            channel: event.channel,
            action: 'shoutout',
            moderator: event.moderatorName,
            target: created ? event.toLogin : event.fromLogin,
          ),
        );
    onSystemMessage(
      event.channel,
      created
          ? '${event.moderatorName} shouted out ${event.toLogin}.'
          : '${event.fromLogin} shouted out this channel.',
    );
  }

  void _onWarningEvent(WarningEvent event) {
    if (_disposed) return;
    if (!topics.isFeedActive(event.channel)) return;
    if (event.kind == WarningKind.acknowledge) {
      final moderation = chat.channelFor(event.channel)?.moderation;
      moderation?.dismissWarningsFor(event.userLogin);
      moderation?.addFeed(
        ModActivityEntry(
          at: DateTime.now(),
          channel: event.channel,
          action: 'warn_ack',
          moderator: event.moderatorName,
          target: event.userLogin,
        ),
      );
      onSystemMessage(
        event.channel,
        '${event.userLogin} acknowledged a warning.',
      );
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
    chat
        .channelFor(event.channel)
        ?.moderation
        .addFeed(
          ModActivityEntry(
            at: DateTime.now(),
            channel: event.channel,
            action: 'warn',
            moderator: event.moderatorName,
            target: user.isEmpty ? null : user,
            reason: event.reason,
          ),
        );
    onSystemMessage(
      event.channel,
      '${event.moderatorName} warned $user$reason.',
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
    final resolution =
        (event.resolutionText != null && event.resolutionText!.isNotEmpty)
        ? ': "${event.resolutionText}"'
        : '';
    chat
        .channelFor(event.channel)
        ?.moderation
        .addFeed(
          ModActivityEntry(
            at: DateTime.now(),
            channel: event.channel,
            action: 'unban_resolved',
            moderator: event.moderatorName,
            target: user.isEmpty ? null : user,
            reason: event.resolutionText,
          ),
        );
    onSystemMessage(
      event.channel,
      '${event.moderatorName} resolved $user\'s unban request$resolution.',
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
    chat
        .channelFor(event.channel)
        ?.moderation
        .addFeed(
          ModActivityEntry(
            at: DateTime.now(),
            channel: event.channel,
            action: action,
            moderator: event.moderatorName,
            terms: event.terms,
          ),
        );
    onSystemMessage(
      event.channel,
      formatTermAction(event.moderatorName, action, event.terms),
    );
  }

  // AutoMod settings changes refresh the Setup tab and land in the feed.
  void _onAutomodSettingsEvent(AutomodSettingsEvent event) {
    if (_disposed) return;
    if (!topics.isTrustActive(event.channel)) return;
    final trustModeration = chat.channelFor(event.channel)?.moderation;
    trustModeration?.touchSettings();
    trustModeration?.addFeed(
      ModActivityEntry(
        at: DateTime.now(),
        channel: event.channel,
        action: 'automod_settings',
        moderator: event.moderatorName,
      ),
    );
    onSystemMessage(
      event.channel,
      '${event.moderatorName} updated AutoMod settings.',
    );
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
