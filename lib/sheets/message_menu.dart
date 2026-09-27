import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/twitch_message.dart';
import '../util/haptics.dart';
import '../util/prefs.dart';
import '../util/timestamp_formatter.dart';

// Long-press menus for chat messages.
class MessageMenus {
  const MessageMenus({
    required this.prefs,
    required this.findThreadRoot,
    required this.showThreadView,
    required this.startReply,
  });

  final Prefs prefs;
  final TwitchMessage? Function(TwitchMessage msg) findThreadRoot;
  final Future<void> Function(TwitchMessage root) showThreadView;
  final void Function(TwitchMessage msg) startReply;

  void showMessageMenu(BuildContext context, TwitchMessage msg) {
    iosHaptic(HapticFeedback.mediumImpact);
    final threadRoot = findThreadRoot(msg);
    final hasThread = threadRoot != null;
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
                  startReply(msg);
                },
              ),
              if (hasThread)
                ListTile(
                  leading: const Icon(Icons.forum),
                  title: const Text('View thread'),
                  onTap: () {
                    Navigator.pop(ctx);
                    unawaited(showThreadView(threadRoot));
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
                final ts = prefs.showTimestamps
                    ? formatTimestamp(msg.timestamp, prefs.timestampFormat)
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
}
