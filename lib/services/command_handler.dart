import '../models/twitch_command.dart';
import '../services/mod_actions.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../irc/transport/write.dart';
import '../l10n/l10n.dart';
import '../util/duration_format.dart';
import '../util/log.dart';

class CommandHandler {
  static final _whitespaceRe = RegExp(r'\s+');
  final TwitchApi twitchApi;
  final IrcService irc;
  final ModActions modActions;
  final Map<String, String> Function() getChannelUserIds;
  final String? Function() getCurrentUserId;
  final String? Function() getCurrentUserLogin;
  final void Function(String channel, String message) addSystemMessage;
  final void Function(String channel, String message)? whisperAddSystemMessage;
  final void Function(String target, String message)? onWhisperSent;
  final void Function(String login)? onUserBlocked;
  final void Function(String login)? onUserUnblocked;

  /// Every command the app can run. Used for / autocomplete - all commands
  /// are suggested regardless of permissions; the API rejects what the
  /// account cannot run with a clean error notice. Keep in sync with
  /// `handle()` below.
  static const allCommands = <TwitchCommand>[
    TwitchCommand(name: '/me'),
    TwitchCommand(name: '/color'),
    TwitchCommand(name: '/ban'),
    TwitchCommand(name: '/timeout'),
    TwitchCommand(name: '/unban'),
    TwitchCommand(name: '/untimeout'),
    TwitchCommand(name: '/warn'),
    TwitchCommand(name: '/delete'),
    TwitchCommand(name: '/clear'),
    TwitchCommand(name: '/announce'),
    TwitchCommand(name: '/announceblue'),
    TwitchCommand(name: '/announcegreen'),
    TwitchCommand(name: '/announceorange'),
    TwitchCommand(name: '/announcepurple'),
    TwitchCommand(name: '/mod'),
    TwitchCommand(name: '/unmod'),
    TwitchCommand(name: '/mods'),
    TwitchCommand(name: '/vip'),
    TwitchCommand(name: '/unvip'),
    TwitchCommand(name: '/vips'),
    TwitchCommand(name: '/slow'),
    TwitchCommand(name: '/slowoff'),
    TwitchCommand(name: '/followers'),
    TwitchCommand(name: '/followersoff'),
    TwitchCommand(name: '/emoteonly'),
    TwitchCommand(name: '/emoteonlyoff'),
    TwitchCommand(name: '/subscribers'),
    TwitchCommand(name: '/subscribersoff'),
    TwitchCommand(name: '/r9kbeta'),
    TwitchCommand(name: '/r9kbetaoff'),
    TwitchCommand(name: '/uniquechat'),
    TwitchCommand(name: '/uniquechatoff'),
    TwitchCommand(name: '/shoutout'),
    TwitchCommand(name: '/raid'),
    TwitchCommand(name: '/unraid'),
    TwitchCommand(name: '/shield'),
    TwitchCommand(name: '/shieldoff'),
    TwitchCommand(name: '/commercial'),
    TwitchCommand(name: '/marker'),
    TwitchCommand(name: '/poll'),
    TwitchCommand(name: '/cancelpoll'),
    TwitchCommand(name: '/endpoll'),
    TwitchCommand(name: '/prediction'),
    TwitchCommand(name: '/lockprediction'),
    TwitchCommand(name: '/cancelprediction'),
    TwitchCommand(name: '/resolveprediction'),
    TwitchCommand(name: '/w'),
    TwitchCommand(name: '/block'),
    TwitchCommand(name: '/unblock'),
  ];

  CommandHandler({
    required this.twitchApi,
    required this.irc,
    required this.getChannelUserIds,
    required this.getCurrentUserId,
    required this.getCurrentUserLogin,
    required this.addSystemMessage,
    this.whisperAddSystemMessage,
    this.onWhisperSent,
    this.onUserBlocked,
    this.onUserUnblocked,
    ModActions? modActions,
    this.strings = englishStrings,
  }) : modActions =
           modActions ??
           ModActions(
             twitchApi: twitchApi,
             getChannelUserIds: getChannelUserIds,
             getCurrentUserId: getCurrentUserId,
             strings: strings,
           );

