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

  Future<ModResult> timeoutUser(
    TwitchAuth auth,
    String channel, {
    String? login,
    String? userId,
    required int duration,
    String? reason,
  }) async {
    final ids = _ids(channel);
    if (ids == null) return const ModResult.fail(ModFailure.notJoined);
    final t = await _target(auth, login: login, userId: userId);
    if (t.error != null) return t.error!;
    final guard = _guardUserAction(
      targetId: t.userId!,
      moderatorId: ids.moderatorId,
      broadcasterId: ids.broadcasterId,
    );
    if (guard != null) return guard;
    return _run(
      'timeout user',
      () => twitchApi.banUser(
        auth,
        broadcasterId: ids.broadcasterId,
        moderatorId: ids.moderatorId,
        userId: t.userId!,
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
    final ids = _ids(channel);
    if (ids == null) return const ModResult.fail(ModFailure.notJoined);
    final t = await _target(auth, login: login, userId: userId);
    if (t.error != null) return t.error!;
    final guard = _guardUserAction(
      targetId: t.userId!,
      moderatorId: ids.moderatorId,
      broadcasterId: ids.broadcasterId,
    );
    if (guard != null) return guard;
    return _run(
      'ban user',
      () => twitchApi.banUser(
        auth,
        broadcasterId: ids.broadcasterId,
        moderatorId: ids.moderatorId,
        userId: t.userId!,
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
    final ids = _ids(channel);
    if (ids == null) return const ModResult.fail(ModFailure.notJoined);
    final t = await _target(auth, login: login, userId: userId);
    if (t.error != null) return t.error!;
    return _run(
      'unban user',
      () => twitchApi.unbanUser(
        auth,
        broadcasterId: ids.broadcasterId,
        moderatorId: ids.moderatorId,
        userId: t.userId!,
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
    final ids = _ids(channel);
    if (ids == null) return const ModResult.fail(ModFailure.notJoined);
    final t = await _target(auth, login: login, userId: userId);
    if (t.error != null) return t.error!;
    final guard = _guardUserAction(
      targetId: t.userId!,
      moderatorId: ids.moderatorId,
      broadcasterId: ids.broadcasterId,
    );
    if (guard != null) return guard;
    return _run(
      'warn user',
      () => twitchApi.warnUser(
        auth,
        broadcasterId: ids.broadcasterId,
        moderatorId: ids.moderatorId,
        userId: t.userId!,
        reason: reason,
      ),
    );
  }

  Future<ModResult> deleteMessage(
    TwitchAuth auth,
    String channel,
    String messageId,
  ) async {
    final ids = _ids(channel);
    if (ids == null) return const ModResult.fail(ModFailure.notJoined);
    return _run(
      'delete chat messages',
      () => twitchApi.deleteChatMessage(
        auth,
        broadcasterId: ids.broadcasterId,
        moderatorId: ids.moderatorId,
        messageId: messageId,
      ),
    );
  }

  Future<ModResult> clearChat(TwitchAuth auth, String channel) async {
    final ids = _ids(channel);
    if (ids == null) return const ModResult.fail(ModFailure.notJoined);
    return _run(
      'delete chat messages',
      () => twitchApi.deleteChatMessage(
        auth,
        broadcasterId: ids.broadcasterId,
        moderatorId: ids.moderatorId,
      ),
    );
  }

  Future<ModResult> _updateChatSettings(
    TwitchAuth auth,
    String channel,
    Map<String, dynamic> body,
  ) async {
    final ids = _ids(channel);
    if (ids == null) return const ModResult.fail(ModFailure.notJoined);
    return _run(
      'update chat settings',
      () => twitchApi.updateChatSettings(
        auth,
        broadcasterId: ids.broadcasterId,
        moderatorId: ids.moderatorId,
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
    final ids = _ids(channel);
    if (ids == null) return const ModResult.fail(ModFailure.notJoined);
    return _run(
      'update shield mode',
      () => twitchApi.updateShieldMode(
        auth,
        broadcasterId: ids.broadcasterId,
        moderatorId: ids.moderatorId,
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
    final ids = _ids(channel);
    if (ids == null) return const ModResult.fail(ModFailure.notJoined);
    final t = await _target(auth, login: login, userId: userId);
    if (t.error != null) return t.error!;
    return _run(
      add ? 'add channel moderator' : 'remove channel moderator',
      () => add
          ? twitchApi.addModerator(
              auth,
              broadcasterId: ids.broadcasterId,
              userId: t.userId!,
            )
          : twitchApi.removeModerator(
              auth,
              broadcasterId: ids.broadcasterId,
              userId: t.userId!,
            ),
    );
  }

  /// Moderator logins; empty on failure (check `twitchApi.lastErrorStatus`).
  Future<List<String>> getModerators(TwitchAuth auth, String channel) {
    final broadcasterId = getChannelUserIds()[channel];
    if (broadcasterId == null) return Future.value(const []);
    return twitchApi.getModerators(auth, broadcasterId);
  }

  Future<ModResult> setVip(
    TwitchAuth auth,
    String channel, {
    String? login,
    String? userId,
    required bool add,
  }) async {
    final ids = _ids(channel);
    if (ids == null) return const ModResult.fail(ModFailure.notJoined);
    final t = await _target(auth, login: login, userId: userId);
    if (t.error != null) return t.error!;
    return _run(
      add ? 'add VIP' : 'remove VIP',
      () => add
          ? twitchApi.addVip(
              auth,
              broadcasterId: ids.broadcasterId,
              userId: t.userId!,
            )
          : twitchApi.removeVip(
              auth,
              broadcasterId: ids.broadcasterId,
              userId: t.userId!,
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
    final ids = _ids(channel);
    if (ids == null) return const ModResult.fail(ModFailure.notJoined);
    return _run(
      'send announcement',
      () => twitchApi.sendChatAnnouncement(
        auth,
        broadcasterId: ids.broadcasterId,
        moderatorId: ids.moderatorId,
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
    final ids = _ids(channel);
    if (ids == null) return const ModResult.fail(ModFailure.notJoined);
    final t = await _target(auth, login: login, userId: userId);
    if (t.error != null) return t.error!;
    return _run(
      'send shoutout',
      () => twitchApi.sendShoutout(
        auth,
        broadcasterId: ids.broadcasterId,
        moderatorId: ids.moderatorId,
        targetUserId: t.userId!,
      ),
    );
  }

  Future<ModResult> startCommercial(
    TwitchAuth auth,
    String channel, {
    required int length,
  }) async {
    final broadcasterId = getChannelUserIds()[channel];
    if (broadcasterId == null) {
      return const ModResult.fail(ModFailure.notJoined);
    }
    return _run(
      'start commercial',
      () => twitchApi.startCommercial(
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
    final broadcasterId = getChannelUserIds()[channel];
    if (broadcasterId == null) {
      return const ModResult.fail(ModFailure.notJoined);
    }
    final t = await _target(auth, login: login, userId: userId);
    if (t.error != null) return t.error!;
    return _run(
      'start a raid',
      () => twitchApi.startRaid(
        auth,
        fromBroadcasterId: broadcasterId,
        toBroadcasterId: t.userId!,
      ),
    );
  }

  Future<ModResult> cancelRaid(TwitchAuth auth, String channel) async {
    final broadcasterId = getChannelUserIds()[channel];
    if (broadcasterId == null) {
      return const ModResult.fail(ModFailure.notJoined);
    }
    return _run(
      'cancel the raid',
      () => twitchApi.cancelRaid(auth, broadcasterId: broadcasterId),
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
    final moderatorId = getCurrentUserId();
    if (getChannelUserIds()[channel] == null || moderatorId == null) {
      return const ModResult.fail(ModFailure.notJoined);
    }
    return _run(
      allow ? 'allow held message' : 'deny held message',
      () => twitchApi.manageHeldAutoModMessages(
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
    final broadcasterId = getChannelUserIds()[channel];
    if (broadcasterId == null) {
      return const ModResult.fail(ModFailure.notJoined);
    }
    var desc = description ?? '';
    if (desc.length > 140) desc = desc.substring(0, 140);
    return _run(
      'create stream marker',
      () => twitchApi.createMarker(
        auth,
        broadcasterId: broadcasterId,
        description: desc.isEmpty ? null : desc,
      ),
    );
  }
}
