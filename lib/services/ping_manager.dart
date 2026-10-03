import 'package:flutter/foundation.dart';

import '../color_utils.dart' show Color;
import '../models/highlight_state.dart';
import '../models/ping_rule.dart';
import '../models/twitch_message.dart';
import '../util/mention.dart';
import '../util/prefs.dart';

/// Evaluates highlight rules (DankChat-style): skip self/system, blacklist, then rules.
class PingManager extends ChangeNotifier {
  /// Shared instance; tests construct fresh ones.
  static final PingManager instance = PingManager();

  /// Built-in message-rule types (fixed UI order).
  static const builtinMessageTypes = [
    'username',
    'reply',
    'thread',
    'redemption',
    'firstMsg',
    'elevated',
  ];

  /// Badge presets (seeded disabled, DankChat-style defaults).
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

  /// Active display name (learned from IRC echoes, not persisted).
  String? _displayName;
  final Map<String, RegExp> _regexCache = {};
  final Map<String, String> _lowerPatternCache = {};

  // Reply-participation: own message ids + thread roots (DankChat-style).
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
    _lowerPatternCache.clear();
    notifyListeners();
  }

  void removeRule(String id) {
    _rules.removeWhere((r) => r.id == id);
    _lowerPatternCache.clear();
    notifyListeners();
  }

  Future<void> load() async {
    final prefs = await Prefs.load();
    // Legacy: remove old alt_pings key.
    if (prefs.hasLegacyAltPings) {
      await prefs.removeLegacyAltPings();
    }
    final raw = prefs.pingRules;
    if (raw == null) {
      _rules = _seedDefaults();
      await prefs.setPingRules(encodeRules(_rules));
    } else {
      _rules = decodeRules(raw);
      _splitThreadRule();
    }
    _regexCache.clear();
    _lowerPatternCache.clear();
    _loaded = true;
    notifyListeners();
  }

  Future<void> save() async {
    final prefs = await Prefs.load();
    await prefs.setPingRules(encodeRules(_rules));
    _regexCache.clear();
    _lowerPatternCache.clear();
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
        notify: type == 'username' || type == 'reply' || type == 'thread',
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

  /// Saved rules predate the thread builtin, when the reply rule covered
  /// threads too; seed it from the reply rule so nothing changes on upgrade.
  void _splitThreadRule() {
    if (_rules.any((r) => r.id == 'builtin_thread')) return;
    final i = _rules.indexWhere((r) => r.id == 'builtin_reply');
    final reply = i < 0 ? null : _rules[i];
    _rules.insert(
      i + 1,
      PingRule(
        id: 'builtin_thread',
        kind: PingRuleKind.message,
        type: 'thread',
        enabled: reply?.enabled ?? true,
        notify: reply?.notify ?? true,
        colorArgb: reply?.colorArgb,
      ),
    );
  }

  /// Sets account for matching; null clears departed account's state.
  void setAccount(String? login) {
    _login = login?.toLowerCase();
    if (login == null) {
      _displayName = null;
      _ownMessageIds.clear();
      _ownThreadRoots.clear();
    }
  }

  /// Learns display name from own IRC echoes for ping matching.
  void setOwnDisplayName(String? displayName) {
    final dn = displayName?.trim();
    if (dn == null || dn.isEmpty) return;
    _displayName = dn;
  }

  /// Registers own message id for reply-participation pings.
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
    final isSelf =
        selfLogin != null &&
        selfLogin.isNotEmpty &&
        msg.login.toLowerCase() == selfLogin;
    if (_isBlacklisted(msg.login)) return null;

    final types = <HighlightType>{};
    var notify = false;
    Color? color;
    String? lowerText;

    void add(PingRule rule, HighlightType type) {
      types.add(type);
      if (rule.notify && rule.mention) notify = true;
      color ??= rule.colorArgb == null ? null : Color(rule.colorArgb!);
    }

    for (final rule in _rules) {
      if (!rule.enabled) continue;
      switch (rule.kind) {
        case PingRuleKind.message:
          switch (rule.type) {
            case 'username':
              if (!isSelf && _matchesSelfName(msg)) {
                add(rule, HighlightType.username);
              }
            case 'reply':
              if (!isSelf && _isReplyToMe(msg)) {
                add(rule, HighlightType.reply);
              }
            case 'thread':
              if (!isSelf && _isInMyThread(msg)) {
                add(rule, HighlightType.reply);
              }
            case 'custom':
              lowerText ??= msg.text.toLowerCase();
              if (matchesText(rule, msg.text, lowerText)) {
                add(
                  rule,
                  rule.mention ? HighlightType.custom : HighlightType.tint,
                );
              }
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
          if (_matchesUser(rule, msg.login)) {
            add(rule, rule.mention ? HighlightType.user : HighlightType.tint);
          }
        case PingRuleKind.badge:
          final badges = msg.badges;
          if (badges != null &&
              badges.any((b) => b.setId.toLowerCase() == _lowerPattern(rule))) {
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
    return parentId != null &&
        _ownMessageIds[channel]?.contains(parentId) == true;
  }

  /// A reply in a thread we started or posted in, to anyone.
  bool _isInMyThread(TwitchMessage msg) {
    final channel = msg.channel;
    final rootId = msg.replyThreadRootId;
    if (channel == null || rootId == null) return false;
    return _ownThreadRoots[channel]?.contains(rootId) == true ||
        _ownMessageIds[channel]?.contains(rootId) == true;
  }

  bool _matchesUser(PingRule rule, String login) =>
      rule.pattern.isNotEmpty && login.toLowerCase() == _lowerPattern(rule);

  /// Plain-text keyword matching, case-insensitive. [lowerText] is a
  /// precomputed lowercase form of [text] shared across rules.
  bool matchesText(PingRule rule, String text, [String? lowerText]) {
    if (rule.pattern.isEmpty) return false;
    if (rule.wordBoundary) {
      return _regexCache
          .putIfAbsent(
            '${rule.id}\u0000${rule.pattern}',
            () => keywordRegExp(rule.pattern, wholeWord: true),
          )
          .hasMatch(text);
    }
    return (lowerText ?? text.toLowerCase()).contains(_lowerPattern(rule));
  }

  /// Regex equivalent of a keyword rule, for callers that need match ranges.
  /// Whole word uses lookarounds so patterns like `:)` still anchor.
  static RegExp keywordRegExp(String pattern, {required bool wholeWord}) {
    final escaped = RegExp.escape(pattern);
    return RegExp(
      wholeWord ? '(?<!\\w)$escaped(?!\\w)' : escaped,
      caseSensitive: false,
    );
  }

  String _lowerPattern(PingRule rule) => _lowerPatternCache.putIfAbsent(
    '${rule.id}\u0000${rule.pattern}',
    () => rule.pattern.toLowerCase(),
  );
}
