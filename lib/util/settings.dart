import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/emote_fetch_tier.dart';
import '../theme_colors.dart';
import 'constants.dart';
import 'layout_density.dart';
import 'timestamp_formatter.dart';

/// One persisted setting: its key, its default, and its own change signal.
///
/// [value] reads the store, so it is always current. Listeners hear only this
/// setting, after [set] or after a bulk write announced through
/// [Settings.refresh].
class Pref<T> extends ChangeNotifier implements ValueListenable<T> {
  Pref(this.key, this.fallback, {this.exported = true});

  final String key;
  final T fallback;

  /// Whether a settings export carries it.
  final bool exported;

  static SharedPreferences? _store;

  /// The value listeners last heard, to tell a bulk write that changed this
  /// setting from one that did not.
  Object? _heard;

  @override
  T get value => decode(_store?.get(key));

  /// The typed value for what the store holds; anything unusable reads as
  /// [fallback].
  @protected
  T decode(Object? raw) => raw is T ? raw : fallback;

  /// What the store keeps for [value].
  @protected
  Object? encode(T value) => value;

  /// The storable form of an imported [raw], or null when it has the wrong
  /// type.
  Object? importable(Object? raw) => raw is T ? raw : null;

  /// Writes [value]. Listeners hear it at once, since the store caches the
  /// write before persisting it.
  Future<void> set(T value) async {
    assert(
      Settings.all.any((s) => identical(s, this)),
      '$key is missing from Settings.all',
    );
    final store = _store ?? await Settings.bind();
    final Future<bool> persisted = switch (encode(value)) {
      null => store.remove(key),
      final bool v => store.setBool(key, v),
      final int v => store.setInt(key, v),
      final double v => store.setDouble(key, v),
      final String v => store.setString(key, v),
      final List<String> v => store.setStringList(key, v),
      final other => throw ArgumentError.value(other, key, 'unstorable'),
    };
    _announce();
    await persisted;
  }

  void _announce() {
    final now = value;
    if (_same(now, _heard)) return;
    _heard = now;
    notifyListeners();
  }

  static bool _same(Object? a, Object? b) =>
      a is List && b is List ? listEquals(a, b) : a == b;
}

/// Where a setting's tile exists; search offers only its own platform's.
enum SettingGate { none, android, notIos }

/// A stored setting: its [Pref] plus the tile that shows it, so the storage,
/// the label, the search entry and the jump target are one declaration.
class Setting<T> extends Pref<T> {
  Setting(
    super.key,
    super.fallback, {
    required this.id,
    required this.page,
    this.section,
    this.keywords = '',
    this.mirrors = const {},
    this.gate = SettingGate.none,
    this.anchored = true,
    super.exported,
  });

  /// Stable name: anchors, titles, help panels and the search index key on it.
  final String id;

  /// The settings page its tile sits on, a `SettingsPageId.name`.
  final String page;

  /// Section header on [page], for the search result's location line.
  final String? section;

  /// Extra words people search by.
  final String keywords;

  /// Aggregate pages that show this setting's own tile too, as
  /// `SettingsPageId.name`; search opens [page], its home.
  final Set<String> mirrors;

  /// Platform gate matching the tile's own.
  final SettingGate gate;

  /// False when no tile reveals it, so search never offers it.
  final bool anchored;
}

class IntSetting extends Setting<int> {
  IntSetting(
    super.key,
    super.fallback, {
    required super.id,
    required super.page,
    super.section,
    super.keywords,
    super.mirrors,
    super.gate,
    super.anchored,
    super.exported,
    this.min,
    this.max,
  });

  final int? min;
  final int? max;

  @override
  int decode(Object? raw) {
    if (raw is! int) return fallback;
    return raw.clamp(min ?? raw, max ?? raw);
  }
}

class DoubleSetting extends Setting<double> {
  DoubleSetting(
    super.key,
    super.fallback, {
    required super.id,
    required super.page,
    super.section,
    super.keywords,
    super.mirrors,
    super.gate,
    super.anchored,
    super.exported,
    this.min,
    this.max,
  });

  final double? min;
  final double? max;

  @override
  double decode(Object? raw) {
    if (raw is! num) return fallback;
    final v = raw.toDouble();
    return v.clamp(min ?? v, max ?? v);
  }

