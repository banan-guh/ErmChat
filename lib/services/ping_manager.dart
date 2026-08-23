import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/highlight_state.dart';
import '../models/ping_rule.dart';
import '../models/twitch_message.dart';
import '../util/mention.dart';

/// Loads highlight rules from SharedPreferences and evaluates messages
/// against them (DankChat-style highlights). One instance per app, shared
/// by the live pipeline, history merge, and the retroactive login scan.
///
/// Evaluation order: self/system skip, blacklist short-circuit, then every
/// enabled rule contributes its type to the merged [HighlightState].
class PingManager extends ChangeNotifier {
  static const _prefKey = 'ping_rules_v1';
  static const _legacyAltPingsKey = 'alt_pings';

  /// Shared app-wide instance: HomeScreen evaluates against the same rules
  /// the settings screen edits. Tests construct fresh instances instead.
  static final PingManager instance = PingManager();

  /// Builtin message-rule types, in fixed UI order.
  static const builtinMessageTypes = [
    'username',
    'reply',
    'redemption',
    'firstMsg',
    'elevated',
  ];

  /// Badge presets seeded disabled with colors, like DankChat's defaults.
  static const presetBadges = <String, int>{
    'broadcaster': 0xFF4E3D14,
    'moderator': 0xFF1E4620,
    'vip': 0xFF5C1A47,
    'subscriber': 0xFF3B2E58,
    'staff': 0xFF15334A,
    'partner': 0xFF5C1A47,
    'founder': 0xFF4A2614,
    'turbo': 0xFF37474F,
  };

  List<PingRule> _rules = [];
  bool _loaded = false;
  String? _login;

  /// The active account's display name as Twitch renders it. Not persisted
  /// in the auth registry, so it is learned from our own IRC echoes.
  String? _displayName;
  final Map<String, RegExp?> _regexCache = {};

  // Reply-participation registry: recent own message ids and thread roots
  // per channel. Replies chained onto them count as mentions even without
  // an explicit name match (DankChat-style reply pings).
  static const _participationCap = 64;
  final Map<String, Set<String>> _ownMessageIds = {};
  final Map<String, Set<String>> _ownThreadRoots = {};

  bool get loaded => _loaded;
  List<PingRule> get rules => List.unmodifiable(_rules);

  void upsertRule(PingRule rule) {
    final i = _rules.indexWhere((r) => r.id == rule.id);
    if (i >= 0) {
      _rules[i] = rule;
    } else {
      _rules.add(rule);
    }
    notifyListeners();
  }

