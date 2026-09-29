import 'package:flutter/material.dart';

import '../../chat/channel/moderation.dart';
import '../../util/date_format.dart';
import 'scope.dart';
import 'widgets.dart';

/// Bans, warnings, and flagged users seen this session.
class UsersTab extends ModTabWidget {
  const UsersTab({super.key, required super.mod});

  @override
  State<UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<UsersTab> with ModTabState<UsersTab> {
  Future<void> _unban(String login) =>
      busy('unban:${login.toLowerCase()}', () async {
        final ok = await mod.report(
          mod.actions.unbanUser(mod.auth, mod.channel, login: login),
          done: 'Unbanned $login.',
        );
        if (ok) mod.moderation?.removeBan(login);
      });

  Future<void> _clearFlag(String login) => busy(
    'flag:${login.toLowerCase()}',
    () async {
      final ok = await mod.report(
        mod.actions.clearSuspiciousStatus(mod.auth, mod.channel, login: login),
        done: 'Cleared flag for $login.',
      );
      if (ok) mod.moderation?.removeSuspicious(login);
    },
  );

  void _dismissWarnings(String login) {
    mod.moderation?.dismissWarningsFor(login);
    mod.notify('Dismissed warnings for $login.');
  }

  Widget _row({
    required String login,
    required String subtitle,
    required Widget trailing,
    String? busyKey,
  }) {
    final busy = busyKey != null && isBusy(busyKey);
    final showUser = mod.showUser;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text(login),
      subtitle: Text(subtitle),
      onTap: showUser == null || busy ? null : () => showUser(login),
      trailing: busy ? const ModSpinner() : trailing,
    );
  }

  @override
  Widget build(BuildContext context) {
    final moderation = mod.moderation;
    if (moderation == null) return const SizedBox.shrink();
    return ValueListenableBuilder<int>(
      valueListenable: moderation.modActivityVersion,
      builder: (context, _, _) {
        // Lapsed timeouts are hidden here; the kernel prunes them on insert.
        final now = DateTime.now();
        final bans = [
          for (final ban in moderation.bans.values)
            if (ban.expiresAt?.isAfter(now) ?? true) ban,
        ];
        final warnCounts = <String, int>{};
        for (final w in moderation.warnings) {
          final key = w.target.toLowerCase();
          warnCounts[key] = (warnCounts[key] ?? 0) + 1;
        }
        final warned = moderation.warnedLatest().values.toList()
          ..sort((a, b) => b.at.compareTo(a.at));
        final flagged = moderation.suspicious.values.toList();
        return ListView(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
          children: [
            // Bans seen this session; the Channel tab lists every ban.
            ModSectionHeader('Recent bans (${bans.length})'),
            if (bans.isEmpty) const ListTile(title: Text('No bans yet.')),
            for (final ban in bans)
              _row(
                login: ban.login,
                subtitle: _banSubtitle(ban),
                busyKey: 'unban:${ban.login.toLowerCase()}',
                trailing: OutlinedButton(
                  onPressed: () => _unban(ban.login),
                  child: const Text('Unban'),
                ),
              ),
            ModSectionHeader('Warned (${warned.length})'),
            if (warned.isEmpty) const ListTile(title: Text('No warnings yet.')),
            for (final w in warned)
              _row(
                login: w.target,
                subtitle: _warnSubtitle(
                  warnCounts[w.target.toLowerCase()] ?? 1,
                  w,
                ),
                trailing: TextButton(
                  onPressed: () => _dismissWarnings(w.target),
                  child: const Text('Dismiss'),
                ),
              ),
            ModSectionHeader('Flagged (${flagged.length})'),
            if (flagged.isEmpty)
              const ListTile(title: Text('No flagged users.')),
            for (final info in flagged)
              _row(
                login: info.login,
                subtitle: _suspiciousSubtitle(info),
                busyKey: 'flag:${info.login.toLowerCase()}',
                trailing: OutlinedButton(
                  onPressed: () => _clearFlag(info.login),
                  child: const Text('Clear'),
                ),
              ),
          ],
        );
      },
    );
  }
}

String _banSubtitle(BanEntry ban) {
  final expires = ban.expiresAt;
  return [
    expires == null ? 'Banned' : 'Timeout until ${formatYmdHm(expires)}',
    if (ban.reason?.isNotEmpty ?? false) '"${ban.reason}"',
    if (ban.moderator.isNotEmpty) 'by ${ban.moderator}',
  ].join(' · ');
}

String _warnSubtitle(int count, WarnEntry latest) {
  final head = count == 1 ? '1 warning' : '$count warnings';
  final reason = latest.reason;
  return reason == null || reason.isEmpty ? head : '$head · "$reason"';
}

String _suspiciousSubtitle(SuspiciousInfo info) {
  final evasion = info.banEvasion;
  final shared = info.sharedBanChannelIds.length;
  return [
    _suspiciousTitle(info.status),
    if (evasion != null && evasion.isNotEmpty)
      '$evasion ban evasion likelihood',
    if (shared > 0) 'shared bans in $shared channel${shared == 1 ? '' : 's'}',
    if (info.types.isNotEmpty) info.types.map(_titleCase).join(', '),
  ].join(' · ');
}

String _suspiciousTitle(String status) {
  final lower = status.toLowerCase();
  if (lower.contains('restrict')) return 'Restricted';
  if (lower.contains('monitor')) return 'Monitored';
  if (lower.isEmpty) return 'Flagged';
  return lower[0].toUpperCase() + lower.substring(1);
}

/// `manually_added` -> `Manually Added`.
String _titleCase(String token) => [
  for (final w in token.split('_'))
    if (w.isNotEmpty) '${w[0].toUpperCase()}${w.substring(1)}',
].join(' ');
