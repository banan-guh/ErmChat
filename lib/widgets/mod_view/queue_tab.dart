import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../chat/chat.dart';
import '../../chat/channel/moderation.dart';
import '../../services/mod_actions.dart';
import '../../services/twitch_auth.dart';
import 'common.dart';

class QueueTab extends StatefulWidget {
  const QueueTab({
    super.key,
    required this.channel,
    required this.chat,
    required this.modActions,
    required this.auth,
    required this.automodActive,
    required this.scopeReady,
    required this.scopeStale,
    required this.onNotice,
    required this.onShowUser,
  });

  final String channel;
  final Chat chat;
  final ModActions modActions;
  final TwitchAuth auth;
  final bool automodActive;
  final bool scopeReady;
  final bool scopeStale;
  final ValueChanged<String> onNotice;
  final ValueChanged<String>? onShowUser;

  @override
  State<QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<QueueTab> {
  final _pending = <String>{};
  String? _filter;

  @override
  void didUpdateWidget(covariant QueueTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel && _filter != null) {
      setState(() => _filter = null);
    }
  }

  Future<void> _decide(HeldMessage held, bool allow) async {
    if (!_pending.add(held.messageId)) return;
    setState(() {});
    bool decidedOk = false;
    try {
      final result = await widget.modActions.decideHeldMessage(
        widget.auth,
        widget.channel,
        messageId: held.messageId,
        allow: allow,
      );
      decidedOk = result.ok;
      if (!mounted) return;
      if (!result.ok) widget.onNotice(modErrorText(result));
    } finally {
      _pending.remove(held.messageId);
      if (mounted) setState(() {});
    }
    if (decidedOk) {
      widget.chat
          .channelFor(widget.channel)
          ?.moderation
          .resolveHeld(held.messageId);
    }
  }

  Future<void> _timeout(HeldMessage held) async {
    final picked = await showTimeoutDialog(context, held.userLogin);
    if (picked == null || !mounted) return;
    final result = await widget.modActions.timeoutUser(
      widget.auth,
      widget.channel,
      login: held.userLogin,
      duration: picked.seconds,
      reason: picked.reason,
    );
    if (!mounted) return;
    if (result.ok) {
      widget.onNotice('Timed out ${held.userLogin}.');
    } else {
      widget.onNotice(modErrorText(result));
    }
  }

  Future<void> _ban(HeldMessage held) async {
    final reason = await showModTextDialog(
      context,
      title: 'Ban ${held.userLogin}?',
      label: 'Reason (optional)',
      confirmLabel: 'Ban',
      allowEmpty: true,
    );
    if (reason == null || !mounted) return;
    final result = await widget.modActions.banUser(
      widget.auth,
      widget.channel,
      login: held.userLogin,
      reason: reason.isEmpty ? null : reason,
    );
    if (!mounted) return;
    if (result.ok) {
      widget.onNotice('Banned ${held.userLogin}.');
    } else {
      widget.onNotice(modErrorText(result));
    }
  }

  Widget _filters(List<HeldMessage> queue) {
    final cats = <String>{for (final h in queue) h.category}.toList()..sort();
    if (cats.length < 2) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          ChoiceChip(
            label: const Text('All'),
            selected: _filter == null,
            onSelected: (_) => setState(() => _filter = null),
          ),
          for (final c in cats)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: ChoiceChip(
                label: Text(c),
                selected: _filter == c,
                onSelected: (_) =>
                    setState(() => _filter = _filter == c ? null : c),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.automodActive) {
      final needsScope = widget.scopeReady || widget.scopeStale;
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.shield_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                needsScope
                    ? 'AutoMod queue needs the moderator:manage:automod scope. '
                          'Your login predates it.'
                    : 'AutoMod queue is unavailable here.',
                textAlign: TextAlign.center,
              ),
              if (needsScope)
                TextButton(
                  onPressed: () => widget.onNotice(
                    'Open Settings > Account > Log in again to grant moderator:manage:automod.',
                  ),
                  child: const Text('How to re-login'),
                ),
            ],
          ),
        ),
      );
    }
    final mod = widget.chat.channelFor(widget.channel)?.moderation;
    if (mod == null) {
      return const ModEmpty(
        icon: Icons.shield_outlined,
        title: 'Queue is clear.',
        subtitle: 'Held messages will appear here for review.',
      );
    }
    return ValueListenableBuilder<int>(
      valueListenable: mod.heldVersion,
      builder: (_, _, _) {
        final all = mod.held;
        if (all.isEmpty) {
          return const ModEmpty(
            icon: Icons.shield_outlined,
            title: 'Queue is clear.',
            subtitle: 'Held messages will appear here for review.',
          );
        }
        final queue = _filter == null
            ? all
            : [
                for (final h in all)
                  if (h.category == _filter) h,
              ];
        return Column(
          children: [
            _filters(all),
            Expanded(
              child: queue.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.filter_list_off_outlined,
                            size: 48,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 12),
                          const Text('No matches for this filter.'),
                          TextButton(
                            onPressed: () => setState(() => _filter = null),
                            child: const Text('Clear filter'),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                      itemCount: queue.length,
                      itemBuilder: (_, i) {
                        final held = queue[i];
                        final busy = _pending.contains(held.messageId);
                        return Card(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 6,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  title: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          held.userLogin,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      _CategoryChip(held.category),
                                    ],
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(held.text, maxLines: 4),
                                  ),
                                  onTap: () =>
                                      widget.onShowUser?.call(held.userLogin),
                                ),
                                if (busy)
                                  const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                else
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      8,
                                      0,
                                      8,
                                      0,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: FilledButton.icon(
                                            onPressed: () =>
                                                _decide(held, true),
                                            icon: const Icon(
                                              Icons.check,
                                              size: 18,
                                            ),
                                            label: const Text('Allow'),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: OutlinedButton.icon(
                                            onPressed: () =>
                                                _decide(held, false),
                                            icon: const Icon(
                                              Icons.close,
                                              size: 18,
                                            ),
                                            label: const Text('Deny'),
                                          ),
                                        ),
                                        PopupMenuButton<String>(
                                          icon: const Icon(Icons.more_vert),
                                          tooltip: 'More',
                                          onSelected: (value) {
                                            switch (value) {
                                              case 'timeout':
                                                _timeout(held);
                                              case 'ban':
                                                _ban(held);
                                              case 'copy':
                                                Clipboard.setData(
                                                  ClipboardData(
                                                    text: held.messageId,
                                                  ),
                                                );
                                                widget.onNotice(
                                                  'Message ID copied.',
                                                );
                                            }
                                          },
                                          itemBuilder: (_) => const [
                                            PopupMenuItem(
                                              value: 'timeout',
                                              child: Text('Timeout...'),
                                            ),
                                            PopupMenuItem(
                                              value: 'ban',
                                              child: Text('Ban...'),
                                            ),
                                            PopupMenuItem(
                                              value: 'copy',
                                              child: Text('Copy message ID'),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip(this.category);

  final String category;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(category, style: theme.textTheme.labelSmall),
    );
  }
}