  @override
  Object? importable(Object? raw) => raw is num ? raw.toDouble() : null;
}

/// A flag stored as an int, nonzero on.
class IntFlagSetting extends Setting<bool> {
  IntFlagSetting(
    super.key,
    super.fallback, {
    required super.id,
    required super.page,
    super.section,
    super.keywords,
    super.mirrors,
    super.gate,
    super.anchored,
    super.exported,
  });

  @override
  bool decode(Object? raw) => raw is int ? raw != 0 : fallback;

  @override
  Object? encode(bool value) => value ? 1 : 0;

  @override
  Object? importable(Object? raw) => raw is int ? raw : null;
}

/// An enum stored by name; an unknown name reads as the fallback.
class EnumSetting<E extends Enum> extends Setting<E> {
  EnumSetting(
    super.key,
    super.fallback,
    this.values, {
    required super.id,
    required super.page,
    super.section,
    super.keywords,
    super.mirrors,
    super.gate,
    super.anchored,
    super.exported,
  });

  final List<E> values;

  @override
  E decode(Object? raw) =>
      values.firstWhere((e) => e.name == raw, orElse: () => fallback);

  @override
  Object? encode(E value) => value.name;

  @override
  Object? importable(Object? raw) => raw is String ? raw : null;
}

/// A string list. [L] is nullable where "never set" differs from empty.
class ListSetting<L extends List<String>?> extends Setting<L> {
  ListSetting(
    super.key,
    super.fallback, {
    required super.id,
    required super.page,
    super.section,
    super.keywords,
    super.mirrors,
    super.gate,
    super.anchored,
    super.exported,
  });

  @override
  L decode(Object? raw) =>
      raw is List ? raw.cast<String>().toList() as L : fallback;

  @override
  Object? importable(Object? raw) =>
      raw is List && raw.every((e) => e is String) ? raw.cast<String>() : null;
}

/// Every user setting, one line each. Keys and defaults live here and
/// nowhere else; `Prefs` keeps device state, caches and per-account data.
///
/// Each line also declares where its tile lives, which is what
/// `SettingsSearchPage` indexes: [Setting.anchored] settings carry their own
/// row, and the id keys the title and help maps.
abstract final class Settings {
  /// Points every setting at the plugin's store, then notifies the ones
  /// whose value differs from what listeners heard before it.
  static Future<SharedPreferences> bind() async {
    final store = await SharedPreferences.getInstance();
    if (identical(store, Pref._store)) return store;
    Pref._store = store;
    refresh();
    return store;
  }

  /// Notifies the settings whose value changed since listeners last heard.
  /// Runs after writes that bypass [Pref.set] (imports, raw store writes).
  static void refresh() {
    for (final p in all) {
      p._announce();
    }
  }

  // ── App / theme ─────────────────────────────────────────────────────
  // `id`, `page`, `section` and `keywords` describe the tile that shows the
  // setting: the id keys its search entry, `page` is where search opens and
  // `section` is the header its result points at. A setting no tile reveals,
  // such as device state or a dev flag, is `anchored: false`.

  static final themeMode = EnumSetting(
    'themeMode',
    ThemeMode.system,
    ThemeMode.values,
    id: 'theme',
    page: 'appearance',
    section: 'Theme',
    keywords: 'dark light mode',
  );

  /// App language tag (`es`, `pt_BR`); null follows the system.
  static final locale = Setting<String?>(
    'locale',
    null,
    id: 'locale',
    page: 'language',
    anchored: false,
  );
  static final keepScreenOn = Setting(
    'keep_screen_on',
    true,
    id: 'keep_screen_on',
    page: 'appearance',
    section: 'Display',
    keywords: 'sleep dim',
    mirrors: {'battery'},
  );
  static final trueDark = Setting(
    'true_dark',
    false,
    id: 'true_dark',
    page: 'appearance',
    section: 'Theme',
    keywords: 'black amoled oled',
    mirrors: {'battery'},
  );
  static final accentColor = Setting(
    'accent_color',
    kDefaultAccent,
    id: 'accent_color',
    page: 'appearance',
    section: 'Theme',
    keywords: 'colour',
  );

