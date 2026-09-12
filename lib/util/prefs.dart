import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/emote_fetch_tier.dart';
import '../theme_colors.dart';
import 'constants.dart';
import 'timestamp_formatter.dart';

/// Typed facade over [SharedPreferences]. Every persisted key string and
/// default lives here, grouped by feature. Callers load one instance with
/// [Prefs.load] and then read synchronously or write asynchronously.
///
/// The backing store is the plugin's cached instance; the wrapper is rebuilt
/// per call on purpose so tests that swap `SharedPreferences.setMockInitialValues`
/// observe the new store instead of a stale cache.
class Prefs {
  Prefs._(this._p);

  final SharedPreferences _p;

  /// Loads the shared preferences store.
  static Future<Prefs> load() async =>
      Prefs._(await SharedPreferences.getInstance());

  /// Escape hatch for APIs that must take the raw store (dynamic keys, key
  /// iteration). Prefer the typed accessors.
  SharedPreferences get raw => _p;

  /// Raw string read for dynamic keys; prefer a typed getter.
  String? rawGetString(String key) => _p.getString(key);

  // ── App / theme ─────────────────────────────────────────────────────
  static const _kThemeMode = 'themeMode';
  static const _kKeepScreenOn = 'keep_screen_on';
  static const _kTrueDark = 'true_dark';
  static const _kAccentColor = 'accent_color';
  static const _kChannels = 'channels';

