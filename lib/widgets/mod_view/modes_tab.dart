import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/mod_actions.dart';
import 'dialogs.dart';
import 'scope.dart';
import 'widgets.dart';

/// Chat mode toggles from ROOMSTATE, plus Shield mode from Helix.
class ModesTab extends ModTabWidget {
  const ModesTab({
    super.key,
    required super.mod,
    required this.roomModes,
    required this.moderationActive,
  });

  /// Merged ROOMSTATE tags (`slow`, `followers-only`, `emote-only`, ...).
  final Map<String, String> roomModes;
  final bool moderationActive;

  @override
  State<ModesTab> createState() => _ModesTabState();
}

class _ModesTabState extends State<ModesTab> with ModTabState<ModesTab> {
  late final ModLoader<bool> _shield;

  /// Second taps while a picker is open no-op instead of stacking dialogs.
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _shield = loader(
      (mod) => mod.actions.getShieldMode(mod.auth, mod.channel),
      failure: mod.l10n.loadShieldFailed,
    );
  }

  Future<bool> _apply(String key, Future<ModResult> Function() call) async {
    var ok = false;
    await busy(key, () async {
      ok = await mod.report(call(), done: mod.l10n.chatModeUpdated);
    });
    return ok;
  }

  Future<T?> _pick<T>(Future<T?> Function() picker) async {
    if (_picking) return null;
    _picking = true;
    try {
      return await picker();
    } finally {
      _picking = false;
    }
  }

  Future<void> _toggleSlow(bool on) async {
    if (!on) {
      await _apply(
        'slow',
        () => mod.actions.setSlowMode(mod.auth, mod.channel, enabled: false),
      );
      return;
    }
    var seconds = await _pick(
      () => showModChoiceDialog(
        context,
        title: mod.l10n.slowModeDelay,
        options: [
          for (final s in const [3, 5, 10]) (mod.l10n.secondsCount(s), s),
          (mod.l10n.customEllipsis, -1),
        ],
      ),
    );
    if (seconds == -1 && mounted) {
      seconds = await showModNumberDialog(
        context,
        title: mod.l10n.slowModeDelay,
        label: mod.l10n.secondsRange,
        min: 3,
        max: 120,
      );
    }
    final delay = seconds;
    if (delay == null || delay < 0) return;
    await _apply(
      'slow',
      () => mod.actions.setSlowMode(
        mod.auth,
        mod.channel,
        enabled: true,
        seconds: delay,
      ),
    );
  }

  Future<void> _toggleFollowers(bool on) async {
    if (!on) {
      await _apply(
        'followers',
        () =>
            mod.actions.setFollowersMode(mod.auth, mod.channel, enabled: false),
      );
      return;
    }
    const custom = -2;
    var minutes = await _pick(
      () => showModChoiceDialog(
        context,
        title: mod.l10n.minimumFollowAge,
        options: [
          (mod.l10n.noMinimum, 0),
          (mod.l10n.minutesCount(10), 10),
          (mod.l10n.minutesCount(30), 30),
          (mod.l10n.oneHour, 60),
          (mod.l10n.oneDay, 1440),
          (mod.l10n.oneWeek, 10080),
          (mod.l10n.customEllipsis, custom),
        ],
      ),
    );
    if (minutes == custom && mounted) {
      // Twitch allows up to 3 months.
      minutes = await showModNumberDialog(
        context,
        title: mod.l10n.minimumFollowAge,
        label: mod.l10n.minutesRange,
        min: 1,
        max: 129600,
      );
    }
    final age = minutes;
    if (age == null || age < 0) return;
    await _apply(
      'followers',
      () => mod.actions.setFollowersMode(
        mod.auth,
        mod.channel,
        enabled: true,
        minutes: age == 0 ? null : age,
      ),
    );
  }

  Future<void> _toggleShield(bool on) async {
    final ok = await _apply(
      'shield',
      () => mod.actions.setShieldMode(mod.auth, mod.channel, active: on),
    );
    if (!ok || !mounted) return;
    // Optimistic flip: the status GET lags the PUT, so an immediate reload
    // can return the stale value and snap the tile back. Verify later.
    _shield.value = on;
    unawaited(
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _shield.load();
      }),
    );
  }

  Widget _toggle(
    String key,
    String label,
    IconData icon, {
    required bool on,
    required String status,
    required Future<void> Function(bool on) onToggle,
    bool ready = true,
    bool busy = false,
  }) {
    final enabled = widget.moderationActive && ready && !isBusy(key);
    return ModTile(
      icon: icon,
      label: label,
      status: status,
      active: on,
      busy: busy,
      onTap: enabled ? () => onToggle(!on) : null,
    );
  }

  Future<void> Function(bool) _flag(
    String key,
    Future<ModResult> Function(bool on) call,
  ) =>
      (on) => _apply(key, () => call(on));

  @override
  Widget build(BuildContext context) {
    final tags = widget.roomModes;
    final slow = int.tryParse(tags['slow'] ?? '') ?? 0;
    final followers = tags['followers-only'];
    final followersOn = followers != null && followers != '-1';
    bool tag(String name) => tags[name] == '1';
    String onOff(bool on) => on ? mod.l10n.on : mod.l10n.off;
    return ListenableBuilder(
      listenable: _shield,
      builder: (context, _) {
        final shield = _shield.value;
        final shieldError = _shield.error;
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            if (!widget.moderationActive)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                title: Text(mod.l10n.chatModesNeedMod),
              ),
            if (anyBusy) const LinearProgressIndicator(minHeight: 2),
            if (shieldError != null && shield == null)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                title: Text(mod.l10n.shieldLoadFailed),
                subtitle: Text(shieldError),
                trailing: TextButton(
                  onPressed: _shield.load,
                  child: Text(mod.l10n.retry),
                ),
              ),
            ModTileGrid(
              aspectRatio: 0.86,
              tiles: [
                _toggle(
                  'slow',
                  mod.l10n.slowMode,
                  Icons.hourglass_bottom_outlined,
                  on: slow > 0,
                  status: slow > 0 ? '${slow}s' : mod.l10n.off,
                  onToggle: _toggleSlow,
                ),
                _toggle(
                  'followers',
                  mod.l10n.followers,
                  Icons.favorite_outline,
                  on: followersOn,
                  status: !followersOn
                      ? mod.l10n.off
                      : followers == '0'
                      ? mod.l10n.noMinimum
                      : mod.l10n.followingMinutes(followers),
                  onToggle: _toggleFollowers,
                ),
                _toggle(
                  'emote',
                  mod.l10n.emoteOnly,
                  Icons.emoji_emotions_outlined,
                  on: tag('emote-only'),
                  status: onOff(tag('emote-only')),
                  onToggle: _flag(
                    'emote',
                    (on) => mod.actions.setEmoteOnly(
                      mod.auth,
                      mod.channel,
                      enabled: on,
                    ),
                  ),
                ),
                _toggle(
                  'subs',
                  mod.l10n.subscribers,
                  Icons.star_outline,
                  on: tag('subs-only'),
                  status: onOff(tag('subs-only')),
                  onToggle: _flag(
                    'subs',
                    (on) => mod.actions.setSubscribersOnly(
                      mod.auth,
                      mod.channel,
                      enabled: on,
                    ),
                  ),
                ),
                _toggle(
                  'unique',
                  mod.l10n.uniqueChat,
                  Icons.person_outline,
                  on: tag('r9k'),
                  status: onOff(tag('r9k')),
                  onToggle: _flag(
                    'unique',
                    (on) => mod.actions.setUniqueChat(
                      mod.auth,
                      mod.channel,
                      enabled: on,
                    ),
                  ),
                ),
                _toggle(
                  'shield',
                  mod.l10n.shieldMode,
                  Icons.shield_outlined,
                  on: shield ?? false,
                  status: shield == null ? '...' : onOff(shield),
                  ready: shield != null,
                  busy:
                      isBusy('shield') ||
                      (shield == null && shieldError == null),
                  onToggle: _toggleShield,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
