import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chrome_theme.dart';
import 'layout_density.dart';
import 'settings.dart';

/// Typed facade over [SharedPreferences]. User settings live in [Settings],
/// one line each with key and default; the accessors here for them are
/// shorthands. Device state, caches, timestamps and per-account data keep
/// their keys here. Callers load one instance with [Prefs.load] and then read
/// synchronously or write asynchronously.
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
    final prefs = Prefs._(await Settings.bind());
    _loaded = prefs;
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

  ThemeMode get themeMode => Settings.themeMode.value;
  Future<void> setThemeMode(ThemeMode value) => Settings.themeMode.set(value);

  String? get locale => Settings.locale.value;
  Future<void> setLocale(String? value) => Settings.locale.set(value);

  bool get keepScreenOn => Settings.keepScreenOn.value;
  Future<void> setKeepScreenOn(bool value) => Settings.keepScreenOn.set(value);

  bool get trueDark => Settings.trueDark.value;
  Future<void> setTrueDark(bool value) => Settings.trueDark.set(value);

  String get accentColor => Settings.accentColor.value;
  Future<void> setAccentColor(String value) => Settings.accentColor.set(value);

  List<String> get channels => _p.getStringList(_kChannels) ?? const [];

  Future<void> setChannels(List<String> value) =>
      _p.setStringList(_kChannels, value);

  // ── Chat behavior ───────────────────────────────────────────────────
  static const _kMentionPush = 'mention_push';
  static const _kNotificationsPausedUntil = 'notifications_paused_until';
  static const _kWelcomeSeen = 'welcome_seen';
  static const _kLastSeenVersion = 'last_seen_version';
  static const _kLastUpdateCheck = 'last_update_check';
  static const _kNotifiedUpdate = 'notified_update_version';
  static const _kAvailableUpdate = 'available_update_version';
  static const _kDismissedUpdate = 'dismissed_update_version';
  static const _kArmWhatsNew = 'dev_arm_whats_new';
  static const _kArmUpdate = 'dev_arm_update';
  static const _kForceModActions = 'dev_force_mod_actions';

  int get maxMessagesPerChannel => Settings.maxMessagesPerChannel.value;
  Future<void> setMaxMessagesPerChannel(int value) =>
      Settings.maxMessagesPerChannel.set(value);

  int get recentMessagesLimit => Settings.recentMessagesLimit.value;
  Future<void> setRecentMessagesLimit(int value) =>
      Settings.recentMessagesLimit.set(value);

  int get archiveRetentionDays => Settings.archiveRetentionDays.value;
  Future<void> setArchiveRetentionDays(int value) =>
      Settings.archiveRetentionDays.set(value);

  int get archiveChannelCapMb => Settings.archiveChannelCapMb.value;
  Future<void> setArchiveChannelCapMb(int value) =>
      Settings.archiveChannelCapMb.set(value);

  /// Whether history sizes its fetch to the gap since the last message seen,
  /// instead of loading [recentMessagesLimit].
  bool get historyDynamicFetch => Settings.historyGapFill.value != 0;
  Future<void> setHistoryDynamicFetch(bool on) =>
      Settings.historyGapFill.set(on ? 1 : 0);

  int get historyFetchLimit => Settings.historyFetchLimit;

  bool get replyToThreadRoot => Settings.replyToThreadRoot.value;
  Future<void> setReplyToThreadRoot(bool value) =>
      Settings.replyToThreadRoot.set(value);

  bool get backgroundService => Settings.backgroundService.value;
  Future<void> setBackgroundService(bool value) =>
      Settings.backgroundService.set(value);

  bool get mentionPush => _p.getBool(_kMentionPush) ?? false;

  Future<void> setMentionPush(bool value) => _p.setBool(_kMentionPush, value);

  /// Epoch milliseconds; absent when notifications aren't paused.
  int? get notificationsPausedUntil => _p.getInt(_kNotificationsPausedUntil);

  Future<void> setNotificationsPausedUntil(int? value) => value == null
      ? _p.remove(_kNotificationsPausedUntil)
      : _p.setInt(_kNotificationsPausedUntil, value);

  bool get mentionNotifyForeground => Settings.mentionNotifyForeground.value;
  Future<void> setMentionNotifyForeground(bool value) =>
      Settings.mentionNotifyForeground.set(value);

  bool get whisperNotifications => Settings.whisperNotifications.value;
  Future<void> setWhisperNotifications(bool value) =>
      Settings.whisperNotifications.set(value);

  bool get preferEmotesFirst => Settings.preferEmotesFirst.value;
  Future<void> setPreferEmotesFirst(bool value) =>
      Settings.preferEmotesFirst.set(value);

  bool get haptics => Settings.haptics.value;
  Future<void> setHaptics(bool value) => Settings.haptics.set(value);

  bool get sendSwipeMenu => Settings.sendSwipeMenu.value;
  Future<void> setSendSwipeMenu(bool value) =>
      Settings.sendSwipeMenu.set(value);

  int get spamIntervalMs => Settings.spamIntervalMs.value;
  Future<void> setSpamIntervalMs(int value) =>
      Settings.spamIntervalMs.set(value);

  int get spamIntervalModMs => Settings.spamIntervalModMs.value;
  Future<void> setSpamIntervalModMs(int value) =>
      Settings.spamIntervalModMs.set(value);

  bool get doubleTapNameCopy => Settings.doubleTapNameCopy.value;
  Future<void> setDoubleTapNameCopy(bool value) =>
      Settings.doubleTapNameCopy.set(value);

  bool get showTimestamps => Settings.showTimestamps.value;
  Future<void> setShowTimestamps(bool value) =>
      Settings.showTimestamps.set(value);

  String get timestampFormat => Settings.timestampFormat.value;
  Future<void> setTimestampFormat(String value) =>
      Settings.timestampFormat.set(value);

  String get sharedChatMode => Settings.sharedChatMode.value;
  Future<void> setSharedChatMode(String value) =>
      Settings.sharedChatMode.set(value);

  bool get sevenTvCosmetics => Settings.sevenTvCosmetics.value;
  Future<void> setSevenTvCosmetics(bool value) =>
      Settings.sevenTvCosmetics.set(value);

  bool get showInput => Settings.showInput.value;
  Future<void> setShowInput(bool value) => Settings.showInput.set(value);

  String get mentionFormat => Settings.mentionFormat.value;
  Future<void> setMentionFormat(String value) =>
      Settings.mentionFormat.set(value);

  bool get welcomeSeen => _p.getBool(_kWelcomeSeen) ?? false;

  Future<void> setWelcomeSeen(bool value) => _p.setBool(_kWelcomeSeen, value);

  bool get analyticsEnabled => Settings.analyticsEnabled.value;
  Future<void> setAnalyticsEnabled(bool value) =>
      Settings.analyticsEnabled.set(value);

  bool get whatsNewEnabled => Settings.whatsNewEnabled.value;
  Future<void> setWhatsNewEnabled(bool value) =>
      Settings.whatsNewEnabled.set(value);

  bool get updateCheckEnabled => Settings.updateCheckEnabled.value;
  Future<void> setUpdateCheckEnabled(bool value) =>
      Settings.updateCheckEnabled.set(value);

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

  /// Dev: the next launch shows What's new regardless of version.
  bool get armWhatsNew => _p.getBool(_kArmWhatsNew) ?? false;

  Future<void> setArmWhatsNew(bool value) => _p.setBool(_kArmWhatsNew, value);

  /// Dev: the next update check reports a fake newer version.
  bool get armUpdate => _p.getBool(_kArmUpdate) ?? false;

  Future<void> setArmUpdate(bool value) => _p.setBool(_kArmUpdate, value);

  /// Dev: the user card shows mod actions in any channel, live or not.
  bool get forceModActions => _p.getBool(_kForceModActions) ?? false;

  Future<void> setForceModActions(bool value) =>
      _p.setBool(_kForceModActions, value);

  bool get animateGifs => Settings.animateGifs.value;
  Future<void> setAnimateGifs(bool value) => Settings.animateGifs.set(value);

  bool get ffzEffects => Settings.ffzEffects.value;
  Future<void> setFfzEffects(bool value) => Settings.ffzEffects.set(value);

  bool get bttvModifiers => Settings.bttvModifiers.value;
  Future<void> setBttvModifiers(bool value) =>
      Settings.bttvModifiers.set(value);

  bool get adaptiveEmoteFps => Settings.adaptiveEmoteFps.value;
  Future<void> setAdaptiveEmoteFps(bool value) =>
      Settings.adaptiveEmoteFps.set(value);

  int get idleEmoteFps => Settings.idleEmoteFps.value;
  Future<void> setIdleEmoteFps(int value) => Settings.idleEmoteFps.set(value);

  // ── Customization ───────────────────────────────────────────────────
  double get chatFontSize => Settings.chatFontSize.value;
  Future<void> setChatFontSize(double value) =>
      Settings.chatFontSize.set(value);

  int get chatFontWeight => Settings.chatFontWeight.value;
  Future<void> setChatFontWeight(int value) =>
      Settings.chatFontWeight.set(value);

  double get highlightOpacity => Settings.highlightOpacity.value;
  Future<void> setHighlightOpacity(double value) =>
      Settings.highlightOpacity.set(value);

  bool get checkeredMessages => Settings.checkeredMessages.value;
  Future<void> setCheckeredMessages(bool value) =>
      Settings.checkeredMessages.set(value);

  bool get lineSeparator => Settings.lineSeparator.value;
  Future<void> setLineSeparator(bool value) =>
      Settings.lineSeparator.set(value);

  bool get fastChannelSnap => Settings.fastChannelSnap.value;
  Future<void> setFastChannelSnap(bool value) =>
      Settings.fastChannelSnap.set(value);

  LayoutDensity get layoutDensity => Settings.layoutDensity.value;
  Future<void> setLayoutDensity(LayoutDensity value) =>
      Settings.layoutDensity.set(value);

  // ── Custom layout overrides ─────────────────────────────────────────
  bool get customLayoutEnabled => Settings.customLayoutEnabled.value;
  Future<void> setCustomLayoutEnabled(bool value) =>
      Settings.customLayoutEnabled.set(value);

  bool get overrideTightComposer => Settings.overrideTightComposer.value;
  Future<void> setOverrideTightComposer(bool value) =>
      Settings.overrideTightComposer.set(value);

  bool get overrideSheetActionRow => Settings.overrideSheetActionRow.value;
  Future<void> setOverrideSheetActionRow(bool value) =>
      Settings.overrideSheetActionRow.set(value);

  bool get overrideCompactDensity => Settings.overrideCompactDensity.value;
  Future<void> setOverrideCompactDensity(bool value) =>
      Settings.overrideCompactDensity.set(value);

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

  bool get liquidGlass => Settings.liquidGlass.value;

  /// Glass only applies to floating-island chrome themes.
  bool get islandGlass => liquidGlass && chromeTheme.isIsland;

  Future<void> setLiquidGlass(bool value) => Settings.liquidGlass.set(value);

  // ── Inline embeds ───────────────────────────────────────────────────
  bool get giphyInlineEnabled => Settings.giphyInlineEnabled.value;
  Future<void> setGiphyInlineEnabled(bool value) =>
      Settings.giphyInlineEnabled.set(value);

  double get giphyInlineHeight => Settings.giphyInlineHeight.value;
  Future<void> setGiphyInlineHeight(double value) =>
      Settings.giphyInlineHeight.set(value);

  bool get imageEmbedEnabled => Settings.imageEmbedEnabled.value;
  Future<void> setImageEmbedEnabled(bool value) =>
      Settings.imageEmbedEnabled.set(value);

  double get imageEmbedHeight => Settings.imageEmbedHeight.value;
  Future<void> setImageEmbedHeight(double value) =>
      Settings.imageEmbedHeight.set(value);

  // ── Emotes ──────────────────────────────────────────────────────────
  static const _kRecentEmotes = 'recent_emotes';

  int get emoteFetchTier => Settings.emoteFetchTier.value;
  Future<void> setEmoteFetchTier(int value) =>
      Settings.emoteFetchTier.set(value);

  int get emoteFetchAuto => Settings.emoteFetchAuto.value;
  Future<void> setEmoteFetchAuto(int value) =>
      Settings.emoteFetchAuto.set(value);

  int get emoteCacheMb => Settings.emoteCacheMb.value;
  Future<void> setEmoteCacheMb(int value) => Settings.emoteCacheMb.set(value);

  List<String>? get emoteProvidersDisabled =>
      Settings.emoteProvidersDisabled.value;
  Future<void> setEmoteProvidersDisabled(List<String> value) =>
      Settings.emoteProvidersDisabled.set(value);

  bool get emoteAllowUnlisted7tv => Settings.emoteAllowUnlisted7tv.value;
  Future<void> setEmoteAllowUnlisted7tv(bool value) =>
      Settings.emoteAllowUnlisted7tv.set(value);

  bool get emoteAllowPersonal7tv => Settings.emoteAllowPersonal7tv.value;
  Future<void> setEmoteAllowPersonal7tv(bool value) =>
      Settings.emoteAllowPersonal7tv.set(value);

  String? get recentEmotes => _p.getString(_kRecentEmotes);

  Future<void> setRecentEmotes(String value) =>
      _p.setString(_kRecentEmotes, value);

  // ── TTS ─────────────────────────────────────────────────────────────
  static const _kTtsVoiceId = 'tts_voice_id';
  static const _kTtsVoiceRaw = 'tts_voice_raw';

  bool get ttsEnabled => Settings.ttsEnabled.value;
  Future<void> setTtsEnabled(bool value) => Settings.ttsEnabled.set(value);

  String get ttsQueueMode => Settings.ttsQueueMode.value;
  Future<void> setTtsQueueMode(String value) =>
      Settings.ttsQueueMode.set(value);

  String get ttsFormatMode => Settings.ttsFormatMode.value;
  Future<void> setTtsFormatMode(String value) =>
      Settings.ttsFormatMode.set(value);

  bool get ttsIgnoreUrls => Settings.ttsIgnoreUrls.value;
  Future<void> setTtsIgnoreUrls(bool value) =>
      Settings.ttsIgnoreUrls.set(value);

  bool get ttsIgnoreEmotes => Settings.ttsIgnoreEmotes.value;
  Future<void> setTtsIgnoreEmotes(bool value) =>
      Settings.ttsIgnoreEmotes.set(value);

  bool get ttsForceEnglish => Settings.ttsForceEnglish.value;
  Future<void> setTtsForceEnglish(bool value) =>
      Settings.ttsForceEnglish.set(value);

  List<String> get ttsUserIgnoreList => Settings.ttsUserIgnoreList.value;
  Future<void> setTtsUserIgnoreList(List<String> value) =>
      Settings.ttsUserIgnoreList.set(value);

  String? get ttsVoiceId => _p.getString(_kTtsVoiceId);

  Future<void> setTtsVoiceId(String value) => _p.setString(_kTtsVoiceId, value);

  String? get ttsVoiceRaw => _p.getString(_kTtsVoiceRaw);

  Future<void> setTtsVoiceRaw(String value) =>
      _p.setString(_kTtsVoiceRaw, value);

  // ── Stream player ───────────────────────────────────────────────────
  bool get streamPipEnabled => Settings.streamPipEnabled.value;
  Future<void> setStreamPipEnabled(bool value) =>
      Settings.streamPipEnabled.set(value);

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

  // ── Chat proxy (ermchat-server) ─────────────────────────────────────
  static const _kProxyEnabled = 'proxy_enabled';
  static const _kProxyUrl = 'proxy_url';

  bool get proxyEnabled => _p.getBool(_kProxyEnabled) ?? false;

  Future<void> setProxyEnabled(bool value) => _p.setBool(_kProxyEnabled, value);

  String get proxyUrl => _p.getString(_kProxyUrl) ?? '';

  Future<void> setProxyUrl(String value) => _p.setString(_kProxyUrl, value);

  // ── Local stores ────────────────────────────────────────────────────
  static const _kUploaderConfig = 'uploader_config';
  static const _kRecentUploads = 'recent_uploads';
  static const _kTestChatWidgets = 'test_chat_widgets';
  static const _kLiveChatWidgets = 'dev_live_chat_widgets';
  static const _kUseBrowserOAuth = 'use_browser_oauth';
  static const _kKeyboardSettledHeight = 'keyboard_settled_h';

  String get localIgnores => Settings.localIgnores.value;
  Future<void> setLocalIgnores(String value) =>
      Settings.localIgnores.set(value);

  String get keywordReplacements => Settings.keywordReplacements.value;
  Future<void> setKeywordReplacements(String value) =>
      Settings.keywordReplacements.set(value);

  String? get pingRules => Settings.pingRules.value;
  Future<void> setPingRules(String value) => Settings.pingRules.set(value);

  String? get uploaderConfig => _p.getString(_kUploaderConfig);

  Future<void> setUploaderConfig(String value) =>
      _p.setString(_kUploaderConfig, value);

  String? get recentUploadsRaw => _p.getString(_kRecentUploads);

  Future<void> setRecentUploadsRaw(String value) =>
      _p.setString(_kRecentUploads, value);

  Future<void> removeRecentUploads() => _p.remove(_kRecentUploads);

  bool get analyticsFilterStopwords => Settings.analyticsFilterStopwords.value;
  Future<void> setAnalyticsFilterStopwords(bool value) =>
      Settings.analyticsFilterStopwords.set(value);

  bool get testChatWidgets => _p.getBool(_kTestChatWidgets) ?? false;

  Future<void> setTestChatWidgets(bool value) =>
      _p.setBool(_kTestChatWidgets, value);

  /// Dev: live poll, prediction and hype train cards. Pins always show.
  bool get liveChatWidgets => _p.getBool(_kLiveChatWidgets) ?? true;

  Future<void> setLiveChatWidgets(bool value) =>
      _p.setBool(_kLiveChatWidgets, value);

  bool get useBrowserOAuth => _p.getBool(_kUseBrowserOAuth) ?? false;

  Future<void> setUseBrowserOAuth(bool value) =>
      _p.setBool(_kUseBrowserOAuth, value);

  double get keyboardSettledHeight =>
      _p.getDouble(_kKeyboardSettledHeight) ?? 0;

  Future<void> setKeyboardSettledHeight(double value) =>
      _p.setDouble(_kKeyboardSettledHeight, value);

  // ── Link whitelist ──────────────────────────────────────────────────
  List<String>? get linkWhitelist => Settings.linkWhitelist.value;
  Future<void> setLinkWhitelist(List<String> value) =>
      Settings.linkWhitelist.set(value);

  bool get linkWhitelistEnabled => Settings.linkWhitelistEnabled.value;
  Future<void> setLinkWhitelistEnabled(bool value) =>
      Settings.linkWhitelistEnabled.set(value);

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
