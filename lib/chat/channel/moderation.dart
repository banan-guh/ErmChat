import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../models/moderation_entries.dart';

// Entry types live in models so the EventSub layer and pure formatters can
// share them; re-exported here so owner consumers keep one import.
export '../../models/moderation_entries.dart';

/// Per-channel moderation state: held queue, activity feed, warnings, bans,
/// suspicious flags. Each list caps at 200.
class Moderation {
  Moderation({DateTime Function()? now}) : now = now ?? DateTime.now;

  final DateTime Function() now;

  static const maxHeldPerChannel = 200;
  static const maxActivityPerChannel = 200;
  static const maxWarningsPerChannel = 200;

  final List<HeldMessage> _held = [];
  final List<ModActivityEntry> _feed = [];
  final List<WarnEntry> _warnings = [];
  final Map<String, BanEntry> _bans = {};
  final Map<String, SuspiciousInfo> _suspicious = {};

  final ValueNotifier<int> heldVersion = ValueNotifier(0);
  final ValueNotifier<int> modActivityVersion = ValueNotifier(0);
  final ValueNotifier<int> modFeedVersion = ValueNotifier(0);
  final ValueNotifier<int> modInboxVersion = ValueNotifier(0);
  final ValueNotifier<int> modSettingsVersion = ValueNotifier(0);

  /// Bumped on EventSub subscription success which mutates no list.
  final ValueNotifier<int> version = ValueNotifier(0);

  UnmodifiableListView<HeldMessage> get held => UnmodifiableListView(_held);
  UnmodifiableListView<ModActivityEntry> get feed =>
      UnmodifiableListView(_feed);
  UnmodifiableListView<WarnEntry> get warnings =>
      UnmodifiableListView(_warnings);

  void touchInbox() => modInboxVersion.value++;
  void touchSettings() => modSettingsVersion.value++;
  void noteSubscribed() => version.value++;

  void addHeld(HeldMessage held) {
    if (_held.any((m) => m.messageId == held.messageId)) return;
    _held.insert(0, held);
    if (_held.length > maxHeldPerChannel) {
      _held.removeRange(maxHeldPerChannel, _held.length);
    }
    heldVersion.value++;
  }

  bool resolveHeld(String messageId) {
    final before = _held.length;
    _held.removeWhere((m) => m.messageId == messageId);
    if (_held.length == before) return false;
    heldVersion.value++;
    return true;
  }

  void clearHeld() {
    if (_held.isEmpty) return;
    _held.clear();
    heldVersion.value++;
  }

  void addFeed(ModActivityEntry entry) {
    _feed.insert(0, entry);
    if (_feed.length > maxActivityPerChannel) {
      _feed.removeRange(maxActivityPerChannel, _feed.length);
    }
    modFeedVersion.value++;
    modActivityVersion.value++;
  }

  void clearFeed() {
    if (_feed.isEmpty) return;
    _feed.clear();
    modFeedVersion.value++;
    modActivityVersion.value++;
  }

  void addWarning(WarnEntry warning) {
    _warnings.insert(0, warning);
    if (_warnings.length > maxWarningsPerChannel) {
      _warnings.removeRange(maxWarningsPerChannel, _warnings.length);
    }
    modActivityVersion.value++;
  }

  List<WarnEntry> warningsFor(String login) {
    final needle = login.toLowerCase();
    return [
      for (final w in _warnings)
        if (w.target.toLowerCase() == needle) w,
    ];
  }

  Map<String, WarnEntry> warnedLatest() {
    final out = <String, WarnEntry>{};
    for (final w in _warnings) {
      final key = w.target.toLowerCase();
      final prev = out[key];
      if (prev == null || w.at.isAfter(prev.at)) out[key] = w;
    }
    return out;
  }

  bool dismissWarningsFor(String login) {
    final needle = login.toLowerCase();
    final before = _warnings.length;
    _warnings.removeWhere((w) => w.target.toLowerCase() == needle);
    if (_warnings.length == before) return false;
    modActivityVersion.value++;
    return true;
  }

  int pruneExpiredBans({DateTime? at}) {
    if (_bans.isEmpty) return 0;
    final t = at ?? now();
    final expired = <String>[];
    for (final entry in _bans.entries) {
      final expires = entry.value.expiresAt;
      if (expires != null && !expires.isAfter(t)) expired.add(entry.key);
    }
    for (final key in expired) {
      _bans.remove(key);
    }
    if (expired.isNotEmpty) modActivityVersion.value++;
    return expired.length;
  }

  void putBan(BanEntry ban) {
    _bans[ban.login.toLowerCase()] = ban;
    modActivityVersion.value++;
  }

  bool removeBan(String login) {
    final removed = _bans.remove(login.toLowerCase()) != null;
    if (!removed) return false;
    modActivityVersion.value++;
    return true;
  }

  BanEntry? banFor(String login) => _bans[login.toLowerCase()];

  UnmodifiableMapView<String, BanEntry> get bans => UnmodifiableMapView(_bans);

  void noteSuspicious(SuspiciousInfo info) {
    _suspicious[info.login.toLowerCase()] = info;
    modActivityVersion.value++;
  }

  bool removeSuspicious(String login) {
    final removed = _suspicious.remove(login.toLowerCase()) != null;
    if (!removed) return false;
    modActivityVersion.value++;
    return true;
  }

  SuspiciousInfo? suspiciousFor(String login) =>
      _suspicious[login.toLowerCase()];

  UnmodifiableMapView<String, SuspiciousInfo> get suspicious =>
      UnmodifiableMapView(_suspicious);

  /// Account switch reuses the channel: drop account-scoped moderation.
  void clearForAccountSwitch() {
    var touchedFeed = false;
    var touchedActivity = false;
    if (_held.isNotEmpty) {
      _held.clear();
      heldVersion.value++;
    }
    if (_feed.isNotEmpty) {
      _feed.clear();
      touchedFeed = true;
    }
    if (_warnings.isNotEmpty) {
      _warnings.clear();
      touchedActivity = true;
    }
    if (_bans.isNotEmpty) {
      _bans.clear();
      touchedActivity = true;
    }
    if (_suspicious.isNotEmpty) {
      _suspicious.clear();
      touchedActivity = true;
    }
    if (touchedFeed) modFeedVersion.value++;
    if (touchedFeed || touchedActivity) modActivityVersion.value++;
  }

  void dispose() {
    heldVersion.dispose();
    modActivityVersion.dispose();
    modFeedVersion.dispose();
    modInboxVersion.dispose();
    modSettingsVersion.dispose();
    version.dispose();
    _held.clear();
    _feed.clear();
    _warnings.clear();
    _bans.clear();
    _suspicious.clear();
  }
}
