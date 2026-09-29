import 'package:flutter/material.dart';

import '../../services/mod_actions.dart';
import '../../services/twitch_api.dart';
import '../../util/date_format.dart';
import '../dialogs.dart';
import 'dialogs.dart';
import 'points_section.dart';
import 'polls_predictions.dart';
import 'scope.dart';
import 'widgets.dart';

/// Channel-wide tools: stream actions for mods; bans, rosters, polls,
/// predictions, and points for the broadcaster.
class ChannelTab extends StatelessWidget {
  const ChannelTab({
    super.key,
    required this.mod,
    required this.moderationActive,
  });

  final ModContext mod;
  final bool moderationActive;

  @override
  Widget build(BuildContext context) {
    final owner = mod.isBroadcaster;
    if (!owner && !moderationActive) {
      return const ModEmpty(
        icon: Icons.shield_outlined,
        title: 'Only the broadcaster can use these tools here.',
        subtitle: 'Log in as the broadcaster to manage rosters and stream.',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
      children: [
        if (owner) ...[
          BannedSection(mod: mod),
          RosterSection(mod: mod, moderators: true),
          RosterSection(mod: mod, moderators: false),
        ],
        const ModSectionHeader('Stream'),
        StreamActions(mod: mod),
        if (owner) ...[
          const ModSectionHeader('Polls'),
          PollsSection(mod: mod),
          const ModSectionHeader('Predictions'),
          PredictionsSection(mod: mod),
          const ModSectionHeader('Points'),
          PointsSection(mod: mod),
        ],
      ],
    );
  }
}

/// Every ban in the channel, from Helix.
class BannedSection extends ModTabWidget {
  const BannedSection({super.key, required super.mod});