  // ── Chat behavior ───────────────────────────────────────────────────
  static final maxMessagesPerChannel = IntSetting(
    'max_messages_per_channel',
    kMaxMessagesPerChannelDefault,
    id: 'max_messages',
    page: 'history',
    keywords: 'buffer limit',
  );
  static final recentMessagesLimit = IntSetting(
    'recent_messages_limit',
    kRecentMessagesLimitDefault,
    id: 'recent_messages_limit',
    page: 'history',
    keywords: 'history',
    mirrors: {'data'},
  );

  /// Whether chat is archived on this device. Read once at launch. Off by
  /// default on iOS, which stops the app in the background and leaves gaps.
  static final archiveEnabled = Setting(
    'archive_enabled',
    defaultTargetPlatform != TargetPlatform.iOS,
    id: 'archive_enabled',
    page: 'history',
    section: 'Archive',
    keywords: 'archive history storage disk save offline',
  );

  /// Days of chat the archive keeps, at most 30.
  static final archiveRetentionDays = IntSetting(
    'archive_retention_days',
    30,
    min: 1,
    max: 30,
    id: 'archive_retention',
    page: 'history',
    section: 'Archive',
    keywords: 'archive retention storage days delete',
  );

  /// Megabytes of chat the archive keeps per channel, 0 for no cap.
  static final archiveChannelCapMb = IntSetting(
    'archive_channel_cap_mb',
    0,
    id: 'archive_channel_cap',
    page: 'history',
    section: 'Archive',
    keywords: 'archive storage size megabytes mb limit delete',
  );

  /// History sizes its fetch to the gap since the last message seen,
  /// instead of loading [recentMessagesLimit].
  static final historyDynamicFetch = IntFlagSetting(
    'history_gap_fill',
    true,
    id: 'gap_fill',
    page: 'history',
    keywords: 'history reconnect missed messages robotty',
    mirrors: {'data'},
  );

  /// Messages the first history fetch loads: the default page under dynamic
  /// fetch, which tops up the gap itself, else the manual count.
  static int get historyFetchLimit =>
      dynamicFetchOn ? kRecentMessagesLimitDefault : recentMessagesLimit.value;

  /// Dynamic fetch sizes itself from the archive, so it needs one.
  static bool get dynamicFetchOn =>
      historyDynamicFetch.value && archiveEnabled.value;
  static final replyToThreadRoot = Setting(
    'reply_to_thread_root',
    false,
    id: 'reply_thread_root',
    page: 'chat',
    section: 'Typing',
    keywords: 'root',
  );
  static final backgroundService = Setting(
    'background_service',
    false,
    id: 'stay_connected',
    page: 'chat',
    section: 'Connection',
    keywords: 'keep alive service',
    mirrors: {'battery'},
    gate: SettingGate.android,
  );
  static final whisperNotifications = Setting(
    'whisper_notifications',
    false,
    id: 'whisper_push',
    page: 'highlights',
    section: 'Mentions',
    keywords: 'notify push dm',
    gate: SettingGate.notIos,
  );
  static final mentionNotifyForeground = Setting(
    'mention_notify_foreground',
    false,
    id: 'mention_foreground',
    page: 'highlights',
    section: 'Mentions',
    keywords: 'ping push foreground',
    gate: SettingGate.notIos,
  );
  static final preferEmotesFirst = Setting(
    'prefer_emotes_first',
    false,
    id: 'prefer_emotes',
    page: 'chat',
    section: 'Typing',
    keywords: 'tab complete',
  );

  /// Emote picker grid order: code, or provider creation time.
  static final emoteSortOrder = Setting(
    'emote_sort_order',
    'name',
    id: 'emote_sort_order',
    page: 'chat',
    section: 'Emotes',
    keywords: 'emote picker order sort alphabetical newest oldest 7tv bttv ffz',
  );

  /// Haptic feedback on holds, drags and crossed thresholds.
  static final haptics = Setting(
    'haptics',
    true,
    id: 'haptics',
    page: 'appearance',
    section: 'Layout',
    keywords: 'vibration vibrate feedback buzz',
  );

  /// Swiping up from send opens the send menu (spam).
  static final sendSwipeMenu = Setting(
    'send_swipe_menu',
    false,
    id: 'send_swipe',
    page: 'chat',
    section: 'Typing',
    // Its speed sliders show only while it is on, so they search here.
    keywords: 'send menu repeat swipe gesture speed interval rate limit ms',
  );

