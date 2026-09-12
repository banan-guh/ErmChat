import '../models/point_rewards.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../util/log.dart';

/// Why a mod action failed. Both callers (slash commands, Mod View) map
/// these to their own copy; the service never builds user-facing text.
enum ModFailure {
  unknownUser,
  selfTarget,
  broadcasterTarget,
  notJoined,
  apiError,
}

class ModResult {
  final bool ok;
  final ModFailure? failure;

  /// DankChat-style API reason, set for [ModFailure.apiError].
  final String? reason;

  const ModResult.ok() : ok = true, failure = null, reason = null;
  const ModResult.fail(this.failure, [this.reason]) : ok = false;
}

/// Single execution site for channel-moderation Helix calls. Slash commands
/// ([CommandHandler]) keep arg parsing and chat copy; Mod View calls these
/// directly. Neither caller touches [TwitchApi] moderation verbs itself.
class ModActions {
  ModActions({
    required this.twitchApi,
    required this.getChannelUserIds,
    required this.getCurrentUserId,
  });

  final TwitchApi twitchApi;
  final Map<String, String> Function() getChannelUserIds;
  final String? Function() getCurrentUserId;

  final _userIdCache = <String, String>{};

  Future<String?> resolveUserId(TwitchAuth auth, String login) async {
    final lower = login.toLowerCase();
    final cached = _userIdCache[lower];
    if (cached != null) return cached;
    final id = await twitchApi.getUserId(auth, login);
    if (id != null) _userIdCache[lower] = id;
    return id;
  }

  /// Human-readable reason for the last failed Helix call, in the style of
  /// DankChat's system messages.
  String failureReason() {
    switch (twitchApi.lastErrorStatus) {
      case 401:
        return 'Missing required scope. Re-login with your account and try again.';
      case 403:
        return "You don't have permission to perform that action.";
      case 429:
        return 'You are being rate-limited. Try again in a moment.';
    }
    final message = twitchApi.lastHelixMessage;
    if (message != null && message.isNotEmpty) return message;
    return 'An unknown error has occurred.';
  }

  /// Runs a Helix moderation call. False (or a throw) becomes an apiError;
  /// IRC slash commands were deprecated by Twitch (Feb 2023), so Helix is
  /// the only path and there is no fallback.
  Future<ModResult> _run(String action, Future<bool> Function() call) async {
    bool ok;
    try {
      ok = await call();
    } catch (e) {
      logDebug('[ModActions] $action failed: $e');
      ok = false;
    }
    if (ok) return const ModResult.ok();
    return ModResult.fail(ModFailure.apiError, failureReason());
  }

  ({String broadcasterId, String moderatorId})? _ids(String channel) {
    final broadcasterId = getChannelUserIds()[channel];
    final moderatorId = getCurrentUserId();
    if (broadcasterId == null || moderatorId == null) return null;
    return (broadcasterId: broadcasterId, moderatorId: moderatorId);
  }

  /// Resolves a login-or-id target to an id, or the failure to report.
  Future<({String? userId, ModResult? error})> _target(
    TwitchAuth auth, {
    String? login,
    String? userId,
  }) async {
    if (userId != null && userId.isNotEmpty) {
      return (userId: userId, error: null);
    }
    if (login == null || login.isEmpty) {
      return (
        userId: null,
        error: const ModResult.fail(ModFailure.unknownUser),
      );
    }
    final id = await resolveUserId(auth, login);
    if (id == null) {
      return (
        userId: null,
        error: const ModResult.fail(ModFailure.unknownUser),
      );
    }
    return (userId: id, error: null);
  }

  /// Ban/timeout/warn refuse self and broadcaster targets, like Twitch does.
  ModResult? _guardUserAction({
    required String targetId,
    required String moderatorId,
    required String broadcasterId,
  }) {
    if (targetId == moderatorId) {
      return const ModResult.fail(ModFailure.selfTarget);
    }
    if (targetId == broadcasterId) {
      return const ModResult.fail(ModFailure.broadcasterTarget);
    }
    return null;
  }