  final AppLocalizations Function() strings;

  // Action ids are English identifiers; this maps them to display phrases.
  String _actionLabel(String action) {
    final s = strings();
    return switch (action) {
      'ban user' => s.actionBanUser,
      'unban user' => s.actionUnbanUser,
      'warn user' => s.actionWarnUser,
      'timeout user' => s.actionTimeoutUser,
      'delete chat messages' => s.actionDeleteMessages,
      'send announcement' => s.actionSendAnnouncement,
      'send shoutout' => s.actionSendShoutout,
      'add channel moderator' => s.actionAddModerator,
      'remove channel moderator' => s.actionRemoveModerator,
      'add VIP' => s.actionAddVip,
      'remove VIP' => s.actionRemoveVip,
      'update chat settings' => s.actionUpdateChatSettings,
      'start commercial' => s.actionStartCommercial,
      'start a raid' => s.actionStartRaid,
      'cancel the raid' => s.actionCancelRaid,
      'update shield mode' => s.actionUpdateShieldMode,
      'create stream marker' => s.actionCreateMarker,
      'create poll' => s.actionCreatePoll,
      'cancel the poll' => s.actionCancelPoll,
      'end the poll' => s.actionEndPoll,
      'create prediction' => s.actionCreatePrediction,
      'end the prediction' => s.actionEndPrediction,
      'block user' => s.actionBlockUser,
      'unblock user' => s.actionUnblockUser,
      'send whisper' => s.actionSendWhisper,
      'list moderators' => s.actionListModerators,
      'list VIPs' => s.actionListVips,
      'fetch polls' => s.actionFetchPolls,
      'fetch predictions' => s.actionFetchPredictions,
      _ => action,
    };
  }

  String _failed(String action, String reason) =>
      strings().modFailed(_actionLabel(action), reason);

  // Shares the ModActions cache so /w and /block reuse mod-path lookups.
  Future<String?> _resolveUserId(TwitchAuth auth, String login) =>
      modActions.resolveUserId(auth, login);

  /// Runs a Helix moderation call. Returns true on success; on failure
  /// reports a clean notice. IRC slash commands were deprecated by Twitch
  /// (Feb 2023), so there is no IRC fallback - Helix is the only way to
  /// send moderation actions.
  Future<bool> _moderate(
    String action,
    String channel,
    Future<bool> Function() helixCall,
  ) async {
    bool ok;
    try {
      ok = await helixCall();
    } catch (e) {
      logDebug('[CommandHandler] $action failed: $e');
      ok = false;
    }
    if (ok) return true;
    _moderationMessage(
      action,
      channel,
      _failed(action, modActions.failureReason()),
    );
    return false;
  }

  /// Routes whisper feedback to the whispers list when composed there;
  /// otherwise falls back to the channel system messages.
  void _whisperMessage(String channel, String text) {
    final whisperMsg = whisperAddSystemMessage;
    if (whisperMsg != null) {
      whisperMsg(channel, text);
    } else {
      addSystemMessage(channel, text);
    }
  }

  void _moderationMessage(String action, String channel, String text) {
    if (action == 'send whisper') {
      _whisperMessage(channel, text);
    } else {
      addSystemMessage(channel, text);
    }
  }

  /// Maps a ModActions failure to the command's chat copy. [verb] renders the
  /// self/broadcaster guards ("You cannot ban yourself").
  String _modCopy(String action, String verb, ModResult result) =>
      switch (result.failure) {
        ModFailure.unknownUser => strings().modErrorUnknownUser,
        ModFailure.selfTarget => strings().modCannotTargetSelf(
          _actionLabel(action),
          _verbLabel(verb),
        ),
        ModFailure.broadcasterTarget => strings().modCannotTargetBroadcaster(
          _actionLabel(action),
          _verbLabel(verb),
        ),
        ModFailure.notJoined => strings().modErrorNotJoined,
        _ => _failed(action, result.reason ?? strings().modErrorUnknown),
      };

  String _verbLabel(String verb) => switch (verb) {
    'ban' => strings().verbBan,
    'warn' => strings().verbWarn,
    'timeout' => strings().verbTimeout,
    _ => verb,
  };