  /// Gap between spam sends in ms for a plain account; 0 paces
  /// automatically under Twitch's limits.
  static final spamIntervalMs = IntSetting(
    'spam_interval_ms',
    0,
    id: 'spam_interval',
    page: 'chat',
    section: 'Typing',
    anchored: false,
  );

  /// [spamIntervalMs] where you are broadcaster, mod or VIP.
  static final spamIntervalModMs = IntSetting(
    'spam_interval_mod_ms',
    0,
    id: 'spam_interval_mod',
    page: 'chat',
    section: 'Typing',
    anchored: false,
  );
  static final doubleTapNameCopy = Setting(
    'double_tap_name_copy',
    false,
    id: 'double_tap_copy',
    page: 'chat',
    section: 'Users',
  );
  static final showTimestamps = Setting(
    kShowTimestampsPrefKey,
    true,
    id: 'show_timestamps',
    page: 'appearance',
    section: 'Chat display',
    keywords: 'time',
  );
  static final timestampFormat = Setting(
    kTimestampFormatPrefKey,
    kDefaultTimestampFormat,
    id: 'timestamp_format',
    page: 'appearance',
    section: 'Chat display',
    keywords: 'time',
  );
  static final sharedChatMode = Setting(
    'shared_chat_mode',
    'spotlight',
    id: 'shared_chat',
    page: 'chat',
    section: 'Messages',
    keywords: 'spotlight fade',
  );

  /// 7TV name paints and badges.
  static final sevenTvCosmetics = Setting(
    'seventv_name_paints',
    false,
    id: 'seven_tv_cosmetics',
    page: 'emotes',
    anchored: false,
  );
  static final showInput = Setting(
    'show_input',
    true,
    id: 'show_input',
    page: 'chat',
    anchored: false,
  );
  static final mentionFormat = Setting(
    'mention_format',
    '@name',
    id: 'mention_format',
    page: 'chat',
    section: 'Typing',
    keywords: '@ name',
  );
  static final analyticsEnabled = Setting(
    'analytics_enabled',
    false,
    id: 'analytics',
    page: 'tools',
    keywords: 'stats',
  );
  static final whatsNewEnabled = Setting(
    'whats_new_enabled',
    true,
    id: 'whats_new',
    page: 'tools',
    anchored: false,
  );
  static final updateCheckEnabled = Setting(
    'update_check_enabled',
    true,
    id: 'updates',
    page: 'tools',
    keywords: "what's new changelog version",
  );

  // ── Emote playback ──────────────────────────────────────────────────
  static final animateGifs = Setting(
    'animate_gifs',
    true,
    id: 'animate_emotes',
    page: 'emotes',
    section: 'Animation',
    keywords: 'gif',
    mirrors: {'battery'},
  );
  static final ffzEffects = Setting(
    'ffz_effects',
    true,
    id: 'ffz_effects',
    page: 'emotes',
    anchored: false,
  );
  static final bttvModifiers = Setting(
    'bttv_modifiers',
    true,
    id: 'bttv_modifiers',
    page: 'emotes',
    anchored: false,
  );
  static final adaptiveEmoteFps = Setting(
    'adaptive_emote_fps',
    true,
    id: 'adaptive_fps',
    page: 'emotes',
    section: 'Animation',
    keywords: 'fps battery',
    mirrors: {'battery'},
  );

  /// Emote frame rate while idle under adaptive, 0 to 60; 0 freezes.
  static final idleEmoteFps = IntSetting(
    'idle_emote_fps',
    30,
    id: 'idle_fps',
    page: 'emotes',
    section: 'Animation',
    keywords: 'fps battery',
    mirrors: {'battery'},
  );

  // ── Customization ───────────────────────────────────────────────────
  static final chatFontSize = DoubleSetting(
    'chat_font_size',
    14,
    id: 'chat_font_size',
    page: 'appearance',
    section: 'Chat display',
    keywords: 'text',
  );

