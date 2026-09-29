import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/channel/moderation.dart';
import 'dialogs.dart';
import 'scope.dart';
import 'widgets.dart';

/// AutoMod held-message queue with per-category filters.
class QueueTab extends ModTabWidget {
  const QueueTab({
    super.key,
    required super.mod,
    required this.automodActive,
    required this.needsScope,
  });

  final bool automodActive;

  /// The AutoMod scope is missing from an otherwise moderating login.
  final bool needsScope;

  @override
  State<QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<QueueTab> with ModTabState<QueueTab> {
  String? _filter;

  @override
  void didChangeChannel() => setState(() => _filter = null);

  Future<void> _decide(HeldMessage held, bool allow) =>
      busy(held.messageId, () async {
        final ok = await mod.report(
          mod.actions.decideHeldMessage(
            mod.auth,
            mod.channel,
            messageId: held.messageId,
            allow: allow,
          ),
        );
        if (ok) mod.moderation?.resolveHeld(held.messageId);
      });

  Future<void> _timeout(HeldMessage held) async {
    final picked = await showTimeoutDialog(context, held.userLogin);
    if (picked == null) return;
    await mod.report(
      mod.actions.timeoutUser(
        mod.auth,
        mod.channel,
        login: held.userLogin,
        duration: picked.seconds,
        reason: picked.reason,
      ),
      done: 'Timed out ${held.userLogin}.',
    );
  }

  Future<void> _ban(HeldMessage held) async {
    final reason = await showModTextDialog(
      context,
      title: 'Ban ${held.userLogin}?',
      label: 'Reason (optional)',
      confirmLabel: 'Ban',
      allowEmpty: true,
    );
    if (reason == null) return;
    await mod.report(
      mod.actions.banUser(
        mod.auth,
        mod.channel,
        login: held.userLogin,
        reason: reason.isEmpty ? null : reason,
      ),
      done: 'Banned ${held.userLogin}.',
    );
  }

  void _copyId(HeldMessage held) {
    Clipboard.setData(ClipboardData(text: held.messageId));
    mod.notify('Message ID copied.');
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.automodActive) {
      return ModEmpty(
        icon: Icons.shield_outlined,
        title: widget.needsScope
            ? 'AutoMod queue needs the moderator:manage:automod scope. '
                  'Your login predates it.'
            : 'AutoMod queue is unavailable here.',
        action: widget.needsScope
            ? TextButton(
                onPressed: () => mod.notify(
                  'Open Settings > Account > Log in again to grant '
                  'moderator:manage:automod.',
                ),
                child: const Text('How to re-login'),
              )
            : null,
      );
    }
    const clear = ModEmpty(
      icon: Icons.shield_outlined,
      title: 'Queue is clear.',
      subtitle: 'Held messages will appear here for review.',
    );
    final moderation = mod.moderation;
    if (moderation == null) return clear;
    return ValueListenableBuilder<int>(
      valueListenable: moderation.heldVersion,
      builder: (context, _, _) {
        final all = moderation.held;
        if (all.isEmpty) return clear;
        final categories = {for (final h in all) h.category}.toList()..sort();
        final queue = [
          for (final h in all)
            if (_filter == null || h.category == _filter) h,
        ];
        return Column(
          children: [
            if (categories.length > 1)
              ModChoiceChips<String?>(
                options: [('All', null), for (final c in categories) (c, c)],
                selected: _filter,
                onSelected: (c) =>
                    setState(() => _filter = c == _filter ? null : c),
              ),
            Expanded(
              child: queue.isEmpty
                  ? ModEmpty(
                      icon: Icons.filter_list_off_outlined,
                      title: 'No matches for this filter.',
                      action: TextButton(
                        onPressed: () => setState(() => _filter = null),
                        child: const Text('Clear filter'),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                      itemCount: queue.length,
                      itemBuilder: (_, i) {
                        final held = queue[i];
                        return _HeldCard(
                          held: held,
                          busy: isBusy(held.messageId),
                          onShowUser: mod.showUser,
                          onDecide: (allow) => _decide(held, allow),
                          onTimeout: () => _timeout(held),
                          onBan: () => _ban(held),
                          onCopyId: () => _copyId(held),
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

class _HeldCard extends StatelessWidget {
  const _HeldCard({
    required this.held,
    required this.busy,
    required this.onShowUser,
    required this.onDecide,
    required this.onTimeout,
    required this.onBan,
    required this.onCopyId,
  });

  final HeldMessage held;
  final bool busy;
  final ValueChanged<String>? onShowUser;
  final ValueChanged<bool> onDecide;
  final VoidCallback onTimeout;
  final VoidCallback onBan;
  final VoidCallback onCopyId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      held.userLogin,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      held.category,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(held.text, maxLines: 4),
              ),
              onTap: onShowUser == null
                  ? null
                  : () => onShowUser!(held.userLogin),
            ),
            if (busy)
              const Padding(padding: EdgeInsets.all(8), child: ModSpinner())
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  spacing: 8,
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => onDecide(true),
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('Allow'),
                      ),
                    ),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => onDecide(false),
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('Deny'),
                      ),
                    ),
                    PopupMenuButton<VoidCallback>(
                      icon: const Icon(Icons.more_vert),
                      tooltip: 'More',
                      onSelected: (action) => action(),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: onTimeout,
                          child: const Text('Timeout...'),
                        ),
                        PopupMenuItem(
                          value: onBan,
                          child: const Text('Ban...'),
                        ),
                        PopupMenuItem(
                          value: onCopyId,
                          child: const Text('Copy message ID'),
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
  }
}
