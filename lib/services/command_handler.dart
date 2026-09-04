import '../models/twitch_command.dart';
import '../services/mod_actions.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_irc.dart';
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
  }) : modActions =
           modActions ??
           ModActions(
             twitchApi: twitchApi,
             getChannelUserIds: getChannelUserIds,
             getCurrentUserId: getCurrentUserId,
           );

  // Shares the ModActions cache so /w and /block reuse mod-path lookups.
  Future<String?> _resolveUserId(TwitchAuth auth, String login) =>
      modActions.resolveUserId(auth, login);

  /// Human-readable reason for the last failed Helix call, in the style of
  /// DankChat's system messages.
  String _failureReason() {
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
      'Failed to $action - ${_failureReason()}',
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
  String _modCopy(
    String action,
    String verb,
    ModResult result,
  ) => switch (result.failure) {
    ModFailure.unknownUser => 'No user matching that username.',
    ModFailure.selfTarget => 'Failed to $action - You cannot $verb yourself.',
    ModFailure.broadcasterTarget =>
      'Failed to $action - You cannot $verb the broadcaster.',
    ModFailure.notJoined => 'Channel not joined.',
    _ =>
      'Failed to $action - ${result.reason ?? 'An unknown error has occurred.'}',
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
      _whisperMessage(channel, 'Usage: /w <username> <message>');
      return;
    }
    final targetId = await _resolveUserId(auth, args[0]);
    if (targetId == null) {
      _whisperMessage(channel, 'No user matching that username.');
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
      _whisperMessage(channel, 'Whisper sent.');
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
      addSystemMessage(
        channel,
        'You must be logged in to use the $cmd command.',
      );
      return;
    }
    final broadcasterId = getChannelUserIds()[channel];
    final currentUserId = getCurrentUserId();
    if (cmd == '/w') {
      if (currentUserId == null) {
        // Whispers are account-scoped, not channel-scoped: this failure means
        // our own user id is unresolved, not that a channel is missing.
        addSystemMessage(
          channel,
          "Couldn't resolve your account; try logging in again.",
        );
        return;
      }
      await _handleWhisper(text, channel, auth, currentUserId);
      return;
    }
    if (currentUserId == null || broadcasterId == null) {
      addSystemMessage(channel, 'Channel not joined.');
      return;
    }

    try {
      switch (cmd) {
        case '/color':
          if (args.isEmpty) {
            addSystemMessage(
              channel,
              "Usage: /color <color> - Color must be one of Twitch's supported colors (blue, blue_violet, cadet_blue, chocolate, coral, dodger_blue, firebrick, golden_rod, green, hot_pink, orange_red, red, sea_green, spring_green, yellow_green) or a hex code (#000000) if you have Turbo or Prime.",
            );
            return;
          }
          final color = args.join(' ');
          final ok = await twitchApi.updateUserChatColor(
            auth,
            userId: currentUserId,
            color: color,
          );
          if (ok) {
            addSystemMessage(channel, 'Your color has been changed to $color');
          } else {
            addSystemMessage(
              channel,
              'Failed to change color to $color - ${_failureReason()}',
            );
          }

        case '/ban':
          if (args.isEmpty) {
            addSystemMessage(channel, 'Usage: /ban <username> [reason]');
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
            addSystemMessage(channel, '$targetLogin has been banned.');
          } else {
            addSystemMessage(channel, _modCopy('ban user', 'ban', banResult));
          }

        case '/unban':
        case '/untimeout':
          if (args.isEmpty) {
            addSystemMessage(channel, 'Usage: $cmd <username>');
            return;
          }
          final unbanResult = await modActions.unbanUser(
            auth,
            channel,
            login: args[0],
          );
          if (unbanResult.ok) {
            addSystemMessage(channel, '${args[0]} has been unbanned.');
          } else {
            addSystemMessage(channel, _modCopy('unban user', '', unbanResult));
          }

        case '/warn':
          if (args.isEmpty) {
            addSystemMessage(channel, 'Usage: /warn <username> [reason]');
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
            addSystemMessage(channel, '$targetLogin has been warned.');
          } else {
            addSystemMessage(
              channel,
              _modCopy('warn user', 'warn', warnResult),
            );
          }

        case '/timeout':
          if (args.isEmpty) {
            addSystemMessage(
              channel,
              'Usage: /timeout <username> [duration] [reason] - Duration (default: 10m) must be a positive number with an optional unit (s, m, h, d, w); maximum is 2 weeks.',
            );
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
              '$targetLogin timed out for ${formatSeconds(duration)}.',
            );
          } else {
            addSystemMessage(
              channel,
              _modCopy('timeout user', 'timeout', timeoutResult),
            );
          }

        case '/delete':
          if (args.isEmpty) {
            addSystemMessage(channel, 'Usage: /delete <message_id>');
            return;
          }
          final deleteResult = await modActions.deleteMessage(
            auth,
            channel,
            args[0],
          );
          if (deleteResult.ok) {
            addSystemMessage(channel, 'Message deleted.');
          } else {
            addSystemMessage(
              channel,
              _modCopy('delete chat messages', '', deleteResult),
            );
          }

        case '/clear':
          final clearResult = await modActions.clearChat(auth, channel);
          if (clearResult.ok) {
            addSystemMessage(channel, 'Chat cleared.');
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
            addSystemMessage(channel, 'Usage: $cmd [color] <message>');
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
              addSystemMessage(channel, 'Usage: /announce [color] <message>');
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
            addSystemMessage(channel, 'Usage: /shoutout <username>');
            return;
          }
          final shoutoutResult = await modActions.sendShoutout(
            auth,
            channel,
            login: args[0],
          );
          if (shoutoutResult.ok) {
            addSystemMessage(channel, 'Sent shoutout to ${args[0]}');
          } else {
            addSystemMessage(
              channel,
              _modCopy('send shoutout', '', shoutoutResult),
            );
          }

        case '/mod':
        case '/unmod':
          if (args.isEmpty) {
            addSystemMessage(channel, 'Usage: $cmd <username>');
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
                  ? 'You have added ${args[0]} as a moderator of this channel.'
                  : 'You have removed ${args[0]} as a moderator of this channel.',
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
              'Failed to list moderators - ${_failureReason()}',
            );
          } else if (list.isEmpty) {
            addSystemMessage(
              channel,
              'This channel does not have any moderators.',
            );
          } else {
            addSystemMessage(
              channel,
              'The moderators of this channel are ${list.join(', ')}.',
            );
          }

        case '/vip':
        case '/unvip':
          if (args.isEmpty) {
            addSystemMessage(channel, 'Usage: $cmd <username>');
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
                  ? 'You have added ${args[0]} as a VIP of this channel.'
                  : 'You have removed ${args[0]} as a VIP of this channel.',
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
              'Failed to list VIPs - ${_failureReason()}',
            );
          } else if (list.isEmpty) {
            addSystemMessage(channel, 'This channel does not have any VIPs.');
          } else {
            addSystemMessage(
              channel,
              'The VIPs of this channel are ${list.join(', ')}.',
            );
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
              addSystemMessage(channel, 'Slow mode disabled.');
            } else {
              addSystemMessage(
                channel,
                _modCopy('update chat settings', '', slowOffResult),
              );
            }
            return;
          }
          final slowSeconds = args.isEmpty ? 30 : int.tryParse(args[0]);
          if (slowSeconds == null || slowSeconds <= 0 || slowSeconds > 120) {
            addSystemMessage(
              channel,
              'Usage: /slow [seconds] - Duration (default: 30) must be a positive number of seconds; maximum is 120.',
            );
            return;
          }
          final slowResult = await modActions.setSlowMode(
            auth,
            channel,
            enabled: true,
            seconds: slowSeconds,
          );
          if (slowResult.ok) {
            addSystemMessage(channel, 'Slow mode enabled (${slowSeconds}s).');
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
              addSystemMessage(channel, 'Followers-only mode disabled.');
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
              addSystemMessage(
                channel,
                'Usage: /followers [duration] - Duration must be a positive number with an optional unit (m, h, d, w); maximum is 3 months.',
              );
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
            addSystemMessage(channel, 'Followers-only mode enabled.');
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
              enable ? 'Emote-only mode enabled.' : 'Emote-only mode disabled.',
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
              subsOnly
                  ? 'Subscribers-only mode enabled.'
                  : 'Subscribers-only mode disabled.',
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
                  ? 'Unique-chat mode enabled.'
                  : 'Unique-chat mode disabled.',
            );
          } else {
            addSystemMessage(
              channel,
              _modCopy('update chat settings', '', uniqueResult),
            );
          }

        case '/commercial':
          if (args.isEmpty) {
            addSystemMessage(
              channel,
              'Usage: /commercial <length> - Valid lengths are 30, 60, 90, 120, 150 and 180 seconds.',
            );
            return;
          }
          final length = int.tryParse(args[0]);
          if (length == null ||
              !const {30, 60, 90, 120, 150, 180}.contains(length)) {
            addSystemMessage(
              channel,
              'Usage: /commercial <length> - Valid lengths are 30, 60, 90, 120, 150 and 180 seconds.',
            );
            return;
          }
          final commercialResult = await modActions.startCommercial(
            auth,
            channel,
            length: length,
          );
          if (commercialResult.ok) {
            addSystemMessage(
              channel,
              'Starting $length second long commercial break.',
            );
          } else {
            addSystemMessage(
              channel,
              _modCopy('start commercial', '', commercialResult),
            );
          }

        case '/raid':
          if (args.isEmpty) {
            addSystemMessage(channel, 'Usage: /raid <username>');
            return;
          }
          final raidResult = await modActions.startRaid(
            auth,
            channel,
            login: args[0],
          );
          if (raidResult.ok) {
            addSystemMessage(channel, 'You started to raid ${args[0]}.');
          } else {
            addSystemMessage(channel, _modCopy('start a raid', '', raidResult));
          }

        case '/unraid':
          final unraidResult = await modActions.cancelRaid(auth, channel);
          if (unraidResult.ok) {
            addSystemMessage(channel, 'You cancelled the raid.');
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
              active
                  ? 'Shield mode was activated.'
                  : 'Shield mode was deactivated.',
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
            addSystemMessage(channel, 'Stream marker added.');
          } else {
            addSystemMessage(
              channel,
              _modCopy('create stream marker', '', markerResult),
            );
          }

        case '/poll':
          const pollUsage =
              'Usage: /poll [duration] <title> | <choice 1> | <choice 2> [| more] - '
              'Duration (default: 60s) must be 15-1800 seconds; 2-5 choices.';
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
          final ok = await _moderate(
            'create poll',
            channel,
            () => twitchApi.createPoll(
              auth,
              broadcasterId: broadcasterId,
              title: parsedPoll.title,
              choices: parsedPoll.options,
              durationSeconds: parsedPoll.duration,
            ),
          );
          if (ok) {
            addSystemMessage(
              channel,
              'Poll started (${parsedPoll.duration}s).',
            );
          }

        case '/cancelpoll':
        case '/endpoll':
          final archivePoll = cmd == '/cancelpoll';
          final polls = await twitchApi.getPolls(auth, broadcasterId);
          if (twitchApi.lastErrorStatus != null) {
            addSystemMessage(
              channel,
              'Failed to fetch polls - ${_failureReason()}',
            );
            return;
          }
          Map<String, dynamic>? activePoll;
          for (final p in polls) {
            if (p['status'] == 'ACTIVE') {
              activePoll = p;
              break;
            }
          }
          if (activePoll == null) {
            addSystemMessage(channel, 'No poll is currently running.');
            return;
          }
          final ok = await _moderate(
            archivePoll ? 'cancel the poll' : 'end the poll',
            channel,
            () => twitchApi.endPoll(
              auth,
              broadcasterId: broadcasterId,
              pollId: activePoll!['id'] as String,
              archive: archivePoll,
            ),
          );
          if (ok) {
            addSystemMessage(
              channel,
              archivePoll ? 'The poll was cancelled.' : 'The poll has ended.',
            );
          }

        case '/prediction':
          const predictionUsage =
              'Usage: /prediction [window] <title> | <outcome 1> | <outcome 2> [| more] - '
              'Window (default: 60s) must be 10-2592000 seconds; 2-11 outcomes.';
          if (args.isEmpty) {
            addSystemMessage(channel, predictionUsage);
            return;
          }
          final parsedPrediction = _parsePipeCommand(
            args.join(' '),
            defaultDuration: 60,
          );
          if (parsedPrediction == null ||
              parsedPrediction.duration < 10 ||
              parsedPrediction.duration > 2592000 ||
              parsedPrediction.options.length < 2 ||
              parsedPrediction.options.length > 11) {
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
              'Prediction started (${parsedPrediction.duration}s).',
            );
          }

        case '/lockprediction':
        case '/cancelprediction':
        case '/resolveprediction':
          final predictions = await twitchApi.getPredictions(
            auth,
            broadcasterId,
          );
          if (twitchApi.lastErrorStatus != null) {
            addSystemMessage(
              channel,
              'Failed to fetch predictions - ${_failureReason()}',
            );
            return;
          }
          Map<String, dynamic>? open;
          for (final p in predictions) {
            if (p['status'] == 'OPEN') {
              open = p;
              break;
            }
          }
          if (open == null) {
            addSystemMessage(channel, 'No prediction is currently running.');
            return;
          }

          String status;
          String successMsg;
          String? winningOutcomeId;
          if (cmd == '/lockprediction') {
            status = 'LOCKED';
            successMsg = 'Predictions are now locked.';
          } else if (cmd == '/cancelprediction') {
            status = 'CANCELED';
            successMsg =
                'The prediction was cancelled and channel points were refunded.';
          } else {
            // /resolveprediction <1-based index | exact outcome title>.
            if (args.isEmpty) {
              addSystemMessage(
                channel,
                'Usage: /resolveprediction <outcome number or exact title>',
              );
              return;
            }
            final outcomes = (open['outcomes'] as List<dynamic>? ?? [])
                .cast<Map>();
            String? matchTitle;
            final selector = args.join(' ').trim();
            final index = int.tryParse(selector);
            if (index != null && index >= 1 && index <= outcomes.length) {
              matchTitle = outcomes[index - 1]['title'] as String?;
            } else {
              for (final o in outcomes) {
                if ((o['title'] as String?)?.toLowerCase() ==
                    selector.toLowerCase()) {
                  matchTitle = o['title'] as String?;
                  break;
                }
              }
            }
            final outcomeId =
                index != null && index >= 1 && index <= outcomes.length
                ? outcomes[index - 1]['id'] as String?
                : outcomes
                      .where(
                        (o) =>
                            (o['title'] as String?)?.toLowerCase() ==
                            selector.toLowerCase(),
                      )
                      .map((o) => o['id'] as String?)
                      .firstOrNull;
            if (outcomeId == null) {
              addSystemMessage(channel, 'No outcome matching "$selector".');
              return;
            }
            status = 'RESOLVED';
            winningOutcomeId = outcomeId;
            successMsg =
                'The prediction was resolved${matchTitle != null ? ': $matchTitle' : ''}.';
          }
          final ok = await _moderate(
            'end the prediction',
            channel,
            () => twitchApi.endPrediction(
              auth,
              broadcasterId: broadcasterId,
              predictionId: open!['id'] as String,
              status: status,
              winningOutcomeId: winningOutcomeId,
            ),
          );
          if (ok) {
            addSystemMessage(channel, successMsg);
          }

        case '/block':
        case '/unblock':
          if (args.isEmpty) {
            addSystemMessage(channel, 'Usage: $cmd <username>');
            return;
          }
          final targetId = await _resolveUserId(auth, args[0]);
          if (targetId == null) {
            addSystemMessage(channel, 'No user matching that username.');
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
              addSystemMessage(
                channel,
                'You successfully blocked user ${args[0]}',
              );
            } else {
              onUserUnblocked?.call(login);
              addSystemMessage(
                channel,
                'You successfully unblocked user ${args[0]}',
              );
            }
          }

        default:
          addSystemMessage(channel, '$cmd is not a known command');
      }
    } catch (e) {
      logDebug('[CommandHandler] $cmd failed: $e');
      addSystemMessage(channel, 'Command failed: ${_failureReason()}');
    }
  }
}
