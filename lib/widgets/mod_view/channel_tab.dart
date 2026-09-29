import 'dart:async';

import 'package:flutter/material.dart';
import '../../chat/chat.dart';
import '../../services/mod_actions.dart';
import '../../services/twitch_api.dart';
import '../../services/twitch_auth.dart';
import '../dialogs.dart';
import 'common.dart';
import 'polls_predictions.dart';
import 'points_section.dart';

class ChannelTab extends StatelessWidget {
  const ChannelTab({
    super.key,
    required this.channel,
    required this.chat,
    required this.modActions,
    required this.auth,
    required this.onNotice,
    required this.isBroadcaster,
    required this.isModerationActive,
  });

  final String channel;
  final Chat chat;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;
  final bool isBroadcaster;
  final bool isModerationActive;

  @override
  Widget build(BuildContext context) {
    if (!isBroadcaster && !isModerationActive) {
      return const ModEmpty(
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
          const ModSectionHeader('Stream'),
          _StreamActions(
            channel: channel,
            modActions: modActions,
            auth: auth,
            onNotice: onNotice,
            isBroadcaster: isBroadcaster,
          ),
        ],
        if (isBroadcaster) ...[
          const ModSectionHeader('Polls'),
          PollsSection(
            channel: channel,
            modActions: modActions,
            auth: auth,
            onNotice: onNotice,
          ),
          const ModSectionHeader('Predictions'),
          PredictionsSection(
            channel: channel,
            modActions: modActions,
            auth: auth,
            onNotice: onNotice,
          ),
          const ModSectionHeader('Points'),
          PointsSection(
            channel: channel,
            chat: chat,
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

class _BannedManagerState extends State<_BannedManager>
    with ModTabLoad<_BannedManager> {
  @override
  ModActions get modActions => widget.modActions;
  @override
  ValueChanged<String> get onNotice => widget.onNotice;

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
    final outcome = await guardedLoad<List<BannedUser>>(
      gen: gen,
      currentGen: () => _loadGen,
      background: _banned != null,
      request: () =>
          widget.modActions.getBannedUsers(widget.auth, widget.channel),
      fallbackError: 'Could not load the banned list.',
    );
    if (outcome == null) return;
    setState(() {
      _error = outcome.error;
      if (outcome.error == null) _banned = outcome.value;
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
          : 'Timeout until ${modFeedDateTime(dt)}';
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
        ModSectionHeader('Banned (${banned?.length ?? 0})'),
        if (_error != null && banned == null)
          ModError(message: _error!, onRetry: _load)
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

  Future<void> _raid(BuildContext context) async {
    final login = await showModTextDialog(
      context,
      title: 'Raid a channel?',
      label: 'Username',
      confirmLabel: 'Raid',
    );
    if (login == null || !context.mounted) return;
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
    final confirmed = await confirmDialog(
      context,
      title: 'Clear chat?',
      message: 'This clears all chat messages.',
      confirmLabel: 'Confirm',
      destructive: true,
    );
    if (!confirmed) return;
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
    final confirmed = await confirmDialog(
      context,
      title: 'Cancel raid?',
      message: 'This cancels the pending raid.',
      confirmLabel: 'Confirm',
      destructive: true,
    );
    if (!confirmed) return;
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
    final actions = widget.modActions;
    Future<(List<String>, String?)> fetch(
      Future<List<String>> Function(TwitchAuth, String) request,
      String fallback,
    ) => actions.twitchApi.isolateErrors(() async {
      try {
        final logins = await request(widget.auth, widget.channel);
        if (actions.twitchApi.lastErrorStatus == null) return (logins, null);
        return (const <String>[], actions.failureReason());
      } catch (_) {
        return (const <String>[], fallback);
      }
    });
    final ((mods, modsError), (vips, vipsError)) = await (
      fetch(actions.getModerators, 'Could not load moderators.'),
      fetch(actions.getVips, 'Could not load VIPs.'),
    ).wait;
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
    final confirm = await confirmDialog(
      context,
      title: 'Remove $login?',
      message: moderator
          ? 'This removes moderator status from $login.'
          : 'This removes VIP status from $login.',
      confirmLabel: 'Remove',
      cancelLabel: 'Back',
      destructive: true,
    );
    if (!confirm || !mounted) {
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
      return ModError(
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
