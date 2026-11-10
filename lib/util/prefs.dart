import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chrome_theme.dart';
import 'settings.dart';

/// Typed facade over [SharedPreferences]. User settings live in [Settings],
/// one line each with key and default. Device state, caches, timestamps and
/// per-account data keep their keys here. Callers load one instance with
/// [Prefs.load] and then read synchronously or write asynchronously.
///
/// The backing store is the plugin's cached instance; the wrapper is rebuilt
/// per call on purpose so tests that swap `SharedPreferences.setMockInitialValues`
/// observe the new store instead of a stale cache.
class Prefs {
  Prefs._(this._p);

  final SharedPreferences _p;

  /// The most recent instance returned by [load], for synchronous reads.
  ///
  /// Every wrapper shares the same underlying SharedPreferences singleton, so
  /// a captured instance reads current values. Tests that swap
  /// `setMockInitialValues` refresh this on the next [load].
  static Prefs? get loaded => _loaded;
  static Prefs? _loaded;

  /// Loads the shared preferences store.
  static Future<Prefs> load() async {
    final prefs = Prefs._(await SharedPreferences.getInstance());
    // Set before binding, so listeners woken by the bind read this store.
    _loaded = prefs;
    await Settings.bind();
    if (!_installChecked) {
      _installChecked = true;
      // Saved prefs on the first load mean an install from before the
      // introduction, which must never show it. Fresh installs start empty.
      final p = prefs._p;
      if (p.getKeys().isNotEmpty && !p.containsKey(_kWelcomeSeen)) {
        await p.setBool(_kWelcomeSeen, true);
      }
    }
    await prefs._repairChromeThemeKey();
    return prefs;
  }

  static bool _installChecked = false;

  @visibleForTesting
  static void resetInstallCheck() => _installChecked = false;

  /// Escape hatch for APIs that must take the raw store (dynamic keys, key
  /// iteration). Prefer the typed accessors.
  SharedPreferences get raw => _p;

  /// Raw string read for dynamic keys; prefer a typed getter.
  String? rawGetString(String key) => _p.getString(key);

  // ── App / theme ─────────────────────────────────────────────────────
  static const _kChannels = 'channels';

  List<String> get channels => _p.getStringList(_kChannels) ?? const [];

  Future<void> setChannels(List<String> value) =>
      _p.setStringList(_kChannels, value);

  // ── Chat behavior ───────────────────────────────────────────────────
  static const _kMentionPush = 'mention_push';
  static const _kNotificationsPausedUntil = 'notifications_paused_until';
  static const _kWelcomeSeen = 'welcome_seen';
  static const _kVideoUploadNoted = 'video_upload_noted';
  static const _kLastSeenVersion = 'last_seen_version';
  static const _kLastUpdateCheck = 'last_update_check';
  static const _kNotifiedUpdate = 'notified_update_version';
  static const _kAvailableUpdate = 'available_update_version';
  static const _kDismissedUpdate = 'dismissed_update_version';

  int get historyFetchLimit => Settings.historyFetchLimit;

  bool get mentionPush => _p.getBool(_kMentionPush) ?? false;

  Future<void> setMentionPush(bool value) => _p.setBool(_kMentionPush, value);

  /// Epoch milliseconds; absent when notifications aren't paused.
  int? get notificationsPausedUntil => _p.getInt(_kNotificationsPausedUntil);

  Future<void> setNotificationsPausedUntil(int? value) => value == null
      ? _p.remove(_kNotificationsPausedUntil)
      : _p.setInt(_kNotificationsPausedUntil, value);

  bool get welcomeSeen => _p.getBool(_kWelcomeSeen) ?? false;

  Future<void> setWelcomeSeen(bool value) => _p.setBool(_kWelcomeSeen, value);

  /// Whether the person has been told videos keep their metadata.
  bool get videoUploadNoted => _p.getBool(_kVideoUploadNoted) ?? false;

  Future<void> setVideoUploadNoted() => _p.setBool(_kVideoUploadNoted, true);

  /// App version at the last launch; null before the first one.
  String? get lastSeenVersion => _p.getString(_kLastSeenVersion);

  Future<void> setLastSeenVersion(String value) =>
      _p.setString(_kLastSeenVersion, value);