  /// Resolves channel ids then runs [body] with broadcaster and moderator.
  Future<ModResult> _idsAction(
    String channel,
    String action,
    Future<bool> Function(String broadcasterId, String moderatorId) body,
  ) async {
    final ids = _ids(channel);
    if (ids == null) return const ModResult.fail(ModFailure.notJoined);
    return _run(action, () => body(ids.broadcasterId, ids.moderatorId));
  }

  /// Resolves just the broadcaster id then runs [body] with it.
  Future<ModResult> _broadcasterAction(
    String channel,
    String action,
    Future<bool> Function(String broadcasterId) body,
  ) async {
    final broadcasterId = getChannelUserIds()[channel];
    if (broadcasterId == null) {
      return const ModResult.fail(ModFailure.notJoined);
    }
    return _run(action, () => body(broadcasterId));
  }

  /// Resolves channel ids plus a login-or-id target, then runs [body]. With
  /// [guard] the self/broadcaster target checks run before the call.
  Future<ModResult> _userAction(
    TwitchAuth auth,
    String channel,
    String action, {
    String? login,
    String? userId,
    bool guard = false,
    required Future<bool> Function(
      String broadcasterId,
      String moderatorId,
      String targetId,
    )
    body,
  }) async {
    final ids = _ids(channel);
    if (ids == null) return const ModResult.fail(ModFailure.notJoined);
    final t = await _target(auth, login: login, userId: userId);
    if (t.error != null) return t.error!;
    if (guard) {
      final g = _guardUserAction(
        targetId: t.userId!,
        moderatorId: ids.moderatorId,
        broadcasterId: ids.broadcasterId,
      );
      if (g != null) return g;
    }
    return _run(
      action,
      () => body(ids.broadcasterId, ids.moderatorId, t.userId!),
    );
  }

  /// Broadcaster-only actions that still take a user target, so the moderator
  /// id is not required.
  Future<ModResult> _broadcasterUserAction(
    TwitchAuth auth,
    String channel,
    String action, {
    String? login,
    String? userId,
    required Future<bool> Function(String broadcasterId, String targetId) body,
  }) async {
    final broadcasterId = getChannelUserIds()[channel];
    if (broadcasterId == null) {
      return const ModResult.fail(ModFailure.notJoined);
    }
    final t = await _target(auth, login: login, userId: userId);
    if (t.error != null) return t.error!;
    return _run(action, () => body(broadcasterId, t.userId!));
  }

  Future<ModResult> timeoutUser(
    TwitchAuth auth,
    String channel, {
    String? login,
    String? userId,
    required int duration,
    String? reason,
  }) async {
    return _userAction(
      auth,
      channel,
      'timeout user',
      login: login,
      userId: userId,
      guard: true,
      body: (broadcasterId, moderatorId, targetId) => twitchApi.banUser(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: moderatorId,
        userId: targetId,
        duration: duration,
        reason: reason,
      ),
    );
  }

  Future<ModResult> banUser(
    TwitchAuth auth,
    String channel, {
    String? login,
    String? userId,
    String? reason,
  }) async {
    return _userAction(
      auth,
      channel,
      'ban user',
      login: login,
      userId: userId,
      guard: true,
      body: (broadcasterId, moderatorId, targetId) => twitchApi.banUser(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: moderatorId,
        userId: targetId,
        reason: reason,
      ),
    );
  }

  Future<ModResult> unbanUser(
    TwitchAuth auth,
    String channel, {
    String? login,
    String? userId,
  }) async {
    return _userAction(
      auth,
      channel,
      'unban user',
      login: login,
      userId: userId,
      body: (broadcasterId, moderatorId, targetId) => twitchApi.unbanUser(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: moderatorId,
        userId: targetId,
      ),
    );
  }

  /// Unban requests; empty on failure (check `twitchApi.lastErrorStatus`).
  Future<List<UnbanRequest>> getUnbanRequests(
    TwitchAuth auth,
    String channel, {
    String? status,
  }) {
    final ids = _ids(channel);
    if (ids == null) return Future.value(const []);
    return twitchApi.getUnbanRequests(
      auth,
      broadcasterId: ids.broadcasterId,
      moderatorId: ids.moderatorId,
      status: status,
    );
  }