  /// Chat body weight as a CSS value: 400, 500, 600 or 700.
  static final chatFontWeight = IntSetting(
    'chat_font_weight',
    400,
    id: 'chat_font_weight',
    page: 'appearance',
    section: 'Chat display',
    keywords: 'text bold thickness',
  );
  static final highlightOpacity = DoubleSetting(
    'highlight_opacity',
    0.6,
    id: 'highlight_strength',
    page: 'highlights',
    section: 'Appearance',
    keywords: 'opacity tint',
  );
  static final checkeredMessages = Setting(
    'checkered_messages',
    false,
    id: 'checkered',
    page: 'appearance',
    section: 'Chat display',
    keywords: 'alternate rows shading',
  );
  static final lineSeparator = Setting(
    'line_separator',
    false,
    id: 'line_separator',
    page: 'appearance',
    section: 'Chat display',
    keywords: 'divider',
  );
  static final fastChannelSnap = Setting(
    'fast_channel_snap',
    true,
    id: 'fast_channel_swipe',
    page: 'appearance',
    section: 'Navigation',
  );
  static final reopenLastChannel = Setting(
    'reopen_last_channel',
    false,
    id: 'reopen_last_channel',
    page: 'appearance',
    section: 'Navigation',
    keywords: 'open reopen startup launch remember tab',
  );

  /// The channel last on screen, which a launch reopens.
  static final lastChannel = Setting<String?>(
    'last_channel',
    null,
    id: 'last_channel',
    page: 'channels',
    anchored: false,
    exported: false,
  );
  static final layoutDensity = EnumSetting(
    'layout_density',
    LayoutDensity.auto,
    LayoutDensity.values,
    id: 'layout',
    page: 'appearance',
    section: 'Layout',
    keywords: 'compact full density',
  );
  static final customLayoutEnabled = Setting(
    'custom_layout_enabled',
    false,
    id: 'custom_layout',
    page: 'customLayout',
  );
  static final overrideTightComposer = Setting(
    'override_tight_composer',
    true,
    id: 'tighter_composer',
    page: 'customLayout',
  );
  static final overrideSheetActionRow = Setting(
    'override_sheet_action_row',
    false,
    id: 'horizontal_sheet_actions',
    page: 'customLayout',
  );
  static final overrideCompactDensity = Setting(
    'override_compact_density',
    true,
    id: 'compact_density',
    page: 'customLayout',
  );

  /// The selected chrome theme key; `Prefs.chromeThemeKey` validates it.
  static final chromeTheme = Setting<String?>(
    'chrome_theme',
    null,
    id: 'chrome_theme',
    page: 'appearance',
    anchored: false,
  );

  /// Encoded custom chrome themes, in the order they were made.
  static final customChromeThemes = ListSetting<List<String>>(
    'chrome_themes_custom',
    const [],
    id: 'chrome_themes',
    page: 'appearance',
    anchored: false,
  );

  // ── Inline embeds ───────────────────────────────────────────────────
  static final giphyInlineEnabled = Setting(
    kGiphyInlineEnabledPrefKey,
    kGiphyInlineEnabledDefault,
    id: 'show_giphy',
    page: 'inlineEmbeds',
    section: 'Giphy',
    keywords: 'gif',
    mirrors: {'data'},
  );
  static final giphyInlineHeight = DoubleSetting(
    kGiphyInlineHeightPrefKey,
    kGiphyInlineHeightDefault,
    min: kGiphyInlineHeightMin,
    max: kGiphyInlineHeightMax,
    id: 'giphy_height',
    page: 'inlineEmbeds',
    section: 'Giphy',
  );
  static final imageEmbedEnabled = Setting(
    kImageEmbedEnabledPrefKey,
    kImageEmbedEnabledDefault,
    id: 'show_images',
    page: 'inlineEmbeds',
    section: 'Images',
  );
  static final imageEmbedHeight = DoubleSetting(
    kImageEmbedHeightPrefKey,
    kImageEmbedHeightDefault,
    min: kImageEmbedHeightMin,
    max: kImageEmbedHeightMax,
    id: 'image_height',
    page: 'inlineEmbeds',
    section: 'Images',
  );

  // ── Emotes ──────────────────────────────────────────────────────────
  static final emoteFetchTier = IntSetting(
    'emote_fetch_tier',
    EmoteFetchTier.high.index,
    min: 0,
    max: EmoteFetchTier.values.length - 1,
    id: 'emote_fetching',
    page: 'emotes',
    keywords: 'quality tier data',
    mirrors: {'data'},
  );
  static final emoteFetchAuto = IntSetting(
    'emote_fetch_auto',
    defaultEmoteFetchAutoMode.index,
    id: 'auto_data_saver',
    page: 'emotes',
    keywords: 'cellular wifi',
    mirrors: {'data'},
  );
  static final emoteCacheMb = IntSetting(
    'emote_cache_mb',
    defaultEmoteCacheMb,
    id: 'emote_cache',
    page: 'emotes',
    keywords: 'storage nuke clear',
    mirrors: {'data'},
  );