  /// /w is account-scoped (whispers are not bound to a channel) and is
  /// handled before the broadcaster-channel gate below.
  Future<void> _handleWhisper(
    String text,
    String channel,
    TwitchAuth auth,
    String currentUserId,
  ) async {
    final parts = text.split(_whitespaceRe);
    final args = parts.length > 1 ? parts.sublist(1) : [];
    if (args.length < 2) {
      _whisperMessage(channel, strings().usageWhisper);
      return;
    }
    final targetId = await _resolveUserId(auth, args[0]);
    if (targetId == null) {
      _whisperMessage(channel, strings().modErrorUnknownUser);
      return;
    }
    final message = args.sublist(1).join(' ');
    final ok = await _moderate(
      'send whisper',
      channel,
      () => twitchApi.sendWhisper(
        auth,
        fromUserId: currentUserId,
        toUserId: targetId,
        message: message,
      ),
    );
    if (ok) {
      _whisperMessage(channel, strings().whisperSent);
      onWhisperSent?.call(args[0], message);
    }
  }

  /// Parses DankChat-style durations ("90", "2m", "1h30m", "1d", "2w").
  /// Returns seconds, or null when unparseable.
  static int? _parseDurationSeconds(String input) {
    if (input.isEmpty) return null;
    final plain = int.tryParse(input);
    if (plain != null) return plain;
    var seconds = 0;
    var acc = 0;
    var lastWasUnit = false;
    for (final c in input.split('')) {
      if (c == ' ') continue;
      final digit = int.tryParse(c);
      if (digit != null) {
        acc = acc * 10 + digit;
        lastWasUnit = false;
        continue;
      }
      final mult = switch (c) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        'w' => 604800,
        _ => null,
      };
      if (mult == null || acc == 0 && !lastWasUnit) return null;
      seconds += acc * mult;
      acc = 0;
      lastWasUnit = true;
    }
    if (acc != 0 || !lastWasUnit) return null;
    return seconds;
  }

  /// Splits the Chatterino-style poll/prediction syntax
  /// "[duration] <title> | <option> | <option>" into its parts. The optional
  /// leading duration token ("60", "2m", "1h30m") is consumed only when it
  /// parses as a duration and more tokens remain. Returns null when the line
  /// has no title or fewer than two options.
  static ({int duration, String title, List<String> options})?
  _parsePipeCommand(String joined, {required int defaultDuration}) {
    final segments = joined.split('|').map((s) => s.trim()).toList();
    if (segments.length < 3 || segments.any((s) => s.isEmpty)) return null;

    var title = segments[0];
    var duration = defaultDuration;
    final tokens = title.split(_whitespaceRe);
    if (tokens.length > 1) {
      final parsed = _parseDurationSeconds(tokens.first);
      if (parsed != null && parsed > 0) {
        duration = parsed;
        title = tokens.sublist(1).join(' ');
      }
    }
    if (title.isEmpty) return null;
    return (duration: duration, title: title, options: segments.sublist(1));
  }

  Future<void> handle(String text, String channel, TwitchAuth auth) async {
    final parts = text.split(_whitespaceRe);
    final cmd = parts[0].toLowerCase();
    final args = parts.length > 1 ? parts.sublist(1) : [];

    // /me is sent via raw IRC (not Helix API) and bypasses the auth gate
    // below - IRC handles it natively. The "/me" prefix is sent as-is.
    if (cmd == '/me') {
      final currentUserLogin = getCurrentUserLogin();
      if (currentUserLogin != null && auth.isConfigured) {
        irc.sendMessage(channel, text);
      }
      return;
    }

    if (!auth.isConfigured) {
      addSystemMessage(channel, strings().commandLoginRequired(cmd));
      return;
    }
    final broadcasterId = getChannelUserIds()[channel];
    final currentUserId = getCurrentUserId();
    if (cmd == '/w') {
      if (currentUserId == null) {
        // Whispers are account-scoped, not channel-scoped: this failure means
        // our own user id is unresolved, not that a channel is missing.
        addSystemMessage(channel, strings().accountUnresolved);
        return;
      }
      await _handleWhisper(text, channel, auth, currentUserId);
      return;
    }
    if (currentUserId == null || broadcasterId == null) {
      addSystemMessage(channel, strings().modErrorNotJoined);
      return;
    }

    try {
      switch (cmd) {
        case '/color':
          if (args.isEmpty) {
            addSystemMessage(channel, strings().usageColor);
            return;
          }
          final color = args.join(' ');
          final ok = await twitchApi.updateUserChatColor(
            auth,
            userId: currentUserId,
            color: color,
          );
          if (ok) {
            addSystemMessage(channel, strings().colorChanged(color));
          } else {
            addSystemMessage(
              channel,
              strings().colorChangeFailed(color, modActions.failureReason()),
            );
          }

        case '/ban':
          if (args.isEmpty) {
            addSystemMessage(channel, strings().usageUserReason('/ban'));
            return;
          }
          final targetLogin = args[0];
          final reason = args.length > 1 ? args.sublist(1).join(' ') : null;
          final banResult = await modActions.banUser(
            auth,
            channel,
            login: targetLogin,
            reason: reason,
          );
          if (banResult.ok) {
            addSystemMessage(channel, strings().userBanned(targetLogin));
          } else {
            addSystemMessage(channel, _modCopy('ban user', 'ban', banResult));
          }

        case '/unban':
        case '/untimeout':
          if (args.isEmpty) {
            addSystemMessage(channel, strings().usageUser(cmd));
            return;
          }
          final unbanResult = await modActions.unbanUser(
            auth,
            channel,
            login: args[0],
          );
          if (unbanResult.ok) {
            addSystemMessage(
              channel,
              cmd == '/untimeout'
                  ? strings().userUntimedOut('${args[0]}')
                  : strings().userUnbanned('${args[0]}'),
            );
          } else {
            addSystemMessage(channel, _modCopy('unban user', '', unbanResult));
          }

        case '/warn':
          if (args.isEmpty) {
            addSystemMessage(channel, strings().usageUserReason('/warn'));
            return;
          }
          final targetLogin = args[0];
          final warnReason = args.length > 1 ? args.sublist(1).join(' ') : null;
          final warnResult = await modActions.warnUser(
            auth,
            channel,
            login: targetLogin,
            reason: warnReason,
          );
          if (warnResult.ok) {
            addSystemMessage(channel, strings().userWarned(targetLogin));
          } else {
            addSystemMessage(
              channel,
              _modCopy('warn user', 'warn', warnResult),
            );
          }

        case '/timeout':
          if (args.isEmpty) {
            addSystemMessage(channel, strings().usageTimeout);
            return;
          }
          final targetLogin = args[0];
          int duration = 600;
          String? reason;
          if (args.length > 1) {
            final parsed = _parseDurationSeconds(args[1]);
            if (parsed != null && parsed > 0) {
              duration = parsed;
              if (args.length > 2) reason = args.sublist(2).join(' ');
            } else {
              reason = args.sublist(1).join(' ');
            }
          }
          final timeoutResult = await modActions.timeoutUser(
            auth,
            channel,
            login: targetLogin,
            duration: duration,
            reason: reason,
          );
          if (timeoutResult.ok) {
            addSystemMessage(
              channel,
              strings().userTimedOut(targetLogin, formatSeconds(duration)),
            );
          } else {
            addSystemMessage(
              channel,
              _modCopy('timeout user', 'timeout', timeoutResult),
            );
          }

        case '/delete':
          if (args.isEmpty) {
            addSystemMessage(channel, strings().usageDelete);
            return;
          }
          final deleteResult = await modActions.deleteMessage(
            auth,
            channel,
            args[0],
          );
          if (deleteResult.ok) {
            addSystemMessage(channel, strings().messageDeleted);
          } else {
            addSystemMessage(
              channel,
              _modCopy('delete chat messages', '', deleteResult),
            );
          }

        case '/clear':
          final clearResult = await modActions.clearChat(auth, channel);
          if (clearResult.ok) {
            addSystemMessage(channel, strings().chatClearedByYou);
          } else {
            addSystemMessage(
              channel,
              _modCopy('delete chat messages', '', clearResult),
            );
          }

        case '/announce':
        case '/announceblue':
        case '/announcegreen':
        case '/announceorange':
        case '/announcepurple':
          if (args.isEmpty) {
            addSystemMessage(channel, strings().usageAnnounce(cmd));
            return;
          }
          var color = switch (cmd) {
            '/announceblue' => 'blue',
            '/announcegreen' => 'green',
            '/announceorange' => 'orange',
            '/announcepurple' => 'purple',
            _ => 'primary',
          };
          var message = args.join(' ');
          if (cmd == '/announce' &&
              const {
                'primary',
                'blue',
                'green',
                'orange',
                'purple',
              }.contains(args[0].toLowerCase())) {
            color = args[0].toLowerCase();
            message = args.sublist(1).join(' ');
            if (message.isEmpty) {
              addSystemMessage(channel, strings().usageAnnounce('/announce'));
              return;
            }
          }
          final announceResult = await modActions.sendAnnouncement(
            auth,
            channel,
            message: message,
            color: color,
          );
          if (!announceResult.ok) {
            addSystemMessage(
              channel,
              _modCopy('send announcement', '', announceResult),
            );
          }

        case '/shoutout':
          if (args.isEmpty) {
            addSystemMessage(channel, strings().usageShoutout);
            return;
          }
          final shoutoutResult = await modActions.sendShoutout(
            auth,
            channel,
            login: args[0],
          );
          if (shoutoutResult.ok) {
            addSystemMessage(channel, strings().cmdShoutoutSent('${args[0]}'));
          } else {
            addSystemMessage(
              channel,
              _modCopy('send shoutout', '', shoutoutResult),
            );
          }

        case '/mod':
        case '/unmod':
          if (args.isEmpty) {
            addSystemMessage(channel, strings().usageUser(cmd));
            return;
          }
          final isMod = cmd == '/mod';
          final modResult = await modActions.setModerator(
            auth,
            channel,
            login: args[0],
            add: isMod,
          );
          if (modResult.ok) {
            addSystemMessage(
              channel,
              isMod
                  ? strings().moderatorAdded('${args[0]}')
                  : strings().moderatorRemoved('${args[0]}'),
            );
          } else {
            addSystemMessage(
              channel,
              _modCopy(
                isMod ? 'add channel moderator' : 'remove channel moderator',
                '',
                modResult,
              ),
            );
          }

        case '/mods':
          final list = await modActions.getModerators(auth, channel);
          if (twitchApi.lastErrorStatus != null) {
            addSystemMessage(
              channel,
              _failed('list moderators', modActions.failureReason()),
            );
          } else if (list.isEmpty) {
            addSystemMessage(channel, strings().noModerators);
          } else {
            addSystemMessage(
              channel,
              strings().moderatorsList(list.join(', ')),
            );
          }

        case '/vip':
        case '/unvip':
          if (args.isEmpty) {
            addSystemMessage(channel, strings().usageUser(cmd));
            return;
          }
          final isVip = cmd == '/vip';
          final vipResult = await modActions.setVip(
            auth,
            channel,
            login: args[0],
            add: isVip,
          );
          if (vipResult.ok) {
            addSystemMessage(
              channel,
              isVip
                  ? strings().vipAdded('${args[0]}')
                  : strings().vipRemoved('${args[0]}'),
            );
          } else {
            addSystemMessage(
              channel,
              _modCopy(isVip ? 'add VIP' : 'remove VIP', '', vipResult),
            );
          }

        case '/vips':
          final list = await modActions.getVips(auth, channel);
          if (twitchApi.lastErrorStatus != null) {
            addSystemMessage(
              channel,
              _failed('list VIPs', modActions.failureReason()),
            );
          } else if (list.isEmpty) {
            addSystemMessage(channel, strings().noVips);
          } else {
            addSystemMessage(channel, strings().vipsList(list.join(', ')));
          }

        case '/slow':
        case '/slowoff':
          if (cmd == '/slowoff') {
            final slowOffResult = await modActions.setSlowMode(
              auth,
              channel,
              enabled: false,
            );
            if (slowOffResult.ok) {
              addSystemMessage(channel, strings().slowDisabled);
            } else {
              addSystemMessage(
                channel,
                _modCopy('update chat settings', '', slowOffResult),
              );
            }
            return;
          }
          final slowSeconds = args.isEmpty
              ? 30
              : _parseDurationSeconds(args.join(' '));
          if (slowSeconds == null || slowSeconds <= 0 || slowSeconds > 120) {
            addSystemMessage(channel, strings().usageSlow);
            return;
          }
          final slowResult = await modActions.setSlowMode(
            auth,
            channel,
            enabled: true,
            seconds: slowSeconds,
          );
          if (slowResult.ok) {
            addSystemMessage(channel, strings().slowEnabled(slowSeconds));
          } else {
            addSystemMessage(
              channel,
              _modCopy('update chat settings', '', slowResult),
            );
          }

        case '/followers':
        case '/followersoff':
          if (cmd == '/followersoff') {
            final followersOffResult = await modActions.setFollowersMode(
              auth,
              channel,
              enabled: false,
            );
            if (followersOffResult.ok) {
              addSystemMessage(channel, strings().followersDisabled);
            } else {
              addSystemMessage(
                channel,
                _modCopy('update chat settings', '', followersOffResult),
              );
            }
            return;
          }
          int? followerMinutes;
          if (args.isNotEmpty) {
            final seconds = _parseDurationSeconds(args.join(' '));
            if (seconds == null || seconds <= 0) {
              addSystemMessage(channel, strings().usageFollowers);
              return;
            }
            followerMinutes = (seconds / 60).ceil();
          }
          final followersResult = await modActions.setFollowersMode(
            auth,
            channel,
            enabled: true,
            minutes: followerMinutes,
          );
          if (followersResult.ok) {
            addSystemMessage(channel, strings().followersEnabled);
          } else {
            addSystemMessage(
              channel,
              _modCopy('update chat settings', '', followersResult),
            );
          }

        case '/emoteonly':
        case '/emoteonlyoff':
          final enable = cmd == '/emoteonly';
          final emoteOnlyResult = await modActions.setEmoteOnly(
            auth,
            channel,
            enabled: enable,
          );
          if (emoteOnlyResult.ok) {
            addSystemMessage(
              channel,
              enable ? strings().emoteOnlyEnabled : strings().emoteOnlyDisabled,
            );
          } else {
            addSystemMessage(
              channel,
              _modCopy('update chat settings', '', emoteOnlyResult),
            );
          }

        case '/subscribers':
        case '/subscribersoff':
          final subsOnly = cmd == '/subscribers';
          final subsResult = await modActions.setSubscribersOnly(
            auth,
            channel,
            enabled: subsOnly,
          );
          if (subsResult.ok) {
            addSystemMessage(
              channel,
              subsOnly ? strings().subsOnlyEnabled : strings().subsOnlyDisabled,
            );
          } else {
            addSystemMessage(
              channel,
              _modCopy('update chat settings', '', subsResult),
            );
          }

        case '/r9kbeta':
        case '/r9kbetaoff':
        case '/uniquechat':
        case '/uniquechatoff':
          final unique = cmd == '/r9kbeta' || cmd == '/uniquechat';
          final uniqueResult = await modActions.setUniqueChat(
            auth,
            channel,
            enabled: unique,
          );
          if (uniqueResult.ok) {
            addSystemMessage(
              channel,
              unique
                  ? strings().uniqueChatEnabled
                  : strings().uniqueChatDisabled,
            );
          } else {
            addSystemMessage(
              channel,
              _modCopy('update chat settings', '', uniqueResult),
            );
          }

        case '/commercial':
          if (args.isEmpty) {
            addSystemMessage(channel, strings().usageCommercial);
            return;
          }
          final length = int.tryParse(args[0]);
          if (length == null ||
              !const {30, 60, 90, 120, 150, 180}.contains(length)) {
            addSystemMessage(channel, strings().usageCommercial);
            return;
          }
          final commercialResult = await modActions.startCommercial(
            auth,
            channel,
            length: length,
          );
          if (commercialResult.ok) {
            addSystemMessage(channel, strings().commercialStarted(length));
          } else {
            addSystemMessage(
              channel,
              _modCopy('start commercial', '', commercialResult),
            );
          }

        case '/raid':
          if (args.isEmpty) {
            addSystemMessage(channel, strings().usageRaid);
            return;
          }
          final raidResult = await modActions.startRaid(
            auth,
            channel,
            login: args[0],
          );
          if (raidResult.ok) {
            addSystemMessage(channel, strings().cmdRaidStarted('${args[0]}'));
          } else {
            addSystemMessage(channel, _modCopy('start a raid', '', raidResult));
          }

        case '/unraid':
          final unraidResult = await modActions.cancelRaid(auth, channel);
          if (unraidResult.ok) {
            addSystemMessage(channel, strings().cmdRaidCancelled);
          } else {
            addSystemMessage(
              channel,
              _modCopy('cancel the raid', '', unraidResult),
            );
          }

        case '/shield':
        case '/shieldoff':
          final active = cmd == '/shield';
          final shieldResult = await modActions.setShieldMode(
            auth,
            channel,
            active: active,
          );
          if (shieldResult.ok) {
            addSystemMessage(
              channel,
              active ? strings().shieldActivated : strings().shieldDeactivated,
            );
          } else {
            addSystemMessage(
              channel,
              _modCopy('update shield mode', '', shieldResult),
            );
          }

        case '/marker':
          final markerResult = await modActions.createMarker(
            auth,
            channel,
            description: args.join(' '),
          );
          if (markerResult.ok) {
            addSystemMessage(channel, strings().cmdMarkerAdded);
          } else {
            addSystemMessage(
              channel,
              _modCopy('create stream marker', '', markerResult),
            );
          }

        case '/poll':
          final pollUsage = strings().usagePoll;
          if (args.isEmpty) {
            addSystemMessage(channel, pollUsage);
            return;
          }
          final parsedPoll = _parsePipeCommand(
            args.join(' '),
            defaultDuration: 60,
          );
          if (parsedPoll == null ||
              parsedPoll.duration < 15 ||
              parsedPoll.duration > 1800 ||
              parsedPoll.options.length < 2 ||
              parsedPoll.options.length > 5) {
            addSystemMessage(channel, pollUsage);
            return;
          }
          final pollResult = await modActions.createPoll(
            auth,
            channel,
            title: parsedPoll.title,
            choices: parsedPoll.options,
            durationSeconds: parsedPoll.duration,
          );
          if (pollResult.ok) {
            addSystemMessage(
              channel,
              strings().cmdPollStarted(parsedPoll.duration),
            );
          } else {
            addSystemMessage(channel, _modCopy('create poll', '', pollResult));
          }

        case '/cancelpoll':
        case '/endpoll':
          final archivePoll = cmd == '/cancelpoll';
          final polls = await modActions.getPolls(auth, channel);
          if (twitchApi.lastErrorStatus != null) {
            addSystemMessage(
              channel,
              _failed('fetch polls', modActions.failureReason()),
            );
            return;
          }
          final activePoll = polls.where((p) => p.isActive).firstOrNull;
          if (activePoll == null) {
            addSystemMessage(channel, strings().cmdNoActivePoll);
            return;
          }
          final pollAction = archivePoll ? 'cancel the poll' : 'end the poll';
          final endPollResult = await modActions.endPoll(
            auth,
            channel,
            pollId: activePoll.id,
            archive: archivePoll,
          );
          if (endPollResult.ok) {
            addSystemMessage(
              channel,
              archivePoll ? strings().cmdPollCancelled : strings().cmdPollEnded,
            );
          } else {
            addSystemMessage(channel, _modCopy(pollAction, '', endPollResult));
          }

        case '/prediction':
          final predictionUsage = strings().usagePrediction;
          if (args.isEmpty) {
            addSystemMessage(channel, predictionUsage);
            return;
          }
          final parsedPrediction = _parsePipeCommand(
            args.join(' '),
            defaultDuration: 60,
          );
          if (parsedPrediction == null ||
              parsedPrediction.duration < 30 ||
              parsedPrediction.duration > 1800 ||
              parsedPrediction.options.length < 2 ||
              parsedPrediction.options.length > 10) {
            addSystemMessage(channel, predictionUsage);
            return;
          }
          final ok = await _moderate(
            'create prediction',
            channel,
            () => twitchApi.createPrediction(
              auth,
              broadcasterId: broadcasterId,
              title: parsedPrediction.title,
              outcomes: parsedPrediction.options,
              windowSeconds: parsedPrediction.duration,
            ),
          );
          if (ok) {
            addSystemMessage(
              channel,
              strings().predictionStarted(parsedPrediction.duration),
            );
          }

        case '/lockprediction':
        case '/cancelprediction':
        case '/resolveprediction':
          final predictions = await modActions.getPredictions(auth, channel);
          if (twitchApi.lastErrorStatus != null) {
            addSystemMessage(
              channel,
              _failed('fetch predictions', modActions.failureReason()),
            );
            return;
          }
          final wantLocked = cmd == '/lockprediction';
          final open = predictions
              .where((p) => wantLocked ? p.isActive : p.isOpen)
              .firstOrNull;
          if (open == null) {
            addSystemMessage(channel, strings().noActivePrediction);
            return;
          }

          String status;
          String successMsg;
          String? winningOutcomeId;
          if (cmd == '/lockprediction') {
            status = 'LOCKED';
            successMsg = strings().cmdPredictionLocked;
          } else if (cmd == '/cancelprediction') {
            status = 'CANCELED';
            successMsg = strings().cmdPredictionCancelled;
          } else {
            // /resolveprediction <1-based index | exact outcome title>.
            if (args.isEmpty) {
              addSystemMessage(channel, strings().usageResolvePrediction);
              return;
            }
            final selector = args.join(' ').trim();
            final outcome = open.outcomeFor(selector);
            if (outcome == null) {
              addSystemMessage(channel, strings().noOutcomeMatching(selector));
              return;
            }
            status = 'RESOLVED';
            winningOutcomeId = outcome.id;
            successMsg = strings().cmdPredictionResolved(outcome.title);
          }
          final endPredictionResult = await modActions.endPrediction(
            auth,
            channel,
            predictionId: open.id,
            status: status,
            winningOutcomeId: winningOutcomeId,
          );
          if (endPredictionResult.ok) {
            addSystemMessage(channel, successMsg);
          } else {
            addSystemMessage(
              channel,
              _modCopy('end the prediction', '', endPredictionResult),
            );
          }

        case '/block':
        case '/unblock':
          if (args.isEmpty) {
            addSystemMessage(channel, strings().usageUser(cmd));
            return;
          }
          final targetId = await _resolveUserId(auth, args[0]);
          if (targetId == null) {
            addSystemMessage(channel, strings().modErrorUnknownUser);
            return;
          }
          final isBlock = cmd == '/block';
          final ok = await _moderate(
            isBlock ? 'block user' : 'unblock user',
            channel,
            () => isBlock
                ? twitchApi.blockUser(auth, targetId)
                : twitchApi.unblockUser(auth, targetId),
          );
          if (ok) {
            final login = args[0].toLowerCase();
            if (isBlock) {
              onUserBlocked?.call(login);
              addSystemMessage(channel, strings().cmdUserBlocked('${args[0]}'));
            } else {
              onUserUnblocked?.call(login);
              addSystemMessage(channel, strings().userUnblocked('${args[0]}'));
            }
          }

        default:
          addSystemMessage(channel, strings().unknownCommand(cmd));
      }
    } catch (e) {
      logDebug('[CommandHandler] $cmd failed: $e');
      addSystemMessage(
        channel,
        strings().commandFailed(modActions.failureReason()),
      );
    }
  }

  /// Applies a block change made outside the slash-command path (the user
  /// profile sheet) through the same callbacks the /block and /unblock
  /// commands use, so the registry and kernel sweep have one owner.
  void notifyUserBlockChanged(String login, {required bool blocked}) {
    if (blocked) {
      onUserBlocked?.call(login);
    } else {
      onUserUnblocked?.call(login);
    }
  }
}