  ThemeMode get themeMode {
    final saved = _p.getString(_kThemeMode);
    if (saved == null) return ThemeMode.system;
    return ThemeMode.values.firstWhere(
      (e) => e.name == saved,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> setThemeMode(ThemeMode value) =>
      _p.setString(_kThemeMode, value.name);

  bool get keepScreenOn => _p.getBool(_kKeepScreenOn) ?? true;

  Future<void> setKeepScreenOn(bool value) => _p.setBool(_kKeepScreenOn, value);

  bool get trueDark => _p.getBool(_kTrueDark) ?? false;

  Future<void> setTrueDark(bool value) => _p.setBool(_kTrueDark, value);

  String get accentColor => _p.getString(_kAccentColor) ?? kDefaultAccent;

  Future<void> setAccentColor(String value) =>
      _p.setString(_kAccentColor, value);

  List<String> get channels => _p.getStringList(_kChannels) ?? const [];

  Future<void> setChannels(List<String> value) =>
      _p.setStringList(_kChannels, value);

  // ── Chat behavior ───────────────────────────────────────────────────
  static const _kMaxMessagesPerChannel = 'max_messages_per_channel';
  static const _kRecentMessagesLimit = 'recent_messages_limit';
  static const _kReplyToThreadRoot = 'reply_to_thread_root';
  static const _kBackgroundService = 'background_service';
  static const _kMentionPush = 'mention_push';
  static const _kWhisperNotifications = 'whisper_notifications';
  static const _kPreferEmotesFirst = 'prefer_emotes_first';
  static const _kSharedChatMode = 'shared_chat_mode';
  static const _kSeventvNamePaints = 'seventv_name_paints';
  static const _kShowInput = 'show_input';
  static const _kMentionFormat = 'mention_format';
  static const _kPingSimpleMode = 'ping_simple_mode';
  static const _kWelcomeSeen = 'welcome_seen';
  static const _kAnimateGifs = 'animate_gifs';

  int get maxMessagesPerChannel =>
      _p.getInt(_kMaxMessagesPerChannel) ?? kMaxMessagesPerChannelDefault;

  Future<void> setMaxMessagesPerChannel(int value) =>
      _p.setInt(_kMaxMessagesPerChannel, value);

  int get recentMessagesLimit =>
      _p.getInt(_kRecentMessagesLimit) ?? kRecentMessagesLimitDefault;

  Future<void> setRecentMessagesLimit(int value) =>
      _p.setInt(_kRecentMessagesLimit, value);

  bool get replyToThreadRoot => _p.getBool(_kReplyToThreadRoot) ?? false;

  Future<void> setReplyToThreadRoot(bool value) =>
      _p.setBool(_kReplyToThreadRoot, value);

  bool get backgroundService => _p.getBool(_kBackgroundService) ?? false;

  Future<void> setBackgroundService(bool value) =>
      _p.setBool(_kBackgroundService, value);

  bool get mentionPush => _p.getBool(_kMentionPush) ?? false;

  Future<void> setMentionPush(bool value) => _p.setBool(_kMentionPush, value);

  bool get whisperNotifications => _p.getBool(_kWhisperNotifications) ?? false;

  Future<void> setWhisperNotifications(bool value) =>
      _p.setBool(_kWhisperNotifications, value);

  bool get preferEmotesFirst => _p.getBool(_kPreferEmotesFirst) ?? false;

  Future<void> setPreferEmotesFirst(bool value) =>
      _p.setBool(_kPreferEmotesFirst, value);

  bool get showTimestamps => _p.getBool(kShowTimestampsPrefKey) ?? true;

  Future<void> setShowTimestamps(bool value) =>
      _p.setBool(kShowTimestampsPrefKey, value);

  String get timestampFormat =>
      _p.getString(kTimestampFormatPrefKey) ?? kDefaultTimestampFormat;

  Future<void> setTimestampFormat(String value) =>
      _p.setString(kTimestampFormatPrefKey, value);

  String get sharedChatMode => _p.getString(_kSharedChatMode) ?? 'spotlight';

  Future<void> setSharedChatMode(String value) =>
      _p.setString(_kSharedChatMode, value);

  bool get seventvNamePaints => _p.getBool(_kSeventvNamePaints) ?? false;

  Future<void> setSeventvNamePaints(bool value) =>
      _p.setBool(_kSeventvNamePaints, value);

  bool get showInput => _p.getBool(_kShowInput) ?? true;

  Future<void> setShowInput(bool value) => _p.setBool(_kShowInput, value);

  String get mentionFormat => _p.getString(_kMentionFormat) ?? '@name';

  Future<void> setMentionFormat(String value) =>
      _p.setString(_kMentionFormat, value);

  bool get pingSimpleMode => _p.getBool(_kPingSimpleMode) ?? true;

  Future<void> setPingSimpleMode(bool value) =>
      _p.setBool(_kPingSimpleMode, value);

  bool get welcomeSeen => _p.getBool(_kWelcomeSeen) ?? false;

  Future<void> setWelcomeSeen(bool value) => _p.setBool(_kWelcomeSeen, value);

  bool get animateGifs => _p.getBool(_kAnimateGifs) ?? true;

  Future<void> setAnimateGifs(bool value) => _p.setBool(_kAnimateGifs, value);

  // ── Customization ───────────────────────────────────────────────────
  static const _kChatFontSize = 'chat_font_size';
  static const _kHighlightOpacity = 'highlight_opacity';
  static const _kCheckeredMessages = 'checkered_messages';
  static const _kLineSeparator = 'line_separator';
  static const _kFastChannelSnap = 'fast_channel_snap';

  double get chatFontSize => _p.getDouble(_kChatFontSize) ?? 14.0;

  Future<void> setChatFontSize(double value) =>
      _p.setDouble(_kChatFontSize, value);

  double get highlightOpacity => _p.getDouble(_kHighlightOpacity) ?? 0.6;

  Future<void> setHighlightOpacity(double value) =>
      _p.setDouble(_kHighlightOpacity, value);

  bool get checkeredMessages => _p.getBool(_kCheckeredMessages) ?? false;

  Future<void> setCheckeredMessages(bool value) =>
      _p.setBool(_kCheckeredMessages, value);

  bool get lineSeparator => _p.getBool(_kLineSeparator) ?? false;

  Future<void> setLineSeparator(bool value) =>
      _p.setBool(_kLineSeparator, value);

  bool get fastChannelSnap => _p.getBool(_kFastChannelSnap) ?? true;

  Future<void> setFastChannelSnap(bool value) =>
      _p.setBool(_kFastChannelSnap, value);

  // ── Inline embeds ───────────────────────────────────────────────────
  bool get giphyInlineEnabled =>
      _p.getBool(kGiphyInlineEnabledPrefKey) ?? kGiphyInlineEnabledDefault;

  Future<void> setGiphyInlineEnabled(bool value) =>
      _p.setBool(kGiphyInlineEnabledPrefKey, value);

  double get giphyInlineHeight =>
      _p.getDouble(kGiphyInlineHeightPrefKey) ?? kGiphyInlineHeightDefault;

  Future<void> setGiphyInlineHeight(double value) =>
      _p.setDouble(kGiphyInlineHeightPrefKey, value);

  bool get imageEmbedEnabled =>
      _p.getBool(kImageEmbedEnabledPrefKey) ?? kImageEmbedEnabledDefault;

  Future<void> setImageEmbedEnabled(bool value) =>
      _p.setBool(kImageEmbedEnabledPrefKey, value);

  double get imageEmbedHeight =>
      _p.getDouble(kImageEmbedHeightPrefKey) ?? kImageEmbedHeightDefault;

  Future<void> setImageEmbedHeight(double value) =>
      _p.setDouble(kImageEmbedHeightPrefKey, value);

  // ── Emotes ──────────────────────────────────────────────────────────
  static const _kEmoteFetchTier = 'emote_fetch_tier';
  static const _kEmoteFetchAuto = 'emote_fetch_auto';
  static const _kEmoteCacheMax = 'emote_cache_max';
  static const _kEmoteProvidersDisabled = 'emote_providers_disabled';
  static const _kEmoteAllowUnlisted7tv = 'emote_7tv_allow_unlisted';
  static const _kRecentEmotes = 'recent_emotes';
  static const _kEmoteUsage = 'emote_usage';
  static const _kEmoteGcMigratedV1 = 'emote_gc_migrated_v1';
  static const _kEmoteGcMigratedV2 = 'emote_gc_migrated_v2';

  int get emoteFetchTier =>
      _p.getInt(_kEmoteFetchTier) ?? EmoteFetchTier.high.index;

  Future<void> setEmoteFetchTier(int value) =>
      _p.setInt(_kEmoteFetchTier, value);

  int get emoteFetchAuto =>
      _p.getInt(_kEmoteFetchAuto) ?? defaultEmoteFetchAutoMode.index;

  Future<void> setEmoteFetchAuto(int value) =>
      _p.setInt(_kEmoteFetchAuto, value);

  int get emoteCacheMax => _p.getInt(_kEmoteCacheMax) ?? defaultEmoteCacheMax;

  Future<void> setEmoteCacheMax(int value) => _p.setInt(_kEmoteCacheMax, value);

  List<String>? get emoteProvidersDisabled =>
      _p.getStringList(_kEmoteProvidersDisabled);

  Future<void> setEmoteProvidersDisabled(List<String> value) =>
      _p.setStringList(_kEmoteProvidersDisabled, value);

  bool get emoteAllowUnlisted7tv =>
      _p.getBool(_kEmoteAllowUnlisted7tv) ?? false;

  Future<void> setEmoteAllowUnlisted7tv(bool value) =>
      _p.setBool(_kEmoteAllowUnlisted7tv, value);

  String? get recentEmotes => _p.getString(_kRecentEmotes);

  Future<void> setRecentEmotes(String value) =>
      _p.setString(_kRecentEmotes, value);

  String? get emoteUsage => _p.getString(_kEmoteUsage);

  Future<void> setEmoteUsage(String value) => _p.setString(_kEmoteUsage, value);

  bool get emoteGcMigratedV1 => _p.getBool(_kEmoteGcMigratedV1) ?? false;

  Future<void> setEmoteGcMigratedV1(bool value) =>
      _p.setBool(_kEmoteGcMigratedV1, value);

  bool get emoteGcMigratedV2 => _p.getBool(_kEmoteGcMigratedV2) ?? false;

  Future<void> setEmoteGcMigratedV2(bool value) =>
      _p.setBool(_kEmoteGcMigratedV2, value);

  // ── TTS ─────────────────────────────────────────────────────────────
  static const _kTtsEnabled = 'tts_enabled';
  static const _kTtsQueueMode = 'tts_queue_mode';
  static const _kTtsFormatMode = 'tts_format_mode';
  static const _kTtsIgnoreUrls = 'tts_ignore_urls';
  static const _kTtsIgnoreEmotes = 'tts_ignore_emotes';
  static const _kTtsForceEnglish = 'tts_force_english';
  static const _kTtsUserIgnoreList = 'tts_user_ignore_list';
  static const _kTtsVoiceId = 'tts_voice_id';
  static const _kTtsVoiceRaw = 'tts_voice_raw';

  bool get ttsEnabled => _p.getBool(_kTtsEnabled) ?? false;

  Future<void> setTtsEnabled(bool value) => _p.setBool(_kTtsEnabled, value);

  String get ttsQueueMode => _p.getString(_kTtsQueueMode) ?? 'queue';

  Future<void> setTtsQueueMode(String value) =>
      _p.setString(_kTtsQueueMode, value);

  String get ttsFormatMode => _p.getString(_kTtsFormatMode) ?? 'userAndMessage';

  Future<void> setTtsFormatMode(String value) =>
      _p.setString(_kTtsFormatMode, value);

  bool get ttsIgnoreUrls => _p.getBool(_kTtsIgnoreUrls) ?? true;

  Future<void> setTtsIgnoreUrls(bool value) =>
      _p.setBool(_kTtsIgnoreUrls, value);

  bool get ttsIgnoreEmotes => _p.getBool(_kTtsIgnoreEmotes) ?? true;

  Future<void> setTtsIgnoreEmotes(bool value) =>
      _p.setBool(_kTtsIgnoreEmotes, value);

  bool get ttsForceEnglish => _p.getBool(_kTtsForceEnglish) ?? false;

  Future<void> setTtsForceEnglish(bool value) =>
      _p.setBool(_kTtsForceEnglish, value);

  List<String> get ttsUserIgnoreList =>
      _p.getStringList(_kTtsUserIgnoreList) ?? const [];

  Future<void> setTtsUserIgnoreList(List<String> value) =>
      _p.setStringList(_kTtsUserIgnoreList, value);

  String? get ttsVoiceId => _p.getString(_kTtsVoiceId);

  Future<void> setTtsVoiceId(String value) => _p.setString(_kTtsVoiceId, value);

  String? get ttsVoiceRaw => _p.getString(_kTtsVoiceRaw);

  Future<void> setTtsVoiceRaw(String value) =>
      _p.setString(_kTtsVoiceRaw, value);

  // ── Stream player ───────────────────────────────────────────────────
  static const _kStreamShowExtensions = 'stream_show_extensions';
  static const _kStreamRetainWebview = 'stream_retain_webview';
  static const _kStreamPipEnabled = 'stream_pip_enabled';
  static const _kStreamSplitFraction = 'stream_split_fraction';

  bool get streamShowExtensions => _p.getBool(_kStreamShowExtensions) ?? false;

  Future<void> setStreamShowExtensions(bool value) =>
      _p.setBool(_kStreamShowExtensions, value);

  bool get streamRetainWebview => _p.getBool(_kStreamRetainWebview) ?? true;

  Future<void> setStreamRetainWebview(bool value) =>
      _p.setBool(_kStreamRetainWebview, value);

  bool get streamPipEnabled => _p.getBool(_kStreamPipEnabled) ?? false;

  Future<void> setStreamPipEnabled(bool value) =>
      _p.setBool(_kStreamPipEnabled, value);

  double get streamSplitFraction => _p.getDouble(_kStreamSplitFraction) ?? 0.5;

  Future<void> setStreamSplitFraction(double value) =>
      _p.setDouble(_kStreamSplitFraction, value);

  // ── Recent messages backend ─────────────────────────────────────────
  static const _kRecentMessagesMode = 'recent_messages_mode';
  static const _kRecentMessagesCustomUrl = 'recent_messages_custom_url';

  String get recentMessagesModeName =>
      _p.getString(_kRecentMessagesMode) ?? 'auto';

  Future<void> setRecentMessagesModeName(String value) =>
      _p.setString(_kRecentMessagesMode, value);

  String? get recentMessagesCustomUrl =>
      _p.getString(_kRecentMessagesCustomUrl);

  Future<void> setRecentMessagesCustomUrl(String value) =>
      _p.setString(_kRecentMessagesCustomUrl, value);

  Future<void> removeRecentMessagesCustomUrl() =>
      _p.remove(_kRecentMessagesCustomUrl);

  // ── Local stores ────────────────────────────────────────────────────
  static const _kLocalIgnores = 'local_ignores_v1';
  static const _kKeywordReplacements = 'keyword_replacements_v1';
  static const _kPingRules = 'ping_rules_v1';
  static const _kLegacyAltPings = 'alt_pings';
  static const _kSavedThreads = 'saved_threads_v1';
  static const _kUploaderConfig = 'uploader_config';
  static const _kRecentUploads = 'recent_uploads';
  static const _kAnalyticsFilterStopwords = 'analytics_filter_stopwords';
  static const _kTestChatWidgets = 'test_chat_widgets';
  static const _kUseBrowserOAuth = 'use_browser_oauth';
  static const _kKeyboardSettledHeight = 'keyboard_settled_h';

  String get localIgnores => _p.getString(_kLocalIgnores) ?? '';

  Future<void> setLocalIgnores(String value) =>
      _p.setString(_kLocalIgnores, value);

  String get keywordReplacements => _p.getString(_kKeywordReplacements) ?? '';

  Future<void> setKeywordReplacements(String value) =>
      _p.setString(_kKeywordReplacements, value);

  String? get pingRules => _p.getString(_kPingRules);

  Future<void> setPingRules(String value) => _p.setString(_kPingRules, value);

  bool get hasLegacyAltPings => _p.containsKey(_kLegacyAltPings);

  Future<void> removeLegacyAltPings() => _p.remove(_kLegacyAltPings);

  String? get savedThreads => _p.getString(_kSavedThreads);

  Future<void> removeSavedThreads() => _p.remove(_kSavedThreads);

  String? get uploaderConfig => _p.getString(_kUploaderConfig);

  Future<void> setUploaderConfig(String value) =>
      _p.setString(_kUploaderConfig, value);

  String? get recentUploadsRaw => _p.getString(_kRecentUploads);

  Future<void> setRecentUploadsRaw(String value) =>
      _p.setString(_kRecentUploads, value);

  Future<void> removeRecentUploads() => _p.remove(_kRecentUploads);

  bool get analyticsFilterStopwords =>
      _p.getBool(_kAnalyticsFilterStopwords) ?? false;

  Future<void> setAnalyticsFilterStopwords(bool value) =>
      _p.setBool(_kAnalyticsFilterStopwords, value);

  bool get testChatWidgets => _p.getBool(_kTestChatWidgets) ?? false;

  Future<void> setTestChatWidgets(bool value) =>
      _p.setBool(_kTestChatWidgets, value);

  bool get useBrowserOAuth => _p.getBool(_kUseBrowserOAuth) ?? false;

  Future<void> setUseBrowserOAuth(bool value) =>
      _p.setBool(_kUseBrowserOAuth, value);

  double get keyboardSettledHeight =>
      _p.getDouble(_kKeyboardSettledHeight) ?? 0;

  Future<void> setKeyboardSettledHeight(double value) =>
      _p.setDouble(_kKeyboardSettledHeight, value);

  // ── Link whitelist ──────────────────────────────────────────────────
  static const _kLinkWhitelistEnabled = 'link_whitelist_enabled';

  List<String>? get linkWhitelist => _p.getStringList(kLinkWhitelistPrefKey);

  Future<void> setLinkWhitelist(List<String> value) =>
      _p.setStringList(kLinkWhitelistPrefKey, value);

  bool get linkWhitelistEnabled => _p.getBool(_kLinkWhitelistEnabled) ?? false;

  Future<void> setLinkWhitelistEnabled(bool value) =>
      _p.setBool(_kLinkWhitelistEnabled, value);

  // ── Per-account macros ──────────────────────────────────────────────
  List<String> macroEntries(String login) =>
      _p.getStringList('macros_${login.toLowerCase()}') ?? const [];

  Future<void> setMacroEntries(String login, List<String> value) =>
      _p.setStringList('macros_${login.toLowerCase()}', value);
}
