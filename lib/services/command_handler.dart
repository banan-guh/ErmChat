import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import '../services/twitch_irc.dart';

class CommandHandler {
  final TwitchApi twitchApi;
  final IrcService irc;
  final Map<String, String> Function() getChannelUserIds;
  final String? Function() getCurrentUserId;
  final String? Function() getCurrentUserLogin;
  final void Function(String channel, String message) addSystemMessage;
  final _userIdCache = <String, String>{};

  CommandHandler({
    required this.twitchApi,
    required this.irc,
    required this.getChannelUserIds,
    required this.getCurrentUserId,
    required this.getCurrentUserLogin,
    required this.addSystemMessage,
  });

  Future<String?> _resolveUserId(TwitchAuth auth, String login) async {
    final lower = login.toLowerCase();
    final cached = _userIdCache[lower];
    if (cached != null) return cached;
    final id = await twitchApi.getUserId(auth, login);
    if (id != null) _userIdCache[lower] = id;
    return id;
  }

  Future<void> handle(String text, String channel, TwitchAuth auth) async {
    final parts = text.split(RegExp(r'\s+'));
    final cmd = parts[0].toLowerCase();
    final args = parts.length > 1 ? parts.sublist(1) : [];

    // /me is sent via raw IRC (not Helix API) and bypasses the auth gate
    // below — IRC handles it natively. The "/me" prefix is sent as-is.
    if (cmd == '/me') {
      final currentUserLogin = getCurrentUserLogin();
      if (currentUserLogin != null && auth.isConfigured) {
        irc.sendMessage(channel, text);
      }
      return;
    }

    final broadcasterId = getChannelUserIds()[channel];
    final currentUserId = getCurrentUserId();
    if (currentUserId == null ||
        broadcasterId == null ||
        !auth.isConfigured) {
      addSystemMessage(channel, 'Not authenticated or channel not joined.');
      return;
    }

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
            'Failed to change color to $color - ${twitchApi.lastError ?? "unknown error"}',
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
          addSystemMessage(channel, 'User "$targetLogin" not found.');
          return;
        }
        final ok = await twitchApi.banUser(
          auth,
          broadcasterId: broadcasterId,
          moderatorId: currentUserId,
          userId: targetId,
          reason: reason,
        );
        if (ok) {
          addSystemMessage(channel, '$targetLogin has been banned.');
        } else {
          addSystemMessage(
            channel,
            'Failed to ban $targetLogin: ${twitchApi.lastError ?? "unknown error"}',
          );
        }

      case '/unban':
        if (args.isEmpty) {
          addSystemMessage(channel, 'Usage: /unban <username>');
          return;
        }
        final targetId = await _resolveUserId(auth, args[0]);
        if (targetId == null) {
          addSystemMessage(channel, 'User "${args[0]}" not found.');
          return;
        }
        final ok = await twitchApi.unbanUser(
          auth,
          broadcasterId: broadcasterId,
          moderatorId: currentUserId,
          userId: targetId,
        );
        if (ok) {
          addSystemMessage(channel, '${args[0]} has been unbanned.');
        } else {
          addSystemMessage(
            channel,
            'Failed to unban ${args[0]}: ${twitchApi.lastError ?? "unknown error"}',
          );
        }

      case '/timeout':
        if (args.isEmpty) {
          addSystemMessage(
            channel,
            'Usage: /timeout <username> [seconds] [reason]',
          );
          return;
        }
        final targetLogin = args[0];
        int duration = 600;
        String? reason;
        if (args.length > 1) {
          final parsed = int.tryParse(args[1]);
          if (parsed != null) {
            duration = parsed;
            if (args.length > 2) reason = args.sublist(2).join(' ');
          } else {
            reason = args.sublist(1).join(' ');
          }
        }
        final targetId = await _resolveUserId(auth, targetLogin);
        if (targetId == null) {
          addSystemMessage(channel, 'User "$targetLogin" not found.');
          return;
        }
        final ok = await twitchApi.banUser(
          auth,
          broadcasterId: broadcasterId,
          moderatorId: currentUserId,
          userId: targetId,
          duration: duration,
          reason: reason,
        );
        if (ok) {
          addSystemMessage(
            channel,
            '$targetLogin timed out for ${duration}s.',
          );
        } else {
          addSystemMessage(
            channel,
            'Failed to timeout $targetLogin: ${twitchApi.lastError ?? "unknown error"}',
          );
        }

      case '/delete':
        if (args.isEmpty) {
          addSystemMessage(channel, 'Usage: /delete <message_id>');
          return;
        }
        final ok = await twitchApi.deleteChatMessage(
          auth,
          broadcasterId: broadcasterId,
          moderatorId: currentUserId,
          messageId: args[0],
        );
        if (ok) {
          addSystemMessage(channel, 'Message deleted.');
        } else {
          addSystemMessage(
            channel,
            'Failed to delete message: ${twitchApi.lastError ?? "unknown error"}',
          );
        }

      case '/clear':
        final ok = await twitchApi.deleteChatMessage(
          auth,
          broadcasterId: broadcasterId,
          moderatorId: currentUserId,
        );
        if (ok) {
          addSystemMessage(channel, 'Chat cleared.');
        } else {
          addSystemMessage(
            channel,
            'Failed to clear chat: ${twitchApi.lastError ?? "unknown error"}',
          );
        }

      case '/announce':
        if (args.isEmpty) {
          addSystemMessage(channel, 'Usage: /announce <message>');
          return;
        }
        final ok = await twitchApi.sendChatAnnouncement(
          auth,
          broadcasterId: broadcasterId,
          moderatorId: currentUserId,
          message: args.join(' '),
        );
        if (!ok) {
          addSystemMessage(
            channel,
            'Failed to announce: ${twitchApi.lastError ?? "unknown error"}',
          );
        }

      case '/shoutout':
        if (args.isEmpty) {
          addSystemMessage(channel, 'Usage: /shoutout <username>');
          return;
        }
        final targetId = await _resolveUserId(auth, args[0]);
        if (targetId == null) {
          addSystemMessage(channel, 'User "${args[0]}" not found.');
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
            'Failed to send shoutout: ${twitchApi.lastError ?? "unknown error"}',
          );
        }

      default:
        addSystemMessage(channel, 'Unknown command: $cmd');
    }
  }
}
