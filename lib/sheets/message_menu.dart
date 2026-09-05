import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/twitch_message.dart';
import '../composer/composer_controller.dart';
import '../services/chat_connection_manager.dart';
import '../services/mod_actions.dart';
import '../services/twitch_auth.dart';
import '../util/haptics.dart';
import '../util/timestamp_formatter.dart';
import '../widgets/mod_view.dart';

// Shell-owned state the menus read but do not own.
abstract class MessageMenuHost extends ShellState {
  TwitchMessage? findThreadRoot(TwitchMessage msg);
  bool isThreadSaved(TwitchMessage msg);
  void startReply(TwitchMessage msg);
  Future<void> showThreadView(TwitchMessage root);
  void toggleSaveThread(TwitchMessage root);
}

// Long-press menus for chat messages plus the mod action verbs.
class MessageMenus {
  const MessageMenus({
    required this.twitchAuth,
    required this.chatConn,
    required this.modActions,
    required this.host,
  });

  final TwitchAuth twitchAuth;
  final ChatConnectionManager chatConn;
  final ModActions modActions;
  final MessageMenuHost host;

  void showMessageMenu(BuildContext context, TwitchMessage msg) {
    iosHaptic(HapticFeedback.mediumImpact);
    final threadRoot = host.findThreadRoot(msg);
    final hasThread = threadRoot != null;
    final threadSaved = hasThread && host.isThreadSaved(threadRoot);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply to message'),
                onTap: () {
                  Navigator.pop(ctx);
                  host.startReply(msg);
                },
              ),
              if (hasThread)
                ListTile(
                  leading: const Icon(Icons.forum),
                  title: const Text('View thread'),
                  onTap: () {
                    Navigator.pop(ctx);
                    unawaited(host.showThreadView(threadRoot));
                  },
                ),
              if (hasThread)
                ListTile(
                  leading: Icon(
                    threadSaved ? Icons.bookmark : Icons.bookmark_border,
                  ),
                  title: Text(threadSaved ? 'Unsave thread' : 'Save thread'),
                  onTap: () {
                    Navigator.pop(ctx);
                    host.toggleSaveThread(threadRoot);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy message'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.text));
                  Navigator.pop(ctx);
                },
              ),
              if (_canModerate(msg)) ...[
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('Timeout'),
                  onTap: () {
                    Navigator.pop(ctx);
                    unawaited(modTimeout(context, msg));
                  },
                ),
                if (msg.messageId != null)
                  ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: const Text('Delete'),
                    onTap: () {
                      Navigator.pop(ctx);
                      unawaited(modDelete(context, msg));
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.warning_amber_outlined),
                  title: const Text('Warn'),
                  onTap: () {
                    Navigator.pop(ctx);
                    unawaited(modWarn(context, msg));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.gavel_outlined),
                  title: const Text('Ban'),
                  onTap: () {
                    Navigator.pop(ctx);
                    unawaited(modBan(context, msg));
                  },
                ),
                const Divider(height: 1),
              ],
              ListTile(
                leading: const Icon(Icons.more_horiz),
                title: const Text('More...'),
                onTap: () {
                  Navigator.pop(ctx);
                  showMoreMenu(context, msg);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Panels (thread, mentions, whispers): copy + more menu. No reply (the
  // input bar belongs to the main chat) and no thread navigation.
  void showPanelMessageMenu(BuildContext context, TwitchMessage msg) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy message'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.text));
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: const Icon(Icons.more_horiz),
                title: const Text('More...'),
                onTap: () {
                  Navigator.pop(ctx);
                  showMoreMenu(context, msg);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showMoreMenu(BuildContext context, TwitchMessage msg) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_all),
              title: const Text('Copy full message'),
              onTap: () {
                final ts = host.showTimestamps
                    ? formatTimestamp(msg.timestamp, host.timestampFormat)
                    : '';
                Clipboard.setData(
                  ClipboardData(
                    text: '$ts ${msg.formattedUsername}: ${msg.text}',
                  ),
                );
                Navigator.pop(ctx);
              },
            ),
            if (msg.messageId != null)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy message ID'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.messageId!));
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  bool _canModerate(TwitchMessage msg) {
    final channel = msg.channel;
    // No mod actions on yourself; Twitch rejects them all.
    final selfLogin = host.sessionLogin?.toLowerCase();
    return !msg.isSystem &&
        channel != null &&
        chatConn.isModerationActive(channel) &&
        (selfLogin == null || msg.login.toLowerCase() != selfLogin);
  }

  Future<void> modTimeout(BuildContext context, TwitchMessage msg) async {
    final channel = msg.channel;
    if (channel == null) return;
    final picked = await showTimeoutDialog(context, msg.login);
    if (picked == null || !context.mounted) return;
    final timeoutResult = await modActions.timeoutUser(
      twitchAuth,
      channel,
      login: msg.login,
      userId: msg.userId,
      duration: picked.seconds,
      reason: picked.reason,
    );
    if (!context.mounted) return;
    showModError(context, timeoutResult);
  }

  Future<void> modDelete(BuildContext context, TwitchMessage msg) async {
    final channel = msg.channel;
    final messageId = msg.messageId;
    if (channel == null || messageId == null) return;
    final deleteResult = await modActions.deleteMessage(
      twitchAuth,
      channel,
      messageId,
    );
    if (!context.mounted) return;
    showModError(context, deleteResult);
  }

  Future<void> modWarn(BuildContext context, TwitchMessage msg) async {
    final channel = msg.channel;
    if (channel == null) return;
    final reason = await showModTextDialog(
      context,
      title: 'Warn ${msg.login}?',
      label: 'Reason (optional)',
      confirmLabel: 'Warn',
    );
    if (reason == null || !context.mounted) return;
    final warnResult = await modActions.warnUser(
      twitchAuth,
      channel,
      login: msg.login,
      userId: msg.userId,
      reason: reason.isEmpty ? null : reason,
    );
    if (!context.mounted) return;
    showModError(context, warnResult);
  }

  Future<void> modBan(BuildContext context, TwitchMessage msg) async {
    final channel = msg.channel;
    if (channel == null) return;
    final reason = await showModTextDialog(
      context,
      title: 'Ban ${msg.login}?',
      label: 'Reason (optional)',
      confirmLabel: 'Ban',
    );
    if (reason == null || !context.mounted) return;
    final banResult = await modActions.banUser(
      twitchAuth,
      channel,
      login: msg.login,
      userId: msg.userId,
      reason: reason.isEmpty ? null : reason,
    );
    if (!context.mounted) return;
    showModError(context, banResult);
  }
}