  /// Epoch ms of the last store version check.
  int? get lastUpdateCheck => _p.getInt(_kLastUpdateCheck);

  Future<void> setLastUpdateCheck(int value) =>
      _p.setInt(_kLastUpdateCheck, value);

  /// Newer version the snackbar already announced.
  String? get notifiedUpdate => _p.getString(_kNotifiedUpdate);

  Future<void> setNotifiedUpdate(String value) =>
      _p.setString(_kNotifiedUpdate, value);

  /// Newer version the install's store serves, for the Settings banner.
  String? get availableUpdate => _p.getString(_kAvailableUpdate);

  Future<void> setAvailableUpdate(String? value) => value == null
      ? _p.remove(_kAvailableUpdate)
      : _p.setString(_kAvailableUpdate, value);

  /// Version whose Settings banner was dismissed; a newer one shows again.
  String? get dismissedUpdate => _p.getString(_kDismissedUpdate);

  Future<void> setDismissedUpdate(String? value) => value == null
      ? _p.remove(_kDismissedUpdate)
      : _p.setString(_kDismissedUpdate, value);

  /// The selected theme: a preset's name, or `custom:<index>` into
  /// [customChromeThemes]. A stale key reads as the default preset.
  String get chromeThemeKey {
    final saved = Settings.chromeTheme.value;
    return saved != null && _isChromeThemeKey(saved)
        ? saved
        : ChromeTheme.ermchat.name;
  }

  /// Whether [key] names a preset or a custom theme that still exists.
  bool _isChromeThemeKey(String key) {
    if (ChromeTheme.values.any((t) => t.name == key)) return true;
    return _customChromeThemeIndex(key) != null;
  }

  /// The index into [customChromeThemes] that [key] names, or null when it
  /// names none that exists.
  int? _customChromeThemeIndex(String key) {
    if (!key.startsWith(customChromeThemePrefix)) return null;
    final i = int.tryParse(key.substring(customChromeThemePrefix.length));
    return i != null && i >= 0 && i < customChromeThemes.length ? i : null;
  }

  Future<void> setChromeThemeKey(String value) =>
      Settings.chromeTheme.set(value);

  /// Persists the fallback when the stored selection names no theme, so the
  /// picker cannot show a phantom selection after a theme is dropped.
  Future<void> _repairChromeThemeKey() async {
    final saved = Settings.chromeTheme.value;
    if (saved != null && !_isChromeThemeKey(saved)) {
      await Settings.chromeTheme.set(ChromeTheme.ermchat.name);
    }
  }

  /// The selected theme's spec; a missing custom theme falls back to the
  /// default preset. An unusable spec is normalized so it cannot lock the
  /// user out of settings or the view menu.
  ChromeThemeSpec get chromeTheme {
    final key = chromeThemeKey;
    final i = _customChromeThemeIndex(key);
    if (i != null) return customChromeThemes[i].normalized();
    return ChromeTheme.values
        .firstWhere((t) => t.name == key, orElse: () => ChromeTheme.ermchat)
        .spec;
  }

  static const customChromeThemePrefix = 'custom:';

  /// The user's themes, in the order they were made.
  List<ChromeThemeSpec> get customChromeThemes => [
    for (final line in Settings.customChromeThemes.value)
      ?ChromeThemeSpec.decode(line),
  ];

  Future<void> setCustomChromeThemes(List<ChromeThemeSpec> themes) =>
      Settings.customChromeThemes.set([for (final t in themes) t.encode()]);

  // ── Emotes ──────────────────────────────────────────────────────────
  static const _kRecentEmotes = 'recent_emotes';

  String? get recentEmotes => _p.getString(_kRecentEmotes);

  Future<void> setRecentEmotes(String value) =>
      _p.setString(_kRecentEmotes, value);

  // ── TTS ─────────────────────────────────────────────────────────────
  static const _kTtsVoiceId = 'tts_voice_id';
  static const _kTtsVoiceRaw = 'tts_voice_raw';

  String? get ttsVoiceId => _p.getString(_kTtsVoiceId);

  Future<void> setTtsVoiceId(String value) => _p.setString(_kTtsVoiceId, value);

  String? get ttsVoiceRaw => _p.getString(_kTtsVoiceRaw);

  Future<void> setTtsVoiceRaw(String value) =>
      _p.setString(_kTtsVoiceRaw, value);

