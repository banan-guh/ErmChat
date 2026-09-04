import 'package:flutter/material.dart';
import '../services/chat_store.dart';
import '../services/mod_actions.dart';
import '../services/twitch_auth.dart';

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
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(modErrorText(result))));
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

/// Mod View panel body: Queue / Modes / Mods tabs. State arrives as channel
/// lookups (not snapshots) so every [refresh] tick re-reads live values;
/// the queue additionally listens to [ChatStore.heldVersion] itself.
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
            ),
            _ModesTab(
              channel: channel,
              modActions: modActions,
              auth: auth,
              roomModes: getRoomModes(channel),
              moderationActive: moderationActive,
            ),
            _PeopleTab(channel: channel, modActions: modActions, auth: auth),
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
  });

  final String channel;
  final ChatStore store;
  final ModActions modActions;
  final TwitchAuth auth;
  final bool automodActive;
  final bool scopeReady;

  @override
  State<_QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends State<_QueueTab> {
  final _pending = <String>{};

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
        showModError(context, result);
      }
    } finally {
      _pending.remove(held.messageId);
      if (mounted) setState(() {});
    }
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
        final queue = widget.store.heldMessages[widget.channel] ?? const [];
        if (queue.isEmpty) {
          return const Center(child: Text('Queue is clear.'));
        }
        return ListView.builder(
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
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  _CategoryChip(held.category),
                ],
              ),
              subtitle: Text(held.text, maxLines: 4),
              isThreeLine: true,
              trailing: busy
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
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
                      ],
                    ),
            );
          },
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

class _ModesTab extends StatefulWidget {
  const _ModesTab({
    required this.channel,
    required this.modActions,
    required this.auth,
    required this.roomModes,
    required this.moderationActive,
  });

  final String channel;
  final ModActions modActions;
  final TwitchAuth auth;
  final Map<String, String> roomModes;
  final bool moderationActive;

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
      if (!result.ok) showModError(context, result);
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

class _PeopleTab extends StatefulWidget {
  const _PeopleTab({
    required this.channel,
    required this.modActions,
    required this.auth,
  });

  final String channel;
  final ModActions modActions;
  final TwitchAuth auth;

  @override
  State<_PeopleTab> createState() => _PeopleTabState();
}

class _PeopleTabState extends State<_PeopleTab> {
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
  void didUpdateWidget(covariant _PeopleTab oldWidget) {
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Enter a username.')));
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
      showModError(context, result);
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
      showModError(context, result);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
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
    if (_mods == null || _vips == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
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
