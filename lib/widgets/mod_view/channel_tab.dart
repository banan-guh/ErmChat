import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/mod_actions.dart';
import '../../services/twitch_api.dart';
import '../../util/date_format.dart';
import '../dialogs.dart';
import 'dialogs.dart';
import 'points_section.dart';
import 'polls_predictions.dart';
import 'scope.dart';
import 'widgets.dart';
import '../glass_chrome.dart';

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
      return ModEmpty(
        icon: Icons.shield_outlined,
        title: mod.l10n.modOnlyBroadcaster,
        subtitle: mod.l10n.modOnlyBroadcasterHint,
      );
    }
    return ListView(
      padding: glassListPadding(
        context,
        const EdgeInsets.fromLTRB(8, 4, 8, 24),
      ),
      children: [
        if (owner) ...[
          BannedSection(mod: mod),
          RosterSection(mod: mod, moderators: true),
          RosterSection(mod: mod, moderators: false),
        ],
        ModSectionHeader(mod.l10n.modSectionStream),
        StreamActions(mod: mod),
        if (owner) ...[
          ModSectionHeader(mod.l10n.modSectionPolls),
          PollsSection(mod: mod),
          ModSectionHeader(mod.l10n.modSectionPredictions),
          PredictionsSection(mod: mod),
          ModSectionHeader(mod.l10n.modSectionPoints),
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
      failure: mod.l10n.loadBannedFailed,
    );
  }

  Future<void> _unban(String login) => busy(login.toLowerCase(), () async {
    final ok = await mod.report(
      mod.actions.unbanUser(mod.auth, mod.channel, login: login),
      done: mod.l10n.unbannedUser(login),
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
          builder: (_, _) => ModSectionHeader(
            mod.l10n.bannedCount(_banned.value?.length ?? 0),
          ),
        ),
        ModLoadView(
          loader: _banned,
          inline: true,
          isEmpty: (banned) => banned.isEmpty,
          empty: ListTile(title: Text(mod.l10n.noBansYet)),
          builder: (context, banned) => Column(
            children: [
              for (final ban in banned)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  title: Text(ban.userLogin),
                  subtitle: Text(_bannedSubtitle(mod.l10n, ban)),
                  trailing: isBusy(ban.userLogin.toLowerCase())
                      ? const ModSpinner()
                      : OutlinedButton(
                          onPressed: () => _unban(ban.userLogin),
                          child: Text(mod.l10n.unban),
                        ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

String _bannedSubtitle(AppLocalizations l, BannedUser ban) {
  final expires = ban.expiresAt;
  final until = expires == null ? null : DateTime.tryParse(expires)?.toLocal();
  return [
    expires == null
        ? l.banned
        : until == null
        ? l.timedOutUnknown
        : l.timeoutUntil(formatYmdHm(until)),
    if (ban.reason?.isNotEmpty ?? false) '"${ban.reason}"',
    if (ban.moderatorName?.isNotEmpty ?? false)
      l.byModerator(ban.moderatorName!),
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
  @override
  void initState() {
    super.initState();
    _logins = loader(
      (mod) => _mods
          ? mod.actions.getModerators(mod.auth, mod.channel)
          : mod.actions.getVips(mod.auth, mod.channel),
      failure: _mods ? mod.l10n.loadModeratorsFailed : mod.l10n.loadVipsFailed,
    );
  }

  Future<ModResult> _set(String login, {required bool add}) => _mods
      ? mod.actions.setModerator(mod.auth, mod.channel, login: login, add: add)
      : mod.actions.setVip(mod.auth, mod.channel, login: login, add: add);

  Future<void> _add() async {
    final login = await showModTextDialog(
      context,
      title: _mods ? mod.l10n.addModerator : mod.l10n.addVip,
      label: mod.l10n.username,
      confirmLabel: mod.l10n.add,
    );
    if (login == null) return;
    if (await mod.report(_set(login, add: true))) await _logins.load();
  }

  Future<void> _remove(String login) async {
    final key = login.toLowerCase();
    if (isBusy(key)) return;
    final confirmed = await confirmDialog(
      context,
      title: mod.l10n.removeUserTitle(login),
      message: _mods
          ? mod.l10n.removeModeratorMessage(login)
          : mod.l10n.removeVipMessage(login),
      confirmLabel: mod.l10n.remove,
      cancelLabel: mod.l10n.back,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await busy(key, () async {
      final ok = await mod.report(
        _set(login, add: false),
        done: mod.l10n.removedUser(login),
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
        final title = _mods ? mod.l10n.moderators : mod.l10n.vips;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.only(left: 16, right: 8),
              title: ModSectionHeaderText(
                count == null ? title : mod.l10n.titleWithCount(title, count),
              ),
              trailing: FilledButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.person_add, size: 18),
                label: Text(mod.l10n.add),
              ),
            ),
            ModLoadView(
              loader: _logins,
              inline: true,
              isEmpty: (logins) => logins.isEmpty,
              empty: ListTile(title: Text(mod.l10n.noneYet)),
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
                              tooltip: mod.l10n.remove,
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
      title: mod.l10n.raidChannelTitle,
      label: mod.l10n.username,
      confirmLabel: mod.l10n.raid,
    );
    if (login == null) return;
    await mod.report(
      mod.actions.startRaid(mod.auth, mod.channel, login: login),
      done: mod.l10n.raidStarted,
    );
  }

  Future<void> _unraid() async {
    final confirmed = await confirmDialog(
      context,
      title: mod.l10n.cancelRaidTitle,
      message: mod.l10n.cancelRaidMessage,
      confirmLabel: mod.l10n.confirm,
      destructive: true,
    );
    if (!confirmed) return;
    await busy(
      'unraid',
      () => mod.report(
        mod.actions.cancelRaid(mod.auth, mod.channel),
        done: mod.l10n.raidCancelled,
      ),
    );
  }

  Future<void> _commercial() async {
    final length = await showModChoiceDialog(
      context,
      title: mod.l10n.commercialLength,
      options: [
        for (final seconds in const [30, 60, 90, 120, 150, 180])
          ('${seconds}s', seconds),
      ],
    );
    if (length == null) return;
    await mod.report(
      mod.actions.startCommercial(mod.auth, mod.channel, length: length),
      done: mod.l10n.commercialRunning,
    );
  }

  Future<void> _marker() async {
    final description = await showModTextDialog(
      context,
      title: mod.l10n.addStreamMarker,
      label: mod.l10n.descriptionOptional,
      confirmLabel: mod.l10n.add,
      allowEmpty: true,
    );
    if (description == null) return;
    await mod.report(
      mod.actions.createMarker(
        mod.auth,
        mod.channel,
        description: description.isEmpty ? null : description,
      ),
      done: mod.l10n.markerAdded,
    );
  }

  Future<void> _announce() async {
    final message = await showModTextDialog(
      context,
      title: mod.l10n.sendAnnouncement,
      label: mod.l10n.message,
      confirmLabel: mod.l10n.send,
    );
    if (message == null) return;
    await busy(
      'announce',
      () => mod.report(
        mod.actions.sendAnnouncement(mod.auth, mod.channel, message: message),
        done: mod.l10n.announcementSent,
      ),
    );
  }

  Future<void> _clear() async {
    final confirmed = await confirmDialog(
      context,
      title: mod.l10n.clearChatTitle,
      message: mod.l10n.clearChatMessage,
      confirmLabel: mod.l10n.confirm,
      destructive: true,
    );
    if (!confirmed) return;
    await busy(
      'clear',
      () => mod.report(
        mod.actions.clearChat(mod.auth, mod.channel),
        done: mod.l10n.chatCleared,
      ),
    );
  }

  Future<void> _shoutout() async {
    final login = await showModTextDialog(
      context,
      title: mod.l10n.shoutoutTitle,
      label: mod.l10n.username,
      confirmLabel: mod.l10n.shoutout,
    );
    if (login == null) return;
    await busy(
      'shoutout',
      () => mod.report(
        mod.actions.sendShoutout(mod.auth, mod.channel, login: login),
        done: mod.l10n.shoutoutSent,
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
            ? () => mod.notify(mod.l10n.onlyBroadcasters)
            : action,
      );
    }

    return ModTileGrid(
      aspectRatio: 0.92,
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      tiles: [
        tile(
          mod.l10n.startRaid,
          Icons.flight_takeoff_outlined,
          _raid,
          ownerOnly: true,
        ),
        tile(
          mod.l10n.cancelRaid,
          Icons.flight_land_outlined,
          _unraid,
          busyKey: 'unraid',
          ownerOnly: true,
        ),
        tile(
          mod.l10n.commercial,
          Icons.monetization_on_outlined,
          _commercial,
          ownerOnly: true,
        ),
        tile(mod.l10n.addMarker, Icons.bookmark_add_outlined, _marker),
        tile(
          mod.l10n.announce,
          Icons.campaign_outlined,
          _announce,
          busyKey: 'announce',
        ),
        tile(
          mod.l10n.clearChat,
          Icons.delete_sweep_outlined,
          _clear,
          busyKey: 'clear',
        ),
        tile(
          mod.l10n.shoutout,
          Icons.record_voice_over_outlined,
          _shoutout,
          busyKey: 'shoutout',
        ),
      ],
    );
  }
}
