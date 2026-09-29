import 'dart:async';

import 'package:flutter/material.dart';
import '../../services/mod_actions.dart';
import '../../services/twitch_auth.dart';
import 'common.dart';

class ModesTab extends StatefulWidget {
  const ModesTab({
    super.key,
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
  State<ModesTab> createState() => _ModesTabState();
}

class _ModesTabState extends State<ModesTab> {
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
  void didUpdateWidget(covariant ModesTab oldWidget) {
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
        ('3 seconds', 3),
        ('5 seconds', 5),
        ('10 seconds', 10),
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
        // Twitch allows up to 3 months.
        picked = await _pickCustomInt(
          title: 'Minimum follow age',
          label: 'Minutes (1-129600)',
          min: 1,
          max: 129600,
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