  /// Null until the user first changes providers.
  static final emoteProvidersDisabled = ListSetting<List<String>?>(
    'emote_providers_disabled',
    null,
    id: 'providers',
    page: 'emotes',
    keywords: 'twitch bttv ffz 7tv effects modifiers paints badges cosmetics',
  );
  static final emoteAllowUnlisted7tv = Setting(
    'emote_7tv_allow_unlisted',
    true,
    id: 'unlisted_emotes',
    page: 'emotes',
  );
  static final emoteAllowPersonal7tv = Setting(
    'emote_7tv_allow_personal',
    true,
    id: 'personal_emotes',
    page: 'emotes',
    keywords: 'seventv subscriber',
  );

  // ── TTS ─────────────────────────────────────────────────────────────
  static final ttsEnabled = Setting(
    'tts_enabled',
    false,
    id: 'enable_tts',
    page: 'tts',
  );
  static final ttsQueueMode = Setting(
    'tts_queue_mode',
    'queue',
    id: 'tts_queue_mode',
    page: 'tts',
  );
  static final ttsFormatMode = Setting(
    'tts_format_mode',
    'userAndMessage',
    id: 'tts_format',
    page: 'tts',
  );
  static final ttsIgnoreUrls = Setting(
    'tts_ignore_urls',
    true,
    id: 'tts_ignore_urls',
    page: 'tts',
  );
  static final ttsIgnoreEmotes = Setting(
    'tts_ignore_emotes',
    true,
    id: 'tts_ignore_emotes',
    page: 'tts',
  );
  static final ttsForceEnglish = Setting(
    'tts_force_english',
    false,
    id: 'tts_force_english',
    page: 'tts',
  );
  static final ttsUserIgnoreList = ListSetting<List<String>>(
    'tts_user_ignore_list',
    const [],
    id: 'tts_ignored_users',
    page: 'tts',
  );

  // ── Stream, history backend, local stores ───────────────────────────
  static final streamPipEnabled = Setting(
    'stream_pip_enabled',
    false,
    id: 'pip',
    page: 'tools',
    section: 'Livestreams',
    keywords: 'pip stream',
    gate: SettingGate.android,
  );
  static final recentMessagesMode = Setting(
    'recent_messages_mode',
    'auto',
    id: 'recent_messages_source',
    page: 'history',
    keywords: 'history provider robotty',
  );
  static final localIgnores = Setting(
    'local_ignores_v1',
    '',
    id: 'ignores',
    page: 'highlights',
    section: "Don't highlight",
    keywords: 'block mute hide',
  );
  static final keywordReplacements = Setting(
    'keyword_replacements_v1',
    '',
    id: 'keyword_replacements',
    page: 'highlights',
    anchored: false,
  );
  static final pingRules = Setting<String?>(
    'ping_rules_v1',
    null,
    id: 'ping_rules',
    page: 'highlights',
    anchored: false,
  );
  static final analyticsFilterStopwords = Setting(
    'analytics_filter_stopwords',
    false,
    id: 'analytics_filter_stopwords',
    page: 'tools',
    anchored: false,
  );

  /// Null until first saved, so the defaults seed once.
  static final linkWhitelist = ListSetting<List<String>?>(
    kLinkWhitelistPrefKey,
    null,
    id: 'link_whitelist',
    page: 'chat',
    anchored: false,
  );
  static final linkWhitelistEnabled = Setting(
    'link_whitelist_enabled',
    false,
    id: 'split_links',
    page: 'chat',
    section: 'Messages',
    keywords: 'whitelist domains',
  );

  // ── Chat proxy (ermchat-server) ─────────────────────────────────────
  // Never exported: the proxy receives the OAuth token, so an imported file
  // must never point it somewhere else.
  static final proxyEnabled = Setting(
    'proxy_enabled',
    false,
    id: 'chat_proxy',
    page: 'chat',
    section: 'Connection',
    keywords: 'server',
    exported: false,
  );
  static final proxyUrl = Setting(
    'proxy_url',
    '',
    id: 'proxy_url',
    page: 'chat',
    anchored: false,
    exported: false,
  );