  @override
  State<BannedSection> createState() => _BannedSectionState();
}

class _BannedSectionState extends State<BannedSection>
    with ModTabState<BannedSection> {
  late final ModLoader<List<BannedUser>> _banned;

  @override
  void initState() {
    super.initState();
    _banned = loader(
      (mod) => mod.actions.getBannedUsers(mod.auth, mod.channel),
      failure: 'Could not load the banned list.',
    );
  }

  Future<void> _unban(String login) => busy(login.toLowerCase(), () async {
    final ok = await mod.report(
      mod.actions.unbanUser(mod.auth, mod.channel, login: login),
      done: 'Unbanned $login.',
    );
    if (!ok) return;
    final key = login.toLowerCase();
    _banned.value = [
      for (final ban in _banned.value ?? const <BannedUser>[])
        if (ban.userLogin.toLowerCase() != key) ban,
    ];
    await _banned.load();
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListenableBuilder(
          listenable: _banned,
          builder: (_, _) =>
              ModSectionHeader('Banned (${_banned.value?.length ?? 0})'),
        ),
        ModLoadView(
          loader: _banned,
          inline: true,
          isEmpty: (banned) => banned.isEmpty,
          empty: const ListTile(title: Text('No bans yet.')),
          builder: (context, banned) => Column(
            children: [
              for (final ban in banned)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  title: Text(ban.userLogin),
                  subtitle: Text(_bannedSubtitle(ban)),
                  trailing: isBusy(ban.userLogin.toLowerCase())
                      ? const ModSpinner()
                      : OutlinedButton(
                          onPressed: () => _unban(ban.userLogin),
                          child: const Text('Unban'),
                        ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

String _bannedSubtitle(BannedUser ban) {
  final expires = ban.expiresAt;
  final until = expires == null ? null : DateTime.tryParse(expires)?.toLocal();
  return [
    expires == null
        ? 'Banned'
        : until == null
        ? 'Timed out (expiry unknown)'
        : 'Timeout until ${formatYmdHm(until)}',
    if (ban.reason?.isNotEmpty ?? false) '"${ban.reason}"',
    if (ban.moderatorName?.isNotEmpty ?? false) 'by ${ban.moderatorName}',
  ].join(' · ');
}

/// Moderator or VIP roster with add and remove. Broadcaster-only Helix.
class RosterSection extends ModTabWidget {
  const RosterSection({
    super.key,
    required super.mod,
    required this.moderators,
  });

  final bool moderators;

  @override
  State<RosterSection> createState() => _RosterSectionState();
}

class _RosterSectionState extends State<RosterSection>
    with ModTabState<RosterSection> {
  late final ModLoader<List<String>> _logins;

  bool get _mods => widget.moderators;
  String get _role => _mods ? 'moderator' : 'VIP';

  @override
  void initState() {
    super.initState();
    _logins = loader(
      (mod) => _mods
          ? mod.actions.getModerators(mod.auth, mod.channel)
          : mod.actions.getVips(mod.auth, mod.channel),
      failure: _mods ? 'Could not load moderators.' : 'Could not load VIPs.',
    );
  }

  Future<ModResult> _set(String login, {required bool add}) => _mods
      ? mod.actions.setModerator(mod.auth, mod.channel, login: login, add: add)
      : mod.actions.setVip(mod.auth, mod.channel, login: login, add: add);

  Future<void> _add() async {
    final login = await showModTextDialog(
      context,
      title: _mods ? 'Add moderator' : 'Add VIP',
      label: 'Username',
      confirmLabel: 'Add',
    );
    if (login == null) return;
    if (await mod.report(_set(login, add: true))) await _logins.load();
  }

  Future<void> _remove(String login) async {
    final key = login.toLowerCase();
    if (isBusy(key)) return;
    final confirmed = await confirmDialog(
      context,
      title: 'Remove $login?',
      message: 'This removes $_role status from $login.',
      confirmLabel: 'Remove',
      cancelLabel: 'Back',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await busy(key, () async {
      final ok = await mod.report(
        _set(login, add: false),
        done: 'Removed $login.',
      );
      if (ok) await _logins.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _logins,
      builder: (context, _) {
        final count = _logins.value?.length;
        final title = _mods ? 'Moderators' : 'VIPs';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.only(left: 16, right: 8),
              title: ModSectionHeaderText(
                count == null ? title : '$title ($count)',
              ),
              trailing: FilledButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.person_add, size: 18),
                label: const Text('Add'),
              ),
            ),
            ModLoadView(
              loader: _logins,
              inline: true,
              isEmpty: (logins) => logins.isEmpty,
              empty: const ListTile(title: Text('None yet.')),
              builder: (context, logins) => Column(
                children: [
                  for (final login in logins)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 2,
                      ),
                      title: Text(login),
                      trailing: isBusy(login.toLowerCase())
                          ? const ModSpinner()
                          : IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              tooltip: 'Remove',
                              onPressed: () => _remove(login),
                            ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Raid, commercial, marker, announcement, clear, and shoutout.
class StreamActions extends ModTabWidget {
  const StreamActions({super.key, required super.mod});

  @override
  State<StreamActions> createState() => _StreamActionsState();
}

class _StreamActionsState extends State<StreamActions>
    with ModTabState<StreamActions> {
  Future<void> _raid() async {
    final login = await showModTextDialog(
      context,
      title: 'Raid a channel?',
      label: 'Username',
      confirmLabel: 'Raid',
    );
    if (login == null) return;
    await mod.report(
      mod.actions.startRaid(mod.auth, mod.channel, login: login),
      done: 'Raid started.',
    );
  }

  Future<void> _unraid() async {
    final confirmed = await confirmDialog(
      context,
      title: 'Cancel raid?',
      message: 'This cancels the pending raid.',
      confirmLabel: 'Confirm',
      destructive: true,
    );
    if (!confirmed) return;
    await busy(
      'unraid',
      () => mod.report(
        mod.actions.cancelRaid(mod.auth, mod.channel),
        done: 'Raid cancelled.',
      ),
    );
  }

  Future<void> _commercial() async {
    final length = await showModChoiceDialog(
      context,
      title: 'Commercial length',
      options: [
        for (final seconds in const [30, 60, 90, 120, 150, 180])
          ('${seconds}s', seconds),
      ],
    );
    if (length == null) return;
    await mod.report(
      mod.actions.startCommercial(mod.auth, mod.channel, length: length),
      done: 'Commercial running.',
    );
  }

  Future<void> _marker() async {
    final description = await showModTextDialog(
      context,
      title: 'Add stream marker',
      label: 'Description (optional)',
      confirmLabel: 'Add',
      allowEmpty: true,
    );
    if (description == null) return;
    await mod.report(
      mod.actions.createMarker(
        mod.auth,
        mod.channel,
        description: description.isEmpty ? null : description,
      ),
      done: 'Marker added.',
    );
  }

  Future<void> _announce() async {
    final message = await showModTextDialog(
      context,
      title: 'Send announcement',
      label: 'Message',
      confirmLabel: 'Send',
    );
    if (message == null) return;
    await busy(
      'announce',
      () => mod.report(
        mod.actions.sendAnnouncement(mod.auth, mod.channel, message: message),
        done: 'Announcement sent.',
      ),
    );
  }

  Future<void> _clear() async {
    final confirmed = await confirmDialog(
      context,
      title: 'Clear chat?',
      message: 'This clears all chat messages.',
      confirmLabel: 'Confirm',
      destructive: true,
    );
    if (!confirmed) return;
    await busy(
      'clear',
      () => mod.report(
        mod.actions.clearChat(mod.auth, mod.channel),
        done: 'Chat cleared.',
      ),
    );
  }

  Future<void> _shoutout() async {
    final login = await showModTextDialog(
      context,
      title: 'Shoutout a channel?',
      label: 'Username',
      confirmLabel: 'Shoutout',
    );
    if (login == null) return;
    await busy(
      'shoutout',
      () => mod.report(
        mod.actions.sendShoutout(mod.auth, mod.channel, login: login),
        done: 'Shoutout sent.',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Raids and commercials are broadcaster-only Helix (the broadcaster id
    // must match the token): mods get a dimmed tile that explains.
    Widget tile(
      String label,
      IconData icon,
      VoidCallback action, {
      String? busyKey,
      bool ownerOnly = false,
    }) {
      final gated = ownerOnly && !mod.isBroadcaster;
      return ModTile(
        icon: icon,
        label: label,
        dimmed: gated,
        busy: busyKey != null && isBusy(busyKey),
        onTap: anyBusy
            ? null
            : gated
            ? () => mod.notify('Only broadcasters can use this.')
            : action,
      );
    }

    return ModTileGrid(
      aspectRatio: 0.92,
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      tiles: [
        tile(
          'Start raid',
          Icons.flight_takeoff_outlined,
          _raid,
          ownerOnly: true,
        ),
        tile(
          'Cancel raid',
          Icons.flight_land_outlined,
          _unraid,
          busyKey: 'unraid',
          ownerOnly: true,
        ),
        tile(
          'Commercial',
          Icons.monetization_on_outlined,
          _commercial,
          ownerOnly: true,
        ),
        tile('Add marker', Icons.bookmark_add_outlined, _marker),
        tile(
          'Announce',
          Icons.campaign_outlined,
          _announce,
          busyKey: 'announce',
        ),
        tile(
          'Clear chat',
          Icons.delete_sweep_outlined,
          _clear,
          busyKey: 'clear',
        ),
        tile(
          'Shoutout',
          Icons.record_voice_over_outlined,
          _shoutout,
          busyKey: 'shoutout',
        ),
      ],
    );
  }
}
