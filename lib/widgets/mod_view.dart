import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/chat_store.dart';
import '../services/mod_actions.dart';
import '../services/twitch_api.dart';
import '../services/twitch_auth.dart';
import 'app_snack.dart';

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

/// Single text field dialog (reasons, usernames). Null means cancelled.
Future<String?> showModTextDialog(
  BuildContext context, {
  required String title,
  String? label,
  required String confirmLabel,
}) {
  final ctrl = TextEditingController();
  final pending = showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (_) => Navigator.pop(ctx, ctrl.text.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  pending.whenComplete(ctrl.dispose);
  return pending;
}

/// Mod View panel body: Queue / Activity / Users / Modes / Requests /
/// Terms / Setup / Channel tabs. State arrives as channel lookups (not
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
  final bool Function(String channel) isModerationActive;
  final bool Function(String channel) isAutomodActive;
  final Map<String, String> Function(String channel) getRoomModes;

  /// Notice sink for failures; the shell routes these to the inline bar.
  final ValueChanged<String> onNotice;

  /// Opens a user card (queue rows, feed-adjacent user lists).
  final ValueChanged<String>? onShowUser;

  /// Whether the session user owns the channel (Channel tab gate).
  final bool isBroadcaster;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: refresh,
      builder: (_, _) {
        final moderationActive = isModerationActive(channel);
        final automodActive = isAutomodActive(channel);
        if (!moderationActive && !automodActive) {
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
        return TabBarView(
          controller: tabController,
          children: [
            _QueueTab(
              channel: channel,
              store: store,
              modActions: modActions,
              auth: auth,
              automodActive: automodActive,
              scopeReady: moderationActive,
              onNotice: onNotice,
              onShowUser: onShowUser,
            ),
            _ActivityTab(channel: channel, store: store),
            _UsersTab(
              channel: channel,
              store: store,
              modActions: modActions,
              auth: auth,
              onNotice: onNotice,
              onShowUser: onShowUser,
            ),
            _ModesTab(
              channel: channel,
              modActions: modActions,
              auth: auth,
              roomModes: getRoomModes(channel),
              moderationActive: moderationActive,
              onNotice: onNotice,
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
              onNotice: onNotice,
            ),
            _SetupTab(
              channel: channel,
              store: store,
              modActions: modActions,
              auth: auth,
              onNotice: onNotice,
            ),
            _ChannelTab(
              channel: channel,
              modActions: modActions,
              auth: auth,
              onNotice: onNotice,
              isBroadcaster: isBroadcaster,
            ),
          ],
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
    required this.onNotice,
    required this.onShowUser,
  });

  final String channel;
  final ChatStore store;
  final ModActions modActions;
  final TwitchAuth auth;
  final bool automodActive;
  final bool scopeReady;
  final ValueChanged<String> onNotice;
  final ValueChanged<String>? onShowUser;

  @override
  State<_QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<_QueueTab> {
  final _pending = <String>{};
  String? _filter;

  Future<void> _decide(HeldMessage held, bool allow) async {
    if (!_pending.add(held.messageId)) return;
    setState(() {});
    try {
      final result = await widget.modActions.decideHeldMessage(
        widget.auth,
        widget.channel,
        messageId: held.messageId,
        allow: allow,
      );
      if (!mounted) return;
      if (result.ok) {
        widget.store.resolveHeldMessage(widget.channel, held.messageId);
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      _pending.remove(held.messageId);
      if (mounted) setState(() {});
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
    if (!result.ok) widget.onNotice(modErrorText(result));
  }

  Future<void> _ban(HeldMessage held) async {
    final reason = await showModTextDialog(
      context,
      title: 'Ban ${held.userLogin}?',
      label: 'Reason (optional)',
      confirmLabel: 'Ban',
    );
    if (reason == null || !mounted) return;
    final result = await widget.modActions.banUser(
      widget.auth,
      widget.channel,
      login: held.userLogin,
      reason: reason.isEmpty ? null : reason,
    );
    if (!mounted) return;
    if (!result.ok) widget.onNotice(modErrorText(result));
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            widget.scopeReady
                ? 'AutoMod queue needs the moderator:manage:automod scope. Re-login to pick it up.'
                : 'AutoMod queue is unavailable here.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ValueListenableBuilder<int>(
      valueListenable: widget.store.heldVersion,
      builder: (_, _, _) {
        final all = widget.store.heldMessages[widget.channel] ?? const [];
        if (all.isEmpty) {
          return const Center(child: Text('Queue is clear.'));
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
                  ? const Center(child: Text('No matches.'))
                  : ListView.builder(
                      itemCount: queue.length,
                      itemBuilder: (_, i) {
                        final held = queue[i];
                        final busy = _pending.contains(held.messageId);
                        return ListTile(
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
                          subtitle: Text(held.text, maxLines: 4),
                          isThreeLine: true,
                          onTap: () => widget.onShowUser?.call(held.userLogin),
                          trailing: busy
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.check),
                                      tooltip: 'Allow',
                                      onPressed: () => _decide(held, true),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.close),
                                      tooltip: 'Deny',
                                      onPressed: () => _decide(held, false),
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
      valueListenable: store.modActivityVersion,
      builder: (_, _, _) {
        final feed = store.modActivity[channel] ?? const [];
        if (feed.isEmpty) {
          return const Center(child: Text('No moderation activity yet.'));
        }
        return ListView.builder(
          itemCount: feed.length,
          itemBuilder: (_, i) {
            final entry = feed[i];
            return ListTile(
              dense: true,
              leading: Icon(_activityIcon(entry.action), size: 20),
              title: Text(formatModActivity(entry)),
              subtitle: Text('${entry.moderator} · ${_feedTime(entry.at)}'),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
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
  });

  final String channel;
  final ChatStore store;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;
  final ValueChanged<String>? onShowUser;

  @override
  State<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<_UsersTab> {
  final _pending = <String>{};

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
        widget.store.removeBan(widget.channel, login);
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      _pending.remove(key);
      if (mounted) setState(() {});
    }
  }

  Future<void> _clearFlag(String login) async {
    final key = login.toLowerCase();
    if (!_pending.add(key)) return;
    setState(() {});
    try {
      final result = await widget.modActions.clearSuspiciousStatus(
        widget.auth,
        widget.channel,
        login: login,
      );
      if (!mounted) return;
      if (result.ok) {
        widget.store.removeSuspicious(widget.channel, login);
      } else {
        widget.onNotice(modErrorText(result));
      }
    } finally {
      _pending.remove(key);
      if (mounted) setState(() {});
    }
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
        final seen = <String>{};
        final warned = <WarnEntry>[];
        for (final w in warnings) {
          final lower = w.target.toLowerCase();
          counts[lower] = (counts[lower] ?? 0) + 1;
          if (seen.add(lower)) warned.add(w);
        }
        return ListView(
          children: [
            _SectionHeader('Banned (${bans.length})'),
            if (bans.isEmpty) const ListTile(dense: true, title: Text('None.')),
            for (final ban in bans)
              ListTile(
                dense: true,
                title: Text(ban.login),
                subtitle: Text(_banSubtitle(ban)),
                onTap: () => widget.onShowUser?.call(ban.login),
                trailing: _pending.contains(ban.login.toLowerCase())
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        icon: const Icon(Icons.undo),
                        tooltip: 'Unban',
                        onPressed: () => _unban(ban.login),
                      ),
              ),
            _SectionHeader('Warned (${warned.length})'),
            if (warned.isEmpty)
              const ListTile(dense: true, title: Text('None.')),
            for (final w in warned)
              ListTile(
                dense: true,
                title: Text(w.target),
                subtitle: Text(
                  _warnSubtitle(counts[w.target.toLowerCase()] ?? 1, w),
                ),
                onTap: () => widget.onShowUser?.call(w.target),
              ),
            _SectionHeader('Flagged (${flagged.length})'),
            if (flagged.isEmpty)
              const ListTile(dense: true, title: Text('None.')),
            for (final info in flagged)
              ListTile(
                dense: true,
                title: Text(info.login),
                subtitle: Text(_suspiciousSubtitle(info)),
                onTap: () => widget.onShowUser?.call(info.login),
                trailing: _pending.contains(info.login.toLowerCase())
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        icon: const Icon(Icons.visibility_off_outlined),
                        tooltip: 'Clear flag',
                        onPressed: () => _clearFlag(info.login),
                      ),
              ),
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
        : 'Timeout until ${_feedTime(ban.expiresAt!)}';
    if (ban.reason != null && ban.reason!.isNotEmpty) {
      return '$head · "${ban.reason}"';
    }
    return head;
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
    if (evasion != null && evasion.isNotEmpty && evasion != 'unknown') {
      parts.add('$evasion ban evasion');
    }
    if (info.sharedBanChannelIds.isNotEmpty) {
      final n = info.sharedBanChannelIds.length;
      parts.add('banned in $n shared channel${n == 1 ? '' : 's'}');
    }
    if (info.types.isNotEmpty) {
      parts.add(info.types.map((t) => t.replaceAll('_', ' ')).join(', '));
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

String _shortDate(String iso) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  final local = dt.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
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
      _status = 'pending';
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
    final decision = await showDialog<bool>(
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
                'Status: ${request.status} · ${_shortDate(request.createdAt)}',
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
    final message = resolutionCtrl.text.trim();
    resolutionCtrl.dispose();
    if (decision == null || !mounted) return;
    final result = await widget.modActions.resolveUnbanRequest(
      widget.auth,
      widget.channel,
      requestId: request.id,
      approved: decision,
      resolutionText: message.isEmpty ? null : message,
    );
    if (!mounted) return;
    if (result.ok) {
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              for (final s in _statuses)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(s[0].toUpperCase() + s.substring(1)),
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    final requests = _requests;
    if (requests == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (requests.isEmpty) {
      return Center(child: Text('No $_status requests.'));
    }
    return ListView.builder(
      itemCount: requests.length,
      itemBuilder: (_, i) {
        final request = requests[i];
        return ListTile(
          title: Text(request.userLogin),
          subtitle: Text(
            '"${request.text}" · ${_shortDate(request.createdAt)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _showDetail(request),
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
    required this.onNotice,
  });

  final String channel;
  final ChatStore store;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

  @override
  State<_TermsTab> createState() => _TermsTabState();
}

class _TermsTabState extends State<_TermsTab> {
  List<BlockedTerm>? _terms;
  String? _error;
  int _loadGen = 0;
  final _addCtrl = TextEditingController();
  final _removing = <String>{};
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    widget.store.modInboxVersion.addListener(_onInboxChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant _TermsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) _load();
  }

  @override
  void dispose() {
    widget.store.modInboxVersion.removeListener(_onInboxChanged);
    _addCtrl.dispose();
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

  Future<void> _add() async {
    final text = _addCtrl.text.trim();
    if (text.isEmpty || _adding) return;
    if (text.length < 2 || text.length > 500) {
      widget.onNotice('Terms must be 2-500 characters.');
      return;
    }
    setState(() => _adding = true);
    final result = await widget.modActions.addBlockedTerm(
      widget.auth,
      widget.channel,
      text,
    );
    if (!mounted) return;
    setState(() => _adding = false);
    if (result.ok) {
      _addCtrl.clear();
      _load();
    } else {
      widget.onNotice(modErrorText(result));
    }
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
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _addCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Block a word or phrase',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: _adding
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                tooltip: 'Add term',
                onPressed: _adding ? null : _add,
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            'Public list only; private terms live in the dashboard. * works at an edge.',
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_error != null && _terms == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    final terms = _terms;
    if (terms == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (terms.isEmpty) {
      return const Center(child: Text('No blocked terms yet.'));
    }
    return ListView.builder(
      itemCount: terms.length,
      itemBuilder: (_, i) {
        final term = terms[i];
        return ListTile(
          dense: true,
          title: Text(term.text),
          subtitle: Text('Added ${_shortDate(term.createdAt)}'),
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
    widget.store.modInboxVersion.addListener(_onInboxChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant _SetupTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) _load();
  }

  @override
  void dispose() {
    widget.store.modInboxVersion.removeListener(_onInboxChanged);
    super.dispose();
  }

  void _onInboxChanged() => _load();

  Future<void> _load() async {
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
    if (_overall != saved.overallLevel) return true;
    if (levels.length != saved.levels.length) return true;
    for (final entry in levels.entries) {
      if (saved.levels[entry.key] != entry.value) return true;
    }
    return false;
  }

  Future<void> _save() async {
    final levels = _levels;
    if (levels == null || _saving || !_dirty) return;
    setState(() => _saving = true);
    final result = await widget.modActions.updateAutoModSettings(
      widget.auth,
      widget.channel,
      _overall != null ? {'overall_level': _overall!} : levels,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.ok) {
      _load();
    } else {
      widget.onNotice(modErrorText(result));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && _settings == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    final levels = _levels;
    if (levels == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        const Text(
          'Levels 0-4 per category. Saving a preset resets every category; moving a slider switches to custom.',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final (label, value) in _presets)
              ChoiceChip(
                label: Text(label),
                selected: _overall == value,
                onSelected: (_) => setState(() => _overall = value),
              ),
          ],
        ),
        if (_overall == null)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Custom levels.'),
          ),
        for (final (key, label) in _cats)
          Row(
            children: [
              Expanded(child: Text(label)),
              SizedBox(
                width: 180,
                child: Slider(
                  value: (levels[key] ?? 0).toDouble(),
                  min: 0,
                  max: 4,
                  divisions: 4,
                  label: '${levels[key] ?? 0}',
                  onChanged: (v) => setState(() {
                    levels[key] = v.round();
                    _overall = null;
                  }),
                ),
              ),
              SizedBox(width: 24, child: Text('${levels[key] ?? 0}')),
            ],
          ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _dirty && !_saving ? _save : null,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save changes'),
        ),
      ],
    );
  }
}

class _ChannelTab extends StatelessWidget {
  const _ChannelTab({
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
  final bool isBroadcaster;

  @override
  Widget build(BuildContext context) {
    if (!isBroadcaster) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            'Only the broadcaster can use these tools here. '
            'Log in as the broadcaster to manage rosters, polls, and the stream.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      children: [
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
        const _SectionHeader('Stream'),
        _StreamActions(
          channel: channel,
          modActions: modActions,
          auth: auth,
          onNotice: onNotice,
        ),
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
    if (oldWidget.channel != widget.channel) _load();
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
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
      head = dt == null ? 'Timed out' : 'Timeout until ${_feedTime(dt)}';
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
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Text(_error!),
              ),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          )
        else if (banned == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [CircularProgressIndicator()],
            ),
          )
        else if (banned.isEmpty)
          const ListTile(dense: true, title: Text('None.'))
        else
          for (final ban in banned)
            ListTile(
              dense: true,
              title: Text(ban.userLogin),
              subtitle: Text(_subtitle(ban)),
              trailing: _pending.contains(ban.userLogin.toLowerCase())
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      icon: const Icon(Icons.undo),
                      tooltip: 'Unban',
                      onPressed: () => _unban(ban.userLogin),
                    ),
            ),
      ],
    );
  }
}

class _StreamActions extends StatelessWidget {
  const _StreamActions({
    required this.channel,
    required this.modActions,
    required this.auth,
    required this.onNotice,
  });

  final String channel;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;

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

  Future<void> _unraid(BuildContext context) async {
    final result = await modActions.cancelRaid(auth, channel);
    if (!context.mounted) return;
    onNotice(result.ok ? 'Raid cancelled.' : modErrorText(result));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.flight_takeoff_outlined),
          title: const Text('Start raid...'),
          onTap: () => _raid(context),
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.flight_land_outlined),
          title: const Text('Cancel raid'),
          onTap: () => _unraid(context),
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.monetization_on_outlined),
          title: const Text('Run commercial...'),
          onTap: () => _commercial(context),
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.bookmark_add_outlined),
          title: const Text('Add marker...'),
          onTap: () => _marker(context),
        ),
      ],
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
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _PollsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) _load();
  }

  String? get _broadcasterId =>
      widget.modActions.getChannelUserIds()[widget.channel];

  Future<void> _load() async {
    final gen = ++_loadGen;
    List<Map<String, dynamic>> polls = const [];
    String? error;
    try {
      final broadcasterId = _broadcasterId;
      if (broadcasterId == null) {
        error = 'Channel not joined.';
      } else {
        polls = await widget.modActions.twitchApi.getPolls(
          widget.auth,
          broadcasterId,
        );
        if (widget.modActions.twitchApi.lastErrorStatus != null) {
          error = widget.modActions.failureReason();
        }
      }
    } catch (_) {
      error = 'Could not load polls.';
    }
    if (!mounted || gen != _loadGen) return;
    setState(() {
      _error = error;
      if (error == null) _polls = polls;
    });
  }

  Future<void> _end(String pollId, bool archive) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final broadcasterId = _broadcasterId;
      final ok =
          broadcasterId != null &&
          await widget.modActions.twitchApi.endPoll(
            widget.auth,
            broadcasterId: broadcasterId,
            pollId: pollId,
            archive: archive,
          );
      if (!mounted) return;
      if (ok) {
        _load();
      } else {
        widget.onNotice(
          widget.modActions.twitchApi.lastErrorStatus != null
              ? widget.modActions.failureReason()
              : 'Could not end the poll.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final polls = _polls;
    if (_error != null && polls == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Text(_error!),
          ),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
      );
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
      return const ListTile(
        dense: true,
        title: Text('No active poll. Create one with /poll.'),
      );
    }
    final pollId = active['id'] as String? ?? '';
    return ListTile(
      title: Text(active['title'] as String? ?? 'Poll'),
      subtitle: Text(
        '${(active['choices'] as List? ?? const []).length} choices',
      ),
      trailing: _busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => _end(pollId, false),
                  child: const Text('End'),
                ),
                TextButton(
                  onPressed: () => _end(pollId, true),
                  child: const Text('Cancel'),
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
    if (oldWidget.channel != widget.channel) _load();
  }

  String? get _broadcasterId =>
      widget.modActions.getChannelUserIds()[widget.channel];

  Future<void> _load() async {
    final gen = ++_loadGen;
    List<Map<String, dynamic>> predictions = const [];
    String? error;
    try {
      final broadcasterId = _broadcasterId;
      if (broadcasterId == null) {
        error = 'Channel not joined.';
      } else {
        predictions = await widget.modActions.twitchApi.getPredictions(
          widget.auth,
          broadcasterId,
        );
        if (widget.modActions.twitchApi.lastErrorStatus != null) {
          error = widget.modActions.failureReason();
        }
      }
    } catch (_) {
      error = 'Could not load predictions.';
    }
    if (!mounted || gen != _loadGen) return;
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
    setState(() => _busy = true);
    try {
      final broadcasterId = _broadcasterId;
      final ok =
          broadcasterId != null &&
          await widget.modActions.twitchApi.endPrediction(
            widget.auth,
            broadcasterId: broadcasterId,
            predictionId: predictionId,
            status: status,
            winningOutcomeId: winningOutcomeId,
          );
      if (!mounted) return;
      if (ok) {
        _load();
      } else {
        widget.onNotice(
          widget.modActions.twitchApi.lastErrorStatus != null
              ? widget.modActions.failureReason()
              : 'Could not update the prediction.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
              child: Text('${outcome['title']}'),
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
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Text(_error!),
          ),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
      );
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
        dense: true,
        title: Text('No open prediction. Create one with /prediction.'),
      );
    }
    final predictionId = open['id'] as String? ?? '';
    final locked = open['status'] == 'LOCKED';
    return ListTile(
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
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!locked)
                  TextButton(
                    onPressed: () => _end(predictionId, 'LOCKED'),
                    child: const Text('Lock'),
                  ),
                TextButton(
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
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadShield();
  }

  @override
  void didUpdateWidget(covariant _ModesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      setState(() => _shield = null);
      _loadShield();
    }
  }

  int _shieldGen = 0;

  Future<void> _loadShield() async {
    final gen = ++_shieldGen;
    bool? active;
    try {
      active = await widget.modActions.getShieldMode(
        widget.auth,
        widget.channel,
      );
    } catch (_) {
      active = null;
    }
    if (mounted && gen == _shieldGen) setState(() => _shield = active);
  }

  Future<void> _apply(Future<ModResult> Function() call) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await call();
      // Modes refresh off the ROOMSTATE echo; shield refetches directly.
      if (!mounted) return;
      if (!result.ok) widget.onNotice(modErrorText(result));
    } finally {
      if (mounted) setState(() => _busy = false);
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

  @override
  Widget build(BuildContext context) {
    final tags = widget.roomModes;
    final slow = int.tryParse(tags['slow'] ?? '') ?? 0;
    final followers = tags['followers-only'];
    final followersOn = followers != null && followers != '-1';
    // Without the moderate subscription every toggle 403s; disable with a
    // hint instead of failing noisily.
    final enabled = widget.moderationActive && !_busy;
    return ListView(
      children: [
        if (!widget.moderationActive)
          const ListTile(
            title: Text('Chat modes need moderator status in this channel.'),
          ),
        SwitchListTile(
          title: const Text('Slow mode'),
          subtitle: Text(slow > 0 ? '${slow}s' : 'Off'),
          value: slow > 0,
          onChanged: !enabled
              ? null
              : (on) async {
                  if (on) {
                    final picked = await _pick('Slow mode delay', const [
                      ('30 seconds', 30),
                      ('60 seconds', 60),
                      ('120 seconds', 120),
                    ]);
                    if (picked == null || !mounted) return;
                    await _apply(
                      () => widget.modActions.setSlowMode(
                        widget.auth,
                        widget.channel,
                        enabled: true,
                        seconds: picked,
                      ),
                    );
                  } else {
                    await _apply(
                      () => widget.modActions.setSlowMode(
                        widget.auth,
                        widget.channel,
                        enabled: false,
                      ),
                    );
                  }
                },
        ),
        SwitchListTile(
          title: const Text('Followers-only'),
          subtitle: Text(
            !followersOn
                ? 'Off'
                : followers == '0'
                ? 'No minimum follow age'
                : 'Following for ${followers}m',
          ),
          value: followersOn,
          onChanged: !enabled
              ? null
              : (on) async {
                  if (on) {
                    // -1 encodes "no minimum"; null is a dismissed dialog.
                    final picked = await _pick('Minimum follow age', const [
                      ('No minimum', -1),
                      ('10 minutes', 10),
                      ('1 hour', 60),
                      ('1 day', 1440),
                      ('1 week', 10080),
                    ]);
                    if (picked == null || !mounted) return;
                    await _apply(
                      () => widget.modActions.setFollowersMode(
                        widget.auth,
                        widget.channel,
                        enabled: true,
                        minutes: picked < 0 ? null : picked,
                      ),
                    );
                  } else {
                    await _apply(
                      () => widget.modActions.setFollowersMode(
                        widget.auth,
                        widget.channel,
                        enabled: false,
                      ),
                    );
                  }
                },
        ),
        for (final (label, modeOn, set) in [
          (
            'Emote-only',
            tags['emote-only'] == '1',
            widget.modActions.setEmoteOnly,
          ),
          (
            'Subscribers-only',
            tags['subs-only'] == '1',
            widget.modActions.setSubscribersOnly,
          ),
          ('Unique chat', tags['r9k'] == '1', widget.modActions.setUniqueChat),
        ])
          SwitchListTile(
            title: Text(label),
            value: modeOn,
            onChanged: !enabled
                ? null
                : (on) => _apply(
                    () => set(widget.auth, widget.channel, enabled: on),
                  ),
          ),
        if (_shield != null)
          SwitchListTile(
            title: const Text('Shield mode'),
            value: _shield!,
            onChanged: !enabled
                ? null
                : (on) async {
                    await _apply(
                      () => widget.modActions.setShieldMode(
                        widget.auth,
                        widget.channel,
                        active: on,
                      ),
                    );
                    if (mounted) _loadShield();
                  },
          )
        else
          ListTile(
            title: const Text('Shield mode'),
            subtitle: const Text('Status unknown'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: !enabled
                      ? null
                      : () async {
                          await _apply(
                            () => widget.modActions.setShieldMode(
                              widget.auth,
                              widget.channel,
                              active: true,
                            ),
                          );
                          if (mounted) _loadShield();
                        },
                  child: const Text('Enable'),
                ),
                TextButton(
                  onPressed: !enabled
                      ? null
                      : () async {
                          await _apply(
                            () => widget.modActions.setShieldMode(
                              widget.auth,
                              widget.channel,
                              active: false,
                            ),
                          );
                          if (mounted) _loadShield();
                        },
                  child: const Text('Disable'),
                ),
              ],
            ),
          ),
      ],
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
  String? _error;
  int _loadGen = 0;

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
      _error = null;
    });
    List<String> mods = const [];
    List<String> vips = const [];
    String? error;
    try {
      mods = await widget.modActions.getModerators(widget.auth, widget.channel);
      // Read synchronously per call: getVips clears the mods error below.
      if (widget.modActions.twitchApi.lastErrorStatus != null) {
        error = widget.modActions.failureReason();
      }
      vips = await widget.modActions.getVips(widget.auth, widget.channel);
      error ??= widget.modActions.twitchApi.lastErrorStatus != null
          ? widget.modActions.failureReason()
          : null;
    } catch (_) {
      error = 'Could not load the lists.';
    }
    if (!mounted || gen != _loadGen) return;
    setState(() {
      _error = error;
      if (error == null) {
        _mods = mods;
        _vips = vips;
      }
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
      _load();
    } else {
      widget.onNotice(modErrorText(result));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(_error!),
          ),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
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
          onAdd: () => _add(true),
          onRemove: (login) => _remove(login, true),
        ),
        _PersonSection(
          title: 'VIPs (${_vips!.length})',
          logins: _vips!,
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
  });

  final String title;
  final List<String> logins;
  final VoidCallback onAdd;
  final void Function(String login) onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.person_add),
            tooltip: 'Add',
            onPressed: onAdd,
          ),
        ),
        if (logins.isEmpty) const ListTile(title: Text('None yet.')),
        for (final login in logins)
          ListTile(
            dense: true,
            title: Text(login),
            trailing: IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              tooltip: 'Remove',
              onPressed: () => onRemove(login),
            ),
          ),
      ],
    );
  }
}