  // ── Developer ───────────────────────────────────────────────────────
  static final testChatWidgets = Setting(
    'test_chat_widgets',
    false,
    id: 'test_chat_widgets',
    page: 'about',
    anchored: false,
    exported: false,
  );

  /// Live poll, prediction and hype train cards. Pins always show.
  static final liveChatWidgets = Setting(
    'dev_live_chat_widgets',
    true,
    id: 'live_chat_widgets',
    page: 'about',
    anchored: false,
    exported: false,
  );
  static final useBrowserOAuth = Setting(
    'use_browser_oauth',
    false,
    id: 'use_browser_oauth',
    page: 'account',
    anchored: false,
    exported: false,
  );

  /// The next update check reports a fake newer version.
  static final armUpdate = Setting(
    'dev_arm_update',
    false,
    id: 'arm_update',
    page: 'about',
    anchored: false,
    exported: false,
  );

  /// The user card shows mod actions in any channel, live or not.
  static final forceModActions = Setting(
    'dev_force_mod_actions',
    false,
    id: 'force_mod_actions',
    page: 'about',
    anchored: false,
    exported: false,
  );

  /// The view menu offers the stream on a channel that is not live.
  static final devShowOfflineStream = Setting(
    'dev_show_offline_stream',
    false,
    id: 'dev_show_offline_stream',
    page: 'about',
    anchored: false,
    exported: false,
  );

  /// Mod menu entries stay available on channels the account owns or
  /// moderates, without waiting for EventSub moderation.
  static final devForceModTools = Setting(
    'dev_force_mod_tools',
    false,
    id: 'dev_force_mod_tools',
    page: 'about',
    anchored: false,
    exported: false,
  );

  static final List<Setting<Object?>> all = [
    themeMode,
    locale,
    keepScreenOn,
    trueDark,
    accentColor,
    maxMessagesPerChannel,
    recentMessagesLimit,
    archiveEnabled,
    archiveRetentionDays,
    archiveChannelCapMb,
    historyDynamicFetch,
    replyToThreadRoot,
    backgroundService,
    whisperNotifications,
    mentionNotifyForeground,
    preferEmotesFirst,
    emoteSortOrder,
    haptics,
    sendSwipeMenu,
    spamIntervalMs,
    spamIntervalModMs,
    doubleTapNameCopy,
    showTimestamps,
    timestampFormat,
    sharedChatMode,
    sevenTvCosmetics,
    showInput,
    mentionFormat,
    analyticsEnabled,
    whatsNewEnabled,
    updateCheckEnabled,
    animateGifs,
    ffzEffects,
    bttvModifiers,
    adaptiveEmoteFps,
    idleEmoteFps,
    chatFontSize,
    chatFontWeight,
    highlightOpacity,
    checkeredMessages,
    lineSeparator,
    fastChannelSnap,
    reopenLastChannel,
    lastChannel,
    layoutDensity,
    customLayoutEnabled,
    overrideTightComposer,
    overrideSheetActionRow,
    overrideCompactDensity,
    chromeTheme,
    customChromeThemes,
    giphyInlineEnabled,
    giphyInlineHeight,
    imageEmbedEnabled,
    imageEmbedHeight,
    emoteFetchTier,
    emoteFetchAuto,
    emoteCacheMb,
    emoteProvidersDisabled,
    emoteAllowUnlisted7tv,
    emoteAllowPersonal7tv,
    ttsEnabled,
    ttsQueueMode,
    ttsFormatMode,
    ttsIgnoreUrls,
    ttsIgnoreEmotes,
    ttsForceEnglish,
    ttsUserIgnoreList,
    streamPipEnabled,
    recentMessagesMode,
    localIgnores,
    keywordReplacements,
    pingRules,
    analyticsFilterStopwords,
    linkWhitelist,
    linkWhitelistEnabled,
    proxyEnabled,
    proxyUrl,
    testChatWidgets,
    liveChatWidgets,
    useBrowserOAuth,
    armUpdate,
    forceModActions,
    devShowOfflineStream,
    devForceModTools,
  ];
}