  Future<ModResult> resolveUnbanRequest(
    TwitchAuth auth,
    String channel, {
    required String requestId,
    required bool approved,
    String? resolutionText,
  }) async {
    return _idsAction(
      channel,
      approved ? 'approve unban request' : 'deny unban request',
      (broadcasterId, moderatorId) => twitchApi.resolveUnbanRequest(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: moderatorId,
        requestId: requestId,
        approved: approved,
        resolutionText: resolutionText,
      ),
    );
  }

  /// Public blocked terms; empty on failure (check lastErrorStatus).
  Future<List<BlockedTerm>> getBlockedTerms(TwitchAuth auth, String channel) {
    final ids = _ids(channel);
    if (ids == null) return Future.value(const []);
    return twitchApi.getBlockedTerms(
      auth,
      broadcasterId: ids.broadcasterId,
      moderatorId: ids.moderatorId,
    );
  }

  Future<ModResult> addBlockedTerm(
    TwitchAuth auth,
    String channel,
    String text,
  ) async {
    return _idsAction(channel, 'add blocked term', (
      broadcasterId,
      moderatorId,
    ) async {
      final created = await twitchApi.addBlockedTerm(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: moderatorId,
        text: text,
      );
      return created != null;
    });
  }

  Future<ModResult> removeBlockedTerm(
    TwitchAuth auth,
    String channel,
    String termId,
  ) async {
    return _idsAction(
      channel,
      'remove blocked term',
      (broadcasterId, moderatorId) => twitchApi.removeBlockedTerm(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: moderatorId,
        termId: termId,
      ),
    );
  }

  /// AutoMod settings, or null when the channel is unknown or Helix fails
  /// (check `twitchApi.lastErrorStatus`).
  Future<AutoModSettings?> getAutoModSettings(TwitchAuth auth, String channel) {
    final ids = _ids(channel);
    if (ids == null) return Future.value(null);
    return twitchApi.getAutoModSettings(
      auth,
      broadcasterId: ids.broadcasterId,
      moderatorId: ids.moderatorId,
    );
  }

  Future<ModResult> updateAutoModSettings(
    TwitchAuth auth,
    String channel,
    Map<String, int> levels,
  ) async {
    return _idsAction(channel, 'update automod settings', (
      broadcasterId,
      moderatorId,
    ) async {
      final applied = await twitchApi.updateAutoModSettings(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: moderatorId,
        levels: levels,
      );
      return applied != null;
    });
  }

  Future<ModResult> setSuspiciousStatus(
    TwitchAuth auth,
    String channel, {
    String? login,
    String? userId,
    required bool restricted,
  }) async {
    return _userAction(
      auth,
      channel,
      restricted ? 'restrict user' : 'monitor user',
      login: login,
      userId: userId,
      body: (broadcasterId, moderatorId, targetId) =>
          twitchApi.addSuspiciousStatus(
            auth,
            broadcasterId: broadcasterId,
            moderatorId: moderatorId,
            userId: targetId,
            restricted: restricted,
          ),
    );
  }

  Future<ModResult> clearSuspiciousStatus(
    TwitchAuth auth,
    String channel, {
    String? login,
    String? userId,
  }) async {
    return _userAction(
      auth,
      channel,
      'clear suspicious status',
      login: login,
      userId: userId,
      body: (broadcasterId, moderatorId, targetId) =>
          twitchApi.removeSuspiciousStatus(
            auth,
            broadcasterId: broadcasterId,
            moderatorId: moderatorId,
            userId: targetId,
          ),
    );
  }

  /// Point rewards; empty on failure (check `twitchApi.lastErrorStatus`).
  /// Broadcaster token only.
  Future<List<PointReward>> getPointRewards(TwitchAuth auth, String channel) {
    final broadcasterId = getChannelUserIds()[channel];
    if (broadcasterId == null) return Future.value(const []);
    return twitchApi.getCustomRewards(auth, broadcasterId: broadcasterId);
  }

