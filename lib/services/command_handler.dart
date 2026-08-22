import '../models/twitch_command.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_irc.dart';
import '../util/log.dart';

class CommandHandler {
  static final _whitespaceRe = RegExp(r'\s+');
  final TwitchApi twitchApi;
  final IrcService irc;
  final Map<String, String> Function() getChannelUserIds;
  final String? Function() getCurrentUserId;
  final String? Function() getCurrentUserLogin;
  final void Function(String channel, String message) addSystemMessage;
  final void Function(String channel, String message)? whisperAddSystemMessage;
  final void Function(String target, String message)? onWhisperSent;
  final void Function(String login)? onUserBlocked;
  final void Function(String login)? onUserUnblocked;
  final _userIdCache = <String, String>{};

  /// Every command the app can run. Used for / autocomplete — all commands
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
  });

  Future<String?> _resolveUserId(TwitchAuth auth, String login) async {
    final lower = login.toLowerCase();
    final cached = _userIdCache[lower];
    if (cached != null) return cached;
    final id = await twitchApi.getUserId(auth, login);
    if (id != null) _userIdCache[lower] = id;
    return id;
  }

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
  /// (Feb 2023), so there is no IRC fallback — Helix is the only way to
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
        addSystemMessage(channel, 'Channel not joined.');
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
          final targetId = await _resolveUserId(auth, targetLogin);
          if (targetId == null) {
            addSystemMessage(channel, 'No user matching that username.');
            return;
          }
          if (targetId == currentUserId) {
            addSystemMessage(
              channel,
              'Failed to ban user - You cannot ban yourself.',
            );
            return;
          }
          if (targetId == broadcasterId) {
            addSystemMessage(
              channel,
              'Failed to ban user - You cannot ban the broadcaster.',
            );
            return;
          }
          final ok = await _moderate(
            'ban user',
            channel,
            () => twitchApi.banUser(
              auth,
              broadcasterId: broadcasterId,
              moderatorId: currentUserId,
              userId: targetId,
              reason: reason,
            ),
          );
          if (ok) {
            addSystemMessage(channel, '$targetLogin has been banned.');
          }

        case '/unban':
        case '/untimeout':
          if (args.isEmpty) {
            addSystemMessage(channel, 'Usage: $cmd <username>');
            return;
          }
          final targetId = await _resolveUserId(auth, args[0]);
          if (targetId == null) {
            addSystemMessage(channel, 'No user matching that username.');
            return;
          }
          final ok = await _moderate(
            'unban user',
            channel,
            () => twitchApi.unbanUser(
              auth,
              broadcasterId: broadcasterId,
              moderatorId: currentUserId,
              userId: targetId,
            ),
          );
          if (ok) {
            addSystemMessage(channel, '${args[0]} has been unbanned.');
          }

        case '/warn':
          if (args.isEmpty) {
            addSystemMessage(channel, 'Usage: /warn <username> [reason]');
            return;
          }
          final targetLogin = args[0];
          final warnReason = args.length > 1 ? args.sublist(1).join(' ') : null;
          final targetId = await _resolveUserId(auth, targetLogin);
          if (targetId == null) {
            addSystemMessage(channel, 'No user matching that username.');
            return;
          }
          if (targetId == currentUserId) {
            addSystemMessage(
              channel,
              'Failed to warn user - You cannot warn yourself.',
            );
            return;
          }
          if (targetId == broadcasterId) {
            addSystemMessage(
              channel,
              'Failed to warn user - You cannot warn the broadcaster.',
            );
            return;
          }
          final ok = await _moderate(
            'warn user',
            channel,
            () => twitchApi.warnUser(
              auth,
              broadcasterId: broadcasterId,
              moderatorId: currentUserId,
              userId: targetId,
              reason: warnReason,
            ),
          );
          if (ok) {
            addSystemMessage(channel, '$targetLogin has been warned.');
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
          final targetId = await _resolveUserId(auth, targetLogin);
          if (targetId == null) {
            addSystemMessage(channel, 'No user matching that username.');
            return;
          }
          if (targetId == currentUserId) {
            addSystemMessage(
              channel,
              'Failed to timeout user - You cannot timeout yourself.',
            );
            return;
          }
          if (targetId == broadcasterId) {
            addSystemMessage(
              channel,
              'Failed to timeout user - You cannot timeout the broadcaster.',
            );
            return;
          }
          final ok = await _moderate(
            'timeout user',
            channel,
            () => twitchApi.banUser(
              auth,
              broadcasterId: broadcasterId,
              moderatorId: currentUserId,
              userId: targetId,
              duration: duration,
              reason: reason,
            ),
          );
          if (ok) {
            addSystemMessage(
              channel,
              '$targetLogin timed out for ${duration}s.',
            );
          }

        case '/delete':
          if (args.isEmpty) {
            addSystemMessage(channel, 'Usage: /delete <message_id>');
            return;
          }
          final ok = await _moderate(
            'delete chat messages',
            channel,
            () => twitchApi.deleteChatMessage(
              auth,
              broadcasterId: broadcasterId,
              moderatorId: currentUserId,
              messageId: args[0],
            ),
          );
          if (ok) {
            addSystemMessage(channel, 'Message deleted.');
          }

        case '/clear':
          final ok = await _moderate(
            'delete chat messages',
            channel,
            () => twitchApi.deleteChatMessage(
              auth,
              broadcasterId: broadcasterId,
              moderatorId: currentUserId,
            ),
          );
          if (ok) {
            addSystemMessage(channel, 'Chat cleared.');
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
          final ok = await twitchApi.sendChatAnnouncement(
            auth,
            broadcasterId: broadcasterId,
            moderatorId: currentUserId,
            message: message,
            color: color,
          );
          if (!ok) {
            addSystemMessage(
              channel,
              'Failed to send announcement - ${_failureReason()}',
            );
          }

        case '/shoutout':
          if (args.isEmpty) {
            addSystemMessage(channel, 'Usage: /shoutout <username>');
            return;
          }
          final targetId = await _resolveUserId(auth, args[0]);
          if (targetId == null) {
            addSystemMessage(channel, 'No user matching that username.');
            return;
          }
          final ok = await twitchApi.sendShoutout(
            auth,
            broadcasterId: broadcasterId,
            moderatorId: currentUserId,
            targetUserId: targetId,
          );
          if (!ok) {
            addSystemMessage(
              channel,
              'Failed to send shoutout - ${_failureReason()}',
            );
          } else {
            addSystemMessage(channel, 'Sent shoutout to ${args[0]}');
          }

        case '/mod':
        case '/unmod':
          if (args.isEmpty) {
            addSystemMessage(channel, 'Usage: $cmd <username>');
            return;
          }
          final targetId = await _resolveUserId(auth, args[0]);
          if (targetId == null) {
            addSystemMessage(channel, 'No user matching that username.');
            return;
          }
          final isMod = cmd == '/mod';
          final ok = await _moderate(
            isMod ? 'add channel moderator' : 'remove channel moderator',
            channel,
            () => isMod
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
          if (ok) {
            addSystemMessage(
              channel,
              isMod
                  ? 'You have added ${args[0]} as a moderator of this channel.'
                  : 'You have removed ${args[0]} as a moderator of this channel.',
            );
          }

        case '/mods':
          final list = await twitchApi.getModerators(auth, broadcasterId);
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
          final targetId = await _resolveUserId(auth, args[0]);
          if (targetId == null) {
            addSystemMessage(channel, 'No user matching that username.');
            return;
          }
          final isVip = cmd == '/vip';
          final ok = await _moderate(
            isVip ? 'add VIP' : 'remove VIP',
            channel,
            () => isVip
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
          if (ok) {
            addSystemMessage(
              channel,
              isVip
                  ? 'You have added ${args[0]} as a VIP of this channel.'
                  : 'You have removed ${args[0]} as a VIP of this channel.',
            );
          }

        case '/vips':
          final list = await twitchApi.getVips(auth, broadcasterId);
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
            final ok = await _moderate(
              'update chat settings',
              channel,
              () => twitchApi.updateChatSettings(
                auth,
                broadcasterId: broadcasterId,
                moderatorId: currentUserId,
                body: {'slow_mode': false},
              ),
            );
            if (ok) {
              addSystemMessage(channel, 'Slow mode disabled.');
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
          final ok = await _moderate(
            'update chat settings',
            channel,
            () => twitchApi.updateChatSettings(
              auth,
              broadcasterId: broadcasterId,
              moderatorId: currentUserId,
              body: {'slow_mode': true, 'slow_mode_wait_time': slowSeconds},
            ),
          );
          if (ok) {
            addSystemMessage(channel, 'Slow mode enabled (${slowSeconds}s).');
          }

        case '/followers':
        case '/followersoff':
          if (cmd == '/followersoff') {
            final ok = await _moderate(
              'update chat settings',
              channel,
              () => twitchApi.updateChatSettings(
                auth,
                broadcasterId: broadcasterId,
                moderatorId: currentUserId,
                body: {'follower_mode': false},
              ),
            );
            if (ok) {
              addSystemMessage(channel, 'Followers-only mode disabled.');
            }
            return;
          }
          Map<String, dynamic> body = {'follower_mode': true};
          if (args.isNotEmpty) {
            final seconds = _parseDurationSeconds(args.join(' '));
            if (seconds == null || seconds <= 0) {
              addSystemMessage(
                channel,
                'Usage: /followers [duration] - Duration must be a positive number with an optional unit (m, h, d, w); maximum is 3 months.',
              );
              return;
            }
            body = {
              'follower_mode': true,
              'follower_mode_duration': (seconds / 60).ceil(),
            };
          }
          final ok = await _moderate(
            'update chat settings',
            channel,
            () => twitchApi.updateChatSettings(
              auth,
              broadcasterId: broadcasterId,
              moderatorId: currentUserId,
              body: body,
            ),
          );
          if (ok) {
            addSystemMessage(channel, 'Followers-only mode enabled.');
          }

        case '/emoteonly':
        case '/emoteonlyoff':
          final enable = cmd == '/emoteonly';
          final ok = await _moderate(
            'update chat settings',
            channel,
            () => twitchApi.updateChatSettings(
              auth,
              broadcasterId: broadcasterId,
              moderatorId: currentUserId,
              body: {'emote_mode': enable},
            ),
          );
          if (ok) {
            addSystemMessage(
              channel,
              enable ? 'Emote-only mode enabled.' : 'Emote-only mode disabled.',
            );
          }

        case '/subscribers':
        case '/subscribersoff':
          final enable = cmd == '/subscribers';
          final ok = await _moderate(
            'update chat settings',
            channel,
            () => twitchApi.updateChatSettings(
              auth,
              broadcasterId: broadcasterId,
              moderatorId: currentUserId,
              body: {'subscriber_mode': enable},
            ),
          );
          if (ok) {
            addSystemMessage(
              channel,
              enable
                  ? 'Subscribers-only mode enabled.'
                  : 'Subscribers-only mode disabled.',
            );
          }

        case '/r9kbeta':
        case '/r9kbetaoff':
        case '/uniquechat':
        case '/uniquechatoff':
          final enable = cmd == '/r9kbeta' || cmd == '/uniquechat';
          final ok = await _moderate(
            'update chat settings',
            channel,
            () => twitchApi.updateChatSettings(
              auth,
              broadcasterId: broadcasterId,
              moderatorId: currentUserId,
              body: {'unique_chat_mode': enable},
            ),
          );
          if (ok) {
            addSystemMessage(
              channel,
              enable
                  ? 'Unique-chat mode enabled.'
                  : 'Unique-chat mode disabled.',
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
          final ok = await _moderate(
            'start commercial',
            channel,
            () => twitchApi.startCommercial(
              auth,
              broadcasterId: broadcasterId,
              length: length,
            ),
          );
          if (ok) {
            addSystemMessage(
              channel,
              'Starting $length second long commercial break.',
            );
          }

        case '/raid':
          if (args.isEmpty) {
            addSystemMessage(channel, 'Usage: /raid <username>');
            return;
          }
          final targetId = await _resolveUserId(auth, args[0]);
          if (targetId == null) {
            addSystemMessage(channel, 'No user matching that username.');
            return;
          }
          final ok = await _moderate(
            'start a raid',
            channel,
            () => twitchApi.startRaid(
              auth,
              fromBroadcasterId: broadcasterId,
              toBroadcasterId: targetId,
            ),
          );
          if (ok) {
            addSystemMessage(channel, 'You started to raid ${args[0]}.');
          }

        case '/unraid':
          final ok = await _moderate(
            'cancel the raid',
            channel,
            () => twitchApi.cancelRaid(auth, broadcasterId: broadcasterId),
          );
          if (ok) {
            addSystemMessage(channel, 'You cancelled the raid.');
          }

        case '/shield':
        case '/shieldoff':
          final active = cmd == '/shield';
          final ok = await _moderate(
            'update shield mode',
            channel,
            () => twitchApi.updateShieldMode(
              auth,
              broadcasterId: broadcasterId,
              moderatorId: currentUserId,
              active: active,
            ),
          );
          if (ok) {
            addSystemMessage(
              channel,
              active
                  ? 'Shield mode was activated.'
                  : 'Shield mode was deactivated.',
            );
          }

        case '/marker':
          final joined = args.join(' ');
          final description = joined.length <= 140
              ? joined
              : joined.substring(0, 140);
          final ok = await _moderate(
            'create stream marker',
            channel,
            () => twitchApi.createMarker(
              auth,
              broadcasterId: broadcasterId,
              description: description.isEmpty ? null : description,
            ),
          );
          if (ok) {
            addSystemMessage(channel, 'Stream marker added.');
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