  // ── Recent messages backend ─────────────────────────────────────────
  static const _kRecentMessagesCustomUrl = 'recent_messages_custom_url';

  String get recentMessagesModeName => Settings.recentMessagesMode.value;
  Future<void> setRecentMessagesModeName(String value) =>
      Settings.recentMessagesMode.set(value);

  String? get recentMessagesCustomUrl =>
      _p.getString(_kRecentMessagesCustomUrl);

  Future<void> setRecentMessagesCustomUrl(String value) =>
      _p.setString(_kRecentMessagesCustomUrl, value);

  Future<void> removeRecentMessagesCustomUrl() =>
      _p.remove(_kRecentMessagesCustomUrl);

  // ── Local stores ────────────────────────────────────────────────────
  static const _kUploaderConfig = 'uploader_config';
  static const _kRecentUploads = 'recent_uploads';
  static const _kKeyboardSettledHeight = 'keyboard_settled_h';

  String? get uploaderConfig => _p.getString(_kUploaderConfig);

  Future<void> setUploaderConfig(String value) =>
      _p.setString(_kUploaderConfig, value);

  String? get recentUploadsRaw => _p.getString(_kRecentUploads);

  Future<void> setRecentUploadsRaw(String value) =>
      _p.setString(_kRecentUploads, value);

  Future<void> removeRecentUploads() => _p.remove(_kRecentUploads);

  double get keyboardSettledHeight =>
      _p.getDouble(_kKeyboardSettledHeight) ?? 0;

  Future<void> setKeyboardSettledHeight(double value) =>
      _p.setDouble(_kKeyboardSettledHeight, value);

  // ── Per-account macros ──────────────────────────────────────────────
  List<String> macroEntries(String login) =>
      _p.getStringList('macros_${login.toLowerCase()}') ?? const [];

  Future<void> setMacroEntries(String login, List<String> value) =>
      _p.setStringList('macros_${login.toLowerCase()}', value);

  // ── Settings export ─────────────────────────────────────────────────
  /// The settings an export carries: every [Settings] entry not marked
  /// otherwise. Account data, joined channels, macros, caches, timestamps,
  /// seen flags, `dev_*` keys and device state live outside [Settings]. So
  /// do the uploader config, which can hold API keys, and the chat proxy and
  /// history endpoints, since the proxy receives the OAuth token and an
  /// imported file must never point it somewhere else.
  static Map<String, Pref<Object?>> get _exportable => {
    for (final p in Settings.all)
      if (p.exported) p.key: p,
  };

  static const _exportFormat = 1;

  /// The exportable settings that are set, as a JSON document.
  String exportSettings(String appVersion) => jsonEncode({
    'format': _exportFormat,
    'app': appVersion,
    'settings': {for (final key in _exportable.keys) key: ?_p.get(key)},
  });

  /// The settings in [text] that [applySettings] would change. Unknown keys
  /// and values of the wrong type are dropped. Null when [text] is not a
  /// settings export.
  Map<String, Object>? settingsToImport(String text) {
    final Object? doc;
    try {
      doc = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (doc is! Map || doc['format'] is! int) return null;
    final settings = doc['settings'];
    if (settings is! Map) return null;
    final exportable = _exportable;
    final out = <String, Object>{};
    for (final MapEntry(:key, :value) in settings.entries) {
      final typed = exportable[key]?.importable(value);
      if (typed == null) continue;
      final current = _p.get(key);
      final same = typed is List ? _sameList(typed, current) : typed == current;
      if (!same) out[key as String] = typed;
    }
    return out;
  }

  static bool _sameList(List<Object?> a, Object? b) =>
      b is List &&
      a.length == b.length &&
      a.indexed.every((e) => e.$2 == b[e.$1]);

  /// Writes [settings] from [settingsToImport]. The caller announces the
  /// change through `PrefsStore`.
  Future<void> applySettings(Map<String, Object> settings) async {
    for (final MapEntry(:key, :value) in settings.entries) {
      switch (value) {
        case final bool v:
          await _p.setBool(key, v);
        case final int v:
          await _p.setInt(key, v);
        case final double v:
          await _p.setDouble(key, v);
        case final String v:
          await _p.setString(key, v);
        case final List<String> v:
          await _p.setStringList(key, v);
      }
    }
  }
}
