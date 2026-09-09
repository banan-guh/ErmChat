import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/point_rewards.dart';
import '../services/chat_store.dart';
import '../services/mod_actions.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import 'app_snack.dart';
import 'tab_drag_focus.dart';

/// Snackbar copy for a failed mod action.
String modErrorText(ModResult result) => switch (result.failure) {
  ModFailure.unknownUser => 'No user matching that username.',
  ModFailure.selfTarget => 'You cannot target yourself.',
  ModFailure.broadcasterTarget => 'You cannot target the broadcaster.',
  ModFailure.notJoined => 'Channel not joined.',
  _ => result.reason ?? 'An unknown error has occurred.',
};

void showModError(BuildContext context, ModResult result) {
  if (result.ok) return;
  AppSnack.showError(context, modErrorText(result));
}

/// Timeout picker: preset chips plus custom seconds and an optional reason.
Future<({int seconds, String? reason})?> showTimeoutDialog(
  BuildContext context,
  String login,
) {
  const presets = <(String, int)>[
    ('10s', 10),
    ('1m', 60),
    ('10m', 600),
    ('1h', 3600),
    ('1d', 86400),
    ('1w', 604800),
  ];
  // Twitch caps timeouts at 2 weeks.
  const maxSeconds = 1209600;
  var seconds = 600;
  final customCtrl = TextEditingController();
  final reasonCtrl = TextEditingController();
  final pending = showDialog<({int seconds, String? reason})>(
    context: context,
    builder: (ctx) {
      var error = '';
      return StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Timeout $login'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final (label, value) in presets)
                    ChoiceChip(
                      label: Text(label),
                      selected: seconds == value && customCtrl.text.isEmpty,
                      onSelected: (_) {
                        customCtrl.clear();
                        setLocal(() {
                          seconds = value;
                          error = '';
                        });
                      },
                    ),
                ],
              ),
              TextField(
                controller: customCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Custom seconds (max 2 weeks)',
                ),
                onChanged: (_) => setLocal(() => error = ''),
              ),
              TextField(
                controller: reasonCtrl,
                decoration: const InputDecoration(
                  labelText: 'Reason (optional)',
                ),
              ),
              if (error.isNotEmpty)
                Text(
                  error,
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                var picked = seconds;
                final custom = customCtrl.text.trim();
                if (custom.isNotEmpty) {
                  final parsed = int.tryParse(custom);
                  if (parsed == null || parsed <= 0 || parsed > maxSeconds) {
                    setLocal(() => error = 'Enter 1-$maxSeconds seconds.');
                    return;
                  }
                  picked = parsed;
                }
                final reason = reasonCtrl.text.trim();
                Navigator.pop(ctx, (
                  seconds: picked,
                  reason: reason.isEmpty ? null : reason,
                ));
              },
              child: const Text('Timeout'),
            ),
          ],
        ),
      );
    },
  );
  pending.whenComplete(() {
    customCtrl.dispose();
    reasonCtrl.dispose();
  });
  return pending;
}

/// Simple destructive confirm. True means confirmed.
Future<bool> showModConfirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Single text field dialog (reasons, usernames). Null means cancelled.
Future<String?> showModTextDialog(
  BuildContext context, {
  required String title,
  String? label,
  required String confirmLabel,
  bool allowEmpty = false,
}) {
  final ctrl = TextEditingController();
  final pending = showDialog<String>(
    context: context,
    builder: (ctx) {
      var error = '';
      return StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: label,
                  errorText: error.isEmpty ? null : error,
                ),
                onSubmitted: (_) {
                  final value = ctrl.text.trim();
                  if (value.isEmpty && !allowEmpty) {
                    setLocal(() => error = 'Enter a value.');
                    return;
                  }
                  Navigator.pop(ctx, value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = ctrl.text.trim();
                if (value.isEmpty && !allowEmpty) {
                  setLocal(() => error = 'Enter a value.');
                  return;
                }
                Navigator.pop(ctx, value);
              },
              child: Text(confirmLabel),
            ),
          ],
        ),
      );
    },
  );
  pending.whenComplete(ctrl.dispose);
  return pending;
}

/// Mod View panel body: Queue / Activity / Modes / Channel / Users /
/// Requests / Terms / Setup tabs. State arrives as channel lookups (not
/// snapshots) so every [refresh] tick re-reads live values; the queue and
/// feed additionally listen to their own versions.
class ModViewPanel extends StatelessWidget {
  const ModViewPanel({
    super.key,
    required this.channel,
    required this.store,
    required this.modActions,
    required this.auth,
    required this.tabController,
    required this.refresh,
    required this.termsVersion,
    required this.dragFocus,
    required this.isModerationActive,
    required this.isAutomodActive,
    required this.getRoomModes,
    required this.onNotice,
    this.onShowUser,
    this.isBroadcaster = false,
  });

  final String channel;
  final ChatStore store;
  final ModActions modActions;
  final TwitchAuth auth;
  final TabController tabController;
  final Listenable refresh;

  /// Bumped when a blocked term is added via the borrowed composer input.
  final ValueListenable<int> termsVersion;

  /// Half-drag focus tracker; the composer morph follows 50% crossings.
  final TabDragFocus dragFocus;
  final bool Function(String channel) isModerationActive;
  final bool Function(String channel) isAutomodActive;
  final Map<String, String> Function(String channel) getRoomModes;

  /// Notice sink for failures; the shell routes these to the inline bar.
  final ValueChanged<String> onNotice;

  /// Opens a user card (queue rows, feed-adjacent user lists).
  final ValueChanged<String>? onShowUser;