  void removeRule(String id) {
    _rules.removeWhere((r) => r.id == id);
    notifyListeners();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    // Legacy flat keyword list from before the rule engine; superseded.
    if (prefs.containsKey(_legacyAltPingsKey)) {
      await prefs.remove(_legacyAltPingsKey);
    }
    final raw = prefs.getString(_prefKey);
    if (raw == null) {
      _rules = _seedDefaults();
      await prefs.setString(_prefKey, encodeRules(_rules));
    } else {
      _rules = decodeRules(raw);
    }
    _regexCache.clear();
    _loaded = true;
    notifyListeners();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, encodeRules(_rules));
    _regexCache.clear();
    notifyListeners();
  }

  List<PingRule> _seedDefaults() => [
    for (final type in builtinMessageTypes)
      PingRule(
        id: 'builtin_$type',
        kind: PingRuleKind.message,
        type: type,
        pattern: '',
        enabled: true,
        notify: type == 'username' || type == 'reply',
      ),
    for (final entry in presetBadges.entries)
      PingRule(
        id: 'preset_badge_${entry.key}',
        kind: PingRuleKind.badge,
        pattern: entry.key,
        enabled: false,
        colorArgb: entry.value,
      ),
  ];

  /// Updates the active account used for username/reply matching. A null
  /// login (account switch / logout) also drops state learned for the
  /// departed account: its display name and reply-participation registries
  /// must not ping the new account.
  void setAccount(String? login) {
    _login = login?.toLowerCase();
    if (login == null) {
      _displayName = null;
      _ownMessageIds.clear();
      _ownThreadRoots.clear();
    }
  }

  /// Learns the display name from our own message echoes so pings on it
  /// match too (login and display name can differ).
  void setOwnDisplayName(String? displayName) {
    final dn = displayName?.trim();
    if (dn == null || dn.isEmpty) return;
    _displayName = dn;
  }

  /// Records one of our own outgoing message ids so replies chained onto it
  /// can ping via participation even without a name match.
  void registerOwnMessage(
    String channel,
    String messageId, {
    String? threadRootId,
  }) {
    if (messageId.isEmpty) return;
    final ids = _ownMessageIds.putIfAbsent(channel, () => {});
    ids.add(messageId);
    while (ids.length > _participationCap) {
      ids.remove(ids.first);
    }
    if (threadRootId != null && threadRootId.isNotEmpty) {
      final roots = _ownThreadRoots.putIfAbsent(channel, () => {});
      roots.add(threadRootId);
      while (roots.length > _participationCap) {
        roots.remove(roots.first);
      }
    }
  }

  HighlightState? evaluate(TwitchMessage msg) {
    if (!_loaded || msg.isSystem) return null;
    final selfLogin = _login;
    if (selfLogin != null &&
        selfLogin.isNotEmpty &&
        msg.login.toLowerCase() == selfLogin) {
      return null;
    }
    if (_isBlacklisted(msg.login)) return null;

    final types = <HighlightType>{};
    var notify = false;
    Color? color;

    void add(PingRule rule, HighlightType type) {
      types.add(type);
      if (rule.notify) notify = true;
      color ??= rule.colorArgb == null ? null : Color(rule.colorArgb!);
    }

    for (final rule in _rules) {
      if (!rule.enabled) continue;
      switch (rule.kind) {
        case PingRuleKind.message:
          switch (rule.type) {
            case 'username':
              if (_matchesSelfName(msg)) add(rule, HighlightType.username);
            case 'reply':
              if (_isReplyToMe(msg)) add(rule, HighlightType.reply);
            case 'custom':
              if (matchesText(rule, msg.text)) add(rule, HighlightType.custom);
            case 'redemption':
              if (msg.customRewardId != null ||
                  msg.msgId == 'highlighted-message') {
                add(rule, HighlightType.redemption);
              }
            case 'firstMsg':
              if (msg.isFirstMessage) add(rule, HighlightType.firstMsg);
            case 'elevated':
              if (msg.pinnedPaidAmount != null) {
                add(rule, HighlightType.elevated);
              }
          }
        case PingRuleKind.user:
          if (_matchesUser(rule, msg.login)) add(rule, HighlightType.user);
        case PingRuleKind.badge:
          final badges = msg.badges;
          if (badges != null &&
              badges.any(
                (b) => b.setId.toLowerCase() == rule.pattern.toLowerCase(),
              )) {
            add(rule, HighlightType.badge);
          }
        case PingRuleKind.blacklist:
          break;
      }
    }

    if (types.isEmpty) return null;
    return HighlightState(types: types, customColor: color, notify: notify);
  }

  bool _isBlacklisted(String login) {
    for (final rule in _rules) {
      if (rule.kind == PingRuleKind.blacklist &&
          rule.enabled &&
          _matchesUser(rule, login)) {
        return true;
      }
    }
    return false;
  }

  bool _matchesSelfName(TwitchMessage msg) {
    final login = _login;
    if (login == null || login.isEmpty) return false;
    if (wordMatches(msg.text, login)) return true;
    final displayName = _displayName;
    return displayName != null &&
        displayName.toLowerCase() != login &&
        wordMatches(msg.text, displayName);
  }

  bool _isReplyToMe(TwitchMessage msg) {
    final login = _login;
    if (login == null || login.isEmpty) return false;
    final replyUser = msg.replyToUser?.toLowerCase();
    if (replyUser != null && replyUser == login) return true;
    final channel = msg.channel;
    if (channel == null) return false;
    final parentId = msg.replyToParentId;
    if (parentId != null &&
        _ownMessageIds[channel]?.contains(parentId) == true) {
      return true;
    }
    final rootId = msg.replyThreadRootId;
    if (rootId != null && _ownThreadRoots[channel]?.contains(rootId) == true) {
      return true;
    }
    return false;
  }

  bool _matchesUser(PingRule rule, String login) {
    if (rule.pattern.isEmpty) return false;
    if (rule.isRegex) {
      final re = _regexFor(rule);
      if (re != null) return re.hasMatch(login);
      // Invalid regex falls back to a literal comparison below.
    }
    return rule.caseSensitive
        ? login == rule.pattern
        : login.toLowerCase() == rule.pattern.toLowerCase();
  }

  /// Pattern matching for custom keyword rules. Invalid regexes fall back
  /// to literal substring matching so a typo'd pattern never silently dies.
  bool matchesText(PingRule rule, String text) {
    if (rule.pattern.isEmpty) return false;
    if (rule.isRegex || rule.wordBoundary) {
      final re = _regexFor(rule);
      if (re != null) return re.hasMatch(text);
    }
    return rule.caseSensitive
        ? text.contains(rule.pattern)
        : text.toLowerCase().contains(rule.pattern.toLowerCase());
  }

  RegExp? _regexFor(PingRule rule) {
    final key =
        '${rule.id}\u0000${rule.pattern}\u0000${rule.caseSensitive}'
        '\u0000${rule.wordBoundary}';
    return _regexCache.putIfAbsent(key, () {
      try {
        // Whole-word literals anchor via lookaround (not \b) so patterns
        // starting or ending with non-word characters still bind correctly.
        if (!rule.isRegex && rule.wordBoundary) {
          return RegExp(
            '(?<!\\w)${RegExp.escape(rule.pattern)}(?!\\w)',
            caseSensitive: rule.caseSensitive,
          );
        }
        return RegExp(rule.pattern, caseSensitive: rule.caseSensitive);
      } on FormatException {
        return null;
      }
    });
  }
}