  /// UNFULFILLED redemptions for one reward; empty on failure (check
  /// lastErrorStatus). Rewards from other client ids 403 here.
  Future<List<PointRedemption>> getPointRedemptions(
    TwitchAuth auth,
    String channel,
    String rewardId,
  ) {
    final broadcasterId = getChannelUserIds()[channel];
    if (broadcasterId == null) return Future.value(const []);
    return twitchApi.getRedemptions(
      auth,
      broadcasterId: broadcasterId,
      rewardId: rewardId,
    );
  }

  Future<ModResult> setRewardPaused(
    TwitchAuth auth,
    String channel,
    String rewardId,
    bool paused,
  ) async {
    return _broadcasterAction(
      channel,
      paused ? 'pause reward' : 'resume reward',
      (broadcasterId) => twitchApi.setRewardPaused(
        auth,
        broadcasterId: broadcasterId,
        rewardId: rewardId,
        paused: paused,
      ),
    );
  }

  Future<ModResult> resolveRedemption(
    TwitchAuth auth,
    String channel,
    String rewardId,
    String redemptionId,
    bool fulfilled,
  ) async {
    return _broadcasterAction(
      channel,
      fulfilled ? 'fulfill redemption' : 'refund redemption',
      (broadcasterId) => twitchApi.updateRedemptionStatus(
        auth,
        broadcasterId: broadcasterId,
        rewardId: rewardId,
        redemptionId: redemptionId,
        fulfilled: fulfilled,
      ),
    );
  }

  Future<ModResult> warnUser(
    TwitchAuth auth,
    String channel, {
    String? login,
    String? userId,
    String? reason,
  }) async {
    return _userAction(
      auth,
      channel,
      'warn user',
      login: login,
      userId: userId,
      guard: true,
      body: (broadcasterId, moderatorId, targetId) => twitchApi.warnUser(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: moderatorId,
        userId: targetId,
        reason: reason,
      ),
    );
  }

  Future<ModResult> deleteMessage(
    TwitchAuth auth,
    String channel,
    String messageId,
  ) async {
    return _idsAction(
      channel,
      'delete chat messages',
      (broadcasterId, moderatorId) => twitchApi.deleteChatMessage(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: moderatorId,
        messageId: messageId,
      ),
    );
  }

  Future<ModResult> clearChat(TwitchAuth auth, String channel) async {
    return _idsAction(
      channel,
      'delete chat messages',
      (broadcasterId, moderatorId) => twitchApi.deleteChatMessage(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: moderatorId,
      ),
    );
  }

  Future<List<Map<String, dynamic>>> getPolls(TwitchAuth auth, String channel) {
    final broadcasterId = getChannelUserIds()[channel];
    if (broadcasterId == null) return Future.value(const []);
    return twitchApi.getPolls(auth, broadcasterId);
  }

  Future<ModResult> createPoll(
    TwitchAuth auth,
    String channel, {
    required String title,
    required List<String> choices,
    required int durationSeconds,
  }) async {
    return _broadcasterAction(
      channel,
      'create poll',
      (broadcasterId) => twitchApi.createPoll(
        auth,
        broadcasterId: broadcasterId,
        title: title,
        choices: choices,
        durationSeconds: durationSeconds,
      ),
    );
  }

  Future<ModResult> endPoll(
    TwitchAuth auth,
    String channel, {
    required String pollId,
    required bool archive,
  }) async {
    return _broadcasterAction(
      channel,
      archive ? 'cancel the poll' : 'end the poll',
      (broadcasterId) => twitchApi.endPoll(
        auth,
        broadcasterId: broadcasterId,
        pollId: pollId,
        archive: archive,
      ),
    );
  }

  Future<List<Map<String, dynamic>>> getPredictions(
    TwitchAuth auth,
    String channel,
  ) {
    final broadcasterId = getChannelUserIds()[channel];
    if (broadcasterId == null) return Future.value(const []);
    return twitchApi.getPredictions(auth, broadcasterId);
  }