  /// Whether the session user owns the channel (Channel and Users gates).
  final bool isBroadcaster;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: refresh,
      builder: (_, _) {
        final moderationActive = isModerationActive(channel);
        final automodActive = isAutomodActive(channel);
        if (!moderationActive && !automodActive) {
          // Scope can flip while a drag is in flight, unmounting the
          // TabBarView below without a ScrollEnd: drop the stranded focus
          // post-frame so the composer gate reads honest state.
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => dragFocus.reset(),
          );
          return const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Mod tools are available where you moderate.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return NotificationListener<ScrollNotification>(
          onNotification: dragFocus.onNotification,
          child: TabBarView(
            controller: tabController,
            children: [
              _QueueTab(
                channel: channel,
                store: store,
                modActions: modActions,
                auth: auth,
                automodActive: automodActive,
                scopeReady: moderationActive,
                scopeStale: auth.scopeStale,
                onNotice: onNotice,
                onShowUser: onShowUser,
              ),
              _ActivityTab(channel: channel, store: store),
              _ModesTab(
                channel: channel,
                modActions: modActions,
                auth: auth,
                roomModes: getRoomModes(channel),
                moderationActive: moderationActive,
                onNotice: onNotice,
              ),
              _ChannelTab(
                channel: channel,
                store: store,
                modActions: modActions,
                auth: auth,
                onNotice: onNotice,
                isBroadcaster: isBroadcaster,
                isModerationActive: moderationActive,
              ),
              _UsersTab(
                channel: channel,
                store: store,
                modActions: modActions,
                auth: auth,
                onNotice: onNotice,
                onShowUser: onShowUser,
                isBroadcaster: isBroadcaster,
              ),
              _RequestsTab(
                channel: channel,
                store: store,
                modActions: modActions,
                auth: auth,
                onNotice: onNotice,
              ),
              _TermsTab(
                channel: channel,
                store: store,
                modActions: modActions,
                auth: auth,
                termsVersion: termsVersion,
                onNotice: onNotice,
              ),
              _SetupTab(
                channel: channel,
                store: store,
                modActions: modActions,
                auth: auth,
                onNotice: onNotice,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _QueueTab extends StatefulWidget {
  const _QueueTab({
    required this.channel,
    required this.store,
    required this.modActions,
    required this.auth,
    required this.automodActive,
    required this.scopeReady,
    required this.scopeStale,
    required this.onNotice,
    required this.onShowUser,
  });

  final String channel;
  final ChatStore store;
  final ModActions modActions;
  final TwitchAuth auth;
  final bool automodActive;
  final bool scopeReady;
  final bool scopeStale;
  final ValueChanged<String> onNotice;
  final ValueChanged<String>? onShowUser;

  @override
  State<_QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<_QueueTab> {
  final _pending = <String>{};
  String? _filter;

  @override
  void didUpdateWidget(covariant _QueueTab oldWidget) {
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
      widget.store.resolveHeldMessage(widget.channel, held.messageId);
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
    return ValueListenableBuilder<int>(
      valueListenable: widget.store.heldVersion,
      builder: (_, _, _) {
        final all = widget.store.heldMessages[widget.channel] ?? const [];
        if (all.isEmpty) {
          return const _ModEmpty(
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

String _feedTime(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

String _feedDateTime(DateTime at) =>
    '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')} ${_feedTime(at)}';

String _relativeAgo(DateTime at) {
  final diff = DateTime.now().difference(at);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  return '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
}

String _relativeShortDate(String iso) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  return _relativeAgo(dt.toLocal());
}

String _capitalizeToken(String token) {
  final words = token.replaceAll('_', ' ').split(' ');
  return [
    for (final w in words)
      if (w.isNotEmpty) '${w[0].toUpperCase()}${w.substring(1)}',
  ].join(' ');
}

IconData _activityIcon(String action) {
  switch (action) {
    case 'ban':
    case 'timeout':
      return Icons.gavel;
    case 'unban':
    case 'untimeout':
      return Icons.undo;
    case 'delete':
    case 'clear':
      return Icons.delete_outline;
    case 'warn':
    case 'warn_ack':
      return Icons.warning_amber;
    case 'approve_unban_request':
      return Icons.check_circle_outline;
    case 'deny_unban_request':
      return Icons.cancel_outlined;
    case 'unban_resolved':
      return Icons.mark_email_read_outlined;
    case 'mod':
    case 'vip':
      return Icons.person_add;
    case 'unmod':
    case 'unvip':
      return Icons.person_remove;
    case 'shield_on':
    case 'shield_off':
    case 'suspicious_flag':
      return Icons.shield;
    case 'automod_settings':
      return Icons.auto_fix_high;
    case 'shoutout':
      return Icons.campaign;
    case 'raid':
    case 'unraid':
      return Icons.flight_takeoff;
    case 'add_blocked_term':
    case 'remove_blocked_term':
    case 'add_permitted_term':
    case 'remove_permitted_term':
      return Icons.block;
    case 'slow':
    case 'slowoff':
    case 'followers':
    case 'followersoff':
    case 'emoteonly':
    case 'emoteonlyoff':
    case 'subscribers':
    case 'subscribersoff':
    case 'uniquechat':
    case 'uniquechatoff':
      return Icons.tune;
    default:
      return Icons.info_outline;
  }
}

class _ActivityTab extends StatelessWidget {
  const _ActivityTab({required this.channel, required this.store});

  final String channel;
  final ChatStore store;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: store.modFeedVersion,
      builder: (_, _, _) {
        final feed = store.modActivity[channel] ?? const [];
        if (feed.isEmpty) {
          return const _ModEmpty(
            icon: Icons.auto_awesome_outlined,
            title: 'No moderation activity yet.',
            subtitle: 'Bans, timeouts and mod actions will show here.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
          itemCount: feed.length,
          itemBuilder: (context, i) {
            final entry = feed[i];
            final scheme = Theme.of(context).colorScheme;
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _activityIcon(entry.action),
                  size: 22,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              title: Text(formatModActivity(entry)),
              subtitle: Text('${entry.moderator} · ${_relativeAgo(entry.at)}'),
            );
          },
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 12,
          letterSpacing: 0.8,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Centered empty state: large icon plus bold title and grey subtitle.
class _ModEmpty extends StatelessWidget {
  const _ModEmpty({required this.icon, required this.title, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Centered error state with retry.
class _ModError extends StatelessWidget {
  const _ModError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _UsersTab extends StatefulWidget {
  const _UsersTab({
    required this.channel,
    required this.store,
    required this.modActions,
    required this.auth,
    required this.onNotice,
    required this.onShowUser,
    required this.isBroadcaster,
  });

  final String channel;
  final ChatStore store;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;
  final ValueChanged<String>? onShowUser;

  /// Moderator and VIP rosters are broadcaster-only Helix (their GETs
  /// require broadcaster_id to match the token), so mods never call them.
  final bool isBroadcaster;

  @override
  State<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<_UsersTab> {
  final _unbanPending = <String>{};
  final _flagPending = <String>{};

  Future<void> _dismissWarnings(String login) async {
    widget.store.dismissWarningsFor(widget.channel, login);
    setState(() {});
    widget.onNotice('Dismissed warnings for $login.');
  }

  Future<void> _unban(String login) async {
    final key = login.toLowerCase();
    if (!_unbanPending.add(key)) return;
    setState(() {});
    bool unbannedOk = false;
    try {
      final result = await widget.modActions.unbanUser(
        widget.auth,
        widget.channel,
        login: login,
      );
      unbannedOk = result.ok;
      if (!mounted) return;
      if (result.ok) {
        widget.onNotice('Unbanned $login.');
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      _unbanPending.remove(key);
      if (mounted) setState(() {});
    }
    if (unbannedOk) widget.store.removeBan(widget.channel, login);
  }

  Future<void> _clearFlag(String login) async {
    final key = login.toLowerCase();
    if (!_flagPending.add(key)) return;
    setState(() {});
    bool clearedOk = false;
    try {
      final result = await widget.modActions.clearSuspiciousStatus(
        widget.auth,
        widget.channel,
        login: login,
      );
      clearedOk = result.ok;
      if (!mounted) return;
      if (result.ok) {
        widget.onNotice('Cleared flag for $login.');
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      _flagPending.remove(key);
      if (mounted) setState(() {});
    }
    if (clearedOk) widget.store.removeSuspicious(widget.channel, login);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.store.modActivityVersion,
      builder: (_, _, _) {
        final bans =
            widget.store.channelBans[widget.channel]?.values.toList() ??
            const [];
        final warnings =
            widget.store.channelWarnings[widget.channel] ?? const [];
        final flagged =
            widget.store.suspiciousUsers[widget.channel]?.values.toList() ??
            const [];
        final counts = <String, int>{};
        final latestByUser = widget.store.warnedLatest(widget.channel);
        for (final w in warnings) {
          final lower = w.target.toLowerCase();
          counts[lower] = (counts[lower] ?? 0) + 1;
        }
        final warned = latestByUser.values.toList()
          ..sort((a, b) => b.at.compareTo(a.at));
        widget.store.pruneExpiredBans(widget.channel);
        return ListView(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
          children: [
            _SectionHeader('Banned (${bans.length})'),
            if (bans.isEmpty) const ListTile(title: Text('No bans yet.')),
            for (final ban in bans)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                title: Text(ban.login),
                subtitle: Text(_banSubtitle(ban)),
                onTap:
                    widget.onShowUser == null ||
                        _unbanPending.contains(ban.login.toLowerCase())
                    ? null
                    : () => widget.onShowUser!.call(ban.login),
                trailing: _unbanPending.contains(ban.login.toLowerCase())
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : OutlinedButton(
                        onPressed: () => _unban(ban.login),
                        child: const Text('Unban'),
                      ),
              ),
            _SectionHeader('Warned (${warned.length})'),
            if (warned.isEmpty) const ListTile(title: Text('No warnings yet.')),
            for (final w in warned)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                title: Text(w.target),
                subtitle: Text(
                  _warnSubtitle(counts[w.target.toLowerCase()] ?? 1, w),
                ),
                onTap: widget.onShowUser == null
                    ? null
                    : () => widget.onShowUser!.call(w.target),
                trailing: TextButton(
                  onPressed: () => _dismissWarnings(w.target),
                  child: const Text('Dismiss'),
                ),
              ),
            _SectionHeader('Flagged (${flagged.length})'),
            if (flagged.isEmpty)
              const ListTile(title: Text('No flagged users.')),
            for (final info in flagged)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                title: Text(info.login),
                subtitle: Text(_suspiciousSubtitle(info)),
                onTap:
                    widget.onShowUser == null ||
                        _flagPending.contains(info.login.toLowerCase())
                    ? null
                    : () => widget.onShowUser!.call(info.login),
                trailing: _flagPending.contains(info.login.toLowerCase())
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : OutlinedButton(
                        onPressed: () => _clearFlag(info.login),
                        child: const Text('Clear'),
                      ),
              ),
            if (widget.isBroadcaster)
              _RosterSections(
                channel: widget.channel,
                modActions: widget.modActions,
                auth: widget.auth,
                onNotice: widget.onNotice,
              ),
          ],
        );
      },
    );
  }

  String _banSubtitle(BanEntry ban) {
    final head = ban.expiresAt == null
        ? 'Banned'
        : 'Timeout until ${_feedDateTime(ban.expiresAt!)}';
    final parts = [head];
    if (ban.reason != null && ban.reason!.isNotEmpty) {
      parts.add('"${ban.reason}"');
    }
    if (ban.moderator.isNotEmpty) parts.add('by ${ban.moderator}');
    return parts.join(' · ');
  }

  String _warnSubtitle(int count, WarnEntry latest) {
    final head = count == 1 ? '1 warning' : '$count warnings';
    if (latest.reason != null && latest.reason!.isNotEmpty) {
      return '$head · "${latest.reason}"';
    }
    return head;
  }

  String _suspiciousSubtitle(SuspiciousInfo info) {
    final parts = <String>[_suspiciousTitle(info.status)];
    final evasion = info.banEvasion;
    if (evasion != null && evasion.isNotEmpty) {
      parts.add('$evasion ban evasion likelihood');
    }
    if (info.sharedBanChannelIds.isNotEmpty) {
      final n = info.sharedBanChannelIds.length;
      parts.add('shared bans in $n channel${n == 1 ? '' : 's'}');
    }
    if (info.types.isNotEmpty) {
      parts.add(info.types.map(_capitalizeToken).join(', '));
    }
    return parts.join(' · ');
  }

  String _suspiciousTitle(String status) {
    final lower = status.toLowerCase();
    if (lower.contains('restrict')) return 'Restricted';
    if (lower.contains('monitor')) return 'Monitored';
    if (lower.isEmpty) return 'Flagged';
    return lower[0].toUpperCase() + lower.substring(1);
  }
}

class _RequestsTab extends StatefulWidget {
  const _RequestsTab({
    required this.channel,
    required this.store,
    required this.modActions,
    required this.auth,
    required this.onNotice,
  });

  final String channel;
  final ChatStore store;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

  @override
  State<_RequestsTab> createState() => _RequestsTabState();
}

class _RequestsTabState extends State<_RequestsTab> {
  static const _statuses = ['pending', 'approved', 'denied'];

  String _status = 'pending';
  List<UnbanRequest>? _requests;
  String? _error;
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    widget.store.modInboxVersion.addListener(_onInboxChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant _RequestsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      setState(() {
        _status = 'pending';
        _requests = null;
        _error = null;
      });
      _load();
    }
  }

  @override
  void dispose() {
    widget.store.modInboxVersion.removeListener(_onInboxChanged);
    super.dispose();
  }

  void _onInboxChanged() => _load();

  void _setStatus(String status) {
    if (_status == status) return;
    setState(() {
      _status = status;
      _requests = null;
      _error = null;
    });
    _load();
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    final background = _requests != null;
    List<UnbanRequest> requests = const [];
    String? error;
    try {
      requests = await widget.modActions.getUnbanRequests(
        widget.auth,
        widget.channel,
        status: _status,
      );
      if (widget.modActions.twitchApi.lastErrorStatus != null) {
        error = widget.modActions.failureReason();
      }
    } catch (_) {
      error = 'Could not load unban requests.';
    }
    if (!mounted || gen != _loadGen) return;
    if (error != null && background) {
      widget.onNotice(error);
      return;
    }
    setState(() {
      _error = error;
      if (error == null) _requests = requests;
    });
  }

  Future<void> _showDetail(UnbanRequest request) async {
    final resolutionCtrl = TextEditingController();
    var resolutionDraft = '';
    final pending = showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Request from ${request.userLogin}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('"${request.text}"'),
              const SizedBox(height: 8),
              Text(
                'Status: ${request.status} · ${_relativeShortDate(request.createdAt)}',
              ),
              if (request.resolutionText != null &&
                  request.resolutionText!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Resolution: "${request.resolutionText}"'),
                ),
              if (request.status == 'pending') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: resolutionCtrl,
                  maxLength: 500,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Resolution message (optional)',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => resolutionDraft = v,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          if (request.status == 'pending') ...[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Deny'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Approve'),
            ),
          ],
        ],
      ),
    );
    pending.whenComplete(resolutionCtrl.dispose);
    final decision = await pending;
    if (decision == null || !mounted) return;
    final message = resolutionDraft.trim();
    final trimmed = message.length > 500 ? message.substring(0, 500) : message;
    final result = await widget.modActions.resolveUnbanRequest(
      widget.auth,
      widget.channel,
      requestId: request.id,
      approved: decision,
      resolutionText: trimmed.isEmpty ? null : trimmed,
    );
    if (!mounted) return;
    if (result.ok) {
      widget.onNotice(decision ? 'Request approved.' : 'Request denied.');
      _load();
    } else {
      widget.onNotice(modErrorText(result));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              for (final s in _statuses)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: Text(s[0].toUpperCase() + s.substring(1)),
                    ),
                    selected: _status == s,
                    onSelected: (_) => _setStatus(s),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_error != null && _requests == null) {
      return _ModError(message: _error!, onRetry: _load);
    }
    final requests = _requests;
    if (requests == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (requests.isEmpty) {
      return _ModEmpty(
        icon: Icons.mark_email_read_outlined,
        title: 'No $_status requests.',
        subtitle: _status == 'pending'
            ? 'New unban requests will appear here.'
            : null,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
      itemCount: requests.length,
      itemBuilder: (_, i) {
        final request = requests[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            title: Text(request.userLogin),
            subtitle: Text(
              '"${request.text}" · ${_relativeShortDate(request.createdAt)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _showDetail(request),
          ),
        );
      },
    );
  }
}

class _TermsTab extends StatefulWidget {
  const _TermsTab({
    required this.channel,
    required this.store,
    required this.modActions,
    required this.auth,
    required this.termsVersion,
    required this.onNotice,
  });

  final String channel;
  final ChatStore store;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueListenable<int> termsVersion;
  final ValueChanged<String> onNotice;

  @override
  State<_TermsTab> createState() => _TermsTabState();
}

class _TermsTabState extends State<_TermsTab> {
  List<BlockedTerm>? _terms;
  String? _error;
  int _loadGen = 0;
  final _removing = <String>{};

  @override
  void initState() {
    super.initState();
    widget.store.modInboxVersion.addListener(_onInboxChanged);
    widget.termsVersion.addListener(_onInboxChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant _TermsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      setState(() {
        _terms = null;
        _error = null;
      });
      _load();
    }
  }

  @override
  void dispose() {
    widget.store.modInboxVersion.removeListener(_onInboxChanged);
    widget.termsVersion.removeListener(_onInboxChanged);
    super.dispose();
  }

  void _onInboxChanged() => _load();

  Future<void> _load() async {
    final gen = ++_loadGen;
    final background = _terms != null;
    List<BlockedTerm> terms = const [];
    String? error;
    try {
      terms = await widget.modActions.getBlockedTerms(
        widget.auth,
        widget.channel,
      );
      if (widget.modActions.twitchApi.lastErrorStatus != null) {
        error = widget.modActions.failureReason();
      }
    } catch (_) {
      error = 'Could not load blocked terms.';
    }
    if (!mounted || gen != _loadGen) return;
    if (error != null && background) {
      widget.onNotice(error);
      return;
    }
    setState(() {
      _error = error;
      if (error == null) _terms = terms;
    });
  }

  Future<void> _remove(BlockedTerm term) async {
    if (!_removing.add(term.id)) return;
    setState(() {});
    final result = await widget.modActions.removeBlockedTerm(
      widget.auth,
      widget.channel,
      term.id,
    );
    if (!mounted) return;
    _removing.remove(term.id);
    if (result.ok) {
      _load();
    } else {
      setState(() {});
      widget.onNotice(modErrorText(result));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'Only moderators can see this list. Public terms only; '
            'private terms live in the dashboard. '
            'Type in the chat box below to add one.',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_error != null && _terms == null) {
      return _ModError(message: _error!, onRetry: _load);
    }
    final terms = _terms;
    if (terms == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (terms.isEmpty) {
      return const _ModEmpty(
        icon: Icons.block_outlined,
        title: 'No blocked terms yet.',
        subtitle: 'A * wildcard is allowed at the start or the end.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
      itemCount: terms.length,
      itemBuilder: (_, i) {
        final term = terms[i];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          title: Text(term.text),
          subtitle: Text('Added ${_relativeShortDate(term.createdAt)}'),
          trailing: _removing.contains(term.id)
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove',
                  onPressed: () => _remove(term),
                ),
        );
      },
    );
  }
}

class _SetupTab extends StatefulWidget {
  const _SetupTab({
    required this.channel,
    required this.store,
    required this.modActions,
    required this.auth,
    required this.onNotice,
  });

  final String channel;
  final ChatStore store;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

  @override
  State<_SetupTab> createState() => _SetupTabState();
}

class _SetupTabState extends State<_SetupTab> {
  static const _cats = [
    ('aggression', 'Aggression'),
    ('bullying', 'Bullying'),
    ('disability', 'Disability'),
    ('misogyny', 'Misogyny'),
    ('race_ethnicity_or_religion', 'Race, ethnicity, religion'),
    ('sex_based_terms', 'Sex-based terms'),
    ('sexuality_sex_or_gender', 'Sexuality, sex, gender'),
    ('swearing', 'Swearing'),
  ];
  static const _presets = [
    ('Off', 0),
    ('Low', 1),
    ('Medium', 2),
    ('High', 3),
    ('Max', 4),
  ];

  AutoModSettings? _settings;
  Map<String, int>? _levels;
  int? _overall;
  String? _error;
  int _loadGen = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    widget.store.modSettingsVersion.addListener(_onInboxChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant _SetupTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) _load(force: true);
  }

  @override
  void dispose() {
    widget.store.modSettingsVersion.removeListener(_onInboxChanged);
    super.dispose();
  }

  void _onInboxChanged() => _load();

  Future<void> _load({bool force = false}) async {
    final gen = ++_loadGen;
    final background = _settings != null;
    AutoModSettings? settings;
    String? error;
    try {
      settings = await widget.modActions.getAutoModSettings(
        widget.auth,
        widget.channel,
      );
      if (settings == null) {
        error = widget.modActions.twitchApi.lastErrorStatus != null
            ? widget.modActions.failureReason()
            : 'Could not load AutoMod settings.';
      }
    } catch (_) {
      error = 'Could not load AutoMod settings.';
    }
    if (!mounted || gen != _loadGen) return;
    if (error != null && background) {
      widget.onNotice(error);
      return;
    }
    if (!force && background && _dirty && settings != null) return;
    setState(() {
      _error = error;
      if (settings != null) {
        _settings = settings;
        _levels = Map.of(settings.levels);
        _overall = settings.overallLevel;
      }
    });
  }

  bool get _dirty {
    final saved = _settings;
    final levels = _levels;
    if (saved == null || levels == null) return false;
    // Levels-only delta: dragging a slider and back is not a change,
    // even though _overall flips to null (custom) on any slider move.
    if (levels.length != saved.levels.length) return true;
    for (final entry in levels.entries) {
      if (saved.levels[entry.key] != entry.value) return true;
    }
    return false;
  }

  /// Preset to display: all-equal levels read as that preset, else custom.
  int? get _displayOverall {
    final levels = _levels;
    if (levels == null || levels.isEmpty) return _overall;
    final first = levels.values.first;
    if (levels.values.every((v) => v == first)) return first;
    return null;
  }

  void _reset() {
    final saved = _settings;
    if (saved == null) return;
    setState(() {
      _levels = Map.of(saved.levels);
      _overall = saved.overallLevel;
    });
  }

  Future<void> _save() async {
    final levels = _levels;
    if (levels == null || _saving || !_dirty) return;
    setState(() => _saving = true);
    try {
      final effective = _displayOverall;
      final result = await widget.modActions.updateAutoModSettings(
        widget.auth,
        widget.channel,
        effective != null ? {'overall_level': effective} : levels,
      );
      if (!mounted) return;
      if (result.ok) {
        widget.onNotice('AutoMod settings saved.');
        await _load(force: true);
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && _settings == null) {
      return _ModError(message: _error!, onRetry: _load);
    }
    final levels = _levels;
    if (levels == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    final displayOverall = _displayOverall;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text(
          'Presets set every category. Changing one switches to custom.',
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (label, value) in _presets)
              ChoiceChip(
                label: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Text(label),
                ),
                selected: displayOverall == value,
                onSelected: _saving
                    ? null
                    : (_) => setState(() {
                        _overall = value;
                        for (final key in levels.keys) {
                          levels[key] = value;
                        }
                      }),
              ),
          ],
        ),
        if (displayOverall == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Custom levels.'),
          ),
        const SizedBox(height: 8),
        for (final (key, label) in _cats)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(
                children: [
                  Expanded(child: Text(label)),
                  DropdownButton<int>(
                    value: levels[key] ?? 0,
                    items: [
                      for (final (itemLabel, value) in _presets)
                        DropdownMenuItem(value: value, child: Text(itemLabel)),
                    ],
                    onChanged: _saving
                        ? null
                        : (v) {
                            if (v == null) return;
                            setState(() {
                              levels[key] = v;
                              _overall = null;
                            });
                          },
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _dirty && !_saving ? _reset : null,
                child: const Text('Reset'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: _dirty && !_saving ? _save : null,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save changes'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ChannelTab extends StatelessWidget {
  const _ChannelTab({
    required this.channel,
    required this.store,
    required this.modActions,
    required this.auth,
    required this.onNotice,
    required this.isBroadcaster,
    required this.isModerationActive,
  });

  final String channel;
  final ChatStore store;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;
  final bool isBroadcaster;
  final bool isModerationActive;

  @override
  Widget build(BuildContext context) {
    if (!isBroadcaster && !isModerationActive) {
      return const _ModEmpty(
        icon: Icons.shield_outlined,
        title: 'Only the broadcaster can use these tools here.',
        subtitle: 'Log in as the broadcaster to manage rosters and stream.',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
      children: [
        if (isBroadcaster) ...[
          _BannedManager(
            channel: channel,
            modActions: modActions,
            auth: auth,
            onNotice: onNotice,
          ),
          _RosterSections(
            channel: channel,
            modActions: modActions,
            auth: auth,
            onNotice: onNotice,
          ),
        ],
        if (isModerationActive || isBroadcaster) ...[
          const _SectionHeader('Stream'),
          _StreamActions(
            channel: channel,
            modActions: modActions,
            auth: auth,
            onNotice: onNotice,
            isBroadcaster: isBroadcaster,
          ),
        ],
        if (isBroadcaster) ...[
          const _SectionHeader('Polls'),
          _PollsSection(
            channel: channel,
            modActions: modActions,
            auth: auth,
            onNotice: onNotice,
          ),
          const _SectionHeader('Predictions'),
          _PredictionsSection(
            channel: channel,
            modActions: modActions,
            auth: auth,
            onNotice: onNotice,
          ),
          const _SectionHeader('Points'),
          _PointsSection(
            channel: channel,
            store: store,
            modActions: modActions,
            auth: auth,
            onNotice: onNotice,
          ),
        ],
      ],
    );
  }
}

class _BannedManager extends StatefulWidget {
  const _BannedManager({
    required this.channel,
    required this.modActions,
    required this.auth,
    required this.onNotice,
  });

  final String channel;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

  @override
  State<_BannedManager> createState() => _BannedManagerState();
}

class _BannedManagerState extends State<_BannedManager> {
  List<BannedUser>? _banned;
  String? _error;
  int _loadGen = 0;
  final _pending = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _BannedManager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      setState(() {
        _banned = null;
        _error = null;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    final background = _banned != null;
    List<BannedUser> banned = const [];
    String? error;
    try {
      banned = await widget.modActions.getBannedUsers(
        widget.auth,
        widget.channel,
      );
      if (widget.modActions.twitchApi.lastErrorStatus != null) {
        error = widget.modActions.failureReason();
      }
    } catch (_) {
      error = 'Could not load the banned list.';
    }
    if (!mounted || gen != _loadGen) return;
    if (error != null && background) {
      widget.onNotice(error);
      return;
    }
    setState(() {
      _error = error;
      if (error == null) _banned = banned;
    });
  }

  Future<void> _unban(String login) async {
    final key = login.toLowerCase();
    if (!_pending.add(key)) return;
    setState(() {});
    try {
      final result = await widget.modActions.unbanUser(
        widget.auth,
        widget.channel,
        login: login,
      );
      if (!mounted) return;
      if (result.ok) {
        setState(() {
          _banned = [
            for (final ban in _banned ?? const <BannedUser>[])
              if (ban.userLogin.toLowerCase() != key) ban,
          ];
        });
        widget.onNotice('Unbanned $login.');
        _load();
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      _pending.remove(key);
      if (mounted) setState(() {});
    }
  }

  String _subtitle(BannedUser ban) {
    var head = 'Banned';
    final expires = ban.expiresAt;
    if (expires != null) {
      final dt = DateTime.tryParse(expires)?.toLocal();
      head = dt == null
          ? 'Timed out (expiry unknown)'
          : 'Timeout until ${_feedDateTime(dt)}';
    }
    final parts = [head];
    if (ban.reason != null && ban.reason!.isNotEmpty) {
      parts.add('"${ban.reason}"');
    }
    if (ban.moderatorName != null && ban.moderatorName!.isNotEmpty) {
      parts.add('by ${ban.moderatorName}');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final banned = _banned;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader('Banned (${banned?.length ?? 0})'),
        if (_error != null && banned == null)
          _ModError(message: _error!, onRetry: _load)
        else if (banned == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [CircularProgressIndicator()],
            ),
          )
        else if (banned.isEmpty)
          const ListTile(title: Text('No bans yet.'))
        else
          for (final ban in banned)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              title: Text(ban.userLogin),
              subtitle: Text(_subtitle(ban)),
              trailing: _pending.contains(ban.userLogin.toLowerCase())
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : OutlinedButton(
                      onPressed: () => _unban(ban.userLogin),
                      child: const Text('Unban'),
                    ),
            ),
      ],
    );
  }
}

class _StreamActions extends StatefulWidget {
  const _StreamActions({
    required this.channel,
    required this.modActions,
    required this.auth,
    required this.onNotice,
    required this.isBroadcaster,
  });

  final String channel;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

  /// Start/cancel raid and commercials are broadcaster-only Helix
  /// (their broadcaster id must match the token), so mods get a
  /// greyed tile that explains instead of a failing call.
  final bool isBroadcaster;

  @override
  State<_StreamActions> createState() => _StreamActionsState();
}

class _StreamActionsState extends State<_StreamActions> {
  String? _busy;

  ModActions get modActions => widget.modActions;
  TwitchAuth get auth => widget.auth;
  String get channel => widget.channel;
  ValueChanged<String> get onNotice => widget.onNotice;

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _raid(BuildContext context) async {
    final login = await showModTextDialog(
      context,
      title: 'Raid a channel?',
      label: 'Username',
      confirmLabel: 'Raid',
    );
    if (login == null || !context.mounted) return;
    if (login.isEmpty) {
      onNotice('Enter a username.');
      return;
    }
    final result = await modActions.startRaid(auth, channel, login: login);
    if (!context.mounted) return;
    onNotice(result.ok ? 'Raid started.' : modErrorText(result));
  }

  Future<void> _commercial(BuildContext context) async {
    const lengths = [30, 60, 90, 120, 150, 180];
    final length = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Commercial length'),
        children: [
          for (final seconds in lengths)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, seconds),
              child: Text('${seconds}s'),
            ),
        ],
      ),
    );
    if (length == null || !context.mounted) return;
    final result = await modActions.startCommercial(
      auth,
      channel,
      length: length,
    );
    if (!context.mounted) return;
    onNotice(result.ok ? 'Commercial running.' : modErrorText(result));
  }

  Future<void> _marker(BuildContext context) async {
    final description = await showModTextDialog(
      context,
      title: 'Add stream marker',
      label: 'Description (optional)',
      confirmLabel: 'Add',
      allowEmpty: true,
    );
    if (description == null || !context.mounted) return;
    final result = await modActions.createMarker(
      auth,
      channel,
      description: description.isEmpty ? null : description,
    );
    if (!context.mounted) return;
    onNotice(result.ok ? 'Marker added.' : modErrorText(result));
  }

  Future<void> _announce(BuildContext context) async {
    final message = await showModTextDialog(
      context,
      title: 'Send announcement',
      label: 'Message',
      confirmLabel: 'Send',
    );
    if (message == null || !context.mounted) return;
    if (_busy != null) return;
    setState(() => _busy = 'announce');
    try {
      final result = await modActions.sendAnnouncement(
        auth,
        channel,
        message: message,
      );
      if (!context.mounted) return;
      onNotice(result.ok ? 'Announcement sent.' : modErrorText(result));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _clear(BuildContext context) async {
    if (_busy != null) return;
    if (!await _confirm('Clear chat?', 'This clears all chat messages.')) {
      return;
    }
    if (!context.mounted) return;
    setState(() => _busy = 'clear');
    try {
      final result = await modActions.clearChat(auth, channel);
      if (!context.mounted) return;
      onNotice(result.ok ? 'Chat cleared.' : modErrorText(result));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _shoutout(BuildContext context) async {
    final login = await showModTextDialog(
      context,
      title: 'Shoutout a channel?',
      label: 'Username',
      confirmLabel: 'Shoutout',
    );
    if (login == null || !context.mounted) return;
    if (_busy != null) return;
    setState(() => _busy = 'shoutout');
    try {
      final result = await modActions.sendShoutout(auth, channel, login: login);
      if (!context.mounted) return;
      onNotice(result.ok ? 'Shoutout sent.' : modErrorText(result));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _unraid(BuildContext context) async {
    if (_busy != null) return;
    if (!await _confirm('Cancel raid?', 'This cancels the pending raid.')) {
      return;
    }
    if (!context.mounted) return;
    setState(() => _busy = 'unraid');
    try {
      final result = await modActions.cancelRaid(auth, channel);
      if (!context.mounted) return;
      onNotice(result.ok ? 'Raid cancelled.' : modErrorText(result));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _busy != null;
    VoidCallback? gated(bool broadcasterOnly, VoidCallback action) {
      if (busy) return null;
      if (broadcasterOnly && !widget.isBroadcaster) {
        return () => onNotice('Only broadcasters can use this.');
      }
      return action;
    }

    final actions = [
      (
        'Start raid',
        Icons.flight_takeoff_outlined,
        gated(true, () => _raid(context)),
        false,
        true,
      ),
      (
        'Cancel raid',
        Icons.flight_land_outlined,
        gated(true, () => _unraid(context)),
        _busy == 'unraid',
        true,
      ),
      (
        'Commercial',
        Icons.monetization_on_outlined,
        gated(true, () => _commercial(context)),
        false,
        true,
      ),
      (
        'Add marker',
        Icons.bookmark_add_outlined,
        busy ? null : () => _marker(context),
        false,
        false,
      ),
      (
        'Announce',
        Icons.campaign_outlined,
        busy ? null : () => _announce(context),
        _busy == 'announce',
        false,
      ),
      (
        'Clear chat',
        Icons.delete_sweep_outlined,
        busy ? null : () => _clear(context),
        _busy == 'clear',
        false,
      ),
      (
        'Shoutout',
        Icons.record_voice_over_outlined,
        busy ? null : () => _shoutout(context),
        _busy == 'shoutout',
        false,
      ),
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.92,
      ),
      itemCount: actions.length,
      itemBuilder: (_, i) {
        final a = actions[i];
        final scheme = Theme.of(context).colorScheme;
        final greyed = a.$3 == null || (a.$5 && !widget.isBroadcaster);
        return Opacity(
          opacity: greyed ? 0.55 : 1.0,
          child: Material(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: a.$3,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (a.$4)
                      const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(a.$2, size: 28, color: scheme.onSurfaceVariant),
                    const SizedBox(height: 8),
                    Text(
                      a.$1,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PollsSection extends StatefulWidget {
  const _PollsSection({
    required this.channel,
    required this.modActions,
    required this.auth,
    required this.onNotice,
  });

  final String channel;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

  @override
  State<_PollsSection> createState() => _PollsSectionState();
}

class _PollsSectionState extends State<_PollsSection> {
  List<Map<String, dynamic>>? _polls;
  String? _error;
  int _loadGen = 0;
  String? _busyKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _PollsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      setState(() {
        _polls = null;
        _error = null;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    final background = _polls != null;
    List<Map<String, dynamic>> polls = const [];
    String? error;
    try {
      polls = await widget.modActions.getPolls(widget.auth, widget.channel);
      if (widget.modActions.twitchApi.lastErrorStatus != null) {
        error = widget.modActions.failureReason();
      }
    } catch (_) {
      error = 'Could not load polls.';
    }
    if (!mounted || gen != _loadGen) return;
    if (error != null && background) {
      widget.onNotice(error);
      return;
    }
    setState(() {
      _error = error;
      if (error == null) _polls = polls;
    });
  }

  Future<void> _end(String pollId, bool archive) async {
    final key = archive ? 'cancel' : 'end';
    if (_busyKey != null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(archive ? 'Cancel poll?' : 'End poll now?'),
        content: Text(
          archive
              ? 'This archives the poll without showing results.'
              : 'This ends the poll and shows the results (TERMINATED).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(archive ? 'Cancel poll' : 'End poll'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    if (pollId.isEmpty) {
      widget.onNotice('Poll id is missing; reload and try again.');
      return;
    }
    setState(() => _busyKey = key);
    try {
      final result = await widget.modActions.endPoll(
        widget.auth,
        widget.channel,
        pollId: pollId,
        archive: archive,
      );
      if (!mounted) return;
      if (result.ok) {
        widget.onNotice(archive ? 'Poll cancelled.' : 'Poll ended.');
        _load();
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final polls = _polls;
    if (_error != null && polls == null) {
      return _ModError(message: _error!, onRetry: _load);
    }
    if (polls == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [CircularProgressIndicator()],
        ),
      );
    }
    Map<String, dynamic>? active;
    for (final poll in polls) {
      if (poll['status'] == 'ACTIVE') {
        active = poll;
        break;
      }
    }
    if (active == null) {
      return _PollCreateForm(
        channel: widget.channel,
        modActions: widget.modActions,
        auth: widget.auth,
        onNotice: widget.onNotice,
        onCreated: _load,
      );
    }
    final pollId = active['id'] as String? ?? '';
    final busy = _busyKey != null;
    final choices = (active['choices'] as List? ?? const []).cast<Map>();
    var totalVotes = 0;
    for (final c in choices) {
      totalVotes += (c['votes'] as num?)?.toInt() ?? 0;
    }
    final endsAt = active['ends_at'] as String?;
    final ends = endsAt == null || endsAt.isEmpty
        ? null
        : _relativeShortDate(endsAt);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text(active['title'] as String? ?? 'Poll'),
      subtitle: Text(
        [
          '${choices.length} choices',
          '$totalVotes votes',
          if (ends != null) 'ends $ends',
        ].join(' · '),
      ),
      trailing: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busyKey != null
                      ? null
                      : () => _end(pollId, false),
                  child: const Text('End'),
                ),
                TextButton(
                  onPressed: _busyKey != null ? null : () => _end(pollId, true),
                  child: const Text('Archive'),
                ),
              ],
            ),
    );
  }
}

class _PollCreateForm extends StatefulWidget {
  const _PollCreateForm({
    required this.channel,
    required this.modActions,
    required this.auth,
    required this.onNotice,
    required this.onCreated,
  });

  final String channel;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;
  final VoidCallback onCreated;

  @override
  State<_PollCreateForm> createState() => _PollCreateFormState();
}

class _PollCreateFormState extends State<_PollCreateForm> {
  final _titleCtrl = TextEditingController();
  final _choiceCtrls = [TextEditingController(), TextEditingController()];
  int _duration = 60;
  bool _creating = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    for (final c in _choiceCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    final title = _titleCtrl.text.trim();
    final choices = [
      for (final c in _choiceCtrls) c.text.trim(),
    ].where((c) => c.isNotEmpty).toList();
    if (title.isEmpty || choices.length < 2) {
      widget.onNotice('Enter a title and at least 2 choices.');
      return;
    }
    if (_creating) return;
    setState(() => _creating = true);
    try {
      final result = await widget.modActions.createPoll(
        widget.auth,
        widget.channel,
        title: title,
        choices: choices,
        durationSeconds: _duration,
      );
      if (!mounted) return;
      if (result.ok) {
        widget.onNotice('Poll started.');
        widget.onCreated();
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('No active poll.'),
          TextField(
            controller: _titleCtrl,
            decoration: const InputDecoration(labelText: 'Poll title'),
          ),
          for (var i = 0; i < _choiceCtrls.length; i++)
            TextField(
              controller: _choiceCtrls[i],
              decoration: InputDecoration(labelText: 'Choice ${i + 1}'),
            ),
          Row(
            children: [
              const Text('Duration:'),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _duration,
                items: const [
                  DropdownMenuItem(value: 15, child: Text('15s')),
                  DropdownMenuItem(value: 60, child: Text('1m')),
                  DropdownMenuItem(value: 120, child: Text('2m')),
                  DropdownMenuItem(value: 300, child: Text('5m')),
                  DropdownMenuItem(value: 600, child: Text('10m')),
                  DropdownMenuItem(value: 1800, child: Text('30m')),
                ],
                onChanged: _creating
                    ? null
                    : (v) => setState(() => _duration = v ?? 60),
              ),
              const Spacer(),
              if (_choiceCtrls.length < 5)
                TextButton(
                  onPressed: _creating
                      ? null
                      : () => setState(
                          () => _choiceCtrls.add(TextEditingController()),
                        ),
                  child: const Text('Add choice'),
                ),
            ],
          ),
          FilledButton(
            onPressed: _creating ? null : _create,
            child: _creating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Start poll'),
          ),
        ],
      ),
    );
  }
}

class _PredictionsSection extends StatefulWidget {
  const _PredictionsSection({
    required this.channel,
    required this.modActions,
    required this.auth,
    required this.onNotice,
  });

  final String channel;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

  @override
  State<_PredictionsSection> createState() => _PredictionsSectionState();
}

class _PredictionsSectionState extends State<_PredictionsSection> {
  List<Map<String, dynamic>>? _predictions;
  String? _error;
  int _loadGen = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _PredictionsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      setState(() {
        _predictions = null;
        _error = null;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    final background = _predictions != null;
    List<Map<String, dynamic>> predictions = const [];
    String? error;
    try {
      predictions = await widget.modActions.getPredictions(
        widget.auth,
        widget.channel,
      );
      if (widget.modActions.twitchApi.lastErrorStatus != null) {
        error = widget.modActions.failureReason();
      }
    } catch (_) {
      error = 'Could not load predictions.';
    }
    if (!mounted || gen != _loadGen) return;
    if (error != null && background) {
      widget.onNotice(error);
      return;
    }
    setState(() {
      _error = error;
      if (error == null) _predictions = predictions;
    });
  }

  Future<void> _end(
    String predictionId,
    String status, [
    String? winningOutcomeId,
  ]) async {
    if (_busy) return;
    if (status == 'CANCELED') {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cancel prediction?'),
          content: const Text('Points are refunded to predictors.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cancel prediction'),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
    }
    if (predictionId.isEmpty) {
      widget.onNotice('Prediction id is missing; reload and try again.');
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await widget.modActions.endPrediction(
        widget.auth,
        widget.channel,
        predictionId: predictionId,
        status: status,
        winningOutcomeId: winningOutcomeId,
      );
      if (!mounted) return;
      if (result.ok) {
        widget.onNotice(
          status == 'LOCKED'
              ? 'Prediction locked.'
              : status == 'CANCELED'
              ? 'Prediction cancelled.'
              : 'Prediction resolved.',
        );
        _load();
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _outcomeLabel(Map outcome) {
    final title = '${outcome['title'] ?? 'Outcome'}';
    final points = outcome['channel_points'];
    final users = outcome['users'];
    final detail = [
      if (points != null) '$points pts',
      if (users != null) '$users predictors',
    ].join(' · ');
    return detail.isEmpty ? title : '$title ($detail)';
  }

  Future<void> _resolve(Map<String, dynamic> prediction) async {
    final outcomes = (prediction['outcomes'] as List? ?? const []).cast<Map>();
    final winningId = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Winning outcome'),
        children: [
          for (final outcome in outcomes)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, outcome['id'] as String?),
              child: Text(_outcomeLabel(outcome)),
            ),
        ],
      ),
    );
    if (winningId == null || winningId.isEmpty || !mounted) return;
    await _end(prediction['id'] as String? ?? '', 'RESOLVED', winningId);
  }

  @override
  Widget build(BuildContext context) {
    final predictions = _predictions;
    if (_error != null && predictions == null) {
      return _ModError(message: _error!, onRetry: _load);
    }
    if (predictions == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [CircularProgressIndicator()],
        ),
      );
    }
    Map<String, dynamic>? open;
    for (final prediction in predictions) {
      if (prediction['status'] == 'ACTIVE' ||
          prediction['status'] == 'LOCKED') {
        open = prediction;
        break;
      }
    }
    if (open == null) {
      return const ListTile(
        title: Text('No open prediction. Create one with /prediction.'),
      );
    }
    final predictionId = open['id'] as String? ?? '';
    final locked = open['status'] == 'LOCKED';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text(open['title'] as String? ?? 'Prediction'),
      subtitle: Text(
        '${(open['outcomes'] as List? ?? const []).length} outcomes'
        '${locked ? ' · locked' : ''}',
      ),
      trailing: _busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Wrap(
              spacing: 8,
              children: [
                if (!locked)
                  OutlinedButton(
                    onPressed: () => _end(predictionId, 'LOCKED'),
                    child: const Text('Lock'),
                  ),
                FilledButton(
                  onPressed: () => _resolve(open!),
                  child: const Text('Resolve'),
                ),
                TextButton(
                  onPressed: () => _end(predictionId, 'CANCELED'),
                  child: const Text('Cancel'),
                ),
              ],
            ),
    );
  }
}

class _PointsSection extends StatefulWidget {
  const _PointsSection({
    required this.channel,
    required this.store,
    required this.modActions,
    required this.auth,
    required this.onNotice,
  });

  final String channel;
  final ChatStore store;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

  @override
  State<_PointsSection> createState() => _PointsSectionState();
}

class _PointsSectionState extends State<_PointsSection> {
  List<PointReward>? _rewards;
  String? _error;
  int _loadGen = 0;
  String? _selectedRewardId;
  List<PointRedemption>? _queue;
  String? _queueError;
  int _queueGen = 0;
  final _busyRedemptions = <String>{};
  final _toggling = <String>{};

  @override
  void initState() {
    super.initState();
    widget.store.pointVersion.addListener(_onPointsChanged);
    _loadRewards();
  }

  @override
  void didUpdateWidget(covariant _PointsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      setState(() {
        _rewards = null;
        _error = null;
        _selectedRewardId = null;
        _queue = null;
        _queueError = null;
      });
      _loadRewards();
    }
  }

  @override
  void dispose() {
    widget.store.pointVersion.removeListener(_onPointsChanged);
    super.dispose();
  }

  void _onPointsChanged() {
    _loadRewards();
    if (_selectedRewardId != null) _loadQueue();
  }

  Future<void> _loadRewards() async {
    final gen = ++_loadGen;
    final background = _rewards != null;
    List<PointReward> rewards = const [];
    String? error;
    try {
      rewards = await widget.modActions.getPointRewards(
        widget.auth,
        widget.channel,
      );
      if (widget.modActions.twitchApi.lastErrorStatus != null) {
        error = widget.modActions.failureReason();
      }
    } catch (_) {
      error = 'Could not load rewards.';
    }
    if (!mounted || gen != _loadGen) return;
    if (error != null && background) {
      widget.onNotice(error);
      return;
    }
    setState(() {
      _error = error;
      if (error == null) {
        _rewards = rewards;
        if (_selectedRewardId != null &&
            rewards.every((r) => r.id != _selectedRewardId)) {
          _selectedRewardId = null;
          _queue = null;
          _queueError = null;
        }
      }
    });
  }

  Future<void> _loadQueue() async {
    final rewardId = _selectedRewardId;
    if (rewardId == null) return;
    final gen = ++_queueGen;
    final background = _queue != null;
    List<PointRedemption> queue = const [];
    String? error;
    try {
      queue = await widget.modActions.getPointRedemptions(
        widget.auth,
        widget.channel,
        rewardId,
      );
      if (widget.modActions.twitchApi.lastErrorStatus != null) {
        error = widget.modActions.twitchApi.lastErrorStatus == 403
            ? 'Redemptions for this reward are only visible '
                  'to the app that created it.'
            : widget.modActions.failureReason();
      }
    } catch (_) {
      error = 'Could not load redemptions.';
    }
    if (!mounted || gen != _queueGen) return;
    if (error != null && background) {
      widget.onNotice(error);
      return;
    }
    setState(() {
      _queueError = error;
      if (error == null) _queue = queue;
    });
  }

  void _select(String rewardId) {
    if (_selectedRewardId == rewardId) return;
    setState(() {
      _selectedRewardId = rewardId;
      _queue = null;
      _queueError = null;
    });
    _loadQueue();
  }

  Future<void> _resolve(PointRedemption redemption, bool fulfilled) async {
    if (!fulfilled) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Refund redemption?'),
          content: Text(
            'Refund ${redemption.cost} pts to ${redemption.userLogin}?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Refund'),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
    }
    if (!_busyRedemptions.add(redemption.id)) return;
    setState(() {});
    try {
      final result = await widget.modActions.resolveRedemption(
        widget.auth,
        widget.channel,
        redemption.rewardId,
        redemption.id,
        fulfilled,
      );
      if (!mounted) return;
      if (result.ok) {
        widget.store.resolvePointRedemption(widget.channel, redemption.id);
        widget.onNotice(
          fulfilled ? 'Redemption fulfilled.' : 'Redemption refunded.',
        );
        _loadQueue();
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      _busyRedemptions.remove(redemption.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _togglePause(PointReward reward) async {
    if (!_toggling.add(reward.id)) return;
    setState(() {});
    try {
      final result = await widget.modActions.setRewardPaused(
        widget.auth,
        widget.channel,
        reward.id,
        !reward.isPaused,
      );
      if (!mounted) return;
      if (result.ok) {
        widget.onNotice(reward.isPaused ? 'Reward resumed.' : 'Reward paused.');
        _loadRewards();
      } else if (widget.modActions.twitchApi.lastErrorStatus == 403) {
        widget.onNotice('Only rewards created by this app can be paused.');
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      _toggling.remove(reward.id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final rewards = _rewards;
    if (_error != null && rewards == null) {
      return _ModError(message: _error!, onRetry: _loadRewards);
    }
    if (rewards == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [CircularProgressIndicator()],
        ),
      );
    }
    if (rewards.isEmpty) {
      return const ListTile(
        title: Text('No custom rewards. Create them in the dashboard.'),
      );
    }
    final selected = _selectedRewardId == null
        ? null
        : rewards.where((r) => r.id == _selectedRewardId).firstOrNull;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Text(
            'Only rewards created by this app are manageable here.',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final reward in rewards)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            selected: reward.id == _selectedRewardId,
            title: Text(reward.title),
            subtitle: Text(
              '${reward.cost} pts · ${reward.isPaused
                  ? 'Paused'
                  : reward.isEnabled
                  ? 'Enabled'
                  : 'Disabled'}',
            ),
            onTap: () => _select(reward.id),
            trailing: _toggling.contains(reward.id)
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: Icon(
                      reward.isPaused ? Icons.play_arrow : Icons.pause,
                    ),
                    tooltip: reward.isPaused ? 'Resume' : 'Pause',
                    onPressed: () => _togglePause(reward),
                  ),
          ),
        if (selected != null) ...[
          _SectionHeader('Queue — ${selected.title}'),
          _queueBody(selected),
        ],
      ],
    );
  }

  Widget _queueBody(PointReward selected) {
    if (_queueError != null && _queue == null) {
      return _ModError(message: _queueError!, onRetry: _loadQueue);
    }
    final queue = _queue;
    if (queue == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [CircularProgressIndicator()],
        ),
      );
    }
    if (queue.isEmpty) {
      return const ListTile(title: Text('Queue is clear.'));
    }
    return Column(
      children: [
        for (final redemption in queue)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            title: Text(redemption.userLogin),
            subtitle: Text(
              [
                '${redemption.cost} pts',
                if (redemption.redeemedAt.isNotEmpty)
                  'redeemed ${_relativeShortDate(redemption.redeemedAt)}',
                if (redemption.userInput.isNotEmpty)
                  '"${redemption.userInput}"',
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _busyRedemptions.contains(redemption.id)
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _resolve(redemption, true),
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('Fulfill'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _resolve(redemption, false),
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('Refund'),
                      ),
                    ],
                  ),
          ),
      ],
    );
  }
}

class _ModesTab extends StatefulWidget {
  const _ModesTab({
    required this.channel,
    required this.modActions,
    required this.auth,
    required this.roomModes,
    required this.moderationActive,
    required this.onNotice,
  });

  final String channel;
  final ModActions modActions;
  final TwitchAuth auth;
  final Map<String, String> roomModes;
  final bool moderationActive;
  final ValueChanged<String> onNotice;

  @override
  State<_ModesTab> createState() => _ModesTabState();
}

class _ModesTabState extends State<_ModesTab> {
  bool? _shield;
  String? _shieldError;
  bool _shieldLoading = true;
  final _busyKeys = <String>{};

  @override
  void initState() {
    super.initState();
    _loadShield();
  }

  @override
  void didUpdateWidget(covariant _ModesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      setState(() {
        _shield = null;
        _shieldError = null;
        _shieldLoading = true;
      });
      _loadShield();
    }
  }

  int _shieldGen = 0;

  Future<void> _loadShield() async {
    final gen = ++_shieldGen;
    final background = !_shieldLoading && _shield != null;
    if (!background) {
      setState(() {
        _shieldLoading = true;
        _shieldError = null;
      });
    }
    bool? active;
    String? error;
    try {
      active = await widget.modActions.getShieldMode(
        widget.auth,
        widget.channel,
      );
      if (active == null) error = 'Could not load Shield status.';
    } catch (_) {
      error = 'Could not load Shield status.';
    }
    if (!mounted || gen != _shieldGen) return;
    if (error != null && background) {
      widget.onNotice(error);
      return;
    }
    setState(() {
      _shieldLoading = false;
      if (error == null) {
        _shield = active;
        _shieldError = null;
      } else if (_shield == null) {
        _shieldError = error;
      }
    });
  }

  /// Late verification read after a toggle. Gives Twitch's GET time to
  /// settle past the PUT; any intervening load cancels this one via [_shieldGen].
  Future<void> _verifyShield() async {
    final gen = _shieldGen;
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted || gen != _shieldGen) return;
    _loadShield();
  }

  Future<bool> _apply(String key, Future<ModResult> Function() call) async {
    if (!_busyKeys.add(key)) return false;
    setState(() {});
    try {
      final result = await call();
      if (!mounted) return result.ok;
      if (result.ok) {
        widget.onNotice('Chat mode updated.');
      } else {
        widget.onNotice(modErrorText(result));
      }
      return result.ok;
    } finally {
      _busyKeys.remove(key);
      if (mounted) setState(() {});
    }
  }

  Future<void> _toggleSlow(bool on, int slow) async {
    if (on) {
      var picked = await _pick('Slow mode delay', const [
        ('30 seconds', 30),
        ('60 seconds', 60),
        ('120 seconds', 120),
        ('Custom...', -1),
      ]);
      if (picked == null || !mounted) return;
      if (picked < 0) {
        picked = await _pickCustomInt(
          title: 'Slow mode delay',
          label: 'Seconds (3-120)',
          min: 3,
          max: 120,
        );
      }
      if (picked == null || !mounted) return;
      await _apply(
        'slow',
        () => widget.modActions.setSlowMode(
          widget.auth,
          widget.channel,
          enabled: true,
          seconds: picked!,
        ),
      );
    } else {
      await _apply(
        'slow',
        () => widget.modActions.setSlowMode(
          widget.auth,
          widget.channel,
          enabled: false,
        ),
      );
    }
  }

  Future<void> _toggleFollowers(bool on) async {
    if (on) {
      var picked = await _pick('Minimum follow age', const [
        ('No minimum', -1),
        ('10 minutes', 10),
        ('30 minutes', 30),
        ('1 hour', 60),
        ('1 day', 1440),
        ('1 week', 10080),
        ('Custom...', -2),
      ]);
      if (picked == null || !mounted) return;
      if (picked == -2) {
        picked = await _pickCustomInt(
          title: 'Minimum follow age',
          label: 'Minutes (1-10080)',
          min: 1,
          max: 10080,
        );
      }
      if (picked == null || !mounted) return;
      await _apply(
        'followers',
        () => widget.modActions.setFollowersMode(
          widget.auth,
          widget.channel,
          enabled: true,
          minutes: picked! < 0 ? null : picked,
        ),
      );
    } else {
      await _apply(
        'followers',
        () => widget.modActions.setFollowersMode(
          widget.auth,
          widget.channel,
          enabled: false,
        ),
      );
    }
  }

  bool _picking = false;

  // Second taps while a picker is open no-op instead of stacking dialogs.
  Future<T?> _pick<T>(String title, List<(String, T)> options) async {
    if (_picking) return null;
    _picking = true;
    try {
      return await showDialog<T>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(title),
          children: [
            for (final (label, value) in options)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, value),
                child: Text(label),
              ),
          ],
        ),
      );
    } finally {
      _picking = false;
    }
  }

  Future<int?> _pickCustomInt({
    required String title,
    required String label,
    required int min,
    required int max,
  }) async {
    final ctrl = TextEditingController();
    final pending = showDialog<int>(
      context: context,
      builder: (ctx) {
        var error = '';
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: Text(title),
            content: TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                labelText: label,
                errorText: error.isEmpty ? null : error,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final parsed = int.tryParse(ctrl.text.trim());
                  if (parsed == null || parsed < min || parsed > max) {
                    setLocal(() => error = 'Enter $min-$max.');
                    return;
                  }
                  Navigator.pop(ctx, parsed);
                },
                child: const Text('Use value'),
              ),
            ],
          ),
        );
      },
    );
    pending.whenComplete(ctrl.dispose);
    return pending;
  }

  @override
  Widget build(BuildContext context) {
    final tags = widget.roomModes;
    final slow = int.tryParse(tags['slow'] ?? '') ?? 0;
    final followers = tags['followers-only'];
    final followersOn = followers != null && followers != '-1';
    bool enabledFor(String key) =>
        widget.moderationActive && !_busyKeys.contains(key);
    bool anyBusy = _busyKeys.isNotEmpty;
    final shieldBusy = _busyKeys.contains('shield') || _shieldLoading;
    final modes = [
      (
        'Slow mode',
        Icons.hourglass_bottom_outlined,
        slow > 0 ? '${slow}s' : 'Off',
        slow > 0,
        enabledFor('slow'),
        (bool on) => _toggleSlow(on, slow),
      ),
      (
        'Followers',
        Icons.favorite_outline,
        !followersOn
            ? 'Off'
            : followers == '0'
            ? 'No minimum'
            : 'Following ${followers}m',
        followersOn,
        enabledFor('followers'),
        _toggleFollowers,
      ),
      (
        'Emote-only',
        Icons.emoji_emotions_outlined,
        tags['emote-only'] == '1' ? 'On' : 'Off',
        tags['emote-only'] == '1',
        enabledFor('emote'),
        (bool on) => _apply(
          'emote',
          () => widget.modActions.setEmoteOnly(
            widget.auth,
            widget.channel,
            enabled: on,
          ),
        ),
      ),
      (
        'Subscribers',
        Icons.star_outline,
        tags['subs-only'] == '1' ? 'On' : 'Off',
        tags['subs-only'] == '1',
        enabledFor('subs'),
        (bool on) => _apply(
          'subs',
          () => widget.modActions.setSubscribersOnly(
            widget.auth,
            widget.channel,
            enabled: on,
          ),
        ),
      ),
      (
        'Unique chat',
        Icons.person_outline,
        tags['r9k'] == '1' ? 'On' : 'Off',
        tags['r9k'] == '1',
        enabledFor('unique'),
        (bool on) => _apply(
          'unique',
          () => widget.modActions.setUniqueChat(
            widget.auth,
            widget.channel,
            enabled: on,
          ),
        ),
      ),
      (
        'Shield mode',
        Icons.shield_outlined,
        _shield == null ? '...' : (_shield! ? 'On' : 'Off'),
        _shield ?? false,
        enabledFor('shield') && !_shieldLoading && _shield != null,
        (bool on) async {
          final ok = await _apply(
            'shield',
            () => widget.modActions.setShieldMode(
              widget.auth,
              widget.channel,
              active: on,
            ),
          );
          if (!ok || !mounted) return;
          // Optimistic flip: the status GET lags the PUT, so an immediate
          // reload can return the stale value and snap the card back.
          setState(() {
            _shield = on;
            _shieldError = null;
          });
          unawaited(_verifyShield());
        },
      ),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        if (!widget.moderationActive)
          const ListTile(
            contentPadding: EdgeInsets.symmetric(horizontal: 4),
            title: Text('Chat modes need moderator status in this channel.'),
          ),
        if (anyBusy) const LinearProgressIndicator(minHeight: 2),
        if (_shieldError != null && _shield == null)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: const Text('Shield mode failed to load'),
            subtitle: Text(_shieldError!),
            trailing: TextButton(
              onPressed: _loadShield,
              child: const Text('Retry'),
            ),
          ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.86,
          ),
          itemCount: modes.length,
          itemBuilder: (_, i) {
            final m = modes[i];
            return _ModeCard(
              label: m.$1,
              icon: m.$2,
              status: m.$3,
              value: m.$4,
              enabled: m.$5,
              busy: i == 5 && shieldBusy,
              onToggle: m.$6,
            );
          },
        ),
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.label,
    required this.icon,
    required this.status,
    required this.value,
    required this.enabled,
    required this.onToggle,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final String status;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = value ? scheme.primaryContainer : scheme.surfaceContainerHigh;
    final fg = value ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Opacity(
      opacity: enabled ? 1.0 : 0.55,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: !enabled || busy ? null : () => onToggle(!value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(icon, size: 28, color: fg),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  status,
                  style: TextStyle(fontSize: 11, color: fg),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RosterSections extends StatefulWidget {
  const _RosterSections({
    required this.channel,
    required this.modActions,
    required this.auth,
    required this.onNotice,
  });

  final String channel;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

  @override
  State<_RosterSections> createState() => _RosterSectionsState();
}

class _RosterSectionsState extends State<_RosterSections> {
  List<String>? _mods;
  List<String>? _vips;
  String? _modsError;
  String? _vipsError;
  int _loadGen = 0;
  final _removing = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _RosterSections oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) _load();
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    setState(() {
      _mods = null;
      _vips = null;
      _modsError = null;
      _vipsError = null;
    });
    List<String> mods = const [];
    List<String> vips = const [];
    String? modsError;
    String? vipsError;
    try {
      mods = await widget.modActions.getModerators(widget.auth, widget.channel);
      if (widget.modActions.twitchApi.lastErrorStatus != null) {
        modsError = widget.modActions.failureReason();
      }
    } catch (_) {
      modsError = 'Could not load moderators.';
    }
    try {
      vips = await widget.modActions.getVips(widget.auth, widget.channel);
      if (widget.modActions.twitchApi.lastErrorStatus != null) {
        vipsError = widget.modActions.failureReason();
      }
    } catch (_) {
      vipsError = 'Could not load VIPs.';
    }
    if (!mounted || gen != _loadGen) return;
    setState(() {
      _modsError = modsError;
      _vipsError = vipsError;
      if (modsError == null) _mods = mods;
      if (vipsError == null) _vips = vips;
    });
  }

  Future<void> _add(bool moderator) async {
    final login = await showModTextDialog(
      context,
      title: moderator ? 'Add moderator' : 'Add VIP',
      label: 'Username',
      confirmLabel: 'Add',
    );
    if (login == null || !mounted) return;
    if (login.isEmpty) {
      widget.onNotice('Enter a username.');
      return;
    }
    final result = moderator
        ? await widget.modActions.setModerator(
            widget.auth,
            widget.channel,
            login: login,
            add: true,
          )
        : await widget.modActions.setVip(
            widget.auth,
            widget.channel,
            login: login,
            add: true,
          );
    if (!mounted) return;
    if (result.ok) {
      _load();
    } else {
      widget.onNotice(modErrorText(result));
    }
  }

  Future<void> _remove(String login, bool moderator) async {
    final key = '${moderator ? 'mod' : 'vip'}:${login.toLowerCase()}';
    if (!_removing.add(key)) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $login?'),
        content: Text(
          moderator
              ? 'This removes moderator status from $login.'
              : 'This removes VIP status from $login.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) {
      _removing.remove(key);
      return;
    }
    setState(() {});
    try {
      final result = moderator
          ? await widget.modActions.setModerator(
              widget.auth,
              widget.channel,
              login: login,
              add: false,
            )
          : await widget.modActions.setVip(
              widget.auth,
              widget.channel,
              login: login,
              add: false,
            );
      if (!mounted) return;
      if (result.ok) {
        widget.onNotice('Removed $login.');
        _load();
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      _removing.remove(key);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_mods == null &&
        _vips == null &&
        (_modsError != null || _vipsError != null)) {
      return _ModError(
        message: _modsError ?? _vipsError ?? 'Could not load.',
        onRetry: _load,
      );
    }
    if (_mods == null || _vips == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [CircularProgressIndicator()],
        ),
      );
    }
    return Column(
      children: [
        _PersonSection(
          title: 'Moderators (${_mods!.length})',
          logins: _mods!,
          error: _modsError,
          onRetry: _load,
          removing: _removing,
          prefix: 'mod',
          onAdd: () => _add(true),
          onRemove: (login) => _remove(login, true),
        ),
        _PersonSection(
          title: 'VIPs (${_vips!.length})',
          logins: _vips!,
          error: _vipsError,
          onRetry: _load,
          removing: _removing,
          prefix: 'vip',
          onAdd: () => _add(false),
          onRemove: (login) => _remove(login, false),
        ),
      ],
    );
  }
}

class _PersonSection extends StatelessWidget {
  const _PersonSection({
    required this.title,
    required this.logins,
    required this.onAdd,
    required this.onRemove,
    this.error,
    this.onRetry,
    this.removing = const {},
    this.prefix = '',
  });

  final String title;
  final List<String> logins;
  final VoidCallback onAdd;
  final void Function(String login) onRemove;
  final String? error;
  final VoidCallback? onRetry;
  final Set<String> removing;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 12,
              letterSpacing: 0.8,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          trailing: FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.person_add, size: 18),
            label: const Text('Add'),
          ),
        ),
        if (error != null)
          ListTile(
            dense: true,
            title: Text(error!),
            trailing: TextButton(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ),
        if (logins.isEmpty && error == null)
          const ListTile(title: Text('None yet.')),
        for (final login in logins)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 2,
            ),
            title: Text(login),
            trailing: removing.contains('$prefix:${login.toLowerCase()}')
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    tooltip: 'Remove',
                    onPressed: () => onRemove(login),
                  ),
          ),
      ],
    );
  }
}
