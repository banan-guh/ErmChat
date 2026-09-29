import 'dart:async';

import 'package:flutter/material.dart';
import '../../chat/chat.dart';
import '../../chat/channel/moderation.dart';
import '../../services/mod_actions.dart';
import '../../services/twitch_auth.dart';
import 'common.dart';

class UsersTab extends StatefulWidget {
  const UsersTab({
    super.key,
    required this.channel,
    required this.chat,
    required this.modActions,
    required this.auth,
    required this.onNotice,
    required this.onShowUser,
  });

  final String channel;
  final Chat chat;
  final ModActions modActions;
  final TwitchAuth auth;
  final ValueChanged<String> onNotice;
  final ValueChanged<String>? onShowUser;

  @override
  State<UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<UsersTab> {
  final _unbanPending = <String>{};
  final _flagPending = <String>{};

  Future<void> _dismissWarnings(String login) async {
    widget.chat
        .channelFor(widget.channel)
        ?.moderation
        .dismissWarningsFor(login);
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
    if (unbannedOk) {
      widget.chat.channelFor(widget.channel)?.moderation.removeBan(login);
    }
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
    if (clearedOk) {
      widget.chat
          .channelFor(widget.channel)
          ?.moderation
          .removeSuspicious(login);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mod = widget.chat.channelFor(widget.channel)?.moderation;
    return ListenableBuilder(
      listenable: mod?.modActivityVersion ?? const AlwaysStoppedAnimation(0),
      builder: (_, _) {
        // Lapsed timeouts are hidden here; the kernel prunes them on insert.
        final now = DateTime.now();
        final bans = [
          for (final ban in mod?.bans.values ?? const <BanEntry>[])
            if (ban.expiresAt?.isAfter(now) ?? true) ban,
        ];
        final warnings = mod?.warnings ?? const [];
        final flagged = mod?.suspicious.values.toList() ?? const [];
        final counts = <String, int>{};
        final latestByUser = mod?.warnedLatest() ?? const <String, WarnEntry>{};
        for (final w in warnings) {
          final lower = w.target.toLowerCase();
          counts[lower] = (counts[lower] ?? 0) + 1;
        }
        final warned = latestByUser.values.toList()
          ..sort((a, b) => b.at.compareTo(a.at));
        return ListView(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
          children: [
            // Bans seen this session; the Channel tab lists every ban.
            ModSectionHeader('Recent bans (${bans.length})'),
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
            ModSectionHeader('Warned (${warned.length})'),
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
            ModSectionHeader('Flagged (${flagged.length})'),
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
          ],
        );
      },
    );
  }

  String _banSubtitle(BanEntry ban) {
    final head = ban.expiresAt == null
        ? 'Banned'
        : 'Timeout until ${modFeedDateTime(ban.expiresAt!)}';
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
      parts.add(info.types.map(modCapitalizeToken).join(', '));
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