  Future<ModResult> endPrediction(
    TwitchAuth auth,
    String channel, {
    required String predictionId,
    required String status,
    String? winningOutcomeId,
  }) async {
    return _broadcasterAction(
      channel,
      'end the prediction',
      (broadcasterId) => twitchApi.endPrediction(
        auth,
        broadcasterId: broadcasterId,
        predictionId: predictionId,
        status: status,
        winningOutcomeId: winningOutcomeId,
      ),
    );
  }

  Future<ModResult> _updateChatSettings(
    TwitchAuth auth,
    String channel,
    Map<String, dynamic> body,
  ) async {
    return _idsAction(
      channel,
      'update chat settings',
      (broadcasterId, moderatorId) => twitchApi.updateChatSettings(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: moderatorId,
        body: body,
      ),
    );
  }

  Future<ModResult> setSlowMode(
    TwitchAuth auth,
    String channel, {
    required bool enabled,
    int seconds = 30,
  }) => _updateChatSettings(
    auth,
    channel,
    enabled
        ? {'slow_mode': true, 'slow_mode_wait_time': seconds}
        : {'slow_mode': false},
  );

  /// [minutes] null leaves the default (no minimum follow age).
  Future<ModResult> setFollowersMode(
    TwitchAuth auth,
    String channel, {
    required bool enabled,
    int? minutes,
  }) {
    final body = <String, dynamic>{'follower_mode': enabled};
    if (enabled && minutes != null) body['follower_mode_duration'] = minutes;
    return _updateChatSettings(auth, channel, body);
  }

  Future<ModResult> setEmoteOnly(
    TwitchAuth auth,
    String channel, {
    required bool enabled,
  }) => _updateChatSettings(auth, channel, {'emote_mode': enabled});

  Future<ModResult> setSubscribersOnly(
    TwitchAuth auth,
    String channel, {
    required bool enabled,
  }) => _updateChatSettings(auth, channel, {'subscriber_mode': enabled});

  Future<ModResult> setUniqueChat(
    TwitchAuth auth,
    String channel, {
    required bool enabled,
  }) => _updateChatSettings(auth, channel, {'unique_chat_mode': enabled});

  /// Shield Mode flag; null when unknown (not joined or request failed).
  Future<bool?> getShieldMode(TwitchAuth auth, String channel) {
    final ids = _ids(channel);
    if (ids == null) return Future.value(null);
    return twitchApi.getShieldModeStatus(
      auth,
      broadcasterId: ids.broadcasterId,
      moderatorId: ids.moderatorId,
    );
  }

  Future<ModResult> setShieldMode(
    TwitchAuth auth,
    String channel, {
    required bool active,
  }) async {
    return _idsAction(
      channel,
      'update shield mode',
      (broadcasterId, moderatorId) => twitchApi.updateShieldMode(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: moderatorId,
        active: active,
      ),
    );
  }

  Future<ModResult> setModerator(
    TwitchAuth auth,
    String channel, {
    String? login,
    String? userId,
    required bool add,
  }) async {
    return _userAction(
      auth,
      channel,
      add ? 'add channel moderator' : 'remove channel moderator',
      login: login,
      userId: userId,
      body: (broadcasterId, moderatorId, targetId) => add
          ? twitchApi.addModerator(
              auth,
              broadcasterId: broadcasterId,
              userId: targetId,
            )
          : twitchApi.removeModerator(
              auth,
              broadcasterId: broadcasterId,
              userId: targetId,
            ),
    );
  }

  /// Moderator logins; empty on failure (check `twitchApi.lastErrorStatus`).
  Future<List<String>> getModerators(TwitchAuth auth, String channel) {
    final broadcasterId = getChannelUserIds()[channel];
    if (broadcasterId == null) return Future.value(const []);
    return twitchApi.getModerators(auth, broadcasterId);
  }

  /// Broadcaster-only banned/timeout list; empty on failure (check
  /// `twitchApi.lastErrorStatus`).
  Future<List<BannedUser>> getBannedUsers(TwitchAuth auth, String channel) {
    final broadcasterId = getChannelUserIds()[channel];
    if (broadcasterId == null) return Future.value(const []);
    return twitchApi.getBannedUsers(auth, broadcasterId);
  }

  Future<ModResult> setVip(
    TwitchAuth auth,
    String channel, {
    String? login,
    String? userId,
    required bool add,
  }) async {
    return _userAction(
      auth,
      channel,
      add ? 'add VIP' : 'remove VIP',
      login: login,
      userId: userId,
      body: (broadcasterId, moderatorId, targetId) => add
          ? twitchApi.addVip(
              auth,
              broadcasterId: broadcasterId,
              userId: targetId,
            )
          : twitchApi.removeVip(
              auth,
              broadcasterId: broadcasterId,
              userId: targetId,
            ),
    );
  }

  /// VIP logins; empty on failure (check `twitchApi.lastErrorStatus`).
  Future<List<String>> getVips(TwitchAuth auth, String channel) {
    final broadcasterId = getChannelUserIds()[channel];
    if (broadcasterId == null) return Future.value(const []);
    return twitchApi.getVips(auth, broadcasterId);
  }

  Future<ModResult> sendAnnouncement(
    TwitchAuth auth,
    String channel, {
    required String message,
    String color = 'primary',
  }) async {
    return _idsAction(
      channel,
      'send announcement',
      (broadcasterId, moderatorId) => twitchApi.sendChatAnnouncement(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: moderatorId,
        message: message,
        color: color,
      ),
    );
  }

  Future<ModResult> sendShoutout(
    TwitchAuth auth,
    String channel, {
    String? login,
    String? userId,
  }) async {
    return _userAction(
      auth,
      channel,
      'send shoutout',
      login: login,
      userId: userId,
      body: (broadcasterId, moderatorId, targetId) => twitchApi.sendShoutout(
        auth,
        broadcasterId: broadcasterId,
        moderatorId: moderatorId,
        targetUserId: targetId,
      ),
    );
  }

  Future<ModResult> startCommercial(
    TwitchAuth auth,
    String channel, {
    required int length,
  }) async {
    return _broadcasterAction(
      channel,
      'start commercial',
      (broadcasterId) => twitchApi.startCommercial(
        auth,
        broadcasterId: broadcasterId,
        length: length,
      ),
    );
  }

  Future<ModResult> startRaid(
    TwitchAuth auth,
    String channel, {
    String? login,
    String? userId,
  }) async {
    return _broadcasterUserAction(
      auth,
      channel,
      'start a raid',
      login: login,
      userId: userId,
      body: (broadcasterId, targetId) => twitchApi.startRaid(
        auth,
        fromBroadcasterId: broadcasterId,
        toBroadcasterId: targetId,
      ),
    );
  }

  Future<ModResult> cancelRaid(TwitchAuth auth, String channel) async {
    return _broadcasterAction(
      channel,
      'cancel the raid',
      (broadcasterId) =>
          twitchApi.cancelRaid(auth, broadcasterId: broadcasterId),
    );
  }

  /// Allows or denies an AutoMod-held message. The queue entry is addressed
  /// by [messageId] alone; the caller drops it from the store on success
  /// (a late automod.message.update resolving it again is a no-op).
  Future<ModResult> decideHeldMessage(
    TwitchAuth auth,
    String channel, {
    required String messageId,
    required bool allow,
  }) async {
    return _idsAction(
      channel,
      allow ? 'allow held message' : 'deny held message',
      (broadcasterId, moderatorId) => twitchApi.manageHeldAutoModMessages(
        auth,
        moderatorId: moderatorId,
        messageId: messageId,
        allow: allow,
      ),
    );
  }

  /// Twitch caps marker descriptions at 140 chars; longer ones are trimmed.
  Future<ModResult> createMarker(
    TwitchAuth auth,
    String channel, {
    String? description,
  }) async {
    return _broadcasterAction(channel, 'create stream marker', (broadcasterId) {
      var desc = description ?? '';
      if (desc.length > 140) desc = desc.substring(0, 140);
      return twitchApi.createMarker(
        auth,
        broadcasterId: broadcasterId,
        description: desc.isEmpty ? null : desc,
      );
    });
  }
}
